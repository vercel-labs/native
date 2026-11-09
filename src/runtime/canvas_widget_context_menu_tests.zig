const Cases = @import("canvas_widget_context_menu_test_cases.zig").Cases(null);

test "right click over a widget with a declared menu presents it natively and dispatches the selection" {
    try Cases.case0();
}
test "a superseding presentation names the dismissed menu's view and keeps the successor selectable" {
    try Cases.case1();
}
test "a stale dismissal from a superseded menu never clears the successor's pending request" {
    try Cases.case2();
}
test "re-clicking the same widget mints a fresh token so the old menu's late dismissal is inert" {
    try Cases.case3();
}
test "right click on editable text presents the default edit menu wired to clipboard actions" {
    try Cases.case4();
}
test "a near-capacity multi-line context-menu paste sanitizes before it clamps" {
    try Cases.case5();
}
test "right click on a terminal presents Copy and Paste wired to selection and committed input" {
    try Cases.case6();
}
test "terminal Paste disables after exit and a pending live menu revalidates before dispatch" {
    try Cases.case7();
}
test "right click on selected static text presents a copy-only menu" {
    try Cases.case8();
}
test "right click with no menu target presents nothing" {
    try Cases.case9();
}
test "a declared menu on a presenter-less host becomes a fallback request, not a lost click" {
    try Cases.case10();
}
test "the widget-context-menu verb dispatches selections through context_menu_action and refuses dead items by name" {
    try Cases.case11();
}
test "the widget-context-menu verb's synthetic selection survives an erroring dismissal handler" {
    try Cases.case12();
}
test "the automation menu verb names its view from the request after the dismissal handler closes another view" {
    try Cases.case13();
}
test "the automation menu verb refuses by name when the dismissal handler presents a superseding menu" {
    try Cases.case14();
}
test "the automation menu verb refuses by name when the dismissal handler closes its target view" {
    try Cases.case15();
}
test "a presentation whose view the dismissal handler closes is disarmed and never announced" {
    try Cases.case16();
}
test "a presentation superseded mid-notice by the dismissal handler's own menu announces nothing" {
    try Cases.case17();
}
test "a superseding presentation's shown event names the presenting view after the dismissal handler closes another" {
    try Cases.case18();
}
test "automation snapshots list each widget's declared context-menu items in invocable order" {
    try Cases.case19();
}
test "automation snapshots report per-view context-menu item headroom" {
    try Cases.case20();
}
test "context-menu declarations sum across widgets to the budget and overflow loudly one past it" {
    try Cases.case21();
}
