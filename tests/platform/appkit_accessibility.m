#import <AppKit/AppKit.h>
#import "../../src/platform/macos/appkit_host.h"

// The isolated host links no updater engine. Unexpected updater use must fail
// rather than supply a verification verdict; shipping apps link the real ABI.
native_sdk_update_verify_result_t native_sdk_update_verify_feed(
    const char *envelope, size_t envelope_len, const char *public_key, size_t public_key_len,
    const char *bundle_id, size_t bundle_id_len, const char *current_version, size_t current_version_len,
    const char *target, size_t target_len, char *version_out, size_t version_capacity,
    char *archive_url_out, size_t archive_url_capacity, char *release_notes_out, size_t release_notes_capacity) {
    abort();
}
int native_sdk_update_verify_archive(const char *path, size_t path_len, uint64_t expected_bytes, const char *sha256, size_t sha256_len) {
    abort();
}

// Exercise the production classes, including OS-owned property storage. Linking
// appkit_host.m keeps this regression independent of copied host logic.
@interface NativeSdkWidgetAccessibilityElement : NSAccessibilityElement
@property(nonatomic, weak) NSView *surfaceView;
@property(nonatomic, assign) uint64_t widgetId;
@property(nonatomic, assign) uint32_t actionFlags;
@property(nonatomic, assign) BOOL canUndo;
@property(nonatomic, assign) BOOL canRedo;
@property(nonatomic, assign) NSRect surfaceFrame;
@end
@interface NativeSdkMetalSurfaceView : NSView
@property(nonatomic, strong) NSArray<NativeSdkWidgetAccessibilityElement *> *widgetAccessibilityElements;
@property(nonatomic, strong) NSArray<NativeSdkWidgetAccessibilityElement *> *widgetAccessibilityRootElements;
- (void)updateWidgetAccessibilityWithNodes:(const native_sdk_appkit_widget_accessibility_node_t *)nodes count:(NSUInteger)count;
- (void)stopDisplayTimer;
@end

static void expect(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "%s\n", message.UTF8String); exit(1); }
}
static NSMutableArray<NSString *> *notifications;
// Observe production notification choices without requiring a subscribed reader.
void NSAccessibilityPostNotification(id element, NSAccessibilityNotificationName notification) {
    (void)element;
    [notifications addObject:notification];
}
static id present(id value) { return value ?: [NSNull null]; }
static NSDictionary *content(NativeSdkWidgetAccessibilityElement *e) {
    id parent = e.accessibilityParent;
    NSMutableArray *children = [NSMutableArray array];
    for (NativeSdkWidgetAccessibilityElement *child in e.accessibilityChildren) [children addObject:@(child.widgetId)];
    return @{
        @"id": @(e.widgetId), @"parent": [parent isKindOfClass:[NativeSdkWidgetAccessibilityElement class]] ? @([(NativeSdkWidgetAccessibilityElement *)parent widgetId]) : @"surface",
        @"children": children, @"role": present(e.accessibilityRole), @"identifier": present(e.accessibilityIdentifier),
        @"label": present(e.accessibilityLabel), @"value": present(e.accessibilityValue), @"description": present(e.accessibilityValueDescription),
        @"placeholder": present(e.accessibilityPlaceholderValue), @"min": present(e.accessibilityMinValue), @"max": present(e.accessibilityMaxValue),
        @"rows": @(e.accessibilityRowCount), @"columns": @(e.accessibilityColumnCount), @"rowRange": [NSValue valueWithRange:e.accessibilityRowIndexRange], @"columnRange": [NSValue valueWithRange:e.accessibilityColumnIndexRange], @"index": @(e.accessibilityIndex),
        @"characters": @(e.accessibilityNumberOfCharacters), @"visible": [NSValue valueWithRange:e.accessibilityVisibleCharacterRange], @"selection": [NSValue valueWithRange:e.accessibilitySelectedTextRange], @"selections": present(e.accessibilitySelectedTextRanges), @"selectedText": present(e.accessibilitySelectedText), @"line": @(e.accessibilityInsertionPointLineNumber),
        @"enabled": @(e.accessibilityEnabled), @"focused": @(e.accessibilityFocused), @"selected": @(e.accessibilitySelected), @"expanded": @(e.accessibilityExpanded), @"required": @(e.accessibilityRequired),
        @"undo": @(e.canUndo), @"redo": @(e.canRedo), @"actions": @(e.actionFlags), @"actionNames": present([e accessibilityActionNames]),
        @"pressAllowed": @([e isAccessibilitySelectorAllowed:@selector(accessibilityPerformPress)]), @"incrementAllowed": @([e isAccessibilitySelectorAllowed:@selector(accessibilityPerformIncrement)]), @"decrementAllowed": @([e isAccessibilitySelectorAllowed:@selector(accessibilityPerformDecrement)]), @"cancelAllowed": @([e isAccessibilitySelectorAllowed:@selector(accessibilityPerformCancel)]),
        @"frame": [NSValue valueWithRect:e.surfaceFrame], @"frameInParent": [NSValue valueWithRect:e.accessibilityFrameInParentSpace]
    };
}
static NativeSdkMetalSurfaceView *surface(void) {
    NativeSdkMetalSurfaceView *view = [[NativeSdkMetalSurfaceView alloc] initWithFrame:NSMakeRect(0, 0, 320, 200)];
    // Offscreen publication has no display clock. Match host teardown by
    // retiring the timer's intentional ownership before testing AX lifetime.
    [view stopDisplayTimer];
    return view;
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        notifications = [NSMutableArray array];
        NativeSdkMetalSurfaceView *view = surface();
        native_sdk_appkit_widget_accessibility_node_t nodes[3] = {0};
        nodes[0].id = UINT64_MAX; nodes[0].role = NATIVE_SDK_APPKIT_WIDGET_ROLE_GROUP;
        nodes[1].id = UINT64_C(9007199254740993); nodes[1].parent_id = UINT64_MAX;
        nodes[1].role = NATIVE_SDK_APPKIT_WIDGET_ROLE_TEXTBOX;
        nodes[1].label = "Editor"; nodes[1].label_len = 6;
        nodes[1].text_value = "a\xc3\xa9z"; nodes[1].text_value_len = 4;
        nodes[1].placeholder = "Hint"; nodes[1].placeholder_len = 4;
        nodes[1].has_text_selection = 1; nodes[1].text_selection_start = 1; nodes[1].text_selection_end = 3;
        nodes[1].has_grid_row_index = nodes[1].has_grid_column_index = nodes[1].has_grid_row_count = nodes[1].has_grid_column_count = 1;
        nodes[1].grid_row_index = 3; nodes[1].grid_column_index = 2; nodes[1].grid_row_count = 8; nodes[1].grid_column_count = 4;
        nodes[1].has_list_item_index = nodes[1].has_list_item_count = 1; nodes[1].list_item_index = 4; nodes[1].list_item_count = 11;
        nodes[1].has_scroll_offset = nodes[1].has_scroll_viewport_extent = nodes[1].has_scroll_content_extent = 1;
        nodes[1].scroll_offset = 7; nodes[1].scroll_viewport_extent = 10; nodes[1].scroll_content_extent = 100;
        nodes[1].state_flags = NATIVE_SDK_APPKIT_WIDGET_STATE_ENABLED | NATIVE_SDK_APPKIT_WIDGET_STATE_FOCUSED | NATIVE_SDK_APPKIT_WIDGET_STATE_CAN_UNDO | NATIVE_SDK_APPKIT_WIDGET_STATE_CAN_REDO;
        nodes[1].action_flags = NATIVE_SDK_APPKIT_WIDGET_ACTION_SET_TEXT | NATIVE_SDK_APPKIT_WIDGET_ACTION_SET_SELECTION;
        nodes[2].id = 3; nodes[2].parent_id = UINT64_MAX; nodes[2].role = NATIVE_SDK_APPKIT_WIDGET_ROLE_BUTTON;
        nodes[2].state_flags = NATIVE_SDK_APPKIT_WIDGET_STATE_ENABLED; nodes[2].action_flags = NATIVE_SDK_APPKIT_WIDGET_ACTION_PRESS;
        [view updateWidgetAccessibilityWithNodes:nodes count:3];
        NativeSdkWidgetAccessibilityElement *editor = view.widgetAccessibilityElements[1], *button = view.widgetAccessibilityElements[2];
        for (NSUInteger i = 0; i < 1000; i++) {
            @autoreleasepool {
                nodes[2].has_value = 1; nodes[2].value = i;
                [notifications removeAllObjects];
                [view updateWidgetAccessibilityWithNodes:nodes count:3];
                expect(view.widgetAccessibilityElements[1] == editor && view.widgetAccessibilityElements[2] == button, @"OS element identity changed during value updates");
                expect([notifications isEqual:@[NSAccessibilityValueChangedNotification]], @"Value update unnecessarily invalidated the accessibility graph");
                NativeSdkMetalSurfaceView *fresh = surface();
                [fresh updateWidgetAccessibilityWithNodes:nodes count:3];
                for (NSUInteger j = 0; j < 3; j++) expect([content(view.widgetAccessibilityElements[j]) isEqual:content(fresh.widgetAccessibilityElements[j])], @"Retained OS fields differ from fresh publication");
            }
        }
        // The same identity becomes a plain label: all optional OS fields reset.
        uint64_t editorId = nodes[1].id;
        nodes[1] = (native_sdk_appkit_widget_accessibility_node_t){ .id = editorId, .role = NATIVE_SDK_APPKIT_WIDGET_ROLE_TEXT, .state_flags = NATIVE_SDK_APPKIT_WIDGET_STATE_ENABLED };
        [view updateWidgetAccessibilityWithNodes:nodes count:3];
        expect(view.widgetAccessibilityElements[1] == editor, @"Role update replaced identity");
        NativeSdkMetalSurfaceView *fresh = surface();
        [fresh updateWidgetAccessibilityWithNodes:nodes count:3];
        expect([content(editor) isEqual:content(fresh.widgetAccessibilityElements[1])], @"Stale editor fields survived role change");
        // Reordering/reparenting keeps identities and removes old child links.
        native_sdk_appkit_widget_accessibility_node_t reordered[3] = { nodes[2], nodes[1], nodes[0] };
        reordered[0].parent_id = editorId;
        [view updateWidgetAccessibilityWithNodes:reordered count:3];
        expect(view.widgetAccessibilityElements[0] == button && view.widgetAccessibilityElements[1] == editor, @"Reordering replaced identities");
        expect(button.accessibilityParent == editor && editor.accessibilityChildren.count == 1, @"Reparenting retained stale links");
        [view updateWidgetAccessibilityWithNodes:reordered + 1 count:2];
        expect(button.surfaceView == nil && button.actionFlags == 0 && !button.accessibilityEnabled && !button.accessibilityFocused, @"Retired OS control remains active");
        expect(button.accessibilityParent == nil && button.accessibilityChildren.count == 0 && ![button accessibilityPerformPress], @"Detached control still routes actions");
        native_sdk_appkit_widget_accessibility_node_t duplicate[2] = { nodes[1], nodes[1] };
        [view updateWidgetAccessibilityWithNodes:duplicate count:2];
        expect(view.widgetAccessibilityElements[0] != view.widgetAccessibilityElements[1], @"Duplicate identities alias an OS element");
        native_sdk_appkit_widget_accessibility_node_t duplicateParents[3] = { nodes[0], nodes[0], nodes[2] };
        [view updateWidgetAccessibilityWithNodes:duplicateParents count:3];
        expect(view.widgetAccessibilityElements[2].accessibilityParent == view.widgetAccessibilityElements[1], @"Duplicate parent resolution changed the last matching ID");
        expect(view.widgetAccessibilityElements[0].accessibilityChildren.count == 0 && view.widgetAccessibilityElements[1].accessibilityChildren.count == 1, @"Duplicate parents both own the same child");
        duplicate[0].id = duplicate[1].id = 0;
        [view updateWidgetAccessibilityWithNodes:duplicate count:2];
        NativeSdkWidgetAccessibilityElement *anonymous = view.widgetAccessibilityElements[0];
        expect(anonymous != view.widgetAccessibilityElements[1], @"Anonymous controls alias each other");
        [view updateWidgetAccessibilityWithNodes:duplicate count:2];
        expect(anonymous != view.widgetAccessibilityElements[0] && anonymous.surfaceView == nil, @"Anonymous identity was retained as a stable key");
        [view updateWidgetAccessibilityWithNodes:NULL count:0];
        expect(view.widgetAccessibilityElements.count == 0 && view.widgetAccessibilityRootElements.count == 0, @"Empty publication retained elements");
        __weak NSView *releasedSurface;
        NativeSdkWidgetAccessibilityElement *retainedElement;
        @autoreleasepool {
            NativeSdkMetalSurfaceView *owned = surface();
            [owned updateWidgetAccessibilityWithNodes:nodes count:3];
            retainedElement = owned.widgetAccessibilityElements[0];
            releasedSurface = owned;
            [owned updateWidgetAccessibilityWithNodes:NULL count:0];
        }
        expect(releasedSurface == nil && retainedElement.surfaceView == nil, @"OS element retained a destroyed surface");
        @autoreleasepool {
            NativeSdkMetalSurfaceView *owned = surface();
            [owned updateWidgetAccessibilityWithNodes:nodes count:3];
            retainedElement = owned.widgetAccessibilityElements[2];
            releasedSurface = owned;
        }
        expect(releasedSurface == nil && retainedElement.surfaceView == nil && retainedElement.accessibilityActionNames.count == 0 && ![retainedElement accessibilityPerformPress], @"OS control retained a surface or actions without explicit clearing");
        puts("AppKit accessibility: 1000 stable updates, complete fields, role reset, reparenting, retirement and lifetime passed");
    }
    return 0;
}
