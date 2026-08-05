#import "audio_capture.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreMedia/CoreMedia.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/message.h>
#pragma clang diagnostic pop
#include <math.h>
#include <stdlib.h>
#include <string.h>

/* Ordinals mirror platform/types.zig. Readable is runtime-generated. */
enum { NS_CAPTURE_STARTED = 0, NS_CAPTURE_READABLE = 1, NS_CAPTURE_STOPPED = 2, NS_CAPTURE_FAILED = 3, NS_CAPTURE_REJECTED = 4 };
enum {
    NS_REASON_NONE = 0, NS_REASON_INVALID_OPTIONS = 1, NS_REASON_PERMISSION_MISSING = 2,
    NS_REASON_PERMISSION_REQUIRED = 3, NS_REASON_ALREADY_RECORDING = 4,
    NS_REASON_DEVICE_NOT_FOUND = 5, NS_REASON_DEVICE_DISCONNECTED = 6,
    NS_REASON_CAPTURE_FAILED = 7, NS_REASON_NO_AUDIO = 8,
    NS_REASON_CONSUMER_TOO_SLOW = 9, NS_REASON_DISCARDED = 10, NS_REASON_UNSUPPORTED = 11,
};
enum { NS_DEVICE = 0, NS_DEVICES_COMPLETED = 1, NS_DEVICES_FAILED = 2, NS_DEVICES_REJECTED = 3 };
enum {
    NS_ACCESS_AUTHORIZED = 0, NS_ACCESS_NOT_AUTHORIZED = 1, NS_ACCESS_NOT_DETERMINED = 2,
    NS_ACCESS_DENIED = 3, NS_ACCESS_RESTRICTED = 4, NS_ACCESS_UNAVAILABLE = 5,
};

/*
 * Native SDK still builds with Xcode 15.4 / the macOS 14.5 SDK. The
 * ScreenCaptureKit microphone declarations were added to the macOS 15 SDK,
 * so name them dynamically after the runtime availability gate instead of
 * making the compiler require newer headers. SCStreamOutputTypeMicrophone is
 * the third SCStreamOutputType case (raw value 2) in the macOS 15 SDK.
 */
static const SCStreamOutputType NativeSdkSCStreamOutputTypeMicrophone = (SCStreamOutputType)2;

static BOOL NativeSdkConfigureScreenCaptureMicrophone(SCStreamConfiguration *configuration, NSString *deviceID) {
    SEL captureSelector = NSSelectorFromString(@"setCaptureMicrophone:");
    SEL deviceSelector = NSSelectorFromString(@"setMicrophoneCaptureDeviceID:");
    if (![configuration respondsToSelector:captureSelector] || ![configuration respondsToSelector:deviceSelector]) return NO;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(configuration, captureSelector, YES);
    ((void (*)(id, SEL, id))objc_msgSend)(configuration, deviceSelector, deviceID);
    return YES;
}

API_AVAILABLE(macos(15.0))
@interface NativeSdkAudioBlock : NSObject
@property(nonatomic, strong) NSMutableData *systemPCM;
@property(nonatomic, strong) NSMutableData *microphonePCM;
@property(nonatomic, strong) NSMutableIndexSet *systemFrames;
@property(nonatomic, strong) NSMutableIndexSet *microphoneFrames;
- (instancetype)initWithByteCount:(NSUInteger)byteCount;
@end

@implementation NativeSdkAudioBlock
- (instancetype)initWithByteCount:(NSUInteger)byteCount {
    self = [super init];
    if (!self) return nil;
    _systemPCM = [NSMutableData dataWithLength:byteCount];
    _microphonePCM = [NSMutableData dataWithLength:byteCount];
    _systemFrames = [NSMutableIndexSet indexSet];
    _microphoneFrames = [NSMutableIndexSet indexSet];
    return self;
}
@end

API_AVAILABLE(macos(15.0))
@interface NativeSdkAudioCapture : NSObject <SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate>
@property(nonatomic, assign) native_sdk_audio_capture_callback_t callback;
@property(nonatomic, assign) void *callbackContext;
@property(nonatomic, assign) native_sdk_audio_capture_frame_callback_t frameCallback;
@property(nonatomic, assign) void *frameContext;
@property(nonatomic, assign) uint64_t frameToken;
@property(nonatomic, strong) dispatch_queue_t sampleQueue;
@property(nonatomic, strong) SCStream *screenStream;
@property(nonatomic, strong) AVCaptureSession *microphoneSession;
@property(nonatomic, strong) AVCaptureAudioDataOutput *microphoneOutput;
@property(nonatomic, strong) NSString *selectedMicrophoneID;
@property(nonatomic, assign) uint32_t sampleRate;
@property(nonatomic, assign) uint8_t channelCount;
@property(nonatomic, assign) BOOL systemAudio;
@property(nonatomic, assign) BOOL microphoneAudio;
@property(nonatomic, assign) BOOL active;
@property(nonatomic, assign) BOOL terminalEmitted;
@property(nonatomic, assign) BOOL observingDevices;
@property(nonatomic, assign) BOOL hasBasePTS;
@property(nonatomic, assign) CMTime basePTS;
@property(nonatomic, assign) uint64_t systemWatermark;
@property(nonatomic, assign) uint64_t microphoneWatermark;
@property(nonatomic, assign) uint64_t nextEmitFrame;
@property(nonatomic, assign) uint64_t acceptedBlocks;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NativeSdkAudioBlock *> *blocks;
@property(nonatomic, strong) id connectedObserver;
@property(nonatomic, strong) id disconnectedObserver;
@property(nonatomic, strong) dispatch_semaphore_t finalizationSemaphore;
- (int)startSystemAudio:(BOOL)systemAudio microphoneKind:(int)microphoneKind microphoneID:(NSString *)microphoneID sampleRate:(uint32_t)sampleRate channels:(uint8_t)channels excludeCurrentProcessAudio:(BOOL)exclude frameCallback:(native_sdk_audio_capture_frame_callback_t)frameCallback frameContext:(void *)frameContext frameToken:(uint64_t)frameToken;
- (int)drainReadyBlocks:(BOOL)final;
- (void)stopCapture;
- (void)finishWithState:(int)state reason:(int)reason;
@end

static NSArray<AVCaptureDevice *> *NativeSdkMicrophones(void) API_AVAILABLE(macos(15.0));
static NSArray<AVCaptureDevice *> *NativeSdkMicrophones(void) {
    AVCaptureDeviceDiscoverySession *session = [AVCaptureDeviceDiscoverySession
        discoverySessionWithDeviceTypes:@[ AVCaptureDeviceTypeMicrophone ]
        mediaType:AVMediaTypeAudio position:AVCaptureDevicePositionUnspecified];
    return session.devices;
}

static AVCaptureDevice *NativeSdkMicrophone(NSString *identifier, BOOL useDefault) API_AVAILABLE(macos(15.0));
static AVCaptureDevice *NativeSdkMicrophone(NSString *identifier, BOOL useDefault) {
    if (useDefault) return [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
    for (AVCaptureDevice *device in NativeSdkMicrophones()) {
        if ([device.uniqueID isEqualToString:identifier]) return device;
    }
    return nil;
}

@implementation NativeSdkAudioCapture

- (instancetype)initWithCallback:(native_sdk_audio_capture_callback_t)callback context:(void *)context {
    self = [super init];
    if (!self) return nil;
    _callback = callback;
    _callbackContext = context;
    _sampleQueue = dispatch_queue_create("dev.native-sdk.audio-capture", DISPATCH_QUEUE_SERIAL);
    _blocks = [NSMutableDictionary dictionary];
    return self;
}

- (void)dealloc {
    [self stopDeviceObservers];
    if (_screenStream) [_screenStream stopCaptureWithCompletionHandler:nil];
    if (_microphoneSession.running) [_microphoneSession stopRunning];
}

- (void)emit:(native_sdk_audio_capture_event_t)event {
    if ([NSThread isMainThread]) {
        native_sdk_audio_capture_callback_t callback = self.callback;
        if (callback) callback(self.callbackContext, &event);
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        native_sdk_audio_capture_callback_t callback = self.callback;
        if (callback) callback(self.callbackContext, &event);
    });
}

- (void)emitCaptureState:(int)state reason:(int)reason {
    native_sdk_audio_capture_event_t event = {
        .kind = NATIVE_SDK_AUDIO_CAPTURE_EVENT_CAPTURE,
        .state = state,
        .reason = reason,
        .sample_rate_hz = self.sampleRate,
        .channel_count = self.channelCount,
    };
    [self emit:event];
}

- (void)startDeviceObservers {
    if (self.connectedObserver || self.disconnectedObserver) return;
    __weak NativeSdkAudioCapture *weakSelf = self;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    self.connectedObserver = [center addObserverForName:AVCaptureDeviceWasConnectedNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        (void)note;
        NativeSdkAudioCapture *strongSelf = weakSelf;
        if (!strongSelf) return;
        native_sdk_audio_capture_event_t event = { .kind = NATIVE_SDK_AUDIO_CAPTURE_EVENT_DEVICES_CHANGED };
        [strongSelf emit:event];
    }];
    self.disconnectedObserver = [center addObserverForName:AVCaptureDeviceWasDisconnectedNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        NativeSdkAudioCapture *strongSelf = weakSelf;
        if (!strongSelf) return;
        AVCaptureDevice *device = note.object;
        if (strongSelf.active && strongSelf.selectedMicrophoneID.length > 0 && [device.uniqueID isEqualToString:strongSelf.selectedMicrophoneID]) {
            [strongSelf finishWithState:NS_CAPTURE_FAILED reason:NS_REASON_DEVICE_DISCONNECTED];
        }
        native_sdk_audio_capture_event_t event = { .kind = NATIVE_SDK_AUDIO_CAPTURE_EVENT_DEVICES_CHANGED };
        [strongSelf emit:event];
    }];
}

- (void)stopDeviceObservers {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    if (self.connectedObserver) [center removeObserver:self.connectedObserver];
    if (self.disconnectedObserver) [center removeObserver:self.disconnectedObserver];
    self.connectedObserver = nil;
    self.disconnectedObserver = nil;
}

- (NSUInteger)blockFrames { return (NSUInteger)self.sampleRate * 20 / 1000; }
- (NSUInteger)bytesPerFrame { return (NSUInteger)self.channelCount * sizeof(int16_t); }

- (NativeSdkAudioBlock *)blockAtIndex:(uint64_t)index create:(BOOL)create {
    NSNumber *key = @(index);
    NativeSdkAudioBlock *block = self.blocks[key];
    if (!block && create) {
        block = [[NativeSdkAudioBlock alloc] initWithByteCount:self.blockFrames * self.bytesPerFrame];
        self.blocks[key] = block;
    }
    return block;
}

- (void)storePCM:(const uint8_t *)bytes frames:(NSUInteger)frames atFrame:(uint64_t)startFrame microphone:(BOOL)microphone {
    /* A source may deliver a late buffer after the paired interval was
       already published with a zero-filled gap. Never recreate those old
       blocks: paired offsets are monotonic and published frames are final. */
    if (startFrame + frames <= self.nextEmitFrame) return;
    if (startFrame < self.nextEmitFrame) {
        NSUInteger skip = (NSUInteger)(self.nextEmitFrame - startFrame);
        bytes += skip * self.bytesPerFrame;
        frames -= skip;
        startFrame = self.nextEmitFrame;
    }
    NSUInteger consumed = 0;
    const NSUInteger blockFrames = self.blockFrames;
    const NSUInteger bytesPerFrame = self.bytesPerFrame;
    while (consumed < frames) {
        uint64_t absoluteFrame = startFrame + consumed;
        uint64_t blockIndex = absoluteFrame / blockFrames;
        NSUInteger inBlock = (NSUInteger)(absoluteFrame % blockFrames);
        NSUInteger take = MIN(frames - consumed, blockFrames - inBlock);
        NativeSdkAudioBlock *block = [self blockAtIndex:blockIndex create:YES];
        NSMutableData *target = microphone ? block.microphonePCM : block.systemPCM;
        memcpy((uint8_t *)target.mutableBytes + inBlock * bytesPerFrame, bytes + consumed * bytesPerFrame, take * bytesPerFrame);
        NSMutableIndexSet *coverage = microphone ? block.microphoneFrames : block.systemFrames;
        [coverage addIndexesInRange:NSMakeRange(inBlock, take)];
        consumed += take;
    }
    uint64_t endFrame = startFrame + frames;
    if (microphone) self.microphoneWatermark = MAX(self.microphoneWatermark, endFrame);
    else self.systemWatermark = MAX(self.systemWatermark, endFrame);
    int result = [self drainReadyBlocks:NO];
    if (result == 1) [self finishWithState:NS_CAPTURE_FAILED reason:NS_REASON_CONSUMER_TOO_SLOW];
    else if (result == 2) [self finishWithState:NS_CAPTURE_FAILED reason:NS_REASON_CAPTURE_FAILED];
}

- (int)drainReadyBlocks:(BOOL)final {
    const NSUInteger blockFrames = self.blockFrames;
    const NSUInteger blockBytes = blockFrames * self.bytesPerFrame;
    /* Bound the native aligner as well as the runtime ring. If one source
       pauses while the other advances, publish the older interval with a
       counted zero-filled gap instead of accumulating blocks indefinitely. */
    const uint64_t alignmentLead = (uint64_t)blockFrames * 2;
    while (self.active || final) {
        uint64_t end = self.nextEmitFrame + blockFrames;
        BOOL ready = final
            ? end <= MAX(self.systemWatermark, self.microphoneWatermark) + blockFrames - 1
            : (!self.systemAudio || self.systemWatermark >= end || self.microphoneWatermark >= end + alignmentLead) &&
              (!self.microphoneAudio || self.microphoneWatermark >= end || self.systemWatermark >= end + alignmentLead);
        if (!ready) break;
        uint64_t blockIndex = self.nextEmitFrame / blockFrames;
        NativeSdkAudioBlock *block = [self blockAtIndex:blockIndex create:YES];
        uint32_t systemGaps = self.systemAudio ? (uint32_t)(blockFrames - block.systemFrames.count) : 0;
        uint32_t microphoneGaps = self.microphoneAudio ? (uint32_t)(blockFrames - block.microphoneFrames.count) : 0;
        int result = self.frameCallback ? self.frameCallback(
            self.frameContext, self.frameToken, self.nextEmitFrame, (uint32_t)blockFrames,
            self.systemAudio ? block.systemPCM.bytes : NULL, self.systemAudio ? blockBytes : 0,
            self.microphoneAudio ? block.microphonePCM.bytes : NULL, self.microphoneAudio ? blockBytes : 0,
            systemGaps, microphoneGaps) : 2;
        [self.blocks removeObjectForKey:@(blockIndex)];
        if (result != 0) return result;
        self.acceptedBlocks += 1;
        self.nextEmitFrame = end;
    }
    return 0;
}

- (int)startSystemAudio:(BOOL)systemAudio microphoneKind:(int)microphoneKind microphoneID:(NSString *)microphoneID sampleRate:(uint32_t)sampleRate channels:(uint8_t)channels excludeCurrentProcessAudio:(BOOL)exclude frameCallback:(native_sdk_audio_capture_frame_callback_t)frameCallback frameContext:(void *)frameContext frameToken:(uint64_t)frameToken {
    if (self.active) return 2;
    if (@available(macOS 15.0, *)) {} else { return 6; }
    if ((!systemAudio && microphoneKind == 0) || (channels != 1 && channels != 2) || !frameCallback) return 1;
    if (sampleRate != 16000 && sampleRate != 24000 && sampleRate != 44100 && sampleRate != 48000) return 1;
    if (systemAudio && !CGPreflightScreenCaptureAccess()) return 4;
    if (microphoneKind != 0 && [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] != AVAuthorizationStatusAuthorized) return 4;
    AVCaptureDevice *device = nil;
    if (microphoneKind != 0) {
        device = NativeSdkMicrophone(microphoneID, microphoneKind == 1);
        if (!device) return 5;
    }
    self.selectedMicrophoneID = device.uniqueID;
    self.sampleRate = sampleRate;
    self.channelCount = channels;
    self.systemAudio = systemAudio;
    self.microphoneAudio = microphoneKind != 0;
    self.frameCallback = frameCallback;
    self.frameContext = frameContext;
    self.frameToken = frameToken;
    self.active = YES;
    self.terminalEmitted = NO;
    self.hasBasePTS = NO;
    self.systemWatermark = 0;
    self.microphoneWatermark = 0;
    self.nextEmitFrame = 0;
    self.acceptedBlocks = 0;
    [self.blocks removeAllObjects];
    self.finalizationSemaphore = dispatch_semaphore_create(0);
    [self startDeviceObservers];

    if (systemAudio) {
        [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:YES completionHandler:^(SCShareableContent *content, NSError *error) {
            if (!self.active) return;
            if (error || content.displays.count == 0) { [self finishWithState:NS_CAPTURE_FAILED reason:NS_REASON_CAPTURE_FAILED]; return; }
            NSArray<SCRunningApplication *> *excluded = @[];
            if (exclude) {
                NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
                if (bundleID.length > 0) {
                    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(SCRunningApplication *application, NSDictionary *bindings) {
                        (void)bindings;
                        return [application.bundleIdentifier isEqualToString:bundleID];
                    }];
                    excluded = [content.applications filteredArrayUsingPredicate:predicate];
                }
            }
            SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:content.displays.firstObject excludingApplications:excluded exceptingWindows:@[]];
            SCStreamConfiguration *configuration = [SCStreamConfiguration new];
            configuration.width = 2;
            configuration.height = 2;
            configuration.minimumFrameInterval = CMTimeMake(1, 1);
            configuration.showsCursor = NO;
            configuration.capturesAudio = YES;
            configuration.sampleRate = sampleRate;
            configuration.channelCount = channels;
            configuration.excludesCurrentProcessAudio = exclude;
            if (microphoneKind != 0 && !NativeSdkConfigureScreenCaptureMicrophone(configuration, device.uniqueID)) {
                [self finishWithState:NS_CAPTURE_FAILED reason:NS_REASON_UNSUPPORTED];
                return;
            }
            SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:configuration delegate:self];
            NSError *addError = nil;
            if (![stream addStreamOutput:self type:SCStreamOutputTypeAudio sampleHandlerQueue:self.sampleQueue error:&addError] ||
                (microphoneKind != 0 && ![stream addStreamOutput:self type:NativeSdkSCStreamOutputTypeMicrophone sampleHandlerQueue:self.sampleQueue error:&addError])) {
                [self finishWithState:NS_CAPTURE_FAILED reason:NS_REASON_CAPTURE_FAILED];
                return;
            }
            self.screenStream = stream;
            [stream startCaptureWithCompletionHandler:^(NSError *startError) {
                if (startError) [self finishWithState:NS_CAPTURE_FAILED reason:NS_REASON_CAPTURE_FAILED];
                else if (self.active && !self.terminalEmitted) [self emitCaptureState:NS_CAPTURE_STARTED reason:NS_REASON_NONE];
            }];
        }];
        return 0;
    }

    dispatch_async(self.sampleQueue, ^{
        NSError *inputError = nil;
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&inputError];
        if (!input) { [self finishWithState:NS_CAPTURE_FAILED reason:NS_REASON_DEVICE_NOT_FOUND]; return; }
        AVCaptureSession *session = [AVCaptureSession new];
        AVCaptureAudioDataOutput *output = [AVCaptureAudioDataOutput new];
        [output setSampleBufferDelegate:self queue:self.sampleQueue];
        [session beginConfiguration];
        if (![session canAddInput:input] || ![session canAddOutput:output]) {
            [session commitConfiguration];
            [self finishWithState:NS_CAPTURE_FAILED reason:NS_REASON_CAPTURE_FAILED];
            return;
        }
        [session addInput:input];
        [session addOutput:output];
        [session commitConfiguration];
        self.microphoneSession = session;
        self.microphoneOutput = output;
        [session startRunning];
        if (!session.running) [self finishWithState:NS_CAPTURE_FAILED reason:NS_REASON_CAPTURE_FAILED];
        else [self emitCaptureState:NS_CAPTURE_STARTED reason:NS_REASON_NONE];
    });
    return 0;
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    (void)stream;
    (void)error;
    if (self.active && !self.terminalEmitted) [self finishWithState:NS_CAPTURE_FAILED reason:NS_REASON_CAPTURE_FAILED];
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    (void)stream;
    [self consumeSampleBuffer:sampleBuffer microphone:(type == NativeSdkSCStreamOutputTypeMicrophone)];
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    (void)output;
    (void)connection;
    [self consumeSampleBuffer:sampleBuffer microphone:YES];
}

- (void)consumeSampleBuffer:(CMSampleBufferRef)sampleBuffer microphone:(BOOL)microphone {
    if (!self.active || !CMSampleBufferDataIsReady(sampleBuffer)) return;
    CMAudioFormatDescriptionRef description = CMSampleBufferGetFormatDescription(sampleBuffer);
    const AudioStreamBasicDescription *asbd = description ? CMAudioFormatDescriptionGetStreamBasicDescription(description) : NULL;
    if (!asbd) return;
    size_t listSize = 0;
    if (CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, &listSize, NULL, 0, NULL, NULL, 0, NULL) != noErr || listSize == 0) return;
    AudioBufferList *list = malloc(listSize);
    if (!list) { [self finishWithState:NS_CAPTURE_FAILED reason:NS_REASON_CAPTURE_FAILED]; return; }
    CMBlockBufferRef block = NULL;
    if (CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, NULL, list, listSize, NULL, NULL, 0, &block) != noErr) {
        free(list);
        return;
    }
    AVAudioFormat *inputFormat = [[AVAudioFormat alloc] initWithStreamDescription:asbd];
    AVAudioPCMBuffer *input = [[AVAudioPCMBuffer alloc] initWithPCMFormat:inputFormat bufferListNoCopy:list deallocator:^(const AudioBufferList *bufferList) {
        (void)bufferList;
        if (block) CFRelease(block);
        free(list);
    }];
    if (!input) { if (block) CFRelease(block); free(list); return; }
    input.frameLength = (AVAudioFrameCount)CMSampleBufferGetNumSamples(sampleBuffer);
    AVAudioFormat *outputFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16 sampleRate:self.sampleRate channels:self.channelCount interleaved:YES];
    AVAudioConverter *converter = [[AVAudioConverter alloc] initFromFormat:inputFormat toFormat:outputFormat];
    if (!converter) return;
    AVAudioFrameCount capacity = (AVAudioFrameCount)ceil((double)input.frameLength * self.sampleRate / inputFormat.sampleRate) + 32;
    AVAudioPCMBuffer *converted = [[AVAudioPCMBuffer alloc] initWithPCMFormat:outputFormat frameCapacity:capacity];
    __block BOOL supplied = NO;
    NSError *conversionError = nil;
    AVAudioConverterOutputStatus status = [converter convertToBuffer:converted error:&conversionError withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount requested, AVAudioConverterInputStatus *inputStatus) {
        (void)requested;
        if (supplied) { *inputStatus = AVAudioConverterInputStatus_EndOfStream; return nil; }
        supplied = YES;
        *inputStatus = AVAudioConverterInputStatus_HaveData;
        return input;
    }];
    if (status == AVAudioConverterOutputStatus_Error || converted.frameLength == 0) return;
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    if (!self.hasBasePTS) { self.basePTS = pts; self.hasBasePTS = YES; }
    double offsetSeconds = CMTimeGetSeconds(CMTimeSubtract(pts, self.basePTS));
    uint64_t startFrame = isfinite(offsetSeconds) && offsetSeconds > 0 ? (uint64_t)llround(offsetSeconds * self.sampleRate) : 0;
    const AudioBufferList *convertedList = converted.audioBufferList;
    if (!convertedList || convertedList->mNumberBuffers == 0 || !convertedList->mBuffers[0].mData) return;
    [self storePCM:convertedList->mBuffers[0].mData frames:converted.frameLength atFrame:startFrame microphone:microphone];
}

- (void)stopCapture {
    if (!self.active || self.terminalEmitted) return;
    [self finishWithState:NS_CAPTURE_STOPPED reason:NS_REASON_NONE];
}

- (void)finishWithState:(int)state reason:(int)reason {
    @synchronized (self) {
        if (self.terminalEmitted) return;
        self.terminalEmitted = YES;
        self.active = NO;
    }
    dispatch_async(self.sampleQueue, ^{
        SCStream *stream = self.screenStream;
        self.screenStream = nil;
        if (stream) [stream stopCaptureWithCompletionHandler:nil];
        AVCaptureSession *session = self.microphoneSession;
        self.microphoneSession = nil;
        self.microphoneOutput = nil;
        if (session.running) [session stopRunning];
        int drainResult = [self drainReadyBlocks:YES];
        int terminalState = state;
        int terminalReason = reason;
        if (drainResult == 1) {
            terminalState = NS_CAPTURE_FAILED;
            terminalReason = NS_REASON_CONSUMER_TOO_SLOW;
        } else if (drainResult == 2 && terminalReason == NS_REASON_NONE) {
            terminalState = NS_CAPTURE_FAILED;
            terminalReason = NS_REASON_CAPTURE_FAILED;
        } else if (terminalReason == NS_REASON_NONE && self.acceptedBlocks == 0) {
            terminalState = NS_CAPTURE_FAILED;
            terminalReason = NS_REASON_NO_AUDIO;
        }
        [self emitCaptureState:terminalState reason:terminalReason];
        self.selectedMicrophoneID = nil;
        self.frameCallback = NULL;
        self.frameContext = NULL;
        [self.blocks removeAllObjects];
        if (!self.observingDevices) [self stopDeviceObservers];
        dispatch_semaphore_t semaphore = self.finalizationSemaphore;
        self.finalizationSemaphore = nil;
        if (semaphore) dispatch_semaphore_signal(semaphore);
    });
}

@end

struct native_sdk_audio_capture { void *object; };

native_sdk_audio_capture_t *native_sdk_audio_capture_create(native_sdk_audio_capture_callback_t callback, void *context) {
    native_sdk_audio_capture_t *handle = calloc(1, sizeof(*handle));
    if (!handle) return NULL;
    if (@available(macOS 15.0, *)) {
        NativeSdkAudioCapture *object = [[NativeSdkAudioCapture alloc] initWithCallback:callback context:context];
        if (!object) { free(handle); return NULL; }
        handle->object = (__bridge_retained void *)object;
        return handle;
    }
    free(handle);
    return NULL;
}

void native_sdk_audio_capture_destroy(native_sdk_audio_capture_t *capture) {
    if (!capture) return;
    if (@available(macOS 15.0, *)) {
        NativeSdkAudioCapture *object = (__bridge_transfer NativeSdkAudioCapture *)capture->object;
        object.callback = NULL;
        object.callbackContext = NULL;
        dispatch_semaphore_t semaphore = object.finalizationSemaphore;
        [object stopCapture];
        if (semaphore) (void)dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    }
    free(capture);
}

int native_sdk_audio_capture_start(native_sdk_audio_capture_t *capture, int system_audio, int microphone_kind, const char *microphone_id, size_t microphone_id_len, uint32_t sample_rate_hz, uint8_t channel_count, int exclude_current_process_audio, native_sdk_audio_capture_frame_callback_t frame_callback, void *frame_context, uint64_t frame_token) {
    if (!capture || !capture->object) return 6;
    if (@available(macOS 15.0, *)) {
        NativeSdkAudioCapture *object = (__bridge NativeSdkAudioCapture *)capture->object;
        NSString *deviceID = [[NSString alloc] initWithBytes:microphone_id length:microphone_id_len encoding:NSUTF8StringEncoding] ?: @"";
        return [object startSystemAudio:(system_audio != 0) microphoneKind:microphone_kind microphoneID:deviceID sampleRate:sample_rate_hz channels:channel_count excludeCurrentProcessAudio:(exclude_current_process_audio != 0) frameCallback:frame_callback frameContext:frame_context frameToken:frame_token];
    }
    return 6;
}

void native_sdk_audio_capture_stop(native_sdk_audio_capture_t *capture) {
    if (!capture || !capture->object) return;
    if (@available(macOS 15.0, *)) [(__bridge NativeSdkAudioCapture *)capture->object stopCapture];
}

void native_sdk_audio_capture_list_microphones(native_sdk_audio_capture_t *capture) {
    if (!capture || !capture->object) return;
    if (@available(macOS 15.0, *)) {
        NativeSdkAudioCapture *object = (__bridge NativeSdkAudioCapture *)capture->object;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSArray<AVCaptureDevice *> *devices = NativeSdkMicrophones();
            AVCaptureDevice *defaultDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
            uint32_t total = (uint32_t)MIN((NSUInteger)UINT32_MAX, devices.count);
            [devices enumerateObjectsUsingBlock:^(AVCaptureDevice *device, NSUInteger index, BOOL *stop) {
                (void)stop;
                const char *identifier = device.uniqueID.UTF8String ?: "";
                const char *name = device.localizedName.UTF8String ?: "";
                native_sdk_audio_capture_event_t event = { .kind = NATIVE_SDK_AUDIO_CAPTURE_EVENT_DEVICE, .state = NS_DEVICE,
                    .device_id = identifier, .device_id_len = strlen(identifier), .device_name = name, .device_name_len = strlen(name),
                    .device_is_default = [device.uniqueID isEqualToString:defaultDevice.uniqueID] ? 1 : 0, .device_index = (uint32_t)index, .device_total = total };
                [object emit:event];
            }];
            native_sdk_audio_capture_event_t completed = { .kind = NATIVE_SDK_AUDIO_CAPTURE_EVENT_DEVICE, .state = NS_DEVICES_COMPLETED, .device_index = total, .device_total = total };
            [object emit:completed];
        });
    }
}

void native_sdk_capture_access(native_sdk_audio_capture_t *capture, int source, int action) {
    if (!capture || !capture->object) return;
    if (@available(macOS 15.0, *)) {
        NativeSdkAudioCapture *object = (__bridge NativeSdkAudioCapture *)capture->object;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (source == 0) {
                BOOL before = CGPreflightScreenCaptureAccess();
                BOOL granted = before;
                if (action == 1 && !before) granted = CGRequestScreenCaptureAccess();
                BOOL after = CGPreflightScreenCaptureAccess();
                int status = (before || after || granted) ? NS_ACCESS_AUTHORIZED : NS_ACCESS_NOT_AUTHORIZED;
                native_sdk_audio_capture_event_t event = { .kind = NATIVE_SDK_AUDIO_CAPTURE_EVENT_ACCESS, .access_source = source,
                    .access_status = status, .restart_required = (granted && !after) ? 1 : 0 };
                [object emit:event];
                return;
            }
            AVAuthorizationStatus auth = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
            void (^emitStatus)(AVAuthorizationStatus) = ^(AVAuthorizationStatus value) {
                int status = NS_ACCESS_DENIED;
                switch (value) {
                    case AVAuthorizationStatusAuthorized: status = NS_ACCESS_AUTHORIZED; break;
                    case AVAuthorizationStatusNotDetermined: status = NS_ACCESS_NOT_DETERMINED; break;
                    case AVAuthorizationStatusRestricted: status = NS_ACCESS_RESTRICTED; break;
                    case AVAuthorizationStatusDenied: default: status = NS_ACCESS_DENIED; break;
                }
                native_sdk_audio_capture_event_t event = { .kind = NATIVE_SDK_AUDIO_CAPTURE_EVENT_ACCESS, .access_source = source, .access_status = status };
                [object emit:event];
            };
            if (action == 1 && auth == AVAuthorizationStatusNotDetermined) {
                [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
                    (void)granted;
                    emitStatus([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio]);
                }];
            } else emitStatus(auth);
        });
    }
}

void native_sdk_audio_capture_observe_microphones(native_sdk_audio_capture_t *capture, int enabled) {
    if (!capture || !capture->object) return;
    if (@available(macOS 15.0, *)) {
        NativeSdkAudioCapture *object = (__bridge NativeSdkAudioCapture *)capture->object;
        object.observingDevices = enabled != 0;
        if (enabled) [object startDeviceObservers];
        else if (!object.active) [object stopDeviceObservers];
    }
}
