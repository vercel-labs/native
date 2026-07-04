// guest-mac VM engine implementation. See vm_host.h for the contract.
//
// Reference: Apple's "Running macOS in a virtual machine on Apple silicon"
// sample — this file is that sample's flow (fetch latest restore image →
// bundle creation from the image's most featureful configuration →
// VZMacOSInstaller → boot) reshaped into the house C-ABI style so the Zig
// layer owns lifecycle and presentation.
//
// Compiled with -mmacosx-version-min=13.0 (dev tooling for the build host;
// the framework target stays 11.0) — every API used here is 13.0 or older,
// with the one 14.0 nicety behind @available.

#import <Foundation/Foundation.h>
#import <Virtualization/Virtualization.h>
#include "vm_host.h"

static NSString *GuestMacString(const char *bytes, size_t len) {
    if (!bytes || len == 0) return @"";
    return [[NSString alloc] initWithBytes:bytes length:len encoding:NSUTF8StringEncoding] ?: @"";
}

@interface GuestMacVmHost : NSObject <VZVirtualMachineDelegate, NSURLSessionDownloadDelegate>
@property(nonatomic, strong) NSURL *bundleURL;
@property(nonatomic, strong) NSURL *cacheURL;
@property(nonatomic, assign) guest_mac_vm_event_callback_t callback;
@property(nonatomic, assign) void *callbackContext;
@property(nonatomic, assign) int state;
@property(nonatomic, strong) VZVirtualMachine *virtualMachine;
@property(nonatomic, strong) VZVirtualMachineView *displayView;
@property(nonatomic, strong) VZMacOSInstaller *installer;
@property(nonatomic, strong) NSTimer *installProgressTimer;
@property(nonatomic, strong) NSURLSession *downloadSession;
@property(nonatomic, strong) NSURL *downloadTargetURL;
@property(nonatomic, assign) BOOL forceStopInFlight;
@end

@implementation GuestMacVmHost

- (NSURL *)diskURL { return [self.bundleURL URLByAppendingPathComponent:@"Disk.img"]; }
- (NSURL *)auxURL { return [self.bundleURL URLByAppendingPathComponent:@"AuxiliaryStorage"]; }
- (NSURL *)hardwareModelURL { return [self.bundleURL URLByAppendingPathComponent:@"HardwareModel"]; }
- (NSURL *)machineIdentifierURL { return [self.bundleURL URLByAppendingPathComponent:@"MachineIdentifier"]; }
- (NSURL *)configURL { return [self.bundleURL URLByAppendingPathComponent:@"config.json"]; }
- (NSURL *)stateURL { return [self.bundleURL URLByAppendingPathComponent:@"state.json"]; }

- (BOOL)bundleInstalled {
    NSFileManager *fm = NSFileManager.defaultManager;
    return [fm fileExistsAtPath:self.diskURL.path] && [fm fileExistsAtPath:self.auxURL.path] &&
        [fm fileExistsAtPath:self.hardwareModelURL.path] && [fm fileExistsAtPath:self.machineIdentifierURL.path] &&
        [fm fileExistsAtPath:self.configURL.path];
}

- (void)emitEvent:(int)kind progress:(double)progress message:(NSString *)message {
    void (^deliver)(void) = ^{
        if (!self.callback) return;
        const char *utf8 = message.UTF8String ?: "";
        self.callback(self.callbackContext, kind, self.state, progress, utf8, strlen(utf8));
    };
    if (NSThread.isMainThread) {
        deliver();
    } else {
        dispatch_async(dispatch_get_main_queue(), deliver);
    }
}

- (void)transitionTo:(int)state detail:(NSString *)detail {
    self.state = state;
    [self writeStateFile];
    [self emitEvent:GUEST_MAC_VM_EVENT_STATE_CHANGED progress:0 message:(detail ?: @"")];
}

- (void)failWith:(NSString *)message {
    [self writeStateFileWithState:@"error" detail:message];
    self.state = GUEST_MAC_VM_STATE_ERROR;
    [self emitEvent:GUEST_MAC_VM_EVENT_ERROR progress:0 message:(message ?: @"unknown error")];
}

- (NSString *)stateName {
    switch (self.state) {
        case GUEST_MAC_VM_STATE_NO_BUNDLE: return @"no-bundle";
        case GUEST_MAC_VM_STATE_FETCHING: return @"fetching";
        case GUEST_MAC_VM_STATE_INSTALLING: return @"installing";
        case GUEST_MAC_VM_STATE_STOPPED: return @"stopped";
        case GUEST_MAC_VM_STATE_STARTING: return @"starting";
        case GUEST_MAC_VM_STATE_RUNNING: return @"running";
        case GUEST_MAC_VM_STATE_STOPPING: return @"stopping";
        default: return @"error";
    }
}

- (void)writeStateFile {
    [self writeStateFileWithState:[self stateName] detail:nil];
}

// state.json is the cross-process status channel: `guest-mac status`/`ip`
// read it from any process while the owning process (UI app or headless
// start) keeps it current. Includes the writer's pid so liveness is
// checkable (kill(pid, 0)).
- (void)writeStateFileWithState:(NSString *)stateName detail:(NSString *)detail {
    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithDictionary:@{
        @"state" : stateName ?: @"error",
        @"pid" : @(getpid()),
    }];
    if (detail.length > 0) payload[@"detail"] = detail;
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (data) [data writeToURL:self.stateURL atomically:YES];
}

- (NSDictionary *)readConfig {
    NSData *data = [NSData dataWithContentsOfURL:self.configURL];
    if (!data) return nil;
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}

// ---- fetch ---------------------------------------------------------------

- (void)fetchRestoreImage {
    self.state = GUEST_MAC_VM_STATE_FETCHING;
    [self emitEvent:GUEST_MAC_VM_EVENT_LOG progress:0 message:@"resolving latest supported restore image"];
    [VZMacOSRestoreImage fetchLatestSupportedWithCompletionHandler:^(VZMacOSRestoreImage *image, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!image) {
                [self failWith:[NSString stringWithFormat:@"restore image catalog fetch failed: %@ (is the binary signed with com.apple.security.virtualization?)", error.localizedDescription]];
                return;
            }
            NSURL *target = [self.cacheURL URLByAppendingPathComponent:image.URL.lastPathComponent];
            if ([NSFileManager.defaultManager fileExistsAtPath:target.path]) {
                self.state = [self bundleInstalled] ? GUEST_MAC_VM_STATE_STOPPED : GUEST_MAC_VM_STATE_NO_BUNDLE;
                [self emitEvent:GUEST_MAC_VM_EVENT_LOG progress:1 message:[NSString stringWithFormat:@"ipsw:%@", target.path]];
                return;
            }
            [self emitEvent:GUEST_MAC_VM_EVENT_LOG progress:0 message:[NSString stringWithFormat:@"downloading %@ (build %@)", image.URL.absoluteString, image.buildVersion]];
            self.downloadTargetURL = target;
            NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.defaultSessionConfiguration;
            self.downloadSession = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
            [[self.downloadSession downloadTaskWithURL:image.URL] resume];
        });
    }];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    double fraction = totalBytesExpectedToWrite > 0 ? (double)totalBytesWritten / (double)totalBytesExpectedToWrite : 0;
    [self emitEvent:GUEST_MAC_VM_EVENT_DOWNLOAD_PROGRESS progress:fraction message:@""];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location {
    NSError *error = nil;
    [NSFileManager.defaultManager removeItemAtURL:self.downloadTargetURL error:nil];
    if (![NSFileManager.defaultManager moveItemAtURL:location toURL:self.downloadTargetURL error:&error]) {
        [self emitEvent:GUEST_MAC_VM_EVENT_ERROR progress:0 message:[NSString stringWithFormat:@"failed to place downloaded IPSW: %@", error.localizedDescription]];
        return;
    }
    NSString *path = self.downloadTargetURL.path;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.state = [self bundleInstalled] ? GUEST_MAC_VM_STATE_STOPPED : GUEST_MAC_VM_STATE_NO_BUNDLE;
        [self emitEvent:GUEST_MAC_VM_EVENT_LOG progress:1 message:[NSString stringWithFormat:@"ipsw:%@", path]];
    });
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (!error) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self failWith:[NSString stringWithFormat:@"IPSW download failed: %@", error.localizedDescription]];
    });
}

// ---- install --------------------------------------------------------------

- (void)installFromIpsw:(NSString *)ipswPath cpus:(uint32_t)cpus memoryBytes:(uint64_t)memoryBytes diskBytes:(uint64_t)diskBytes {
    NSURL *ipswURL = [NSURL fileURLWithPath:ipswPath];
    [self transitionTo:GUEST_MAC_VM_STATE_INSTALLING detail:@"loading restore image"];
    [VZMacOSRestoreImage loadFileURL:ipswURL completionHandler:^(VZMacOSRestoreImage *image, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!image) {
                [self failWith:[NSString stringWithFormat:@"restore image load failed: %@", error.localizedDescription]];
                return;
            }
            VZMacOSConfigurationRequirements *requirements = image.mostFeaturefulSupportedConfiguration;
            if (!requirements || !requirements.hardwareModel.supported) {
                [self failWith:@"no supported macOS configuration for this host (Apple silicon required)"];
                return;
            }
            NSError *bundleError = nil;
            if (![self createBundleWithRequirements:requirements cpus:cpus memoryBytes:memoryBytes diskBytes:diskBytes error:&bundleError]) {
                [self failWith:[NSString stringWithFormat:@"bundle creation failed: %@", bundleError.localizedDescription]];
                return;
            }
            // cpus/memoryBytes 0 → read the clamped values createBundle
            // persisted to config.json (>= the image's minimums).
            VZVirtualMachineConfiguration *configuration = [self bootConfigurationWithShareDir:nil shareTag:nil cpus:0 memoryBytes:0 requirements:requirements error:&bundleError];
            if (!configuration) {
                [self failWith:[NSString stringWithFormat:@"install configuration invalid: %@", bundleError.localizedDescription]];
                return;
            }
            self.virtualMachine = [[VZVirtualMachine alloc] initWithConfiguration:configuration];
            self.virtualMachine.delegate = self;
            self.installer = [[VZMacOSInstaller alloc] initWithVirtualMachine:self.virtualMachine restoreImageURL:ipswURL];
            [self transitionTo:GUEST_MAC_VM_STATE_INSTALLING detail:@"restoring macOS onto the disk image"];
            // NSProgress KVO is delivered on arbitrary threads; a main-loop
            // timer polling fractionCompleted keeps the progress channel on
            // the same thread as every other event.
            self.installProgressTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
                [self emitEvent:GUEST_MAC_VM_EVENT_INSTALL_PROGRESS progress:self.installer.progress.fractionCompleted message:@""];
            }];
            [self.installer installWithCompletionHandler:^(NSError *installError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.installProgressTimer invalidate];
                    self.installProgressTimer = nil;
                    self.installer = nil;
                    self.virtualMachine = nil;
                    if (installError) {
                        [self failWith:[NSString stringWithFormat:@"macOS install failed: %@", installError.localizedDescription]];
                        return;
                    }
                    [self emitEvent:GUEST_MAC_VM_EVENT_INSTALL_PROGRESS progress:1 message:@""];
                    [self transitionTo:GUEST_MAC_VM_STATE_STOPPED detail:@"install complete"];
                });
            }];
        });
    }];
}

- (BOOL)createBundleWithRequirements:(VZMacOSConfigurationRequirements *)requirements cpus:(uint32_t)cpus memoryBytes:(uint64_t)memoryBytes diskBytes:(uint64_t)diskBytes error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtURL:self.bundleURL withIntermediateDirectories:YES attributes:nil error:error]) return NO;

    if (![requirements.hardwareModel.dataRepresentation writeToURL:self.hardwareModelURL options:NSDataWritingAtomic error:error]) return NO;

    VZMacMachineIdentifier *identifier = [[VZMacMachineIdentifier alloc] init];
    if (![identifier.dataRepresentation writeToURL:self.machineIdentifierURL options:NSDataWritingAtomic error:error]) return NO;

    [fm removeItemAtURL:self.auxURL error:nil];
    VZMacAuxiliaryStorage *aux = [[VZMacAuxiliaryStorage alloc] initCreatingStorageAtURL:self.auxURL hardwareModel:requirements.hardwareModel options:0 error:error];
    if (!aux) return NO;

    // Sparse disk: truncate to size without writing data blocks.
    [fm removeItemAtURL:self.diskURL error:nil];
    if (![fm createFileAtPath:self.diskURL.path contents:nil attributes:nil]) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:@{NSLocalizedDescriptionKey : @"could not create Disk.img"}];
        return NO;
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:self.diskURL error:error];
    if (!handle) return NO;
    if (![handle truncateAtOffset:diskBytes error:error]) return NO;
    [handle closeAndReturnError:nil];

    VZMACAddress *mac = [VZMACAddress randomLocallyAdministeredAddress];
    NSDictionary *config = @{
        @"mac_address" : mac.string,
        @"cpus" : @(MAX(cpus, (uint32_t)requirements.minimumSupportedCPUCount)),
        @"memory_bytes" : @(MAX(memoryBytes, requirements.minimumSupportedMemorySize)),
    };
    NSData *configData = [NSJSONSerialization dataWithJSONObject:config options:NSJSONWritingPrettyPrinted error:error];
    if (!configData || ![configData writeToURL:self.configURL options:NSDataWritingAtomic error:error]) return NO;
    return YES;
}

// ---- boot configuration ----------------------------------------------------

- (VZVirtualMachineConfiguration *)bootConfigurationWithShareDir:(NSString *)shareDir shareTag:(NSString *)shareTag cpus:(uint32_t)cpus memoryBytes:(uint64_t)memoryBytes requirements:(VZMacOSConfigurationRequirements *)requirements error:(NSError **)error {
    NSData *hardwareModelData = [NSData dataWithContentsOfURL:self.hardwareModelURL];
    NSData *identifierData = [NSData dataWithContentsOfURL:self.machineIdentifierURL];
    NSDictionary *config = [self readConfig];
    VZMacHardwareModel *hardwareModel = requirements ? requirements.hardwareModel : (hardwareModelData ? [[VZMacHardwareModel alloc] initWithDataRepresentation:hardwareModelData] : nil);
    VZMacMachineIdentifier *identifier = identifierData ? [[VZMacMachineIdentifier alloc] initWithDataRepresentation:identifierData] : nil;
    if (!hardwareModel || !identifier || !config) {
        if (error) *error = [NSError errorWithDomain:@"guest-mac" code:1 userInfo:@{NSLocalizedDescriptionKey : @"VM bundle is missing or incomplete — run install first"}];
        return nil;
    }

    VZMacPlatformConfiguration *platform = [[VZMacPlatformConfiguration alloc] init];
    platform.hardwareModel = hardwareModel;
    platform.machineIdentifier = identifier;
    platform.auxiliaryStorage = [[VZMacAuxiliaryStorage alloc] initWithURL:self.auxURL];

    VZVirtualMachineConfiguration *configuration = [[VZVirtualMachineConfiguration alloc] init];
    configuration.platform = platform;
    configuration.bootLoader = [[VZMacOSBootLoader alloc] init];

    uint32_t configuredCpus = (uint32_t)[config[@"cpus"] unsignedIntValue];
    uint64_t configuredMemory = [config[@"memory_bytes"] unsignedLongLongValue];
    if (cpus == 0) cpus = configuredCpus;
    if (memoryBytes == 0) memoryBytes = configuredMemory;
    configuration.CPUCount = MAX(MIN((NSUInteger)cpus, VZVirtualMachineConfiguration.maximumAllowedCPUCount), VZVirtualMachineConfiguration.minimumAllowedCPUCount);
    configuration.memorySize = MAX(MIN(memoryBytes, VZVirtualMachineConfiguration.maximumAllowedMemorySize), VZVirtualMachineConfiguration.minimumAllowedMemorySize);

    VZDiskImageStorageDeviceAttachment *diskAttachment = [[VZDiskImageStorageDeviceAttachment alloc] initWithURL:self.diskURL readOnly:NO error:error];
    if (!diskAttachment) return nil;
    configuration.storageDevices = @[ [[VZVirtioBlockDeviceConfiguration alloc] initWithAttachment:diskAttachment] ];

    NSString *macString = config[@"mac_address"];
    VZVirtioNetworkDeviceConfiguration *network = [[VZVirtioNetworkDeviceConfiguration alloc] init];
    network.attachment = [[VZNATNetworkDeviceAttachment alloc] init];
    VZMACAddress *mac = macString.length > 0 ? [[VZMACAddress alloc] initWithString:macString] : nil;
    if (mac) network.MACAddress = mac;
    configuration.networkDevices = @[ network ];

    VZMacGraphicsDeviceConfiguration *graphics = [[VZMacGraphicsDeviceConfiguration alloc] init];
    graphics.displays = @[ [[VZMacGraphicsDisplayConfiguration alloc] initWithWidthInPixels:2560 heightInPixels:1600 pixelsPerInch:220] ];
    configuration.graphicsDevices = @[ graphics ];

    configuration.keyboards = @[ [[VZUSBKeyboardConfiguration alloc] init] ];
    configuration.pointingDevices = @[ [[VZMacTrackpadConfiguration alloc] init] ];
    configuration.entropyDevices = @[ [[VZVirtioEntropyDeviceConfiguration alloc] init] ];
    configuration.memoryBalloonDevices = @[ [[VZVirtioTraditionalMemoryBalloonDeviceConfiguration alloc] init] ];

    if (shareDir.length > 0 && shareTag.length > 0) {
        if (![VZVirtioFileSystemDeviceConfiguration validateTag:shareTag error:error]) return nil;
        VZSharedDirectory *directory = [[VZSharedDirectory alloc] initWithURL:[NSURL fileURLWithPath:shareDir] readOnly:NO];
        VZVirtioFileSystemDeviceConfiguration *fs = [[VZVirtioFileSystemDeviceConfiguration alloc] initWithTag:shareTag];
        fs.share = [[VZSingleDirectoryShare alloc] initWithDirectory:directory];
        configuration.directorySharingDevices = @[ fs ];
    }

    if (![configuration validateWithError:error]) return nil;
    return configuration;
}

- (BOOL)configureWithShareDir:(NSString *)shareDir shareTag:(NSString *)shareTag cpus:(uint32_t)cpus memoryBytes:(uint64_t)memoryBytes {
    NSError *error = nil;
    VZVirtualMachineConfiguration *configuration = [self bootConfigurationWithShareDir:shareDir shareTag:shareTag cpus:cpus memoryBytes:memoryBytes requirements:nil error:&error];
    if (!configuration) {
        [self failWith:[NSString stringWithFormat:@"boot configuration invalid: %@", error.localizedDescription]];
        return NO;
    }
    self.virtualMachine = [[VZVirtualMachine alloc] initWithConfiguration:configuration];
    self.virtualMachine.delegate = self;
    VZVirtualMachineView *view = [[VZVirtualMachineView alloc] initWithFrame:NSMakeRect(0, 0, 1280, 800)];
    view.virtualMachine = self.virtualMachine;
    view.capturesSystemKeys = YES;
    if (@available(macOS 14.0, *)) {
        view.automaticallyReconfiguresDisplay = YES;
    }
    self.displayView = view;
    [self transitionTo:GUEST_MAC_VM_STATE_STOPPED detail:@"configured"];
    return YES;
}

// ---- run ------------------------------------------------------------------

- (BOOL)startVm {
    if (!self.virtualMachine) {
        [self failWith:@"start before configure"];
        return NO;
    }
    [self transitionTo:GUEST_MAC_VM_STATE_STARTING detail:@"starting"];
    [self.virtualMachine startWithCompletionHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                [self failWith:[NSString stringWithFormat:@"VM start failed: %@", error.localizedDescription]];
                return;
            }
            [self transitionTo:GUEST_MAC_VM_STATE_RUNNING detail:@"running"];
        });
    }];
    return YES;
}

- (BOOL)requestStopVm {
    if (!self.virtualMachine) return NO;
    NSError *error = nil;
    [self transitionTo:GUEST_MAC_VM_STATE_STOPPING detail:@"stop requested"];
    if (![self.virtualMachine requestStopWithError:&error]) {
        [self failWith:[NSString stringWithFormat:@"guest stop request failed: %@", error.localizedDescription]];
        return NO;
    }
    return YES;
}

- (BOOL)forceStopVm {
    if (!self.virtualMachine) return NO;
    if (self.forceStopInFlight || self.state == GUEST_MAC_VM_STATE_STOPPED) return YES;
    self.forceStopInFlight = YES;
    [self transitionTo:GUEST_MAC_VM_STATE_STOPPING detail:@"force stopping"];
    [self.virtualMachine stopWithCompletionHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.forceStopInFlight = NO;
            if (error) {
                // A force stop racing an in-flight shutdown reports an
                // invalid state transition — not a failure; the delegate
                // callback carries the final state. Log, don't fail.
                [self emitEvent:GUEST_MAC_VM_EVENT_LOG progress:0 message:[NSString stringWithFormat:@"force stop: %@", error.localizedDescription]];
                return;
            }
            [self transitionTo:GUEST_MAC_VM_STATE_STOPPED detail:@"stopped"];
        });
    }];
    return YES;
}

- (void)guestDidStopVirtualMachine:(VZVirtualMachine *)virtualMachine {
    [self transitionTo:GUEST_MAC_VM_STATE_STOPPED detail:@"guest shut down"];
}

- (void)virtualMachine:(VZVirtualMachine *)virtualMachine didStopWithError:(NSError *)error {
    [self failWith:[NSString stringWithFormat:@"VM stopped with error: %@", error.localizedDescription]];
}

@end

// ---- C ABI -----------------------------------------------------------------

guest_mac_vm_host_t *guest_mac_vm_create(const char *bundle_dir, size_t bundle_dir_len, const char *cache_dir, size_t cache_dir_len) {
    NSString *bundlePath = GuestMacString(bundle_dir, bundle_dir_len);
    NSString *cachePath = GuestMacString(cache_dir, cache_dir_len);
    if (bundlePath.length == 0 || cachePath.length == 0) return NULL;
    if (!VZVirtualMachineConfiguration.class) return NULL;

    GuestMacVmHost *host = [[GuestMacVmHost alloc] init];
    host.bundleURL = [NSURL fileURLWithPath:bundlePath.stringByExpandingTildeInPath];
    host.cacheURL = [NSURL fileURLWithPath:cachePath.stringByExpandingTildeInPath];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtURL:host.bundleURL withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtURL:host.cacheURL withIntermediateDirectories:YES attributes:nil error:nil];
    host.state = [host bundleInstalled] ? GUEST_MAC_VM_STATE_STOPPED : GUEST_MAC_VM_STATE_NO_BUNDLE;
    return (guest_mac_vm_host_t *)CFBridgingRetain(host);
}

void guest_mac_vm_destroy(guest_mac_vm_host_t *host) {
    if (!host) return;
    GuestMacVmHost *object = (__bridge_transfer GuestMacVmHost *)(void *)host;
    object.callback = NULL;
}

void guest_mac_vm_set_callback(guest_mac_vm_host_t *host, guest_mac_vm_event_callback_t callback, void *context) {
    GuestMacVmHost *object = (__bridge GuestMacVmHost *)(void *)host;
    object.callback = callback;
    object.callbackContext = context;
}

int guest_mac_vm_state(guest_mac_vm_host_t *host) {
    GuestMacVmHost *object = (__bridge GuestMacVmHost *)(void *)host;
    return object.state;
}

int guest_mac_vm_fetch_restore_image(guest_mac_vm_host_t *host) {
    GuestMacVmHost *object = (__bridge GuestMacVmHost *)(void *)host;
    [object fetchRestoreImage];
    return 1;
}

int guest_mac_vm_install(guest_mac_vm_host_t *host, const char *ipsw_path, size_t ipsw_path_len, uint32_t cpus, uint64_t memory_bytes, uint64_t disk_bytes) {
    GuestMacVmHost *object = (__bridge GuestMacVmHost *)(void *)host;
    NSString *path = GuestMacString(ipsw_path, ipsw_path_len);
    if (path.length == 0) return 0;
    [object installFromIpsw:path.stringByExpandingTildeInPath cpus:cpus memoryBytes:memory_bytes diskBytes:disk_bytes];
    return 1;
}

int guest_mac_vm_configure(guest_mac_vm_host_t *host, const char *share_dir, size_t share_dir_len, const char *share_tag, size_t share_tag_len, uint32_t cpus, uint64_t memory_bytes) {
    GuestMacVmHost *object = (__bridge GuestMacVmHost *)(void *)host;
    NSString *shareDir = GuestMacString(share_dir, share_dir_len);
    NSString *shareTag = GuestMacString(share_tag, share_tag_len);
    return [object configureWithShareDir:(shareDir.length > 0 ? shareDir.stringByExpandingTildeInPath : nil) shareTag:shareTag cpus:cpus memoryBytes:memory_bytes] ? 1 : 0;
}

int guest_mac_vm_start(guest_mac_vm_host_t *host) {
    GuestMacVmHost *object = (__bridge GuestMacVmHost *)(void *)host;
    return [object startVm] ? 1 : 0;
}

int guest_mac_vm_request_stop(guest_mac_vm_host_t *host) {
    GuestMacVmHost *object = (__bridge GuestMacVmHost *)(void *)host;
    return [object requestStopVm] ? 1 : 0;
}

int guest_mac_vm_force_stop(guest_mac_vm_host_t *host) {
    GuestMacVmHost *object = (__bridge GuestMacVmHost *)(void *)host;
    return [object forceStopVm] ? 1 : 0;
}

size_t guest_mac_vm_mac_address(guest_mac_vm_host_t *host, char *buffer, size_t buffer_len) {
    GuestMacVmHost *object = (__bridge GuestMacVmHost *)(void *)host;
    NSString *mac = [object readConfig][@"mac_address"];
    if (mac.length == 0) return 0;
    const char *utf8 = mac.UTF8String;
    size_t len = strlen(utf8);
    if (len > buffer_len) return 0;
    memcpy(buffer, utf8, len);
    return len;
}

void *guest_mac_vm_display_view(guest_mac_vm_host_t *host) {
    GuestMacVmHost *object = (__bridge GuestMacVmHost *)(void *)host;
    return (__bridge void *)object.displayView;
}

void guest_mac_vm_run_main_loop(void) {
    CFRunLoopRun();
}

void guest_mac_vm_interrupt_run_loop(void) {
    CFRunLoopStop(CFRunLoopGetMain());
}

void guest_mac_vm_pump_main_loop(double seconds) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, true);
}
