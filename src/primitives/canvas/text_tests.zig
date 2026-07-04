const support = @import("test_support.zig");
const std = support.std;
const geometry = support.geometry;
const canvas = support.canvas;
const drawing_model = support.drawing_model;
const text_model = support.text_model;
const render_model = support.render_model;
const event_model = support.event_model;
const equality_model = support.equality_model;
const widget_runtime = support.widget_runtime;
const Error = support.Error;
const ObjectId = support.ObjectId;
const ImageId = support.ImageId;
const FontId = support.FontId;
const default_sans_font_id = support.default_sans_font_id;
const default_mono_font_id = support.default_mono_font_id;
const default_sans_font_family = support.default_sans_font_family;
const default_mono_font_family = support.default_mono_font_family;
const default_glyph_atlas_cache_retention_frames = support.default_glyph_atlas_cache_retention_frames;
const default_text_layout_cache_retention_frames = support.default_text_layout_cache_retention_frames;
const Color = support.Color;
const Affine = support.Affine;
const Radius = support.Radius;
const GradientStop = support.GradientStop;
const LinearGradient = support.LinearGradient;
const Fill = support.Fill;
const Stroke = support.Stroke;
const Clip = support.Clip;
const FillRect = support.FillRect;
const StrokeRect = support.StrokeRect;
const FillRoundedRect = support.FillRoundedRect;
const Line = support.Line;
const PathVerb = support.PathVerb;
const PathElement = support.PathElement;
const FillPath = support.FillPath;
const StrokePath = support.StrokePath;
const ImageFit = support.ImageFit;
const ImageSampling = support.ImageSampling;
const DrawImage = support.DrawImage;
const Shadow = support.Shadow;
const Blur = support.Blur;
const Glyph = support.Glyph;
const GlyphAtlasKey = support.GlyphAtlasKey;
const GlyphAtlasEntry = support.GlyphAtlasEntry;
const GlyphAtlasPlan = support.GlyphAtlasPlan;
const GlyphAtlasPlanner = support.GlyphAtlasPlanner;
const GlyphAtlasCacheEntry = support.GlyphAtlasCacheEntry;
const GlyphAtlasCacheActionKind = support.GlyphAtlasCacheActionKind;
const GlyphAtlasCacheAction = support.GlyphAtlasCacheAction;
const GlyphAtlasCachePlan = support.GlyphAtlasCachePlan;
const GlyphAtlasCachePlanner = support.GlyphAtlasCachePlanner;
const DrawText = support.DrawText;
const TextWrap = support.TextWrap;
const TextAlign = support.TextAlign;
const TextLayoutOptions = support.TextLayoutOptions;
const TextLine = support.TextLine;
const TextLayout = support.TextLayout;
const TextLayoutKey = support.TextLayoutKey;
const TextLayoutPlan = support.TextLayoutPlan;
const TextLayoutPlanSet = support.TextLayoutPlanSet;
const TextLayoutPlanner = support.TextLayoutPlanner;
const TextLayoutCacheEntry = support.TextLayoutCacheEntry;
const TextLayoutCacheActionKind = support.TextLayoutCacheActionKind;
const TextLayoutCacheAction = support.TextLayoutCacheAction;
const TextLayoutCachePlan = support.TextLayoutCachePlan;
const TextLayoutCachePlanner = support.TextLayoutCachePlanner;
const TextRange = support.TextRange;
const TextSelectionRect = support.TextSelectionRect;
const TextSelection = support.TextSelection;
const TextCaretDirection = support.TextCaretDirection;
const TextCaretMove = support.TextCaretMove;
const TextCompositionUpdate = support.TextCompositionUpdate;
const TextInputEvent = support.TextInputEvent;
const TextEditState = support.TextEditState;
const CanvasCommand = support.CanvasCommand;
const CommandRef = support.CommandRef;
const DiffKind = support.DiffKind;
const DiffChange = support.DiffChange;
const Builder = support.Builder;
const max_render_state_stack = support.max_render_state_stack;
const RenderState = support.RenderState;
const RenderCommand = support.RenderCommand;
const CanvasRenderOverride = support.CanvasRenderOverride;
const CanvasRenderAnimation = support.CanvasRenderAnimation;
const applyRenderOverrides = support.applyRenderOverrides;
const renderOverrideDirtyBounds = support.renderOverrideDirtyBounds;
const RenderPlan = support.RenderPlan;
const RenderPlanner = support.RenderPlanner;
const RenderPipelineKind = support.RenderPipelineKind;
const RenderBatch = support.RenderBatch;
const RenderBatchPlanner = support.RenderBatchPlanner;
const RenderBatchPlan = support.RenderBatchPlan;
const RenderPipelineCacheEntry = support.RenderPipelineCacheEntry;
const RenderPipelineCacheActionKind = support.RenderPipelineCacheActionKind;
const RenderPipelineCacheAction = support.RenderPipelineCacheAction;
const RenderPipelineCachePlanner = support.RenderPipelineCachePlanner;
const RenderPipelineCachePlan = support.RenderPipelineCachePlan;
const RenderPathGeometryKind = support.RenderPathGeometryKind;
const RenderPathGeometry = support.RenderPathGeometry;
const RenderPathGeometryPlan = support.RenderPathGeometryPlan;
const RenderPathGeometryPlanner = support.RenderPathGeometryPlanner;
const RenderPathGeometryKey = support.RenderPathGeometryKey;
const RenderPathGeometryCacheEntry = support.RenderPathGeometryCacheEntry;
const RenderPathGeometryCacheActionKind = support.RenderPathGeometryCacheActionKind;
const RenderPathGeometryCacheAction = support.RenderPathGeometryCacheAction;
const RenderPathGeometryCachePlan = support.RenderPathGeometryCachePlan;
const RenderPathGeometryCachePlanner = support.RenderPathGeometryCachePlanner;
const RenderImage = support.RenderImage;
const RenderImagePlan = support.RenderImagePlan;
const RenderImagePlanner = support.RenderImagePlanner;
const RenderImageKey = support.RenderImageKey;
const RenderImageCacheEntry = support.RenderImageCacheEntry;
const RenderImageCacheActionKind = support.RenderImageCacheActionKind;
const RenderImageCacheAction = support.RenderImageCacheAction;
const RenderImageCachePlan = support.RenderImageCachePlan;
const RenderImageCachePlanner = support.RenderImageCachePlanner;
const RenderResourceKind = support.RenderResourceKind;
const RenderResource = support.RenderResource;
const RenderResourcePlan = support.RenderResourcePlan;
const RenderResourcePlanner = support.RenderResourcePlanner;
const RenderResourceKey = support.RenderResourceKey;
const RenderResourceCacheEntry = support.RenderResourceCacheEntry;
const RenderResourceCacheActionKind = support.RenderResourceCacheActionKind;
const RenderResourceCacheAction = support.RenderResourceCacheAction;
const RenderResourceCachePlan = support.RenderResourceCachePlan;
const RenderResourceCachePlanner = support.RenderResourceCachePlanner;
const RenderLayer = support.RenderLayer;
const RenderLayerPlan = support.RenderLayerPlan;
const RenderLayerPlanner = support.RenderLayerPlanner;
const RenderLayerKey = support.RenderLayerKey;
const RenderLayerCacheEntry = support.RenderLayerCacheEntry;
const RenderLayerCacheActionKind = support.RenderLayerCacheActionKind;
const RenderLayerCacheAction = support.RenderLayerCacheAction;
const RenderLayerCachePlan = support.RenderLayerCachePlan;
const RenderLayerCachePlanner = support.RenderLayerCachePlanner;
const VisualEffectKind = support.VisualEffectKind;
const VisualEffect = support.VisualEffect;
const VisualEffectPlan = support.VisualEffectPlan;
const VisualEffectPlanner = support.VisualEffectPlanner;
const VisualEffectKey = support.VisualEffectKey;
const VisualEffectCacheEntry = support.VisualEffectCacheEntry;
const VisualEffectCacheActionKind = support.VisualEffectCacheActionKind;
const VisualEffectCacheAction = support.VisualEffectCacheAction;
const VisualEffectCachePlan = support.VisualEffectCachePlan;
const VisualEffectCachePlanner = support.VisualEffectCachePlanner;
const CanvasFrameOptions = support.CanvasFrameOptions;
const CanvasFrameStorage = support.CanvasFrameStorage;
const CanvasFrameBudget = support.CanvasFrameBudget;
const CanvasFrameBudgetStatus = support.CanvasFrameBudgetStatus;
const CanvasFrameDiagnostics = support.CanvasFrameDiagnostics;
const CanvasFrameProfileRisk = support.CanvasFrameProfileRisk;
const CanvasFrameProfile = support.CanvasFrameProfile;
const CanvasRenderPass = support.CanvasRenderPass;
const CanvasFrame = support.CanvasFrame;
const buildCanvasFrame = support.buildCanvasFrame;
const CanvasRenderPassLoadAction = support.CanvasRenderPassLoadAction;
const RenderEncoderBeginPass = support.RenderEncoderBeginPass;
const RenderEncoderCommand = support.RenderEncoderCommand;
const RenderEncoderPlan = support.RenderEncoderPlan;
const RenderEncoderPlanner = support.RenderEncoderPlanner;
const CanvasGpuCommandKind = support.CanvasGpuCommandKind;
const CanvasGpuRoundedRect = support.CanvasGpuRoundedRect;
const CanvasGpuStrokeRect = support.CanvasGpuStrokeRect;
const CanvasGpuLine = support.CanvasGpuLine;
const CanvasGpuShape = support.CanvasGpuShape;
const CanvasGpuPaint = support.CanvasGpuPaint;
const CanvasGpuImage = support.CanvasGpuImage;
const CanvasGpuText = support.CanvasGpuText;
const CanvasGpuShadow = support.CanvasGpuShadow;
const CanvasGpuBlur = support.CanvasGpuBlur;
const CanvasGpuEffect = support.CanvasGpuEffect;
const CanvasGpuCommand = support.CanvasGpuCommand;
const CanvasGpuPacket = support.CanvasGpuPacket;
const CanvasGpuPacketSummary = support.CanvasGpuPacketSummary;
const CanvasGpuPacketPlanner = support.CanvasGpuPacketPlanner;
const ReferenceImage = support.ReferenceImage;
const ReferenceRenderSurface = support.ReferenceRenderSurface;
const Density = support.Density;
const Easing = support.Easing;
const ColorScheme = support.ColorScheme;
const ColorContrast = support.ColorContrast;
const ThemeOptions = support.ThemeOptions;
const ColorTokens = support.ColorTokens;
const FontFamily = support.FontFamily;
const TypographyTokens = support.TypographyTokens;
const SpacingTokens = support.SpacingTokens;
const RadiusTokens = support.RadiusTokens;
const StrokeTokens = support.StrokeTokens;
const ShadowToken = support.ShadowToken;
const ShadowTokens = support.ShadowTokens;
const BlurTokens = support.BlurTokens;
const MotionDuration = support.MotionDuration;
const MotionAnimationOptions = support.MotionAnimationOptions;
const MotionTokens = support.MotionTokens;
const SpringToken = support.SpringToken;
const BlurTokenRef = support.BlurTokenRef;
const ScrollPhysics = support.ScrollPhysics;
const ScrollState = support.ScrollState;
const VirtualListOptions = support.VirtualListOptions;
const VirtualListRange = support.VirtualListRange;
const virtualListRange = support.virtualListRange;
const LayerTokens = support.LayerTokens;
const PixelSnapTokens = support.PixelSnapTokens;
const ControlVisualTokens = support.ControlVisualTokens;
const ControlTokens = support.ControlTokens;
const ColorTokenOverrides = support.ColorTokenOverrides;
const TypographyTokenOverrides = support.TypographyTokenOverrides;
const SpacingTokenOverrides = support.SpacingTokenOverrides;
const RadiusTokenOverrides = support.RadiusTokenOverrides;
const StrokeTokenOverrides = support.StrokeTokenOverrides;
const ShadowTokenOverrides = support.ShadowTokenOverrides;
const ShadowTokensOverrides = support.ShadowTokensOverrides;
const BlurTokenOverrides = support.BlurTokenOverrides;
const SpringTokenOverrides = support.SpringTokenOverrides;
const MotionTokenOverrides = support.MotionTokenOverrides;
const ScrollPhysicsOverrides = support.ScrollPhysicsOverrides;
const LayerTokenOverrides = support.LayerTokenOverrides;
const PixelSnapTokenOverrides = support.PixelSnapTokenOverrides;
const ControlVisualTokenOverrides = support.ControlVisualTokenOverrides;
const ControlTokenOverrides = support.ControlTokenOverrides;
const DesignTokenOverrides = support.DesignTokenOverrides;
const DesignTokens = support.DesignTokens;
const WidgetKind = support.WidgetKind;
const WidgetCursor = support.WidgetCursor;
const WidgetState = support.WidgetState;
const WidgetRenderState = support.WidgetRenderState;
const WidgetMainAlignment = support.WidgetMainAlignment;
const WidgetCrossAlignment = support.WidgetCrossAlignment;
const WidgetLayoutStyle = support.WidgetLayoutStyle;
const WidgetStyle = support.WidgetStyle;
const WidgetVariant = support.WidgetVariant;
const WidgetSize = support.WidgetSize;
const WidgetRole = support.WidgetRole;
const BuiltinComponentStyle = support.BuiltinComponentStyle;
const BuiltinComponentKind = support.BuiltinComponentKind;
const builtin_component_kinds = support.builtin_component_kinds;
const builtin_component_names = support.builtin_component_names;
const BuiltinComponentDescriptor = support.BuiltinComponentDescriptor;
const builtinComponentCount = support.builtinComponentCount;
const builtinComponentName = support.builtinComponentName;
const builtinComponentDescriptor = support.builtinComponentDescriptor;
const WidgetActions = support.WidgetActions;
const WidgetSemantics = support.WidgetSemantics;
const Widget = support.Widget;
const BuiltinComponentOptions = support.BuiltinComponentOptions;
const WidgetCommandPart = support.WidgetCommandPart;
const BuiltinSurfacePlacementOptions = support.BuiltinSurfacePlacementOptions;
const BuiltinSurfaceBackdropOptions = support.BuiltinSurfaceBackdropOptions;
const BuiltinStatusBarOptions = support.BuiltinStatusBarOptions;
const BuiltinSurfaceEnterAnimationOptions = support.BuiltinSurfaceEnterAnimationOptions;
const builtinComponentWidget = support.builtinComponentWidget;
const widgetCommandPartId = support.widgetCommandPartId;
const builtinSurfaceBackdropWidget = support.builtinSurfaceBackdropWidget;
const builtinStatusBarWidget = support.builtinStatusBarWidget;
const builtinSurfaceFrame = support.builtinSurfaceFrame;
const appendBuiltinSurfaceEnterAnimations = support.appendBuiltinSurfaceEnterAnimations;
const builtinSurfaceEnterOffset = support.builtinSurfaceEnterOffset;
const max_widget_depth = support.max_widget_depth;
const max_widget_text_range_rects = support.max_widget_text_range_rects;
const WidgetLayoutNode = support.WidgetLayoutNode;
const WidgetHit = support.WidgetHit;
const WidgetPointerPhase = support.WidgetPointerPhase;
const WidgetPointerEvent = support.WidgetPointerEvent;
const WidgetKeyboardPhase = support.WidgetKeyboardPhase;
const WidgetKeyboardModifiers = support.WidgetKeyboardModifiers;
const WidgetKeyboardEvent = support.WidgetKeyboardEvent;
const WidgetControlIntentKind = support.WidgetControlIntentKind;
const WidgetControlIntent = support.WidgetControlIntent;
const WidgetSemanticAction = support.WidgetSemanticAction;
const WidgetFileDropEvent = support.WidgetFileDropEvent;
const WidgetDragEvent = support.WidgetDragEvent;
const WidgetEventPhase = support.WidgetEventPhase;
const WidgetEventRouteEntry = support.WidgetEventRouteEntry;
const WidgetEventRoute = support.WidgetEventRoute;
const WidgetKeyboardRoute = support.WidgetKeyboardRoute;
const WidgetFocusDirection = support.WidgetFocusDirection;
const WidgetFocusTarget = support.WidgetFocusTarget;
const WidgetScrollMetrics = support.WidgetScrollMetrics;
const WidgetListMetrics = support.WidgetListMetrics;
const WidgetSemanticsNode = support.WidgetSemanticsNode;
const WidgetInvalidationKind = support.WidgetInvalidationKind;
const WidgetInvalidation = support.WidgetInvalidation;
const widgetKeyboardControlIntent = support.widgetKeyboardControlIntent;
const widgetSemanticControlIntent = support.widgetSemanticControlIntent;
const widgetSemanticControlIntentWithActions = support.widgetSemanticControlIntentWithActions;
const isWidgetActivationKey = support.isWidgetActivationKey;
const widgetSliderKeyboardValue = support.widgetSliderKeyboardValue;
const widgetScrollKeyboardIntent = support.widgetScrollKeyboardIntent;
const widgetScrollKeyboardDelta = support.widgetScrollKeyboardDelta;
const WidgetLayoutTree = support.WidgetLayoutTree;
const DisplayList = support.DisplayList;
const emitWidgetTree = support.emitWidgetTree;
const layoutWidgetTree = support.layoutWidgetTree;
const layoutWidgetTreeWithTokens = support.layoutWidgetTreeWithTokens;
const layoutTextRun = support.layoutTextRun;
const layoutTextRunPlan = support.layoutTextRunPlan;
const layoutTextCaretRect = support.layoutTextCaretRect;
const textCaretRectForLayout = support.textCaretRectForLayout;
const layoutTextSelectionRects = support.layoutTextSelectionRects;
const textSelectionRectsForLayout = support.textSelectionRectsForLayout;
const layoutTextOffsetForPoint = support.layoutTextOffsetForPoint;
const textOffsetForLayoutPoint = support.textOffsetForLayoutPoint;
const applyTextInputEvent = support.applyTextInputEvent;
const sampleCanvasRenderAnimations = support.sampleCanvasRenderAnimations;
const emitWidgetLayout = support.emitWidgetLayout;
const toggleWidgetKnobCommandId = support.toggleWidgetKnobCommandId;
const toggleWidgetKnobTravel = support.toggleWidgetKnobTravel;
const textSelectionForWidgetPoint = support.textSelectionForWidgetPoint;
const textOffsetForWidgetPoint = support.textOffsetForWidgetPoint;
const textInputViewportForWidget = support.textInputViewportForWidget;
const textInputContentExtentForWidget = support.textInputContentExtentForWidget;
const textInputMaxScrollOffsetForWidget = support.textInputMaxScrollOffsetForWidget;
const clampedTextInputScrollOffsetForWidget = support.clampedTextInputScrollOffsetForWidget;
const intrinsicWidgetSize = support.intrinsicWidgetSize;
const cursorForWidgetHit = support.cursorForWidgetHit;
const cursorForWidgetTarget = support.cursorForWidgetTarget;
const WidgetTextGeometry = support.WidgetTextGeometry;
const textGeometryForWidget = support.textGeometryForWidget;
const virtualWidgetScrollContentExtent = support.virtualWidgetScrollContentExtent;
const virtualWidgetScrollContentExtentWithTokens = support.virtualWidgetScrollContentExtentWithTokens;
const writeCanvasGpuPacketJson = support.writeCanvasGpuPacketJson;
const strokeBounds = support.strokeBounds;
const shadowBounds = support.shadowBounds;
const semanticActions = support.semanticActions;
const defaultSemanticActions = support.defaultSemanticActions;
const defaultFocusable = support.defaultFocusable;
const textLineBounds = support.textLineBounds;
const textBounds = support.textBounds;
const estimateTextWidth = support.estimateTextWidth;
const estimateTextWidthForFont = support.estimateTextWidthForFont;
const estimateTextAdvanceForBytes = support.estimateTextAdvanceForBytes;
const estimatedGlyphAdvance = support.estimatedGlyphAdvance;
const snapTextSelection = support.snapTextSelection;
const snapTextRange = support.snapTextRange;
const nextTextOffset = support.nextTextOffset;
const nextTextLineEnd = support.nextTextLineEnd;
const isTextBreakByte = support.isTextBreakByte;
const textLineRange = support.textLineRange;
const textLineCaretX = support.textLineCaretX;
const motionProgress = support.motionProgress;
const renderImageFingerprint = support.renderImageFingerprint;
const renderImageFingerprintForResource = support.renderImageFingerprintForResource;
const commandsEqual = support.commandsEqual;
const rectsEqual = support.rectsEqual;
const optionalRectsEqual = support.optionalRectsEqual;
const sizesEqual = support.sizesEqual;
const insetsEqual = support.insetsEqual;
const optionalColorsEqual = support.optionalColorsEqual;
const radiiEqual = support.radiiEqual;
const affinesEqual = support.affinesEqual;
const optionalF32Equal = support.optionalF32Equal;
const optionalTextSelectionsEqual = support.optionalTextSelectionsEqual;
const optionalTextRangesEqual = support.optionalTextRangesEqual;
const widgetPartId = support.widgetPartId;
const colorWithAlpha = support.colorWithAlpha;
const widgetControlHeight = support.widgetControlHeight;
const textSelectionFillColor = support.textSelectionFillColor;
const transparentColor = support.transparentColor;
const expectRect = support.expectRect;
const expectRectApprox = support.expectRectApprox;
const expectPixelRgba8 = support.expectPixelRgba8;
const expectVisiblePixel = support.expectVisiblePixel;
const referenceSurfaceSignature = support.referenceSurfaceSignature;
const expectLayoutFrame = support.expectLayoutFrame;
const expectRouteEntry = support.expectRouteEntry;
const expectFillColor = support.expectFillColor;
const expectGpuPaintColor = support.expectGpuPaintColor;

test "text edit state applies utf8-aware caret insert and delete events" {
    var storage_a: [64]u8 = undefined;
    var storage_b: [64]u8 = undefined;
    var state = TextEditState.init("AéB");

    state = try state.apply(.{ .move_caret = .{ .direction = .previous } }, &storage_a);
    try std.testing.expectEqual(@as(usize, 3), state.selection.focus);

    state = try state.apply(.delete_backward, &storage_a);
    try std.testing.expectEqualStrings("AB", state.text);
    try std.testing.expectEqual(@as(usize, 1), state.selection.focus);

    state = try state.apply(.{ .insert_text = "x" }, &storage_b);
    try std.testing.expectEqualStrings("AxB", state.text);
    try std.testing.expectEqual(@as(usize, 2), state.selection.focus);

    state = try state.apply(.clear, &storage_a);
    try std.testing.expectEqualStrings("", state.text);
    try std.testing.expectEqualDeep(TextSelection.collapsed(0), state.selection);

    state = TextEditState{ .text = "hello brave world", .selection = TextSelection.collapsed(17) };
    state = try state.apply(.delete_word_backward, &storage_b);
    try std.testing.expectEqualStrings("hello brave ", state.text);
    try std.testing.expectEqualDeep(TextSelection.collapsed(12), state.selection);

    state = TextEditState{ .text = "hello brave world", .selection = TextSelection.collapsed(0) };
    state = try state.apply(.delete_word_forward, &storage_a);
    try std.testing.expectEqualStrings(" brave world", state.text);
    try std.testing.expectEqualDeep(TextSelection.collapsed(0), state.selection);

    state = TextEditState{ .text = "éclair cafe", .selection = TextSelection.collapsed(7) };
    state = try state.apply(.delete_word_backward, &storage_b);
    try std.testing.expectEqualStrings(" cafe", state.text);
    try std.testing.expectEqualDeep(TextSelection.collapsed(0), state.selection);

    state = TextEditState.init("");
    state = try state.apply(.{ .insert_text = "AxB" }, &storage_b);
    try std.testing.expectEqualStrings("AxB", state.text);
    try std.testing.expectEqual(@as(usize, 3), state.selection.focus);

    state = try state.apply(.{ .set_selection = .{ .anchor = 1, .focus = 3 } }, &storage_a);
    state = try state.apply(.delete_forward, &storage_a);
    try std.testing.expectEqualStrings("A", state.text);
    try std.testing.expectEqual(@as(usize, 1), state.selection.focus);

    var small: [1]u8 = undefined;
    try std.testing.expectError(error.TextEditBufferTooSmall, state.apply(.{ .insert_text = "toolong" }, &small));
}

test "widget keyboard control intents map activation keys" {
    const press = widgetKeyboardControlIntent(.{ .kind = .button, .text = "Save" }, .{ .phase = .key_down, .key = "enter" }).?;
    try std.testing.expectEqual(WidgetControlIntentKind.press, press.kind);
    try std.testing.expect(press.actions.press);

    const select = widgetKeyboardControlIntent(.{ .kind = .select, .text = "Environment" }, .{ .phase = .key_down, .key = "space" }).?;
    try std.testing.expectEqual(WidgetControlIntentKind.press, select.kind);
    try std.testing.expect(select.actions.press);

    const combobox = widgetKeyboardControlIntent(.{ .kind = .combobox, .text = "Search", .command = "search.open" }, .{ .phase = .key_down, .key = "enter" }).?;
    try std.testing.expectEqual(WidgetControlIntentKind.press, combobox.kind);
    try std.testing.expect(combobox.actions.press);

    const toggle = widgetKeyboardControlIntent(.{ .kind = .toggle, .text = "Live" }, .{ .phase = .key_down, .key = "space" }).?;
    try std.testing.expectEqual(WidgetControlIntentKind.toggle, toggle.kind);
    try std.testing.expect(toggle.actions.toggle);

    const accordion = widgetKeyboardControlIntent(.{ .kind = .accordion, .text = "Details" }, .{ .phase = .key_down, .key = "enter" }).?;
    try std.testing.expectEqual(WidgetControlIntentKind.toggle, accordion.kind);
    try std.testing.expect(accordion.actions.toggle);

    const selected = widgetKeyboardControlIntent(.{ .kind = .segmented_control, .text = "Revenue", .command = "mode.change" }, .{ .phase = .key_down, .key = "enter" }).?;
    try std.testing.expectEqual(WidgetControlIntentKind.select, selected.kind);
    try std.testing.expect(selected.actions.select);
    try std.testing.expect(selected.actions.press);

    const radio = widgetKeyboardControlIntent(.{ .kind = .radio, .text = "Annual", .command = "billing.cadence" }, .{ .phase = .key_down, .key = "space" }).?;
    try std.testing.expectEqual(WidgetControlIntentKind.select, radio.kind);
    try std.testing.expect(radio.actions.select);
    try std.testing.expect(radio.actions.press);
    try std.testing.expect(!radio.actions.toggle);

    try std.testing.expect(widgetKeyboardControlIntent(.{ .kind = .button, .text = "Save" }, .{ .phase = .key_down, .key = "enter", .modifiers = .{ .super = true } }) == null);
    try std.testing.expect(widgetKeyboardControlIntent(.{ .kind = .button, .text = "Save", .state = .{ .disabled = true } }, .{ .phase = .key_down, .key = "enter" }) == null);
    try std.testing.expect(widgetKeyboardControlIntent(.{ .kind = .button, .text = "Save" }, .{ .phase = .key_up, .key = "enter" }) == null);
}

test "widget keyboard control intents map slider and scroll keys" {
    const slider = Widget{ .kind = .slider, .value = 0.5 };
    const increment = widgetKeyboardControlIntent(slider, .{ .phase = .key_down, .key = "arrowright" }).?;
    try std.testing.expectEqual(WidgetControlIntentKind.set_value, increment.kind);
    try std.testing.expect(increment.actions.increment);
    try std.testing.expect(!increment.actions.decrement);
    try std.testing.expectApproxEqAbs(@as(f32, 0.55), increment.value.?, 0.001);

    const decrement = widgetKeyboardControlIntent(slider, .{ .phase = .key_down, .key = "arrowleft", .modifiers = .{ .shift = true } }).?;
    try std.testing.expectEqual(WidgetControlIntentKind.set_value, decrement.kind);
    try std.testing.expect(decrement.actions.decrement);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), decrement.value.?, 0.001);

    const end = widgetKeyboardControlIntent(slider, .{ .phase = .key_down, .key = "end" }).?;
    try std.testing.expectEqual(WidgetControlIntentKind.set_value, end.kind);
    try std.testing.expectApproxEqAbs(@as(f32, 1), end.value.?, 0.001);

    const scroll = Widget{ .kind = .scroll_view, .frame = geometry.RectF.init(0, 0, 120, 100) };
    const line_down = widgetKeyboardControlIntent(scroll, .{ .phase = .key_down, .key = "arrowdown" }).?;
    try std.testing.expectEqual(WidgetControlIntentKind.scroll_by, line_down.kind);
    try std.testing.expect(line_down.actions.increment);
    try std.testing.expectApproxEqAbs(@as(f32, 35), line_down.delta, 0.001);

    const page_up = widgetKeyboardControlIntent(scroll, .{ .phase = .key_down, .key = "pageup" }).?;
    try std.testing.expectEqual(WidgetControlIntentKind.scroll_by, page_up.kind);
    try std.testing.expect(page_up.actions.decrement);
    try std.testing.expectApproxEqAbs(@as(f32, -85), page_up.delta, 0.001);

    try std.testing.expectEqual(WidgetControlIntentKind.scroll_to_start, widgetKeyboardControlIntent(scroll, .{ .phase = .key_down, .key = "home" }).?.kind);
    try std.testing.expectEqual(WidgetControlIntentKind.scroll_to_end, widgetKeyboardControlIntent(scroll, .{ .phase = .key_down, .key = "end" }).?.kind);
}

test "widget semantic control intents map built-in actions" {
    const press = widgetSemanticControlIntent(.{ .kind = .button, .text = "Save" }, .press).?;
    try std.testing.expectEqual(WidgetControlIntentKind.press, press.kind);
    try std.testing.expect(press.actions.press);

    const select = widgetSemanticControlIntent(.{ .kind = .select, .text = "Environment" }, .press).?;
    try std.testing.expectEqual(WidgetControlIntentKind.press, select.kind);
    try std.testing.expect(select.actions.press);

    const combobox = widgetSemanticControlIntent(.{ .kind = .combobox, .text = "Search", .command = "search.open" }, .press).?;
    try std.testing.expectEqual(WidgetControlIntentKind.press, combobox.kind);
    try std.testing.expect(combobox.actions.press);

    const toggle = widgetSemanticControlIntent(.{ .kind = .checkbox, .text = "Selected" }, .toggle).?;
    try std.testing.expectEqual(WidgetControlIntentKind.toggle, toggle.kind);
    try std.testing.expect(toggle.actions.toggle);

    const accordion = widgetSemanticControlIntent(.{ .kind = .accordion, .text = "Details" }, .toggle).?;
    try std.testing.expectEqual(WidgetControlIntentKind.toggle, accordion.kind);
    try std.testing.expect(accordion.actions.toggle);

    const selected = widgetSemanticControlIntent(.{ .kind = .segmented_control, .text = "Revenue", .command = "mode.change" }, .select).?;
    try std.testing.expectEqual(WidgetControlIntentKind.select, selected.kind);
    try std.testing.expect(selected.actions.select);
    try std.testing.expect(selected.actions.press);

    const radio = widgetSemanticControlIntent(.{ .kind = .radio, .text = "Annual", .command = "billing.cadence" }, .select).?;
    try std.testing.expectEqual(WidgetControlIntentKind.select, radio.kind);
    try std.testing.expect(radio.actions.select);
    try std.testing.expect(radio.actions.press);
    try std.testing.expect(!radio.actions.toggle);

    const pressed_menu_item = widgetSemanticControlIntent(.{ .kind = .menu_item, .text = "Archive", .command = "archive" }, .press).?;
    try std.testing.expectEqual(WidgetControlIntentKind.select, pressed_menu_item.kind);
    try std.testing.expect(pressed_menu_item.actions.select);
    try std.testing.expect(pressed_menu_item.actions.press);

    try std.testing.expect(widgetSemanticControlIntent(.{ .kind = .button, .text = "Save" }, .toggle) == null);
    try std.testing.expect(widgetSemanticControlIntent(.{ .kind = .button, .text = "Save", .state = .{ .disabled = true } }, .press) == null);
    try std.testing.expect(widgetSemanticControlIntent(.{ .kind = .button, .text = "Save", .semantics = .{ .hidden = true } }, .press) == null);
}

test "widget semantic control intents map slider and scroll actions" {
    const slider = Widget{ .kind = .slider, .value = 0.5 };
    const increment = widgetSemanticControlIntent(slider, .increment).?;
    try std.testing.expectEqual(WidgetControlIntentKind.set_value, increment.kind);
    try std.testing.expect(increment.actions.increment);
    try std.testing.expect(!increment.actions.decrement);
    try std.testing.expectApproxEqAbs(@as(f32, 0.55), increment.value.?, 0.001);

    const decrement = widgetSemanticControlIntent(slider, .decrement).?;
    try std.testing.expectEqual(WidgetControlIntentKind.set_value, decrement.kind);
    try std.testing.expect(decrement.actions.decrement);
    try std.testing.expectApproxEqAbs(@as(f32, 0.45), decrement.value.?, 0.001);

    const max_slider = Widget{ .kind = .slider, .value = 0.98 };
    try std.testing.expectApproxEqAbs(@as(f32, 1), widgetSemanticControlIntent(max_slider, .increment).?.value.?, 0.001);

    const scroll = Widget{ .kind = .scroll_view, .frame = geometry.RectF.init(0, 0, 120, 100) };
    try std.testing.expect(widgetSemanticControlIntent(scroll, .increment) == null);

    const scroll_actions = WidgetActions{ .increment = true, .decrement = true };
    const page_down = widgetSemanticControlIntentWithActions(scroll, .increment, scroll_actions).?;
    try std.testing.expectEqual(WidgetControlIntentKind.scroll_by, page_down.kind);
    try std.testing.expect(page_down.actions.increment);
    try std.testing.expectApproxEqAbs(@as(f32, 85), page_down.delta, 0.001);

    const page_up = widgetSemanticControlIntentWithActions(scroll, .decrement, scroll_actions).?;
    try std.testing.expectEqual(WidgetControlIntentKind.scroll_by, page_up.kind);
    try std.testing.expect(page_up.actions.decrement);
    try std.testing.expectApproxEqAbs(@as(f32, -85), page_up.delta, 0.001);
}

test "widget keyboard events map to text edit events" {
    var storage_a: [64]u8 = undefined;
    var storage_b: [64]u8 = undefined;
    var state = TextEditState.init("Hi");

    const insert = (WidgetKeyboardEvent{ .phase = .text_input, .text = "!" }).textEditEvent().?;
    state = try state.apply(insert, &storage_a);
    try std.testing.expectEqualStrings("Hi!", state.text);
    try std.testing.expectEqual(@as(usize, 3), state.selection.focus);

    const backspace = (WidgetKeyboardEvent{ .phase = .key_down, .key = "backspace" }).textEditEvent().?;
    state = try state.apply(backspace, &storage_b);
    try std.testing.expectEqualStrings("Hi", state.text);
    try std.testing.expectEqual(@as(usize, 2), state.selection.focus);

    const extend_left = (WidgetKeyboardEvent{ .phase = .key_down, .key = "arrowleft", .modifiers = .{ .shift = true } }).textEditEvent().?;
    state = try state.apply(extend_left, &storage_a);
    try std.testing.expectEqual(@as(usize, 2), state.selection.anchor);
    try std.testing.expectEqual(@as(usize, 1), state.selection.focus);

    const delete_forward = (WidgetKeyboardEvent{ .phase = .key_down, .key = "delete" }).textEditEvent().?;
    state = try state.apply(delete_forward, &storage_b);
    try std.testing.expectEqualStrings("H", state.text);
    try std.testing.expectEqual(@as(usize, 1), state.selection.focus);

    const home = (WidgetKeyboardEvent{ .phase = .key_down, .key = "home" }).textEditEvent().?;
    state = try state.apply(home, &storage_a);
    try std.testing.expectEqual(@as(usize, 0), state.selection.focus);

    const select_all = (WidgetKeyboardEvent{ .phase = .key_down, .key = "a", .modifiers = .{ .super = true } }).textEditEvent().?;
    state = try state.apply(select_all, &storage_b);
    try std.testing.expectEqual(@as(usize, 0), state.selection.anchor);
    try std.testing.expectEqual(@as(usize, 1), state.selection.focus);

    state = try state.apply(.{ .insert_text = "!" }, &storage_a);
    try std.testing.expectEqualStrings("!", state.text);
    try std.testing.expectEqual(@as(usize, 1), state.selection.focus);

    const option_insert = (WidgetKeyboardEvent{ .phase = .text_input, .text = "@", .modifiers = .{ .alt = true } }).textEditEvent().?;
    switch (option_insert) {
        .insert_text => |text| try std.testing.expectEqualStrings("@", text),
        else => try std.testing.expect(false),
    }

    var nav_storage: [64]u8 = undefined;
    var nav_state = TextEditState{ .text = "hello", .selection = TextSelection.collapsed(2) };
    const command_left = (WidgetKeyboardEvent{ .phase = .key_down, .key = "arrowleft", .modifiers = .{ .super = true } }).textEditEvent().?;
    nav_state = try nav_state.apply(command_left, &nav_storage);
    try std.testing.expectEqualDeep(TextSelection.collapsed(0), nav_state.selection);

    nav_state = TextEditState{ .text = "hello", .selection = TextSelection.collapsed(2) };
    const command_right = (WidgetKeyboardEvent{ .phase = .key_down, .key = "arrowright", .modifiers = .{ .super = true } }).textEditEvent().?;
    nav_state = try nav_state.apply(command_right, &nav_storage);
    try std.testing.expectEqualDeep(TextSelection.collapsed(5), nav_state.selection);

    nav_state = TextEditState{ .text = "hello", .selection = TextSelection.collapsed(4) };
    const shift_command_left = (WidgetKeyboardEvent{ .phase = .key_down, .key = "arrowleft", .modifiers = .{ .super = true, .shift = true } }).textEditEvent().?;
    nav_state = try nav_state.apply(shift_command_left, &nav_storage);
    try std.testing.expectEqualDeep(TextSelection{ .anchor = 4, .focus = 0 }, nav_state.selection);

    nav_state = TextEditState{ .text = "hello brave world", .selection = TextSelection.collapsed(17) };
    const option_left = (WidgetKeyboardEvent{ .phase = .key_down, .key = "arrowleft", .modifiers = .{ .alt = true } }).textEditEvent().?;
    nav_state = try nav_state.apply(option_left, &nav_storage);
    try std.testing.expectEqualDeep(TextSelection.collapsed(12), nav_state.selection);

    nav_state = try nav_state.apply(option_left, &nav_storage);
    try std.testing.expectEqualDeep(TextSelection.collapsed(6), nav_state.selection);

    nav_state = TextEditState{ .text = "hello brave world", .selection = TextSelection.collapsed(0) };
    const control_right = (WidgetKeyboardEvent{ .phase = .key_down, .key = "arrowright", .modifiers = .{ .control = true } }).textEditEvent().?;
    nav_state = try nav_state.apply(control_right, &nav_storage);
    try std.testing.expectEqualDeep(TextSelection.collapsed(5), nav_state.selection);

    nav_state = try nav_state.apply(control_right, &nav_storage);
    try std.testing.expectEqualDeep(TextSelection.collapsed(11), nav_state.selection);

    nav_state = TextEditState{ .text = "hello brave world", .selection = TextSelection.collapsed(17) };
    const shift_option_left = (WidgetKeyboardEvent{ .phase = .key_down, .key = "arrowleft", .modifiers = .{ .alt = true, .shift = true } }).textEditEvent().?;
    nav_state = try nav_state.apply(shift_option_left, &nav_storage);
    try std.testing.expectEqualDeep(TextSelection{ .anchor = 17, .focus = 12 }, nav_state.selection);

    nav_state = TextEditState{ .text = "éclair cafe", .selection = TextSelection.collapsed(0) };
    const unicode_control_right = (WidgetKeyboardEvent{ .phase = .key_down, .key = "arrowright", .modifiers = .{ .control = true } }).textEditEvent().?;
    nav_state = try nav_state.apply(unicode_control_right, &nav_storage);
    try std.testing.expectEqualDeep(TextSelection.collapsed(7), nav_state.selection);

    nav_state = TextEditState{ .text = "hello brave world", .selection = TextSelection.collapsed(17) };
    const option_backspace = (WidgetKeyboardEvent{ .phase = .key_down, .key = "backspace", .modifiers = .{ .alt = true } }).textEditEvent().?;
    nav_state = try nav_state.apply(option_backspace, &nav_storage);
    try std.testing.expectEqualStrings("hello brave ", nav_state.text);
    try std.testing.expectEqualDeep(TextSelection.collapsed(12), nav_state.selection);

    nav_state = TextEditState{ .text = "hello brave world", .selection = TextSelection.collapsed(0) };
    const control_delete = (WidgetKeyboardEvent{ .phase = .key_down, .key = "delete", .modifiers = .{ .control = true } }).textEditEvent().?;
    nav_state = try nav_state.apply(control_delete, &nav_storage);
    try std.testing.expectEqualStrings(" brave world", nav_state.text);
    try std.testing.expectEqualDeep(TextSelection.collapsed(0), nav_state.selection);

    try std.testing.expect((WidgetKeyboardEvent{ .phase = .text_input, .text = "a", .modifiers = .{ .super = true } }).textEditEvent() == null);
    try std.testing.expect((WidgetKeyboardEvent{ .phase = .key_down, .key = "arrowleft", .modifiers = .{ .alt = true, .control = true } }).textEditEvent() == null);
    try std.testing.expect((WidgetKeyboardEvent{ .phase = .key_down, .key = "backspace", .modifiers = .{ .alt = true, .control = true } }).textEditEvent() == null);
    try std.testing.expect((WidgetKeyboardEvent{ .phase = .key_down, .key = "a", .modifiers = .{ .super = true, .shift = true } }).textEditEvent() == null);
    try std.testing.expect((WidgetKeyboardEvent{ .phase = .key_up, .key = "backspace" }).textEditEvent() == null);
}

test "text edit state tracks ime composition ranges" {
    var storage_a: [64]u8 = undefined;
    var storage_b: [64]u8 = undefined;
    var state = TextEditState.init("hello");

    state = try state.apply(.{ .set_selection = .{ .anchor = 1, .focus = 4 } }, &storage_a);
    state = try state.apply(.{ .set_composition = .{ .text = "é", .cursor = 2 } }, &storage_a);
    try std.testing.expectEqualStrings("héo", state.text);
    try std.testing.expectEqualDeep(TextRange.init(1, 3), state.composition.?);
    try std.testing.expectEqual(@as(usize, 3), state.selection.focus);

    state = try state.apply(.commit_composition, &storage_b);
    try std.testing.expectEqualStrings("héo", state.text);
    try std.testing.expect(state.composition == null);

    state = try state.apply(.{ .set_composition = .{ .text = "ll", .cursor = 2 } }, &storage_b);
    try std.testing.expectEqualStrings("héllo", state.text);
    state = try state.apply(.cancel_composition, &storage_a);
    try std.testing.expectEqualStrings("héo", state.text);
    try std.testing.expectEqual(@as(usize, 3), state.selection.focus);
    try std.testing.expect(state.composition == null);
}

test "text bounds follow utf8 scalar fallback and shaped y offsets" {
    // Metric boxes inflate by the ink allowance (left/bottom 0.1em,
    // right 0.35em) so real glyph outlines never clip at the bounds.
    try expectRectApprox(geometry.RectF.init(1, 8, 19.47, 13.5), textBounds(.{
        .font_id = 1,
        .size = 10,
        .origin = geometry.PointF.init(2, 18),
        .color = Color.rgb8(0, 0, 0),
        .text = "é B",
    }));

    const glyphs = [_]Glyph{
        .{ .id = 1, .x = 0, .y = -2, .advance = 6 },
        .{ .id = 2, .x = 8, .y = 3, .advance = 5 },
    };
    try expectRect(geometry.RectF.init(3, 8, 17.5, 18.5), textBounds(.{
        .font_id = 1,
        .size = 10,
        .origin = geometry.PointF.init(4, 20),
        .color = Color.rgb8(0, 0, 0),
        .glyphs = &glyphs,
    }));
}

test "text bounds and reference renderer honor per-run wrapping" {
    const text = DrawText{
        .font_id = 1,
        .size = 10,
        .origin = geometry.PointF.init(0, 10),
        .color = Color.rgb8(255, 255, 255),
        .text = "ABCD",
        .text_layout = .{ .max_width = 10, .line_height = 12, .wrap = .character },
    };
    // Metric box (0, 0, 7.11, 48) plus the ink allowance.
    try expectRectApprox(geometry.RectF.init(-1, 0, 11.61, 49), textBounds(text));

    const commands = [_]CanvasCommand{.{ .draw_text = text }};
    var render_commands: [1]RenderCommand = undefined;
    const render_plan = try (DisplayList{ .commands = &commands }).renderPlan(&render_commands);
    try std.testing.expectEqual(@as(usize, 1), render_plan.commandCount());
    try expectRectApprox(geometry.RectF.init(-1, 0, 11.61, 49), render_plan.commands[0].bounds);

    var pixels: [16 * 32 * 4]u8 = [_]u8{0} ** (16 * 32 * 4);
    const surface = try ReferenceRenderSurface.init(16, 32, &pixels);
    try surface.renderPass(.{
        .commands = render_plan.commands,
        .surface_size = geometry.SizeF.init(16, 32),
        .full_repaint = true,
    }, Color.rgb8(0, 0, 0));
    // Real Geist outlines replaced block glyphs: line one's 'A' inks
    // from cap height (row 3) down to the baseline at row 10, and line
    // two's 'B' from row 15 under the 12px line advance; the sampled
    // pixels sit on anti-aliased stem edges.
    try expectPixelRgba8([4]u8{ 225, 225, 225, 255 }, surface, 1, 7);
    try expectPixelRgba8([4]u8{ 0, 0, 0, 255 }, surface, 1, 1);
    try expectPixelRgba8([4]u8{ 241, 241, 241, 255 }, surface, 1, 15);
}

test "text layout wraps words into deterministic line boxes" {
    const text = DrawText{
        .font_id = 1,
        .size = 10,
        .origin = geometry.PointF.init(4, 20),
        .color = Color.rgb8(0, 0, 0),
        .text = "Hello world from zero",
    };

    var lines: [4]TextLine = undefined;
    const plan = try layoutTextRunPlan(text, .{ .max_width = 30, .line_height = 14, .wrap = .word }, &lines);
    const layout = plan.layout;
    try std.testing.expectEqual(@as(FontId, 1), plan.key.font_id);
    try std.testing.expectEqual(@as(f32, 10), plan.key.size);
    try std.testing.expectEqual(@as(f32, 30), plan.key.max_width);
    try std.testing.expectEqual(@as(f32, 14), plan.key.line_height);
    try std.testing.expectEqual(TextWrap.word, plan.key.wrap);
    try std.testing.expectEqual(TextAlign.start, plan.key.alignment);
    try std.testing.expectEqual(text.text.len, plan.key.text_len);
    try std.testing.expectEqual(@as(usize, 0), plan.key.glyph_count);
    try std.testing.expect(plan.key.fingerprint != 0);
    try std.testing.expectEqual(@as(usize, 4), layout.lineCount());
    try std.testing.expectEqual(@as(usize, 0), layout.lines[0].text_start);
    try std.testing.expectEqual(@as(usize, 5), layout.lines[0].text_len);
    try expectRectApprox(geometry.RectF.init(4, 10, 24.25, 14), layout.lines[0].bounds);
    try std.testing.expectEqual(@as(usize, 6), layout.lines[1].text_start);
    try std.testing.expectEqual(@as(usize, 5), layout.lines[1].text_len);
    try std.testing.expectEqual(@as(f32, 34), layout.lines[1].baseline);
    try std.testing.expectEqual(@as(usize, 12), layout.lines[2].text_start);
    try std.testing.expectEqual(@as(usize, 4), layout.lines[2].text_len);
    try std.testing.expectEqual(@as(usize, 17), layout.lines[3].text_start);
    try std.testing.expectEqual(@as(usize, 4), layout.lines[3].text_len);
    try expectRectApprox(geometry.RectF.init(4, 10, 26.61, 56), layout.bounds);
}

test "text layout aligns fallback and shaped line boxes" {
    const text = DrawText{
        .font_id = 1,
        .size = 10,
        .origin = geometry.PointF.init(4, 20),
        .color = Color.rgb8(0, 0, 0),
        .text = "Hi",
    };

    var center_lines: [1]TextLine = undefined;
    const centered = try layoutTextRunPlan(text, .{ .max_width = 30, .line_height = 14, .alignment = .center }, &center_lines);
    try std.testing.expectEqual(TextAlign.center, centered.key.alignment);
    try expectRectApprox(geometry.RectF.init(14.215, 10, 9.57, 14), centered.layout.lines[0].bounds);
    try expectRectApprox(geometry.RectF.init(14.215, 10, 9.57, 14), centered.layout.bounds);

    var end_lines: [1]TextLine = undefined;
    const end = try layoutTextRun(text, .{ .max_width = 30, .line_height = 14, .alignment = .end }, &end_lines);
    try expectRectApprox(geometry.RectF.init(24.43, 10, 9.57, 14), end.lines[0].bounds);

    const glyphs = [_]Glyph{
        .{ .id = 1, .x = 0, .y = 0, .advance = 8 },
        .{ .id = 2, .x = 8, .y = 0, .advance = 4 },
    };
    var shaped_lines: [1]TextLine = undefined;
    const shaped = try layoutTextRun(.{
        .font_id = 2,
        .size = 10,
        .origin = geometry.PointF.init(4, 20),
        .color = Color.rgb8(0, 0, 0),
        .text = "AV",
        .glyphs = &glyphs,
    }, .{ .max_width = 20, .line_height = 14, .alignment = .center }, &shaped_lines);

    try expectRect(geometry.RectF.init(8, 10, 12, 14), shaped.lines[0].bounds);
    try expectRect(geometry.RectF.init(8, 10, 12, 14), shaped.bounds);
}

test "text layout maps caret selection and points across wrapped fallback lines" {
    const text = DrawText{
        .font_id = 1,
        .size = 10,
        .origin = geometry.PointF.init(4, 20),
        .color = Color.rgb8(0, 0, 0),
        .text = "Hello world",
    };
    const options = TextLayoutOptions{ .max_width = 30, .line_height = 14, .wrap = .word };

    var caret_lines: [2]TextLine = undefined;
    try expectRectApprox(geometry.RectF.init(28.25, 10, 1, 14), try layoutTextCaretRect(text, options, 5, &caret_lines));

    var selection_lines: [2]TextLine = undefined;
    var selection_rects: [2]TextSelectionRect = undefined;
    const rects = try layoutTextSelectionRects(text, options, TextRange.init(3, 8), &selection_lines, &selection_rects);
    try std.testing.expectEqual(@as(usize, 2), rects.len);
    try std.testing.expectEqualDeep(TextRange.init(3, 5), rects[0].range);
    try expectRectApprox(geometry.RectF.init(19.63, 10, 8.62, 14), rects[0].rect);
    try std.testing.expectEqualDeep(TextRange.init(6, 8), rects[1].range);
    try expectRectApprox(geometry.RectF.init(4, 24, 13.98, 14), rects[1].rect);

    const dashboard_value = DrawText{
        .font_id = default_sans_font_id,
        .size = 17,
        .origin = geometry.PointF.init(0, 17),
        .color = Color.rgb8(0, 0, 0),
        .text = "$13.4M",
    };
    var dashboard_value_lines: [1]TextLine = undefined;
    try expectRectApprox(
        geometry.RectF.init(57.001, 0, 1, 21.25),
        try layoutTextCaretRect(dashboard_value, .{ .line_height = 21.25 }, dashboard_value.text.len, &dashboard_value_lines),
    );

    var point_lines: [2]TextLine = undefined;
    const offset = (try layoutTextOffsetForPoint(text, options, geometry.PointF.init(16, 25), &point_lines)).?;
    try std.testing.expectEqual(@as(usize, 8), offset);

    var overflow_lines: [2]TextLine = undefined;
    var one_rect: [1]TextSelectionRect = undefined;
    try std.testing.expectError(error.TextSelectionRectListFull, layoutTextSelectionRects(text, options, TextRange.init(3, 8), &overflow_lines, &one_rect));
}

test "text layout maps caret selection and points across shaped glyph lines" {
    const glyphs = [_]Glyph{
        .{ .id = 1, .x = 2, .y = -3, .advance = 5 },
        .{ .id = 2, .x = 6, .y = 4, .advance = 4 },
    };
    const text = DrawText{
        .font_id = 2,
        .size = 10,
        .origin = geometry.PointF.init(10, 20),
        .color = Color.rgb8(255, 255, 255),
        .text = "AV",
        .glyphs = &glyphs,
    };
    const options = TextLayoutOptions{ .line_height = 12 };

    var caret_lines: [1]TextLine = undefined;
    try expectRect(geometry.RectF.init(14, 7, 1, 19.5), try layoutTextCaretRect(text, options, 1, &caret_lines));

    var selection_lines: [1]TextLine = undefined;
    var selection_rects: [1]TextSelectionRect = undefined;
    const rects = try layoutTextSelectionRects(text, options, TextRange.init(1, 2), &selection_lines, &selection_rects);
    try std.testing.expectEqual(@as(usize, 1), rects.len);
    try expectRect(geometry.RectF.init(14, 7, 4, 19.5), rects[0].rect);

    var point_lines: [1]TextLine = undefined;
    const offset = (try layoutTextOffsetForPoint(text, options, geometry.PointF.init(13, 12), &point_lines)).?;
    try std.testing.expectEqual(@as(usize, 1), offset);

    const commands = [_]CanvasCommand{.{ .draw_text = .{
        .font_id = text.font_id,
        .size = text.size,
        .origin = text.origin,
        .color = text.color,
        .text = text.text,
        .glyphs = text.glyphs,
        .text_layout = options,
    } }};
    var render_commands: [1]RenderCommand = undefined;
    const render_plan = try (DisplayList{ .commands = &commands }).renderPlan(&render_commands);
    var pixels: [24 * 32 * 4]u8 = [_]u8{0} ** (24 * 32 * 4);
    const surface = try ReferenceRenderSurface.init(24, 32, &pixels);
    try surface.renderPass(.{
        .commands = render_plan.commands,
        .surface_size = geometry.SizeF.init(24, 32),
        .full_repaint = true,
    }, Color.rgb8(0, 0, 0));
    try expectPixelRgba8([4]u8{ 255, 255, 255, 255 }, surface, 10, 8);
}

test "text layout maps caret selection and points through glyph text clusters" {
    const glyphs = [_]Glyph{
        .{ .id = 'o', .x = 0, .y = 0, .advance = 6, .text_start = 0, .text_len = 1 },
        .{ .id = 1001, .x = 6, .y = 0, .advance = 18, .text_start = 1, .text_len = 3 },
        .{ .id = 'c', .x = 24, .y = 0, .advance = 5, .text_start = 4, .text_len = 1 },
        .{ .id = 'e', .x = 29, .y = 0, .advance = 7, .text_start = 5, .text_len = 1 },
    };
    const text = DrawText{
        .font_id = 2,
        .size = 10,
        .origin = geometry.PointF.init(10, 20),
        .color = Color.rgb8(255, 255, 255),
        .text = "office",
        .glyphs = &glyphs,
    };
    const options = TextLayoutOptions{ .line_height = 12 };

    var layout_lines: [1]TextLine = undefined;
    const layout = try layoutTextRun(text, options, &layout_lines);
    try std.testing.expectEqualDeep(TextRange.init(0, 6), textLineRange(text, layout.lines[0]));

    var caret_lines: [1]TextLine = undefined;
    try expectRectApprox(geometry.RectF.init(16, 10, 1, 12.5), try layoutTextCaretRect(text, options, 1, &caret_lines));
    try expectRectApprox(geometry.RectF.init(22, 10, 1, 12.5), try layoutTextCaretRect(text, options, 2, &caret_lines));
    try expectRectApprox(geometry.RectF.init(28, 10, 1, 12.5), try layoutTextCaretRect(text, options, 3, &caret_lines));
    try expectRectApprox(geometry.RectF.init(34, 10, 1, 12.5), try layoutTextCaretRect(text, options, 4, &caret_lines));

    var selection_lines: [1]TextLine = undefined;
    var selection_rects: [1]TextSelectionRect = undefined;
    const rects = try layoutTextSelectionRects(text, options, TextRange.init(1, 4), &selection_lines, &selection_rects);
    try std.testing.expectEqual(@as(usize, 1), rects.len);
    try std.testing.expectEqualDeep(TextRange.init(1, 4), rects[0].range);
    try expectRectApprox(geometry.RectF.init(16, 10, 18, 12.5), rects[0].rect);

    var point_lines: [1]TextLine = undefined;
    try std.testing.expectEqual(@as(usize, 2), (try layoutTextOffsetForPoint(text, options, geometry.PointF.init(21, 15), &point_lines)).?);
    try std.testing.expectEqual(@as(usize, 3), (try layoutTextOffsetForPoint(text, options, geometry.PointF.init(27, 15), &point_lines)).?);
    try std.testing.expectEqual(@as(usize, 4), (try layoutTextOffsetForPoint(text, options, geometry.PointF.init(33.5, 15), &point_lines)).?);
}

test "text layout measures utf8 scalars for fallback wrapping" {
    const text = DrawText{
        .font_id = 1,
        .size = 10,
        .origin = geometry.PointF.init(2, 18),
        .color = Color.rgb8(0, 0, 0),
        .text = "éééé éé",
    };

    // é measures at the face's real 0.567 em advance, so "éééé" splits
    // after three scalars and the remaining "é éé" fits one line.
    var lines: [3]TextLine = undefined;
    const layout = try layoutTextRun(text, .{ .max_width = 20, .line_height = 12, .wrap = .word }, &lines);
    try std.testing.expectEqual(@as(usize, 2), layout.lineCount());
    try std.testing.expectEqual(@as(usize, 0), layout.lines[0].text_start);
    try std.testing.expectEqual(@as(usize, 6), layout.lines[0].text_len);
    try expectRectApprox(geometry.RectF.init(2, 8, 17.01, 12), layout.lines[0].bounds);
    try std.testing.expectEqual(@as(usize, 6), layout.lines[1].text_start);
    try std.testing.expectEqual(@as(usize, 7), layout.lines[1].text_len);
    try expectRectApprox(geometry.RectF.init(2, 20, 19.51, 12), layout.lines[1].bounds);
    try expectRectApprox(geometry.RectF.init(2, 8, 19.51, 24), layout.bounds);

    var character_lines: [3]TextLine = undefined;
    const character_layout = try layoutTextRun(.{
        .font_id = 1,
        .size = 10,
        .origin = geometry.PointF.init(0, 10),
        .color = Color.rgb8(0, 0, 0),
        .text = "ééé",
    }, .{ .max_width = 10, .line_height = 12, .wrap = .character }, &character_lines);
    try std.testing.expectEqual(@as(usize, 3), character_layout.lineCount());
    try std.testing.expectEqual(@as(usize, 0), character_layout.lines[0].text_start);
    try std.testing.expectEqual(@as(usize, 2), character_layout.lines[0].text_len);
    try std.testing.expectEqual(@as(usize, 2), character_layout.lines[1].text_start);
    try std.testing.expectEqual(@as(usize, 2), character_layout.lines[1].text_len);
    try std.testing.expectEqual(@as(usize, 4), character_layout.lines[2].text_start);
    try std.testing.expectEqual(@as(usize, 2), character_layout.lines[2].text_len);
}

test "text layout cache plans upload retain and evict work" {
    const text = DrawText{
        .font_id = 1,
        .size = 10,
        .origin = geometry.PointF.init(4, 20),
        .color = Color.rgb8(0, 0, 0),
        .text = "Hello world from zero",
    };

    var lines: [4]TextLine = undefined;
    const plan = try layoutTextRunPlan(text, .{ .max_width = 30, .line_height = 14, .wrap = .word }, &lines);
    var entries: [1]TextLayoutCacheEntry = undefined;
    var actions: [1]TextLayoutCacheAction = undefined;
    const first = try plan.cachePlan(&.{}, 1, &entries, &actions);
    try std.testing.expectEqual(@as(usize, 1), first.entryCount());
    try std.testing.expectEqual(@as(usize, 1), first.uploadCount());
    try std.testing.expectEqual(@as(usize, 0), first.retainCount());
    try std.testing.expectEqual(@as(usize, 0), first.evictCount());
    try std.testing.expectEqual(@as(usize, 4), first.entries[0].line_count);
    try std.testing.expectEqual(@as(u64, 1), first.entries[0].last_used_frame);
    try expectRectApprox(geometry.RectF.init(4, 10, 26.61, 56), first.entries[0].bounds);
    try std.testing.expectEqual(TextLayoutCacheActionKind.upload, first.actions[0].kind);

    var retained_entries: [1]TextLayoutCacheEntry = undefined;
    var retained_actions: [1]TextLayoutCacheAction = undefined;
    const retained = try plan.cachePlan(first.entries, 2, &retained_entries, &retained_actions);
    try std.testing.expectEqual(@as(usize, 1), retained.entryCount());
    try std.testing.expectEqual(@as(usize, 0), retained.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), retained.retainCount());
    try std.testing.expectEqual(@as(usize, 0), retained.evictCount());
    try std.testing.expectEqual(@as(u64, 2), retained.entries[0].last_used_frame);
    try std.testing.expectEqual(@as(?usize, 0), retained.actions[0].layout_index);
    try std.testing.expectEqual(@as(?usize, 0), retained.actions[0].cache_index);

    var changed_lines: [4]TextLine = undefined;
    const changed_plan = try layoutTextRunPlan(text, .{ .max_width = 30, .line_height = 14, .wrap = .word, .alignment = .center }, &changed_lines);
    var changed_entries: [1]TextLayoutCacheEntry = undefined;
    var changed_actions: [2]TextLayoutCacheAction = undefined;
    const changed = try changed_plan.cachePlan(retained.entries, 3, &changed_entries, &changed_actions);
    try std.testing.expectEqual(@as(usize, 1), changed.entryCount());
    try std.testing.expectEqual(@as(usize, 1), changed.uploadCount());
    try std.testing.expectEqual(@as(usize, 0), changed.retainCount());
    try std.testing.expectEqual(@as(usize, 1), changed.evictCount());
    try std.testing.expectEqual(TextAlign.center, changed.entries[0].key.alignment);
    try std.testing.expectEqual(TextLayoutCacheActionKind.upload, changed.actions[0].kind);
    try std.testing.expectEqual(@as(?usize, 0), changed.actions[0].layout_index);
    try std.testing.expectEqual(TextLayoutCacheActionKind.evict, changed.actions[1].kind);
    try std.testing.expect(changed.actions[1].layout_index == null);
    try std.testing.expectEqual(@as(?usize, 0), changed.actions[1].cache_index);
}

test "display list text layout plan caches multiple text runs" {
    const commands = [_]CanvasCommand{
        .{ .draw_text = .{
            .id = 1,
            .font_id = 1,
            .size = 10,
            .origin = geometry.PointF.init(0, 10),
            .color = Color.rgb8(0, 0, 0),
            .text = "Alpha",
        } },
        .{ .draw_text = .{
            .id = 2,
            .font_id = 1,
            .size = 10,
            .origin = geometry.PointF.init(0, 28),
            .color = Color.rgb8(0, 0, 0),
            .text = "Beta",
        } },
    };

    var plans: [2]TextLayoutPlan = undefined;
    var lines: [2]TextLine = undefined;
    const plan_set = try (DisplayList{ .commands = &commands }).textLayoutPlan(.{}, &plans, &lines);
    try std.testing.expectEqual(@as(usize, 2), plan_set.planCount());
    try std.testing.expectEqual(@as(usize, 2), plan_set.lineCount());
    try std.testing.expect(plan_set.plans[0].key.fingerprint != plan_set.plans[1].key.fingerprint);

    var entries: [2]TextLayoutCacheEntry = undefined;
    var actions: [2]TextLayoutCacheAction = undefined;
    const first = try plan_set.cachePlan(&.{}, 1, &entries, &actions);
    try std.testing.expectEqual(@as(usize, 2), first.uploadCount());
    try std.testing.expectEqual(@as(?usize, 0), first.actions[0].layout_index);
    try std.testing.expectEqual(@as(?usize, 1), first.actions[1].layout_index);

    var retained_entries: [2]TextLayoutCacheEntry = undefined;
    var retained_actions: [2]TextLayoutCacheAction = undefined;
    const retained = try plan_set.cachePlan(first.entries, 2, &retained_entries, &retained_actions);
    try std.testing.expectEqual(@as(usize, 2), retained.retainCount());
    try std.testing.expectEqual(@as(usize, 0), retained.evictCount());
}

test "text layout cache keeps recent unused layouts warm" {
    const commands = [_]CanvasCommand{
        .{ .draw_text = .{
            .id = 1,
            .font_id = 1,
            .size = 10,
            .origin = geometry.PointF.init(0, 10),
            .color = Color.rgb8(0, 0, 0),
            .text = "Alpha",
        } },
        .{ .draw_text = .{
            .id = 2,
            .font_id = 1,
            .size = 10,
            .origin = geometry.PointF.init(0, 28),
            .color = Color.rgb8(0, 0, 0),
            .text = "Beta",
        } },
    };

    var plans: [2]TextLayoutPlan = undefined;
    var lines: [2]TextLine = undefined;
    const plan_set = try (DisplayList{ .commands = &commands }).textLayoutPlan(.{}, &plans, &lines);

    var first_entries: [2]TextLayoutCacheEntry = undefined;
    var first_actions: [2]TextLayoutCacheAction = undefined;
    const first = try plan_set.cachePlanWithRetention(&.{}, 1, 2, &first_entries, &first_actions);
    try std.testing.expectEqual(@as(usize, 2), first.uploadCount());

    const visible_plan_set = TextLayoutPlanSet{ .plans = plan_set.plans[0..1] };
    var warm_entries: [2]TextLayoutCacheEntry = undefined;
    var warm_actions: [2]TextLayoutCacheAction = undefined;
    const warm = try visible_plan_set.cachePlanWithRetention(first.entries, 2, 2, &warm_entries, &warm_actions);
    try std.testing.expectEqual(@as(usize, 2), warm.entryCount());
    try std.testing.expectEqual(@as(usize, 0), warm.uploadCount());
    try std.testing.expectEqual(@as(usize, 2), warm.retainCount());
    try std.testing.expectEqual(@as(usize, 0), warm.evictCount());
    try std.testing.expectEqual(@as(u64, 2), warm.entries[0].last_used_frame);
    try std.testing.expectEqual(@as(u64, 1), warm.entries[1].last_used_frame);
    try std.testing.expectEqual(@as(?usize, 0), warm.actions[0].layout_index);
    try std.testing.expectEqual(@as(?usize, 0), warm.actions[0].cache_index);
    try std.testing.expect(warm.actions[1].layout_index == null);
    try std.testing.expectEqual(@as(?usize, 1), warm.actions[1].cache_index);

    var stale_entries: [2]TextLayoutCacheEntry = undefined;
    var stale_actions: [2]TextLayoutCacheAction = undefined;
    const stale = try visible_plan_set.cachePlanWithRetention(first.entries, 4, 2, &stale_entries, &stale_actions);
    try std.testing.expectEqual(@as(usize, 1), stale.entryCount());
    try std.testing.expectEqual(@as(usize, 1), stale.retainCount());
    try std.testing.expectEqual(@as(usize, 1), stale.evictCount());
    try std.testing.expectEqual(TextLayoutCacheActionKind.evict, stale.actions[1].kind);
    try std.testing.expect(stale.actions[1].layout_index == null);
    try std.testing.expectEqual(@as(?usize, 1), stale.actions[1].cache_index);
}

test "display list text layout plan honors per-run options" {
    const commands = [_]CanvasCommand{
        .{ .draw_text = .{
            .id = 1,
            .font_id = 1,
            .size = 10,
            .origin = geometry.PointF.init(2, 18),
            .color = Color.rgb8(0, 0, 0),
            .text = "Alpha beta",
            .text_layout = .{ .max_width = 30, .line_height = 14, .wrap = .word, .alignment = .end },
        } },
        .{ .draw_text = .{
            .id = 2,
            .font_id = 1,
            .size = 10,
            .origin = geometry.PointF.init(2, 42),
            .color = Color.rgb8(0, 0, 0),
            .text = "Gamma",
        } },
    };

    var plans: [2]TextLayoutPlan = undefined;
    var lines: [4]TextLine = undefined;
    const plan_set = try (DisplayList{ .commands = &commands }).textLayoutPlan(.{ .max_width = 80, .line_height = 20, .alignment = .center }, &plans, &lines);
    try std.testing.expectEqual(@as(usize, 2), plan_set.planCount());
    try std.testing.expectEqual(@as(f32, 30), plan_set.plans[0].key.max_width);
    try std.testing.expectEqual(@as(f32, 14), plan_set.plans[0].key.line_height);
    try std.testing.expectEqual(TextAlign.end, plan_set.plans[0].key.alignment);
    try std.testing.expectEqual(@as(f32, 80), plan_set.plans[1].key.max_width);
    try std.testing.expectEqual(@as(f32, 20), plan_set.plans[1].key.line_height);
    try std.testing.expectEqual(TextAlign.center, plan_set.plans[1].key.alignment);
    try std.testing.expect(plan_set.plans[0].key.fingerprint != plan_set.plans[1].key.fingerprint);
}

test "text layout cache reports capacity overflow" {
    const text = DrawText{
        .font_id = 1,
        .size = 10,
        .origin = geometry.PointF.init(0, 10),
        .color = Color.rgb8(0, 0, 0),
        .text = "Hello",
    };
    var lines: [1]TextLine = undefined;
    const plan = try layoutTextRunPlan(text, .{}, &lines);

    var no_entries: [0]TextLayoutCacheEntry = .{};
    var actions: [1]TextLayoutCacheAction = undefined;
    try std.testing.expectError(error.TextLayoutCacheListFull, plan.cachePlan(&.{}, 1, &no_entries, &actions));

    var entries: [1]TextLayoutCacheEntry = undefined;
    var no_actions: [0]TextLayoutCacheAction = .{};
    try std.testing.expectError(error.TextLayoutCacheListFull, plan.cachePlan(&.{}, 1, &entries, &no_actions));
}

test "text layout handles newlines and shaped glyph runs" {
    const text = DrawText{
        .font_id = 1,
        .size = 12,
        .origin = geometry.PointF.init(0, 12),
        .color = Color.rgb8(0, 0, 0),
        .text = "One\nTwo",
    };
    var lines: [2]TextLine = undefined;
    const layout = try layoutTextRun(text, .{ .line_height = 16, .wrap = .none }, &lines);
    try std.testing.expectEqual(@as(usize, 2), layout.lineCount());
    try std.testing.expectEqual(@as(usize, 0), layout.lines[0].text_start);
    try std.testing.expectEqual(@as(usize, 3), layout.lines[0].text_len);
    try std.testing.expectEqual(@as(usize, 4), layout.lines[1].text_start);
    try std.testing.expectEqual(@as(usize, 3), layout.lines[1].text_len);
    try std.testing.expectEqual(@as(f32, 28), layout.lines[1].baseline);

    const trailing = DrawText{
        .font_id = 1,
        .size = 12,
        .origin = geometry.PointF.init(0, 12),
        .color = Color.rgb8(0, 0, 0),
        .text = "One\n",
    };
    var trailing_lines: [2]TextLine = undefined;
    const trailing_layout = try layoutTextRun(trailing, .{ .line_height = 16, .wrap = .none }, &trailing_lines);
    try std.testing.expectEqual(@as(usize, 2), trailing_layout.lineCount());
    try std.testing.expectEqual(@as(usize, 4), trailing_layout.lines[1].text_start);
    try std.testing.expectEqual(@as(usize, 0), trailing_layout.lines[1].text_len);
    try std.testing.expectEqual(@as(f32, 28), trailing_layout.lines[1].baseline);

    const blank = DrawText{
        .font_id = 1,
        .size = 12,
        .origin = geometry.PointF.init(0, 12),
        .color = Color.rgb8(0, 0, 0),
        .text = "One\n\nTwo",
    };
    var blank_lines: [3]TextLine = undefined;
    const blank_layout = try layoutTextRun(blank, .{ .line_height = 16, .wrap = .none }, &blank_lines);
    try std.testing.expectEqual(@as(usize, 3), blank_layout.lineCount());
    try std.testing.expectEqual(@as(usize, 4), blank_layout.lines[1].text_start);
    try std.testing.expectEqual(@as(usize, 0), blank_layout.lines[1].text_len);
    try std.testing.expectEqual(@as(usize, 5), blank_layout.lines[2].text_start);

    const glyphs = [_]Glyph{
        .{ .id = 1, .x = 0, .y = 0, .advance = 9 },
        .{ .id = 2, .x = 9, .y = 0, .advance = 10 },
    };
    var shaped_lines: [1]TextLine = undefined;
    const shaped = try layoutTextRun(.{
        .font_id = 2,
        .size = 14,
        .origin = geometry.PointF.init(3, 18),
        .color = Color.rgb8(0, 0, 0),
        .text = "AV",
        .glyphs = &glyphs,
    }, .{ .line_height = 20 }, &shaped_lines);
    try std.testing.expectEqual(@as(usize, 1), shaped.lineCount());
    try std.testing.expectEqual(@as(usize, 2), shaped.lines[0].glyph_len);
    try expectRect(geometry.RectF.init(3, 4, 19, 20), shaped.lines[0].bounds);
}

test "text layout bounds shaped glyph positions and vertical offsets" {
    const glyphs = [_]Glyph{
        .{ .id = 1, .x = 2, .y = -3, .advance = 5 },
        .{ .id = 2, .x = 6, .y = 4, .advance = 4 },
    };
    var lines: [1]TextLine = undefined;
    const layout = try layoutTextRun(.{
        .font_id = 2,
        .size = 10,
        .origin = geometry.PointF.init(10, 20),
        .color = Color.rgb8(0, 0, 0),
        .text = "AV",
        .glyphs = &glyphs,
    }, .{ .line_height = 12 }, &lines);

    try std.testing.expectEqual(@as(usize, 1), layout.lineCount());
    try expectRect(geometry.RectF.init(10, 7, 8, 19.5), layout.lines[0].bounds);
    try expectRect(geometry.RectF.init(10, 7, 8, 19.5), layout.bounds);
}

test "text layout wraps shaped glyph runs by glyph advances" {
    const glyphs = [_]Glyph{
        .{ .id = 1, .x = 0, .y = 0, .advance = 8 },
        .{ .id = 2, .x = 8, .y = 0, .advance = 7 },
        .{ .id = 3, .x = 15, .y = 0, .advance = 6 },
        .{ .id = 4, .x = 21, .y = 0, .advance = 9 },
        .{ .id = 5, .x = 30, .y = 0, .advance = 5 },
    };
    var lines: [3]TextLine = undefined;
    const layout = try layoutTextRun(.{
        .font_id = 2,
        .size = 12,
        .origin = geometry.PointF.init(4, 20),
        .color = Color.rgb8(0, 0, 0),
        .text = "abcde",
        .glyphs = &glyphs,
    }, .{ .max_width = 16, .line_height = 18, .wrap = .character }, &lines);

    try std.testing.expectEqual(@as(usize, 3), layout.lineCount());
    try std.testing.expectEqual(@as(usize, 0), layout.lines[0].glyph_start);
    try std.testing.expectEqual(@as(usize, 2), layout.lines[0].glyph_len);
    try std.testing.expectEqual(@as(usize, 0), layout.lines[0].text_start);
    try std.testing.expectEqual(@as(usize, 2), layout.lines[0].text_len);
    try expectRect(geometry.RectF.init(4, 8, 15, 18), layout.lines[0].bounds);
    try std.testing.expectEqual(@as(usize, 2), layout.lines[1].glyph_start);
    try std.testing.expectEqual(@as(usize, 2), layout.lines[1].glyph_len);
    try std.testing.expectEqual(@as(usize, 2), layout.lines[1].text_start);
    try std.testing.expectEqual(@as(usize, 2), layout.lines[1].text_len);
    try std.testing.expectEqual(@as(f32, 38), layout.lines[1].baseline);
    try std.testing.expectEqual(@as(usize, 4), layout.lines[2].glyph_start);
    try std.testing.expectEqual(@as(usize, 1), layout.lines[2].glyph_len);
    try std.testing.expectEqual(@as(usize, 4), layout.lines[2].text_start);
    try std.testing.expectEqual(@as(usize, 1), layout.lines[2].text_len);
    try expectRect(geometry.RectF.init(4, 8, 15, 54), layout.bounds);
}

test "text layout word-wraps shaped glyph runs at mapped spaces" {
    const glyphs = [_]Glyph{
        .{ .id = 1, .x = 0, .y = 0, .advance = 5 },
        .{ .id = 2, .x = 5, .y = 0, .advance = 5 },
        .{ .id = 3, .x = 10, .y = 0, .advance = 5 },
        .{ .id = 4, .x = 15, .y = 0, .advance = 5 },
        .{ .id = 5, .x = 20, .y = 0, .advance = 5 },
        .{ .id = 6, .x = 25, .y = 0, .advance = 5 },
    };
    var lines: [2]TextLine = undefined;
    const layout = try layoutTextRun(.{
        .font_id = 2,
        .size = 10,
        .origin = geometry.PointF.init(0, 10),
        .color = Color.rgb8(0, 0, 0),
        .text = "Hi all",
        .glyphs = &glyphs,
    }, .{ .max_width = 16, .line_height = 14, .wrap = .word }, &lines);

    try std.testing.expectEqual(@as(usize, 2), layout.lineCount());
    try std.testing.expectEqual(@as(usize, 0), layout.lines[0].glyph_start);
    try std.testing.expectEqual(@as(usize, 2), layout.lines[0].glyph_len);
    try std.testing.expectEqual(@as(usize, 0), layout.lines[0].text_start);
    try std.testing.expectEqual(@as(usize, 2), layout.lines[0].text_len);
    try expectRect(geometry.RectF.init(0, 0, 10, 14), layout.lines[0].bounds);
    try std.testing.expectEqual(@as(usize, 3), layout.lines[1].glyph_start);
    try std.testing.expectEqual(@as(usize, 3), layout.lines[1].glyph_len);
    try std.testing.expectEqual(@as(usize, 3), layout.lines[1].text_start);
    try std.testing.expectEqual(@as(usize, 3), layout.lines[1].text_len);
    try expectRect(geometry.RectF.init(0, 14, 15, 14), layout.lines[1].bounds);
    try expectRect(geometry.RectF.init(0, 0, 15, 28), layout.bounds);
}

test "text layout keeps an empty line for shaped whitespace runs" {
    const glyphs = [_]Glyph{
        .{ .id = 1, .x = 0, .y = 0, .advance = 5 },
        .{ .id = 2, .x = 5, .y = 0, .advance = 5 },
    };
    var lines: [1]TextLine = undefined;
    const layout = try layoutTextRun(.{
        .font_id = 2,
        .size = 10,
        .origin = geometry.PointF.init(0, 10),
        .color = Color.rgb8(0, 0, 0),
        .text = "  ",
        .glyphs = &glyphs,
    }, .{ .max_width = 16, .line_height = 14, .wrap = .word }, &lines);

    try std.testing.expectEqual(@as(usize, 1), layout.lineCount());
    try std.testing.expectEqual(@as(usize, 0), layout.lines[0].glyph_len);
    try std.testing.expectEqual(@as(usize, 0), layout.lines[0].text_len);
    try expectRect(geometry.RectF.init(0, 0, 0, 14), layout.bounds);
}

test "text layout reports output overflow" {
    var lines: [0]TextLine = .{};
    try std.testing.expectError(error.TextLayoutLineListFull, layoutTextRun(.{
        .size = 10,
        .origin = geometry.PointF.init(0, 10),
        .color = Color.rgb8(0, 0, 0),
        .text = "Hello",
    }, .{}, &lines));
}

test "display list serializes deterministic Phase 2 primitives" {
    const stops = [_]GradientStop{
        .{ .offset = 0, .color = Color.rgb8(255, 255, 255) },
        .{ .offset = 1, .color = Color.rgb8(0, 0, 0) },
    };
    const glyphs = [_]Glyph{
        .{ .id = 42, .x = 12, .y = 28, .advance = 9 },
        .{ .id = 43, .x = 21, .y = 28, .advance = 8 },
    };
    const path = [_]PathElement{
        .{ .verb = .move_to, .points = .{ geometry.PointF.init(180, 120), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(212, 104), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .quad_to, .points = .{ geometry.PointF.init(228, 116), geometry.PointF.init(220, 136), geometry.PointF.zero() } },
        .{ .verb = .cubic_to, .points = .{ geometry.PointF.init(208, 148), geometry.PointF.init(188, 148), geometry.PointF.init(180, 120) } },
        .{ .verb = .close },
    };

    var commands: [15]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try builder.pushClip(.{
        .id = 9,
        .rect = geometry.RectF.init(4, 5, 320, 160),
        .radius = Radius.all(12),
    });
    try builder.pushOpacity(0.75);
    try builder.transform(Affine.translate(8, 6));
    try builder.fillRect(.{
        .id = 10,
        .rect = geometry.RectF.init(0, 0, 360, 180),
        .fill = .{ .linear_gradient = .{
            .start = geometry.PointF.init(0, 0),
            .end = geometry.PointF.init(360, 180),
            .stops = &stops,
        } },
    });
    try builder.shadow(.{
        .id = 11,
        .rect = geometry.RectF.init(24, 24, 220, 96),
        .radius = Radius.all(16),
        .offset = .{ .dx = 0, .dy = 18 },
        .blur = 42,
        .spread = -8,
        .color = Color.rgba(0, 0, 0, 0.25),
    });
    try builder.fillRoundedRect(.{
        .id = 13,
        .rect = geometry.RectF.init(24, 80, 128, 48),
        .radius = .{ .top_left = 8, .top_right = 10, .bottom_right = 12, .bottom_left = 6 },
        .fill = .{ .color = Color.rgb8(255, 255, 255) },
    });
    try builder.strokeRect(.{
        .id = 14,
        .rect = geometry.RectF.init(24, 80, 128, 48),
        .radius = Radius.all(8),
        .stroke = .{ .fill = .{ .color = Color.rgb8(0, 0, 0) }, .width = 1.5 },
    });
    try builder.drawLine(.{
        .id = 17,
        .from = geometry.PointF.init(24, 140),
        .to = geometry.PointF.init(152, 140),
        .stroke = .{ .fill = .{ .linear_gradient = .{
            .start = geometry.PointF.init(0, 0),
            .end = geometry.PointF.init(360, 180),
            .stops = &stops,
        } }, .width = 2 },
    });
    try builder.fillPath(.{
        .id = 18,
        .elements = &path,
        .fill = .{ .color = Color.rgb8(15, 23, 42) },
    });
    try builder.strokePath(.{
        .id = 19,
        .elements = &path,
        .stroke = .{ .fill = .{ .color = Color.rgb8(0, 0, 0) }, .width = 2 },
    });
    try builder.drawImage(.{
        .id = 15,
        .image_id = 3,
        .src = geometry.RectF.init(0, 0, 48, 32),
        .dst = geometry.RectF.init(180, 40, 96, 64),
        .opacity = 0.6,
        .fit = .cover,
        .sampling = .nearest,
    });
    try builder.drawText(.{
        .id = 12,
        .font_id = 7,
        .size = 17,
        .origin = geometry.PointF.init(32, 52),
        .color = Color.rgb8(15, 23, 42),
        .text = "Hi",
        .glyphs = &glyphs,
    });
    try builder.blur(.{
        .id = 16,
        .rect = geometry.RectF.init(24, 24, 220, 96),
        .radius = 18,
    });
    try builder.popOpacity();
    try builder.popClip();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try builder.displayList().writeJson(&writer);

    const expected =
        "{\"commands\":[{\"op\":\"push_clip\",\"id\":9,\"rect\":[4,5,320,160],\"radius\":[12,12,12,12]},{\"op\":\"push_opacity\",\"opacity\":0.75},{\"op\":\"transform\",\"matrix\":[1,0,0,1,8,6]},{\"op\":\"fill_rect\",\"id\":10,\"rect\":[0,0,360,180],\"fill\":{\"kind\":\"linear_gradient\",\"start\":[0,0],\"end\":[360,180],\"stops\":[{\"offset\":0,\"color\":[1,1,1,1]},{\"offset\":1,\"color\":[0,0,0,1]}]}},{\"op\":\"shadow\",\"id\":11,\"rect\":[24,24,220,96],\"radius\":[16,16,16,16],\"offset\":[0,18],\"blur\":42,\"spread\":-8,\"color\":[0,0,0,0.25]},{\"op\":\"fill_rounded_rect\",\"id\":13,\"rect\":[24,80,128,48],\"radius\":[8,10,12,6],\"fill\":{\"kind\":\"color\",\"color\":[1,1,1,1]}},{\"op\":\"stroke_rect\",\"id\":14,\"rect\":[24,80,128,48],\"radius\":[8,8,8,8],\"stroke\":{\"width\":1.5,\"fill\":{\"kind\":\"color\",\"color\":[0,0,0,1]}}},{\"op\":\"draw_line\",\"id\":17,\"from\":[24,140],\"to\":[152,140],\"stroke\":{\"width\":2,\"fill\":{\"kind\":\"linear_gradient\",\"start\":[0,0],\"end\":[360,180],\"stops\":[{\"offset\":0,\"color\":[1,1,1,1]},{\"offset\":1,\"color\":[0,0,0,1]}]}}},{\"op\":\"fill_path\",\"id\":18,\"path\":[{\"verb\":\"move_to\",\"points\":[[180,120]]},{\"verb\":\"line_to\",\"points\":[[212,104]]},{\"verb\":\"quad_to\",\"points\":[[228,116],[220,136]]},{\"verb\":\"cubic_to\",\"points\":[[208,148],[188,148],[180,120]]},{\"verb\":\"close\",\"points\":[]}],\"fill\":{\"kind\":\"color\",\"color\":[0.05882353,0.09019608,0.16470589,1]}},{\"op\":\"stroke_path\",\"id\":19,\"path\":[{\"verb\":\"move_to\",\"points\":[[180,120]]},{\"verb\":\"line_to\",\"points\":[[212,104]]},{\"verb\":\"quad_to\",\"points\":[[228,116],[220,136]]},{\"verb\":\"cubic_to\",\"points\":[[208,148],[188,148],[180,120]]},{\"verb\":\"close\",\"points\":[]}],\"stroke\":{\"width\":2,\"fill\":{\"kind\":\"color\",\"color\":[0,0,0,1]}}},{\"op\":\"draw_image\",\"id\":15,\"image\":3,\"dst\":[180,40,96,64],\"src\":[0,0,48,32],\"opacity\":0.6,\"fit\":\"cover\",\"sampling\":\"nearest\"},{\"op\":\"draw_text\",\"id\":12,\"font\":7,\"size\":17,\"origin\":[32,52],\"color\":[0.05882353,0.09019608,0.16470589,1],\"text\":\"Hi\",\"glyphs\":[{\"id\":42,\"x\":12,\"y\":28,\"advance\":9},{\"id\":43,\"x\":21,\"y\":28,\"advance\":8}]},{\"op\":\"blur\",\"id\":16,\"rect\":[24,24,220,96],\"radius\":18},{\"op\":\"pop_opacity\"},{\"op\":\"pop_clip\"}]}";
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "display list serializes per-run text layout options" {
    const commands = [_]CanvasCommand{.{ .draw_text = .{
        .id = 3,
        .font_id = 1,
        .size = 10,
        .origin = geometry.PointF.init(4, 20),
        .color = Color.rgb8(0, 0, 0),
        .text = "Wrapped",
        .text_layout = .{ .max_width = 42, .line_height = 14, .wrap = .character, .alignment = .center },
    } }};

    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try (DisplayList{ .commands = &commands }).writeJson(&writer);
    try std.testing.expectEqualStrings(
        "{\"commands\":[{\"op\":\"draw_text\",\"id\":3,\"font\":1,\"size\":10,\"origin\":[4,20],\"color\":[0,0,0,1],\"text\":\"Wrapped\",\"glyphs\":[],\"layout\":{\"maxWidth\":42,\"lineHeight\":14,\"wrap\":\"character\",\"align\":\"center\"}}]}",
        writer.buffered(),
    );
}

test "display list serializes glyph text clusters" {
    const glyphs = [_]Glyph{
        .{ .id = 42, .x = 12, .y = 28, .advance = 9, .text_start = 0, .text_len = 1 },
        .{ .id = 1001, .x = 21, .y = 28, .advance = 12, .text_start = 1, .text_len = 2 },
    };
    const commands = [_]CanvasCommand{.{ .draw_text = .{
        .id = 3,
        .font_id = 1,
        .size = 10,
        .origin = geometry.PointF.init(4, 20),
        .color = Color.rgb8(0, 0, 0),
        .text = "ffi",
        .glyphs = &glyphs,
    } }};

    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try (DisplayList{ .commands = &commands }).writeJson(&writer);
    try std.testing.expectEqualStrings(
        "{\"commands\":[{\"op\":\"draw_text\",\"id\":3,\"font\":1,\"size\":10,\"origin\":[4,20],\"color\":[0,0,0,1],\"text\":\"ffi\",\"glyphs\":[{\"id\":42,\"x\":12,\"y\":28,\"advance\":9,\"textStart\":0,\"textLen\":1},{\"id\":1001,\"x\":21,\"y\":28,\"advance\":12,\"textStart\":1,\"textLen\":2}]}]}",
        writer.buffered(),
    );
}

fn wideTextMeasureForTests(context: ?*anyopaque, font_id: FontId, size: f32, text: []const u8) f32 {
    _ = context;
    _ = font_id;
    var scalars: f32 = 0;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        if (!text_model.isUtf8ContinuationByte(text[index])) scalars += 1;
    }
    return size * 2 * scalars;
}

const wide_text_measure = support.TextMeasureProvider{ .measure_fn = wideTextMeasureForTests };

test "injected measure provider drives line breaking and caret geometry" {
    const estimator_text = DrawText{
        .font_id = 1,
        .size = 10,
        .origin = geometry.PointF.init(0, 10),
        .color = Color.rgb8(0, 0, 0),
        .text = "ab cd",
        .text_layout = .{ .max_width = 50, .line_height = 12, .wrap = .word },
    };
    var estimator_lines: [4]TextLine = undefined;
    const estimator_layout = try layoutTextRun(estimator_text, estimator_text.text_layout.?, &estimator_lines);
    try std.testing.expectEqual(@as(usize, 1), estimator_layout.lineCount());

    var measured_text = estimator_text;
    measured_text.text_layout = .{
        .max_width = 50,
        .line_height = 12,
        .wrap = .word,
        .measure = &wide_text_measure,
    };
    var measured_lines: [4]TextLine = undefined;
    const measured_layout = try layoutTextRun(measured_text, measured_text.text_layout.?, &measured_lines);
    try std.testing.expectEqual(@as(usize, 2), measured_layout.lineCount());

    // Caret after "ab" on the first line: 2 scalars x (2 x size) wide.
    const measured_caret = textLineCaretX(measured_text, measured_layout.lines[0], 2);
    try std.testing.expectEqual(@as(f32, 40), measured_caret);
    const estimator_caret = textLineCaretX(estimator_text, estimator_layout.lines[0], 2);
    try std.testing.expect(estimator_caret != measured_caret);

    // Hit testing agrees with the provider-measured advances.
    const hit = textOffsetForLayoutPoint(measured_text, measured_layout, geometry.PointF.init(39, 5)).?;
    try std.testing.expectEqual(@as(usize, 2), hit);
}

// ------------------------------------------------------------------
// Regression: the reference pen must walk the same measurement seam
// layout used. A CoreText-like provider measures multibyte codepoints
// narrower than the estimator's flat 0.65em multibyte advance; walking
// the raw estimator while the provider measured the line's bounds and
// clip dropped one tail glyph per multibyte codepoint — the shape a
// live macOS app's automation screenshots exposed.
fn coretextLikeMeasureForTests(context: ?*anyopaque, font_id: FontId, size: f32, text: []const u8) f32 {
    _ = context;
    var width: f32 = 0;
    var index: usize = 0;
    while (index < text.len) {
        const next = @min(text.len, index + text_model.utf8SequenceLength(text[index]));
        const cluster = text[index..next];
        width += if (cluster.len > 1) size * 0.3 else estimateTextAdvanceForBytes(font_id, cluster, size);
        index = next;
    }
    return width;
}

const coretext_like_measure = support.TextMeasureProvider{ .measure_fn = coretextLikeMeasureForTests };

fn tailInkDroppedByBoundsClip(comptime body: []const u8, text_layout: ?TextLayoutOptions) !usize {
    const size: f32 = 16;
    const text = DrawText{
        .font_id = 1,
        .size = size,
        .origin = geometry.PointF.init(4, 20),
        .color = Color.rgb8(255, 255, 255),
        .text = body,
        .text_layout = text_layout,
    };
    const commands = [_]CanvasCommand{.{ .draw_text = text }};
    var render_commands: [1]RenderCommand = undefined;
    const render_plan = try (DisplayList{ .commands = &commands }).renderPlan(&render_commands);

    const width = 360;
    const height = 40;
    var clipped_pixels: [width * height * 4]u8 = [_]u8{0} ** (width * height * 4);
    var unclipped_pixels: [width * height * 4]u8 = [_]u8{0} ** (width * height * 4);

    const clipped = try ReferenceRenderSurface.init(width, height, &clipped_pixels);
    try clipped.renderPass(.{
        .commands = render_plan.commands,
        .surface_size = geometry.SizeF.init(width, height),
        .full_repaint = true,
    }, Color.rgb8(0, 0, 0));

    // The same command with surface-wide bounds: every pixel the glyph
    // outlines would ink with no bounds clip at all.
    var widened = render_plan.commands[0];
    widened.bounds = geometry.RectF.init(0, 0, width, height);
    widened.local_bounds = widened.bounds;
    const widened_commands = [_]RenderCommand{widened};
    const unclipped = try ReferenceRenderSurface.init(width, height, &unclipped_pixels);
    try unclipped.renderPass(.{
        .commands = &widened_commands,
        .surface_size = geometry.SizeF.init(width, height),
        .full_repaint = true,
    }, Color.rgb8(0, 0, 0));

    var dropped: usize = 0;
    for (0..height) |y| for (0..width) |x| {
        const index = (y * width + x) * 4;
        if (clipped_pixels[index] != unclipped_pixels[index]) dropped += 1;
    };
    return dropped;
}

test "provider-measured runs keep their multibyte tails inside command bounds" {
    const size: f32 = 16;
    // One exact-fit line per string, measured by the provider — the shape
    // every tight intrinsic text box produces on a live macOS app.
    inline for ([_][]const u8{
        "Live \xc2\xb7 every 2 s",
        "12 kept \xc2\xb7 2 s \xc2\xb7 ok",
        "caf\xc3\xa9 r\xc3\xa9sum\xc3\xa9",
        "go \xe2\x86\x92 done \xe2\x86\x92 end",
        "\xe4\xb8\xad\xe6\x96\x87 label",
    }) |body| {
        const provider_width = coretextLikeMeasureForTests(null, 1, size, body);
        const options = TextLayoutOptions{
            .max_width = provider_width,
            .line_height = size * 1.25,
            .wrap = .word,
            .measure = &coretext_like_measure,
        };
        // Exact fit stays one line under the provider's own widths.
        const text = DrawText{
            .font_id = 1,
            .size = size,
            .origin = geometry.PointF.init(4, 20),
            .color = Color.rgb8(255, 255, 255),
            .text = body,
            .text_layout = options,
        };
        var lines: [4]TextLine = undefined;
        const layout = try layoutTextRun(text, options, &lines);
        try std.testing.expectEqual(@as(usize, 1), layout.lineCount());
        try std.testing.expectEqual(body.len, layout.lines[0].text_len);

        // And every inked pixel stays inside the command bounds: nothing
        // the renderer would draw unbounded is lost to the bounds clip.
        try std.testing.expectEqual(@as(usize, 0), try tailInkDroppedByBoundsClip(body, options));
    }
}

test "estimator-measured exact-fit multibyte strings keep every byte on one line" {
    const size: f32 = 13;
    inline for ([_][]const u8{
        "Live \xc2\xb7 every 2 s",
        "of 32.0 GB \xc2\xb7 47%",
        "caf\xc3\xa9 \xc2\xb7 r\xc3\xa9sum\xc3\xa9 \xc2\xb7 na\xc3\xafve",
        "next \xe2\x86\x92 prev",
        "\xe4\xb8\xad\xe6\x96\x87\xe6\xb8\xac\xe8\xa9\xa6 row",
    }) |body| {
        const options = TextLayoutOptions{
            .max_width = estimateTextWidth(body, size),
            .line_height = size * 1.25,
            .wrap = .word,
        };
        const text = DrawText{
            .font_id = 1,
            .size = size,
            .origin = geometry.PointF.init(0, 16),
            .color = Color.rgb8(0, 0, 0),
            .text = body,
            .text_layout = options,
        };
        var lines: [4]TextLine = undefined;
        const layout = try layoutTextRun(text, options, &lines);
        try std.testing.expectEqual(@as(usize, 1), layout.lineCount());
        try std.testing.expectEqual(@as(usize, 0), layout.lines[0].text_start);
        try std.testing.expectEqual(body.len, layout.lines[0].text_len);
    }
}

test "text command bounds cover glyph ink overhang past metric advances" {
    // Wide real outlines behind narrow metric advances historically
    // clipped at the bounds edge: the flat 0.65em multibyte estimate
    // under an \u{2192} arrow, and mono glyphs inking wider than the flat
    // 0.6em mono advance (the notes-build "tail clip" screenshot
    // artifact). With the ink allowance on textBounds nothing inks
    // outside the command bounds.
    try std.testing.expectEqual(@as(usize, 0), try tailInkDroppedByBoundsClip("go \xe2\x86\x92", null));
    try std.testing.expectEqual(@as(usize, 0), try tailInkDroppedByBoundsClip("mono tail mm", null));
    try std.testing.expectEqual(@as(usize, 0), try tailInkDroppedByBoundsClip("gravity plummets", null));
    try std.testing.expectEqual(@as(usize, 0), try tailInkDroppedByBoundsClip("Grocery run notes\xe2\x80\xa6", null));
}
