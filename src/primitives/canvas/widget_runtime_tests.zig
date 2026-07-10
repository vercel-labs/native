const support = @import("test_support.zig");
const widget_render_style = @import("widget_render_style.zig");
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

test "widget layout reports fixed buffer errors" {
    const children = [_]Widget{
        .{ .id = 2, .kind = .text, .text = "One" },
        .{ .id = 3, .kind = .text, .text = "Two" },
    };
    const root = Widget{ .id = 1, .kind = .stack, .children = &children };

    var small_nodes: [2]WidgetLayoutNode = undefined;
    try std.testing.expectError(error.WidgetLayoutListFull, layoutWidgetTree(root, geometry.RectF.init(0, 0, 100, 100), &small_nodes));

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 100, 100), &nodes);
    var small_semantics: [1]WidgetSemanticsNode = undefined;
    try std.testing.expectError(error.WidgetSemanticsListFull, layout.collectSemantics(&small_semantics));
}

test "widget layout diff tracks added removed and layout changes by id" {
    const previous_children = [_]Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(10, 10, 100, 30),
            .text = "Run",
        },
        .{
            .id = 3,
            .kind = .progress,
            .frame = geometry.RectF.init(10, 50, 100, 8),
            .value = 0.4,
        },
    };
    const next_children = [_]Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(20, 10, 100, 30),
            .text = "Run",
            .state = .{ .focused = true },
        },
        .{
            .id = 4,
            .kind = .text,
            .frame = geometry.RectF.init(10, 50, 100, 20),
            .text = "Done",
        },
    };

    var previous_nodes: [4]WidgetLayoutNode = undefined;
    var next_nodes: [4]WidgetLayoutNode = undefined;
    const previous = try layoutWidgetTree(.{ .id = 1, .kind = .stack, .children = &previous_children }, geometry.RectF.init(0, 0, 180, 100), &previous_nodes);
    const next = try layoutWidgetTree(.{ .id = 1, .kind = .stack, .children = &next_children }, geometry.RectF.init(0, 0, 180, 100), &next_nodes);

    var invalidations_buffer: [4]WidgetInvalidation = undefined;
    const invalidations = try WidgetLayoutTree.diff(previous, next, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 3), invalidations.len);

    try std.testing.expectEqual(WidgetInvalidationKind.changed, invalidations[0].kind);
    try std.testing.expectEqual(@as(ObjectId, 2), invalidations[0].id);
    try std.testing.expect(invalidations[0].layout_dirty);
    try std.testing.expect(invalidations[0].paint_dirty);
    try std.testing.expect(invalidations[0].semantics_dirty);
    // The button is flat (no shadow halo), so the damage is the union
    // of the old and new frames plus their chrome-stroke outsets: half
    // of the resting 1px border around the old frame, half of the 2px
    // focus-weight stroke around the new (focused) frame.
    try expectRect(geometry.RectF.init(9.5, 9, 111.5, 32), invalidations[0].dirty_bounds);

    try std.testing.expectEqual(WidgetInvalidationKind.removed, invalidations[1].kind);
    try std.testing.expectEqual(@as(ObjectId, 3), invalidations[1].id);
    try expectRect(geometry.RectF.init(10, 50, 100, 8), invalidations[1].dirty_bounds);

    try std.testing.expectEqual(WidgetInvalidationKind.added, invalidations[2].kind);
    try std.testing.expectEqual(@as(ObjectId, 4), invalidations[2].id);
    try expectRect(geometry.RectF.init(10, 50, 100, 20), invalidations[2].dirty_bounds);
}

test "widget layout diff includes paint overdraw in dirty bounds" {
    const panel_child = [_]Widget{.{
        .id = 2,
        .kind = .panel,
        .frame = geometry.RectF.init(10, 10, 100, 40),
    }};
    const hidden_panel_child = [_]Widget{.{
        .id = 2,
        .kind = .panel,
        .frame = geometry.RectF.init(10, 10, 100, 40),
        .semantics = .{ .hidden = true },
    }};
    const overflow_panel_children = [_]Widget{.{
        .id = 6,
        .kind = .text,
        .frame = geometry.RectF.init(100, 10, 80, 20),
        .text = "Overflow",
    }};
    const visible_overflow_panel_child = [_]Widget{.{
        .id = 5,
        .kind = .panel,
        .frame = geometry.RectF.init(10, 10, 40, 20),
        .children = &overflow_panel_children,
    }};
    const hidden_overflow_panel_child = [_]Widget{.{
        .id = 5,
        .kind = .panel,
        .frame = geometry.RectF.init(10, 10, 40, 20),
        .semantics = .{ .hidden = true },
        .children = &overflow_panel_children,
    }};
    const unfocused_child = [_]Widget{.{
        .id = 3,
        .kind = .button,
        .frame = geometry.RectF.init(10, 70, 100, 30),
        .text = "Focus",
    }};
    const focused_child = [_]Widget{.{
        .id = 3,
        .kind = .button,
        .frame = geometry.RectF.init(10, 70, 100, 30),
        .text = "Focus",
        .state = .{ .focused = true },
    }};

    var previous_panel_nodes: [2]WidgetLayoutNode = undefined;
    var next_panel_nodes: [1]WidgetLayoutNode = undefined;
    var hidden_panel_nodes: [2]WidgetLayoutNode = undefined;
    var visible_overflow_panel_nodes: [3]WidgetLayoutNode = undefined;
    var hidden_overflow_panel_nodes: [3]WidgetLayoutNode = undefined;
    const previous_panel = try layoutWidgetTree(.{ .kind = .stack, .children = &panel_child }, geometry.RectF.init(0, 0, 160, 120), &previous_panel_nodes);
    const next_panel = try layoutWidgetTree(.{ .kind = .stack, .children = &.{} }, geometry.RectF.init(0, 0, 160, 120), &next_panel_nodes);
    const hidden_panel = try layoutWidgetTree(.{ .kind = .stack, .children = &hidden_panel_child }, geometry.RectF.init(0, 0, 160, 120), &hidden_panel_nodes);
    const visible_overflow_panel = try layoutWidgetTree(.{ .kind = .stack, .children = &visible_overflow_panel_child }, geometry.RectF.init(0, 0, 220, 120), &visible_overflow_panel_nodes);
    const hidden_overflow_panel = try layoutWidgetTree(.{ .kind = .stack, .children = &hidden_overflow_panel_child }, geometry.RectF.init(0, 0, 220, 120), &hidden_overflow_panel_nodes);

    var invalidations_buffer: [2]WidgetInvalidation = undefined;
    const panel_invalidations = try WidgetLayoutTree.diff(previous_panel, next_panel, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 1), panel_invalidations.len);
    try std.testing.expectEqual(WidgetInvalidationKind.removed, panel_invalidations[0].kind);
    try std.testing.expectEqual(@as(ObjectId, 2), panel_invalidations[0].id);
    try expectRect(geometry.RectF.init(-2, 0, 124, 64), panel_invalidations[0].dirty_bounds);

    const hidden_panel_invalidations = try WidgetLayoutTree.diff(previous_panel, hidden_panel, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 1), hidden_panel_invalidations.len);
    try std.testing.expectEqual(WidgetInvalidationKind.changed, hidden_panel_invalidations[0].kind);
    try std.testing.expectEqual(@as(ObjectId, 2), hidden_panel_invalidations[0].id);
    try std.testing.expect(!hidden_panel_invalidations[0].layout_dirty);
    try std.testing.expect(hidden_panel_invalidations[0].paint_dirty);
    try std.testing.expect(hidden_panel_invalidations[0].semantics_dirty);
    try expectRect(geometry.RectF.init(-2, 0, 124, 64), hidden_panel_invalidations[0].dirty_bounds);

    const hidden_overflow_panel_invalidations = try WidgetLayoutTree.diff(visible_overflow_panel, hidden_overflow_panel, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 1), hidden_overflow_panel_invalidations.len);
    try std.testing.expectEqual(WidgetInvalidationKind.changed, hidden_overflow_panel_invalidations[0].kind);
    try std.testing.expectEqual(@as(ObjectId, 5), hidden_overflow_panel_invalidations[0].id);
    try std.testing.expect(hidden_overflow_panel_invalidations[0].paint_dirty);
    try expectRect(geometry.RectF.init(-2, 0, 192, 44), hidden_overflow_panel_invalidations[0].dirty_bounds);

    var unfocused_nodes: [2]WidgetLayoutNode = undefined;
    var focused_nodes: [2]WidgetLayoutNode = undefined;
    const unfocused = try layoutWidgetTree(.{ .kind = .stack, .children = &unfocused_child }, geometry.RectF.init(0, 0, 160, 120), &unfocused_nodes);
    const focused = try layoutWidgetTree(.{ .kind = .stack, .children = &focused_child }, geometry.RectF.init(0, 0, 160, 120), &focused_nodes);

    const focus_invalidations = try WidgetLayoutTree.diff(unfocused, focused, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 1), focus_invalidations.len);
    try std.testing.expectEqual(WidgetInvalidationKind.changed, focus_invalidations[0].kind);
    try std.testing.expectEqual(@as(ObjectId, 3), focus_invalidations[0].id);
    // The focus ring strokes 2px outside the control, so its dirty
    // bounds inflate by the offset plus half the 2px focus stroke.
    try expectRect(geometry.RectF.init(7, 67, 106, 36), focus_invalidations[0].dirty_bounds);
}

test "widget render state dirty bounds tracks changed runtime states" {
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(10, 12, 96, 32),
            .text = "Run",
        },
        .{
            .id = 3,
            .kind = .button,
            .frame = geometry.RectF.init(10, 56, 96, 32),
            .text = "Stop",
        },
        .{
            .id = 4,
            .kind = .text,
            .frame = geometry.RectF.init(10, 100, 96, 20),
            .text = "Label",
        },
    };
    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 160, 140), &nodes);

    try expectRect(
        geometry.RectF.init(7, 9, 102, 82),
        layout.renderStateDirtyBounds(
            .{ .focused_id = 2, .focus_visible_id = 2, .hovered_id = 2, .pressed_id = 2 },
            .{ .focused_id = 3, .focus_visible_id = 3, .hovered_id = 3 },
        ),
    );
    try std.testing.expect(layout.renderStateDirtyBounds(.{ .focused_id = 2 }, .{ .focused_id = 2 }) == null);
    try std.testing.expect(layout.renderStateDirtyBounds(.{ .focused_id = 99 }, .{ .focused_id = 100 }) == null);
}

test "widget render state dirty bounds uses custom focus stroke tokens" {
    const children = [_]Widget{.{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(10, 12, 96, 32),
        .text = "Run",
    }};
    const tokens = DesignTokens{
        .stroke = .{ .focus = 6 },
    };
    var nodes: [2]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 160, 80), &nodes);

    try expectRect(
        geometry.RectF.init(5, 7, 106, 42),
        layout.renderStateDirtyBoundsWithTokens(.{}, .{ .focused_id = 2, .focus_visible_id = 2 }, tokens),
    );
}

test "widget render state dirty bounds clips to scroll ancestors" {
    const children = [_]Widget{.{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(0, 50, 0, 32),
        .text = "Tail",
    }};
    var nodes: [2]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(
        .{ .id = 1, .kind = .scroll_view, .children = &children },
        geometry.RectF.init(0, 0, 120, 60),
        &nodes,
    );

    try expectRect(
        geometry.RectF.init(0, 50, 120, 10),
        layout.renderStateDirtyBounds(.{}, .{ .pressed_id = 2 }),
    );
}

test "widget layout diff separates paint and semantics dirtiness" {
    const previous_child = [_]Widget{.{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(10, 10, 100, 30),
        .text = "Run",
    }};
    const pressed_child = [_]Widget{.{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(10, 10, 100, 30),
        .text = "Run",
        .state = .{ .pressed = true },
    }};
    const semantic_child = [_]Widget{.{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(10, 10, 100, 30),
        .text = "Run",
        .semantics = .{ .label = "Run report" },
    }};
    const command_child = [_]Widget{.{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(10, 10, 100, 30),
        .text = "Run",
        .command = "report.run",
    }};
    const action_previous_child = [_]Widget{.{
        .id = 2,
        .kind = .text,
        .frame = geometry.RectF.init(10, 10, 100, 30),
        .text = "Report",
    }};
    const action_child = [_]Widget{.{
        .id = 2,
        .kind = .text,
        .frame = geometry.RectF.init(10, 10, 100, 30),
        .text = "Report",
        .semantics = .{ .actions = .{ .focus = true, .press = true } },
    }};
    const image_previous_child = [_]Widget{.{
        .id = 3,
        .kind = .image,
        .frame = geometry.RectF.init(8, 12, 80, 48),
        .image_id = 11,
    }};
    const image_next_child = [_]Widget{.{
        .id = 3,
        .kind = .image,
        .frame = geometry.RectF.init(8, 12, 80, 48),
        .image_id = 12,
        .image_src = geometry.RectF.init(0, 0, 640, 360),
        .image_fit = .contain,
        .image_sampling = .nearest,
        .image_opacity = 0.5,
    }};

    var previous_nodes: [2]WidgetLayoutNode = undefined;
    var pressed_nodes: [2]WidgetLayoutNode = undefined;
    var semantic_nodes: [2]WidgetLayoutNode = undefined;
    var command_nodes: [2]WidgetLayoutNode = undefined;
    var action_previous_nodes: [2]WidgetLayoutNode = undefined;
    var action_nodes: [2]WidgetLayoutNode = undefined;
    var image_previous_nodes: [2]WidgetLayoutNode = undefined;
    var image_next_nodes: [2]WidgetLayoutNode = undefined;
    const previous = try layoutWidgetTree(.{ .kind = .stack, .children = &previous_child }, geometry.RectF.init(0, 0, 140, 80), &previous_nodes);
    const pressed = try layoutWidgetTree(.{ .kind = .stack, .children = &pressed_child }, geometry.RectF.init(0, 0, 140, 80), &pressed_nodes);
    const semantic = try layoutWidgetTree(.{ .kind = .stack, .children = &semantic_child }, geometry.RectF.init(0, 0, 140, 80), &semantic_nodes);
    const command = try layoutWidgetTree(.{ .kind = .stack, .children = &command_child }, geometry.RectF.init(0, 0, 140, 80), &command_nodes);
    const action_previous = try layoutWidgetTree(.{ .kind = .stack, .children = &action_previous_child }, geometry.RectF.init(0, 0, 140, 80), &action_previous_nodes);
    const action = try layoutWidgetTree(.{ .kind = .stack, .children = &action_child }, geometry.RectF.init(0, 0, 140, 80), &action_nodes);
    const image_previous = try layoutWidgetTree(.{ .kind = .stack, .children = &image_previous_child }, geometry.RectF.init(0, 0, 140, 80), &image_previous_nodes);
    const image_next = try layoutWidgetTree(.{ .kind = .stack, .children = &image_next_child }, geometry.RectF.init(0, 0, 140, 80), &image_next_nodes);

    var invalidations_buffer: [2]WidgetInvalidation = undefined;
    const pressed_invalidations = try WidgetLayoutTree.diff(previous, pressed, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 1), pressed_invalidations.len);
    try std.testing.expect(!pressed_invalidations[0].layout_dirty);
    try std.testing.expect(pressed_invalidations[0].paint_dirty);
    try std.testing.expect(pressed_invalidations[0].semantics_dirty);
    try expectRect(geometry.RectF.init(10, 10, 100, 30), pressed_invalidations[0].dirty_bounds);

    const semantic_invalidations = try WidgetLayoutTree.diff(previous, semantic, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 1), semantic_invalidations.len);
    try std.testing.expect(!semantic_invalidations[0].layout_dirty);
    try std.testing.expect(!semantic_invalidations[0].paint_dirty);
    try std.testing.expect(semantic_invalidations[0].semantics_dirty);
    try std.testing.expect(semantic_invalidations[0].dirty_bounds == null);

    const command_invalidations = try WidgetLayoutTree.diff(previous, command, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 1), command_invalidations.len);
    try std.testing.expect(!command_invalidations[0].layout_dirty);
    try std.testing.expect(!command_invalidations[0].paint_dirty);
    try std.testing.expect(command_invalidations[0].semantics_dirty);
    try std.testing.expect(command_invalidations[0].dirty_bounds == null);

    const action_invalidations = try WidgetLayoutTree.diff(action_previous, action, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 1), action_invalidations.len);
    try std.testing.expect(!action_invalidations[0].layout_dirty);
    try std.testing.expect(!action_invalidations[0].paint_dirty);
    try std.testing.expect(action_invalidations[0].semantics_dirty);

    const image_invalidations = try WidgetLayoutTree.diff(image_previous, image_next, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 1), image_invalidations.len);
    try std.testing.expect(!image_invalidations[0].layout_dirty);
    try std.testing.expect(image_invalidations[0].paint_dirty);
    try std.testing.expect(image_invalidations[0].semantics_dirty);
    try expectRect(geometry.RectF.init(8, 12, 80, 48), image_invalidations[0].dirty_bounds);
}

test "widget layout diff marks style changes as paint dirty" {
    const previous_child = [_]Widget{.{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(10, 10, 100, 30),
        .text = "Run",
    }};
    const styled_child = [_]Widget{.{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(10, 10, 100, 30),
        .text = "Run",
        .style = .{
            .background = Color.rgb8(12, 18, 24),
            .foreground = Color.rgb8(235, 241, 247),
            .border = Color.rgb8(54, 64, 74),
            .radius = 5,
            .stroke_width = 2,
        },
    }};

    var previous_nodes: [2]WidgetLayoutNode = undefined;
    var styled_nodes: [2]WidgetLayoutNode = undefined;
    const previous = try layoutWidgetTree(.{ .kind = .stack, .children = &previous_child }, geometry.RectF.init(0, 0, 140, 80), &previous_nodes);
    const styled = try layoutWidgetTree(.{ .kind = .stack, .children = &styled_child }, geometry.RectF.init(0, 0, 140, 80), &styled_nodes);

    var invalidations_buffer: [1]WidgetInvalidation = undefined;
    const invalidations = try WidgetLayoutTree.diff(previous, styled, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 1), invalidations.len);
    try std.testing.expect(!invalidations[0].layout_dirty);
    try std.testing.expect(invalidations[0].paint_dirty);
    try std.testing.expect(!invalidations[0].semantics_dirty);
    try expectRect(geometry.RectF.init(9, 9, 102, 32), invalidations[0].dirty_bounds);
}

test "widget layout diff marks variant changes as paint dirty" {
    const previous_child = [_]Widget{.{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(10, 10, 100, 30),
        .text = "Run",
    }};
    const variant_child = [_]Widget{.{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(10, 10, 100, 30),
        .text = "Run",
        .variant = .primary,
    }};

    var previous_nodes: [2]WidgetLayoutNode = undefined;
    var variant_nodes: [2]WidgetLayoutNode = undefined;
    const previous = try layoutWidgetTree(.{ .kind = .stack, .children = &previous_child }, geometry.RectF.init(0, 0, 140, 80), &previous_nodes);
    const variant = try layoutWidgetTree(.{ .kind = .stack, .children = &variant_child }, geometry.RectF.init(0, 0, 140, 80), &variant_nodes);

    var invalidations_buffer: [1]WidgetInvalidation = undefined;
    const invalidations = try WidgetLayoutTree.diff(previous, variant, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 1), invalidations.len);
    try std.testing.expect(!invalidations[0].layout_dirty);
    try std.testing.expect(invalidations[0].paint_dirty);
    try std.testing.expect(!invalidations[0].semantics_dirty);
    try expectRect(geometry.RectF.init(10, 10, 100, 30), invalidations[0].dirty_bounds);
}

test "widget layout diff marks size changes as paint dirty" {
    const previous_child = [_]Widget{.{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(10, 10, 100, 30),
        .text = "Run",
    }};
    const sized_child = [_]Widget{.{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(10, 10, 100, 30),
        .text = "Run",
        .size = .lg,
    }};

    var previous_nodes: [2]WidgetLayoutNode = undefined;
    var sized_nodes: [2]WidgetLayoutNode = undefined;
    const previous = try layoutWidgetTree(.{ .kind = .stack, .children = &previous_child }, geometry.RectF.init(0, 0, 140, 80), &previous_nodes);
    const sized = try layoutWidgetTree(.{ .kind = .stack, .children = &sized_child }, geometry.RectF.init(0, 0, 140, 80), &sized_nodes);

    var invalidations_buffer: [1]WidgetInvalidation = undefined;
    const invalidations = try WidgetLayoutTree.diff(previous, sized, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 1), invalidations.len);
    try std.testing.expect(!invalidations[0].layout_dirty);
    try std.testing.expect(invalidations[0].paint_dirty);
    try std.testing.expect(!invalidations[0].semantics_dirty);
    try expectRect(geometry.RectF.init(10, 10, 100, 30), invalidations[0].dirty_bounds);
}

test "widget layout diff marks grid column changes as layout dirty" {
    const children = [_]Widget{
        .{ .id = 2, .kind = .text, .text = "One" },
        .{ .id = 3, .kind = .text, .text = "Two" },
    };
    const previous_grid = Widget{ .id = 1, .kind = .grid, .layout = .{ .columns = 2, .gap = 8 }, .children = &children };
    const next_grid = Widget{ .id = 1, .kind = .grid, .layout = .{ .columns = 1, .gap = 8 }, .children = &children };

    var previous_nodes: [3]WidgetLayoutNode = undefined;
    var next_nodes: [3]WidgetLayoutNode = undefined;
    const previous = try layoutWidgetTree(previous_grid, geometry.RectF.init(0, 0, 208, 88), &previous_nodes);
    const next = try layoutWidgetTree(next_grid, geometry.RectF.init(0, 0, 208, 88), &next_nodes);

    var invalidations_buffer: [3]WidgetInvalidation = undefined;
    const invalidations = try WidgetLayoutTree.diff(previous, next, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 3), invalidations.len);
    try std.testing.expectEqual(@as(ObjectId, 1), invalidations[0].id);
    try std.testing.expect(invalidations[0].layout_dirty);
    try std.testing.expect(invalidations[0].paint_dirty);
    try std.testing.expect(invalidations[0].semantics_dirty);
}

test "widget layout diff marks list spacing changes as layout dirty" {
    const children = [_]Widget{
        .{ .id = 2, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "One" },
        .{ .id = 3, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "Two" },
    };
    const previous_list = Widget{ .id = 1, .kind = .list, .layout = .{ .gap = 4 }, .children = &children };
    const next_list = Widget{ .id = 1, .kind = .list, .layout = .{ .gap = 8 }, .children = &children };

    var previous_nodes: [3]WidgetLayoutNode = undefined;
    var next_nodes: [3]WidgetLayoutNode = undefined;
    const previous = try layoutWidgetTree(previous_list, geometry.RectF.init(0, 0, 120, 80), &previous_nodes);
    const next = try layoutWidgetTree(next_list, geometry.RectF.init(0, 0, 120, 80), &next_nodes);

    var invalidations_buffer: [3]WidgetInvalidation = undefined;
    const invalidations = try WidgetLayoutTree.diff(previous, next, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 2), invalidations.len);
    try std.testing.expectEqual(@as(ObjectId, 1), invalidations[0].id);
    try std.testing.expect(invalidations[0].layout_dirty);
    try std.testing.expectEqual(@as(ObjectId, 3), invalidations[1].id);
    try std.testing.expect(invalidations[1].layout_dirty);
    try std.testing.expect(invalidations[1].paint_dirty);
}

test "widget layout diff marks axis alignment changes as layout dirty" {
    const children = [_]Widget{
        .{ .id = 2, .kind = .text, .frame = geometry.RectF.init(0, 0, 40, 12), .text = "A" },
        .{ .id = 3, .kind = .text, .frame = geometry.RectF.init(0, 0, 20, 16), .text = "B" },
    };
    const previous_row = Widget{
        .id = 1,
        .kind = .row,
        .layout = .{ .gap = 4 },
        .children = &children,
    };
    const next_row = Widget{
        .id = 1,
        .kind = .row,
        .layout = .{
            .gap = 4,
            .main_alignment = .end,
            .cross_alignment = .center,
        },
        .children = &children,
    };

    var previous_nodes: [3]WidgetLayoutNode = undefined;
    var next_nodes: [3]WidgetLayoutNode = undefined;
    const previous = try layoutWidgetTree(previous_row, geometry.RectF.init(0, 0, 120, 40), &previous_nodes);
    const next = try layoutWidgetTree(next_row, geometry.RectF.init(0, 0, 120, 40), &next_nodes);

    var invalidations_buffer: [3]WidgetInvalidation = undefined;
    const invalidations = try WidgetLayoutTree.diff(previous, next, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 3), invalidations.len);
    try std.testing.expectEqual(@as(ObjectId, 1), invalidations[0].id);
    try std.testing.expect(invalidations[0].layout_dirty);
    try std.testing.expectEqual(@as(ObjectId, 2), invalidations[1].id);
    try std.testing.expect(invalidations[1].layout_dirty);
    try std.testing.expectEqual(@as(ObjectId, 3), invalidations[2].id);
    try std.testing.expect(invalidations[2].layout_dirty);
}

test "widget layout diff marks text alignment changes as paint dirty" {
    const previous_text = Widget{
        .id = 1,
        .kind = .text,
        .frame = geometry.RectF.init(10, 12, 120, 24),
        .text = "Status",
    };
    const next_text = Widget{
        .id = 1,
        .kind = .text,
        .frame = geometry.RectF.init(10, 12, 120, 24),
        .text = "Status",
        .text_alignment = .end,
    };

    var previous_nodes: [1]WidgetLayoutNode = undefined;
    var next_nodes: [1]WidgetLayoutNode = undefined;
    const previous = try layoutWidgetTree(previous_text, previous_text.frame, &previous_nodes);
    const next = try layoutWidgetTree(next_text, next_text.frame, &next_nodes);

    var invalidations_buffer: [1]WidgetInvalidation = undefined;
    const invalidations = try WidgetLayoutTree.diff(previous, next, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 1), invalidations.len);
    try std.testing.expect(!invalidations[0].layout_dirty);
    try std.testing.expect(invalidations[0].paint_dirty);
    try std.testing.expect(!invalidations[0].semantics_dirty);
    try expectRect(geometry.RectF.init(10, 12, 120, 24), invalidations[0].dirty_bounds);
}

test "widget layout diff marks opacity changes as subtree paint dirty" {
    const children = [_]Widget{.{
        .id = 2,
        .kind = .text,
        .frame = geometry.RectF.init(20, 0, 30, 10),
        .text = "Fade",
    }};
    const previous_stack = Widget{
        .id = 1,
        .kind = .stack,
        .children = &children,
    };
    const next_stack = Widget{
        .id = 1,
        .kind = .stack,
        .opacity = 0.5,
        .children = &children,
    };

    var previous_nodes: [2]WidgetLayoutNode = undefined;
    var next_nodes: [2]WidgetLayoutNode = undefined;
    const previous = try layoutWidgetTree(previous_stack, geometry.RectF.init(0, 0, 10, 10), &previous_nodes);
    const next = try layoutWidgetTree(next_stack, geometry.RectF.init(0, 0, 10, 10), &next_nodes);

    var invalidations_buffer: [2]WidgetInvalidation = undefined;
    const invalidations = try WidgetLayoutTree.diff(previous, next, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 1), invalidations.len);
    try std.testing.expectEqual(@as(ObjectId, 1), invalidations[0].id);
    try std.testing.expect(!invalidations[0].layout_dirty);
    try std.testing.expect(invalidations[0].paint_dirty);
    try std.testing.expect(!invalidations[0].semantics_dirty);
    try expectRect(geometry.RectF.init(0, 0, 50, 10), invalidations[0].dirty_bounds);
}

test "widget layout diff marks transform changes as subtree paint dirty" {
    const children = [_]Widget{.{
        .id = 2,
        .kind = .text,
        .frame = geometry.RectF.init(20, 0, 30, 10),
        .text = "Move",
    }};
    const previous_stack = Widget{
        .id = 1,
        .kind = .stack,
        .children = &children,
    };
    const next_stack = Widget{
        .id = 1,
        .kind = .stack,
        .transform = Affine.translate(10, 0),
        .children = &children,
    };

    var previous_nodes: [2]WidgetLayoutNode = undefined;
    var next_nodes: [2]WidgetLayoutNode = undefined;
    const previous = try layoutWidgetTree(previous_stack, geometry.RectF.init(0, 0, 10, 10), &previous_nodes);
    const next = try layoutWidgetTree(next_stack, geometry.RectF.init(0, 0, 10, 10), &next_nodes);

    var invalidations_buffer: [2]WidgetInvalidation = undefined;
    const invalidations = try WidgetLayoutTree.diff(previous, next, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 1), invalidations.len);
    try std.testing.expectEqual(@as(ObjectId, 1), invalidations[0].id);
    try std.testing.expect(!invalidations[0].layout_dirty);
    try std.testing.expect(invalidations[0].paint_dirty);
    try std.testing.expect(!invalidations[0].semantics_dirty);
    try expectRect(geometry.RectF.init(0, 0, 60, 10), invalidations[0].dirty_bounds);
}

test "widget layout diff marks backdrop blur changes as paint dirty" {
    const previous_stack = Widget{
        .id = 1,
        .kind = .stack,
    };
    const next_stack = Widget{
        .id = 1,
        .kind = .stack,
        .backdrop_blur = 6,
    };

    var previous_nodes: [1]WidgetLayoutNode = undefined;
    var next_nodes: [1]WidgetLayoutNode = undefined;
    const previous = try layoutWidgetTree(previous_stack, geometry.RectF.init(10, 12, 80, 40), &previous_nodes);
    const next = try layoutWidgetTree(next_stack, geometry.RectF.init(10, 12, 80, 40), &next_nodes);

    var invalidations_buffer: [1]WidgetInvalidation = undefined;
    const invalidations = try WidgetLayoutTree.diff(previous, next, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 1), invalidations.len);
    try std.testing.expectEqual(@as(ObjectId, 1), invalidations[0].id);
    try std.testing.expect(!invalidations[0].layout_dirty);
    try std.testing.expect(invalidations[0].paint_dirty);
    try std.testing.expect(!invalidations[0].semantics_dirty);
    try expectRect(geometry.RectF.init(4, 6, 92, 52), invalidations[0].dirty_bounds);
}

test "widget layout diff marks backdrop blur token changes as paint dirty" {
    const previous_stack = Widget{
        .id = 1,
        .kind = .stack,
    };
    const next_stack = Widget{
        .id = 1,
        .kind = .stack,
        .backdrop_blur_token = .sm,
    };

    var previous_nodes: [1]WidgetLayoutNode = undefined;
    var next_nodes: [1]WidgetLayoutNode = undefined;
    const previous = try layoutWidgetTree(previous_stack, geometry.RectF.init(10, 12, 80, 40), &previous_nodes);
    const next = try layoutWidgetTree(next_stack, geometry.RectF.init(10, 12, 80, 40), &next_nodes);

    var invalidations_buffer: [1]WidgetInvalidation = undefined;
    const invalidations = try WidgetLayoutTree.diff(previous, next, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 1), invalidations.len);
    try std.testing.expectEqual(@as(ObjectId, 1), invalidations[0].id);
    try std.testing.expect(!invalidations[0].layout_dirty);
    try std.testing.expect(invalidations[0].paint_dirty);
    try std.testing.expect(!invalidations[0].semantics_dirty);
    try expectRect(geometry.RectF.init(2, 4, 96, 56), invalidations[0].dirty_bounds);
}

test "widget layout diff uses custom blur tokens for paint dirty bounds" {
    const previous_stack = Widget{
        .id = 1,
        .kind = .stack,
    };
    const next_stack = Widget{
        .id = 1,
        .kind = .stack,
        .backdrop_blur_token = .md,
    };
    const tokens = DesignTokens{
        .blur = .{
            .sm = 8,
            .md = 24,
        },
    };

    var previous_nodes: [1]WidgetLayoutNode = undefined;
    var next_nodes: [1]WidgetLayoutNode = undefined;
    const previous = try layoutWidgetTree(previous_stack, geometry.RectF.init(10, 12, 80, 40), &previous_nodes);
    const next = try layoutWidgetTree(next_stack, geometry.RectF.init(10, 12, 80, 40), &next_nodes);

    var invalidations_buffer: [1]WidgetInvalidation = undefined;
    const invalidations = try WidgetLayoutTree.diffWithTokens(previous, next, tokens, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 1), invalidations.len);
    try std.testing.expect(invalidations[0].paint_dirty);
    try expectRect(geometry.RectF.init(-14, -12, 128, 88), invalidations[0].dirty_bounds);
}

test "widget layout diff clips paint dirtiness to clip content ancestors" {
    const previous_children = [_]Widget{.{
        .id = 2,
        .kind = .text,
        .frame = geometry.RectF.init(40, 0, 40, 20),
        .text = "One",
    }};
    const next_children = [_]Widget{.{
        .id = 2,
        .kind = .text,
        .frame = geometry.RectF.init(40, 0, 40, 20),
        .text = "Two",
    }};
    const previous_stack = Widget{
        .id = 1,
        .kind = .stack,
        .layout = .{ .clip_content = true },
        .children = &previous_children,
    };
    const next_stack = Widget{
        .id = 1,
        .kind = .stack,
        .layout = .{ .clip_content = true },
        .children = &next_children,
    };

    var previous_nodes: [2]WidgetLayoutNode = undefined;
    var next_nodes: [2]WidgetLayoutNode = undefined;
    const previous = try layoutWidgetTree(previous_stack, geometry.RectF.init(0, 0, 50, 20), &previous_nodes);
    const next = try layoutWidgetTree(next_stack, geometry.RectF.init(0, 0, 50, 20), &next_nodes);

    var invalidations_buffer: [2]WidgetInvalidation = undefined;
    const invalidations = try WidgetLayoutTree.diff(previous, next, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 1), invalidations.len);
    try std.testing.expectEqual(@as(ObjectId, 2), invalidations[0].id);
    try std.testing.expect(invalidations[0].paint_dirty);
    try expectRect(geometry.RectF.init(40, 0, 10, 20), invalidations[0].dirty_bounds);
}

test "widget layout diff marks scroll offset changes as child layout dirty" {
    const children = [_]Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 0, 32), .text = "One" },
    };
    const previous_scroll = Widget{ .id = 1, .kind = .scroll_view, .value = 0, .children = &children };
    const next_scroll = Widget{ .id = 1, .kind = .scroll_view, .value = 12, .children = &children };

    var previous_nodes: [2]WidgetLayoutNode = undefined;
    var next_nodes: [2]WidgetLayoutNode = undefined;
    const previous = try layoutWidgetTree(previous_scroll, geometry.RectF.init(0, 0, 120, 60), &previous_nodes);
    const next = try layoutWidgetTree(next_scroll, geometry.RectF.init(0, 0, 120, 60), &next_nodes);

    var invalidations_buffer: [2]WidgetInvalidation = undefined;
    const invalidations = try WidgetLayoutTree.diff(previous, next, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 2), invalidations.len);
    try std.testing.expectEqual(@as(ObjectId, 1), invalidations[0].id);
    try std.testing.expect(invalidations[0].paint_dirty);
    try std.testing.expectEqual(@as(ObjectId, 2), invalidations[1].id);
    try std.testing.expect(invalidations[1].layout_dirty);
    try std.testing.expect(invalidations[1].paint_dirty);
}

test "widget layout diff clips paint dirtiness to scroll ancestors" {
    const previous_children = [_]Widget{.{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(0, 50, 0, 32),
        .text = "Tail",
    }};
    const pressed_children = [_]Widget{.{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(0, 50, 0, 32),
        .text = "Tail",
        .state = .{ .pressed = true },
    }};
    const previous_scroll = Widget{ .id = 1, .kind = .scroll_view, .children = &previous_children };
    const pressed_scroll = Widget{ .id = 1, .kind = .scroll_view, .children = &pressed_children };

    var previous_nodes: [2]WidgetLayoutNode = undefined;
    var pressed_nodes: [2]WidgetLayoutNode = undefined;
    const previous = try layoutWidgetTree(previous_scroll, geometry.RectF.init(0, 0, 120, 60), &previous_nodes);
    const pressed = try layoutWidgetTree(pressed_scroll, geometry.RectF.init(0, 0, 120, 60), &pressed_nodes);

    var invalidations_buffer: [2]WidgetInvalidation = undefined;
    const invalidations = try WidgetLayoutTree.diff(previous, pressed, &invalidations_buffer);
    try std.testing.expectEqual(@as(usize, 1), invalidations.len);
    try std.testing.expectEqual(WidgetInvalidationKind.changed, invalidations[0].kind);
    try std.testing.expectEqual(@as(ObjectId, 2), invalidations[0].id);
    try std.testing.expect(!invalidations[0].layout_dirty);
    try std.testing.expect(invalidations[0].paint_dirty);
    try expectRect(geometry.RectF.init(0, 50, 120, 10), invalidations[0].dirty_bounds);
}

test "widget layout diff reports duplicate ids and output overflow" {
    const duplicate_children = [_]Widget{
        .{ .id = 2, .kind = .text, .text = "One" },
        .{ .id = 2, .kind = .text, .text = "Two" },
    };
    const changed_children = [_]Widget{.{
        .id = 3,
        .kind = .text,
        .text = "Changed",
    }};

    var duplicate_nodes: [3]WidgetLayoutNode = undefined;
    var previous_nodes: [2]WidgetLayoutNode = undefined;
    var next_nodes: [2]WidgetLayoutNode = undefined;
    const duplicate = try layoutWidgetTree(.{ .kind = .stack, .children = &duplicate_children }, geometry.RectF.init(0, 0, 100, 100), &duplicate_nodes);
    const previous = try layoutWidgetTree(.{ .kind = .stack, .children = &.{.{ .id = 3, .kind = .text, .text = "Old" }} }, geometry.RectF.init(0, 0, 100, 100), &previous_nodes);
    const next = try layoutWidgetTree(.{ .kind = .stack, .children = &changed_children }, geometry.RectF.init(0, 0, 100, 100), &next_nodes);

    var invalidations_buffer: [1]WidgetInvalidation = undefined;
    try std.testing.expectError(error.DuplicateWidgetId, WidgetLayoutTree.diff(duplicate, next, &invalidations_buffer));

    var empty_invalidations: [0]WidgetInvalidation = .{};
    try std.testing.expectError(error.WidgetInvalidationListFull, WidgetLayoutTree.diff(previous, next, &empty_invalidations));
}

test "widget tree emits panel button text and progress commands" {
    const tokens: DesignTokens = .{};
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(16, 16, 120, 36),
            .text = "Launch",
        },
        .{
            .id = 3,
            .kind = .text,
            .frame = geometry.RectF.init(16, 64, 200, 20),
            .text = "Frames stay retained",
        },
        .{
            .id = 4,
            .kind = .progress,
            .frame = geometry.RectF.init(16, 96, 160, 8),
            .value = 0.25,
        },
    };
    const root = Widget{
        .id = 1,
        .kind = .panel,
        .frame = geometry.RectF.init(0, 0, 240, 128),
        .children = &children,
    };

    var commands: [12]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, root, tokens);

    const display_list = builder.displayList();
    // Panel shadow/fill/border, then the button's fill/border/label —
    // buttons are FLAT (no shadow command of their own; only elevated
    // surfaces cast).
    try std.testing.expectEqual(@as(usize, 9), display_list.commandCount());
    try std.testing.expectEqual(@as(?ObjectId, widgetPartId(1, 1)), display_list.commands[0].objectId());
    try std.testing.expect(display_list.commands[0] == .shadow);
    try std.testing.expectEqual(@as(?ObjectId, widgetPartId(1, 2)), display_list.commands[1].objectId());
    try std.testing.expect(display_list.commands[1] == .fill_rounded_rect);
    try std.testing.expectEqual(@as(?ObjectId, widgetPartId(2, 1)), display_list.commands[3].objectId());
    try std.testing.expect(display_list.commands[3] == .fill_rounded_rect);

    switch (display_list.commands[5]) {
        .draw_text => |text| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(2, 4)), text.id);
            try std.testing.expectEqualStrings("Launch", text.text);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[6]) {
        .draw_text => |text| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(3, 1)), text.id);
            try std.testing.expectEqualStrings("Frames stay retained", text.text);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[8]) {
        .fill_rounded_rect => |fill| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(4, 2)), fill.id);
            try expectRect(geometry.RectF.init(16, 96, 40, 8), fill.rect);
            try expectFillColor(tokens.colors.accent, fill.fill);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "widget tree emits backdrop blur before widget content" {
    const children = [_]Widget{.{
        .id = 2,
        .kind = .text,
        .frame = geometry.RectF.init(18, 24, 100, 18),
        .text = "Glass",
    }};
    const root = Widget{
        .id = 1,
        .kind = .stack,
        .frame = geometry.RectF.init(10, 12, 140, 72),
        .backdrop_blur = 8,
        .children = &children,
    };

    var commands: [2]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, root, .{});

    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 2), display_list.commandCount());
    switch (display_list.commands[0]) {
        .blur => |blur| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(1, 12)), blur.id);
            try expectRect(geometry.RectF.init(10, 12, 140, 72), blur.rect);
            try std.testing.expectEqual(@as(f32, 8), blur.radius);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[1]) {
        .draw_text => |text| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(2, 1)), text.id);
            try std.testing.expectEqualStrings("Glass", text.text);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "widget tree resolves backdrop blur tokens from design tokens" {
    const children = [_]Widget{.{
        .id = 2,
        .kind = .text,
        .frame = geometry.RectF.init(18, 24, 100, 18),
        .text = "Glass",
    }};
    const root = Widget{
        .id = 1,
        .kind = .stack,
        .frame = geometry.RectF.init(10, 12, 140, 72),
        .backdrop_blur_token = .md,
        .children = &children,
    };
    const tokens = DesignTokens{
        .blur = .{
            .sm = 6,
            .md = 18,
        },
    };

    var commands: [2]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, root, tokens);

    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 2), display_list.commandCount());
    switch (display_list.commands[0]) {
        .blur => |blur| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(1, 12)), blur.id);
            try expectRect(geometry.RectF.init(10, 12, 140, 72), blur.rect);
            try std.testing.expectEqual(@as(f32, 18), blur.radius);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "widget display list skips hidden subtrees" {
    const hidden_button = Widget{
        .id = 2,
        .kind = .button,
        .frame = geometry.RectF.init(10, 10, 100, 32),
        .text = "Hidden",
        .semantics = .{ .hidden = true },
    };
    var hidden_commands: [4]CanvasCommand = undefined;
    var hidden_builder = Builder.init(&hidden_commands);
    try emitWidgetTree(&hidden_builder, hidden_button, .{});
    try std.testing.expectEqual(@as(usize, 0), hidden_builder.displayList().commandCount());

    const hidden_scroll_children = [_]Widget{.{
        .id = 4,
        .kind = .button,
        .frame = geometry.RectF.init(0, 0, 0, 32),
        .text = "Nested",
    }};
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(16, 16, 120, 36),
            .text = "Visible",
        },
        .{
            .id = 3,
            .kind = .scroll_view,
            .frame = geometry.RectF.init(16, 64, 160, 48),
            .semantics = .{ .hidden = true },
            .children = &hidden_scroll_children,
        },
        .{
            .id = 5,
            .kind = .text,
            .frame = geometry.RectF.init(16, 124, 120, 20),
            .text = "Visible text",
        },
    };
    const root = Widget{
        .id = 1,
        .kind = .panel,
        .frame = geometry.RectF.init(0, 0, 220, 160),
        .children = &children,
    };

    var nodes: [5]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, root.frame, &nodes);

    var commands: [16]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, .{});

    const display_list = builder.displayList();
    var saw_visible_button = false;
    var saw_visible_text = false;
    for (display_list.commands) |command| {
        if (command.objectId()) |id| {
            if (id == widgetPartId(2, 1)) saw_visible_button = true;
            if (id == widgetPartId(5, 1)) saw_visible_text = true;
            if ((id > widgetPartId(3, 0) and id < widgetPartId(4, 0)) or
                (id > widgetPartId(4, 0) and id < widgetPartId(5, 0)))
            {
                return error.TestUnexpectedResult;
            }
        }
    }
    try std.testing.expect(saw_visible_button);
    try std.testing.expect(saw_visible_text);
}

test "widget display list renders through reference surface" {
    const tokens: DesignTokens = .{};
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(16, 16, 120, 36),
            .text = "Launch",
        },
        .{
            .id = 3,
            .kind = .text,
            .frame = geometry.RectF.init(16, 64, 200, 20),
            .text = "Frames stay retained",
        },
        .{
            .id = 4,
            .kind = .progress,
            .frame = geometry.RectF.init(16, 96, 160, 8),
            .value = 0.25,
        },
    };
    const root = Widget{
        .id = 1,
        .kind = .panel,
        .frame = geometry.RectF.init(0, 0, 240, 128),
        .children = &children,
    };

    var layout_nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, root.frame, &layout_nodes);

    var commands: [12]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, tokens);

    var render_commands: [12]RenderCommand = undefined;
    var render_batches: [12]RenderBatch = undefined;
    var resources: [8]RenderResource = undefined;
    var resource_cache_entries: [8]RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [8]RenderResourceCacheAction = undefined;
    var glyphs: [64]GlyphAtlasEntry = undefined;
    var glyph_cache_entries: [64]GlyphAtlasCacheEntry = undefined;
    var glyph_cache_actions: [64]GlyphAtlasCacheAction = undefined;
    var changes: [0]DiffChange = .{};
    const frame = try builder.displayList().framePlan(null, .{
        .surface_size = geometry.SizeF.init(240, 128),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .glyph_atlas_cache_entries = &glyph_cache_entries,
        .glyph_atlas_cache_actions = &glyph_cache_actions,
        .changes = &changes,
    });

    try std.testing.expect(frame.requiresRender());
    try std.testing.expectEqual(CanvasRenderPassLoadAction.clear, frame.renderPass().loadAction());
    // Panel shadow/fill/border + flat button fill/border/label + text +
    // progress track/fill: buttons cast no shadow of their own.
    try std.testing.expectEqual(@as(usize, 9), frame.renderPass().commandCount());

    var pixels: [240 * 128 * 4]u8 = undefined;
    const surface = try ReferenceRenderSurface.init(240, 128, &pixels);
    try surface.renderPass(frame.renderPass(), Color.rgb8(0, 0, 0));

    try expectPixelRgba8(.{ 255, 255, 255, 255 }, surface, 220, 20);
    // The progress fill is the monochrome near-black primary of the
    // house register.
    try expectPixelRgba8(.{ 23, 23, 23, 255 }, surface, 20, 100);
}

test "widget emitter applies button state tokens" {
    const tokens = DesignTokens{
        .colors = .{
            .accent = Color.rgb8(10, 20, 30),
            .accent_text = Color.rgb8(240, 241, 242),
            .focus_ring = Color.rgb8(1, 2, 3),
        },
        .stroke = .{ .focus = 3 },
    };
    const button = Widget{
        .id = 7,
        .kind = .button,
        .frame = geometry.RectF.init(0, 0, 140, 40),
        .text = "Pressed",
        .state = .{ .pressed = true, .focused = true },
    };

    var commands: [5]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, button, tokens);

    // Fill + border + focus ring + label — flat, no shadow command.
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 4), display_list.commandCount());
    switch (display_list.commands[0]) {
        .fill_rounded_rect => |fill| try expectFillColor(tokens.colors.accent, fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[2]) {
        .stroke_rect => |stroke| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(7, 3)), stroke.id);
            try std.testing.expectEqual(@as(f32, 3), stroke.stroke.width);
            try expectFillColor(tokens.colors.focus_ring, stroke.stroke.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[3]) {
        .draw_text => |text| try std.testing.expectEqualDeep(tokens.colors.accent_text, text.color),
        else => return error.TestUnexpectedResult,
    }
}

test "widget emitter applies button variants" {
    const tokens = DesignTokens{
        .colors = .{
            .surface = Color.rgb8(250, 250, 250),
            .surface_subtle = Color.rgb8(242, 244, 246),
            .border = Color.rgb8(200, 205, 210),
            .text = Color.rgb8(20, 24, 28),
            .accent = Color.rgb8(30, 80, 210),
            .accent_text = Color.rgb8(255, 255, 255),
            .destructive = Color.rgb8(210, 40, 40),
            .destructive_text = Color.rgb8(255, 255, 255),
        },
    };

    var commands: [18]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, .{ .id = 20, .kind = .button, .frame = geometry.RectF.init(0, 0, 120, 32), .text = "Primary", .variant = .primary }, tokens);
    try emitWidgetTree(&builder, .{ .id = 21, .kind = .button, .frame = geometry.RectF.init(0, 40, 120, 32), .text = "Secondary", .variant = .secondary }, tokens);
    try emitWidgetTree(&builder, .{ .id = 22, .kind = .button, .frame = geometry.RectF.init(0, 80, 120, 32), .text = "Outline", .variant = .outline }, tokens);
    try emitWidgetTree(&builder, .{ .id = 23, .kind = .button, .frame = geometry.RectF.init(0, 120, 120, 32), .text = "Ghost", .variant = .ghost }, tokens);
    try emitWidgetTree(&builder, .{ .id = 24, .kind = .button, .frame = geometry.RectF.init(0, 160, 120, 32), .text = "Delete", .variant = .destructive }, tokens);

    // Every variant is FLAT (no shadow command): 5 x (fill + border +
    // label). Destructive is the quiet red chip — the destructive hue
    // as a 10% wash under destructive-red text, borderless.
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 15), display_list.commandCount());
    switch (display_list.commands[0]) {
        .fill_rounded_rect => |fill| try expectFillColor(tokens.colors.accent, fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[1]) {
        .stroke_rect => |stroke| try expectFillColor(tokens.colors.accent, stroke.stroke.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[3]) {
        .fill_rounded_rect => |fill| try expectFillColor(tokens.colors.surface_subtle, fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[6]) {
        .fill_rounded_rect => |fill| try expectFillColor(transparentColor(), fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[9]) {
        .fill_rounded_rect => |fill| try expectFillColor(transparentColor(), fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[10]) {
        .stroke_rect => |stroke| try std.testing.expectEqual(@as(f32, 0), stroke.stroke.width),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[12]) {
        .fill_rounded_rect => |fill| try expectFillColor(colorWithAlpha(tokens.colors.destructive, 0.10), fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[13]) {
        .stroke_rect => |stroke| try std.testing.expectEqual(@as(f32, 0), stroke.stroke.width),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[14]) {
        .draw_text => |text| try std.testing.expectEqualDeep(tokens.colors.destructive, text.color),
        else => return error.TestUnexpectedResult,
    }
}

test "widget emitter applies button variant control tokens" {
    const tokens = DesignTokens{
        .controls = .{
            .button_primary = .{
                .background = Color.rgb8(12, 44, 88),
                .hover_background = Color.rgb8(14, 54, 108),
                .active_background = Color.rgb8(8, 32, 72),
                .foreground = Color.rgb8(244, 248, 255),
                .border = Color.rgb8(20, 70, 120),
            },
            .button_secondary = .{
                .background = Color.rgb8(230, 235, 240),
                .hover_background = Color.rgb8(210, 220, 230),
                .active_background = Color.rgb8(190, 205, 220),
                .foreground = Color.rgb8(10, 20, 30),
                .border = Color.rgb8(120, 140, 160),
            },
        },
    };

    var commands: [12]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, .{ .id = 30, .kind = .button, .frame = geometry.RectF.init(0, 0, 120, 32), .text = "Primary", .variant = .primary, .state = .{ .hovered = true } }, tokens);
    try emitWidgetTree(&builder, .{ .id = 31, .kind = .button, .frame = geometry.RectF.init(0, 40, 120, 32), .text = "Secondary", .variant = .secondary, .state = .{ .pressed = true } }, tokens);
    try emitWidgetTree(&builder, .{ .id = 32, .kind = .button, .frame = geometry.RectF.init(0, 80, 120, 32), .text = "Local", .variant = .primary, .style = .{ .accent = Color.rgb8(1, 2, 3), .accent_foreground = Color.rgb8(4, 5, 6), .border = Color.rgb8(7, 8, 9) } }, tokens);

    // Buttons are flat (no shadow command): 3 x (fill + border + label).
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 9), display_list.commandCount());
    switch (display_list.commands[0]) {
        .fill_rounded_rect => |fill| try expectFillColor(Color.rgb8(14, 54, 108), fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[1]) {
        .stroke_rect => |stroke| try expectFillColor(Color.rgb8(20, 70, 120), stroke.stroke.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[2]) {
        .draw_text => |text| try std.testing.expectEqualDeep(Color.rgb8(244, 248, 255), text.color),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[3]) {
        .fill_rounded_rect => |fill| try expectFillColor(Color.rgb8(190, 205, 220), fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[5]) {
        .draw_text => |text| try std.testing.expectEqualDeep(Color.rgb8(10, 20, 30), text.color),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[6]) {
        .fill_rounded_rect => |fill| try expectFillColor(Color.rgb8(1, 2, 3), fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[7]) {
        .stroke_rect => |stroke| try expectFillColor(Color.rgb8(7, 8, 9), stroke.stroke.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[8]) {
        .draw_text => |text| try std.testing.expectEqualDeep(Color.rgb8(4, 5, 6), text.color),
        else => return error.TestUnexpectedResult,
    }
}

test "widget emitter applies input and list control tokens" {
    const tokens = DesignTokens{
        .controls = .{
            .input = .{
                .background = Color.rgb8(20, 24, 28),
                .foreground = Color.rgb8(238, 242, 246),
                .border = Color.rgb8(80, 90, 100),
            },
            .search_field = .{
                .background = Color.rgb8(24, 28, 32),
                .foreground = Color.rgb8(210, 220, 230),
                .border = Color.rgb8(90, 100, 110),
            },
            .textarea = .{
                .background = Color.rgb8(28, 32, 36),
                .foreground = Color.rgb8(236, 240, 244),
                .border = Color.rgb8(96, 106, 116),
            },
            .list_item = .{
                .hover_background = Color.rgb8(40, 48, 56),
                .active_background = Color.rgb8(52, 62, 72),
                .foreground = Color.rgb8(244, 248, 252),
            },
        },
    };

    var commands: [24]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, .{ .id = 50, .kind = .input, .frame = geometry.RectF.init(0, 0, 160, 34), .text = "Input" }, tokens);
    try emitWidgetTree(&builder, .{ .id = 51, .kind = .search_field, .frame = geometry.RectF.init(0, 44, 180, 34), .semantics = .{ .label = "Search" } }, tokens);
    try emitWidgetTree(&builder, .{ .id = 52, .kind = .textarea, .frame = geometry.RectF.init(0, 88, 180, 72), .text = "Message" }, tokens);
    try emitWidgetTree(&builder, .{ .id = 53, .kind = .list_item, .frame = geometry.RectF.init(0, 168, 180, 30), .text = "Inbox", .state = .{ .selected = true } }, tokens);

    const display_list = builder.displayList();
    // The search field's magnifier is now the vector `search` icon:
    // transform in, circle + handle stroke paths, inverse transform out.
    try std.testing.expectEqual(@as(usize, 17), display_list.commandCount());
    switch (display_list.commands[0]) {
        .fill_rounded_rect => |fill| try expectFillColor(Color.rgb8(20, 24, 28), fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[1]) {
        .stroke_rect => |stroke| try expectFillColor(Color.rgb8(80, 90, 100), stroke.stroke.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[2]) {
        .draw_text => |text| try std.testing.expectEqualDeep(Color.rgb8(238, 242, 246), text.color),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[3]) {
        .fill_rounded_rect => |fill| try expectFillColor(Color.rgb8(24, 28, 32), fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[4]) {
        .stroke_rect => |stroke| try expectFillColor(Color.rgb8(90, 100, 110), stroke.stroke.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[6]) {
        .stroke_path => |stroke| try expectFillColor(Color.rgb8(210, 220, 230), stroke.stroke.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[9]) {
        .draw_text => |text| {
            try std.testing.expectEqualStrings("Search", text.text);
            try std.testing.expectEqualDeep(Color.rgb8(210, 220, 230), text.color);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[10]) {
        .fill_rounded_rect => |fill| try expectFillColor(Color.rgb8(28, 32, 36), fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[11]) {
        .stroke_rect => |stroke| try expectFillColor(Color.rgb8(96, 106, 116), stroke.stroke.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[12]) {
        .push_clip => {},
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[13]) {
        .draw_text => |text| try std.testing.expectEqualDeep(Color.rgb8(236, 240, 244), text.color),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(CanvasCommand.pop_clip, display_list.commands[14]);
    switch (display_list.commands[15]) {
        .fill_rounded_rect => |fill| try expectFillColor(Color.rgb8(52, 62, 72), fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[16]) {
        .draw_text => |text| try std.testing.expectEqualDeep(Color.rgb8(244, 248, 252), text.color),
        else => return error.TestUnexpectedResult,
    }
}

test "widget emitter applies data cell control tokens" {
    const tokens = DesignTokens{
        .controls = .{
            .list_item = .{
                .active_background = Color.rgb8(12, 18, 24),
                .foreground = Color.rgb8(200, 210, 220),
                .border = Color.rgb8(40, 50, 60),
            },
            .data_cell = .{
                .active_background = Color.rgb8(32, 42, 52),
                .foreground = Color.rgb8(236, 242, 248),
                .border = Color.rgb8(70, 82, 94),
                .stroke_width = 1.5,
            },
        },
    };

    var commands: [4]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, .{
        .id = 54,
        .kind = .data_cell,
        .frame = geometry.RectF.init(0, 0, 180, 30),
        .text = "Revenue",
        .state = .{ .selected = true },
    }, tokens);

    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 3), display_list.commandCount());
    switch (display_list.commands[0]) {
        .fill_rect => |fill| try expectFillColor(Color.rgb8(32, 42, 52), fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[1]) {
        .stroke_rect => |stroke| {
            try expectFillColor(Color.rgb8(70, 82, 94), stroke.stroke.fill);
            try std.testing.expectEqual(@as(f32, 1.5), stroke.stroke.width);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[2]) {
        .draw_text => |text| {
            try std.testing.expectEqualStrings("Revenue", text.text);
            try std.testing.expectEqualDeep(Color.rgb8(236, 242, 248), text.color);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "widget emitter applies menu item control tokens" {
    const tokens = DesignTokens{
        .controls = .{
            .list_item = .{
                .active_background = Color.rgb8(12, 18, 24),
                .foreground = Color.rgb8(200, 210, 220),
                .radius = 2,
            },
            .menu_item = .{
                .active_background = Color.rgb8(36, 44, 52),
                .foreground = Color.rgb8(240, 246, 252),
                .radius = 5,
            },
        },
    };

    // A PRESSED row takes the menu-item active background (attention
    // states drive the wash; commit does not — see below).
    var commands: [3]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, .{
        .id = 55,
        .kind = .menu_item,
        .frame = geometry.RectF.init(0, 0, 180, 30),
        .text = "Copy token",
        .state = .{ .pressed = true },
    }, tokens);

    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 2), display_list.commandCount());
    switch (display_list.commands[0]) {
        .fill_rounded_rect => |fill| {
            try std.testing.expectEqualDeep(Radius.all(5), fill.radius);
            try expectFillColor(Color.rgb8(36, 44, 52), fill.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[1]) {
        .draw_text => |text| {
            try std.testing.expectEqualStrings("Copy token", text.text);
            try std.testing.expectEqualDeep(Color.rgb8(240, 246, 252), text.color);
        },
        else => return error.TestUnexpectedResult,
    }

    // A COMMITTED row wears no wash at all: its marker is the trailing
    // checkmark, tinted with the same menu-item foreground token.
    var committed_commands: [5]CanvasCommand = undefined;
    var committed_builder = Builder.init(&committed_commands);
    try emitWidgetTree(&committed_builder, .{
        .id = 55,
        .kind = .menu_item,
        .frame = geometry.RectF.init(0, 0, 180, 30),
        .text = "Copy token",
        .state = .{ .selected = true },
    }, tokens);
    const committed_list = committed_builder.displayList();
    try std.testing.expectEqual(@as(usize, 4), committed_list.commandCount());
    switch (committed_list.commands[0]) {
        .draw_text => |text| try std.testing.expectEqualDeep(Color.rgb8(240, 246, 252), text.color),
        else => return error.TestUnexpectedResult,
    }
    switch (committed_list.commands[2]) {
        .stroke_path => |stroke| try expectFillColor(Color.rgb8(240, 246, 252), stroke.stroke.fill),
        else => return error.TestUnexpectedResult,
    }
}

test "widget emitter applies selection and range control tokens" {
    const tokens = DesignTokens{
        .controls = .{
            .segmented_control = .{
                .active_background = Color.rgb8(30, 50, 70),
                .foreground = Color.rgb8(245, 248, 252),
                .border = Color.rgb8(80, 96, 112),
            },
            .checkbox = .{
                .active_background = Color.rgb8(32, 64, 96),
                .foreground = Color.rgb8(250, 252, 255),
                .border = Color.rgb8(88, 104, 120),
            },
            .switch_control = .{
                .background = Color.rgb8(48, 54, 60),
                .active_background = Color.rgb8(34, 70, 108),
                .foreground = Color.rgb8(248, 250, 252),
                .border = Color.rgb8(84, 94, 104),
            },
            .slider = .{
                .background = Color.rgb8(50, 56, 64),
                .active_background = Color.rgb8(38, 76, 114),
                .foreground = Color.rgb8(246, 248, 250),
                .border = Color.rgb8(82, 92, 102),
            },
            .progress = .{
                .background = Color.rgb8(52, 58, 66),
                .active_background = Color.rgb8(40, 80, 120),
            },
        },
    };

    var commands: [18]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, .{ .id = 60, .kind = .segmented_control, .frame = geometry.RectF.init(0, 0, 120, 32), .text = "Open", .state = .{ .selected = true } }, tokens);
    try emitWidgetTree(&builder, .{ .id = 61, .kind = .checkbox, .frame = geometry.RectF.init(0, 40, 140, 32), .text = "Check", .state = .{ .selected = true } }, tokens);
    try emitWidgetTree(&builder, .{ .id = 62, .kind = .switch_control, .frame = geometry.RectF.init(0, 80, 140, 32), .text = "Live", .value = 1 }, tokens);
    try emitWidgetTree(&builder, .{ .id = 63, .kind = .slider, .frame = geometry.RectF.init(0, 124, 160, 32), .value = 0.25 }, tokens);
    try emitWidgetTree(&builder, .{ .id = 64, .kind = .progress, .frame = geometry.RectF.init(0, 172, 160, 8), .value = 0.5 }, tokens);

    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 17), display_list.commandCount());
    switch (display_list.commands[0]) {
        .fill_rounded_rect => |fill| try expectFillColor(Color.rgb8(30, 50, 70), fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[2]) {
        .draw_text => |text| try std.testing.expectEqualDeep(Color.rgb8(245, 248, 252), text.color),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[3]) {
        .fill_rounded_rect => |fill| try expectFillColor(Color.rgb8(32, 64, 96), fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[4]) {
        .stroke_rect => |stroke| try expectFillColor(Color.rgb8(88, 104, 120), stroke.stroke.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[5]) {
        .stroke_path => |stroke| try expectFillColor(Color.rgb8(250, 252, 255), stroke.stroke.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[7]) {
        .fill_rounded_rect => |fill| try expectFillColor(Color.rgb8(34, 70, 108), fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[9]) {
        .fill_rounded_rect => |fill| try expectFillColor(Color.rgb8(248, 250, 252), fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[11]) {
        .fill_rounded_rect => |fill| try expectFillColor(Color.rgb8(50, 56, 64), fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[12]) {
        .fill_rounded_rect => |fill| try expectFillColor(Color.rgb8(38, 76, 114), fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[13]) {
        .fill_rounded_rect => |fill| try expectFillColor(Color.rgb8(246, 248, 250), fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[15]) {
        .fill_rounded_rect => |fill| try expectFillColor(Color.rgb8(52, 58, 66), fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[16]) {
        .fill_rounded_rect => |fill| try expectFillColor(Color.rgb8(40, 80, 120), fill.fill),
        else => return error.TestUnexpectedResult,
    }
}

test "widget emitter applies radio control tokens" {
    const tokens = DesignTokens{
        .controls = .{
            .radio = .{
                .active_background = Color.rgb8(36, 72, 108),
                .foreground = Color.rgb8(248, 250, 252),
                .border = Color.rgb8(90, 106, 122),
            },
        },
    };

    var commands: [5]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, .{
        .id = 65,
        .kind = .radio,
        .frame = geometry.RectF.init(0, 0, 140, 32),
        .text = "Monthly",
        .state = .{ .selected = true },
    }, tokens);

    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 4), display_list.commandCount());
    switch (display_list.commands[1]) {
        .stroke_rect => |stroke| try expectFillColor(Color.rgb8(90, 106, 122), stroke.stroke.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[2]) {
        .fill_rounded_rect => |fill| try expectFillColor(Color.rgb8(36, 72, 108), fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[3]) {
        .draw_text => |text| try std.testing.expectEqualDeep(Color.rgb8(248, 250, 252), text.color),
        else => return error.TestUnexpectedResult,
    }
}

test "widget emitter applies surface control tokens" {
    const tokens = DesignTokens{
        .controls = .{
            .panel = .{
                .background = Color.rgb8(20, 24, 28),
                .border = Color.rgb8(80, 88, 96),
            },
            .popover = .{
                .hover_background = Color.rgb8(24, 30, 36),
                .border = Color.rgb8(90, 98, 106),
            },
            .menu_surface = .{
                .active_background = Color.rgb8(28, 36, 44),
                .border = Color.rgb8(100, 108, 116),
            },
            .tooltip = .{
                .background = Color.rgb8(240, 244, 248),
                .foreground = Color.rgb8(18, 24, 30),
            },
        },
    };

    var commands: [12]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, .{ .id = 70, .kind = .panel, .frame = geometry.RectF.init(0, 0, 160, 80) }, tokens);
    try emitWidgetTree(&builder, .{ .id = 71, .kind = .popover, .frame = geometry.RectF.init(0, 90, 160, 80), .state = .{ .hovered = true } }, tokens);
    try emitWidgetTree(&builder, .{ .id = 72, .kind = .menu_surface, .frame = geometry.RectF.init(0, 180, 160, 80), .state = .{ .selected = true } }, tokens);
    try emitWidgetTree(&builder, .{ .id = 73, .kind = .tooltip, .frame = geometry.RectF.init(0, 270, 120, 28), .text = "Hint" }, tokens);

    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 12), display_list.commandCount());
    switch (display_list.commands[1]) {
        .fill_rounded_rect => |fill| try expectFillColor(Color.rgb8(20, 24, 28), fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[2]) {
        .stroke_rect => |stroke| try expectFillColor(Color.rgb8(80, 88, 96), stroke.stroke.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[4]) {
        .fill_rounded_rect => |fill| try expectFillColor(Color.rgb8(24, 30, 36), fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[5]) {
        .stroke_rect => |stroke| try expectFillColor(Color.rgb8(90, 98, 106), stroke.stroke.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[7]) {
        .fill_rounded_rect => |fill| try expectFillColor(Color.rgb8(28, 36, 44), fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[8]) {
        .stroke_rect => |stroke| try expectFillColor(Color.rgb8(100, 108, 116), stroke.stroke.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[10]) {
        .fill_rounded_rect => |fill| try expectFillColor(Color.rgb8(240, 244, 248), fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[11]) {
        .draw_text => |text| try std.testing.expectEqualDeep(Color.rgb8(18, 24, 30), text.color),
        else => return error.TestUnexpectedResult,
    }
}

test "widget emitter applies control radius and stroke tokens" {
    const tokens = DesignTokens{
        .controls = .{
            .button_primary = .{
                .border = Color.rgb8(20, 70, 120),
                .radius = 10,
                .stroke_width = 3,
            },
            .text_field = .{
                .border = Color.rgb8(80, 90, 100),
                .radius = 4,
                .stroke_width = 2,
            },
            .checkbox = .{
                .border = Color.rgb8(88, 104, 120),
                .radius = 1,
                .stroke_width = 5,
            },
            .panel = .{
                .border = Color.rgb8(72, 82, 92),
                .radius = 14,
                .stroke_width = 2.5,
            },
        },
    };

    var commands: [12]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, .{ .id = 80, .kind = .button, .variant = .primary, .frame = geometry.RectF.init(0, 0, 120, 32), .text = "Save" }, tokens);
    try emitWidgetTree(&builder, .{ .id = 81, .kind = .text_field, .frame = geometry.RectF.init(0, 40, 160, 34), .text = "Name" }, tokens);
    try emitWidgetTree(&builder, .{ .id = 82, .kind = .checkbox, .frame = geometry.RectF.init(0, 86, 40, 24) }, tokens);
    try emitWidgetTree(&builder, .{ .id = 83, .kind = .panel, .frame = geometry.RectF.init(0, 120, 180, 90), .style = .{ .radius = 6, .stroke_width = 1 } }, tokens);

    // Buttons are flat, so the button's chrome sits at [0]/[1].
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 11), display_list.commandCount());
    switch (display_list.commands[0]) {
        .fill_rounded_rect => |fill| try std.testing.expectEqualDeep(Radius.all(10), fill.radius),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[1]) {
        .stroke_rect => |stroke| {
            try std.testing.expectEqualDeep(Radius.all(10), stroke.radius);
            try std.testing.expectEqual(@as(f32, 3), stroke.stroke.width);
            try expectFillColor(Color.rgb8(20, 70, 120), stroke.stroke.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[3]) {
        .fill_rounded_rect => |fill| try std.testing.expectEqualDeep(Radius.all(4), fill.radius),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[4]) {
        .stroke_rect => |stroke| {
            try std.testing.expectEqualDeep(Radius.all(4), stroke.radius);
            try std.testing.expectEqual(@as(f32, 2), stroke.stroke.width);
            try expectFillColor(Color.rgb8(80, 90, 100), stroke.stroke.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[6]) {
        .fill_rounded_rect => |fill| try std.testing.expectEqualDeep(Radius.all(1), fill.radius),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[7]) {
        .stroke_rect => |stroke| {
            try std.testing.expectEqualDeep(Radius.all(1), stroke.radius);
            try std.testing.expectEqual(@as(f32, 5), stroke.stroke.width);
            try expectFillColor(Color.rgb8(88, 104, 120), stroke.stroke.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[9]) {
        .fill_rounded_rect => |fill| try std.testing.expectEqualDeep(Radius.all(6), fill.radius),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[10]) {
        .stroke_rect => |stroke| {
            try std.testing.expectEqualDeep(Radius.all(6), stroke.radius);
            try std.testing.expectEqual(@as(f32, 1), stroke.stroke.width);
            try expectFillColor(Color.rgb8(72, 82, 92), stroke.stroke.fill);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "widget emitter applies control sizes" {
    const tokens = DesignTokens{};

    var commands: [13]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, .{ .id = 40, .kind = .button, .frame = geometry.RectF.init(0, 0, 120, 32), .text = "Small", .size = .sm }, tokens);
    try emitWidgetTree(&builder, .{ .id = 41, .kind = .button, .frame = geometry.RectF.init(0, 40, 120, 32), .text = "Large", .size = .lg }, tokens);
    try emitWidgetTree(&builder, .{ .id = 42, .kind = .text_field, .frame = geometry.RectF.init(0, 80, 120, 32), .text = "Input", .size = .sm }, tokens);
    try emitWidgetTree(&builder, .{ .id = 43, .kind = .checkbox, .frame = geometry.RectF.init(0, 120, 80, 20), .size = .lg }, tokens);

    // Buttons are flat (fill + border + label each). The corner steps
    // once at sm (8 vs the default/lg 10) and the label steps down to
    // 12.8 at sm; the 10px inset holds across the ladder.
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 11), display_list.commandCount());
    switch (display_list.commands[0]) {
        .fill_rounded_rect => |fill| try std.testing.expectEqualDeep(Radius.all(8), fill.radius),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[2]) {
        .draw_text => |text| {
            try std.testing.expectEqual(@as(f32, 12.8), text.size);
            try std.testing.expect(text.text_layout != null);
            // The shared 10px inset on each side of the 120 frame.
            try std.testing.expectApproxEqAbs(@as(f32, 100), text.text_layout.?.max_width, 0.001);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[3]) {
        .fill_rounded_rect => |fill| try std.testing.expectEqualDeep(Radius.all(10), fill.radius),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[5]) {
        .draw_text => |text| {
            try std.testing.expectEqual(@as(f32, 14), text.size);
            try std.testing.expect(text.text_layout != null);
            // lg keeps the same 10px inset — sizes step height and
            // radius, never the padding register.
            try std.testing.expectApproxEqAbs(@as(f32, 100), text.text_layout.?.max_width, 0.001);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[8]) {
        .draw_text => |text| {
            try std.testing.expectEqual(@as(f32, 13), text.size);
            try std.testing.expect(text.text_layout != null);
            try std.testing.expectApproxEqAbs(@as(f32, 100), text.text_layout.?.max_width, 0.001);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[9]) {
        .fill_rounded_rect => |fill| try std.testing.expectApproxEqAbs(@as(f32, 18), fill.rect.width, 0.001),
        else => return error.TestUnexpectedResult,
    }
}

test "widget emitter applies per-widget style overrides" {
    const base_style = WidgetStyle{
        .background = Color.rgb8(12, 18, 24),
        .foreground = Color.rgb8(235, 241, 247),
        .border = Color.rgb8(54, 64, 74),
        .focus_ring = Color.rgb8(90, 120, 255),
        .radius = 5,
        .stroke_width = 2,
    };
    const active_style = WidgetStyle{
        .accent = Color.rgb8(30, 80, 210),
        .accent_foreground = Color.rgb8(255, 255, 255),
        .border = Color.rgb8(30, 80, 210),
        .radius = 4,
    };

    var commands: [9]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, .{
        .id = 30,
        .kind = .button,
        .frame = geometry.RectF.init(0, 0, 128, 36),
        .text = "Brand",
        .state = .{ .focused = true },
        .style = base_style,
    }, .{});
    try emitWidgetTree(&builder, .{
        .id = 31,
        .kind = .button,
        .frame = geometry.RectF.init(0, 48, 128, 36),
        .text = "Active",
        .state = .{ .pressed = true },
        .style = active_style,
    }, .{});

    // Buttons are flat — styled chrome starts at [0].
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 7), display_list.commandCount());
    switch (display_list.commands[0]) {
        .fill_rounded_rect => |fill| {
            try expectFillColor(Color.rgb8(12, 18, 24), fill.fill);
            try std.testing.expectEqualDeep(Radius.all(5), fill.radius);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[1]) {
        .stroke_rect => |stroke| {
            try expectFillColor(Color.rgb8(54, 64, 74), stroke.stroke.fill);
            try std.testing.expectEqual(@as(f32, 2), stroke.stroke.width);
            try std.testing.expectEqualDeep(Radius.all(5), stroke.radius);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[2]) {
        .stroke_rect => |stroke| try expectFillColor(Color.rgb8(90, 120, 255), stroke.stroke.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[3]) {
        .draw_text => |text| try std.testing.expectEqualDeep(Color.rgb8(235, 241, 247), text.color),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[4]) {
        .fill_rounded_rect => |fill| {
            try expectFillColor(Color.rgb8(30, 80, 210), fill.fill);
            try std.testing.expectEqualDeep(Radius.all(4), fill.radius);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[6]) {
        .draw_text => |text| try std.testing.expectEqualDeep(Color.rgb8(255, 255, 255), text.color),
        else => return error.TestUnexpectedResult,
    }
}

test "widget emitter applies density tokens to spacing and affordances" {
    const button = Widget{
        .id = 1,
        .kind = .button,
        .frame = geometry.RectF.init(0, 0, 140, 40),
        .text = "Density",
    };

    // The label inset is the shared 10px register, density-scaled
    // (8.75/10/11.25); buttons are flat so the label lands at [2]
    // behind fill and border.
    var compact_button_commands: [5]CanvasCommand = undefined;
    var compact_button_builder = Builder.init(&compact_button_commands);
    try emitWidgetTree(&compact_button_builder, button, .{ .density = .compact });
    switch (compact_button_builder.displayList().commands[2]) {
        .draw_text => |text| {
            try std.testing.expectApproxEqAbs(@as(f32, 8.75), text.origin.x, 0.001);
            try std.testing.expect(text.text_layout != null);
            try std.testing.expectApproxEqAbs(@as(f32, 122.5), text.text_layout.?.max_width, 0.001);
            try std.testing.expectEqual(TextAlign.center, text.text_layout.?.alignment);
        },
        else => return error.TestUnexpectedResult,
    }

    var regular_button_commands: [5]CanvasCommand = undefined;
    var regular_button_builder = Builder.init(&regular_button_commands);
    try emitWidgetTree(&regular_button_builder, button, .{ .density = .regular });
    switch (regular_button_builder.displayList().commands[2]) {
        .draw_text => |text| {
            try std.testing.expectApproxEqAbs(@as(f32, 10), text.origin.x, 0.001);
            try std.testing.expect(text.text_layout != null);
            try std.testing.expectApproxEqAbs(@as(f32, 120), text.text_layout.?.max_width, 0.001);
            try std.testing.expectEqual(TextAlign.center, text.text_layout.?.alignment);
        },
        else => return error.TestUnexpectedResult,
    }

    var spacious_button_commands: [5]CanvasCommand = undefined;
    var spacious_button_builder = Builder.init(&spacious_button_commands);
    try emitWidgetTree(&spacious_button_builder, button, .{ .density = .spacious });
    switch (spacious_button_builder.displayList().commands[2]) {
        .draw_text => |text| {
            try std.testing.expectApproxEqAbs(@as(f32, 11.25), text.origin.x, 0.001);
            try std.testing.expect(text.text_layout != null);
            try std.testing.expectApproxEqAbs(@as(f32, 117.5), text.text_layout.?.max_width, 0.001);
            try std.testing.expectEqual(TextAlign.center, text.text_layout.?.alignment);
        },
        else => return error.TestUnexpectedResult,
    }

    const checkbox = Widget{
        .id = 2,
        .kind = .checkbox,
        .frame = geometry.RectF.init(0, 0, 80, 20),
    };

    var compact_checkbox_commands: [2]CanvasCommand = undefined;
    var compact_checkbox_builder = Builder.init(&compact_checkbox_commands);
    try emitWidgetTree(&compact_checkbox_builder, checkbox, .{ .density = .compact });
    switch (compact_checkbox_builder.displayList().commands[0]) {
        .fill_rounded_rect => |fill| try std.testing.expectApproxEqAbs(@as(f32, 14), fill.rect.width, 0.001),
        else => return error.TestUnexpectedResult,
    }

    var regular_checkbox_commands: [2]CanvasCommand = undefined;
    var regular_checkbox_builder = Builder.init(&regular_checkbox_commands);
    try emitWidgetTree(&regular_checkbox_builder, checkbox, .{ .density = .regular });
    switch (regular_checkbox_builder.displayList().commands[0]) {
        .fill_rounded_rect => |fill| try std.testing.expectApproxEqAbs(@as(f32, 16), fill.rect.width, 0.001),
        else => return error.TestUnexpectedResult,
    }

    var spacious_checkbox_commands: [2]CanvasCommand = undefined;
    var spacious_checkbox_builder = Builder.init(&spacious_checkbox_commands);
    try emitWidgetTree(&spacious_checkbox_builder, checkbox, .{ .density = .spacious });
    switch (spacious_checkbox_builder.displayList().commands[0]) {
        .fill_rounded_rect => |fill| try std.testing.expectApproxEqAbs(@as(f32, 18), fill.rect.width, 0.001),
        else => return error.TestUnexpectedResult,
    }
}

test "widget pixel snap tokens align widget chrome and text origins" {
    const tokens = DesignTokens{
        .pixel_snap = .{ .geometry = true, .text = true, .scale = 1 },
    };
    const button = Widget{
        .id = 42,
        .kind = .button,
        .frame = geometry.RectF.init(0.26, 0.51, 100.4, 32.4),
        .text = "Snap",
    };

    var commands: [4]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, button, tokens);

    // Fill + border + label — buttons are flat.
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 3), display_list.commandCount());
    switch (display_list.commands[0]) {
        .fill_rounded_rect => |fill| try expectRect(geometry.RectF.init(0, 1, 101, 32), fill.rect),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[2]) {
        .draw_text => |text| {
            try std.testing.expectEqual(@round(text.origin.x), text.origin.x);
            try std.testing.expectEqual(@round(text.origin.y), text.origin.y);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "widget layout emission can render runtime focus state" {
    const tokens = DesignTokens{
        .colors = .{
            .accent = Color.rgb8(10, 20, 30),
            .focus_ring = Color.rgb8(1, 2, 3),
        },
        .stroke = .{ .focus = 3 },
    };
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .button,
            .frame = geometry.RectF.init(0, 0, 100, 32),
            .text = "Run",
        },
        .{
            .id = 3,
            .kind = .button,
            .frame = geometry.RectF.init(0, 40, 100, 32),
            .text = "Stop",
            .state = .{ .hovered = true, .pressed = true, .focused = true },
        },
    };

    var nodes: [3]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 140, 100), &nodes);

    var commands: [10]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayListWithState(&builder, tokens, .{ .focused_id = 2, .focus_visible_id = 2, .hovered_id = 2, .pressed_id = 2 });

    // Flat buttons: 4 commands for the focused/pressed one (fill,
    // border, focus ring, label), 3 for the resting one.
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 7), display_list.commandCount());
    switch (display_list.commands[0]) {
        .fill_rounded_rect => |fill| try expectFillColor(tokens.colors.accent, fill.fill),
        else => return error.TestUnexpectedResult,
    }
    var saw_runtime_focus = false;
    var saw_stale_focus = false;
    for (display_list.commands) |command| {
        if (command.objectId()) |id| {
            if (id == widgetPartId(2, 3)) saw_runtime_focus = true;
            if (id == widgetPartId(3, 3)) saw_stale_focus = true;
        }
    }
    try std.testing.expect(saw_runtime_focus);
    try std.testing.expect(!saw_stale_focus);
}

test "input-group wears the focus ring for its focused descendant" {
    const tokens = DesignTokens{};
    const group_children = [_]Widget{
        .{
            .id = 3,
            .kind = .textarea,
            .layout = .{ .grow = 1 },
            // The dissolved entry chrome `Ui.inputGroup` stamps.
            .style = .{
                .background = Color.rgba8(0, 0, 0, 0),
                .border = Color.rgba8(0, 0, 0, 0),
                .focus_ring = Color.rgba8(0, 0, 0, 0),
            },
        },
        .{ .id = 4, .kind = .row, .frame = geometry.RectF.init(0, 0, 0, 32) },
    };
    const children = [_]Widget{.{
        .id = 2,
        .kind = .input_group,
        .frame = geometry.RectF.init(0, 0, 200, 112),
        .children = &group_children,
    }};

    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 240, 140), &nodes);

    // Focus on the inner textarea: the GROUP's ring (part slot 3 on id 2)
    // is emitted — focus-within, not the group's own focus.
    var focused_commands: [24]CanvasCommand = undefined;
    var focused_builder = Builder.init(&focused_commands);
    try layout.emitDisplayListWithState(&focused_builder, tokens, .{ .focused_id = 3, .focus_visible_id = 3 });
    var saw_group_ring = false;
    for (focused_builder.displayList().commands) |command| {
        if (command.objectId()) |id| {
            if (id == widgetPartId(2, 3)) saw_group_ring = true;
        }
    }
    try std.testing.expect(saw_group_ring);

    // No focus anywhere: no ring.
    var idle_commands: [24]CanvasCommand = undefined;
    var idle_builder = Builder.init(&idle_commands);
    try layout.emitDisplayListWithState(&idle_builder, tokens, .{});
    for (idle_builder.displayList().commands) |command| {
        if (command.objectId()) |id| {
            try std.testing.expect(id != widgetPartId(2, 3));
        }
    }

    // Focus somewhere OUTSIDE the group's subtree: still no ring.
    var outside_commands: [24]CanvasCommand = undefined;
    var outside_builder = Builder.init(&outside_commands);
    try layout.emitDisplayListWithState(&outside_builder, tokens, .{ .focused_id = 99, .focus_visible_id = 99 });
    for (outside_builder.displayList().commands) |command| {
        if (command.objectId()) |id| {
            try std.testing.expect(id != widgetPartId(2, 3));
        }
    }
}

test "input-group focus change dirties the group's ring region" {
    const tokens = DesignTokens{};
    const group_children = [_]Widget{
        .{ .id = 3, .kind = .textarea, .layout = .{ .grow = 1 } },
    };
    const children = [_]Widget{.{
        .id = 2,
        .kind = .input_group,
        .frame = geometry.RectF.init(20, 20, 200, 112),
        .children = &group_children,
    }};

    var nodes: [3]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 260, 160), &nodes);

    // Focus arriving on the inner textarea must dirty the GROUP's
    // focus-ring region (frame + ring offset + stroke), not just the
    // textarea's own bounds — the group wears the ring on its behalf.
    const dirty = layout.renderStateDirtyBoundsWithTokens(.{}, .{ .focused_id = 3, .focus_visible_id = 3 }, tokens).?;
    const ring = drawing_model.strokeBounds(widget_render_style.focusRingRect(geometry.RectF.init(20, 20, 200, 112), tokens), tokens.stroke.focus);
    try std.testing.expect(dirty.x <= ring.x);
    try std.testing.expect(dirty.y <= ring.y);
    try std.testing.expect(dirty.maxX() >= ring.maxX());
    try std.testing.expect(dirty.maxY() >= ring.maxY());
}

test "widget layer tokens order display emission and hit testing" {
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .popover,
            .frame = geometry.RectF.init(8, 8, 96, 64),
        },
        .{
            .id = 3,
            .kind = .button,
            .frame = geometry.RectF.init(12, 12, 80, 32),
            .text = "Base",
        },
    };

    var nodes: [3]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 120, 90), &nodes);

    var commands: [8]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, .{});
    // The button contributes 3 flat commands (fill, border, label),
    // the popover 3 (its own shadow, fill, border).
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 6), display_list.commandCount());
    try std.testing.expectEqual(@as(?ObjectId, widgetPartId(3, 1)), display_list.commands[0].objectId());
    try std.testing.expectEqual(@as(?ObjectId, widgetPartId(2, 1)), display_list.commands[3].objectId());
    try std.testing.expectEqual(@as(ObjectId, 2), layout.hitTest(geometry.PointF.init(20, 20)).?.id);

    const lowered_overlay = DesignTokens{
        .layer = .{
            .base = 10,
            .floating = 20,
            .overlay = 0,
            .modal = 30,
        },
    };
    var lowered_commands: [8]CanvasCommand = undefined;
    var lowered_builder = Builder.init(&lowered_commands);
    try layout.emitDisplayList(&lowered_builder, lowered_overlay);
    const lowered_display_list = lowered_builder.displayList();
    try std.testing.expectEqual(@as(?ObjectId, widgetPartId(2, 1)), lowered_display_list.commands[0].objectId());
    try std.testing.expectEqual(@as(?ObjectId, widgetPartId(3, 1)), lowered_display_list.commands[3].objectId());
    try std.testing.expectEqual(@as(ObjectId, 3), layout.hitTestWithTokens(geometry.PointF.init(20, 20), lowered_overlay).?.id);
}

test "widget explicit layers override token defaults for overlay ordering" {
    const children = [_]Widget{
        .{
            .id = 2,
            .kind = .popover,
            .frame = geometry.RectF.init(8, 8, 96, 64),
        },
        .{
            .id = 3,
            .kind = .button,
            .frame = geometry.RectF.init(12, 12, 80, 32),
            .text = "Top",
            .layer = 500,
        },
    };

    var nodes: [3]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 120, 90), &nodes);

    var commands: [8]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, .{});
    // The popover's 3 chrome commands paint first; the elevated flat
    // button's fill follows directly.
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(?ObjectId, widgetPartId(2, 1)), display_list.commands[0].objectId());
    try std.testing.expectEqual(@as(?ObjectId, widgetPartId(3, 1)), display_list.commands[3].objectId());
    try std.testing.expectEqual(@as(ObjectId, 3), layout.hitTest(geometry.PointF.init(20, 20)).?.id);
}

test "widget emitter renders checkbox radio switch and slider controls" {
    const tokens = DesignTokens{
        .colors = .{
            .accent = Color.rgb8(10, 20, 30),
            .accent_text = Color.rgb8(240, 241, 242),
            .focus_ring = Color.rgb8(1, 2, 3),
        },
        .stroke = .{ .focus = 3 },
    };
    var commands: [20]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, .{
        .id = 10,
        .kind = .checkbox,
        .frame = geometry.RectF.init(0, 0, 120, 32),
        .text = "Live",
        .state = .{ .selected = true, .focused = true },
    }, tokens);
    try emitWidgetTree(&builder, .{
        .id = 11,
        .kind = .radio,
        .frame = geometry.RectF.init(0, 40, 120, 32),
        .text = "Monthly",
        .state = .{ .selected = true, .focused = true },
    }, tokens);
    try emitWidgetTree(&builder, .{
        .id = 12,
        .kind = .switch_control,
        .frame = geometry.RectF.init(0, 80, 120, 32),
        .text = "Mode",
        .value = 1,
    }, tokens);
    try emitWidgetTree(&builder, .{
        .id = 13,
        .kind = .slider,
        .frame = geometry.RectF.init(0, 124, 160, 32),
        .value = 0.25,
        .state = .{ .focused = true },
    }, tokens);

    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 18), display_list.commandCount());
    switch (display_list.commands[0]) {
        .fill_rounded_rect => |fill| try expectFillColor(tokens.colors.accent, fill.fill),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(display_list.commands[3] == .stroke_path);
    switch (display_list.commands[4]) {
        .draw_text => |text| try std.testing.expectEqualStrings("Live", text.text),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[5]) {
        .fill_rounded_rect => |fill| try expectFillColor(tokens.colors.surface, fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[8]) {
        .fill_rounded_rect => |fill| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(11, 4)), fill.id);
            try expectFillColor(tokens.colors.accent, fill.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[9]) {
        .draw_text => |text| try std.testing.expectEqualStrings("Monthly", text.text),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[10]) {
        .fill_rounded_rect => |fill| try expectFillColor(tokens.colors.accent, fill.fill),
        else => return error.TestUnexpectedResult,
    }
    // The switch track is borderless now, so the toggle's label follows
    // its fill and knob directly.
    switch (display_list.commands[12]) {
        .draw_text => |text| try std.testing.expectEqualStrings("Mode", text.text),
        else => return error.TestUnexpectedResult,
    }
    // 4px slider rail centered in the 32px row: y = 124 + 14.
    switch (display_list.commands[14]) {
        .fill_rounded_rect => |fill| try expectRect(geometry.RectF.init(0, 138, 40, 4), fill.rect),
        else => return error.TestUnexpectedResult,
    }
    // The knob's resting hairline wears the focus-ring neutral; focus
    // adds the offset ring in the same color outside it.
    switch (display_list.commands[16]) {
        .stroke_rect => |stroke| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(13, 4)), stroke.id);
            try expectFillColor(tokens.colors.focus_ring, stroke.stroke.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[17]) {
        .stroke_rect => |stroke| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(13, 5)), stroke.id);
            try std.testing.expectEqual(@as(f32, 3), stroke.stroke.width);
            try expectFillColor(tokens.colors.focus_ring, stroke.stroke.fill);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "checkbox radio and switch focus rings stay on the control glyph" {
    const tokens = DesignTokens{
        .colors = .{ .focus_ring = Color.rgb8(1, 2, 3) },
        .stroke = .{ .focus = 3 },
    };

    var checkbox_commands: [8]CanvasCommand = undefined;
    var checkbox_builder = Builder.init(&checkbox_commands);
    try emitWidgetTree(&checkbox_builder, .{
        .id = 20,
        .kind = .checkbox,
        .frame = geometry.RectF.init(10, 10, 160, 32),
        .text = "Live",
        .state = .{ .focused = true },
    }, tokens);
    const checkbox_display_list = checkbox_builder.displayList();
    const checkbox_box = checkbox_display_list.findCommandById(widgetPartId(20, 2)).?.command;
    const checkbox_focus = checkbox_display_list.findCommandById(widgetPartId(20, 3)).?.command;
    switch (checkbox_box) {
        .stroke_rect => |box| switch (checkbox_focus) {
            .stroke_rect => |focus| {
                // The ring wraps the box 2px outside it — still glyph-
                // sized, nowhere near the clickable label's row width.
                try std.testing.expectEqualDeep(widget_render_style.focusRingRect(box.rect, tokens), focus.rect);
                try std.testing.expect(focus.rect.width < 32);
                try std.testing.expect(focus.rect.width < 160);
                try expectFillColor(tokens.colors.focus_ring, focus.stroke.fill);
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }

    var radio_commands: [8]CanvasCommand = undefined;
    var radio_builder = Builder.init(&radio_commands);
    try emitWidgetTree(&radio_builder, .{
        .id = 21,
        .kind = .radio,
        .frame = geometry.RectF.init(10, 52, 160, 32),
        .text = "Monthly",
        .state = .{ .focused = true },
    }, tokens);
    const radio_display_list = radio_builder.displayList();
    const radio_circle = radio_display_list.findCommandById(widgetPartId(21, 2)).?.command;
    const radio_focus = radio_display_list.findCommandById(widgetPartId(21, 3)).?.command;
    switch (radio_circle) {
        .stroke_rect => |circle| switch (radio_focus) {
            .stroke_rect => |focus| {
                try std.testing.expectEqualDeep(widget_render_style.focusRingRect(circle.rect, tokens), focus.rect);
                try std.testing.expect(focus.rect.width < 32);
                try std.testing.expect(focus.rect.width < 160);
                try expectFillColor(tokens.colors.focus_ring, focus.stroke.fill);
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }

    var switch_commands: [8]CanvasCommand = undefined;
    var switch_builder = Builder.init(&switch_commands);
    try emitWidgetTree(&switch_builder, .{
        .id = 22,
        .kind = .switch_control,
        .frame = geometry.RectF.init(10, 94, 160, 32),
        .text = "Alerts",
        .state = .{ .focused = true },
    }, tokens);
    const switch_display_list = switch_builder.displayList();
    // The borderless track's fill (slot 1) anchors the ring geometry.
    const switch_track = switch_display_list.findCommandById(widgetPartId(22, 1)).?.command;
    const switch_focus = switch_display_list.findCommandById(widgetPartId(22, 4)).?.command;
    switch (switch_track) {
        .fill_rounded_rect => |track| switch (switch_focus) {
            .stroke_rect => |focus| {
                try std.testing.expectEqualDeep(widget_render_style.focusRingRect(track.rect, tokens), focus.rect);
                try std.testing.expect(focus.rect.width < 80);
                try std.testing.expect(focus.rect.width < 160);
                try expectFillColor(tokens.colors.focus_ring, focus.stroke.fill);
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "selection control focus bounds exclude clickable labels" {
    const tokens = DesignTokens{
        .stroke = .{ .focus = 4 },
    };
    const children = [_]Widget{
        .{
            .id = 20,
            .kind = .checkbox,
            .frame = geometry.RectF.init(10, 10, 160, 32),
            .text = "Selected",
        },
        .{
            .id = 21,
            .kind = .switch_control,
            .frame = geometry.RectF.init(10, 52, 160, 32),
            .text = "Live",
        },
    };

    var nodes: [3]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 220, 100), &nodes);

    const checkbox_label_hit = layout.hitTest(geometry.PointF.init(80, 26)).?;
    try std.testing.expectEqual(@as(ObjectId, 20), checkbox_label_hit.id);
    try std.testing.expectEqual(WidgetKind.checkbox, checkbox_label_hit.kind);

    const switch_label_hit = layout.hitTest(geometry.PointF.init(100, 68)).?;
    try std.testing.expectEqual(@as(ObjectId, 21), switch_label_hit.id);
    try std.testing.expectEqual(WidgetKind.switch_control, switch_label_hit.kind);

    // Dirty bounds cover the offset ring: control glyph + 2px ring
    // offset + half the 4px focus stroke on every side.
    try expectRectApprox(
        geometry.RectF.init(6, 13.2, 25.6, 25.6),
        layout.renderStateDirtyBoundsWithTokens(.{}, .{ .focused_id = 20, .focus_visible_id = 20 }, tokens),
    );
    try expectRect(
        geometry.RectF.init(6, 52, 64, 32),
        layout.renderStateDirtyBoundsWithTokens(.{}, .{ .focused_id = 21, .focus_visible_id = 21 }, tokens),
    );
}

test "hover target resolves composite row children to the row" {
    // A two-line list row: title text, then a snippet line inside a
    // nested row with a link — the shape the notes/feed list panes
    // render. Probe points derive from the LAID-OUT frames so the test
    // pins behavior, not layout arithmetic.
    const snippet = Widget{ .id = 6, .kind = .text, .frame = geometry.RectF.init(0, 0, 140, 20), .text = "Snippet line" };
    const link = Widget{ .id = 7, .kind = .text, .frame = geometry.RectF.init(0, 0, 50, 20), .text = "More", .semantics = .{ .role = .link } };
    const inner_row = Widget{ .id = 5, .kind = .row, .frame = geometry.RectF.init(0, 0, 0, 20), .layout = .{ .gap = 8 }, .children = &.{ snippet, link } };
    const title = Widget{ .id = 4, .kind = .text, .frame = geometry.RectF.init(0, 0, 120, 20), .text = "Title" };
    const column = Widget{ .id = 3, .kind = .column, .layout = .{ .gap = 8 }, .children = &.{ title, inner_row } };
    const row = Widget{ .id = 2, .kind = .list_item, .frame = geometry.RectF.init(0, 0, 0, 72), .layout = .{ .padding = geometry.InsetsF.all(10) }, .children = &.{column} };
    const caption = Widget{ .id = 8, .kind = .text, .frame = geometry.RectF.init(0, 90, 120, 20), .text = "Bare caption" };

    var nodes: [8]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(.{ .kind = .stack, .children = &.{ row, caption } }, geometry.RectF.init(0, 0, 320, 130), &nodes);

    const row_frame = layout.findById(2).?.frame.normalized();
    const title_frame = layout.findById(4).?.frame.normalized();
    const snippet_frame = layout.findById(6).?.frame.normalized();
    const link_frame = layout.findById(7).?.frame.normalized();

    // The raw hit over the title line is the text child; hover resolves
    // to the row, so the wash covers the whole row. The cursor stays the
    // native arrow — rows are controls, and the hand belongs to links.
    const title_hit = layout.hitTest(title_frame.center()).?;
    try std.testing.expectEqual(@as(ObjectId, 4), title_hit.id);
    const title_hover = layout.hoverTargetForHit(title_hit).?;
    try std.testing.expectEqual(@as(ObjectId, 2), title_hover.id);
    try std.testing.expectEqual(WidgetKind.list_item, title_hover.kind);
    try std.testing.expectEqual(WidgetCursor.arrow, layout.cursorForHit(title_hover));

    // The snippet line, the gap between the lines, and the row's own
    // padding corner all belong to the row too.
    const snippet_hover = layout.hoverTargetForHit(layout.hitTest(snippet_frame.center())).?;
    try std.testing.expectEqual(@as(ObjectId, 2), snippet_hover.id);
    const gap_point = geometry.PointF.init(title_frame.center().x, (title_frame.maxY() + snippet_frame.y) / 2);
    const gap_hover = layout.hoverTargetForHit(layout.hitTest(gap_point)).?;
    try std.testing.expectEqual(@as(ObjectId, 2), gap_hover.id);
    const corner_point = geometry.PointF.init(row_frame.x + 3, row_frame.y + 3);
    const corner_hover = layout.hoverTargetForHit(layout.hitTest(corner_point)).?;
    try std.testing.expectEqual(@as(ObjectId, 2), corner_hover.id);

    // A link keeps its own hover: the pointer cursor is the link's
    // affordance even inside a pressable row.
    const link_hover = layout.hoverTargetForHit(layout.hitTest(link_frame.center())).?;
    try std.testing.expectEqual(@as(ObjectId, 7), link_hover.id);
    try std.testing.expectEqual(WidgetCursor.pointing_hand, layout.cursorForHit(link_hover));

    // Bare text with no claiming ancestor keeps itself (selection
    // affordance), and stays on the default cursor.
    const caption_frame = layout.findById(8).?.frame.normalized();
    const caption_hover = layout.hoverTargetForHit(layout.hitTest(caption_frame.center())).?;
    try std.testing.expectEqual(@as(ObjectId, 8), caption_hover.id);
    try std.testing.expectEqual(WidgetCursor.arrow, layout.cursorForHit(caption_hover));
}

test "widget emitter renders list item and segmented control states" {
    const tokens = DesignTokens{
        .colors = .{
            .accent = Color.rgb8(10, 20, 30),
            .accent_text = Color.rgb8(240, 241, 242),
            .focus_ring = Color.rgb8(1, 2, 3),
            .surface_pressed = Color.rgb8(220, 224, 230),
        },
        .stroke = .{ .focus = 3 },
    };
    var commands: [7]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, .{
        .id = 20,
        .kind = .list_item,
        .frame = geometry.RectF.init(0, 0, 160, 32),
        .text = "Inbox",
        .state = .{ .selected = true, .focused = true },
    }, tokens);
    try emitWidgetTree(&builder, .{
        .id = 21,
        .kind = .segmented_control,
        .frame = geometry.RectF.init(0, 40, 96, 32),
        .text = "Open",
        .state = .{ .selected = true, .focused = true },
    }, tokens);

    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 7), display_list.commandCount());
    switch (display_list.commands[0]) {
        .fill_rounded_rect => |fill| try expectFillColor(tokens.colors.surface_pressed, fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[1]) {
        .stroke_rect => |stroke| try expectFillColor(tokens.colors.focus_ring, stroke.stroke.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[2]) {
        .draw_text => |text| try std.testing.expectEqualStrings("Inbox", text.text),
        else => return error.TestUnexpectedResult,
    }
    // The active tab lifts to the page surface with a hairline border;
    // its label stays on the foreground, not the accent text.
    switch (display_list.commands[3]) {
        .fill_rounded_rect => |fill| try expectFillColor(tokens.colors.surface, fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[4]) {
        .stroke_rect => |stroke| try expectFillColor(tokens.colors.border, stroke.stroke.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[5]) {
        .stroke_rect => |stroke| {
            try std.testing.expectEqual(@as(f32, 3), stroke.stroke.width);
            try expectFillColor(tokens.colors.focus_ring, stroke.stroke.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[6]) {
        .draw_text => |text| try std.testing.expectEqualDeep(tokens.colors.text, text.color),
        else => return error.TestUnexpectedResult,
    }
}

test "widget emitter reports depth and display list overflow" {
    var tiny_commands: [2]CanvasCommand = undefined;
    var tiny_builder = Builder.init(&tiny_commands);
    try std.testing.expectError(error.DisplayListFull, emitWidgetTree(&tiny_builder, .{
        .kind = .button,
        .frame = geometry.RectF.init(0, 0, 120, 36),
        .text = "Overflow",
    }, .{}));

    var widgets: [max_widget_depth + 1]Widget = undefined;
    var index = widgets.len;
    while (index > 0) {
        index -= 1;
        widgets[index] = .{
            .kind = .stack,
            .children = if (index + 1 < widgets.len) widgets[index + 1 .. index + 2] else &.{},
        };
    }

    var commands: [1]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try std.testing.expectError(error.WidgetDepthExceeded, emitWidgetTree(&builder, widgets[0], .{}));
}

test "widget control aim point targets the rendered glyph of stretched selection controls" {
    const tokens: canvas.DesignTokens = .{};
    // A stretched switch: 718px frame, ~42px track at the left edge.
    const stretched: canvas.Widget = .{
        .id = 5,
        .kind = .switch_control,
        .frame = geometry.RectF.init(0, 100, 718, 24),
        .text = "Group",
    };
    const switch_aim = canvas.widgetControlAimPoint(stretched, tokens);
    try std.testing.expect(switch_aim.x < 60);
    try std.testing.expectApproxEqAbs(@as(f32, 112), switch_aim.y, 1);

    const checkbox: canvas.Widget = .{
        .id = 6,
        .kind = .checkbox,
        .frame = geometry.RectF.init(0, 0, 500, 28),
        .text = "Live",
    };
    try std.testing.expect(canvas.widgetControlAimPoint(checkbox, tokens).x < 30);

    const radio: canvas.Widget = .{
        .id = 7,
        .kind = .radio,
        .frame = geometry.RectF.init(0, 0, 500, 28),
        .text = "Monthly",
    };
    try std.testing.expect(canvas.widgetControlAimPoint(radio, tokens).x < 30);

    // Non-selection controls keep the frame center.
    const button: canvas.Widget = .{
        .id = 8,
        .kind = .button,
        .frame = geometry.RectF.init(0, 0, 500, 44),
        .text = "Save",
    };
    const button_aim = canvas.widgetControlAimPoint(button, tokens);
    try std.testing.expectApproxEqAbs(@as(f32, 250), button_aim.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 22), button_aim.y, 0.01);
}
