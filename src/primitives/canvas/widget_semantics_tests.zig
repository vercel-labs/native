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
const textSelectionTextColor = support.textSelectionTextColor;
const textEditingInkColor = support.textEditingInkColor;
const staticTextSelectionFillColor = support.staticTextSelectionFillColor;
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

test "widget spatial focus traversal moves across data grid cells" {
    const header_cells = [_]Widget{
        .{ .id = 3, .kind = .data_cell, .text = "Project", .layout = .{ .grow = 1 } },
        .{ .id = 4, .kind = .data_cell, .text = "Status", .layout = .{ .grow = 1 } },
    };
    const row_cells = [_]Widget{
        .{ .id = 6, .kind = .data_cell, .text = "Edge API", .layout = .{ .grow = 1 } },
        .{ .id = 7, .kind = .data_cell, .text = "Live", .layout = .{ .grow = 1 } },
    };
    const rows = [_]Widget{
        .{ .id = 2, .kind = .data_row, .frame = geometry.RectF.init(0, 0, 0, 28), .children = &header_cells },
        .{ .id = 5, .kind = .data_row, .frame = geometry.RectF.init(0, 0, 0, 28), .children = &row_cells },
    };
    const grid = Widget{
        .id = 1,
        .kind = .data_grid,
        .layout = .{ .gap = 2 },
        .children = &rows,
    };

    var nodes: [8]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(grid, geometry.RectF.init(0, 0, 240, 58), &nodes);
    try std.testing.expectEqual(@as(ObjectId, 4), layout.focusTarget(3, .right).?.id);
    try std.testing.expectEqual(@as(ObjectId, 3), layout.focusTarget(4, .left).?.id);
    try std.testing.expectEqual(@as(ObjectId, 6), layout.focusTarget(3, .down).?.id);
    try std.testing.expectEqual(@as(ObjectId, 7), layout.focusTarget(4, .down).?.id);
    try std.testing.expectEqual(@as(ObjectId, 3), layout.focusTarget(6, .up).?.id);
    try std.testing.expect(layout.focusTarget(3, .left) == null);
    try std.testing.expect(layout.focusTarget(3, .up) == null);
    try std.testing.expect(layout.focusTarget(null, .right) == null);
}

test "widget spatial focus traversal reaches staggered targets" {
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(0, 0, 40, 24),
            .text = "Start",
        },
        .{
            .id = 3,
            .kind = .button,
            .frame = geometry.RectF.init(72, 40, 40, 24),
            .text = "Next",
        },
        .{
            .id = 4,
            .kind = .button,
            .frame = geometry.RectF.init(60, 88, 40, 24),
            .text = "Lower",
        },
    };
    const root = Widget{ .kind = .stack, .children = &children };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 140, 128), &nodes);
    try std.testing.expectEqual(@as(ObjectId, 3), layout.focusTarget(2, .right).?.id);
    try std.testing.expectEqual(@as(ObjectId, 3), layout.focusTarget(2, .down).?.id);
    try std.testing.expectEqual(@as(ObjectId, 2), layout.focusTarget(3, .left).?.id);
    try std.testing.expectEqual(@as(ObjectId, 2), layout.focusTarget(3, .up).?.id);
    try std.testing.expectEqual(@as(ObjectId, 4), layout.focusTarget(3, .down).?.id);
}

test "widget layout collects accessibility semantics" {
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(10, 10, 100, 32),
            .text = "Run",
            .semantics = .{ .label = "Run query" },
        },
        .{
            .id = 3,
            .kind = .progress,
            .frame = geometry.RectF.init(10, 52, 160, 8),
            .value = 0.75,
        },
        .{
            .id = 4,
            .kind = .text,
            .frame = geometry.RectF.init(10, 68, 120, 20),
            .text = "Hidden note",
            .semantics = .{ .hidden = true },
        },
    };
    const root = Widget{
        .id = 1,
        .kind = .panel,
        .semantics = .{ .label = "Dashboard card" },
        .children = &children,
    };

    var nodes: [6]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 240, 120), &nodes);
    var semantics_buffer: [4]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);

    try std.testing.expectEqual(@as(usize, 3), semantics.len);
    try std.testing.expectEqual(WidgetRole.group, semantics[0].role);
    try std.testing.expectEqualStrings("Dashboard card", semantics[0].label);
    try std.testing.expect(semantics[0].parent_index == null);

    try std.testing.expectEqual(WidgetRole.button, semantics[1].role);
    // The label-replace contract: an explicit semantics.label REPLACES the
    // widget's text ("Run") as the accessible name — the sources never
    // combine, so screen readers and snapshots see the label alone.
    try std.testing.expectEqualStrings("Run query", semantics[1].label);
    try std.testing.expectEqual(@as(?usize, 0), semantics[1].parent_index);
    try std.testing.expect(semantics[1].focusable);
    try std.testing.expect(semantics[1].actions.focus);
    try std.testing.expect(semantics[1].actions.press);
    try std.testing.expect(!semantics[1].actions.toggle);

    try std.testing.expectEqual(WidgetRole.progressbar, semantics[2].role);
    try std.testing.expectEqual(@as(?f32, 0.75), semantics[2].value);
    try std.testing.expect(semantics[2].actions.isEmpty());
    try expectRect(geometry.RectF.init(10, 52, 160, 8), semantics[2].bounds);
}

test "widget text size rungs do not change semantics" {
    // heading/display are VISUAL typography rungs, not document
    // structure: a display-size stat announces exactly like a body-size
    // one (same role, same label, no heading level), so assistive tech
    // output never shifts when a surface adopts the ladder.
    const sizes = [_]canvas.WidgetSize{ .default, .heading, .display };
    inline for (sizes) |size| {
        const children = [_]Widget{
            .{ .id = 2, .kind = .text, .frame = geometry.RectF.init(10, 10, 200, 60), .text = "42.7%", .size = size },
        };
        const root = Widget{ .id = 1, .kind = .column, .children = &children };
        var nodes: [4]WidgetLayoutNode = undefined;
        const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 240, 120), &nodes);
        var semantics_buffer: [4]WidgetSemanticsNode = undefined;
        const semantics = try layout.collectSemantics(&semantics_buffer);
        try std.testing.expectEqual(@as(usize, 2), semantics.len);
        try std.testing.expectEqual(WidgetRole.text, semantics[1].role);
        try std.testing.expectEqualStrings("42.7%", semantics[1].label);
        try std.testing.expect(!semantics[1].focusable);
        try std.testing.expect(semantics[1].actions.isEmpty());
    }
}

test "widget disabled semantics suppresses focusability and actions" {
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(8, 8, 100, 32),
            .text = "Disabled",
            .state = .{ .disabled = true },
            .semantics = .{ .focusable = true, .actions = .{ .focus = true, .press = true } },
        },
        .{
            .id = 3,
            .kind = .text,
            .frame = geometry.RectF.init(8, 48, 140, 20),
            .text = "Disabled copy",
            .state = .{ .disabled = true },
            .semantics = .{ .focusable = true },
        },
        .{
            .id = 4,
            .kind = .button,
            .frame = geometry.RectF.init(8, 76, 100, 32),
            .text = "Active",
        },
    };
    const root = Widget{ .kind = .stack, .children = &children };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 160, 120), &nodes);
    try std.testing.expectEqual(@as(ObjectId, 4), layout.focusTarget(null, .forward).?.id);
    try std.testing.expect(layout.focusTargetById(2) == null);
    try std.testing.expect(layout.focusTargetById(3) == null);

    var semantics_buffer: [3]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 3), semantics.len);

    try std.testing.expectEqual(@as(ObjectId, 2), semantics[0].id);
    try std.testing.expect(semantics[0].state.disabled);
    try std.testing.expect(!semantics[0].focusable);
    try std.testing.expect(semantics[0].actions.isEmpty());

    try std.testing.expectEqual(@as(ObjectId, 3), semantics[1].id);
    try std.testing.expect(semantics[1].state.disabled);
    try std.testing.expect(!semantics[1].focusable);
    try std.testing.expect(semantics[1].actions.isEmpty());

    try std.testing.expectEqual(@as(ObjectId, 4), semantics[2].id);
    try std.testing.expect(semantics[2].focusable);
    try std.testing.expect(semantics[2].actions.focus);
    try std.testing.expect(semantics[2].actions.press);
}

test "widget hidden semantics suppresses descendant semantics" {
    const hidden_children = [_]Widget{.{
        .id = 3,
        .kind = .button,
        .frame = geometry.RectF.init(0, 0, 100, 32),
        .text = "Hidden child",
    }};
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .panel,
            .frame = geometry.RectF.init(8, 8, 120, 48),
            .semantics = .{ .hidden = true },
            .children = &hidden_children,
        },
        .{
            .id = 4,
            .kind = .button,
            .frame = geometry.RectF.init(8, 64, 120, 32),
            .text = "Visible",
        },
    };
    const root = Widget{
        .id = 1,
        .kind = .panel,
        .semantics = .{ .label = "Root" },
        .children = &children,
    };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 160, 120), &nodes);
    var semantics_buffer: [4]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);

    try std.testing.expectEqual(@as(usize, 2), semantics.len);
    try std.testing.expectEqual(@as(ObjectId, 1), semantics[0].id);
    try std.testing.expectEqualStrings("Root", semantics[0].label);
    try std.testing.expectEqual(@as(ObjectId, 4), semantics[1].id);
    try std.testing.expectEqualStrings("Visible", semantics[1].label);
    try std.testing.expectEqual(@as(?usize, 0), semantics[1].parent_index);
}

test "widget hidden subtrees do not receive input routes" {
    const hidden_children = [_]Widget{.{
        .id = 3,
        .kind = .button,
        .frame = geometry.RectF.init(0, 0, 100, 32),
        .text = "Hidden child",
        .semantics = .{ .actions = .{ .drag = true, .drop_files = true } },
    }};
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .panel,
            .frame = geometry.RectF.init(8, 8, 120, 48),
            .semantics = .{ .hidden = true },
            .children = &hidden_children,
        },
        .{
            .id = 4,
            .kind = .button,
            .frame = geometry.RectF.init(8, 64, 120, 32),
            .text = "Visible",
        },
    };
    const root = Widget{ .id = 1, .kind = .stack, .children = &children };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 160, 120), &nodes);

    try std.testing.expect(layout.hitTest(geometry.PointF.init(16, 16)) == null);
    try std.testing.expectEqual(@as(ObjectId, 4), layout.hitTest(geometry.PointF.init(16, 72)).?.id);
    try std.testing.expectEqual(@as(ObjectId, 4), layout.focusTarget(null, .forward).?.id);
    try std.testing.expect(layout.focusTargetById(3) == null);

    var route_buffer: [4]WidgetEventRouteEntry = undefined;
    const pointer_route = try layout.routePointerEvent(.{ .phase = .down, .point = geometry.PointF.init(16, 16) }, &route_buffer);
    try std.testing.expect(pointer_route.target == null);
    try std.testing.expectEqual(@as(usize, 0), pointer_route.entries.len);

    const keyboard_route = try layout.routeKeyboardEvent(.{ .phase = .key_down, .focused_id = 3, .key = "Enter" }, &route_buffer);
    try std.testing.expect(keyboard_route.target == null);
    try std.testing.expectEqual(@as(usize, 0), keyboard_route.entries.len);

    const paths = [_][]const u8{"/tmp/report.csv"};
    const drop_route = try layout.routeFileDropEvent(.{ .point = geometry.PointF.init(16, 16), .paths = &paths }, &route_buffer);
    try std.testing.expect(drop_route.target == null);
    try std.testing.expectEqual(@as(usize, 0), drop_route.entries.len);

    const drag_route = try layout.routeDragEvent(.{ .source_id = 3, .point = geometry.PointF.init(16, 16) }, &route_buffer);
    try std.testing.expect(drag_route.target == null);
    try std.testing.expectEqual(@as(usize, 0), drag_route.entries.len);
}

test "widget controls expose roles values focus and hit testing" {
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .checkbox,
            .frame = geometry.RectF.init(10, 10, 120, 28),
            .text = "Live",
            .state = .{ .selected = true },
        },
        .{
            .id = 3,
            .kind = .radio,
            .frame = geometry.RectF.init(10, 46, 120, 28),
            .text = "Monthly",
            .state = .{ .selected = true },
        },
        .{
            .id = 4,
            .kind = .toggle,
            .frame = geometry.RectF.init(10, 82, 120, 28),
            .text = "Focus",
        },
        .{
            .id = 5,
            .kind = .slider,
            .frame = geometry.RectF.init(10, 118, 160, 32),
            .value = 0.35,
        },
    };
    const root = Widget{ .id = 1, .kind = .panel, .children = &children };

    var nodes: [6]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 220, 176), &nodes);
    try std.testing.expectEqual(@as(ObjectId, 2), layout.focusTarget(null, .forward).?.id);
    try std.testing.expectEqual(@as(ObjectId, 3), layout.focusTarget(2, .forward).?.id);
    try std.testing.expectEqual(@as(ObjectId, 4), layout.focusTarget(3, .forward).?.id);
    try std.testing.expectEqual(@as(ObjectId, 5), layout.focusTarget(4, .forward).?.id);
    try std.testing.expectEqual(@as(ObjectId, 4), layout.focusTarget(5, .backward).?.id);

    const slider_hit = layout.hitTest(geometry.PointF.init(40, 130)).?;
    try std.testing.expectEqual(@as(ObjectId, 5), slider_hit.id);
    try std.testing.expectEqual(WidgetKind.slider, slider_hit.kind);

    const checkbox_label_hit = layout.hitTest(geometry.PointF.init(80, 24)).?;
    try std.testing.expectEqual(@as(ObjectId, 2), checkbox_label_hit.id);
    try std.testing.expectEqual(WidgetKind.checkbox, checkbox_label_hit.kind);

    const toggle_label_hit = layout.hitTest(geometry.PointF.init(100, 96)).?;
    try std.testing.expectEqual(@as(ObjectId, 4), toggle_label_hit.id);
    try std.testing.expectEqual(WidgetKind.toggle, toggle_label_hit.kind);

    var semantics_buffer: [5]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 5), semantics.len);
    try std.testing.expectEqual(WidgetRole.checkbox, semantics[1].role);
    try std.testing.expectEqualStrings("Live", semantics[1].label);
    try std.testing.expectEqual(@as(?f32, 1), semantics[1].value);
    try std.testing.expect(semantics[1].focusable);
    try std.testing.expect(semantics[1].actions.focus);
    try std.testing.expect(semantics[1].actions.toggle);
    try std.testing.expectEqual(WidgetRole.radio, semantics[2].role);
    try std.testing.expectEqualStrings("Monthly", semantics[2].label);
    try std.testing.expectEqual(@as(?f32, 1), semantics[2].value);
    try std.testing.expect(semantics[2].focusable);
    try std.testing.expect(semantics[2].actions.select);
    try std.testing.expect(!semantics[2].actions.toggle);
    // `toggle` is the pressed-state button family; the switch role
    // belongs to `switch_control` alone.
    try std.testing.expectEqual(WidgetRole.button, semantics[3].role);
    try std.testing.expectEqual(@as(?f32, 0), semantics[3].value);
    try std.testing.expect(semantics[3].actions.toggle);
    try std.testing.expectEqual(WidgetRole.slider, semantics[4].role);
    try std.testing.expectEqual(@as(?f32, 0.35), semantics[4].value);
    try std.testing.expect(semantics[4].actions.focus);
    try std.testing.expect(semantics[4].actions.increment);
    try std.testing.expect(semantics[4].actions.decrement);
    try std.testing.expect(!semantics[4].actions.press);
}

test "widget icons expose image and button semantics" {
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .icon,
            .frame = geometry.RectF.init(8, 8, 24, 24),
            .text = "?",
            .semantics = .{ .label = "Help" },
        },
        .{
            .id = 3,
            .kind = .icon_button,
            .frame = geometry.RectF.init(40, 4, 32, 32),
            .text = "+",
            .state = .{ .focused = true },
            .semantics = .{ .label = "Add item" },
        },
    };
    const root = Widget{ .kind = .stack, .children = &children };

    var nodes: [3]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 120, 48), &nodes);
    try std.testing.expectEqual(@as(ObjectId, 3), layout.focusTarget(null, .forward).?.id);
    try std.testing.expect(layout.hitTest(geometry.PointF.init(16, 16)) == null);

    const button_hit = layout.hitTest(geometry.PointF.init(48, 16)).?;
    try std.testing.expectEqual(@as(ObjectId, 3), button_hit.id);
    try std.testing.expectEqual(WidgetKind.icon_button, button_hit.kind);

    var semantics_buffer: [2]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 2), semantics.len);
    try std.testing.expectEqual(WidgetRole.image, semantics[0].role);
    try std.testing.expectEqualStrings("Help", semantics[0].label);
    try std.testing.expect(!semantics[0].focusable);
    try std.testing.expectEqual(WidgetRole.button, semantics[1].role);
    try std.testing.expectEqualStrings("Add item", semantics[1].label);
    try std.testing.expect(semantics[1].focusable);

    const tokens = DesignTokens{
        .colors = .{ .focus_ring = Color.rgb8(1, 2, 3) },
        .stroke = .{ .focus = 4 },
    };
    var icon_commands: [1]CanvasCommand = undefined;
    var icon_builder = Builder.init(&icon_commands);
    try emitWidgetTree(&icon_builder, children[0], tokens);
    const icon_display_list = icon_builder.displayList();
    try std.testing.expectEqual(@as(usize, 1), icon_display_list.commandCount());
    switch (icon_display_list.commands[0]) {
        .draw_text => |text| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(2, 1)), text.id);
            try std.testing.expectEqualStrings("?", text.text);
        },
        else => return error.TestUnexpectedResult,
    }

    var button_commands: [5]CanvasCommand = undefined;
    var button_builder = Builder.init(&button_commands);
    try emitWidgetTree(&button_builder, children[1], tokens);
    const button_display_list = button_builder.displayList();
    // Focus no longer restyles the border: fill, border, offset focus
    // ring, then the glyph (the button register is flat — no shadow).
    try std.testing.expectEqual(@as(usize, 4), button_display_list.commandCount());
    switch (button_display_list.commands[2]) {
        .stroke_rect => |stroke| {
            try std.testing.expectEqual(@as(f32, 4), stroke.stroke.width);
            try expectFillColor(tokens.colors.focus_ring, stroke.stroke.fill);
            // The ring sits 2px outside the control frame.
            try std.testing.expectEqual(@as(f32, 40 - 2), stroke.rect.x);
            try std.testing.expectEqual(@as(f32, 32 + 4), stroke.rect.width);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (button_display_list.commands[3]) {
        .draw_text => |text| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(3, 3)), text.id);
            try std.testing.expectEqualStrings("+", text.text);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "widget image emits draw image and exposes image semantics" {
    const image = Widget{
        .id = 8,
        .kind = .image,
        .frame = geometry.RectF.init(12, 14, 80, 48),
        .image_id = 42,
        .image_src = geometry.RectF.init(0, 0, 320, 192),
        .image_fit = .cover,
        .image_sampling = .nearest,
        .image_opacity = 0.75,
        .semantics = .{ .label = "Deployment preview" },
    };

    var nodes: [1]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(image, image.frame, &nodes);
    try std.testing.expect(layout.hitTest(geometry.PointF.init(20, 20)) == null);

    var semantics_buffer: [1]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 1), semantics.len);
    try std.testing.expectEqual(WidgetRole.image, semantics[0].role);
    try std.testing.expectEqualStrings("Deployment preview", semantics[0].label);
    try std.testing.expect(!semantics[0].focusable);

    var commands: [3]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, .{});
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 3), display_list.commandCount());
    switch (display_list.commands[0]) {
        .push_clip => |clip| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(8, 2)), clip.id);
            try expectRect(geometry.RectF.init(12, 14, 80, 48), clip.rect);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[1]) {
        .draw_image => |draw| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(8, 1)), draw.id);
            try std.testing.expectEqual(@as(ImageId, 42), draw.image_id);
            try expectRect(geometry.RectF.init(0, 0, 320, 192), draw.src);
            try expectRect(geometry.RectF.init(12, 14, 80, 48), draw.dst);
            try std.testing.expectEqual(ImageFit.cover, draw.fit);
            try std.testing.expectEqual(ImageSampling.nearest, draw.sampling);
            try std.testing.expectEqual(@as(f32, 0.75), draw.opacity);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(display_list.commands[2] == .pop_clip);
}

test "widget media surface cover fit emits the image widget's rectangular clip" {
    // Cover fit expands the drawn texture past the widget frame on one
    // axis; emitImageWidget crops the overflow with a rectangular clip.
    // The media surface draws through the same image pipeline and must
    // carry the SAME clip: its draw-level radius mask is nothing at
    // radius zero, so hosts that only mask radii (the AppKit packet
    // draw) painted a zero-radius cover surface outside its bounds,
    // over its siblings.
    const surface_id: u64 = 5;
    const row_children = [_]Widget{
        .{
            .id = 21,
            .kind = .media_surface,
            .frame = geometry.RectF.init(0, 0, 80, 48),
            .image_id = surface_id,
            .image_fit = .cover,
        },
        .{
            .id = 22,
            .kind = .image,
            .frame = geometry.RectF.init(0, 0, 40, 48),
            .image_id = 42,
        },
    };
    const root = Widget{ .id = 20, .kind = .row, .children = &row_children };

    var nodes: [3]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 160, 48), &nodes);
    var commands: [8]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, .{});
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 5), display_list.commandCount());
    const media_frame = geometry.RectF.init(0, 0, 80, 48);
    switch (display_list.commands[0]) {
        .fill_rounded_rect => |fill| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(21, 1)), fill.id);
            try expectRect(media_frame, fill.rect);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[1]) {
        .push_clip => |clip| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(21, 3)), clip.id);
            try expectRect(media_frame, clip.rect);
            // A rectangular bounds crop, exactly like the image
            // widget's — rounding stays on the draw's own mask.
            try std.testing.expectEqual(@as(f32, 0), clip.radius.top_left);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[2]) {
        .draw_image => |draw| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(21, 2)), draw.id);
            try std.testing.expectEqual(canvas.mediaSurfaceTextureImageId(surface_id), draw.image_id);
            try std.testing.expectEqual(ImageFit.cover, draw.fit);
        },
        else => return error.TestUnexpectedResult,
    }
    // The clip closes BEFORE the sibling paints: the sibling's own draw
    // is never cropped by the media surface's frame.
    try std.testing.expect(display_list.commands[3] == .pop_clip);
    switch (display_list.commands[4]) {
        .draw_image => |draw| try std.testing.expectEqual(@as(ObjectId, widgetPartId(22, 1)), draw.id),
        else => return error.TestUnexpectedResult,
    }

    // Non-cover fits expand nothing and emit no clip — unchanged.
    const contained = Widget{
        .id = 21,
        .kind = .media_surface,
        .frame = media_frame,
        .image_id = surface_id,
        .image_fit = .stretch,
    };
    var contained_nodes: [1]WidgetLayoutNode = undefined;
    const contained_layout = try layoutWidgetTree(contained, media_frame, &contained_nodes);
    var contained_commands: [4]CanvasCommand = undefined;
    var contained_builder = Builder.init(&contained_commands);
    try contained_layout.emitDisplayList(&contained_builder, .{});
    try std.testing.expectEqual(@as(usize, 2), contained_builder.displayList().commandCount());

    // The rounded cover case keeps its draw-level radius mask AND gains
    // the same bounds crop (the mask lies inside the rect, so pixels
    // are unchanged where the radius already masked).
    const rounded = Widget{
        .id = 21,
        .kind = .media_surface,
        .frame = media_frame,
        .image_id = surface_id,
        .image_fit = .cover,
        .style = .{ .radius = 12 },
    };
    var rounded_nodes: [1]WidgetLayoutNode = undefined;
    const rounded_layout = try layoutWidgetTree(rounded, media_frame, &rounded_nodes);
    var rounded_commands: [4]CanvasCommand = undefined;
    var rounded_builder = Builder.init(&rounded_commands);
    try rounded_layout.emitDisplayList(&rounded_builder, .{});
    const rounded_list = rounded_builder.displayList();
    try std.testing.expectEqual(@as(usize, 4), rounded_list.commandCount());
    try std.testing.expect(rounded_list.commands[1] == .push_clip);
    switch (rounded_list.commands[2]) {
        .draw_image => |draw| try std.testing.expectEqual(@as(f32, 12), draw.radius.top_left),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(rounded_list.commands[3] == .pop_clip);
}

test "a composited cover media texture is byte-contained in the reference render" {
    // Containment pin for the deterministic path: the render planner
    // already crops every draw to its requested `dst` (command bounds),
    // so reference renders — goldens, screenshots — were contained
    // before the cover clip and must stay byte-identical with it. The
    // clip COMMAND itself (pinned in the test above) is what protects
    // packet hosts, which replay the display list and expand cover at
    // draw time without the planner's bounds. The reference renderer
    // skips presentation-only media textures by policy; feeding the
    // texture in as an ordinary resource under the media-derived id
    // exercises the draw geometry itself.
    const surface_id: u64 = 5;
    const media_frame = geometry.RectF.init(8, 4, 8, 16);
    const widget = Widget{
        .id = 9,
        .kind = .media_surface,
        .frame = media_frame,
        .image_id = surface_id,
        .image_fit = .cover,
    };
    var nodes: [1]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(widget, media_frame, &nodes);
    var commands: [4]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, .{});

    // A square texture in a 1:2 frame: cover expands the draw to
    // (4,4,16,16) — four columns past BOTH vertical edges of the frame,
    // where a sibling would sit.
    const texture_pixels = [_]u8{
        255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255,
    };
    const images = [_]ReferenceImage{.{
        .id = canvas.mediaSurfaceTextureImageId(surface_id),
        .width = 2,
        .height = 2,
        .pixels = &texture_pixels,
    }};

    var render_commands: [8]RenderCommand = undefined;
    const plan = try builder.displayList().renderPlan(&render_commands);
    var pixels: [32 * 24 * 4]u8 = undefined;
    @memset(&pixels, 0);
    const surface = (try ReferenceRenderSurface.init(32, 24, &pixels)).withImages(&images);
    try surface.renderPass(.{
        .commands = plan.commands,
        .surface_size = geometry.SizeF.init(32, 24),
        .full_repaint = true,
    }, Color.rgb8(0, 0, 0));

    // Inside the frame: the texture (cover fills the whole frame).
    try support.expectPixelRgba8(.{ 255, 255, 255, 255 }, surface, 12, 12);
    // The fit-expanded bleed columns — left (x in [4,8)) and right
    // (x in [16,20)) of the frame — stay background: the emitted clip
    // contains the draw to the widget's bytes.
    try support.expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 5, 12);
    try support.expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 18, 12);
}

/// Render one contain-fit media surface headlessly and hand back the
/// composited pixels: the widget's emitted display list (placeholder
/// fill + black remainder bars + fitted quad) reference-rendered with
/// the texture fed in as an ORDINARY resource under the media-derived
/// id, defeating the presentation-only skip so the letterbox geometry
/// itself is pixel-assertable. The texture is solid white at the
/// STREAM's own aspect (a decoder pushes frames at stream geometry, so
/// the draw's contain re-fit against the real texture is a no-op —
/// exactly production); the pass clears to opaque blue so bars
/// (black), picture (white), and page (blue) are three unmistakable
/// bands.
fn renderContainVideoSurface(
    frame: geometry.RectF,
    stream: ?geometry.SizeF,
    texture_width: usize,
    texture_height: usize,
    pixels: *[32 * 24 * 4]u8,
) !ReferenceRenderSurface {
    const surface_id: u64 = 5;
    const widget = Widget{
        .id = 9,
        .kind = .media_surface,
        .frame = frame,
        .image_id = surface_id,
        .image_fit = .contain,
        .stream_size = stream,
    };
    var nodes: [1]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(widget, frame, &nodes);
    var commands: [6]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, .{});

    var texture_pixels: [4 * 2 * 4]u8 = undefined;
    @memset(&texture_pixels, 255);
    const images = [_]ReferenceImage{.{
        .id = canvas.mediaSurfaceTextureImageId(surface_id),
        .width = texture_width,
        .height = texture_height,
        .pixels = texture_pixels[0 .. texture_width * texture_height * 4],
    }};
    var render_commands: [8]RenderCommand = undefined;
    const plan = try builder.displayList().renderPlan(&render_commands);
    @memset(pixels, 0);
    const surface = (try ReferenceRenderSurface.init(32, 24, pixels)).withImages(&images);
    try surface.renderPass(.{
        .commands = plan.commands,
        .surface_size = geometry.SizeF.init(32, 24),
        .full_repaint = true,
    }, Color.rgb8(0, 0, 255));
    return surface;
}

test "a contain video surface pillarboxes a narrow stream on black" {
    // A square (1:1) stream into a 2:1 box: the fitted quad is the
    // 16x16 center, with 8px black bars left and right.
    const frame = geometry.RectF.init(0, 4, 32, 16);
    const widget = Widget{
        .id = 9,
        .kind = .media_surface,
        .frame = frame,
        .image_id = 5,
        .image_fit = .contain,
        .stream_size = .{ .width = 240, .height = 240 },
    };
    var nodes: [1]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(widget, frame, &nodes);
    var commands: [6]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, .{});
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 4), display_list.commandCount());

    // The placeholder stays the deterministic base fill (goldens and
    // replay screenshots skip the texture and show it inside the quad).
    switch (display_list.commands[0]) {
        .fill_rounded_rect => |fill| {
            try expectRect(frame, fill.rect);
            try std.testing.expectEqual(Fill{ .color = canvas.mediaSurfacePlaceholderColor(5) }, fill.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    // The remainder bars: opaque black over exactly the frame minus the
    // fitted quad — left and right for a pillarbox.
    switch (display_list.commands[1]) {
        .fill_rounded_rect => |fill| {
            try expectRect(geometry.RectF.init(0, 4, 8, 16), fill.rect);
            try std.testing.expectEqual(Fill{ .color = Color.rgba8(0, 0, 0, 255) }, fill.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[2]) {
        .fill_rounded_rect => |fill| {
            try expectRect(geometry.RectF.init(24, 4, 8, 16), fill.rect);
            try std.testing.expectEqual(Fill{ .color = Color.rgba8(0, 0, 0, 255) }, fill.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    // The frame quad: aspect-fitted from the REPORTED dimensions and
    // centered — the engine computed it, no host fit math required.
    // `image_src` keeps its ordinary source-crop meaning (untouched
    // here, so null).
    switch (display_list.commands[3]) {
        .draw_image => |draw| {
            try std.testing.expectEqual(canvas.mediaSurfaceTextureImageId(5), draw.image_id);
            try expectRect(geometry.RectF.init(8, 4, 16, 16), draw.dst);
            // The quad IS the fit: the draw stretches into it, so a
            // decoder whose true dimensions round off the report can
            // never open a host-side contain seam inside the quad.
            try std.testing.expectEqual(ImageFit.stretch, draw.fit);
            try std.testing.expectEqual(@as(?geometry.RectF, null), draw.src);
        },
        else => return error.TestUnexpectedResult,
    }

    // Pixel truth: black side regions, picture centered, page untouched.
    var pixels: [32 * 24 * 4]u8 = undefined;
    const surface = try renderContainVideoSurface(frame, .{ .width = 240, .height = 240 }, 2, 2, &pixels);
    try support.expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 3, 12); // left bar
    try support.expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 28, 12); // right bar
    try support.expectPixelRgba8(.{ 255, 255, 255, 255 }, surface, 16, 12); // picture
    try support.expectPixelRgba8(.{ 0, 0, 255, 255 }, surface, 16, 1); // page above the frame
}

test "a contain video surface letterboxes a wide stream on black" {
    // A 2:1 stream into a 2:3 box: the fitted quad is the 16x8 center
    // band, with 8px black bars above and below.
    const frame = geometry.RectF.init(8, 0, 16, 24);
    const stream = geometry.SizeF{ .width = 480, .height = 240 };
    const widget = Widget{
        .id = 9,
        .kind = .media_surface,
        .frame = frame,
        .image_id = 5,
        .image_fit = .contain,
        .stream_size = stream,
    };
    var nodes: [1]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(widget, frame, &nodes);
    var commands: [6]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, .{});
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 4), display_list.commandCount());
    switch (display_list.commands[1]) {
        .fill_rounded_rect => |fill| try expectRect(geometry.RectF.init(8, 0, 16, 8), fill.rect),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[2]) {
        .fill_rounded_rect => |fill| try expectRect(geometry.RectF.init(8, 16, 16, 8), fill.rect),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[3]) {
        .draw_image => |draw| try expectRect(geometry.RectF.init(8, 8, 16, 8), draw.dst),
        else => return error.TestUnexpectedResult,
    }

    var pixels: [32 * 24 * 4]u8 = undefined;
    const surface = try renderContainVideoSurface(frame, stream, 4, 2, &pixels);
    try support.expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 16, 4); // top bar
    try support.expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 16, 20); // bottom bar
    try support.expectPixelRgba8(.{ 255, 255, 255, 255 }, surface, 16, 12); // picture
    try support.expectPixelRgba8(.{ 0, 0, 255, 255 }, surface, 4, 12); // page beside the frame
}

test "a contain video surface with matching aspect fills the frame barless" {
    const frame = geometry.RectF.init(0, 4, 32, 16);
    const stream = geometry.SizeF{ .width = 640, .height = 320 };
    var pixels: [32 * 24 * 4]u8 = undefined;
    const surface = try renderContainVideoSurface(frame, stream, 4, 2, &pixels);
    // Every frame corner is picture — no bars on either axis.
    try support.expectPixelRgba8(.{ 255, 255, 255, 255 }, surface, 1, 5);
    try support.expectPixelRgba8(.{ 255, 255, 255, 255 }, surface, 30, 18);
    try support.expectPixelRgba8(.{ 255, 255, 255, 255 }, surface, 16, 12);

    // No bar fills, and the full-frame quad keeps the frame's own
    // corner radius (an inset quad drops it — its corners sit in the
    // bars, not at the surface's silhouette).
    const widget = Widget{
        .id = 9,
        .kind = .media_surface,
        .frame = frame,
        .image_id = 5,
        .image_fit = .contain,
        .stream_size = stream,
        .style = .{ .radius = 6 },
    };
    var nodes: [1]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(widget, frame, &nodes);
    var commands: [6]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, .{});
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 2), display_list.commandCount());
    switch (display_list.commands[1]) {
        .draw_image => |draw| {
            try expectRect(frame, draw.dst);
            try std.testing.expectEqual(@as(f32, 6), draw.radius.top_left);
            // Known geometry always stretches into the engine's quad —
            // the barless exact-aspect case seams just like the boxed
            // ones if a host re-fits the real texture.
            try std.testing.expectEqual(ImageFit.stretch, draw.fit);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "bars thinner than the corner radius keep the frame's mask on the quad" {
    // A 2.25:1 stream into a 2:1 box leaves ~0.9px letterbox bars —
    // thinner than the 6px corner radius. Dropping the mask there would
    // paint the picture's square corners OUTSIDE the surface's rounded
    // silhouette (a hairline bar cannot cover a 6px corner), so the
    // frame's radius stays on the draw.
    const frame = geometry.RectF.init(0, 0, 32, 16);
    const widget = Widget{
        .id = 9,
        .kind = .media_surface,
        .frame = frame,
        .image_id = 5,
        .image_fit = .contain,
        .stream_size = .{ .width = 36, .height = 16 },
        .style = .{ .radius = 6 },
    };
    var nodes: [1]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(widget, frame, &nodes);
    var commands: [6]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, .{});
    const display_list = builder.displayList();
    // Placeholder + two hairline bars + the quad.
    try std.testing.expectEqual(@as(usize, 4), display_list.commandCount());
    switch (display_list.commands[3]) {
        .draw_image => |draw| {
            try std.testing.expect(draw.dst.height < frame.height);
            try std.testing.expectEqual(@as(f32, 6), draw.radius.top_left);
            try std.testing.expectEqual(@as(f32, 6), draw.radius.bottom_right);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "a rounded pillarboxed video quad drops the radius mask; its bars keep the silhouette" {
    // A rounded surface with side bars: the picture quad sits between
    // the bars, so masking it with the frame radius would notch the
    // picture's own corners — the quad emits unmasked, and each bar
    // rounds only its outer corners.
    const frame = geometry.RectF.init(0, 4, 32, 16);
    const widget = Widget{
        .id = 9,
        .kind = .media_surface,
        .frame = frame,
        .image_id = 5,
        .image_fit = .contain,
        .stream_size = .{ .width = 240, .height = 240 },
        .style = .{ .radius = 6 },
    };
    var nodes: [1]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(widget, frame, &nodes);
    var commands: [6]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, .{});
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 4), display_list.commandCount());
    switch (display_list.commands[1]) {
        .fill_rounded_rect => |fill| {
            // Left bar: rounded on the frame's left corners only.
            try std.testing.expectEqual(@as(f32, 6), fill.radius.top_left);
            try std.testing.expectEqual(@as(f32, 6), fill.radius.bottom_left);
            try std.testing.expectEqual(@as(f32, 0), fill.radius.top_right);
            try std.testing.expectEqual(@as(f32, 0), fill.radius.bottom_right);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[2]) {
        .fill_rounded_rect => |fill| {
            // Right bar: the mirror.
            try std.testing.expectEqual(@as(f32, 0), fill.radius.top_left);
            try std.testing.expectEqual(@as(f32, 6), fill.radius.top_right);
            try std.testing.expectEqual(@as(f32, 6), fill.radius.bottom_right);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[3]) {
        .draw_image => |draw| {
            try std.testing.expectEqual(@as(f32, 0), draw.radius.top_left);
            try std.testing.expectEqual(@as(f32, 0), draw.radius.bottom_right);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "a contain video surface with unknown stream geometry keeps the placeholder draw" {
    // Pre-LOADED: no reported dimensions, so no fit math runs (nothing
    // to divide by) — the id-derived placeholder fills the frame and
    // the texture draw keeps the full frame as its dst.
    const frame = geometry.RectF.init(0, 4, 32, 16);
    const widget = Widget{
        .id = 9,
        .kind = .media_surface,
        .frame = frame,
        .image_id = 5,
        .image_fit = .contain,
    };
    var nodes: [1]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(widget, frame, &nodes);
    var commands: [4]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, .{});
    const display_list = builder.displayList();
    switch (display_list.commands[0]) {
        .fill_rounded_rect => |fill| {
            try std.testing.expectEqual(
                Fill{ .color = canvas.mediaSurfacePlaceholderColor(5) },
                fill.fill,
            );
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[1]) {
        .draw_image => |draw| {
            try expectRect(frame, draw.dst);
            try std.testing.expectEqual(ImageFit.contain, draw.fit);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "widget text fields expose textbox semantics and render focused chrome" {
    const text_field = Widget{
        .id = 8,
        .kind = .text_field,
        .frame = geometry.RectF.init(10, 12, 180, 36),
        .text = "search terms",
        .state = .{ .focused = true },
        .semantics = .{ .label = "Search" },
    };

    var nodes: [1]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(text_field, text_field.frame, &nodes);
    try std.testing.expectEqual(@as(ObjectId, 8), layout.focusTarget(null, .forward).?.id);
    try std.testing.expectEqual(WidgetKind.text_field, layout.hitTest(geometry.PointF.init(20, 24)).?.kind);

    var semantics_buffer: [1]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 1), semantics.len);
    try std.testing.expectEqual(WidgetRole.textbox, semantics[0].role);
    try std.testing.expectEqualStrings("Search", semantics[0].label);
    try std.testing.expectEqualStrings("search terms", semantics[0].text_value);
    try std.testing.expect(semantics[0].focusable);

    const tokens = DesignTokens{
        .colors = .{ .focus_ring = Color.rgb8(1, 2, 3) },
        .stroke = .{ .focus = 3 },
    };
    var commands: [4]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, text_field, tokens);
    const display_list = builder.displayList();
    // Fill, border, offset focus ring, text: focus adds a ring instead
    // of recoloring the border.
    try std.testing.expectEqual(@as(usize, 4), display_list.commandCount());
    switch (display_list.commands[2]) {
        .stroke_rect => |stroke| {
            try std.testing.expectEqual(@as(f32, 3), stroke.stroke.width);
            try expectFillColor(tokens.colors.focus_ring, stroke.stroke.fill);
            try std.testing.expectEqual(@as(f32, 10 - 2), stroke.rect.x);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[3]) {
        .draw_text => |text| try std.testing.expectEqualStrings("search terms", text.text),
        else => return error.TestUnexpectedResult,
    }
}

test "widget inputs expose textbox semantics and render house input tokens" {
    const input = Widget{
        .id = 18,
        .kind = .input,
        .frame = geometry.RectF.init(10, 12, 180, 36),
        .text = "native-sdk",
        .semantics = .{ .label = "Project name" },
    };

    var nodes: [1]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(input, input.frame, &nodes);
    try std.testing.expectEqual(@as(ObjectId, 18), layout.focusTarget(null, .forward).?.id);
    try std.testing.expectEqual(WidgetKind.input, layout.hitTest(geometry.PointF.init(20, 24)).?.kind);
    try std.testing.expectEqual(WidgetCursor.text, cursorForWidgetTarget(.input, .{}));

    var semantics_buffer: [1]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 1), semantics.len);
    try std.testing.expectEqual(WidgetRole.textbox, semantics[0].role);
    try std.testing.expectEqualStrings("Project name", semantics[0].label);
    try std.testing.expectEqualStrings("native-sdk", semantics[0].text_value);
    try std.testing.expectEqualStrings("", semantics[0].placeholder);
    try std.testing.expect(semantics[0].focusable);
    try std.testing.expect(semantics[0].actions.set_text);
    try std.testing.expect(semantics[0].actions.set_selection);

    const tokens = DesignTokens{
        .controls = .{
            .input = .{
                .background = Color.rgb8(18, 24, 30),
                .foreground = Color.rgb8(230, 236, 242),
                .border = Color.rgb8(78, 88, 98),
                .radius = 7,
                .stroke_width = 1.25,
            },
        },
    };
    var commands: [3]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, input, tokens);
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 3), display_list.commandCount());
    switch (display_list.commands[0]) {
        .fill_rounded_rect => |fill| {
            try std.testing.expectEqualDeep(Radius.all(7), fill.radius);
            try expectFillColor(Color.rgb8(18, 24, 30), fill.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[1]) {
        .stroke_rect => |stroke| {
            try std.testing.expectEqual(@as(f32, 1.25), stroke.stroke.width);
            try expectFillColor(Color.rgb8(78, 88, 98), stroke.stroke.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[2]) {
        .draw_text => |text| {
            try std.testing.expectEqualStrings("native-sdk", text.text);
            try std.testing.expectEqualDeep(Color.rgb8(230, 236, 242), text.color);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "widget text inputs render explicit placeholders without changing text value" {
    const input = Widget{
        .id = 20,
        .kind = .input,
        .frame = geometry.RectF.init(10, 12, 180, 36),
        .placeholder = "Project name",
        .semantics = .{ .label = "Name" },
    };

    var nodes: [1]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(input, input.frame, &nodes);
    var semantics_buffer: [1]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 1), semantics.len);
    try std.testing.expectEqualStrings("Name", semantics[0].label);
    try std.testing.expectEqualStrings("", semantics[0].text_value);
    try std.testing.expectEqualStrings("Project name", semantics[0].placeholder);

    const tokens = DesignTokens{
        .colors = .{ .text_muted = Color.rgb8(90, 91, 92) },
    };
    var commands: [3]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, input, tokens);
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 3), display_list.commandCount());
    switch (display_list.commands[2]) {
        .draw_text => |text| {
            try std.testing.expectEqualStrings("Project name", text.text);
            try std.testing.expectEqualDeep(Color.rgb8(90, 91, 92), text.color);
        },
        else => return error.TestUnexpectedResult,
    }

    const textarea = Widget{
        .id = 21,
        .kind = .textarea,
        .frame = geometry.RectF.init(0, 0, 180, 84),
        .placeholder = "Write a message",
        .semantics = .{ .label = "Message" },
    };
    var textarea_nodes: [1]WidgetLayoutNode = undefined;
    const textarea_layout = try layoutWidgetTree(textarea, textarea.frame, &textarea_nodes);
    var textarea_semantics_buffer: [1]WidgetSemanticsNode = undefined;
    const textarea_semantics = try textarea_layout.collectSemantics(&textarea_semantics_buffer);
    try std.testing.expectEqualStrings("", textarea_semantics[0].text_value);
    try std.testing.expectEqualStrings("Write a message", textarea_semantics[0].placeholder);
}

test "widget inputs expose required read-only and invalid form state" {
    const input = Widget{
        .id = 19,
        .kind = .input,
        .frame = geometry.RectF.init(0, 0, 180, 36),
        .text = "readonly",
        .state = .{ .required = true, .read_only = true, .invalid = true },
        .semantics = .{ .label = "Readonly project name" },
    };

    var nodes: [1]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(input, input.frame, &nodes);
    var semantics_buffer: [1]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);

    try std.testing.expectEqual(@as(usize, 1), semantics.len);
    try std.testing.expectEqual(WidgetRole.textbox, semantics[0].role);
    try std.testing.expect(semantics[0].state.required);
    try std.testing.expect(semantics[0].state.read_only);
    try std.testing.expect(semantics[0].state.invalid);
    try std.testing.expect(semantics[0].focusable);
    try std.testing.expect(!semantics[0].actions.set_text);
    try std.testing.expect(semantics[0].actions.set_selection);
}

test "widget selects expose trigger semantics and render chevron chrome" {
    const select = Widget{
        .id = 9,
        .kind = .select,
        .frame = geometry.RectF.init(10, 12, 180, 36),
        .text = "Production",
        .command = "environment.open",
        .state = .{ .focused = true },
        .semantics = .{ .label = "Environment" },
    };

    var nodes: [1]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(select, select.frame, &nodes);
    try std.testing.expectEqual(@as(ObjectId, 9), layout.focusTarget(null, .forward).?.id);
    try std.testing.expectEqual(WidgetKind.select, layout.hitTest(geometry.PointF.init(20, 24)).?.kind);

    var semantics_buffer: [1]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 1), semantics.len);
    try std.testing.expectEqual(WidgetRole.button, semantics[0].role);
    try std.testing.expectEqualStrings("Environment", semantics[0].label);
    try std.testing.expectEqualStrings("", semantics[0].placeholder);
    try std.testing.expectEqual(@as(?bool, false), semantics[0].state.expanded);
    try std.testing.expect(semantics[0].focusable);
    try std.testing.expect(semantics[0].actions.press);
    try std.testing.expect(!semantics[0].actions.set_text);

    const tokens = DesignTokens{
        .colors = .{ .focus_ring = Color.rgb8(1, 2, 3), .text_muted = Color.rgb8(90, 91, 92) },
        .stroke = .{ .focus = 3 },
        .controls = .{
            .select = .{
                .background = Color.rgb8(20, 24, 28),
                .foreground = Color.rgb8(238, 242, 246),
                .border = Color.rgb8(80, 90, 100),
                .radius = 5,
                .stroke_width = 2,
            },
        },
    };
    var commands: [7]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, select, tokens);
    const display_list = builder.displayList();
    // Fill, border, offset focus ring, text, then the registry chevron
    // (a transform pair bracketing its stroked path).
    try std.testing.expectEqual(@as(usize, 7), display_list.commandCount());
    switch (display_list.commands[0]) {
        .fill_rounded_rect => |fill| {
            try expectFillColor(Color.rgb8(20, 24, 28), fill.fill);
            try std.testing.expectEqualDeep(Radius.all(5), fill.radius);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[1]) {
        .stroke_rect => |stroke| {
            try std.testing.expectEqual(@as(f32, 2), stroke.stroke.width);
            try expectFillColor(Color.rgb8(80, 90, 100), stroke.stroke.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[2]) {
        .stroke_rect => |stroke| {
            try std.testing.expectEqual(@as(f32, 3), stroke.stroke.width);
            try expectFillColor(tokens.colors.focus_ring, stroke.stroke.fill);
            try std.testing.expectEqual(@as(f32, 10 - 2), stroke.rect.x);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[3]) {
        .draw_text => |text| {
            try std.testing.expectEqualStrings("Production", text.text);
            try std.testing.expectEqualDeep(Color.rgb8(238, 242, 246), text.color);
            try std.testing.expect(text.text_layout != null);
            try std.testing.expect(text.text_layout.?.max_width < select.frame.width);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[4]) {
        .transform => {},
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[5]) {
        .stroke_path => |stroke| try expectFillColor(Color.rgb8(238, 242, 246), stroke.stroke.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[6]) {
        .transform => {},
        else => return error.TestUnexpectedResult,
    }

    var placeholder_commands: [6]CanvasCommand = undefined;
    var placeholder_builder = Builder.init(&placeholder_commands);
    try emitWidgetTree(&placeholder_builder, .{
        .id = 10,
        .kind = .select,
        .frame = geometry.RectF.init(0, 0, 180, 36),
        .semantics = .{ .label = "Choose item" },
    }, tokens);
    var placeholder_nodes: [1]WidgetLayoutNode = undefined;
    const placeholder_layout = try layoutWidgetTree(.{
        .id = 10,
        .kind = .select,
        .frame = geometry.RectF.init(0, 0, 180, 36),
        .placeholder = "Choose item",
        .semantics = .{ .label = "Environment" },
    }, geometry.RectF.init(0, 0, 180, 36), &placeholder_nodes);
    var placeholder_semantics_buffer: [1]WidgetSemanticsNode = undefined;
    const placeholder_semantics = try placeholder_layout.collectSemantics(&placeholder_semantics_buffer);
    try std.testing.expectEqualStrings("", placeholder_semantics[0].text_value);
    try std.testing.expectEqualStrings("Choose item", placeholder_semantics[0].placeholder);

    const placeholder_list = placeholder_builder.displayList();
    switch (placeholder_list.commands[2]) {
        .draw_text => |text| {
            try std.testing.expectEqualStrings("Choose item", text.text);
            try std.testing.expectEqualDeep(Color.rgb8(90, 91, 92), text.color);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "widget search fields expose textbox semantics and render search chrome" {
    const search_field = Widget{
        .id = 10,
        .kind = .search_field,
        .frame = geometry.RectF.init(10, 12, 220, 36),
        .text = "customers",
        .text_selection = TextSelection.collapsed(9),
        .state = .{ .focused = true },
        .semantics = .{ .label = "Search customers" },
    };

    var nodes: [1]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(search_field, search_field.frame, &nodes);
    try std.testing.expectEqual(@as(ObjectId, 10), layout.focusTarget(null, .forward).?.id);
    try std.testing.expectEqual(WidgetKind.search_field, layout.hitTest(geometry.PointF.init(20, 24)).?.kind);

    var semantics_buffer: [1]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 1), semantics.len);
    try std.testing.expectEqual(WidgetRole.textbox, semantics[0].role);
    try std.testing.expectEqualStrings("Search customers", semantics[0].label);
    try std.testing.expectEqualStrings("customers", semantics[0].text_value);
    try std.testing.expect(semantics[0].focusable);
    try std.testing.expectEqualDeep(TextRange.init(9, 9), semantics[0].text_selection.?);
    const search_geometry = layout.textGeometry(10, .{}).?;
    try expectRectApprox(geometry.RectF.init(111.818, 21.25, 1, 17.5), search_geometry.caret_bounds.?);
    try std.testing.expectEqual(@as(usize, 0), search_geometry.selection_rect_count);

    const tokens = DesignTokens{
        .colors = .{ .focus_ring = Color.rgb8(1, 2, 3), .text_muted = Color.rgb8(90, 91, 92) },
        .stroke = .{ .focus = 3 },
    };
    var commands: [13]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, search_field, tokens);
    const display_list = builder.displayList();
    // Fill, border, offset focus ring, then the vector magnifier
    // (transform, circle + handle stroke paths, inverse transform),
    // text, caret, and the trailing clear affordance (transform, two
    // stroke paths, inverse transform) since the field holds text.
    try std.testing.expectEqual(@as(usize, 13), display_list.commandCount());
    switch (display_list.commands[2]) {
        .stroke_rect => |stroke| {
            try std.testing.expectEqual(@as(f32, 3), stroke.stroke.width);
            try expectFillColor(tokens.colors.focus_ring, stroke.stroke.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    // The magnifier is the registry `search` icon: a true circle as a
    // stroked path, not the old hand-drawn line box.
    switch (display_list.commands[4]) {
        .stroke_path => |stroke| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(10, 4)), stroke.id);
            const registered = canvas.icons.find("search").?;
            try std.testing.expectEqual(registered.elements.ptr, stroke.elements.ptr);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[7]) {
        .draw_text => |text| try std.testing.expectEqualStrings("customers", text.text),
        else => return error.TestUnexpectedResult,
    }
    // The built-in clear affordance: the registry `x` icon over the
    // trailing inset (its two strokes land on part slots 16 and 18).
    switch (display_list.commands[10]) {
        .stroke_path => |stroke| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(10, 16)), stroke.id);
            const registered = canvas.icons.find("x").?;
            try std.testing.expectEqual(registered.elements.ptr, stroke.elements.ptr);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "widget comboboxes expose textbox semantics and render trigger chrome" {
    const combobox = Widget{
        .id = 14,
        .kind = .combobox,
        .frame = geometry.RectF.init(10, 12, 220, 36),
        .text = "components",
        .command = "components.open",
        .semantics = .{ .label = "Component combobox" },
    };

    var nodes: [1]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(combobox, combobox.frame, &nodes);
    try std.testing.expectEqual(@as(ObjectId, 14), layout.focusTarget(null, .forward).?.id);
    try std.testing.expectEqual(WidgetKind.combobox, layout.hitTest(geometry.PointF.init(20, 24)).?.kind);

    var semantics_buffer: [1]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 1), semantics.len);
    try std.testing.expectEqual(WidgetRole.textbox, semantics[0].role);
    try std.testing.expectEqualStrings("Component combobox", semantics[0].label);
    try std.testing.expectEqualStrings("components", semantics[0].text_value);
    try std.testing.expectEqual(@as(?bool, false), semantics[0].state.expanded);
    try std.testing.expect(semantics[0].actions.press);
    try std.testing.expect(semantics[0].actions.set_text);
    try std.testing.expect(semantics[0].actions.set_selection);

    var commands: [10]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, combobox, .{});
    const display_list = builder.displayList();
    // Fill, border, vector magnifier (4 commands), text, then the
    // registry chevron-down (a transform pair bracketing its stroked
    // path) — the same icon register the select trigger draws.
    try std.testing.expectEqual(@as(usize, 10), display_list.commandCount());
    switch (display_list.commands[6]) {
        .draw_text => |text| {
            try std.testing.expectEqualStrings("components", text.text);
            try std.testing.expect(text.text_layout != null);
            try std.testing.expect(text.text_layout.?.max_width < combobox.frame.width);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[7]) {
        .transform => {},
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[8]) {
        // The chevron's stroke path lands on slot 13 (the icon's shape
        // range starts at 12: fill slot skipped for a stroke-only icon).
        .stroke_path => |stroke| try std.testing.expectEqual(@as(ObjectId, widgetPartId(14, 13)), stroke.id),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[9]) {
        .transform => {},
        else => return error.TestUnexpectedResult,
    }
}

test "widget textareas expose multiline textbox semantics and render wrapped text" {
    const textarea = Widget{
        .id = 12,
        .kind = .textarea,
        .frame = geometry.RectF.init(10, 12, 150, 84),
        .text = "First line Second line",
        .text_selection = TextSelection.collapsed(10),
        .state = .{ .focused = true },
        .semantics = .{ .label = "Message" },
    };

    var nodes: [1]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(textarea, textarea.frame, &nodes);
    try std.testing.expectEqual(@as(ObjectId, 12), layout.focusTarget(null, .forward).?.id);
    try std.testing.expectEqual(WidgetKind.textarea, layout.hitTest(geometry.PointF.init(20, 24)).?.kind);

    var semantics_buffer: [1]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 1), semantics.len);
    try std.testing.expectEqual(WidgetRole.textbox, semantics[0].role);
    try std.testing.expectEqualStrings("Message", semantics[0].label);
    try std.testing.expectEqualStrings("First line Second line", semantics[0].text_value);
    try std.testing.expect(semantics[0].focusable);
    try std.testing.expect(semantics[0].actions.set_text);
    try std.testing.expect(semantics[0].actions.set_selection);

    const text_geometry = layout.textGeometry(12, .{}).?;
    try std.testing.expect(text_geometry.caret_bounds != null);
    try std.testing.expectEqual(@as(usize, 0), text_geometry.selection_rect_count);

    const offset = textOffsetForWidgetPoint(textarea, geometry.PointF.init(28, 36), .{}) orelse return error.TestUnexpectedResult;
    try std.testing.expect(offset <= textarea.text.len);

    var commands: [7]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, textarea, .{});
    const display_list = builder.displayList();
    // Fill, border, offset focus ring, clip, text, caret, pop.
    try std.testing.expectEqual(@as(usize, 7), display_list.commandCount());
    switch (display_list.commands[3]) {
        .push_clip => |clip| try expectRectApprox(textInputViewportForWidget(textarea, .{}).?, clip.rect),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[4]) {
        .draw_text => |text| {
            try std.testing.expectEqualStrings("First line Second line", text.text);
            try std.testing.expect(text.text_layout != null);
            try std.testing.expectEqual(TextWrap.word, text.text_layout.?.wrap);
            try std.testing.expect(text.origin.y < textarea.frame.y + textarea.frame.height * 0.5);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[5]) {
        // The caret is a filled one-point bar in the field's text ink —
        // full reading contrast, not the soft focus-ring gray.
        .fill_rect => |caret| {
            try expectFillColor(ColorTokens.light().text, caret.fill);
            try std.testing.expectEqual(@as(f32, 1), caret.rect.width);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(CanvasCommand.pop_clip, display_list.commands[6]);
}

test "widget text fields render selection caret and composition ranges" {
    // The caret and composition underline take the field's own text ink
    // (the control foreground here), and the selection inverts: solid
    // accent fill under accent-foreground glyphs.
    const ink_color = Color.rgb8(40, 80, 120);
    const tokens = DesignTokens{
        .colors = .{ .focus_ring = Color.rgb8(10, 20, 30) },
        .controls = .{
            .text_field = .{ .foreground = ink_color },
        },
    };
    const composing = Widget{
        .id = 9,
        .kind = .text_field,
        .frame = geometry.RectF.init(8, 10, 180, 36),
        .text = "abcdef",
        .text_selection = .{ .anchor = 1, .focus = 4 },
        .text_composition = TextRange.init(2, 4),
        .state = .{ .focused = true },
    };

    var nodes: [1]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(composing, composing.frame, &nodes);

    var semantics_buffer: [1]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 1), semantics.len);
    try std.testing.expectEqualDeep(TextRange.init(1, 4), semantics[0].text_selection.?);
    try std.testing.expectEqualDeep(TextRange.init(2, 4), semantics[0].text_composition.?);
    const text_geometry = layout.textGeometry(9, .{}).?;
    try std.testing.expect(text_geometry.caret_bounds == null);
    try std.testing.expectEqual(@as(usize, 1), text_geometry.selection_rect_count);
    try expectRectApprox(geometry.RectF.init(27.98, 19.25, 24.472, 17.5), text_geometry.selection_bounds.?);
    try std.testing.expectEqual(@as(usize, 1), text_geometry.composition_rect_count);
    try expectRectApprox(geometry.RectF.init(36.352, 19.25, 16.1, 17.5), text_geometry.composition_bounds.?);

    var commands: [10]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, tokens);
    const display_list = builder.displayList();
    // Fill, border, offset focus ring, selection fill, text, the
    // clipped selected-glyph repaint (clip + text + pop), composition.
    try std.testing.expectEqual(@as(usize, 9), display_list.commandCount());
    const selection_fill_rect = switch (display_list.commands[3]) {
        .fill_rect => |selection| blk: {
            try expectFillColor(textSelectionFillColor(composing, tokens), selection.fill);
            break :blk selection.rect;
        },
        else => return error.TestUnexpectedResult,
    };
    switch (display_list.commands[4]) {
        .draw_text => |text| {
            try std.testing.expectEqualStrings("abcdef", text.text);
            try std.testing.expectEqualDeep(ink_color, text.color);
            try std.testing.expect(text.text_layout != null);
            try std.testing.expectEqual(TextWrap.none, text.text_layout.?.wrap);
        },
        else => return error.TestUnexpectedResult,
    }
    // The repaint clip shares the highlight's exact rect, so the glyph
    // ink swaps precisely at the fill edge.
    switch (display_list.commands[5]) {
        .push_clip => |clip| try expectRectApprox(selection_fill_rect, clip.rect),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[6]) {
        .draw_text => |text| {
            try std.testing.expectEqualStrings("abcdef", text.text);
            try std.testing.expectEqualDeep(textSelectionTextColor(composing, tokens), text.color);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(CanvasCommand.pop_clip, display_list.commands[7]);
    switch (display_list.commands[8]) {
        .fill_rect => |underline| try expectFillColor(ink_color, underline.fill),
        else => return error.TestUnexpectedResult,
    }

    const caret = Widget{
        .id = 10,
        .kind = .text_field,
        .frame = geometry.RectF.init(8, 10, 180, 36),
        .text = "abcd",
        .text_selection = TextSelection.collapsed(2),
        .state = .{ .focused = true },
    };
    var caret_commands: [5]CanvasCommand = undefined;
    var caret_builder = Builder.init(&caret_commands);
    try emitWidgetTree(&caret_builder, caret, tokens);
    const caret_display_list = caret_builder.displayList();
    try std.testing.expectEqual(@as(usize, 5), caret_display_list.commandCount());
    switch (caret_display_list.commands[4]) {
        .fill_rect => |caret_bar| {
            try expectFillColor(ink_color, caret_bar.fill);
            try std.testing.expectEqual(@as(f32, 1), caret_bar.rect.width);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "text editing affordance colors resolve tokens and per-widget overrides" {
    const tokens = DesignTokens{};
    const field = Widget{ .id = 3, .kind = .text_field, .frame = geometry.RectF.init(0, 0, 100, 32), .text = "abc" };

    // Defaults: caret/underline take the text ink; the selection takes
    // the solid accent with the accent foreground for selected glyphs;
    // static text keeps a translucent accent wash under untouched inks.
    try std.testing.expectEqualDeep(tokens.colors.text, textEditingInkColor(field, tokens));
    try std.testing.expectEqualDeep(tokens.colors.accent, textSelectionFillColor(field, tokens));
    try std.testing.expectEqualDeep(tokens.colors.accent_text, textSelectionTextColor(field, tokens));
    const wash = staticTextSelectionFillColor(field, tokens);
    try std.testing.expectEqual(tokens.colors.accent.r, wash.r);
    try std.testing.expectEqual(tokens.colors.accent.g, wash.g);
    try std.testing.expectEqual(tokens.colors.accent.b, wash.b);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), wash.a, 0.001);

    // Per-widget style overrides win: foreground drives the ink, accent
    // and accent_foreground drive the selection pair.
    var styled = field;
    styled.style.foreground = Color.rgb8(1, 2, 3);
    styled.style.accent = Color.rgb8(4, 5, 6);
    styled.style.accent_foreground = Color.rgb8(7, 8, 9);
    try std.testing.expectEqualDeep(Color.rgb8(1, 2, 3), textEditingInkColor(styled, tokens));
    try std.testing.expectEqualDeep(Color.rgb8(4, 5, 6), textSelectionFillColor(styled, tokens));
    try std.testing.expectEqualDeep(Color.rgb8(7, 8, 9), textSelectionTextColor(styled, tokens));
    const styled_wash = staticTextSelectionFillColor(styled, tokens);
    try std.testing.expectEqual(Color.rgb8(4, 5, 6).r, styled_wash.r);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), styled_wash.a, 0.001);

    // A disabled field's ink mutes with its text.
    var disabled = field;
    disabled.state.disabled = true;
    try std.testing.expectEqualDeep(tokens.colors.text_muted, textEditingInkColor(disabled, tokens));
}

test "widget text fields render wrapped selection geometry" {
    const tokens = DesignTokens{
        .colors = .{ .focus_ring = Color.rgb8(10, 20, 30) },
        .typography = .{ .body_size = 10 },
        .spacing = .{ .sm = 4, .md = 4 },
    };
    const field = Widget{
        .id = 11,
        .kind = .text_field,
        .frame = geometry.RectF.init(4, 6, 28, 60),
        .text = "AB CD",
        .text_selection = .{ .anchor = 1, .focus = 5 },
        .state = .{ .focused = true },
    };

    var commands: [12]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, field, tokens);

    var nodes: [1]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(field, field.frame, &nodes);
    const text_geometry = layout.textGeometry(11, tokens).?;
    try std.testing.expectEqual(@as(usize, 2), text_geometry.selection_rect_count);
    try expectRectApprox(geometry.RectF.init(8, 10, 14.13, 25), text_geometry.selection_bounds.?);

    const display_list = builder.displayList();
    // Fill, border, offset focus ring, two selection rects, text, then
    // the selected-glyph repaint per rect (clip + text + pop, twice).
    try std.testing.expectEqual(@as(usize, 12), display_list.commandCount());
    switch (display_list.commands[3]) {
        .fill_rect => |selection| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(11, 3)), selection.id);
            try expectRectApprox(geometry.RectF.init(14.7, 10, 6.8, 12.5), selection.rect);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[4]) {
        .fill_rect => |selection| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(11, 13)), selection.id);
            try expectRectApprox(geometry.RectF.init(8, 22.5, 14.13, 12.5), selection.rect);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[5]) {
        .draw_text => |text| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(11, 4)), text.id);
            try std.testing.expectEqualStrings("AB CD", text.text);
            try std.testing.expectEqual(TextWrap.word, text.text_layout.?.wrap);
            try std.testing.expectEqual(@as(f32, 20), text.text_layout.?.max_width);
        },
        else => return error.TestUnexpectedResult,
    }
    // Each repaint clip pairs with one full-run redraw in the selection
    // foreground; the clip rects mirror the two highlight rects above.
    switch (display_list.commands[6]) {
        .push_clip => |clip| try expectRectApprox(geometry.RectF.init(14.7, 10, 6.8, 12.5), clip.rect),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[7]) {
        .draw_text => |text| try std.testing.expectEqualDeep(textSelectionTextColor(field, tokens), text.color),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(CanvasCommand.pop_clip, display_list.commands[8]);
    switch (display_list.commands[9]) {
        .push_clip => |clip| try expectRectApprox(geometry.RectF.init(8, 22.5, 14.13, 12.5), clip.rect),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[10]) {
        .draw_text => |text| try std.testing.expectEqualStrings("AB CD", text.text),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(CanvasCommand.pop_clip, display_list.commands[11]);
}

test "widget text fields map pointer positions to caret selections" {
    const tokens = DesignTokens{};
    const field = Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(10, 12, 160, 32),
        .text = "AéB",
    };
    try std.testing.expectEqual(@as(usize, 0), textOffsetForWidgetPoint(field, geometry.PointF.init(18, 24), tokens).?);
    try std.testing.expectEqual(@as(usize, 1), textOffsetForWidgetPoint(field, geometry.PointF.init(27, 24), tokens).?);
    try std.testing.expectEqual(@as(usize, 3), textOffsetForWidgetPoint(field, geometry.PointF.init(37, 24), tokens).?);
    try std.testing.expectEqual(@as(usize, 4), textOffsetForWidgetPoint(field, geometry.PointF.init(80, 24), tokens).?);
    try std.testing.expectEqualDeep(TextSelection.collapsed(3), textSelectionForWidgetPoint(field, geometry.PointF.init(37, 24), null, tokens).?);
    try std.testing.expectEqualDeep(TextSelection{ .anchor = 1, .focus = 4 }, textSelectionForWidgetPoint(field, geometry.PointF.init(80, 24), 1, tokens).?);

    const search = Widget{
        .id = 3,
        .kind = .search_field,
        .frame = geometry.RectF.init(10, 52, 180, 32),
        .text = "Find",
    };
    try std.testing.expectEqual(@as(usize, 0), textOffsetForWidgetPoint(search, geometry.PointF.init(24, 64), tokens).?);
    try std.testing.expectEqual(@as(usize, 1), textOffsetForWidgetPoint(search, geometry.PointF.init(48, 64), tokens).?);
    try std.testing.expect(textOffsetForWidgetPoint(.{ .kind = .text_field, .state = .{ .disabled = true } }, geometry.PointF.init(0, 0), tokens) == null);

    const wrapped_tokens = DesignTokens{
        .typography = .{ .body_size = 10 },
        .spacing = .{ .sm = 4, .md = 4 },
    };
    const wrapped = Widget{
        .id = 4,
        .kind = .text_field,
        .frame = geometry.RectF.init(4, 6, 28, 60),
        .text = "AB CD",
    };
    try std.testing.expectEqual(@as(usize, 4), textOffsetForWidgetPoint(wrapped, geometry.PointF.init(14, 24), wrapped_tokens).?);
}

test "widget tooltip emits overlay chrome and tooltip semantics" {
    const tokens = DesignTokens{};
    const tooltip = Widget{
        .id = 1,
        .kind = .tooltip,
        .frame = geometry.RectF.init(10, 12, 140, 28),
        .text = "Saved",
    };

    var nodes: [1]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(tooltip, tooltip.frame, &nodes);

    var commands: [4]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, tokens);
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 3), display_list.commandCount());
    switch (display_list.commands[0]) {
        .shadow => |shadow| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(1, 1)), shadow.id);
            try expectRect(geometry.RectF.init(10, 12, 140, 28), shadow.rect);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[1]) {
        .fill_rounded_rect => |fill| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(1, 2)), fill.id);
            try expectFillColor(tokens.colors.accent, fill.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[2]) {
        .draw_text => |text| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(1, 3)), text.id);
            try std.testing.expectEqualStrings("Saved", text.text);
            try std.testing.expectEqualDeep(tokens.colors.accent_text, text.color);
        },
        else => return error.TestUnexpectedResult,
    }

    try std.testing.expect(layout.hitTest(geometry.PointF.init(20, 20)) == null);

    var semantics_buffer: [1]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 1), semantics.len);
    try std.testing.expectEqual(WidgetRole.tooltip, semantics[0].role);
    try std.testing.expectEqualStrings("Saved", semantics[0].label);
    try std.testing.expect(!semantics[0].focusable);
}

test "widget popover emits overlay chrome and routes child events" {
    const children = [_]Widget{.{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(0, 0, 100, 32),
        .text = "Open",
    }};
    const popover = Widget{
        .id = 1,
        .kind = .popover,
        .frame = geometry.RectF.init(20, 24, 180, 120),
        .layout = .{ .padding = geometry.InsetsF.all(10) },
        .semantics = .{ .label = "Command palette" },
        .children = &children,
    };

    var nodes: [3]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(popover, popover.frame, &nodes);
    try std.testing.expectEqual(@as(usize, 2), layout.nodeCount());
    try expectLayoutFrame(layout, 1, geometry.RectF.init(20, 24, 180, 120));
    try expectLayoutFrame(layout, 2, geometry.RectF.init(30, 34, 100, 32));

    var commands: [8]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, .{});
    const display_list = builder.displayList();
    // Popover shadow + fill + border, then the flat child button's
    // fill + border + label.
    try std.testing.expectEqual(@as(usize, 6), display_list.commandCount());
    try std.testing.expect(display_list.commands[0] == .shadow);
    try std.testing.expectEqual(@as(?ObjectId, widgetPartId(1, 2)), display_list.commands[1].objectId());
    try std.testing.expect(display_list.commands[1] == .fill_rounded_rect);
    try std.testing.expectEqual(@as(?ObjectId, widgetPartId(2, 1)), display_list.commands[3].objectId());
    try std.testing.expect(display_list.commands[3] == .fill_rounded_rect);

    try std.testing.expectEqual(@as(ObjectId, 2), layout.hitTest(geometry.PointF.init(40, 44)).?.id);
    const blank_hit = layout.hitTest(geometry.PointF.init(190, 130)).?;
    try std.testing.expectEqual(@as(ObjectId, 1), blank_hit.id);
    try std.testing.expectEqual(WidgetKind.popover, blank_hit.kind);
    try std.testing.expect(layout.hitTest(geometry.PointF.init(10, 10)) == null);

    var route_buffer: [3]WidgetEventRouteEntry = undefined;
    const route = try layout.routePointerEvent(.{ .phase = .down, .point = geometry.PointF.init(40, 44) }, &route_buffer);
    try std.testing.expectEqual(@as(usize, 3), route.entries.len);
    try expectRouteEntry(route.entries[0], .capture, 1);
    try expectRouteEntry(route.entries[1], .target, 2);
    try expectRouteEntry(route.entries[2], .bubble, 1);

    var semantics_buffer: [2]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 2), semantics.len);
    try std.testing.expectEqual(WidgetRole.dialog, semantics[0].role);
    try std.testing.expectEqualStrings("Command palette", semantics[0].label);
    try std.testing.expect(semantics[0].parent_index == null);
    try std.testing.expectEqual(WidgetRole.button, semantics[1].role);
    try std.testing.expectEqual(@as(?usize, 0), semantics[1].parent_index);
    try std.testing.expect(semantics[1].focusable);
}

test "widget menu surface groups menu items semantically" {
    const items = [_]Widget{
        .{
            .id = 2,
            .kind = .menu_item,
            .text = "Rename",
            .state = .{ .selected = true },
        },
        .{
            .id = 3,
            .kind = .menu_item,
            .text = "Archive",
        },
    };
    const menu = Widget{
        .id = 1,
        .kind = .menu_surface,
        .frame = geometry.RectF.init(20, 24, 180, 90),
        .layout = .{ .padding = geometry.InsetsF.all(6), .gap = 2 },
        .semantics = .{ .label = "More actions" },
        .children = &items,
    };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(menu, menu.frame, &nodes);
    try std.testing.expectEqual(@as(usize, 3), layout.nodeCount());
    try expectLayoutFrame(layout, 1, geometry.RectF.init(20, 24, 180, 90));
    // Menu rows sit on the comfortable 32px band.
    try expectLayoutFrame(layout, 2, geometry.RectF.init(26, 30, 168, 32));
    try expectLayoutFrame(layout, 3, geometry.RectF.init(26, 64, 168, 32));

    var commands: [10]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, .{});
    const display_list = builder.displayList();
    // Surface shadow/fill/border, then the committed row's label plus
    // its trailing checkmark (a transform pair bracketing the stroked
    // check path — commit paints a marker, not a wash), then the idle
    // row's label.
    try std.testing.expectEqual(@as(usize, 8), display_list.commandCount());
    try std.testing.expect(display_list.commands[0] == .shadow);
    try std.testing.expectEqual(@as(?ObjectId, widgetPartId(1, 2)), display_list.commands[1].objectId());
    try std.testing.expectEqual(@as(?ObjectId, widgetPartId(2, 3)), display_list.commands[3].objectId());
    try std.testing.expectEqual(@as(?ObjectId, widgetPartId(2, 13)), display_list.commands[5].objectId());
    try std.testing.expect(display_list.commands[5] == .stroke_path);

    try std.testing.expectEqual(@as(ObjectId, 2), layout.focusTarget(null, .forward).?.id);
    try std.testing.expectEqual(@as(ObjectId, 3), layout.focusTarget(2, .forward).?.id);
    try std.testing.expectEqual(@as(ObjectId, 2), layout.hitTest(geometry.PointF.init(34, 38)).?.id);
    const blank_hit = layout.hitTest(geometry.PointF.init(190, 108)).?;
    try std.testing.expectEqual(@as(ObjectId, 1), blank_hit.id);
    try std.testing.expectEqual(WidgetKind.menu_surface, blank_hit.kind);

    var route_buffer: [3]WidgetEventRouteEntry = undefined;
    const route = try layout.routePointerEvent(.{ .phase = .down, .point = geometry.PointF.init(34, 38) }, &route_buffer);
    try std.testing.expectEqual(@as(usize, 3), route.entries.len);
    try expectRouteEntry(route.entries[0], .capture, 1);
    try expectRouteEntry(route.entries[1], .target, 2);
    try expectRouteEntry(route.entries[2], .bubble, 1);

    var semantics_buffer: [3]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 3), semantics.len);
    try std.testing.expectEqual(WidgetRole.menu, semantics[0].role);
    try std.testing.expectEqualStrings("More actions", semantics[0].label);
    try std.testing.expect(semantics[0].parent_index == null);
    try std.testing.expectEqual(WidgetRole.menuitem, semantics[1].role);
    try std.testing.expectEqualStrings("Rename", semantics[1].label);
    try std.testing.expectEqual(@as(?usize, 0), semantics[1].parent_index);
    try std.testing.expectEqual(@as(?f32, 1), semantics[1].value);
    try std.testing.expect(semantics[1].state.selected);
    try std.testing.expect(semantics[1].focusable);
    try std.testing.expect(semantics[1].actions.press);
    try std.testing.expect(semantics[1].actions.select);
    try std.testing.expectEqual(WidgetRole.menuitem, semantics[2].role);
    try std.testing.expectEqualStrings("Archive", semantics[2].label);
    try std.testing.expectEqual(@as(?usize, 0), semantics[2].parent_index);
    try std.testing.expectEqual(@as(?f32, 0), semantics[2].value);
    try std.testing.expect(!semantics[2].state.selected);
    try std.testing.expect(semantics[2].actions.press);
    try std.testing.expect(semantics[2].actions.select);
}

test "widget dropdown menus expose menu semantics with house surface chrome" {
    const items = [_]Widget{
        .{
            .id = 12,
            .kind = .menu_item,
            .text = "Profile",
        },
        .{
            .id = 13,
            .kind = .separator,
            .frame = geometry.RectF.init(0, 0, 128, 1),
        },
        .{
            .id = 14,
            .kind = .menu_item,
            .text = "Sign out",
            .variant = .destructive,
        },
    };
    const dropdown = Widget{
        .id = 11,
        .kind = .dropdown_menu,
        .frame = geometry.RectF.init(12, 16, 160, 112),
        .layout = builtinComponentWidget(.dropdown_menu, .{}).layout,
        .semantics = .{ .label = "Account menu" },
        .children = &items,
    };
    const tokens = DesignTokens{
        .controls = .{
            .dropdown_menu = .{
                .background = Color.rgb8(8, 9, 10),
                .border = Color.rgb8(60, 70, 80),
                .stroke_width = 2,
            },
        },
    };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTreeWithTokens(dropdown, dropdown.frame, tokens, &nodes);
    try std.testing.expectEqual(@as(usize, 4), layout.nodeCount());
    try expectLayoutFrame(layout, 11, geometry.RectF.init(12, 16, 160, 112));
    try expectLayoutFrame(layout, 12, geometry.RectF.init(16, 20, 152, 32));
    try expectLayoutFrame(layout, 13, geometry.RectF.init(16, 54, 128, 1));
    try expectLayoutFrame(layout, 14, geometry.RectF.init(16, 57, 152, 32));
    try std.testing.expectEqual(@as(ObjectId, 12), layout.focusTarget(null, .forward).?.id);
    try std.testing.expectEqual(@as(ObjectId, 14), layout.focusTarget(12, .forward).?.id);
    const blank_hit = layout.hitTest(geometry.PointF.init(168, 124)).?;
    try std.testing.expectEqual(@as(ObjectId, 11), blank_hit.id);
    try std.testing.expectEqual(WidgetKind.dropdown_menu, blank_hit.kind);

    var semantics_buffer: [4]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 3), semantics.len);
    try std.testing.expectEqual(WidgetRole.menu, semantics[0].role);
    try std.testing.expectEqualStrings("Account menu", semantics[0].label);
    try std.testing.expectEqual(@as(?bool, true), semantics[0].state.expanded);
    try std.testing.expectEqual(WidgetRole.menuitem, semantics[1].role);
    try std.testing.expectEqualStrings("Profile", semantics[1].label);
    try std.testing.expect(semantics[1].actions.press);
    try std.testing.expect(semantics[1].actions.select);
    try std.testing.expectEqual(WidgetRole.menuitem, semantics[2].role);
    try std.testing.expectEqualStrings("Sign out", semantics[2].label);

    var commands: [8]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, tokens);
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 8), display_list.commandCount());
    try std.testing.expect(display_list.commands[0] == .shadow);
    switch (display_list.commands[1]) {
        .fill_rounded_rect => |fill| try expectFillColor(Color.rgb8(8, 9, 10), fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[2]) {
        .stroke_rect => |stroke| {
            try expectFillColor(Color.rgb8(60, 70, 80), stroke.stroke.fill);
            try std.testing.expectEqual(@as(f32, 2), stroke.stroke.width);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "widget list item and segmented controls expose selectable semantics" {
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .list_item,
            .frame = geometry.RectF.init(8, 8, 160, 32),
            .text = "Inbox",
            .state = .{ .selected = true },
        },
        .{
            .id = 3,
            .kind = .segmented_control,
            .frame = geometry.RectF.init(8, 48, 96, 32),
            .text = "Open",
            .value = 1,
        },
    };
    const root = Widget{ .kind = .stack, .children = &children };

    var nodes: [3]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 200, 100), &nodes);
    try std.testing.expectEqual(@as(ObjectId, 2), layout.focusTarget(null, .forward).?.id);
    try std.testing.expectEqual(@as(ObjectId, 3), layout.focusTarget(2, .forward).?.id);
    try std.testing.expectEqual(WidgetKind.list_item, layout.hitTest(geometry.PointF.init(20, 20)).?.kind);

    var semantics_buffer: [2]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 2), semantics.len);
    try std.testing.expectEqual(WidgetRole.listitem, semantics[0].role);
    try std.testing.expectEqualStrings("Inbox", semantics[0].label);
    try std.testing.expectEqual(@as(?f32, 1), semantics[0].value);
    try std.testing.expect(semantics[0].focusable);
    try std.testing.expectEqual(WidgetRole.tab, semantics[1].role);
    try std.testing.expectEqualStrings("Open", semantics[1].label);
    try std.testing.expectEqual(@as(?f32, 1), semantics[1].value);
}

test "widget data grids expose row and column semantics" {
    const header_cells = [_]Widget{
        .{ .id = 3, .kind = .data_cell, .text = "Project", .layout = .{ .grow = 1 } },
        .{ .id = 4, .kind = .data_cell, .text = "Status", .layout = .{ .grow = 1 } },
    };
    const row_cells = [_]Widget{
        .{ .id = 6, .kind = .data_cell, .text = "Edge API", .layout = .{ .grow = 1 } },
        .{ .id = 7, .kind = .data_cell, .text = "Live", .layout = .{ .grow = 1 } },
    };
    const rows = [_]Widget{
        .{ .id = 2, .kind = .data_row, .children = &header_cells },
        .{ .id = 5, .kind = .data_row, .children = &row_cells },
    };
    const grid = Widget{
        .id = 1,
        .kind = .data_grid,
        .text = "Deployments",
        .layout = .{ .gap = 2 },
        .children = &rows,
    };

    var nodes: [8]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(grid, geometry.RectF.init(0, 0, 320, 180), &nodes);
    try expectLayoutFrame(layout, 2, geometry.RectF.init(0, 0, 320, 36));
    try expectLayoutFrame(layout, 3, geometry.RectF.init(0, 0, 160, 36));
    try expectLayoutFrame(layout, 5, geometry.RectF.init(0, 38, 320, 36));
    try expectLayoutFrame(layout, 6, geometry.RectF.init(0, 38, 160, 36));
    var semantics_buffer: [8]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);

    try std.testing.expectEqual(@as(usize, 7), semantics.len);
    try std.testing.expectEqual(WidgetRole.grid, semantics[0].role);
    try std.testing.expect(semantics[0].grid_row_index == null);
    try std.testing.expect(semantics[0].grid_column_index == null);
    try std.testing.expectEqual(@as(?usize, 2), semantics[0].grid_row_count);
    try std.testing.expectEqual(@as(?usize, 2), semantics[0].grid_column_count);

    try std.testing.expectEqual(WidgetRole.row, semantics[1].role);
    try std.testing.expectEqual(@as(?usize, 0), semantics[1].grid_row_index);
    try std.testing.expect(semantics[1].grid_column_index == null);
    try std.testing.expectEqual(@as(?usize, 2), semantics[1].grid_row_count);
    try std.testing.expectEqual(@as(?usize, 2), semantics[1].grid_column_count);

    try std.testing.expectEqual(WidgetRole.gridcell, semantics[2].role);
    try std.testing.expectEqualStrings("Project", semantics[2].label);
    try std.testing.expectEqual(@as(?usize, 0), semantics[2].grid_row_index);
    try std.testing.expectEqual(@as(?usize, 0), semantics[2].grid_column_index);
    try std.testing.expectEqual(@as(?usize, 2), semantics[2].grid_row_count);
    try std.testing.expectEqual(@as(?usize, 2), semantics[2].grid_column_count);

    try std.testing.expectEqual(WidgetRole.gridcell, semantics[5].role);
    try std.testing.expectEqualStrings("Edge API", semantics[5].label);
    try std.testing.expectEqual(@as(?usize, 1), semantics[5].grid_row_index);
    try std.testing.expectEqual(@as(?usize, 0), semantics[5].grid_column_index);
    try std.testing.expectEqual(@as(?usize, 2), semantics[5].grid_row_count);
    try std.testing.expectEqual(@as(?usize, 2), semantics[5].grid_column_count);
}

test "widget tables expose grid semantics and scroll intents" {
    const header_cells = [_]Widget{
        .{ .id = 23, .kind = .data_cell, .text = "Component", .layout = .{ .grow = 1 } },
        .{ .id = 24, .kind = .data_cell, .text = "State", .layout = .{ .grow = 1 } },
    };
    const row_cells = [_]Widget{
        .{ .id = 26, .kind = .data_cell, .text = "Dropdown Menu", .layout = .{ .grow = 1 } },
        .{ .id = 27, .kind = .data_cell, .text = "Finished", .layout = .{ .grow = 1 } },
    };
    const rows = [_]Widget{
        .{ .id = 22, .kind = .data_row, .children = &header_cells },
        .{ .id = 25, .kind = .data_row, .children = &row_cells },
    };
    const table = Widget{
        .id = 21,
        .kind = .table,
        .frame = geometry.RectF.init(0, 0, 320, 72),
        .text = "Built-in components",
        .layout = .{ .gap = 2 },
        .children = &rows,
    };

    var nodes: [8]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(table, table.frame, &nodes);
    try expectLayoutFrame(layout, 22, geometry.RectF.init(0, 0, 320, 36));
    try expectLayoutFrame(layout, 23, geometry.RectF.init(0, 0, 160, 36));
    try expectLayoutFrame(layout, 25, geometry.RectF.init(0, 38, 320, 36));
    try expectLayoutFrame(layout, 26, geometry.RectF.init(0, 38, 160, 36));

    var semantics_buffer: [8]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 7), semantics.len);
    try std.testing.expectEqual(WidgetRole.grid, semantics[0].role);
    try std.testing.expectEqualStrings("Built-in components", semantics[0].label);
    try std.testing.expectEqual(@as(?usize, 2), semantics[0].grid_row_count);
    try std.testing.expectEqual(@as(?usize, 2), semantics[0].grid_column_count);
    try std.testing.expectEqual(WidgetRole.row, semantics[1].role);
    try std.testing.expectEqual(@as(?usize, 0), semantics[1].grid_row_index);
    try std.testing.expectEqual(WidgetRole.gridcell, semantics[2].role);
    try std.testing.expectEqualStrings("Component", semantics[2].label);
    try std.testing.expectEqual(@as(?usize, 0), semantics[2].grid_column_index);
    try std.testing.expectEqual(WidgetRole.gridcell, semantics[5].role);
    try std.testing.expectEqualStrings("Dropdown Menu", semantics[5].label);
    try std.testing.expectEqual(@as(?usize, 1), semantics[5].grid_row_index);
    try std.testing.expectEqual(@as(?usize, 0), semantics[5].grid_column_index);

    const virtual_table = Widget{
        .id = 31,
        .kind = .table,
        .frame = geometry.RectF.init(0, 0, 320, 64),
        .value = 28,
        .layout = .{ .virtualized = true, .virtual_item_extent = 28, .virtual_overscan = 0 },
        .semantics = .{ .label = "Virtual table" },
        .children = &rows,
    };
    try std.testing.expectEqual(@as(f32, 56), virtualWidgetScrollContentExtent(virtual_table, 64));
    const page_down = WidgetKeyboardEvent{ .phase = .key_down, .key = "pagedown" };
    const keyboard_intent = widgetKeyboardControlIntent(virtual_table, page_down).?;
    try std.testing.expectEqual(WidgetControlIntentKind.scroll_by, keyboard_intent.kind);
    try std.testing.expect(keyboard_intent.actions.increment);
    const semantic_intent = widgetSemanticControlIntentWithActions(virtual_table, .increment, .{ .increment = true }).?;
    try std.testing.expectEqual(WidgetControlIntentKind.scroll_by, semantic_intent.kind);
    try std.testing.expect(semantic_intent.actions.increment);
}

test "widget list layout groups list items semantically" {
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .list_item,
            .text = "Inbox",
            .state = .{ .selected = true },
        },
        .{
            .id = 3,
            .kind = .list_item,
            .text = "Archive",
        },
    };
    const list = Widget{
        .id = 1,
        .kind = .list,
        .text = "Mailboxes",
        .layout = .{ .padding = geometry.InsetsF.all(8), .gap = 4 },
        .children = &children,
    };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(list, geometry.RectF.init(0, 0, 220, 88), &nodes);
    try std.testing.expectEqual(@as(usize, 3), layout.nodeCount());
    try expectLayoutFrame(layout, 1, geometry.RectF.init(0, 0, 220, 88));
    try expectLayoutFrame(layout, 2, geometry.RectF.init(8, 8, 204, 28));
    try expectLayoutFrame(layout, 3, geometry.RectF.init(8, 40, 204, 28));

    var commands: [4]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, .{});
    try std.testing.expectEqual(@as(usize, 3), builder.displayList().commandCount());

    const hit = layout.hitTest(geometry.PointF.init(16, 16)).?;
    try std.testing.expectEqual(@as(ObjectId, 2), hit.id);
    try std.testing.expectEqual(WidgetKind.list_item, hit.kind);
    try std.testing.expect(layout.hitTest(geometry.PointF.init(16, 82)) == null);

    var route_buffer: [3]WidgetEventRouteEntry = undefined;
    const route = try layout.routePointerEvent(.{ .phase = .down, .point = geometry.PointF.init(16, 16) }, &route_buffer);
    try std.testing.expectEqual(@as(usize, 3), route.entries.len);
    try std.testing.expectEqual(@as(ObjectId, 1), route.entries[0].id);
    try std.testing.expectEqual(WidgetEventPhase.capture, route.entries[0].phase);
    try std.testing.expectEqual(@as(ObjectId, 2), route.entries[1].id);
    try std.testing.expectEqual(WidgetEventPhase.target, route.entries[1].phase);
    try std.testing.expectEqual(@as(ObjectId, 1), route.entries[2].id);
    try std.testing.expectEqual(WidgetEventPhase.bubble, route.entries[2].phase);

    var semantics_buffer: [3]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 3), semantics.len);
    try std.testing.expectEqual(WidgetRole.list, semantics[0].role);
    try std.testing.expectEqualStrings("Mailboxes", semantics[0].label);
    try std.testing.expect(semantics[0].parent_index == null);
    try std.testing.expect(!semantics[0].list.present);
    try std.testing.expectEqual(WidgetRole.listitem, semantics[1].role);
    try std.testing.expectEqual(@as(?usize, 0), semantics[1].parent_index);
    try std.testing.expectEqual(@as(?f32, 1), semantics[1].value);
    try std.testing.expect(semantics[1].list.present);
    try std.testing.expectEqual(@as(u32, 0), semantics[1].list.item_index);
    try std.testing.expectEqual(@as(u32, 2), semantics[1].list.item_count);
    try std.testing.expectEqual(WidgetRole.listitem, semantics[2].role);
    try std.testing.expectEqual(@as(?usize, 0), semantics[2].parent_index);
    try std.testing.expectEqual(@as(?f32, 0), semantics[2].value);
    try std.testing.expect(semantics[2].list.present);
    try std.testing.expectEqual(@as(u32, 1), semantics[2].list.item_index);
    try std.testing.expectEqual(@as(u32, 2), semantics[2].list.item_count);
}
