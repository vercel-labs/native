// Minimal iOS presentation shim for a zero-native mobile canvas static
// library (M2: pixels on a real surface, presentation only — no touch/IME
// forwarding yet).
//
// Mirrors the macOS raster path in src/platform/macos/appkit_host.m: the
// embed host renders the retained scene through the CPU reference renderer
// (`zero_native_app_render_pixels`, RGBA8); the shim uploads those bytes to
// a shared MTLTexture and blit-copies them to the CAMetalLayer drawable.
// A CADisplayLink pumps `zero_native_app_frame` (the host synthesizes the
// gpu_surface_frame event a desktop display link would deliver) and the
// canvas revision from `zero_native_app_gpu_frame_state` gates re-renders,
// so unchanged frames cost one ABI call and no upload.
//
// The RGBA -> BGRA swizzle happens on the CPU while filling the staging
// buffer: CAMetalLayer cannot present RGBA8 drawables and blit copies
// require matching pixel formats, so a BGRA8 texture fed with swizzled
// bytes is the simplest correct path (appkit_host.m instead samples an
// RGBA8 texture from a shader; presentation-only M2 does not need one).

#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdlib.h>

#include "zero_native_app.h"

// Zig's std.debug stack-trace symbolication (pulled in by the embed lib's
// panic path) references `_dyld_get_image_header_containing_address`, which
// the iOS SDK marks __API_UNAVAILABLE(ios). Provide the documented
// replacement (dladdr) under the old symbol so the static lib links; it
// only runs while formatting a panic trace.
const struct mach_header *_dyld_get_image_header_containing_address(const void *address) {
    Dl_info info;
    if (dladdr(address, &info) != 0 && info.dli_fbase != NULL) {
        return (const struct mach_header *)info.dli_fbase;
    }
    return NULL;
}

@interface ZeroNativeCanvasView : UIView
@end

@implementation ZeroNativeCanvasView
+ (Class)layerClass {
    return [CAMetalLayer class];
}
@end

@interface ZeroNativeCanvasViewController : UIViewController
@property(nonatomic) void *nativeApp;
@property(nonatomic, strong) id<MTLDevice> device;
@property(nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property(nonatomic, strong) id<MTLTexture> canvasTexture;
@property(nonatomic, strong) CADisplayLink *displayLink;
@property(nonatomic) uint8_t *rgbaBytes;
@property(nonatomic) uint8_t *bgraBytes;
@property(nonatomic) size_t stagingCapacity;
@property(nonatomic) uint64_t lastCanvasRevision;
@property(nonatomic) BOOL hasPresentedRevision;
@property(nonatomic) BOOL needsPresent;
@property(nonatomic) CGFloat viewportScale;
@end

@implementation ZeroNativeCanvasViewController

- (CAMetalLayer *)metalLayer {
    return (CAMetalLayer *)self.view.layer;
}

- (void)loadView {
    self.view = [[ZeroNativeCanvasView alloc] init];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.device = MTLCreateSystemDefaultDevice();
    self.commandQueue = [self.device newCommandQueue];
    self.viewportScale = 1;

    CAMetalLayer *layer = [self metalLayer];
    layer.device = self.device;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    // Blit destination: the drawable texture must stay CPU/blit-accessible.
    layer.framebufferOnly = NO;
    layer.opaque = YES;
    self.view.backgroundColor = [UIColor whiteColor];

    self.nativeApp = zero_native_app_create();
    if (!self.nativeApp) {
        NSLog(@"zero-native: zero_native_app_create failed");
        return;
    }
    zero_native_app_start(self.nativeApp);
    zero_native_app_activate(self.nativeApp);
    [self logNativeErrorIfAny:@"start"];

    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayLinkTick:)];
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)dealloc {
    [self.displayLink invalidate];
    if (self.nativeApp) {
        zero_native_app_stop(self.nativeApp);
        zero_native_app_destroy(self.nativeApp);
    }
    free(self.rgbaBytes);
    free(self.bgraBytes);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self pushViewport];
}

- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    [self pushViewport];
}

// Report the view's size in points + contentScale + safe-area insets to the
// embed host (keyboard insets stay zero: IME is M3).
- (void)pushViewport {
    if (!self.nativeApp) return;
    CGSize size = self.view.bounds.size;
    if (size.width <= 0 || size.height <= 0) return;
    UIScreen *screen = self.view.window.screen ?: UIScreen.mainScreen;
    CGFloat scale = screen.scale > 0 ? screen.scale : 1;
    self.viewportScale = scale;
    [self metalLayer].contentsScale = scale;
    UIEdgeInsets safe = self.view.safeAreaInsets;
    zero_native_app_viewport(self.nativeApp,
                             (float)size.width, (float)size.height, (float)scale,
                             (__bridge void *)[self metalLayer],
                             (float)safe.top, (float)safe.right, (float)safe.bottom, (float)safe.left,
                             0, 0, 0, 0);
    [self logNativeErrorIfAny:@"viewport"];
    self.needsPresent = YES;
}

- (void)displayLinkTick:(CADisplayLink *)link {
    if (!self.nativeApp) return;

    // Host-pumped frame: synthesizes the gpu_surface_frame event (first
    // tick installs the widget tree, later ticks re-present).
    zero_native_app_frame(self.nativeApp);

    // Only re-render + blit when the retained canvas actually changed.
    zero_native_gpu_frame_state_t state = {0};
    BOOL haveState = zero_native_app_gpu_frame_state(self.nativeApp, &state) == 1;
    if (!self.needsPresent && haveState && self.hasPresentedRevision &&
        state.canvas_revision == self.lastCanvasRevision) {
        return;
    }

    if ([self renderAndPresent]) {
        if (haveState) {
            self.lastCanvasRevision = state.canvas_revision;
            self.hasPresentedRevision = YES;
        }
        self.needsPresent = NO;
    }
}

- (BOOL)ensureStagingCapacity:(size_t)byteLength {
    if (self.stagingCapacity >= byteLength && self.rgbaBytes && self.bgraBytes) return YES;
    free(self.rgbaBytes);
    free(self.bgraBytes);
    self.rgbaBytes = malloc(byteLength);
    self.bgraBytes = malloc(byteLength);
    self.stagingCapacity = (self.rgbaBytes && self.bgraBytes) ? byteLength : 0;
    return self.stagingCapacity != 0;
}

- (BOOL)renderAndPresent {
    float scale = (float)self.viewportScale;

    zero_native_canvas_pixels_t info = {0};
    if (zero_native_app_render_pixel_size(self.nativeApp, scale, &info) != 1) return NO;
    if (info.width == 0 || info.height == 0 || info.byte_len != info.width * info.height * 4) return NO;
    if (![self ensureStagingCapacity:info.byte_len]) return NO;

    zero_native_canvas_pixels_t rendered = {0};
    if (zero_native_app_render_pixels(self.nativeApp, scale, self.rgbaBytes, info.byte_len, &rendered) != 1) {
        [self logNativeErrorIfAny:@"render_pixels"];
        return NO;
    }
    NSUInteger width = rendered.width;
    NSUInteger height = rendered.height;
    if (width == 0 || height == 0 || rendered.byte_len != width * height * 4) return NO;

    // RGBA8 (renderer) -> BGRA8 (drawable) swizzle into the upload buffer.
    const uint8_t *rgba = self.rgbaBytes;
    uint8_t *bgra = self.bgraBytes;
    size_t pixelCount = (size_t)width * (size_t)height;
    for (size_t i = 0; i < pixelCount; i++) {
        const size_t offset = i * 4;
        bgra[offset + 0] = rgba[offset + 2];
        bgra[offset + 1] = rgba[offset + 1];
        bgra[offset + 2] = rgba[offset + 0];
        bgra[offset + 3] = rgba[offset + 3];
    }

    if (!self.canvasTexture || self.canvasTexture.width != width || self.canvasTexture.height != height) {
        MTLTextureDescriptor *descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                               width:width
                                                              height:height
                                                           mipmapped:NO];
        descriptor.usage = MTLTextureUsageShaderRead;
        descriptor.storageMode = MTLStorageModeShared;
        self.canvasTexture = [self.device newTextureWithDescriptor:descriptor];
    }
    if (!self.canvasTexture) return NO;
    [self.canvasTexture replaceRegion:MTLRegionMake2D(0, 0, width, height)
                          mipmapLevel:0
                            withBytes:bgra
                          bytesPerRow:width * 4];

    CAMetalLayer *layer = [self metalLayer];
    layer.drawableSize = CGSizeMake(width, height);
    id<CAMetalDrawable> drawable = [layer nextDrawable];
    if (!drawable) return NO;
    if (drawable.texture.width != width || drawable.texture.height != height) return NO;

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    [blit copyFromTexture:self.canvasTexture
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(width, height, 1)
                toTexture:drawable.texture
         destinationSlice:0
         destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
    return YES;
}

- (void)logNativeErrorIfAny:(NSString *)stage {
    const char *name = zero_native_app_last_error_name(self.nativeApp);
    if (name && name[0] != '\0') {
        NSLog(@"zero-native: %@ error %s", stage, name);
    }
}

@end

@interface ZeroNativeAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation ZeroNativeAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[ZeroNativeCanvasViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([ZeroNativeAppDelegate class]));
    }
}
