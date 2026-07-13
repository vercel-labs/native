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

test "widget layout resolves row sizing and emits laid out commands" {
    const row_children = [_]Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(0, 0, 80, 32),
            .text = "Run",
        },
        .{
            .id = 3,
            .kind = .progress,
            .frame = geometry.RectF.init(0, 0, 0, 8),
            .value = 0.5,
            .layout = .{ .grow = 1, .min_size = geometry.SizeF.init(40, 8) },
        },
        .{
            .id = 4,
            .kind = .text,
            .frame = geometry.RectF.init(0, 0, 60, 20),
            .text = "Ready",
        },
    };
    const panel_children = [_]Widget{
        .{
            .kind = .row,
            .frame = geometry.RectF.init(0, 0, 0, 40),
            .layout = .{ .gap = 8 },
            .children = &row_children,
        },
    };
    const root = Widget{
        .id = 1,
        .kind = .panel,
        .layout = .{ .padding = geometry.InsetsF.all(12) },
        .children = &panel_children,
    };

    var nodes: [8]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 300, 80), &nodes);
    try std.testing.expectEqual(@as(usize, 5), layout.nodeCount());
    try expectLayoutFrame(layout, 1, geometry.RectF.init(0, 0, 300, 80));
    try expectLayoutFrame(layout, 2, geometry.RectF.init(12, 12, 80, 32));
    try expectLayoutFrame(layout, 3, geometry.RectF.init(100, 12, 120, 8));
    try expectLayoutFrame(layout, 4, geometry.RectF.init(228, 12, 60, 20));

    var commands: [12]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, .{});
    // Panel chrome (shadow/fill/border), the flat button (fill/border/
    // label), the progress track+value fills, then the text run.
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 9), display_list.commandCount());
    switch (display_list.commands[7]) {
        .fill_rounded_rect => |fill| try expectRect(geometry.RectF.init(100, 12, 60, 8), fill.rect),
        else => return error.TestUnexpectedResult,
    }
}

test "chat bubbles cap at the thread fraction, never the full thread" {
    // A hug-sized bubble in a WIDE thread: its message wants 700 points,
    // the row offers 600, and the reference contract caps the bubble at
    // 80% of the thread — 480 — so a long message wraps into a readable
    // column instead of spanning wall to wall.
    const wide_message = [_]Widget{.{ .id = 3, .kind = .text, .frame = geometry.RectF.init(0, 0, 700, 18), .text = "long" }};
    const wide_children = [_]Widget{.{ .id = 2, .kind = .bubble, .children = &wide_message }};
    const wide_row = Widget{ .id = 1, .kind = .row, .children = &wide_children };
    var wide_nodes: [4]WidgetLayoutNode = undefined;
    const wide = try layoutWidgetTree(wide_row, geometry.RectF.init(0, 0, 600, 60), &wide_nodes);
    try std.testing.expectEqual(@as(f32, 480), wide.nodes[1].frame.width);

    // A NARROW thread: the cap follows the thread down, so the bubble
    // never exceeds what the row can offer (160 = 80% of 200).
    var narrow_nodes: [4]WidgetLayoutNode = undefined;
    const narrow = try layoutWidgetTree(wide_row, geometry.RectF.init(0, 0, 200, 60), &narrow_nodes);
    try std.testing.expectEqual(@as(f32, 160), narrow.nodes[1].frame.width);

    // Ghost bubbles are exempt (the reference lets the chrome-less
    // variant run full width), and an explicit author width is definite
    // through the frame channel — both keep the classic result.
    const ghost_children = [_]Widget{.{ .id = 2, .kind = .bubble, .variant = .ghost, .children = &wide_message }};
    const ghost_row = Widget{ .id = 1, .kind = .row, .children = &ghost_children };
    var ghost_nodes: [4]WidgetLayoutNode = undefined;
    const ghost = try layoutWidgetTree(ghost_row, geometry.RectF.init(0, 0, 600, 60), &ghost_nodes);
    try std.testing.expectEqual(@as(f32, 700), ghost.nodes[1].frame.width);
    const sized_children = [_]Widget{.{ .id = 2, .kind = .bubble, .frame = geometry.RectF.init(0, 0, 550, 0), .children = &wide_message }};
    const sized_row = Widget{ .id = 1, .kind = .row, .children = &sized_children };
    var sized_nodes: [4]WidgetLayoutNode = undefined;
    const sized = try layoutWidgetTree(sized_row, geometry.RectF.init(0, 0, 600, 60), &sized_nodes);
    try std.testing.expectEqual(@as(f32, 550), sized.nodes[1].frame.width);
}

test "column-direct chat bubbles hug their message up to the fraction" {
    // The bubble is a message-hugging surface even under a column's
    // default stretch alignment: a short message hugs (100 points, at
    // the column's leading edge), a long one caps at 80% of the column
    // (240 of 300) — the reference's fit-content bubble, never a
    // stretched band.
    const short_message = [_]Widget{.{ .id = 3, .kind = .text, .frame = geometry.RectF.init(0, 0, 100, 18), .text = "hi" }};
    const long_message = [_]Widget{.{ .id = 5, .kind = .text, .frame = geometry.RectF.init(0, 0, 700, 18), .text = "long" }};
    const column_children = [_]Widget{
        .{ .id = 2, .kind = .bubble, .children = &short_message },
        .{ .id = 4, .kind = .bubble, .children = &long_message },
    };
    const column = Widget{ .id = 1, .kind = .column, .layout = .{ .gap = 8 }, .children = &column_children };
    var nodes: [8]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(column, geometry.RectF.init(0, 0, 300, 120), &nodes);
    try std.testing.expectEqual(@as(f32, 100), layout.nodes[1].frame.width);
    try std.testing.expectEqual(@as(f32, 0), layout.nodes[1].frame.x);
    try std.testing.expectEqual(@as(f32, 240), layout.nodes[3].frame.width);
}

test "widget layout uses intrinsic sizes for unframed controls" {
    const tokens = DesignTokens{};
    const button = Widget{ .id = 2, .kind = .button, .text = "Run" };
    const search = Widget{ .id = 3, .kind = .search_field, .text = "Find" };
    const icon_button = Widget{ .id = 4, .kind = .icon_button, .text = "+", .size = .icon };
    const row_children = [_]Widget{ button, search, icon_button };
    const row = Widget{
        .id = 1,
        .kind = .row,
        .layout = .{ .gap = 8, .cross_alignment = .center },
        .children = &row_children,
    };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTreeWithTokens(row, geometry.RectF.init(0, 0, 400, 64), tokens, &nodes);

    const button_size = intrinsicWidgetSize(button, tokens);
    const search_size = intrinsicWidgetSize(search, tokens);
    const icon_size = intrinsicWidgetSize(icon_button, tokens);
    try std.testing.expect(button_size.width > 0);
    try std.testing.expect(search_size.width > button_size.width);
    try expectLayoutFrame(layout, 2, geometry.RectF.init(0, (64 - button_size.height) * 0.5, button_size.width, button_size.height));
    try expectLayoutFrame(layout, 3, geometry.RectF.init(button_size.width + 8, (64 - search_size.height) * 0.5, search_size.width, search_size.height));
    // Accumulate x the way the row layout does — each step adds
    // `width + gap` as ONE term — so the comparison stays bit-exact
    // under f32 association.
    try expectLayoutFrame(layout, 4, geometry.RectF.init((button_size.width + 8) + (search_size.width + 8), (64 - icon_size.height) * 0.5, icon_size.width, icon_size.height));

    var custom_nodes: [4]WidgetLayoutNode = undefined;
    const custom_tokens = DesignTokens{ .typography = .{ .button_size = 18 } };
    const custom_layout = try layoutWidgetTreeWithTokens(row, geometry.RectF.init(0, 0, 400, 64), custom_tokens, &custom_nodes);
    try std.testing.expect(custom_layout.findById(2).?.frame.width > layout.findById(2).?.frame.width);
}

test "spinner intrinsic size is the compact icon register" {
    // The spinner sizes as an inline activity glyph — 16 (sm) / 20
    // (default) / 24 (lg), density scaled — never the 36px control
    // square that dwarfed neighboring compact controls.
    const tokens = DesignTokens{};
    const sm = Widget{ .id = 2, .kind = .spinner, .size = .sm };
    const default_size = Widget{ .id = 3, .kind = .spinner };
    const lg = Widget{ .id = 4, .kind = .spinner, .size = .lg };
    try std.testing.expectEqualDeep(geometry.SizeF.init(16, 16), intrinsicWidgetSize(sm, tokens));
    try std.testing.expectEqualDeep(geometry.SizeF.init(20, 20), intrinsicWidgetSize(default_size, tokens));
    try std.testing.expectEqualDeep(geometry.SizeF.init(24, 24), intrinsicWidgetSize(lg, tokens));

    const compact = DesignTokens{ .density = .compact };
    try std.testing.expectEqualDeep(geometry.SizeF.init(16 * 0.875, 16 * 0.875), intrinsicWidgetSize(sm, compact));
}

test "widget layout aligns row children on main and cross axes" {
    const centered_children = [_]Widget{
        .{
            .id = 2,
            .kind = .text,
            .frame = geometry.RectF.init(0, 0, 40, 12),
            .text = "A",
        },
        .{
            .id = 3,
            .kind = .text,
            .frame = geometry.RectF.init(0, 0, 20, 16),
            .text = "B",
        },
    };
    const centered = Widget{
        .id = 1,
        .kind = .row,
        .layout = .{
            .gap = 4,
            .main_alignment = .center,
            .cross_alignment = .center,
        },
        .children = &centered_children,
    };

    var centered_nodes: [3]WidgetLayoutNode = undefined;
    const centered_layout = try layoutWidgetTree(centered, geometry.RectF.init(0, 0, 120, 40), &centered_nodes);
    try expectLayoutFrame(centered_layout, 2, geometry.RectF.init(28, 14, 40, 12));
    try expectLayoutFrame(centered_layout, 3, geometry.RectF.init(72, 12, 20, 16));

    const spaced_children = [_]Widget{
        .{ .id = 5, .kind = .text, .frame = geometry.RectF.init(0, 0, 40, 12), .text = "A" },
        .{ .id = 6, .kind = .text, .frame = geometry.RectF.init(0, 0, 20, 16), .text = "B" },
    };
    const spaced = Widget{
        .id = 4,
        .kind = .row,
        .layout = .{ .main_alignment = .space_between },
        .children = &spaced_children,
    };

    var spaced_nodes: [3]WidgetLayoutNode = undefined;
    const spaced_layout = try layoutWidgetTree(spaced, geometry.RectF.init(0, 0, 120, 40), &spaced_nodes);
    try expectLayoutFrame(spaced_layout, 5, geometry.RectF.init(0, 0, 40, 12));
    try expectLayoutFrame(spaced_layout, 6, geometry.RectF.init(100, 0, 20, 16));
}

test "cross-centering splits the overflow of a taller-than-band child evenly" {
    // A fixed-height list row whose centered text stack is TALLER than
    // the padded band: the stack keeps its intrinsic height and the
    // overflow splits evenly across both edges (the free extent goes
    // negative and halves), so the content sits optically centered.
    // Before this pin the stack was clamped to the band and its inner
    // flow spilled past the bottom edge only — a visible top gap with
    // the last line pressed against the row's bottom edge.
    // Fixed-size leaves stand in for the text lines so the pinned
    // numbers stay independent of font metrics.
    const stack_children = [_]Widget{
        .{ .id = 3, .kind = .stack, .frame = geometry.RectF.init(0, 0, 80, 18) },
        .{ .id = 4, .kind = .stack, .frame = geometry.RectF.init(0, 0, 80, 16) },
    };
    const row_children = [_]Widget{
        .{ .id = 2, .kind = .column, .layout = .{ .gap = 2 }, .children = &stack_children },
    };
    const row = Widget{
        .id = 1,
        .kind = .list_item,
        .frame = geometry.RectF.init(0, 0, 300, 44),
        .layout = .{ .padding = geometry.InsetsF.all(10), .cross_alignment = .center },
        .children = &row_children,
    };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(row, geometry.RectF.init(0, 0, 300, 44), &nodes);
    // Stack intrinsic height 18 + 2 + 16 = 36 against the 24-point band
    // (44 minus 10 padding per edge): the frame keeps 36 and centers at
    // 10 + (24 - 36) / 2 = 4 — six points of overflow on EACH side.
    try expectLayoutFrame(layout, 2, geometry.RectF.init(10, 4, 80, 36));
    // The lines flow inside the centered stack: both sit symmetric
    // around the row's vertical middle (22).
    try expectLayoutFrame(layout, 3, geometry.RectF.init(10, 4, 80, 18));
    try expectLayoutFrame(layout, 4, geometry.RectF.init(10, 24, 80, 16));

    // A child that FITS the band keeps the classic centering unchanged.
    const fitting_children = [_]Widget{
        .{ .id = 6, .kind = .stack, .frame = geometry.RectF.init(0, 0, 80, 16) },
    };
    const fitting = Widget{
        .id = 5,
        .kind = .list_item,
        .frame = geometry.RectF.init(0, 0, 300, 44),
        .layout = .{ .padding = geometry.InsetsF.all(10), .cross_alignment = .center },
        .children = &fitting_children,
    };
    var fitting_nodes: [3]WidgetLayoutNode = undefined;
    const fitting_layout = try layoutWidgetTree(fitting, geometry.RectF.init(0, 0, 300, 44), &fitting_nodes);
    try expectLayoutFrame(fitting_layout, 6, geometry.RectF.init(10, 14, 80, 16));
}

test "widget text alignment emits local text layout options" {
    const tokens = DesignTokens{
        .typography = .{ .font_id = 1, .body_size = 10 },
    };

    const centered = Widget{
        .id = 1,
        .kind = .text,
        .frame = geometry.RectF.init(10, 20, 100, 20),
        .text = "Hi",
        .text_alignment = .center,
    };
    var center_commands: [1]CanvasCommand = undefined;
    var center_builder = Builder.init(&center_commands);
    try emitWidgetTree(&center_builder, centered, tokens);
    switch (center_builder.displayList().commands[0]) {
        .draw_text => |text| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(1, 1)), text.id);
            try std.testing.expectApproxEqAbs(@as(f32, 10), text.origin.x, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 33.75), text.origin.y, 0.001);
            try std.testing.expect(text.text_layout != null);
            try std.testing.expectEqual(@as(f32, 100), text.text_layout.?.max_width);
            try std.testing.expectEqual(TextAlign.center, text.text_layout.?.alignment);
        },
        else => return error.TestUnexpectedResult,
    }

    const end = Widget{
        .id = 2,
        .kind = .text,
        .frame = geometry.RectF.init(10, 20, 100, 20),
        .text = "Hi",
        .text_alignment = .end,
    };
    var end_commands: [1]CanvasCommand = undefined;
    var end_builder = Builder.init(&end_commands);
    try emitWidgetTree(&end_builder, end, tokens);
    switch (end_builder.displayList().commands[0]) {
        .draw_text => |text| {
            try std.testing.expectApproxEqAbs(@as(f32, 10), text.origin.x, 0.001);
            try std.testing.expect(text.text_layout != null);
            try std.testing.expectEqual(TextAlign.end, text.text_layout.?.alignment);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "widget opacity wraps subtree display list commands" {
    const children = [_]Widget{.{
        .id = 2,
        .kind = .text,
        .frame = geometry.RectF.init(8, 10, 80, 20),
        .text = "Fade",
    }};
    const root = Widget{
        .id = 1,
        .kind = .stack,
        .opacity = 0.5,
        .children = &children,
    };

    var direct_commands: [3]CanvasCommand = undefined;
    var direct_builder = Builder.init(&direct_commands);
    try emitWidgetTree(&direct_builder, root, .{});
    const direct_display_list = direct_builder.displayList();
    try std.testing.expectEqual(@as(usize, 3), direct_display_list.commandCount());
    switch (direct_display_list.commands[0]) {
        .push_opacity => |opacity| try std.testing.expectEqual(@as(f32, 0.5), opacity),
        else => return error.TestUnexpectedResult,
    }
    switch (direct_display_list.commands[1]) {
        .draw_text => |text| try std.testing.expectEqualStrings("Fade", text.text),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(direct_display_list.commands[2] == .pop_opacity);

    var render_commands: [1]RenderCommand = undefined;
    const render_plan = try direct_display_list.renderPlan(&render_commands);
    try std.testing.expectEqual(@as(usize, 1), render_plan.commandCount());
    try std.testing.expectEqual(@as(f32, 0.5), render_plan.commands[0].opacity);

    var nodes: [2]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 100, 40), &nodes);
    var layout_commands: [3]CanvasCommand = undefined;
    var layout_builder = Builder.init(&layout_commands);
    try layout.emitDisplayList(&layout_builder, .{});
    const layout_display_list = layout_builder.displayList();
    try std.testing.expectEqual(@as(usize, 3), layout_display_list.commandCount());
    switch (layout_display_list.commands[0]) {
        .push_opacity => |opacity| try std.testing.expectEqual(@as(f32, 0.5), opacity),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(layout_display_list.commands[2] == .pop_opacity);

    var transparent_commands: [1]CanvasCommand = undefined;
    var transparent_builder = Builder.init(&transparent_commands);
    try emitWidgetTree(&transparent_builder, .{ .kind = .stack, .opacity = 0, .children = &children }, .{});
    try std.testing.expectEqual(@as(usize, 0), transparent_builder.displayList().commandCount());
}

test "widget transform wraps subtree display list commands" {
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .text,
            .frame = geometry.RectF.init(0, 0, 40, 20),
            .transform = Affine.translate(20, 0),
            .text = "Move",
        },
        .{
            .id = 3,
            .kind = .text,
            .frame = geometry.RectF.init(0, 24, 40, 20),
            .text = "Still",
        },
    };
    const root = Widget{ .kind = .stack, .children = &children };

    var commands: [4]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, root, .{});
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 4), display_list.commandCount());
    switch (display_list.commands[0]) {
        .transform => |transform| try std.testing.expectEqualDeep(Affine.translate(20, 0), transform),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[1]) {
        .draw_text => |text| try std.testing.expectEqualStrings("Move", text.text),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[2]) {
        .transform => |transform| try std.testing.expectEqualDeep(Affine.translate(-20, 0), transform),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[3]) {
        .draw_text => |text| try std.testing.expectEqualStrings("Still", text.text),
        else => return error.TestUnexpectedResult,
    }

    var render_commands: [2]RenderCommand = undefined;
    const render_plan = try display_list.renderPlan(&render_commands);
    try std.testing.expectEqual(@as(usize, 2), render_plan.commandCount());
    try std.testing.expectEqualDeep(Affine.translate(20, 0), render_plan.commands[0].transform);
    try std.testing.expectEqualDeep(Affine.identity(), render_plan.commands[1].transform);

    var invalid_commands: [1]CanvasCommand = undefined;
    var invalid_builder = Builder.init(&invalid_commands);
    try std.testing.expectError(error.InvalidTransform, emitWidgetTree(&invalid_builder, .{
        .kind = .text,
        .transform = Affine.scale(0, 1),
        .text = "Bad",
    }, .{}));
    try std.testing.expectEqual(@as(usize, 0), invalid_builder.displayList().commandCount());
}

test "widget transform affects hit testing" {
    const button = Widget{
        .id = 4,
        .kind = .button,
        .frame = geometry.RectF.init(0, 0, 32, 24),
        .transform = Affine.translate(40, 0),
        .text = "Go",
    };

    var nodes: [1]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(button, button.frame, &nodes);
    try std.testing.expect(layout.hitTest(geometry.PointF.init(8, 12)) == null);
    const hit = layout.hitTest(geometry.PointF.init(48, 12)).?;
    try std.testing.expectEqual(@as(ObjectId, 4), hit.id);
    try std.testing.expectEqual(WidgetKind.button, hit.kind);
}

test "widget clip content wraps subtree display list and hit testing" {
    const children = [_]Widget{.{
        .id = 2,
        .kind = .text,
        .frame = geometry.RectF.init(40, 0, 40, 20),
        .text = "Clip",
        .semantics = .{ .focusable = true },
    }};
    const root = Widget{
        .id = 1,
        .kind = .stack,
        .frame = geometry.RectF.init(0, 0, 50, 20),
        .layout = .{ .clip_content = true },
        .children = &children,
    };

    var direct_commands: [3]CanvasCommand = undefined;
    var direct_builder = Builder.init(&direct_commands);
    try emitWidgetTree(&direct_builder, root, .{});
    const direct_display_list = direct_builder.displayList();
    try std.testing.expectEqual(@as(usize, 3), direct_display_list.commandCount());
    switch (direct_display_list.commands[0]) {
        .push_clip => |clip| try expectRect(geometry.RectF.init(0, 0, 50, 20), clip.rect),
        else => return error.TestUnexpectedResult,
    }
    switch (direct_display_list.commands[1]) {
        .draw_text => |text| try std.testing.expectEqualStrings("Clip", text.text),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(direct_display_list.commands[2] == .pop_clip);

    var nodes: [2]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, root.frame, &nodes);
    var layout_commands: [3]CanvasCommand = undefined;
    var layout_builder = Builder.init(&layout_commands);
    try layout.emitDisplayList(&layout_builder, .{});
    const layout_display_list = layout_builder.displayList();
    try std.testing.expectEqual(@as(usize, 3), layout_display_list.commandCount());
    try std.testing.expect(layout_display_list.commands[0] == .push_clip);
    try std.testing.expect(layout_display_list.commands[2] == .pop_clip);

    try std.testing.expectEqual(@as(ObjectId, 2), layout.hitTest(geometry.PointF.init(45, 10)).?.id);
    try std.testing.expect(layout.hitTest(geometry.PointF.init(55, 10)) == null);
    try std.testing.expectEqual(@as(ObjectId, 2), layout.focusTarget(null, .forward).?.id);
}

test "widget layout hit testing prefers deepest topmost enabled target" {
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(8, 8, 90, 32),
            .text = "Disabled",
            .state = .{ .disabled = true },
        },
        .{
            .id = 3,
            .kind = .button,
            .frame = geometry.RectF.init(16, 16, 90, 32),
            .text = "Active",
        },
    };
    const root = Widget{
        .id = 1,
        .kind = .panel,
        .children = &children,
    };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 140, 80), &nodes);
    const active_hit = layout.hitTest(geometry.PointF.init(24, 24)).?;
    try std.testing.expectEqual(@as(ObjectId, 3), active_hit.id);
    try std.testing.expectEqual(WidgetKind.button, active_hit.kind);

    const panel_hit = layout.hitTest(geometry.PointF.init(10, 10)).?;
    try std.testing.expectEqual(@as(ObjectId, 1), panel_hit.id);
    try std.testing.expect(layout.hitTest(geometry.PointF.init(200, 10)) == null);
}

test "widget layout resolves cursor intent from hit targets" {
    const children = [_]Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(8, 8, 90, 32), .text = "Run" },
        .{ .id = 3, .kind = .text_field, .frame = geometry.RectF.init(8, 48, 120, 32), .text = "Query" },
        .{ .id = 4, .kind = .slider, .frame = geometry.RectF.init(8, 88, 120, 32), .value = 0.5 },
        .{ .id = 5, .kind = .resizable, .frame = geometry.RectF.init(8, 128, 120, 40) },
    };
    const root = Widget{
        .id = 1,
        .kind = .panel,
        .children = &children,
    };

    var nodes: [6]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 160, 180), &nodes);
    // The native register: buttons AND sliders show the arrow (the hand
    // is reserved for hyperlinks), editable text shows the I-beam, and
    // only resize affordances show resize arrows.
    try std.testing.expectEqual(WidgetCursor.arrow, layout.cursorForHit(layout.hitTest(geometry.PointF.init(16, 16))));
    try std.testing.expectEqual(WidgetCursor.text, layout.cursorForHit(layout.hitTest(geometry.PointF.init(16, 56))));
    try std.testing.expectEqual(WidgetCursor.arrow, layout.cursorForHit(layout.hitTest(geometry.PointF.init(16, 96))));
    try std.testing.expectEqual(WidgetCursor.resize_horizontal, layout.cursorForHit(layout.hitTest(geometry.PointF.init(120, 140))));
    try std.testing.expectEqual(WidgetCursor.arrow, layout.cursorForHit(layout.hitTest(geometry.PointF.init(150, 170))));
    try std.testing.expectEqual(WidgetCursor.arrow, cursorForWidgetTarget(.button, .{ .disabled = true }));
}

test "widget grid layout places children in deterministic cells" {
    const children = [_]Widget{
        .{ .id = 2, .kind = .text, .text = "One" },
        .{ .id = 3, .kind = .text, .text = "Two" },
        .{ .id = 4, .kind = .button, .text = "Three" },
        .{ .id = 5, .kind = .button, .text = "Four" },
    };
    const grid = Widget{
        .id = 1,
        .kind = .grid,
        .layout = .{ .gap = 8, .columns = 2 },
        .children = &children,
    };

    var nodes: [6]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(grid, geometry.RectF.init(0, 0, 208, 88), &nodes);
    try std.testing.expectEqual(@as(usize, 5), layout.nodeCount());
    try expectLayoutFrame(layout, 2, geometry.RectF.init(0, 0, 100, 40));
    try expectLayoutFrame(layout, 3, geometry.RectF.init(108, 0, 100, 40));
    try expectLayoutFrame(layout, 4, geometry.RectF.init(0, 48, 100, 40));
    try expectLayoutFrame(layout, 5, geometry.RectF.init(108, 48, 100, 40));

    var commands: [10]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, .{});
    // Each flat button contributes 3 commands (fill/border/label); the
    // two text cells stay at 1.
    try std.testing.expectEqual(@as(usize, 8), builder.displayList().commandCount());
}

test "widget grid keeps declared column slots when children run short" {
    // Fewer children than the declared columns (a filtered grid): each
    // child keeps the column-slot width the declared count derives —
    // never stretching across the freed row — filling the leading slots
    // and leaving the trailing slots empty.
    const children = [_]Widget{
        .{ .id = 2, .kind = .text, .text = "One" },
        .{ .id = 3, .kind = .text, .text = "Two" },
    };
    const grid = Widget{
        .id = 1,
        .kind = .grid,
        .layout = .{ .gap = 8, .columns = 4 },
        .children = &children,
    };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(grid, geometry.RectF.init(0, 0, 424, 40), &nodes);
    try std.testing.expectEqual(@as(usize, 3), layout.nodeCount());
    // Slot width = (424 - 3 gaps of 8) / 4 declared columns = 100.
    try expectLayoutFrame(layout, 2, geometry.RectF.init(0, 0, 100, 40));
    try expectLayoutFrame(layout, 3, geometry.RectF.init(108, 0, 100, 40));
}

test "widget grid row count survives a huge declared column count" {
    const widget_tree = @import("widget_tree.zig");
    // Declared columns are engine input (never validator-bounded): the
    // additive ceil-div `(count + columns - 1) / columns` would overflow
    // in safe builds for a huge but valid usize. A few children under
    // maxInt columns is one row, not a panic.
    const huge = std.math.maxInt(usize);
    try std.testing.expectEqual(@as(usize, 1), widget_tree.gridRowCount(3, huge));
    try std.testing.expectEqual(@as(usize, 1), widget_tree.gridRowCount(1, huge));
    // Zero children (or zero columns) is zero rows in both paths.
    try std.testing.expectEqual(@as(usize, 0), widget_tree.gridRowCount(0, huge));
    try std.testing.expectEqual(@as(usize, 0), widget_tree.gridRowCount(0, 4));
    try std.testing.expectEqual(@as(usize, 0), widget_tree.gridRowCount(5, 0));
    // The ordinary shape still ceil-divides: 5 children over 2 columns
    // is 3 rows.
    try std.testing.expectEqual(@as(usize, 3), widget_tree.gridRowCount(5, 2));
    try std.testing.expectEqual(@as(usize, 2), widget_tree.gridRowCount(4, 2));
}

test "widget virtualized grid lays out visible cells by row" {
    const children = [_]Widget{
        .{ .id = 2, .kind = .button, .text = "Zero" },
        .{ .id = 3, .kind = .button, .text = "One" },
        .{ .id = 4, .kind = .button, .text = "Two" },
        .{ .id = 5, .kind = .button, .text = "Three" },
        .{ .id = 6, .kind = .button, .text = "Four" },
        .{ .id = 7, .kind = .button, .text = "Five" },
        .{ .id = 8, .kind = .button, .text = "Six" },
        .{ .id = 9, .kind = .button, .text = "Seven" },
    };
    const grid = Widget{
        .id = 1,
        .kind = .grid,
        .value = 25,
        .semantics = .{ .role = .grid, .label = "Tile grid" },
        .layout = .{
            .gap = 5,
            .columns = 2,
            .virtualized = true,
            .virtual_item_extent = 20,
        },
        .children = &children,
    };

    var nodes: [6]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(grid, geometry.RectF.init(0, 0, 105, 45), &nodes);
    try std.testing.expectEqual(@as(usize, 5), layout.nodeCount());
    try std.testing.expectEqual(@as(?u32, 4), layout.nodes[0].widget.semantics.list_item_count);
    try std.testing.expectEqual(@as(f32, 20), layout.nodes[0].widget.layout.virtual_item_extent);
    const grid_range = layout.virtualRangeById(1).?;
    try std.testing.expectEqual(@as(usize, 1), grid_range.start_index);
    try std.testing.expectEqual(@as(usize, 3), grid_range.end_index);
    try std.testing.expectEqual(@as(usize, 1), grid_range.first_visible_index);
    try std.testing.expectEqual(@as(usize, 2), grid_range.last_visible_index);
    try expectLayoutFrame(layout, 1, geometry.RectF.init(0, 0, 105, 45));
    try expectLayoutFrame(layout, 4, geometry.RectF.init(0, 0, 50, 20));
    try expectLayoutFrame(layout, 5, geometry.RectF.init(55, 0, 50, 20));
    try expectLayoutFrame(layout, 6, geometry.RectF.init(0, 25, 50, 20));
    try expectLayoutFrame(layout, 7, geometry.RectF.init(55, 25, 50, 20));
    try std.testing.expect(layout.findById(2) == null);
    try std.testing.expect(layout.findById(3) == null);
    try std.testing.expect(layout.findById(8) == null);
    try std.testing.expect(layout.findById(9) == null);
    try std.testing.expectEqual(@as(?u32, 2), layout.findById(4).?.widget.semantics.list_item_index);
    try std.testing.expectEqual(@as(?u32, 8), layout.findById(4).?.widget.semantics.list_item_count);
    try std.testing.expectEqual(@as(?u32, 5), layout.findById(7).?.widget.semantics.list_item_index);

    var semantics_buffer: [6]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 5), semantics.len);
    try std.testing.expectEqual(WidgetRole.grid, semantics[0].role);
    try std.testing.expectEqualStrings("Tile grid", semantics[0].label);
    try std.testing.expectEqual(@as(?usize, 4), semantics[0].grid_row_count);
    try std.testing.expectEqual(@as(?usize, 2), semantics[0].grid_column_count);
    try std.testing.expect(semantics[0].scroll.present);
    try std.testing.expectEqual(@as(f32, 25), semantics[0].scroll.offset);
    try std.testing.expectEqual(@as(f32, 45), semantics[0].scroll.viewport_extent);
    try std.testing.expectEqual(@as(f32, 95), semantics[0].scroll.content_extent);
    try std.testing.expect(semantics[0].focusable);
    try std.testing.expect(semantics[0].actions.focus);
    try std.testing.expect(semantics[0].actions.increment);
    try std.testing.expect(semantics[0].actions.decrement);
    try std.testing.expectEqual(@as(f32, 95), virtualWidgetScrollContentExtent(grid, 45));
    try std.testing.expectEqual(WidgetRole.button, semantics[1].role);
    try std.testing.expectEqual(@as(?usize, 1), semantics[1].grid_row_index);
    try std.testing.expectEqual(@as(?usize, 0), semantics[1].grid_column_index);
    try std.testing.expectEqual(@as(?usize, 4), semantics[1].grid_row_count);
    try std.testing.expectEqual(@as(?usize, 2), semantics[1].grid_column_count);
    try std.testing.expectEqual(WidgetRole.button, semantics[2].role);
    try std.testing.expectEqual(@as(?usize, 1), semantics[2].grid_row_index);
    try std.testing.expectEqual(@as(?usize, 1), semantics[2].grid_column_index);
    try std.testing.expectEqual(WidgetRole.button, semantics[3].role);
    try std.testing.expectEqual(@as(?usize, 2), semantics[3].grid_row_index);
    try std.testing.expectEqual(@as(?usize, 0), semantics[3].grid_column_index);
    try std.testing.expectEqual(WidgetRole.button, semantics[4].role);
    try std.testing.expectEqual(@as(?usize, 2), semantics[4].grid_row_index);
    try std.testing.expectEqual(@as(?usize, 1), semantics[4].grid_column_index);

    const laid_out_grid = layout.findById(1).?.widget;
    const page_down = WidgetKeyboardEvent{ .phase = .key_down, .key = "pagedown" };
    const keyboard_intent = widgetKeyboardControlIntent(laid_out_grid, page_down).?;
    try std.testing.expectEqual(WidgetControlIntentKind.scroll_by, keyboard_intent.kind);
    try std.testing.expect(keyboard_intent.actions.increment);
    const semantic_intent = widgetSemanticControlIntentWithActions(laid_out_grid, .increment, .{ .increment = true }).?;
    try std.testing.expectEqual(WidgetControlIntentKind.scroll_by, semantic_intent.kind);
    try std.testing.expect(semantic_intent.actions.increment);

    var commands: [32]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, .{});
    const display_list = builder.displayList();
    switch (display_list.findCommandById(widgetPartId(1, 1)).?.command) {
        .push_clip => |clip| try expectRect(geometry.RectF.init(0, 0, 105, 45), clip.rect),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.findCommandById(widgetPartId(1, 2)).?.command) {
        .fill_rounded_rect => |track| try expectRect(geometry.RectF.init(99, 3, 3, 39), track.rect),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.findCommandById(widgetPartId(1, 3)).?.command) {
        .fill_rounded_rect => |thumb| {
            try std.testing.expectApproxEqAbs(@as(f32, 13.263), thumb.rect.y, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 18.474), thumb.rect.height, 0.001);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "widget data grid exposes rows cells semantics and display list" {
    const header_cells = [_]Widget{
        .{ .id = 3, .kind = .data_cell, .text = "Name", .layout = .{ .grow = 1 } },
        .{ .id = 4, .kind = .data_cell, .text = "Status", .layout = .{ .grow = 1 } },
    };
    const deployment_cells = [_]Widget{
        .{ .id = 6, .kind = .data_cell, .text = "Edge API", .command = "cell.open", .layout = .{ .grow = 1 } },
        .{ .id = 7, .kind = .data_cell, .text = "Live", .layout = .{ .grow = 1 } },
    };
    const rows = [_]Widget{
        .{ .id = 2, .kind = .data_row, .frame = geometry.RectF.init(0, 0, 0, 28), .children = &header_cells },
        .{ .id = 5, .kind = .data_row, .frame = geometry.RectF.init(0, 0, 0, 28), .children = &deployment_cells },
    };
    const grid = Widget{
        .id = 1,
        .kind = .data_grid,
        .text = "Deployments",
        .layout = .{ .gap = 2 },
        .children = &rows,
    };

    var nodes: [8]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(grid, geometry.RectF.init(0, 0, 240, 58), &nodes);
    try std.testing.expectEqual(@as(usize, 7), layout.nodeCount());
    try expectLayoutFrame(layout, 1, geometry.RectF.init(0, 0, 240, 58));
    try expectLayoutFrame(layout, 2, geometry.RectF.init(0, 0, 240, 28));
    try expectLayoutFrame(layout, 3, geometry.RectF.init(0, 0, 120, 28));
    try expectLayoutFrame(layout, 4, geometry.RectF.init(120, 0, 120, 28));
    try expectLayoutFrame(layout, 5, geometry.RectF.init(0, 30, 240, 28));
    try expectLayoutFrame(layout, 6, geometry.RectF.init(0, 30, 120, 28));
    try expectLayoutFrame(layout, 7, geometry.RectF.init(120, 30, 120, 28));

    const hit = layout.hitTest(geometry.PointF.init(8, 38)).?;
    try std.testing.expectEqual(@as(ObjectId, 6), hit.id);
    try std.testing.expectEqual(WidgetKind.data_cell, hit.kind);

    var semantics_buffer: [8]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 7), semantics.len);
    try std.testing.expectEqual(WidgetRole.grid, semantics[0].role);
    try std.testing.expectEqualStrings("Deployments", semantics[0].label);
    try std.testing.expect(semantics[0].parent_index == null);
    try std.testing.expectEqual(WidgetRole.row, semantics[1].role);
    try std.testing.expectEqual(@as(?usize, 0), semantics[1].parent_index);
    try std.testing.expectEqual(WidgetRole.gridcell, semantics[2].role);
    try std.testing.expectEqualStrings("Name", semantics[2].label);
    try std.testing.expectEqual(@as(?usize, 1), semantics[2].parent_index);
    try std.testing.expect(semantics[2].focusable);
    try std.testing.expect(semantics[2].actions.focus);
    try std.testing.expect(semantics[2].actions.select);
    try std.testing.expect(!semantics[2].actions.press);
    try std.testing.expectEqual(WidgetRole.row, semantics[4].role);
    try std.testing.expectEqual(@as(?usize, 0), semantics[4].parent_index);
    try std.testing.expectEqual(WidgetRole.gridcell, semantics[5].role);
    try std.testing.expectEqualStrings("Edge API", semantics[5].label);
    try std.testing.expect(semantics[5].actions.select);
    try std.testing.expect(semantics[5].actions.press);
    try expectRect(geometry.RectF.init(0, 30, 120, 28), semantics[5].bounds);

    var commands: [16]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, .{});
    const display_list = builder.displayList();
    // Borderless cells (text only) plus ONE hairline row separator under
    // the first row — the table register: no cell boxes, no line under
    // the last row.
    try std.testing.expectEqual(@as(usize, 5), display_list.commandCount());
    switch (display_list.commands[0]) {
        .draw_text => |text| try std.testing.expectEqualStrings("Name", text.text),
        else => return error.UnexpectedCommand,
    }
    switch (display_list.commands[4]) {
        .draw_line => |line| try std.testing.expectEqual(@as(ObjectId, widgetPartId(2, 2)), line.id),
        else => return error.UnexpectedCommand,
    }
}

test "widget virtualized data grid lays out visible rows" {
    const rows = [_]Widget{
        .{ .id = 2, .kind = .data_row, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Zero" },
        .{ .id = 3, .kind = .data_row, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "One" },
        .{ .id = 4, .kind = .data_row, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Two" },
        .{ .id = 5, .kind = .data_row, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Three" },
    };
    const grid = Widget{
        .id = 1,
        .kind = .data_grid,
        .value = 25,
        .layout = .{
            .gap = 5,
            .virtualized = true,
            .virtual_item_extent = 20,
        },
        .children = &rows,
    };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(grid, geometry.RectF.init(0, 0, 160, 45), &nodes);
    try std.testing.expectEqual(@as(usize, 3), layout.nodeCount());
    try std.testing.expectEqual(@as(?u32, 4), layout.nodes[0].widget.semantics.list_item_count);
    try std.testing.expectEqual(@as(f32, 20), layout.nodes[0].widget.layout.virtual_item_extent);
    const grid_range = layout.virtualRangeById(1).?;
    try std.testing.expectEqual(@as(usize, 1), grid_range.start_index);
    try std.testing.expectEqual(@as(usize, 3), grid_range.end_index);
    try std.testing.expectEqual(@as(usize, 1), grid_range.first_visible_index);
    try std.testing.expectEqual(@as(usize, 2), grid_range.last_visible_index);
    try std.testing.expectEqual(@as(?u32, 1), layout.nodes[1].widget.semantics.list_item_index);
    try std.testing.expectEqual(@as(?u32, 2), layout.nodes[2].widget.semantics.list_item_index);
    try expectLayoutFrame(layout, 1, geometry.RectF.init(0, 0, 160, 45));
    try expectLayoutFrame(layout, 3, geometry.RectF.init(0, 0, 160, 20));
    try expectLayoutFrame(layout, 4, geometry.RectF.init(0, 25, 160, 20));
    try std.testing.expect(layout.findById(2) == null);
    try std.testing.expect(layout.findById(5) == null);

    var semantics_buffer: [4]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 3), semantics.len);
    try std.testing.expectEqual(WidgetRole.grid, semantics[0].role);
    try std.testing.expectEqual(@as(?usize, 4), semantics[0].grid_row_count);
    try std.testing.expectEqual(@as(?usize, 0), semantics[0].grid_column_count);
    try std.testing.expect(semantics[0].scroll.present);
    try std.testing.expectEqual(@as(f32, 25), semantics[0].scroll.offset);
    try std.testing.expectEqual(@as(f32, 45), semantics[0].scroll.viewport_extent);
    try std.testing.expectEqual(@as(f32, 95), semantics[0].scroll.content_extent);
    try std.testing.expect(semantics[0].focusable);
    try std.testing.expect(semantics[0].actions.focus);
    try std.testing.expect(semantics[0].actions.increment);
    try std.testing.expect(semantics[0].actions.decrement);
    try std.testing.expectEqual(@as(ObjectId, 1), layout.focusTargetById(1).?.id);

    try std.testing.expectEqual(WidgetRole.row, semantics[1].role);
    try std.testing.expectEqual(@as(ObjectId, 3), semantics[1].id);
    try std.testing.expectEqual(@as(?usize, 1), semantics[1].grid_row_index);
    try std.testing.expectEqual(@as(?usize, 4), semantics[1].grid_row_count);

    try std.testing.expectEqual(WidgetRole.row, semantics[2].role);
    try std.testing.expectEqual(@as(ObjectId, 4), semantics[2].id);
    try std.testing.expectEqual(@as(?usize, 2), semantics[2].grid_row_index);
    try std.testing.expectEqual(@as(?usize, 4), semantics[2].grid_row_count);

    var commands: [16]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, .{});
    const display_list = builder.displayList();
    switch (display_list.findCommandById(widgetPartId(1, 1)).?.command) {
        .push_clip => |clip| try expectRect(geometry.RectF.init(0, 0, 160, 45), clip.rect),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.findCommandById(widgetPartId(1, 2)).?.command) {
        .fill_rounded_rect => |track| try expectRect(geometry.RectF.init(154, 3, 3, 39), track.rect),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.findCommandById(widgetPartId(1, 3)).?.command) {
        .fill_rounded_rect => |thumb| {
            try std.testing.expectApproxEqAbs(@as(f32, 13.263), thumb.rect.y, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 18.474), thumb.rect.height, 0.001);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "widget scroll view offsets children and clips display list" {
    const children = [_]Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "One" },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 44, 0, 32), .text = "Two" },
        .{ .id = 4, .kind = .button, .frame = geometry.RectF.init(0, 80, 0, 32), .text = "Three" },
    };
    const scroll = Widget{
        .id = 1,
        .kind = .scroll_view,
        .value = 20,
        .children = &children,
    };

    var nodes: [5]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(scroll, geometry.RectF.init(0, 0, 120, 60), &nodes);
    try std.testing.expectEqual(@as(usize, 4), layout.nodeCount());
    try expectLayoutFrame(layout, 1, geometry.RectF.init(0, 0, 120, 60));
    try expectLayoutFrame(layout, 2, geometry.RectF.init(0, -20, 120, 32));
    try expectLayoutFrame(layout, 3, geometry.RectF.init(0, 24, 120, 32));
    try expectLayoutFrame(layout, 4, geometry.RectF.init(0, 60, 120, 32));

    var commands: [16]CanvasCommand = undefined;
    const tokens: DesignTokens = .{};
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, tokens);
    // Three visible flat buttons at 3 commands each inside the clip
    // pair, then the scrollbar track and thumb.
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 13), display_list.commandCount());
    switch (display_list.commands[0]) {
        .push_clip => |clip| try expectRect(geometry.RectF.init(0, 0, 120, 60), clip.rect),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(display_list.commands[10] == .pop_clip);
    switch (display_list.commands[11]) {
        .fill_rounded_rect => |track| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(1, 2)), track.id);
            try expectRect(geometry.RectF.init(114, 3, 3, 54), track.rect);
            try expectFillColor(colorWithAlpha(tokens.colors.border, 0.22), track.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[12]) {
        .fill_rounded_rect => |thumb| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(1, 3)), thumb.id);
            try std.testing.expectApproxEqAbs(@as(f32, 12.642), thumb.rect.y, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 28.928), thumb.rect.height, 0.001);
            try expectFillColor(colorWithAlpha(tokens.colors.text_muted, 0.55), thumb.fill);
        },
        else => return error.TestUnexpectedResult,
    }

    try std.testing.expectEqual(@as(ObjectId, 2), layout.hitTest(geometry.PointF.init(10, 4)).?.id);
    try std.testing.expectEqual(@as(ObjectId, 3), layout.hitTest(geometry.PointF.init(10, 50)).?.id);
    const blank_hit = layout.hitTest(geometry.PointF.init(10, 58)).?;
    try std.testing.expectEqual(@as(ObjectId, 1), blank_hit.id);
    try std.testing.expectEqual(WidgetKind.scroll_view, blank_hit.kind);
    try std.testing.expect(layout.hitTest(geometry.PointF.init(10, 70)) == null);

    var route_buffer: [2]WidgetEventRouteEntry = undefined;
    const route = try layout.routePointerEvent(.{ .phase = .wheel, .point = geometry.PointF.init(10, 58), .delta = geometry.OffsetF.init(0, -12) }, &route_buffer);
    try std.testing.expectEqual(@as(ObjectId, 1), route.target.?.id);
    try std.testing.expectEqual(@as(usize, 1), route.entries.len);
    try std.testing.expectEqual(WidgetEventPhase.target, route.entries[0].phase);

    var semantics_buffer: [4]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 4), semantics.len);
    try std.testing.expectEqual(WidgetRole.group, semantics[0].role);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0 / 52.0), semantics[0].value.?, 0.001);
    try std.testing.expect(semantics[0].scroll.present);
    try std.testing.expectEqual(@as(f32, 20.0), semantics[0].scroll.offset);
    try std.testing.expectEqual(@as(f32, 60.0), semantics[0].scroll.viewport_extent);
    try std.testing.expectEqual(@as(f32, 112.0), semantics[0].scroll.content_extent);
    try std.testing.expect(semantics[0].focusable);
    try std.testing.expect(semantics[0].actions.focus);
    try std.testing.expect(semantics[0].actions.increment);
    try std.testing.expect(semantics[0].actions.decrement);
}

test "widget scroll view scrollbars use control visual tokens" {
    const children = [_]Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "One" },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 44, 0, 32), .text = "Two" },
        .{ .id = 4, .kind = .button, .frame = geometry.RectF.init(0, 80, 0, 32), .text = "Three" },
    };
    const scroll = Widget{
        .id = 1,
        .kind = .scroll_view,
        .value = 20,
        .children = &children,
    };
    const tokens = DesignTokens{
        .controls = .{
            .scrollbar = .{
                .background = Color.rgb8(25, 31, 37),
                .foreground = Color.rgb8(132, 144, 156),
                .radius = 4,
            },
        },
    };

    var nodes: [5]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(scroll, geometry.RectF.init(0, 0, 120, 60), &nodes);

    var commands: [16]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, tokens);
    const display_list = builder.displayList();
    switch (display_list.findCommandById(widgetPartId(1, 2)).?.command) {
        .fill_rounded_rect => |track| {
            try std.testing.expectEqualDeep(Radius.all(4), track.radius);
            try expectFillColor(Color.rgb8(25, 31, 37), track.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.findCommandById(widgetPartId(1, 3)).?.command) {
        .fill_rounded_rect => |thumb| {
            try std.testing.expectEqualDeep(Radius.all(4), thumb.radius);
            try expectFillColor(Color.rgb8(132, 144, 156), thumb.fill);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "widget focus traversal skips scroll clipped children" {
    const children = [_]Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "One" },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 44, 0, 32), .text = "Two" },
        .{ .id = 4, .kind = .button, .frame = geometry.RectF.init(0, 80, 0, 32), .text = "Three" },
    };
    const scroll = Widget{
        .id = 1,
        .kind = .scroll_view,
        .value = 20,
        .children = &children,
    };

    var nodes: [5]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(scroll, geometry.RectF.init(0, 0, 120, 60), &nodes);
    try expectLayoutFrame(layout, 2, geometry.RectF.init(0, -20, 120, 32));
    try expectLayoutFrame(layout, 3, geometry.RectF.init(0, 24, 120, 32));
    try expectLayoutFrame(layout, 4, geometry.RectF.init(0, 60, 120, 32));

    try std.testing.expectEqual(@as(ObjectId, 1), layout.focusTarget(null, .forward).?.id);
    try std.testing.expectEqual(@as(ObjectId, 2), layout.focusTarget(1, .forward).?.id);
    try std.testing.expectEqual(@as(ObjectId, 3), layout.focusTarget(2, .forward).?.id);
    try std.testing.expectEqual(@as(ObjectId, 1), layout.focusTarget(3, .forward).?.id);
    try std.testing.expectEqual(@as(ObjectId, 3), layout.focusTarget(1, .backward).?.id);
    try std.testing.expect(layout.focusTargetById(4) == null);
}

test "scroll state applies wheel deltas kinetic decay and bounds" {
    const physics = ScrollPhysics{
        .wheel_multiplier = 2,
        .wheel_velocity_scale = 10,
        .deceleration_per_second = 0.5,
        .stop_velocity = 1,
    };
    const start = ScrollState{
        .offset = 10,
        .viewport_extent = 100,
        .content_extent = 360,
    };

    const wheeled = start.applyWheel(30, physics);
    try std.testing.expectEqual(@as(f32, 70), wheeled.offset);
    try std.testing.expectEqual(@as(f32, 600), wheeled.velocity);

    const stepped = wheeled.stepKinetic(100, physics);
    try std.testing.expect(stepped.offset > wheeled.offset);
    try std.testing.expect(stepped.velocity > 0);
    try std.testing.expect(stepped.velocity < wheeled.velocity);

    const clamped_by_default = wheeled.applyWheel(1000, physics);
    try std.testing.expectEqual(@as(f32, 260), clamped_by_default.offset);
    try std.testing.expectEqual(@as(f32, 0), clamped_by_default.velocity);

    const clamped = wheeled.applyWheelClamped(1000, physics);
    try std.testing.expectEqual(@as(f32, 260), clamped.offset);
    try std.testing.expectEqual(@as(f32, 0), clamped.velocity);
}

test "scroll overscroll gates rubber-band: none pins at the edges, rubber_band excursions recover" {
    const start = ScrollState{
        .offset = 250,
        .viewport_extent = 100,
        .content_extent = 360,
    };

    // Overscroll off (the default): a wheel past the edge clamps and
    // zeroes velocity — the clean stop — and kinetic stepping never
    // carries the offset past the boundary.
    const pinned_physics = ScrollPhysics{};
    try std.testing.expectEqual(canvas.ScrollOverscroll.none, pinned_physics.overscroll);
    const pinned = start.applyWheel(1000, pinned_physics);
    try std.testing.expectEqual(@as(f32, 260), pinned.offset);
    try std.testing.expectEqual(@as(f32, 0), pinned.velocity);
    var rolling = ScrollState{
        .offset = 250,
        .velocity = 400,
        .viewport_extent = 100,
        .content_extent = 360,
    };
    rolling = rolling.stepKinetic(100, pinned_physics);
    try std.testing.expectEqual(@as(f32, 260), rolling.offset);
    try std.testing.expectEqual(@as(f32, 0), rolling.velocity);
    try std.testing.expect(!rolling.needsKineticStep(pinned_physics));

    // Overscroll on: the same wheel travels past the edge under
    // resistance, and kinetic steps pull the excursion back to the edge.
    const bouncy_physics = ScrollPhysics{ .overscroll = .rubber_band };
    const bounced = start.applyWheel(1000, bouncy_physics);
    try std.testing.expect(bounced.offset > 260);
    try std.testing.expect(bounced.overscroll() > 0);
    var recovering = bounced;
    recovering.velocity = 0;
    var steps: usize = 0;
    while (recovering.overscroll() != 0 and steps < 200) : (steps += 1) {
        recovering = recovering.stepKinetic(16, bouncy_physics);
    }
    try std.testing.expectEqual(@as(f32, 260), recovering.offset);

    // A stale out-of-range offset on a pinned region self-heals in one
    // kinetic step instead of animating a return.
    const stale = ScrollState{
        .offset = 300,
        .viewport_extent = 100,
        .content_extent = 360,
    };
    const healed = stale.stepKinetic(16, pinned_physics);
    try std.testing.expectEqual(@as(f32, 260), healed.offset);
}

test "virtual list range computes visible and overscan windows" {
    const range = virtualListRange(.{
        .item_count = 100,
        .item_extent = 24,
        .item_gap = 4,
        .viewport_extent = 70,
        .scroll_offset = 50,
        .overscan = 1,
    });

    try std.testing.expectEqual(@as(usize, 0), range.start_index);
    try std.testing.expectEqual(@as(usize, 6), range.end_index);
    try std.testing.expectEqual(@as(usize, 1), range.first_visible_index);
    try std.testing.expectEqual(@as(usize, 4), range.last_visible_index);
    try std.testing.expectEqual(@as(usize, 6), range.itemCount());
    try std.testing.expectEqual(@as(f32, 2796), range.content_extent);
    try std.testing.expectEqual(@as(f32, 2632), range.after_extent);

    const top_rubberband = virtualListRange(.{
        .item_count = 10,
        .item_extent = 20,
        .item_gap = 5,
        .viewport_extent = 50,
        .scroll_offset = -14,
        .overscan = 1,
    });
    try std.testing.expectEqual(@as(f32, 0), top_rubberband.scroll_offset);
    try std.testing.expectEqual(@as(f32, -14), top_rubberband.layout_offset);
    try std.testing.expectEqual(@as(usize, 0), top_rubberband.first_visible_index);

    const bottom_rubberband = virtualListRange(.{
        .item_count = 10,
        .item_extent = 20,
        .item_gap = 5,
        .viewport_extent = 50,
        .scroll_offset = 216,
        .overscan = 1,
    });
    try std.testing.expectEqual(@as(f32, 195), bottom_rubberband.scroll_offset);
    try std.testing.expectEqual(@as(f32, 216), bottom_rubberband.layout_offset);
    try std.testing.expectEqual(@as(usize, 7), bottom_rubberband.first_visible_index);

    const bounded_rubberband = virtualListRange(.{
        .item_count = 10,
        .item_extent = 20,
        .item_gap = 5,
        .viewport_extent = 50,
        .scroll_offset = 1000,
        .overscan = 1,
    });
    try std.testing.expectEqual(@as(f32, 195), bounded_rubberband.scroll_offset);
    try std.testing.expectEqual(@as(f32, 245), bounded_rubberband.layout_offset);

    const empty = virtualListRange(.{
        .item_count = 10,
        .item_extent = 0,
        .viewport_extent = 100,
    });
    try std.testing.expect(empty.isEmpty());
}

test "widget virtualized scroll view lays out only visible overscan children" {
    const children = [_]Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Zero" },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "One" },
        .{ .id = 4, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Two" },
        .{ .id = 5, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Three" },
        .{ .id = 6, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Four" },
        .{ .id = 7, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Five" },
        .{ .id = 8, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Six" },
        .{ .id = 9, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Seven" },
        .{ .id = 10, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Eight" },
        .{ .id = 11, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Nine" },
    };
    const scroll = Widget{
        .id = 1,
        .kind = .scroll_view,
        .value = 45,
        .layout = .{
            .gap = 5,
            .virtualized = true,
            .virtual_item_extent = 20,
            .virtual_overscan = 1,
        },
        .children = &children,
    };

    var nodes: [6]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(scroll, geometry.RectF.init(0, 0, 120, 50), &nodes);
    try std.testing.expectEqual(@as(usize, 6), layout.nodeCount());
    try std.testing.expectEqual(@as(?u32, 10), layout.nodes[0].widget.semantics.list_item_count);
    try std.testing.expectEqual(@as(f32, 20), layout.nodes[0].widget.layout.virtual_item_extent);
    const scroll_range = layout.virtualRangeById(1).?;
    try std.testing.expectEqual(@as(usize, 0), scroll_range.start_index);
    try std.testing.expectEqual(@as(usize, 5), scroll_range.end_index);
    try std.testing.expectEqual(@as(usize, 1), scroll_range.first_visible_index);
    try std.testing.expectEqual(@as(usize, 3), scroll_range.last_visible_index);
    try expectLayoutFrame(layout, 1, geometry.RectF.init(0, 0, 120, 50));
    try expectLayoutFrame(layout, 2, geometry.RectF.init(0, -45, 120, 20));
    try expectLayoutFrame(layout, 3, geometry.RectF.init(0, -20, 120, 20));
    try expectLayoutFrame(layout, 4, geometry.RectF.init(0, 5, 120, 20));
    try expectLayoutFrame(layout, 5, geometry.RectF.init(0, 30, 120, 20));
    try expectLayoutFrame(layout, 6, geometry.RectF.init(0, 55, 120, 20));
    try std.testing.expect(layout.findById(7) == null);

    try std.testing.expectEqual(@as(ObjectId, 4), layout.hitTest(geometry.PointF.init(10, 8)).?.id);
    try std.testing.expect(layout.hitTest(geometry.PointF.init(10, 56)) == null);

    const top_overscroll = Widget{
        .id = 20,
        .kind = .scroll_view,
        .value = -12,
        .layout = .{
            .gap = 5,
            .virtualized = true,
            .virtual_item_extent = 20,
            .virtual_overscan = 1,
        },
        .children = &children,
    };
    var top_nodes: [5]WidgetLayoutNode = undefined;
    const top_layout = try layoutWidgetTree(top_overscroll, geometry.RectF.init(0, 0, 120, 50), &top_nodes);
    try expectLayoutFrame(top_layout, 2, geometry.RectF.init(0, 12, 120, 20));
    try expectLayoutFrame(top_layout, 3, geometry.RectF.init(0, 37, 120, 20));
    try std.testing.expectEqual(@as(f32, 0), top_layout.virtualRangeById(20).?.scroll_offset);
    try std.testing.expectEqual(@as(f32, -12), top_layout.virtualRangeById(20).?.layout_offset);
}

test "windowed virtual list lays out the built window at absolute virtual positions" {
    // The WINDOWED contract: children are the built slice (here items
    // 100..106 of a 100k list), `virtual_first_index` names where it
    // starts, and the declared `virtual_item_count` drives the content
    // extent, the range math, and the list_item semantics — the view
    // never materializes the other 99_994 items.
    const window = [_]Widget{
        .{ .id = 2, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Item 100" },
        .{ .id = 3, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Item 101" },
        .{ .id = 4, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Item 102" },
        .{ .id = 5, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Item 103" },
        .{ .id = 6, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Item 104" },
        .{ .id = 7, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Item 105" },
    };
    const list = Widget{
        .id = 1,
        .kind = .scroll_view,
        // Item 100's row top: 100 * (20 + 5).
        .value = 2500,
        .layout = .{
            .gap = 5,
            .virtualized = true,
            .virtual_item_extent = 20,
            .virtual_overscan = 1,
            .virtual_item_count = 100_000,
            .virtual_first_index = 100,
        },
        .children = &window,
    };

    var nodes: [8]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(list, geometry.RectF.init(0, 0, 120, 50), &nodes);

    // The runtime-scrolled predicate holds for exactly this shape.
    try std.testing.expect(support.canvas.widgetVirtualRuntimeScrolled(layout.nodes[0].widget));

    // Semantics and extent derive from the DECLARED count: 100k items of
    // stride 25 (minus the trailing gap), not the six built children.
    try std.testing.expectEqual(@as(?u32, 100_000), layout.nodes[0].widget.semantics.list_item_count);
    try std.testing.expectEqual(@as(f32, 2_499_995), virtualWidgetScrollContentExtent(layout.nodes[0].widget, 50));

    // The visible range (offset 2500, viewport 50, overscan 1) is items
    // 99..104 (end exclusive); intersected with the built window it
    // mounts 100..103, each at its ABSOLUTE virtual position.
    const range = layout.virtualRangeById(1).?;
    try std.testing.expectEqual(@as(usize, 99), range.start_index);
    try std.testing.expectEqual(@as(usize, 104), range.end_index);
    try std.testing.expectEqual(@as(usize, 5), layout.nodeCount());
    try expectLayoutFrame(layout, 2, geometry.RectF.init(0, 0, 120, 20));
    try expectLayoutFrame(layout, 3, geometry.RectF.init(0, 25, 120, 20));
    try expectLayoutFrame(layout, 4, geometry.RectF.init(0, 50, 120, 20));
    try expectLayoutFrame(layout, 5, geometry.RectF.init(0, 75, 120, 20));
    try std.testing.expect(layout.findById(6) == null);
    try std.testing.expect(layout.findById(7) == null);

    // Built rows carry their absolute item indices against the declared
    // count — assistive tech reads "item 101 of 100000".
    try std.testing.expectEqual(@as(?u32, 100), layout.findById(2).?.widget.semantics.list_item_index);
    try std.testing.expectEqual(@as(?u32, 100_000), layout.findById(2).?.widget.semantics.list_item_count);
    try std.testing.expectEqual(@as(?u32, 103), layout.findById(5).?.widget.semantics.list_item_index);

    // A window that under-covers the visible range mounts only the
    // intersection (the coverage-retry rebuild widens it): scrolled to
    // the very end, the same 100..106 window mounts nothing.
    var tail = list;
    tail.value = 2_499_995 - 50;
    var tail_nodes: [8]WidgetLayoutNode = undefined;
    const tail_layout = try layoutWidgetTree(tail, geometry.RectF.init(0, 0, 120, 50), &tail_nodes);
    try std.testing.expectEqual(@as(usize, 1), tail_layout.nodeCount());
    const tail_range = tail_layout.virtualRangeById(1).?;
    try std.testing.expectEqual(@as(usize, 99_996), tail_range.start_index);
    try std.testing.expectEqual(@as(usize, 100_000), tail_range.end_index);
}

// The overflow diagnostic's test seam lives on the layout module itself
// (same canvas-module instance `layoutWidgetTree` runs through), so
// these tests read exactly the counter the diagnostic path increments.
const widget_layout_module = @import("widget_layout.zig");

test "scroll scopes silence the vertical overflow diagnostic; bare overflow still warns" {
    // A trailing virtualized scroll in a flex column, with the mounted
    // window's extent (10 rows x 25 stride = 250) far past the space
    // the column can give it (140 - 40 header = 100). This is the
    // normal virtual-list operating mode — the runtime scrolls the
    // window — so the layout must be correct AND no overflow
    // diagnostic may fire for it. The diagnostic used to blame the
    // parent bookkeeping here on every rebuild (hundreds of identical
    // lines in a scrolling app) while the layout audit stayed clean.
    var window_rows: [10]Widget = undefined;
    for (&window_rows, 0..) |*row, index| {
        row.* = .{
            .id = @intCast(10 + index),
            .kind = .list_item,
            .frame = geometry.RectF.init(0, 0, 0, 20),
            .text = "Row",
        };
    }
    const virtual_column = Widget{
        .id = 1,
        .kind = .column,
        .children = &.{
            .{ .id = 2, .kind = .row, .frame = geometry.RectF.init(0, 0, 0, 40) },
            .{
                .id = 3,
                .kind = .scroll_view,
                // Deep in the list: the window tracks a virtualized
                // offset (items 100.. of 100k mounted).
                .value = 2500,
                .layout = .{
                    .grow = 1,
                    .gap = 5,
                    .virtualized = true,
                    .virtual_item_extent = 20,
                    .virtual_item_count = 100_000,
                    .virtual_first_index = 100,
                },
                .children = &window_rows,
            },
        },
    };
    widget_layout_module.test_axis_overflow_diagnostics = 0;
    var nodes: [16]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(virtual_column, geometry.RectF.init(0, 0, 120, 140), &nodes);
    try std.testing.expectEqual(@as(usize, 0), widget_layout_module.test_axis_overflow_diagnostics);
    // The flex math is untouched by the silenced diagnostic: the grow
    // scroll takes exactly the space after the header, and the first
    // mounted row sits at its absolute virtual position (100 * 25 -
    // 2500 = 0 into the viewport).
    try expectLayoutFrame(layout, 3, geometry.RectF.init(0, 40, 120, 100));
    try expectLayoutFrame(layout, 10, geometry.RectF.init(0, 40, 120, 20));

    // The tracked-offset plain scroll shape (a markup `<scroll>` with a
    // model-owned offset over a column of rows): the wrapper column is
    // sized to the viewport, its rows extend far past it, pixels are
    // correct — and the diagnostic stays quiet on every rebuild.
    var tall_rows: [10]Widget = undefined;
    for (&tall_rows, 0..) |*row, index| {
        row.* = .{
            .id = @intCast(30 + index),
            .kind = .list_item,
            .frame = geometry.RectF.init(0, 0, 0, 60),
            .text = "Note",
        };
    }
    const tracked_column = Widget{
        .id = 1,
        .kind = .column,
        .children = &.{
            .{ .id = 2, .kind = .row, .frame = geometry.RectF.init(0, 0, 0, 40) },
            .{
                .id = 3,
                .kind = .scroll_view,
                .value = 50,
                .layout = .{ .grow = 1 },
                .children = &.{
                    .{ .id = 4, .kind = .column, .children = &tall_rows },
                },
            },
        },
    };
    widget_layout_module.test_axis_overflow_diagnostics = 0;
    var tracked_nodes: [16]WidgetLayoutNode = undefined;
    const tracked_layout = try layoutWidgetTree(tracked_column, geometry.RectF.init(0, 0, 120, 140), &tracked_nodes);
    try std.testing.expectEqual(@as(usize, 0), widget_layout_module.test_axis_overflow_diagnostics);
    // The wrapper is viewport-sized and scrolled up by the offset; the
    // rows stack from there — correct pixels, no warning.
    try expectLayoutFrame(tracked_layout, 4, geometry.RectF.init(0, -10, 120, 100));
    try expectLayoutFrame(tracked_layout, 30, geometry.RectF.init(0, -10, 120, 60));

    // Control: the same tall column with NO scroll ancestor is real
    // silent damage — the diagnostic must still fire for it.
    const bare_column = Widget{
        .id = 1,
        .kind = .column,
        .children = &tall_rows,
    };
    widget_layout_module.test_axis_overflow_diagnostics = 0;
    var bare_nodes: [16]WidgetLayoutNode = undefined;
    _ = try layoutWidgetTree(bare_column, geometry.RectF.init(0, 0, 120, 140), &bare_nodes);
    try std.testing.expectEqual(@as(usize, 1), widget_layout_module.test_axis_overflow_diagnostics);

    // Horizontal overflow inside a vertical scroll still warns: nothing
    // scrolls sideways to reveal those pixels.
    const wide_row_scroll = Widget{
        .id = 1,
        .kind = .scroll_view,
        .children = &.{
            .{
                .id = 2,
                .kind = .row,
                .children = &.{
                    .{ .id = 3, .kind = .badge, .frame = geometry.RectF.init(0, 0, 200, 20), .text = "Wide" },
                    .{ .id = 4, .kind = .badge, .frame = geometry.RectF.init(0, 0, 200, 20), .text = "Wider" },
                },
            },
        },
    };
    widget_layout_module.test_axis_overflow_diagnostics = 0;
    var wide_nodes: [8]WidgetLayoutNode = undefined;
    _ = try layoutWidgetTree(wide_row_scroll, geometry.RectF.init(0, 0, 120, 140), &wide_nodes);
    try std.testing.expectEqual(@as(usize, 1), widget_layout_module.test_axis_overflow_diagnostics);
}

test "widget virtualized list exposes logical item semantics" {
    const children = [_]Widget{
        .{ .id = 2, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Zero" },
        .{ .id = 3, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "One" },
        .{ .id = 4, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Two" },
        .{ .id = 5, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Three" },
        .{ .id = 6, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Four" },
        .{ .id = 7, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Five" },
        .{ .id = 8, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Six" },
        .{ .id = 9, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Seven" },
        .{ .id = 10, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Eight" },
        .{ .id = 11, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Nine" },
    };
    const list = Widget{
        .id = 1,
        .kind = .list,
        .value = 45,
        .layout = .{
            .gap = 5,
            .virtualized = true,
            .virtual_item_extent = 20,
            .virtual_overscan = 1,
        },
        .children = &children,
    };

    var nodes: [6]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(list, geometry.RectF.init(0, 0, 120, 50), &nodes);
    try std.testing.expectEqual(@as(usize, 6), layout.nodeCount());
    try std.testing.expect(layout.findById(7) == null);

    var semantics_buffer: [6]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 6), semantics.len);
    try std.testing.expectEqual(WidgetRole.list, semantics[0].role);
    try std.testing.expect(!semantics[0].list.present);
    try std.testing.expect(semantics[0].scroll.present);
    try std.testing.expectEqual(@as(f32, 45), semantics[0].scroll.offset);
    try std.testing.expectEqual(@as(f32, 50), semantics[0].scroll.viewport_extent);
    try std.testing.expectEqual(@as(f32, 245), semantics[0].scroll.content_extent);
    try std.testing.expect(semantics[0].focusable);
    try std.testing.expect(semantics[0].actions.focus);
    try std.testing.expect(semantics[0].actions.increment);
    try std.testing.expect(semantics[0].actions.decrement);
    try std.testing.expectEqual(@as(ObjectId, 1), layout.focusTargetById(1).?.id);

    try std.testing.expectEqual(WidgetRole.listitem, semantics[1].role);
    try std.testing.expectEqual(@as(ObjectId, 2), semantics[1].id);
    try std.testing.expect(semantics[1].list.present);
    try std.testing.expectEqual(@as(u32, 0), semantics[1].list.item_index);
    try std.testing.expectEqual(@as(u32, 10), semantics[1].list.item_count);

    try std.testing.expectEqual(WidgetRole.listitem, semantics[3].role);
    try std.testing.expectEqual(@as(ObjectId, 4), semantics[3].id);
    try std.testing.expect(semantics[3].list.present);
    try std.testing.expectEqual(@as(u32, 2), semantics[3].list.item_index);
    try std.testing.expectEqual(@as(u32, 10), semantics[3].list.item_count);

    try std.testing.expectEqual(WidgetRole.listitem, semantics[5].role);
    try std.testing.expectEqual(@as(ObjectId, 6), semantics[5].id);
    try std.testing.expect(semantics[5].list.present);
    try std.testing.expectEqual(@as(u32, 4), semantics[5].list.item_index);
    try std.testing.expectEqual(@as(u32, 10), semantics[5].list.item_count);
}

test "widget virtualized list preserves component child roles and item metrics" {
    const children = [_]Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Button" },
        .{ .id = 3, .kind = .checkbox, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Checkbox" },
        .{ .id = 4, .kind = .alert, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Alert" },
        .{ .id = 5, .kind = .badge, .frame = geometry.RectF.init(0, 0, 0, 20), .text = "Badge" },
    };
    const list = Widget{
        .id = 1,
        .kind = .list,
        .layout = .{
            .virtualized = true,
            .virtual_item_extent = 20,
        },
        .children = &children,
    };

    var nodes: [5]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(list, geometry.RectF.init(0, 0, 120, 60), &nodes);
    var semantics_buffer: [5]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);

    try std.testing.expectEqual(@as(usize, 4), semantics.len);
    try std.testing.expectEqual(WidgetRole.list, semantics[0].role);
    try std.testing.expectEqual(WidgetRole.button, semantics[1].role);
    try std.testing.expect(semantics[1].list.present);
    try std.testing.expectEqual(@as(u32, 0), semantics[1].list.item_index);
    try std.testing.expectEqual(@as(u32, 4), semantics[1].list.item_count);
    try std.testing.expectEqual(WidgetRole.checkbox, semantics[2].role);
    try std.testing.expect(semantics[2].list.present);
    try std.testing.expectEqual(@as(u32, 1), semantics[2].list.item_index);
    try std.testing.expectEqual(WidgetRole.group, semantics[3].role);
    try std.testing.expect(semantics[3].list.present);
    try std.testing.expectEqual(@as(u32, 2), semantics[3].list.item_index);
}

test "widget pointer route includes capture target and bubble phases" {
    const row_children = [_]Widget{.{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(0, 0, 80, 32),
        .text = "Run",
    }};
    const root_children = [_]Widget{.{
        .id = 5,
        .kind = .row,
        .frame = geometry.RectF.init(8, 8, 120, 40),
        .children = &row_children,
    }};
    const root = Widget{
        .id = 1,
        .kind = .panel,
        .children = &root_children,
    };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 160, 80), &nodes);
    var route_entries: [5]WidgetEventRouteEntry = undefined;
    const route = try layout.routePointerEvent(.{
        .phase = .down,
        .point = geometry.PointF.init(20, 20),
    }, &route_entries);

    try std.testing.expect(route.target != null);
    try std.testing.expectEqual(@as(ObjectId, 2), route.target.?.id);
    try std.testing.expectEqual(@as(usize, 5), route.entries.len);
    try expectRouteEntry(route.entries[0], .capture, 1);
    try expectRouteEntry(route.entries[1], .capture, 5);
    try expectRouteEntry(route.entries[2], .target, 2);
    try expectRouteEntry(route.entries[3], .bubble, 5);
    try expectRouteEntry(route.entries[4], .bubble, 1);
}

test "widget pointer route honors captured target for drag lifecycle" {
    const row_children = [_]Widget{.{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(0, 0, 80, 32),
        .text = "Run",
    }};
    const root_children = [_]Widget{.{
        .id = 5,
        .kind = .row,
        .frame = geometry.RectF.init(8, 8, 120, 40),
        .children = &row_children,
    }};
    const root = Widget{
        .id = 1,
        .kind = .panel,
        .children = &root_children,
    };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 160, 80), &nodes);

    var move_entries: [5]WidgetEventRouteEntry = undefined;
    const move_route = try layout.routePointerEvent(.{
        .phase = .move,
        .point = geometry.PointF.init(220, 120),
        .captured_id = 2,
    }, &move_entries);
    try std.testing.expect(move_route.target != null);
    try std.testing.expectEqual(@as(ObjectId, 2), move_route.target.?.id);
    try std.testing.expectEqual(@as(usize, 5), move_route.entries.len);
    try expectRouteEntry(move_route.entries[0], .capture, 1);
    try expectRouteEntry(move_route.entries[1], .capture, 5);
    try expectRouteEntry(move_route.entries[2], .target, 2);
    try expectRouteEntry(move_route.entries[3], .bubble, 5);
    try expectRouteEntry(move_route.entries[4], .bubble, 1);

    var up_entries: [5]WidgetEventRouteEntry = undefined;
    const up_route = try layout.routePointerEvent(.{
        .phase = .up,
        .point = geometry.PointF.init(220, 120),
        .captured_id = 2,
    }, &up_entries);
    try std.testing.expectEqual(@as(ObjectId, 2), up_route.target.?.id);

    var cancel_entries: [5]WidgetEventRouteEntry = undefined;
    const cancel_route = try layout.routePointerEvent(.{
        .phase = .cancel,
        .point = geometry.PointF.init(220, 120),
        .captured_id = 2,
    }, &cancel_entries);
    try std.testing.expectEqual(@as(ObjectId, 2), cancel_route.target.?.id);
}

test "widget pointer route skips scroll clipped captured targets" {
    const children = [_]Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "Hidden" },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 48, 0, 32), .text = "Visible" },
    };
    const scroll = Widget{
        .id = 1,
        .kind = .scroll_view,
        .value = 40,
        .children = &children,
    };

    var nodes: [3]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(scroll, geometry.RectF.init(0, 0, 120, 48), &nodes);
    try expectLayoutFrame(layout, 2, geometry.RectF.init(0, -40, 120, 32));
    try expectLayoutFrame(layout, 3, geometry.RectF.init(0, 8, 120, 32));

    var hidden_entries: [0]WidgetEventRouteEntry = .{};
    const hidden_route = try layout.routePointerEvent(.{
        .phase = .move,
        .point = geometry.PointF.init(10, 20),
        .captured_id = 2,
    }, &hidden_entries);
    try std.testing.expect(hidden_route.target == null);
    try std.testing.expectEqual(@as(usize, 0), hidden_route.entries.len);

    var visible_entries: [3]WidgetEventRouteEntry = undefined;
    const visible_route = try layout.routePointerEvent(.{
        .phase = .move,
        .point = geometry.PointF.init(180, 80),
        .captured_id = 3,
    }, &visible_entries);
    try std.testing.expect(visible_route.target != null);
    try std.testing.expectEqual(@as(ObjectId, 3), visible_route.target.?.id);
    try std.testing.expectEqual(@as(usize, 3), visible_route.entries.len);
    try expectRouteEntry(visible_route.entries[0], .capture, 1);
    try expectRouteEntry(visible_route.entries[1], .target, 3);
    try expectRouteEntry(visible_route.entries[2], .bubble, 1);
}

test "widget pointer capture does not retarget hover down or wheel" {
    const root = Widget{
        .id = 1,
        .kind = .panel,
        .children = &.{.{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(10, 10, 80, 32),
            .text = "Run",
        }},
    };

    var nodes: [3]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 120, 80), &nodes);
    var empty_entries: [0]WidgetEventRouteEntry = .{};

    const hover_route = try layout.routePointerEvent(.{
        .phase = .hover,
        .point = geometry.PointF.init(200, 20),
        .captured_id = 2,
    }, &empty_entries);
    try std.testing.expect(hover_route.target == null);
    try std.testing.expectEqual(@as(usize, 0), hover_route.entries.len);

    const down_route = try layout.routePointerEvent(.{
        .phase = .down,
        .point = geometry.PointF.init(200, 20),
        .captured_id = 2,
    }, &empty_entries);
    try std.testing.expect(down_route.target == null);
    try std.testing.expectEqual(@as(usize, 0), down_route.entries.len);

    const wheel_route = try layout.routePointerEvent(.{
        .phase = .wheel,
        .point = geometry.PointF.init(200, 20),
        .delta = geometry.OffsetF.init(0, -16),
        .captured_id = 2,
    }, &empty_entries);
    try std.testing.expect(wheel_route.target == null);
    try std.testing.expectEqual(@as(usize, 0), wheel_route.entries.len);
}

test "widget pointer route handles no hit and bounded output" {
    const root = Widget{
        .id = 1,
        .kind = .panel,
        .children = &.{.{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(10, 10, 80, 32),
            .text = "Run",
        }},
    };

    var nodes: [3]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 120, 80), &nodes);
    var empty_entries: [0]WidgetEventRouteEntry = .{};
    const no_hit = try layout.routePointerEvent(.{
        .phase = .down,
        .point = geometry.PointF.init(200, 20),
    }, &empty_entries);
    try std.testing.expect(no_hit.target == null);
    try std.testing.expectEqual(@as(usize, 0), no_hit.entries.len);

    var small_entries: [1]WidgetEventRouteEntry = undefined;
    try std.testing.expectError(error.WidgetEventRouteListFull, layout.routePointerEvent(.{
        .phase = .down,
        .point = geometry.PointF.init(20, 20),
    }, &small_entries));
}

test "widget file drop route targets explicit drop semantics" {
    const row_children = [_]Widget{.{
        .id = 3,
        .kind = .button,
        .frame = geometry.RectF.init(0, 0, 80, 32),
        .text = "Upload",
    }};
    const root_children = [_]Widget{.{
        .id = 2,
        .kind = .row,
        .frame = geometry.RectF.init(8, 8, 120, 44),
        .semantics = .{ .actions = .{ .drop_files = true } },
        .children = &row_children,
    }};
    const root = Widget{
        .id = 1,
        .kind = .panel,
        .children = &root_children,
    };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 160, 80), &nodes);
    const paths = [_][]const u8{"/tmp/image.png"};
    var route_entries: [3]WidgetEventRouteEntry = undefined;
    const route = try layout.routeFileDropEvent(.{
        .point = geometry.PointF.init(20, 20),
        .paths = &paths,
    }, &route_entries);

    try std.testing.expect(route.target != null);
    try std.testing.expectEqual(@as(ObjectId, 2), route.target.?.id);
    try std.testing.expectEqual(WidgetKind.row, route.target.?.kind);
    try std.testing.expectEqual(@as(usize, 3), route.entries.len);
    try expectRouteEntry(route.entries[0], .capture, 1);
    try expectRouteEntry(route.entries[1], .target, 2);
    try expectRouteEntry(route.entries[2], .bubble, 1);

    var semantics_buffer: [4]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    for (semantics) |semantic| {
        if (semantic.id == 2) {
            try std.testing.expect(semantic.actions.drop_files);
            return;
        }
    }
    return error.TestUnexpectedResult;
}

test "widget file drop route ignores missing paths disabled and non-drop targets" {
    const root = Widget{
        .id = 1,
        .kind = .panel,
        .children = &.{
            .{
                .id = 2,
                .kind = .panel,
                .frame = geometry.RectF.init(8, 8, 80, 44),
                .semantics = .{ .actions = .{ .drop_files = true } },
                .state = .{ .disabled = true },
            },
            .{
                .id = 3,
                .kind = .button,
                .frame = geometry.RectF.init(96, 8, 80, 44),
                .text = "Plain",
            },
        },
    };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 200, 80), &nodes);
    const paths = [_][]const u8{"/tmp/report.csv"};
    var empty_entries: [0]WidgetEventRouteEntry = .{};

    const no_paths = try layout.routeFileDropEvent(.{
        .point = geometry.PointF.init(20, 20),
    }, &empty_entries);
    try std.testing.expect(no_paths.target == null);
    try std.testing.expectEqual(@as(usize, 0), no_paths.entries.len);

    const disabled = try layout.routeFileDropEvent(.{
        .point = geometry.PointF.init(20, 20),
        .paths = &paths,
    }, &empty_entries);
    try std.testing.expect(disabled.target == null);
    try std.testing.expectEqual(@as(usize, 0), disabled.entries.len);

    const plain = try layout.routeFileDropEvent(.{
        .point = geometry.PointF.init(110, 20),
        .paths = &paths,
    }, &empty_entries);
    try std.testing.expect(plain.target == null);
    try std.testing.expectEqual(@as(usize, 0), plain.entries.len);
}

test "widget drag route targets explicit drag source semantics" {
    const row_children = [_]Widget{.{
        .id = 3,
        .kind = .button,
        .frame = geometry.RectF.init(0, 0, 80, 32),
        .text = "Move",
    }};
    const root_children = [_]Widget{.{
        .id = 2,
        .kind = .row,
        .frame = geometry.RectF.init(8, 8, 120, 44),
        .semantics = .{ .actions = .{ .drag = true } },
        .children = &row_children,
    }};
    const root = Widget{
        .id = 1,
        .kind = .panel,
        .children = &root_children,
    };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 160, 80), &nodes);
    var route_entries: [3]WidgetEventRouteEntry = undefined;
    const route = try layout.routeDragEvent(.{
        .source_id = 2,
        .point = geometry.PointF.init(60, 40),
        .delta = geometry.OffsetF.init(20, 4),
    }, &route_entries);

    try std.testing.expect(route.target != null);
    try std.testing.expectEqual(@as(ObjectId, 2), route.target.?.id);
    try std.testing.expectEqual(WidgetKind.row, route.target.?.kind);
    try std.testing.expectEqual(@as(usize, 3), route.entries.len);
    try expectRouteEntry(route.entries[0], .capture, 1);
    try expectRouteEntry(route.entries[1], .target, 2);
    try expectRouteEntry(route.entries[2], .bubble, 1);

    var semantics_buffer: [4]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    for (semantics) |semantic| {
        if (semantic.id == 2) {
            try std.testing.expect(semantic.actions.drag);
            return;
        }
    }
    return error.TestUnexpectedResult;
}

test "widget drag route ignores missing disabled and non-drag sources" {
    const root = Widget{
        .id = 1,
        .kind = .panel,
        .children = &.{
            .{
                .id = 2,
                .kind = .panel,
                .frame = geometry.RectF.init(8, 8, 80, 44),
                .semantics = .{ .actions = .{ .drag = true } },
                .state = .{ .disabled = true },
            },
            .{
                .id = 3,
                .kind = .button,
                .frame = geometry.RectF.init(96, 8, 80, 44),
                .text = "Plain",
            },
        },
    };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 200, 80), &nodes);
    var empty_entries: [0]WidgetEventRouteEntry = .{};

    const no_source = try layout.routeDragEvent(.{
        .point = geometry.PointF.init(20, 20),
    }, &empty_entries);
    try std.testing.expect(no_source.target == null);
    try std.testing.expectEqual(@as(usize, 0), no_source.entries.len);

    const disabled = try layout.routeDragEvent(.{
        .source_id = 2,
        .point = geometry.PointF.init(20, 20),
    }, &empty_entries);
    try std.testing.expect(disabled.target == null);
    try std.testing.expectEqual(@as(usize, 0), disabled.entries.len);

    const plain = try layout.routeDragEvent(.{
        .source_id = 3,
        .point = geometry.PointF.init(110, 20),
    }, &empty_entries);
    try std.testing.expect(plain.target == null);
    try std.testing.expectEqual(@as(usize, 0), plain.entries.len);
}

test "widget drag route skips scroll clipped sources" {
    const children = [_]Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "Hidden", .semantics = .{ .actions = .{ .drag = true } } },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(0, 48, 0, 32), .text = "Visible", .semantics = .{ .actions = .{ .drag = true } } },
    };
    const scroll = Widget{
        .id = 1,
        .kind = .scroll_view,
        .value = 40,
        .children = &children,
    };

    var nodes: [3]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(scroll, geometry.RectF.init(0, 0, 120, 48), &nodes);
    try expectLayoutFrame(layout, 2, geometry.RectF.init(0, -40, 120, 32));
    try expectLayoutFrame(layout, 3, geometry.RectF.init(0, 8, 120, 32));

    var hidden_entries: [0]WidgetEventRouteEntry = .{};
    const hidden = try layout.routeDragEvent(.{
        .source_id = 2,
        .point = geometry.PointF.init(180, 80),
        .delta = geometry.OffsetF.init(12, 0),
    }, &hidden_entries);
    try std.testing.expect(hidden.target == null);
    try std.testing.expectEqual(@as(usize, 0), hidden.entries.len);

    var visible_entries: [3]WidgetEventRouteEntry = undefined;
    const visible = try layout.routeDragEvent(.{
        .source_id = 3,
        .point = geometry.PointF.init(180, 80),
        .delta = geometry.OffsetF.init(12, 0),
    }, &visible_entries);
    try std.testing.expect(visible.target != null);
    try std.testing.expectEqual(@as(ObjectId, 3), visible.target.?.id);
    try std.testing.expectEqual(@as(usize, 3), visible.entries.len);
    try expectRouteEntry(visible.entries[0], .capture, 1);
    try expectRouteEntry(visible.entries[1], .target, 3);
    try expectRouteEntry(visible.entries[2], .bubble, 1);
}

test "widget keyboard route uses focused target and ancestors" {
    const row_children = [_]Widget{.{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(0, 0, 120, 32),
        .text = "Find",
    }};
    const root_children = [_]Widget{.{
        .id = 5,
        .kind = .row,
        .frame = geometry.RectF.init(8, 8, 140, 40),
        .children = &row_children,
    }};
    const root = Widget{
        .id = 1,
        .kind = .panel,
        .children = &root_children,
    };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 180, 80), &nodes);
    var route_entries: [5]WidgetEventRouteEntry = undefined;
    const route = try layout.routeKeyboardEvent(.{
        .phase = .key_down,
        .focused_id = 2,
        .key = "enter",
    }, &route_entries);

    try std.testing.expect(route.target != null);
    try std.testing.expectEqual(@as(ObjectId, 2), route.target.?.id);
    try std.testing.expectEqual(WidgetKind.text_field, route.target.?.kind);
    try std.testing.expectEqual(@as(usize, 5), route.entries.len);
    try expectRouteEntry(route.entries[0], .capture, 1);
    try expectRouteEntry(route.entries[1], .capture, 5);
    try expectRouteEntry(route.entries[2], .target, 2);
    try expectRouteEntry(route.entries[3], .bubble, 5);
    try expectRouteEntry(route.entries[4], .bubble, 1);
}

test "widget keyboard route handles missing focus non-focus targets and bounded output" {
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .text,
            .frame = geometry.RectF.init(8, 8, 100, 20),
            .text = "Title",
        },
        .{
            .id = 3,
            .kind = .button,
            .frame = geometry.RectF.init(8, 36, 100, 32),
            .text = "Disabled",
            .state = .{ .disabled = true },
        },
        .{
            .id = 4,
            .kind = .button,
            .frame = geometry.RectF.init(8, 76, 100, 32),
            .text = "Run",
        },
    };
    const root = Widget{ .id = 1, .kind = .panel, .children = &children };

    var nodes: [5]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 140, 120), &nodes);

    var empty_entries: [0]WidgetEventRouteEntry = .{};
    const no_focus = try layout.routeKeyboardEvent(.{ .phase = .key_down, .key = "enter" }, &empty_entries);
    try std.testing.expect(no_focus.target == null);
    try std.testing.expectEqual(@as(usize, 0), no_focus.entries.len);

    const text_target = try layout.routeKeyboardEvent(.{ .phase = .key_down, .focused_id = 2, .key = "enter" }, &empty_entries);
    try std.testing.expect(text_target.target == null);
    try std.testing.expectEqual(@as(usize, 0), text_target.entries.len);

    const disabled_target = try layout.routeKeyboardEvent(.{ .phase = .key_down, .focused_id = 3, .key = "enter" }, &empty_entries);
    try std.testing.expect(disabled_target.target == null);
    try std.testing.expectEqual(@as(usize, 0), disabled_target.entries.len);

    var small_entries: [1]WidgetEventRouteEntry = undefined;
    try std.testing.expectError(error.WidgetEventRouteListFull, layout.routeKeyboardEvent(.{
        .phase = .key_down,
        .focused_id = 4,
        .key = "enter",
    }, &small_entries));
}

test "widget focus traversal skips disabled nodes and wraps" {
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .text,
            .frame = geometry.RectF.init(0, 0, 100, 20),
            .text = "Search",
            .semantics = .{ .focusable = true },
        },
        .{
            .id = 3,
            .kind = .button,
            .frame = geometry.RectF.init(0, 28, 100, 32),
            .text = "Disabled",
            .state = .{ .disabled = true },
        },
        .{
            .id = 4,
            .kind = .button,
            .frame = geometry.RectF.init(0, 68, 100, 32),
            .text = "Apply",
        },
    };
    const root = Widget{ .kind = .stack, .children = &children };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 140, 120), &nodes);
    try std.testing.expectEqual(@as(ObjectId, 2), layout.focusTarget(null, .forward).?.id);
    try std.testing.expectEqual(@as(ObjectId, 4), layout.focusTarget(2, .forward).?.id);
    try std.testing.expectEqual(@as(ObjectId, 2), layout.focusTarget(4, .forward).?.id);
    try std.testing.expectEqual(@as(ObjectId, 4), layout.focusTarget(2, .backward).?.id);
    try std.testing.expectEqual(@as(ObjectId, 4), layout.focusTarget(null, .backward).?.id);
}

test "widget focus target lookup validates focusable ids" {
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .text,
            .frame = geometry.RectF.init(0, 0, 100, 20),
            .text = "Title",
        },
        .{
            .id = 3,
            .kind = .button,
            .frame = geometry.RectF.init(0, 28, 100, 32),
            .text = "Run",
        },
        .{
            .id = 4,
            .kind = .button,
            .frame = geometry.RectF.init(0, 68, 100, 32),
            .text = "Disabled",
            .state = .{ .disabled = true },
        },
    };
    const root = Widget{ .kind = .stack, .children = &children };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 140, 120), &nodes);
    try std.testing.expect(layout.focusTargetById(2) == null);
    try std.testing.expect(layout.focusTargetById(4) == null);
    try std.testing.expect(layout.focusTargetById(99) == null);

    const target = layout.focusTargetById(3).?;
    try std.testing.expectEqual(@as(ObjectId, 3), target.id);
    try std.testing.expectEqual(WidgetKind.button, target.kind);
}

fn doubledTextMeasure(context: ?*anyopaque, font_id: FontId, size: f32, text: []const u8) f32 {
    _ = context;
    _ = font_id;
    return size * 2 * @as(f32, @floatFromInt(text.len));
}

const doubled_text_measure = support.TextMeasureProvider{ .measure_fn = doubledTextMeasure };

test "intrinsic text sizing defaults to the estimator and honors an injected provider" {
    const widget = Widget{ .id = 1, .kind = .text, .text = "Refresh dashboard" };
    const default_tokens = DesignTokens{};
    const default_size = intrinsicWidgetSize(widget, default_tokens);
    try std.testing.expectEqual(
        estimateTextWidthForFont(default_tokens.typography.font_id, widget.text, default_tokens.typography.body_size),
        default_size.width,
    );

    const measured_tokens = DesignTokens{ .text_measure = &doubled_text_measure };
    const measured_size = intrinsicWidgetSize(widget, measured_tokens);
    try std.testing.expectEqual(
        default_tokens.typography.body_size * 2 * @as(f32, @floatFromInt(widget.text.len)),
        measured_size.width,
    );
    try std.testing.expect(measured_size.width != default_size.width);
    try std.testing.expectEqual(default_size.height, measured_size.height);
}

test "text size rungs resolve the typography tokens and retheme with overrides" {
    const tokens = DesignTokens{};
    const heading = Widget{ .id = 1, .kind = .text, .text = "Usage" };
    const heading_sized = Widget{ .id = 1, .kind = .text, .text = "Usage", .size = .heading };
    const display_sized = Widget{ .id = 2, .kind = .text, .text = "42.7%", .size = .display };

    // The rungs REPLACE the body base with the named token: intrinsic
    // height is the rung's 1.25 line height, width the rung-sized
    // measurement.
    const heading_size = intrinsicWidgetSize(heading_sized, tokens);
    const display_size = intrinsicWidgetSize(display_sized, tokens);
    try std.testing.expectEqual(tokens.typography.heading_size * 1.25, heading_size.height);
    try std.testing.expectEqual(tokens.typography.display_size * 1.25, display_size.height);
    try std.testing.expect(heading_size.width > intrinsicWidgetSize(heading, tokens).width);

    // Themable like every typography token: an override moves the rung.
    const themed = DesignTokens{ .typography = (TypographyTokenOverrides{ .display_size = 36 }).apply(.{}) };
    try std.testing.expectEqual(@as(f32, 36 * 1.25), intrinsicWidgetSize(display_sized, themed).height);

    // Like body/title, the rungs do not density-scale (density scales
    // chrome, never glyph sizes).
    const compact = DesignTokens{ .density = .compact };
    try std.testing.expectEqual(display_size.height, intrinsicWidgetSize(display_sized, compact).height);

    // On a control the rungs are inert: the button stays at its default
    // control step (markup rejects this shape; Zig views get a Debug
    // warning).
    const button = Widget{ .id = 3, .kind = .button, .text = "Run" };
    const button_display = Widget{ .id = 3, .kind = .button, .text = "Run", .size = .display };
    try std.testing.expectEqualDeep(intrinsicWidgetSize(button, tokens), intrinsicWidgetSize(button_display, tokens));
}

test "widget tree layout widths follow the injected text measure provider" {
    const button = Widget{ .id = 2, .kind = .button, .text = "Run" };
    const row_children = [_]Widget{button};
    const row = Widget{ .id = 1, .kind = .row, .children = &row_children };

    var default_nodes: [2]WidgetLayoutNode = undefined;
    const default_layout = try layoutWidgetTreeWithTokens(row, geometry.RectF.init(0, 0, 400, 64), .{}, &default_nodes);

    var measured_nodes: [2]WidgetLayoutNode = undefined;
    const measured_tokens = DesignTokens{ .text_measure = &doubled_text_measure };
    const measured_layout = try layoutWidgetTreeWithTokens(row, geometry.RectF.init(0, 0, 400, 64), measured_tokens, &measured_nodes);

    try std.testing.expect(measured_layout.findById(2).?.frame.width > default_layout.findById(2).?.frame.width);
}

// ------------------------------------------------------ definite sizes

test "definite width caps intrinsic content so siblings keep their share" {
    // A sidebar repro shape: a non-growing 360px pane whose single-line text
    // is far wider than the pane. With width as a min-only floor the pane
    // ballooned to its intrinsic text width and starved the growing
    // sibling; a definite width (min AND max) keeps the pane at 360.
    const long_text = "A long single-line status message that lays out much wider than the pane it sits in, pushing siblings to zero";
    const pane_children = [_]Widget{
        .{ .id = 3, .kind = .text, .text = long_text },
    };
    const definite = geometry.SizeF.init(360, 0);
    const row_children = [_]Widget{
        .{
            .id = 2,
            .kind = .column,
            .layout = .{ .min_size = definite, .max_size = definite },
            .children = &pane_children,
        },
        .{ .id = 4, .kind = .column, .layout = .{ .grow = 1 } },
    };
    const root = Widget{ .id = 1, .kind = .row, .children = &row_children };

    var nodes: [8]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 800, 200), &nodes);
    try expectLayoutFrame(layout, 2, geometry.RectF.init(0, 0, 360, 200));
    try expectLayoutFrame(layout, 4, geometry.RectF.init(360, 0, 440, 200));
    // The text child stretches to the pane's definite width, not past it.
    try std.testing.expectEqual(@as(f32, 360), layout.findById(3).?.frame.width);
}

test "min-only width keeps the classic floor behavior" {
    // The min channel alone (no max) still lets intrinsic content widen
    // the box - the pre-definite behavior existing Zig callers of
    // `min_size` rely on.
    const long_text = "A long single-line status message that lays out much wider than the pane it sits in, pushing siblings to zero";
    const pane_children = [_]Widget{
        .{ .id = 3, .kind = .text, .text = long_text },
    };
    const row_children = [_]Widget{
        .{
            .id = 2,
            .kind = .column,
            .layout = .{ .min_size = geometry.SizeF.init(360, 0) },
            .children = &pane_children,
        },
        .{ .id = 4, .kind = .column, .layout = .{ .grow = 1 } },
    };
    const root = Widget{ .id = 1, .kind = .row, .children = &row_children };

    var nodes: [8]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 800, 200), &nodes);
    try std.testing.expect(layout.findById(2).?.frame.width > 360);
}

test "definite width caps grow distribution" {
    const definite = geometry.SizeF.init(200, 0);
    const row_children = [_]Widget{
        .{ .id = 2, .kind = .column, .layout = .{ .grow = 1, .min_size = definite, .max_size = definite } },
        .{ .id = 3, .kind = .column, .layout = .{ .grow = 1 } },
    };
    const root = Widget{ .id = 1, .kind = .row, .children = &row_children };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 800, 100), &nodes);
    try expectLayoutFrame(layout, 2, geometry.RectF.init(0, 0, 200, 100));
    try expectLayoutFrame(layout, 3, geometry.RectF.init(200, 0, 400, 100));
}

test "definite height caps cross-axis stretch in a row" {
    const definite = geometry.SizeF.init(0, 40);
    const row_children = [_]Widget{
        .{ .id = 2, .kind = .column, .layout = .{ .grow = 1, .min_size = definite, .max_size = definite } },
    };
    const root = Widget{ .id = 1, .kind = .row, .children = &row_children };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 300, 200), &nodes);
    try expectLayoutFrame(layout, 2, geometry.RectF.init(0, 0, 300, 40));
}

test "definite size caps stack children instead of stretching them" {
    const definite = geometry.SizeF.init(120, 60);
    const stack_children = [_]Widget{
        .{ .id = 2, .kind = .panel, .layout = .{ .min_size = definite, .max_size = definite } },
    };
    const root = Widget{ .id = 1, .kind = .stack, .children = &stack_children };

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 500, 400), &nodes);
    try expectLayoutFrame(layout, 2, geometry.RectF.init(0, 0, 120, 60));
}

// ------------------------------------------------- separator orientation

test "separator in a row is a thin vertical divider" {
    // A two-pane repro shape: a divider between two growing panes. The
    // separator's h-rule default length no longer applies in the row
    // axis, so it takes its stroke width (hairline) and the panes split
    // the rest.
    const row_children = [_]Widget{
        .{ .id = 2, .kind = .column, .layout = .{ .grow = 1 } },
        .{ .id = 3, .kind = .separator },
        .{ .id = 4, .kind = .column, .layout = .{ .grow = 1 } },
    };
    const root = Widget{ .id = 1, .kind = .row, .children = &row_children };

    var nodes: [8]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 401, 120), &nodes);
    try expectLayoutFrame(layout, 2, geometry.RectF.init(0, 0, 200, 120));
    try expectLayoutFrame(layout, 3, geometry.RectF.init(200, 0, 1, 120));
    try expectLayoutFrame(layout, 4, geometry.RectF.init(201, 0, 200, 120));
}

test "separator in a column keeps the horizontal rule behavior" {
    const column_children = [_]Widget{
        .{ .id = 2, .kind = .text, .text = "Above" },
        .{ .id = 3, .kind = .separator },
        .{ .id = 4, .kind = .text, .text = "Below" },
    };
    const root = Widget{ .id = 1, .kind = .column, .children = &column_children };

    var nodes: [8]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 240, 200), &nodes);
    const separator = layout.findById(3).?.frame;
    try std.testing.expectEqual(@as(f32, 240), separator.width);
    try std.testing.expectEqual(@as(f32, 1), separator.height);
}

test "row intrinsic width counts a separator as its stroke width" {
    const inner_children = [_]Widget{
        .{ .id = 3, .kind = .stack, .frame = geometry.RectF.init(0, 0, 50, 20) },
        .{ .id = 4, .kind = .separator },
        .{ .id = 5, .kind = .stack, .frame = geometry.RectF.init(0, 0, 50, 20) },
    };
    const outer_children = [_]Widget{
        .{ .id = 2, .kind = .row, .children = &inner_children },
        .{ .id = 6, .kind = .column, .layout = .{ .grow = 1 } },
    };
    const root = Widget{ .id = 1, .kind = .row, .children = &outer_children };

    var nodes: [8]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 800, 100), &nodes);
    // 50 + 1 + 50: the separator contributes its stroke width, not the
    // 160px horizontal-rule default.
    try std.testing.expectEqual(@as(f32, 101), layout.findById(2).?.frame.width);
}

// ------------------------------------------------ overflow diagnostics

test "axis layout overflow is reported past the float-noise epsilon" {
    const widget_layout = @import("widget_layout.zig");
    try std.testing.expect(widget_layout.axisLayoutOverflow(400, 400) == null);
    try std.testing.expect(widget_layout.axisLayoutOverflow(400, 400.25) == null);
    const overflow = widget_layout.axisLayoutOverflow(400, 446) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f32, 46), overflow);
}
