/* Exercise the production AppKit Enter path: modifier intent must survive
 * Cocoa text interpretation while IME Return still commits marked text. */
#import "appkit_host.m"
#include <assert.h>

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

@interface NativeSdkTextHostProbe : NativeSdkAppKitHost
@property(nonatomic, assign) NSUInteger inputs;
@property(nonatomic, assign) native_sdk_appkit_event_t lastInput;
@end
@implementation NativeSdkTextHostProbe
- (void)emitEvent:(native_sdk_appkit_event_t)event {
    if (event.kind == NATIVE_SDK_APPKIT_EVENT_GPU_SURFACE_INPUT) {
        self.inputs += 1;
        self.lastInput = event;
    }
}
@end

@interface NativeSdkTextProbe : NativeSdkMetalSurfaceView
@property(nonatomic, strong) NativeSdkWidgetAccessibilityElement *editor;
@property(nonatomic, assign) BOOL marked;
@property(nonatomic, assign) NSUInteger interpretations;
@end
@implementation NativeSdkTextProbe
- (void)requestRetainedCanvasFrame {}
- (NativeSdkWidgetAccessibilityElement *)focusedTextAccessibilityElement { return self.editor; }
- (BOOL)hasMarkedText { return self.marked; }
- (void)interpretKeyEvents:(NSArray<NSEvent *> *)events {
    self.interpretations += 1;
    // Cocoa can map Shift+Return onto the modifier-less newline selector.
    [self doCommandBySelector:@selector(insertNewline:)];
}
@end

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NativeSdkTextHostProbe *host = [NativeSdkTextHostProbe new];
        NativeSdkTextProbe *probe = [[NativeSdkTextProbe alloc] initWithFrame:NSMakeRect(0, 0, 600, 600)];
        probe.host = host; probe.surfaceLabel = @"canvas";
        probe.editor = [NativeSdkWidgetAccessibilityElement new];
        const NSEventModifierFlags flags[] = { NSEventModifierFlagShift, 0,
            NSEventModifierFlagCommand, NSEventModifierFlagOption, NSEventModifierFlagControl,
            NSEventModifierFlagShift | NSEventModifierFlagCommand };
        for (NSUInteger i = 0; i < sizeof(flags) / sizeof(flags[0]); i++) {
            NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
                modifierFlags:flags[i] timestamp:0 windowNumber:0 context:nil
                characters:@"\r" charactersIgnoringModifiers:@"\r" isARepeat:NO keyCode:36];
            [probe keyDown:event];
            assert(host.inputs == i + 1);
            assert(host.lastInput.input_kind == NATIVE_SDK_APPKIT_GPU_INPUT_KEY_DOWN);
            assert(host.lastInput.key_text_len == 5 && memcmp(host.lastInput.key_text, "enter", 5) == 0);
            assert(host.lastInput.shortcut_modifiers == NativeSdkModifierFlagsForEvent(event));
            assert(probe.interpretations == 0);
        }
        probe.marked = YES;
        NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
            modifierFlags:NSEventModifierFlagShift timestamp:0 windowNumber:0 context:nil
            characters:@"\r" charactersIgnoringModifiers:@"\r" isARepeat:NO keyCode:36];
        [probe keyDown:event];
        assert(probe.interpretations == 1);
        assert(host.inputs == sizeof(flags) / sizeof(flags[0]) + 1);
    }
    return 0;
}
