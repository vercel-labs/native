/* Exercise the production accessibility element without opening a window.
 * Internal publication updates its snapshot; only assistive focus writes
 * may enqueue a runtime focus action. */
#import "appkit_host.m"
#include <assert.h>

/* These unrelated host services are implemented by Zig in apps. The
 * windowless probe must never reach them. */
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

@interface NativeSdkFocusProbe : NSObject
@property(nonatomic, assign) NSUInteger actions;
@property(nonatomic, assign) uint64_t widgetId;
@property(nonatomic, assign) NSInteger action;
- (BOOL)emitWidgetAccessibilityActionWithId:(uint64_t)widgetId action:(NSInteger)action;
@end
@implementation NativeSdkFocusProbe
- (BOOL)emitWidgetAccessibilityActionWithId:(uint64_t)widgetId action:(NSInteger)action {
    self.actions += 1;
    self.widgetId = widgetId;
    self.action = action;
    return YES;
}
@end

int main(void) {
    @autoreleasepool {
        NativeSdkFocusProbe *probe = [NativeSdkFocusProbe new];
        NativeSdkWidgetAccessibilityElement *element = [NativeSdkWidgetAccessibilityElement new];
        element.surfaceView = (NativeSdkMetalSurfaceView *)(id)probe;
        element.widgetId = 42;
        element.actionFlags = NATIVE_SDK_APPKIT_WIDGET_ACTION_FOCUS;
        element.accessibilityEnabled = YES;
        [element publishAccessibilityFocused:YES];
        assert(element.accessibilityFocused && probe.actions == 0);
        [element publishAccessibilityFocused:YES];
        [element publishAccessibilityFocused:NO];
        assert(!element.accessibilityFocused && probe.actions == 0);
        element.accessibilityFocused = YES;
        assert(probe.actions == 1 && probe.widgetId == 42);
        assert(probe.action == NATIVE_SDK_APPKIT_WIDGET_ACCESSIBILITY_ACTION_FOCUS);
        element.accessibilityFocused = NO;
        assert(probe.actions == 1);
        element.accessibilityEnabled = NO;
        element.accessibilityFocused = YES;
        assert(probe.actions == 1);
        element.accessibilityEnabled = YES;
        element.actionFlags = 0;
        element.accessibilityFocused = YES;
        assert(probe.actions == 1);
    }
    return 0;
}
