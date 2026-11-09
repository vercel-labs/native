/* Exercise the real host creation ABI and every system-WebView path.
 * Inspection must never be inferred from bridge access or menu presence. */
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


static void checkInspection(WKWebView *view, BOOL enabled) {
    assert(view != nil);
    if ([view.configuration.preferences respondsToSelector:NSSelectorFromString(@"setDeveloperExtrasEnabled:")]) {
        assert([[view.configuration.preferences valueForKey:@"developerExtrasEnabled"] boolValue] == enabled);
    }
    if ([view respondsToSelector:NSSelectorFromString(@"setInspectable:")]) {
        assert([[view valueForKey:@"inspectable"] boolValue] == enabled);
    }
}

static BOOL hasMenuAction(NSMenu *menu, SEL action) {
    for (NSMenuItem *item in menu.itemArray) {
        if (item.action == action || (item.submenu && hasMenuAction(item.submenu, action))) return YES;
    }
    return NO;
}

static void checkHost(BOOL enabled, BOOL declaresWebContent) {
    native_sdk_appkit_host_t *handle = native_sdk_appkit_create(
        "inspection-test", 15, "Inspection Test", 15, "", 0, "", 0,
        declaresWebContent, enabled, 1,
        "Inspection Test", 15, "dev.native_sdk.inspection_test", sizeof("dev.native_sdk.inspection_test") - 1,
        "", 0, "main", 4, 0, 0, 640, 480, 0, 0, 0, 1, 0, 0, 0);
    assert(handle);
    NativeSdkAppKitHost *host = (__bridge NativeSdkAppKitHost *)handle;
    assert(host.webViewInspection == enabled);
    // Canvas-first hosts must stay lazy, even when Debug permits inspection.
    assert(host.webView == nil && host.webViews.count == 0);
    assert(hasMenuAction(NSApp.mainMenu, @selector(toggleWebInspector:)) == (enabled && declaresWebContent));
    assert(hasMenuAction(NSApp.mainMenu, @selector(reload:)) == declaresWebContent);
    if (!enabled) {
        [host toggleWebInspector:nil];
        assert(host.webView == nil); // A denied action cannot instantiate WebKit.
    }

    // Loading a primary page is the normal WebView-first startup path.
    const char html[] = "<h1>Inspection test</h1>";
    native_sdk_appkit_load_webview(handle, html, sizeof(html) - 1, 0,
        "", 0, "", 0, "", 0, 0);
    WKWebView *main = host.webView;
    checkInspection(main, enabled);
    assert([host ensureMainWebViewForWindowId:1] == main);
    assert(main.configuration.userContentController.userScripts.count == 1);

    assert([host createWindowWithId:2 title:@"Secondary" label:@"secondary"
        x:0 y:0 width:400 height:300 restoreFrame:NO initialPlacement:0
        restorePolicy:0 resizable:YES titlebarStyle:0 showPolicy:0 windowFlags:0 makeMain:NO]);
    assert(host.webViews[@2] == nil);
    WKWebView *secondary = [host ensureMainWebViewForWindowId:2];
    checkInspection(secondary, enabled);
    assert([host ensureMainWebViewForWindowId:2] == secondary);

    // Trusted and isolated children, in both windows, share the host capability.
    for (uint64_t windowId = 1; windowId <= 2; windowId++) {
        for (NSUInteger bridge = 0; bridge <= 1; bridge++) {
            NSString *label = bridge ? @"trusted" : @"isolated";
            assert([host createWebViewInWindow:windowId label:label url:@"zero://inline/child"
                x:0 y:0 width:200 height:120 layer:1 transparent:NO bridgeEnabled:(bridge != 0)]);
            NSString *key = [host webViewKeyForWindow:windowId label:label];
            WKWebView *child = host.childWebViews[key];
            checkInspection(child, enabled);
            assert(child.configuration.userContentController.userScripts.count == bridge);
            assert([host.bridgeEnabledChildWebViewKeys containsObject:key] == (bridge != 0));
        }
    }
    assert(host.childWebViews.count == 4);
    for (NSWindow *window in host.windows.allValues) {
        window.delegate = nil;
        [window close];
    }
    native_sdk_appkit_destroy(handle);
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        for (NSUInteger enabled = 0; enabled <= 1; enabled++) {
            for (NSUInteger web = 0; web <= 1; web++) {
                checkHost(enabled != 0, web != 0);
            }
        }
        puts("WebView inspection: all primary, lazy, secondary, child and menu checks passed");
    }
    return 0;
}
