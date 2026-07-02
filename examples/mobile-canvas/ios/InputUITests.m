// Hardware-true input injection for the zero-native canvas shim, driven by
// verify_input.sh: a minimal XCUITest bundle (no .xcodeproj — compiled with
// clang, hosted by the stock XCTRunner.app, run via `xcodebuild
// test-without-building` and a generated .xctestrun). XCUITest synthesizes
// real UITouch / keyboard events through the system input path, so these
// tests prove the shim's touch forwarding and first-responder keyboard
// wiring — model-state ground truth comes from the automation snapshot the
// script reads between test invocations.
//
// Target coordinates arrive in points via TestingEnvironmentVariables
// ("x,y" pairs parsed from the automation snapshot's widget bounds):
//   ZN_TARGET_BUNDLE_ID  app under test
//   ZN_TAP_POINT         "Add task" button center
//   ZN_TEXTBOX_POINT     draft text field center
//   ZN_BLUR_POINT        non-focusable point (header text)
//   ZN_TYPE_TEXT         text typed on the system keyboard
//   ZN_PRESCROLL_TAPS    taps on ZN_TAP_POINT to grow the list before scrolling
//   ZN_SCROLL_FROM / ZN_SCROLL_TO  drag gesture endpoints

#import <XCTest/XCTest.h>

static NSString *ZeroNativeEnv(NSString *name) {
    return NSProcessInfo.processInfo.environment[name] ?: @"";
}

static CGPoint ZeroNativePointFromEnv(NSString *name) {
    NSArray<NSString *> *parts = [ZeroNativeEnv(name) componentsSeparatedByString:@","];
    if (parts.count != 2) return CGPointZero;
    return CGPointMake(parts[0].doubleValue, parts[1].doubleValue);
}

@interface ZeroNativeInputUITests : XCTestCase
@end

@implementation ZeroNativeInputUITests

- (XCUIApplication *)foregroundApp {
    NSString *bundleId = ZeroNativeEnv(@"ZN_TARGET_BUNDLE_ID");
    XCTAssertTrue(bundleId.length > 0, @"ZN_TARGET_BUNDLE_ID must be set");
    XCUIApplication *app = [[XCUIApplication alloc] initWithBundleIdentifier:bundleId];
    // Activate (not launch): the script launched the app with its
    // automation environment; model state persists across test steps.
    [app activate];
    XCTAssertTrue([app waitForState:XCUIApplicationStateRunningForeground timeout:30],
                  @"app under test did not reach the foreground");
    return app;
}

- (XCUICoordinate *)coordinateIn:(XCUIApplication *)app point:(CGPoint)point {
    XCTAssertFalse(CGPointEqualToPoint(point, CGPointZero), @"missing injection coordinate");
    XCUICoordinate *origin = [app coordinateWithNormalizedOffset:CGVectorMake(0, 0)];
    return [origin coordinateWithOffset:CGVectorMake(point.x, point.y)];
}

// (a) A real tap on the "Add task" button center; the script asserts the
// open count grew in the automation snapshot.
- (void)testTapAddTask {
    XCUIApplication *app = [self foregroundApp];
    [[self coordinateIn:app point:ZeroNativePointFromEnv(@"ZN_TAP_POINT")] tap];
    // Give the host-pumped frame loop a beat to publish the snapshot.
    [NSThread sleepForTimeInterval:1.0];
}

// (b) Tapping the draft textbox raises the system keyboard (asserted here,
// against the real UI), typed text flows through the shim's text path (the
// script asserts the draft value in the snapshot), and tapping a
// non-focusable point dismisses the keyboard.
- (void)testFocusTypeAndDismissKeyboard {
    XCUIApplication *app = [self foregroundApp];
    XCUIElement *keyboard = app.keyboards.firstMatch;

    [[self coordinateIn:app point:ZeroNativePointFromEnv(@"ZN_TEXTBOX_POINT")] tap];
    XCTAssertTrue([keyboard waitForExistenceWithTimeout:10],
                  @"system keyboard should appear when the textbox takes focus");

    NSString *text = ZeroNativeEnv(@"ZN_TYPE_TEXT");
    XCTAssertTrue(text.length > 0, @"ZN_TYPE_TEXT must be set");
    [app typeText:text];

    [[self coordinateIn:app point:ZeroNativePointFromEnv(@"ZN_BLUR_POINT")] tap];
    BOOL hidden = NO;
    for (int attempt = 0; attempt < 40; attempt++) {
        if (!keyboard.exists) {
            hidden = YES;
            break;
        }
        [NSThread sleepForTimeInterval:0.25];
    }
    XCTAssertTrue(hidden, @"system keyboard should hide when textbox focus leaves");
    [NSThread sleepForTimeInterval:1.0];
}

// (c) Grow the list past the viewport with real taps, then drag-scroll it;
// the script asserts the scroll offset moved in the snapshot.
- (void)testDragScroll {
    XCUIApplication *app = [self foregroundApp];
    NSInteger taps = ZeroNativeEnv(@"ZN_PRESCROLL_TAPS").integerValue;
    XCUICoordinate *add = [self coordinateIn:app point:ZeroNativePointFromEnv(@"ZN_TAP_POINT")];
    for (NSInteger index = 0; index < taps; index++) {
        [add tap];
    }

    XCUICoordinate *from = [self coordinateIn:app point:ZeroNativePointFromEnv(@"ZN_SCROLL_FROM")];
    XCUICoordinate *to = [self coordinateIn:app point:ZeroNativePointFromEnv(@"ZN_SCROLL_TO")];
    [from pressForDuration:0.1 thenDragToCoordinate:to];
    [NSThread sleepForTimeInterval:1.0];
}

@end
