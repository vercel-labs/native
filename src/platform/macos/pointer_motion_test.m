/* Exercise production AppKit coalescing and pointer emission without a window.
 * Absolute drag samples must retain lossless y-down geometry deltas. */
#import "appkit_host.m"
#include <assert.h>

/* These unrelated host services are implemented by Zig in apps. */
native_sdk_update_verify_result_t native_sdk_update_verify_feed(
    const char *envelope, size_t envelope_len,
    const char *public_key, size_t public_key_len,
    const char *bundle_id, size_t bundle_id_len,
    const char *current_version, size_t current_version_len,
    const char *target, size_t target_len,
    char *version_out, size_t version_capacity,
    char *archive_url_out, size_t archive_url_capacity,
    char *release_notes_out, size_t release_notes_capacity) {
    abort();
}
int native_sdk_update_verify_archive(const char *path, size_t path_len, uint64_t expected_bytes, const char *sha256, size_t sha256_len) {
    abort();
}

@interface NativeSdkPointerHostProbe : NativeSdkAppKitHost
@property(nonatomic, assign) NSUInteger inputs;
@property(nonatomic, assign) native_sdk_appkit_event_t lastInput;
@end
@implementation NativeSdkPointerHostProbe
- (void)emitEvent:(native_sdk_appkit_event_t)event {
    if (event.kind == NATIVE_SDK_APPKIT_EVENT_GPU_SURFACE_INPUT) {
        self.inputs += 1;
        self.lastInput = event;
    }
}
@end

@interface NativeSdkPointerProbe : NativeSdkMetalSurfaceView
@end
@implementation NativeSdkPointerProbe
- (void)requestRetainedCanvasFrame {}
@end

static NSPoint rawPoint(NativeSdkPointerProbe *probe, double x, double y) {
    return NSMakePoint(x, probe.isFlipped ? y : probe.bounds.size.height - y);
}
static void emit(NativeSdkPointerProbe *probe, NSInteger kind, double x, double y, NSInteger button) {
    [probe emitInputEventWithKind:kind point:rawPoint(probe, x, y) timestampNs:1
        modifiers:0 keyText:@"" inputText:@"" button:button deltaX:0 deltaY:0];
}
static void queue(NativeSdkPointerProbe *probe, double x, double y) {
    NSEvent *event = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDragged
        location:rawPoint(probe, x, y) modifierFlags:0 timestamp:0
        windowNumber:0 context:nil eventNumber:1 clickCount:1 pressure:1];
    [probe queuePointerMotionInputEvent:event kind:NATIVE_SDK_APPKIT_GPU_INPUT_POINTER_DRAG button:0];
}
static void expect(NativeSdkPointerHostProbe *host, double x, double y, double dx, double dy) {
    const native_sdk_appkit_event_t event = host.lastInput;
    assert(event.x == x && event.y == y);
    assert(event.delta_x == dx && event.delta_y == dy);
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NativeSdkPointerHostProbe *host = [NativeSdkPointerHostProbe new];
        NativeSdkPointerProbe *probe = [[NativeSdkPointerProbe alloc] initWithFrame:NSMakeRect(0, 0, 600, 600)];
        probe.host = host;
        probe.surfaceLabel = @"canvas";
        emit(probe, NATIVE_SDK_APPKIT_GPU_INPUT_POINTER_DOWN, 120, 200, 0);
        expect(host, 120, 200, 0, 0);
        queue(probe, 130.25, 210.5);
        queue(probe, 150.5, 205.25);
        assert(host.inputs == 1);
        [probe emitQueuedPointerMotionInputEvent];
        assert(host.inputs == 2);
        expect(host, 150.5, 205.25, 30.5, 5.25);
        queue(probe, 144.25, 198);
        [probe emitQueuedPointerMotionInputEvent];
        expect(host, 144.25, 198, -6.25, -7.25);
        emit(probe, NATIVE_SDK_APPKIT_GPU_INPUT_POINTER_UP, 144.25, 198, 0);
        emit(probe, NATIVE_SDK_APPKIT_GPU_INPUT_POINTER_DRAG, 900, 900, 0);
        expect(host, 900, 900, 0, 0);
        // A new gesture resets its baseline; another button cannot advance it.
        emit(probe, NATIVE_SDK_APPKIT_GPU_INPUT_POINTER_DOWN, 30, 40, 0);
        emit(probe, NATIVE_SDK_APPKIT_GPU_INPUT_POINTER_DRAG, 100, 100, 1);
        expect(host, 100, 100, 0, 0);
        emit(probe, NATIVE_SDK_APPKIT_GPU_INPUT_POINTER_DRAG, 31, 43, 0);
        expect(host, 31, 43, 1, 3);
        emit(probe, NATIVE_SDK_APPKIT_GPU_INPUT_POINTER_CANCEL, 31, 43, 0);
        emit(probe, NATIVE_SDK_APPKIT_GPU_INPUT_POINTER_DRAG, 150, 200, 0);
        expect(host, 150, 200, 0, 0);
        // Secondary-button drags use the same point/delta convention.
        emit(probe, NATIVE_SDK_APPKIT_GPU_INPUT_POINTER_DOWN, 60, 70, 1);
        emit(probe, NATIVE_SDK_APPKIT_GPU_INPUT_POINTER_DRAG, 50, 65, 1);
        expect(host, 50, 65, -10, -5);
    }
    return 0;
}
