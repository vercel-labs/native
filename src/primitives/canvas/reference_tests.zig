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

test "reference renderer clears and fills solid rect render pass" {
    const commands = [_]CanvasCommand{.{ .fill_rect = .{
        .id = 1,
        .rect = geometry.RectF.init(1, 1, 2, 2),
        .fill = .{ .color = Color.rgb8(255, 0, 0) },
    } }};

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [0]RenderResource = .{};
    var resource_cache_entries: [0]RenderResourceCacheEntry = .{};
    var resource_cache_actions: [0]RenderResourceCacheAction = .{};
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [0]DiffChange = .{};
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .surface_size = geometry.SizeF.init(4, 4),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    var pixels: [4 * 4 * 4]u8 = undefined;
    const surface = try ReferenceRenderSurface.init(4, 4, &pixels);
    try surface.renderPass(frame.renderPass(), Color.rgb8(0, 0, 0));
    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 0, 0);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 1, 1);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 2, 2);
    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 3, 3);

    try surface.renderPass(.{}, Color.rgb8(255, 255, 255));
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 1, 1);
}

test "reference renderer applies render pass scale" {
    const commands = [_]CanvasCommand{.{ .fill_rect = .{
        .id = 1,
        .rect = geometry.RectF.init(1, 1, 1, 1),
        .fill = .{ .color = Color.rgb8(255, 0, 0) },
    } }};

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [0]RenderResource = .{};
    var resource_cache_entries: [0]RenderResourceCacheEntry = .{};
    var resource_cache_actions: [0]RenderResourceCacheAction = .{};
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [0]DiffChange = .{};
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .surface_size = geometry.SizeF.init(2, 2),
        .scale = 2,
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    var pixels: [4 * 4 * 4]u8 = undefined;
    const surface = try ReferenceRenderSurface.init(4, 4, &pixels);
    try surface.renderPass(frame.renderPass(), Color.rgb8(0, 0, 0));
    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 1, 1);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 2, 2);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 3, 3);
}

test "reference renderer applies render pass scissor on load" {
    const commands = [_]RenderCommand{.{
        .command = .{ .fill_rect = .{
            .id = 1,
            .rect = geometry.RectF.init(0, 0, 4, 4),
            .fill = .{ .color = Color.rgb8(255, 0, 0) },
        } },
        .local_bounds = geometry.RectF.init(0, 0, 4, 4),
        .bounds = geometry.RectF.init(0, 0, 4, 4),
    }};

    var pixels: [4 * 4 * 4]u8 = undefined;
    const surface = try ReferenceRenderSurface.init(4, 4, &pixels);
    surface.clear(Color.rgb8(0, 0, 255));
    try surface.renderPass(.{
        .dirty_bounds = geometry.RectF.init(1, 1, 2, 2),
        .commands = &commands,
    }, Color.rgb8(0, 0, 0));

    try expectPixelRgba8(.{ 0, 0, 255, 255 }, surface, 0, 0);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 1, 1);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 2, 2);
    try expectPixelRgba8(.{ 0, 0, 255, 255 }, surface, 3, 3);
}

test "reference renderer clears dirty rect on retained load" {
    const commands = [_]RenderCommand{.{
        .command = .{ .fill_rect = .{
            .id = 1,
            .rect = geometry.RectF.init(1, 1, 1, 1),
            .fill = .{ .color = Color.rgb8(255, 0, 0) },
        } },
        .local_bounds = geometry.RectF.init(1, 1, 1, 1),
        .bounds = geometry.RectF.init(1, 1, 1, 1),
    }};

    var pixels: [4 * 4 * 4]u8 = undefined;
    const surface = try ReferenceRenderSurface.init(4, 4, &pixels);
    surface.clear(Color.rgb8(0, 0, 255));
    try surface.renderPass(.{
        .dirty_bounds = geometry.RectF.init(1, 1, 2, 2),
        .commands = &commands,
    }, Color.rgb8(0, 0, 0));

    try expectPixelRgba8(.{ 0, 0, 255, 255 }, surface, 0, 0);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 1, 1);
    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 2, 2);
    try expectPixelRgba8(.{ 0, 0, 255, 255 }, surface, 3, 3);
}

test "reference renderer captures Phase 2 primitive signature" {
    const stops = [_]GradientStop{
        .{ .offset = 0, .color = Color.rgb8(248, 250, 252) },
        .{ .offset = 1, .color = Color.rgb8(48, 111, 237) },
    };
    const glyphs = [_]Glyph{
        .{ .id = 1, .x = 0, .y = 0, .advance = 4 },
        .{ .id = 2, .x = 5, .y = 0, .advance = 4 },
    };
    const image_pixels = [_]u8{
        16,  185, 129, 255,
        255, 255, 255, 255,
        15,  23,  42,  255,
        48,  111, 237, 255,
    };
    const images = [_]ReferenceImage{.{
        .id = 7,
        .width = 2,
        .height = 2,
        .pixels = &image_pixels,
    }};
    const commands = [_]CanvasCommand{
        .{ .fill_rect = .{
            .id = 1,
            .rect = geometry.RectF.init(0, 0, 32, 24),
            .fill = .{ .linear_gradient = .{ .start = geometry.PointF.init(0, 0), .end = geometry.PointF.init(32, 24), .stops = &stops } },
        } },
        .{ .shadow = .{
            .id = 2,
            .rect = geometry.RectF.init(4, 4, 18, 10),
            .radius = Radius.all(3),
            .offset = .{ .dx = 0, .dy = 2 },
            .blur = 2,
            .spread = 0,
            .color = Color.rgba8(15, 23, 42, 64),
        } },
        .{ .push_clip = .{ .id = 3, .rect = geometry.RectF.init(2, 2, 28, 20), .radius = Radius.all(2) } },
        .{ .push_opacity = 0.84 },
        .{ .transform = Affine.translate(1, 1) },
        .{ .fill_rounded_rect = .{
            .id = 4,
            .rect = geometry.RectF.init(4, 4, 18, 10),
            .radius = Radius.all(3),
            .fill = .{ .color = Color.rgb8(255, 255, 255) },
        } },
        .{ .stroke_rect = .{
            .id = 5,
            .rect = geometry.RectF.init(4, 4, 18, 10),
            .radius = Radius.all(3),
            .stroke = .{ .fill = .{ .color = Color.rgb8(15, 23, 42) }, .width = 1 },
        } },
        .{ .draw_image = .{
            .id = 6,
            .image_id = 7,
            .dst = geometry.RectF.init(18, 5, 8, 8),
            .fit = .cover,
            .sampling = .nearest,
        } },
        .{ .draw_text = .{
            .id = 7,
            .font_id = 1,
            .size = 4,
            .origin = geometry.PointF.init(6, 18),
            .color = Color.rgb8(15, 23, 42),
            .text = "UI",
            .glyphs = &glyphs,
        } },
        .pop_opacity,
        .pop_clip,
        .{ .blur = .{
            .id = 8,
            .rect = geometry.RectF.init(24, 2, 6, 6),
            .radius = 1,
        } },
    };

    var render_commands: [commands.len]RenderCommand = undefined;
    var render_batches: [commands.len]RenderBatch = undefined;
    var pipeline_cache_entries: [8]RenderPipelineCacheEntry = undefined;
    var pipeline_cache_actions: [16]RenderPipelineCacheAction = undefined;
    var layers: [commands.len]RenderLayer = undefined;
    var layer_cache_entries: [commands.len]RenderLayerCacheEntry = undefined;
    var layer_cache_actions: [commands.len * 2]RenderLayerCacheAction = undefined;
    var resources: [8]RenderResource = undefined;
    var resource_cache_entries: [8]RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [16]RenderResourceCacheAction = undefined;
    var visual_effects: [4]VisualEffect = undefined;
    var visual_effect_cache_entries: [4]VisualEffectCacheEntry = undefined;
    var visual_effect_cache_actions: [8]VisualEffectCacheAction = undefined;
    var glyph_atlas_entries: [8]GlyphAtlasEntry = undefined;
    var glyph_cache_entries: [8]GlyphAtlasCacheEntry = undefined;
    var glyph_cache_actions: [16]GlyphAtlasCacheAction = undefined;
    var text_layout_plans: [4]TextLayoutPlan = undefined;
    var text_layout_lines: [8]TextLine = undefined;
    var text_layout_cache_entries: [4]TextLayoutCacheEntry = undefined;
    var text_layout_cache_actions: [8]TextLayoutCacheAction = undefined;
    var changes: [commands.len]DiffChange = undefined;
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .surface_size = geometry.SizeF.init(32, 24),
        .full_repaint = true,
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .pipeline_cache_entries = &pipeline_cache_entries,
        .pipeline_cache_actions = &pipeline_cache_actions,
        .layers = &layers,
        .layer_cache_entries = &layer_cache_entries,
        .layer_cache_actions = &layer_cache_actions,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .visual_effects = &visual_effects,
        .visual_effect_cache_entries = &visual_effect_cache_entries,
        .visual_effect_cache_actions = &visual_effect_cache_actions,
        .glyph_atlas_entries = &glyph_atlas_entries,
        .glyph_atlas_cache_entries = &glyph_cache_entries,
        .glyph_atlas_cache_actions = &glyph_cache_actions,
        .text_layout_plans = &text_layout_plans,
        .text_layout_lines = &text_layout_lines,
        .text_layout_cache_entries = &text_layout_cache_entries,
        .text_layout_cache_actions = &text_layout_cache_actions,
        .changes = &changes,
    });

    try std.testing.expect(frame.requiresRender());
    try std.testing.expect(frame.batch_plan.batchCount() >= 5);
    try std.testing.expectEqual(@as(usize, 1), frame.layer_plan.opacityLayerCount());
    try std.testing.expectEqual(@as(usize, 1), frame.layer_plan.clipLayerCount());
    try std.testing.expectEqual(@as(usize, 2), frame.layer_plan.transformLayerCount());
    try std.testing.expect(frame.resource_plan.resourceCount() >= 3);
    try std.testing.expect(frame.visual_effect_plan.shadowCount() >= 1);
    try std.testing.expect(frame.visual_effect_plan.blurCount() >= 1);
    try std.testing.expectEqual(@as(usize, 2), frame.glyph_atlas_plan.entryCount());

    var pixels: [32 * 24 * 4]u8 = undefined;
    var scratch: [32 * 24 * 4]u8 = undefined;
    const surface = (try ReferenceRenderSurface.initWithScratch(32, 24, &pixels, &scratch)).withImages(&images);
    try surface.renderPass(frame.renderPass(), Color.rgb8(0, 0, 0));

    try std.testing.expectEqual(@as(u64, 8143217197410062006), referenceSurfaceSignature(&pixels));
    try expectVisiblePixel(surface.pixelRgba8(6, 6));
    try expectVisiblePixel(surface.pixelRgba8(20, 8));
    try expectVisiblePixel(surface.pixelRgba8(6, 16));
}

// ---------------------------------------------------------------------------
// Rounded-rect coverage shape fidelity.
//
// The anti-aliased rounded-rect rasterization derives per-pixel coverage
// from one continuous signed-distance field of the whole shape. These
// tests hold that coverage against ground truth — 16x16 supersampling of
// the exact point-in-shape predicate per pixel — with two assertions:
//
//   1. NO PROTRUSION: any pixel the supersampled shape leaves empty must
//      stay empty. A coverage model that treats perimeter regions
//      differently (an arc ramp handing off to a binary straight edge)
//      disagrees with itself about where the boundary is and pushes
//      nubs outside the silhouette; this catches that class of bug
//      exactly.
//   2. BOUNDED DEVIATION: the worst per-pixel difference stays within
//      the intrinsic error of distance-ramp coverage. A half-pixel
//      linear ramp reproduces box-filter coverage exactly on straight
//      edges; on arcs it deviates more as curvature tightens, and at a
//      sharp concave ring corner the distance-to-coverage mapping has a
//      known worst case of ~1/4 at the single corner pixel. The
//      per-case bounds encode those regimes with a small margin; the
//      discontinuous-coverage bug class lands far outside them (2-4x).

const roundedRectCoverageFidelityCase = struct {
    kind: enum { fill, stroke },
    rect: geometry.RectF,
    radius: Radius,
    stroke_width: f32 = 0,
    /// Max per-pixel |rendered - supersampled| in 1/255 levels.
    tolerance: i32,
};

fn fidelityClampRadius(value: f32, max_radius: f32) f32 {
    return std.math.clamp(@max(0, value), 0, max_radius);
}

fn fidelityInCorner(x: f32, y: f32, cx: f32, cy: f32, r: f32) bool {
    if (r <= 0) return false;
    const dx = x - cx;
    const dy = y - cy;
    return dx * dx + dy * dy <= r * r;
}

/// The exact rounded-rect interior predicate the supersampled ground
/// truth integrates: the rect with each corner replaced by a quarter
/// disc of its (clamped) radius.
fn fidelityInRoundedRect(x: f32, y: f32, rect: geometry.RectF, radius: Radius) bool {
    if (rect.width <= 0 or rect.height <= 0) return false;
    if (x < rect.x or x > rect.x + rect.width or y < rect.y or y > rect.y + rect.height) return false;
    const max_radius = @min(rect.width, rect.height) * 0.5;
    const top_left = fidelityClampRadius(radius.top_left, max_radius);
    const top_right = fidelityClampRadius(radius.top_right, max_radius);
    const bottom_right = fidelityClampRadius(radius.bottom_right, max_radius);
    const bottom_left = fidelityClampRadius(radius.bottom_left, max_radius);
    const max_x = rect.x + rect.width;
    const max_y = rect.y + rect.height;
    if (x < rect.x + top_left and y < rect.y + top_left) return fidelityInCorner(x, y, rect.x + top_left, rect.y + top_left, top_left);
    if (x >= max_x - top_right and y < rect.y + top_right) return fidelityInCorner(x, y, max_x - top_right, rect.y + top_right, top_right);
    if (x >= max_x - bottom_right and y >= max_y - bottom_right) return fidelityInCorner(x, y, max_x - bottom_right, max_y - bottom_right, bottom_right);
    if (x < rect.x + bottom_left and y >= max_y - bottom_left) return fidelityInCorner(x, y, rect.x + bottom_left, max_y - bottom_left, bottom_left);
    return true;
}

fn fidelityOutsetRadius(radius: Radius, outset: f32) Radius {
    return .{
        .top_left = @max(0, radius.top_left + outset),
        .top_right = @max(0, radius.top_right + outset),
        .bottom_right = @max(0, radius.bottom_right + outset),
        .bottom_left = @max(0, radius.bottom_left + outset),
    };
}

/// Ground-truth alpha of one pixel: the fraction of a 16x16 subsample
/// grid inside the case's shape (the stroke ring is outer minus inner,
/// derived exactly as the renderer derives them), quantized to a byte
/// like the renderer's blend quantizes coverage.
fn fidelityTruthAlpha(case: roundedRectCoverageFidelityCase, px: usize, py: usize) u8 {
    const half = case.stroke_width * 0.5;
    const outer = case.rect.inflate(geometry.InsetsF.all(half));
    const inner = case.rect.deflate(geometry.InsetsF.all(@min(half, @min(case.rect.width, case.rect.height) * 0.5)));
    const outer_radius = fidelityOutsetRadius(case.radius, half);
    const inner_radius = fidelityOutsetRadius(case.radius, -half);
    var covered: usize = 0;
    var sub_y: usize = 0;
    while (sub_y < 16) : (sub_y += 1) {
        var sub_x: usize = 0;
        while (sub_x < 16) : (sub_x += 1) {
            const x = @as(f32, @floatFromInt(px)) + (@as(f32, @floatFromInt(sub_x)) + 0.5) / 16.0;
            const y = @as(f32, @floatFromInt(py)) + (@as(f32, @floatFromInt(sub_y)) + 0.5) / 16.0;
            const in = switch (case.kind) {
                .fill => fidelityInRoundedRect(x, y, case.rect, case.radius),
                .stroke => fidelityInRoundedRect(x, y, outer, outer_radius) and !fidelityInRoundedRect(x, y, inner, inner_radius),
            };
            if (in) covered += 1;
        }
    }
    return @intFromFloat(@round(@as(f32, @floatFromInt(covered)) / 256.0 * 255.0));
}

test "rounded-rect coverage matches supersampled ground truth with no silhouette protrusion" {
    const fidelity_width: usize = 48;
    const fidelity_height: usize = 40;
    const white = Color{ .r = 1, .g = 1, .b = 1, .a = 1 };
    const cases = [_]roundedRectCoverageFidelityCase{
        // Button-shaped fills: smooth arcs, integer and fractional bounds.
        .{ .kind = .fill, .rect = geometry.RectF.init(6, 5, 30, 22), .radius = Radius.all(8), .tolerance = 16 },
        .{ .kind = .fill, .rect = geometry.RectF.init(6.3, 5.7, 29.4, 21.6), .radius = Radius.all(8), .tolerance = 16 },
        // Pill: the radius clamps to the half-height.
        .{ .kind = .fill, .rect = geometry.RectF.init(4, 6, 40, 20), .radius = Radius.all(22), .tolerance = 16 },
        // Tight curvature and mixed per-corner radii (one square corner).
        .{ .kind = .fill, .rect = geometry.RectF.init(10.2, 8.6, 21.7, 14.3), .radius = Radius.all(0.75), .tolerance = 32 },
        .{ .kind = .fill, .rect = geometry.RectF.init(7.6, 6.2, 30.8, 24.9), .radius = .{ .top_left = 0, .top_right = 6, .bottom_right = 12, .bottom_left = 2 }, .tolerance = 32 },
        // Thin borders: both ring edges from the same field.
        .{ .kind = .stroke, .rect = geometry.RectF.init(8, 7, 28, 20), .radius = Radius.all(6), .stroke_width = 1, .tolerance = 20 },
        .{ .kind = .stroke, .rect = geometry.RectF.init(8.4, 7.8, 27.3, 19.5), .radius = Radius.all(6), .stroke_width = 2, .tolerance = 20 },
        .{ .kind = .stroke, .rect = geometry.RectF.init(9.1, 8.3, 25.6, 17.2), .radius = Radius.all(0.75), .stroke_width = 1, .tolerance = 32 },
        // Thick border whose inset radius bottoms out: the ring's inner
        // corners go sharp and concave, the distance-ramp worst case.
        .{ .kind = .stroke, .rect = geometry.RectF.init(8, 7, 28, 20), .radius = Radius.all(1), .stroke_width = 3, .tolerance = 72 },
    };

    for (cases) |case| {
        var pixels: [fidelity_width * fidelity_height * 4]u8 = undefined;
        const surface = try ReferenceRenderSurface.init(fidelity_width, fidelity_height, &pixels);
        const bounds = geometry.RectF.init(0, 0, fidelity_width, fidelity_height);
        const command = RenderCommand{
            .command = switch (case.kind) {
                .fill => .{ .fill_rounded_rect = .{ .rect = case.rect, .radius = case.radius, .fill = .{ .color = white } } },
                .stroke => .{ .stroke_rect = .{ .rect = case.rect, .radius = case.radius, .stroke = .{ .fill = .{ .color = white }, .width = case.stroke_width } } },
            },
            .local_bounds = bounds,
            .bounds = bounds,
        };
        const pass = CanvasRenderPass{
            .surface_size = geometry.SizeF.init(fidelity_width, fidelity_height),
            .scale = 1,
            .full_repaint = true,
            .commands = &.{command},
        };
        try surface.renderPass(pass, Color{ .r = 0, .g = 0, .b = 0, .a = 0 });

        var y: usize = 0;
        while (y < fidelity_height) : (y += 1) {
            var x: usize = 0;
            while (x < fidelity_width) : (x += 1) {
                const rendered: i32 = surface.pixelRgba8(x, y)[3];
                const truth: i32 = fidelityTruthAlpha(case, x, y);
                if (truth == 0) try std.testing.expectEqual(@as(i32, 0), rendered);
                try std.testing.expect(@max(rendered - truth, truth - rendered) <= case.tolerance);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Coverage blend-space split.
//
// Geometry (paths, rounded rects) blends its anti-aliased edge coverage
// in linear light; glyph coverage blends in sRGB to preserve text
// weight. These tests pin the split from both sides with independently
// computed ground truth, so a refactor can never silently swap the two
// (a swap fails BOTH assertions, loudly).

/// The exact sRGB decode the renderer's 256-entry byte table holds.
fn blendSplitSrgbToLinear(value: f32) f32 {
    const channel = std.math.clamp(value, 0, 1);
    if (channel <= 0.04045) return channel / 12.92;
    return std.math.pow(f32, (channel + 0.055) / 1.055, 2.4);
}

fn blendSplitLinearToSrgb(value: f32) f32 {
    const channel = std.math.clamp(value, 0, 1);
    if (channel <= 0.0031308) return channel * 12.92;
    return 1.055 * std.math.pow(f32, channel, 1.0 / 2.4) - 0.055;
}

/// The renderer's encode-table lookup, replicated: nearest of 4096
/// evenly spaced entries, then the final byte rounding.
fn blendSplitEncodeByte(value: f32) u8 {
    const index = @round(std.math.clamp(value, 0, 1) * 4095.0);
    return @intFromFloat(@round(blendSplitLinearToSrgb(index / 4095.0) * 255.0));
}

/// Linear-light coverage blend of an opaque source byte over an opaque
/// destination byte, from the same LUT math the renderer tabulates.
fn blendSplitLinearByte(src: u8, dst: u8, coverage: f32) u8 {
    const src_linear = blendSplitSrgbToLinear(@as(f32, @floatFromInt(src)) / 255.0);
    const dst_linear = blendSplitSrgbToLinear(@as(f32, @floatFromInt(dst)) / 255.0);
    return blendSplitEncodeByte(src_linear * coverage + dst_linear * (1 - coverage));
}

/// sRGB-space coverage blend of the same pixel (the historical fold).
fn blendSplitSrgbByte(src: u8, dst: u8, coverage: f32) u8 {
    const src_f = @as(f32, @floatFromInt(src)) / 255.0;
    const dst_f = @as(f32, @floatFromInt(dst)) / 255.0;
    return @intFromFloat(@round((src_f * coverage + dst_f * (1 - coverage)) * 255.0));
}

fn blendSplitRenderPass(surface: ReferenceRenderSurface, command: RenderCommand, clear: Color, width: usize, height: usize) !void {
    const pass = CanvasRenderPass{
        .surface_size = geometry.SizeF.init(@floatFromInt(width), @floatFromInt(height)),
        .scale = 1,
        .full_repaint = true,
        .commands = &.{command},
    };
    try surface.renderPass(pass, clear);
}

test "geometry edge coverage blends in linear light, computed from the LUT math" {
    // A black path whose right edge splits pixel column 12 exactly in
    // half: the vector core reports coverage 0.5 there, interiors 1.
    const split_width: usize = 24;
    const split_height: usize = 16;
    const white = Color{ .r = 1, .g = 1, .b = 1, .a = 1 };
    const black = Color{ .r = 0, .g = 0, .b = 0, .a = 1 };
    const bounds = geometry.RectF.init(0, 0, split_width, split_height);
    const elements = [_]PathElement{
        .{ .verb = .move_to, .points = .{ geometry.PointF.init(4, 4), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(12.5, 4), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(12.5, 12), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(4, 12), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .close, .points = .{ geometry.PointF.zero(), geometry.PointF.zero(), geometry.PointF.zero() } },
    };

    const linear_edge = blendSplitLinearByte(0, 255, 0.5);
    const srgb_edge = blendSplitSrgbByte(0, 255, 0.5);
    // The split is only observable if the two spaces disagree here.
    try std.testing.expect(linear_edge != srgb_edge);

    // fill_path: the vector-core geometry route.
    {
        var pixels: [split_width * split_height * 4]u8 = undefined;
        const surface = try ReferenceRenderSurface.init(split_width, split_height, &pixels);
        try blendSplitRenderPass(surface, .{
            .command = .{ .fill_path = .{ .elements = &elements, .fill = .{ .color = black } } },
            .local_bounds = bounds,
            .bounds = bounds,
        }, white, split_width, split_height);
        // Fully covered interior pixels stay bit-identical to the plain
        // sRGB blend: an opaque source at coverage 1 is a copy in either
        // space.
        try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 8, 8);
        // The half-covered edge pixel holds the linear-light value.
        try expectPixelRgba8(.{ linear_edge, linear_edge, linear_edge, 255 }, surface, 12, 8);
    }

    // fill_rounded_rect: the signed-distance geometry route. Its right
    // edge is a straight segment at the same half-pixel boundary (the
    // radius-2 corners are far from row 8), so coverage is 0.5 again.
    {
        var pixels: [split_width * split_height * 4]u8 = undefined;
        const surface = try ReferenceRenderSurface.init(split_width, split_height, &pixels);
        try blendSplitRenderPass(surface, .{
            .command = .{ .fill_rounded_rect = .{ .rect = geometry.RectF.init(4, 4, 8.5, 8), .radius = Radius.all(2), .fill = .{ .color = black } } },
            .local_bounds = bounds,
            .bounds = bounds,
        }, white, split_width, split_height);
        try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 8, 8);
        try expectPixelRgba8(.{ linear_edge, linear_edge, linear_edge, 255 }, surface, 12, 8);
    }
}

test "glyph edge coverage blends in sRGB, not linear light" {
    // The same discrimination from the text side: render one glyph twice
    // — once over transparent (whose alpha channel IS the coverage, in
    // any blend space) and once over white — then check every fringe
    // pixel of the white render against both models. Text must track the
    // sRGB fold and stay far from the linear-light value at mid
    // coverage, so inverting the sink's blend space can never pass.
    const glyph_width: usize = 32;
    const glyph_height: usize = 48;
    const white = Color{ .r = 1, .g = 1, .b = 1, .a = 1 };
    const black = Color{ .r = 0, .g = 0, .b = 0, .a = 1 };
    const clear = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
    const bounds = geometry.RectF.init(0, 0, glyph_width, glyph_height);
    const command = RenderCommand{
        .command = .{ .draw_text = .{ .size = 32, .origin = geometry.PointF.init(4, 40), .color = black, .text = "o" } },
        .local_bounds = bounds,
        .bounds = bounds,
    };

    var coverage_pixels: [glyph_width * glyph_height * 4]u8 = undefined;
    const coverage_surface = try ReferenceRenderSurface.init(glyph_width, glyph_height, &coverage_pixels);
    try blendSplitRenderPass(coverage_surface, command, clear, glyph_width, glyph_height);

    var blended_pixels: [glyph_width * glyph_height * 4]u8 = undefined;
    const blended_surface = try ReferenceRenderSurface.init(glyph_width, glyph_height, &blended_pixels);
    try blendSplitRenderPass(blended_surface, command, white, glyph_width, glyph_height);

    var mid_coverage_pixels: usize = 0;
    var y: usize = 0;
    while (y < glyph_height) : (y += 1) {
        var x: usize = 0;
        while (x < glyph_width) : (x += 1) {
            const coverage_byte = coverage_surface.pixelRgba8(x, y)[3];
            if (coverage_byte == 0 or coverage_byte == 255) continue;
            const coverage = @as(f32, @floatFromInt(coverage_byte)) / 255.0;
            const rendered: i32 = blended_surface.pixelRgba8(x, y)[0];
            const srgb_expected: i32 = blendSplitSrgbByte(0, 255, coverage);
            // One level of slack: the recovered coverage byte is itself
            // rounded, so the re-derived sRGB fold can sit one step off
            // the value blended from the unrounded coverage.
            try std.testing.expect(@max(rendered - srgb_expected, srgb_expected - rendered) <= 1);
            // Mid-coverage fringes are where the spaces disagree most;
            // hold text a wide margin away from the linear value there.
            if (coverage_byte >= 64 and coverage_byte <= 192) {
                mid_coverage_pixels += 1;
                const linear_expected: i32 = blendSplitLinearByte(0, 255, coverage);
                try std.testing.expect(linear_expected - rendered >= 16);
            }
        }
    }
    // The glyph must actually have exercised the fringe band.
    try std.testing.expect(mid_coverage_pixels >= 4);
}

test "reference renderer applies clip transform and opacity" {
    const commands = [_]CanvasCommand{
        .{ .push_clip = .{ .rect = geometry.RectF.init(1, 1, 2, 2) } },
        .{ .push_opacity = 0.5 },
        .{ .transform = Affine.translate(1, 0) },
        .{ .fill_rect = .{
            .id = 1,
            .rect = geometry.RectF.init(0, 0, 3, 3),
            .fill = .{ .color = Color.rgb8(255, 0, 0) },
        } },
        .pop_opacity,
        .pop_clip,
    };

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [0]RenderResource = .{};
    var resource_cache_entries: [0]RenderResourceCacheEntry = .{};
    var resource_cache_actions: [0]RenderResourceCacheAction = .{};
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [0]DiffChange = .{};
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .surface_size = geometry.SizeF.init(4, 4),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    var pixels: [4 * 4 * 4]u8 = undefined;
    const surface = try ReferenceRenderSurface.init(4, 4, &pixels);
    try surface.renderPass(frame.renderPass(), Color.rgb8(0, 0, 0));
    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 1, 0);
    try expectPixelRgba8(.{ 128, 0, 0, 255 }, surface, 1, 1);
    try expectPixelRgba8(.{ 128, 0, 0, 255 }, surface, 2, 2);
    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 3, 3);
}

test "reference renderer samples transformed clipped linear gradients" {
    const stops = [_]GradientStop{
        .{ .offset = 0, .color = Color.rgb8(255, 0, 0) },
        .{ .offset = 1, .color = Color.rgb8(0, 0, 255) },
    };
    const commands = [_]CanvasCommand{
        .{ .push_clip = .{ .rect = geometry.RectF.init(2, 0, 1, 1) } },
        .{ .transform = Affine.translate(1, 0) },
        .{ .fill_rect = .{
            .id = 1,
            .rect = geometry.RectF.init(0, 0, 2, 1),
            .fill = .{ .linear_gradient = .{
                .start = geometry.PointF.init(0, 0),
                .end = geometry.PointF.init(2, 0),
                .stops = &stops,
            } },
        } },
        .pop_clip,
    };

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [1]RenderResource = undefined;
    var resource_cache_entries: [1]RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [1]RenderResourceCacheAction = undefined;
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [0]DiffChange = .{};
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .surface_size = geometry.SizeF.init(4, 1),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    var pixels: [4 * 1 * 4]u8 = undefined;
    const surface = try ReferenceRenderSurface.init(4, 1, &pixels);
    try surface.renderPass(frame.renderPass(), Color.rgb8(0, 0, 0));

    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 0, 0);
    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 1, 0);
    try expectPixelRgba8(.{ 137, 0, 225, 255 }, surface, 2, 0);
    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 3, 0);
}

test "reference renderer draws stroked lines" {
    const commands = [_]CanvasCommand{.{ .draw_line = .{
        .id = 1,
        .from = geometry.PointF.init(0.5, 1.5),
        .to = geometry.PointF.init(2.5, 1.5),
        .stroke = .{ .fill = .{ .color = Color.rgb8(255, 0, 0) }, .width = 1 },
    } }};

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [0]RenderResource = .{};
    var resource_cache_entries: [0]RenderResourceCacheEntry = .{};
    var resource_cache_actions: [0]RenderResourceCacheAction = .{};
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [0]DiffChange = .{};
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .surface_size = geometry.SizeF.init(4, 3),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    var pixels: [4 * 3 * 4]u8 = undefined;
    const surface = try ReferenceRenderSurface.init(4, 3, &pixels);
    try surface.renderPass(frame.renderPass(), Color.rgb8(0, 0, 0));

    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 1, 0);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 0, 1);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 1, 1);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 2, 1);
    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 3, 1);
    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 1, 2);
}

test "reference renderer fills closed paths" {
    const elements = [_]PathElement{
        .{ .verb = .move_to, .points = .{ geometry.PointF.init(1, 1), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(3, 1), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(3, 3), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(1, 3), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .close },
    };
    const commands = [_]CanvasCommand{.{ .fill_path = .{
        .id = 1,
        .elements = &elements,
        .fill = .{ .color = Color.rgb8(255, 0, 0) },
    } }};

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [0]RenderResource = .{};
    var resource_cache_entries: [0]RenderResourceCacheEntry = .{};
    var resource_cache_actions: [0]RenderResourceCacheAction = .{};
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [0]DiffChange = .{};
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .surface_size = geometry.SizeF.init(4, 4),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    var pixels: [4 * 4 * 4]u8 = undefined;
    const surface = try ReferenceRenderSurface.init(4, 4, &pixels);
    try surface.renderPass(frame.renderPass(), Color.rgb8(0, 0, 0));

    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 0, 0);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 1, 1);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 2, 2);
    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 3, 3);
}

test "reference renderer strokes paths: butt caps end at the segment, round caps extend it" {
    // One horizontal unit-width segment, rendered once per cap shape.
    // The end pixels (0,1) and (2,1) are where the caps live: the butt
    // cap stops at the endpoint (the segment covers exactly half of each
    // end pixel), while the round cap bulges a half-width semicircle
    // past it (75% coverage per the anti-aliased vector core). Interior
    // and off-stroke pixels are cap-independent. The expected end-pixel
    // bytes are the LINEAR-LIGHT encodings of those coverages over black
    // — geometry edge coverage blends in linear light (see the renderer's
    // `CoverageBlend`), so 50% coverage of a 255 channel re-encodes to
    // 188 and 75% to 225, not the 128/191 sRGB-space folds.
    const cases = [_]struct { cap: canvas.LineCap, end_coverage: u8 }{
        .{ .cap = .butt, .end_coverage = 188 },
        .{ .cap = .round, .end_coverage = 225 },
    };
    for (cases) |case| {
        const elements = [_]PathElement{
            .{ .verb = .move_to, .points = .{ geometry.PointF.init(0.5, 1.5), geometry.PointF.zero(), geometry.PointF.zero() } },
            .{ .verb = .line_to, .points = .{ geometry.PointF.init(2.5, 1.5), geometry.PointF.zero(), geometry.PointF.zero() } },
        };
        const commands = [_]CanvasCommand{.{ .stroke_path = .{
            .id = 1,
            .elements = &elements,
            .stroke = .{ .fill = .{ .color = Color.rgb8(255, 0, 0) }, .width = 1 },
            .cap = case.cap,
        } }};

        var render_commands: [1]RenderCommand = undefined;
        var render_batches: [1]RenderBatch = undefined;
        var resources: [0]RenderResource = .{};
        var resource_cache_entries: [0]RenderResourceCacheEntry = .{};
        var resource_cache_actions: [0]RenderResourceCacheAction = .{};
        var glyphs: [0]GlyphAtlasEntry = .{};
        var changes: [0]DiffChange = .{};
        const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
            .surface_size = geometry.SizeF.init(4, 3),
        }, .{
            .render_commands = &render_commands,
            .render_batches = &render_batches,
            .resources = &resources,
            .resource_cache_entries = &resource_cache_entries,
            .resource_cache_actions = &resource_cache_actions,
            .glyph_atlas_entries = &glyphs,
            .changes = &changes,
        });

        var pixels: [4 * 3 * 4]u8 = undefined;
        const surface = try ReferenceRenderSurface.init(4, 3, &pixels);
        try surface.renderPass(frame.renderPass(), Color.rgb8(0, 0, 0));

        try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 1, 0);
        try expectPixelRgba8(.{ case.end_coverage, 0, 0, 255 }, surface, 0, 1);
        try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 1, 1);
        try expectPixelRgba8(.{ case.end_coverage, 0, 0, 255 }, surface, 2, 1);
        try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 3, 1);
    }
}

test "reference renderer draws soft shadows" {
    const commands = [_]CanvasCommand{.{ .shadow = .{
        .id = 1,
        .rect = geometry.RectF.init(1, 1, 2, 2),
        .blur = 1,
        .color = Color.rgba8(0, 0, 0, 128),
    } }};

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [1]RenderResource = undefined;
    var resource_cache_entries: [1]RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [1]RenderResourceCacheAction = undefined;
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [0]DiffChange = .{};
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .surface_size = geometry.SizeF.init(4, 4),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    var pixels: [4 * 4 * 4]u8 = undefined;
    const surface = try ReferenceRenderSurface.init(4, 4, &pixels);
    try surface.renderPass(frame.renderPass(), Color.rgba8(0, 0, 0, 0));

    try expectPixelRgba8(.{ 0, 0, 0, 27 }, surface, 0, 0);
    try expectPixelRgba8(.{ 0, 0, 0, 64 }, surface, 0, 1);
    try expectPixelRgba8(.{ 0, 0, 0, 128 }, surface, 1, 1);
    try expectPixelRgba8(.{ 0, 0, 0, 64 }, surface, 3, 2);
}

test "reference renderer blurs with caller scratch storage" {
    const commands = [_]CanvasCommand{
        .{ .fill_rect = .{
            .id = 1,
            .rect = geometry.RectF.init(0, 0, 1, 1),
            .fill = .{ .color = Color.rgb8(255, 0, 0) },
        } },
        .{ .fill_rect = .{
            .id = 2,
            .rect = geometry.RectF.init(2, 0, 1, 1),
            .fill = .{ .color = Color.rgb8(0, 0, 255) },
        } },
        .{ .blur = .{
            .id = 3,
            .rect = geometry.RectF.init(0, 0, 3, 1),
            .radius = 1,
        } },
    };

    var render_commands: [3]RenderCommand = undefined;
    var render_batches: [3]RenderBatch = undefined;
    var resources: [1]RenderResource = undefined;
    var resource_cache_entries: [1]RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [1]RenderResourceCacheAction = undefined;
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [0]DiffChange = .{};
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .surface_size = geometry.SizeF.init(3, 1),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    var pixels: [3 * 1 * 4]u8 = undefined;
    var scratch: [3 * 1 * 4]u8 = undefined;
    const surface = try ReferenceRenderSurface.initWithScratch(3, 1, &pixels, &scratch);
    try surface.renderPass(frame.renderPass(), Color.rgb8(0, 0, 0));

    try expectPixelRgba8(.{ 159, 0, 0, 255 }, surface, 0, 0);
    try expectPixelRgba8(.{ 70, 0, 70, 255 }, surface, 1, 0);
    try expectPixelRgba8(.{ 0, 0, 159, 255 }, surface, 2, 0);
}

test "reference renderer render memo replays byte-identical pixels" {
    // The render memo is pure memoization: a render with a cold memo, a
    // render that HITS the memo, and a render with no memo at all must
    // produce the same bytes — determinism is the law, the memo only
    // moves time. A content change under the memoized layers must miss
    // and land on the unmemoized bytes for the NEW content. The scene
    // carries every memoized command kind: a base fill, a backdrop blur,
    // a translucent wash fill, a drop shadow, and a rounded surface fill
    // (the modal-dialog stack in miniature).
    const Frame = struct {
        commands: [5]CanvasCommand,
        render_commands: [5]RenderCommand,
        render_batches: [5]RenderBatch,
        resources: [8]RenderResource,
        resource_cache_entries: [8]RenderResourceCacheEntry,
        resource_cache_actions: [8]RenderResourceCacheAction,
        glyphs: [0]GlyphAtlasEntry,
        changes: [0]DiffChange,

        fn render(self: *@This(), base: Color, pixels: []u8, scratch: []u8, memo: ?*canvas.ReferenceRenderMemo) !void {
            self.commands = .{
                .{ .fill_rect = .{
                    .id = 1,
                    .rect = geometry.RectF.init(0, 0, 8, 8),
                    .fill = .{ .color = base },
                } },
                .{ .blur = .{
                    .id = 2,
                    .rect = geometry.RectF.init(0, 0, 8, 8),
                    .radius = 1,
                } },
                .{ .fill_rect = .{
                    .id = 3,
                    .rect = geometry.RectF.init(0, 0, 8, 8),
                    .fill = .{ .color = Color.rgba8(0, 0, 0, 26) },
                } },
                .{ .shadow = .{
                    .id = 4,
                    .rect = geometry.RectF.init(2, 2, 4, 4),
                    .blur = 2,
                    .color = Color.rgba8(0, 0, 0, 128),
                } },
                .{ .fill_rounded_rect = .{
                    .id = 5,
                    .rect = geometry.RectF.init(2, 2, 4, 4),
                    .radius = Radius.all(1),
                    .fill = .{ .color = Color.rgb8(240, 240, 240) },
                } },
            };
            const frame = try (DisplayList{ .commands = &self.commands }).framePlan(null, .{
                .surface_size = geometry.SizeF.init(8, 8),
            }, .{
                .render_commands = &self.render_commands,
                .render_batches = &self.render_batches,
                .resources = &self.resources,
                .resource_cache_entries = &self.resource_cache_entries,
                .resource_cache_actions = &self.resource_cache_actions,
                .glyph_atlas_entries = &self.glyphs,
                .changes = &self.changes,
            });
            const surface = (try ReferenceRenderSurface.initWithScratch(8, 8, pixels, scratch)).withRenderMemo(memo);
            try surface.renderPass(frame.renderPass(), Color.rgb8(0, 0, 0));
        }
    };
    var frame: Frame = undefined;

    var memo = canvas.ReferenceRenderMemo.init(std.testing.allocator);
    defer memo.deinit();
    // The production threshold skips small rects; the test surface is
    // tiny, so memoize everything to exercise all four command kinds.
    memo.min_pixels = 0;

    var baseline: [8 * 8 * 4]u8 = undefined;
    var pixels: [8 * 8 * 4]u8 = undefined;
    var scratch: [8 * 8 * 4]u8 = undefined;

    const red = Color.rgb8(255, 0, 0);
    try frame.render(red, &baseline, &scratch, null);

    // Cold memo: all five commands miss and compute — same bytes as
    // unmemoized.
    try frame.render(red, &pixels, &scratch, &memo);
    try std.testing.expectEqual(@as(u64, 0), memo.hits);
    try std.testing.expectEqual(@as(u64, 5), memo.misses);
    try std.testing.expectEqualSlices(u8, &baseline, &pixels);

    // Warm memo: every command hits — replayed bytes must be identical
    // too.
    try frame.render(red, &pixels, &scratch, &memo);
    try std.testing.expectEqual(@as(u64, 5), memo.hits);
    try std.testing.expectEqual(@as(u64, 5), memo.misses);
    try std.testing.expectEqualSlices(u8, &baseline, &pixels);

    // Changed content at the bottom of the stack: every layer above it
    // reads different source bytes, so all five must MISS (stale pixels
    // would be wrong) and match the unmemoized render of the new
    // content.
    const green = Color.rgb8(0, 255, 0);
    var changed_baseline: [8 * 8 * 4]u8 = undefined;
    try frame.render(green, &changed_baseline, &scratch, null);
    try frame.render(green, &pixels, &scratch, &memo);
    try std.testing.expectEqual(@as(u64, 5), memo.hits);
    try std.testing.expectEqual(@as(u64, 10), memo.misses);
    try std.testing.expectEqualSlices(u8, &changed_baseline, &pixels);
}

test "reference renderer blurs transparent colors without dark fringes" {
    const commands = [_]CanvasCommand{
        .{ .fill_rect = .{
            .id = 1,
            .rect = geometry.RectF.init(0, 0, 1, 1),
            .fill = .{ .color = Color.rgba8(255, 0, 0, 128) },
        } },
        .{ .blur = .{
            .id = 2,
            .rect = geometry.RectF.init(0, 0, 3, 1),
            .radius = 1,
        } },
    };

    var render_commands: [2]RenderCommand = undefined;
    var render_batches: [2]RenderBatch = undefined;
    var resources: [1]RenderResource = undefined;
    var resource_cache_entries: [1]RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [1]RenderResourceCacheAction = undefined;
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [0]DiffChange = .{};
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .surface_size = geometry.SizeF.init(3, 1),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    var pixels: [3 * 1 * 4]u8 = undefined;
    var scratch: [3 * 1 * 4]u8 = undefined;
    const surface = try ReferenceRenderSurface.initWithScratch(3, 1, &pixels, &scratch);
    try surface.renderPass(frame.renderPass(), Color.rgba8(0, 0, 0, 0));

    try expectPixelRgba8(.{ 255, 0, 0, 80 }, surface, 0, 0);
    try expectPixelRgba8(.{ 255, 0, 0, 35 }, surface, 1, 0);
    try expectPixelRgba8(.{ 0, 0, 0, 0 }, surface, 2, 0);
}

test "reference renderer draws proxy text runs" {
    const commands = [_]CanvasCommand{.{ .draw_text = .{
        .id = 1,
        .size = 2,
        .origin = geometry.PointF.init(1, 3),
        .color = Color.rgb8(255, 0, 0),
        .text = "A B",
    } }};

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [1]RenderResource = undefined;
    var resource_cache_entries: [1]RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [1]RenderResourceCacheAction = undefined;
    var glyphs: [3]GlyphAtlasEntry = undefined;
    var glyph_cache_entries: [3]GlyphAtlasCacheEntry = undefined;
    var glyph_cache_actions: [3]GlyphAtlasCacheAction = undefined;
    var changes: [0]DiffChange = .{};
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .surface_size = geometry.SizeF.init(5, 4),
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

    var pixels: [5 * 4 * 4]u8 = undefined;
    const surface = try ReferenceRenderSurface.init(5, 4, &pixels);
    try surface.renderPass(frame.renderPass(), Color.rgb8(0, 0, 0));

    // Real Geist outlines walk estimator advances: 'A' inks column 1,
    // the space keeps column 2 empty, 'B' inks column 3 and ends inside
    // its estimator box (column 4 stays background). Values are exact
    // 2px-em anti-aliased coverage.
    try expectPixelRgba8(.{ 39, 0, 0, 255 }, surface, 1, 1);
    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 2, 1);
    try expectPixelRgba8(.{ 72, 0, 0, 255 }, surface, 3, 1);
    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 4, 1);
    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 1, 3);
}

test "reference renderer advances proxy text by utf8 scalars" {
    const commands = [_]CanvasCommand{.{ .draw_text = .{
        .id = 1,
        .size = 2,
        .origin = geometry.PointF.init(1, 3),
        .color = Color.rgb8(255, 0, 0),
        .text = "é B",
    } }};

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [1]RenderResource = undefined;
    var resource_cache_entries: [1]RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [1]RenderResourceCacheAction = undefined;
    var glyphs: [4]GlyphAtlasEntry = undefined;
    var glyph_cache_entries: [4]GlyphAtlasCacheEntry = undefined;
    var glyph_cache_actions: [4]GlyphAtlasCacheAction = undefined;
    var changes: [0]DiffChange = .{};
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .surface_size = geometry.SizeF.init(5, 4),
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

    var pixels: [5 * 4 * 4]u8 = undefined;
    const surface = try ReferenceRenderSurface.init(5, 4, &pixels);
    try surface.renderPass(frame.renderPass(), Color.rgb8(0, 0, 0));

    // Real outlines walking the face's real advances: the composite
    // 'e-acute' inks column 1 (11 at this row; its accent shows stronger
    // one row down) and 'B' lands one scalar advance later — é now
    // measures its true 0.567 em, so 'B' starts a third of a pixel
    // earlier than under the old flat multibyte estimate but still
    // proves multi-byte input advances once per scalar, not per byte.
    try expectPixelRgba8(.{ 11, 0, 0, 255 }, surface, 1, 1);
    try expectPixelRgba8(.{ 23, 0, 0, 255 }, surface, 2, 1);
    try expectPixelRgba8(.{ 49, 0, 0, 255 }, surface, 3, 1);
    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 4, 1);
}

test "reference renderer inks mono runs with the bundled mono face" {
    // Mono runs ink the bundled Geist Mono outlines at the 0.6 em pitch
    // layout charges. Before the mono face landed, mono ids borrowed the
    // proportional sans outlines centered in the cell: narrow 'i' floated
    // in gulfs while wide 'M' (~0.83 em) overflowed its cell into the
    // next glyph. At size 20 the cell is 12 px; the mono 'i' is designed
    // for the cell (serif base, ~9.6 px of ink) and 'M' stays inside its
    // own 12 px column.
    const size: f32 = 20;
    const cell: usize = 12; // 0.6 em at size 20
    const commands = [_]CanvasCommand{.{ .draw_text = .{
        .id = 1,
        .font_id = default_mono_font_id,
        .size = size,
        .origin = geometry.PointF.init(0, 20),
        .color = Color.rgb8(255, 0, 0),
        .text = "iM",
    } }};

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [1]RenderResource = undefined;
    var resource_cache_entries: [1]RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [1]RenderResourceCacheAction = undefined;
    var glyphs: [2]GlyphAtlasEntry = undefined;
    var glyph_cache_entries: [2]GlyphAtlasCacheEntry = undefined;
    var glyph_cache_actions: [2]GlyphAtlasCacheAction = undefined;
    var changes: [0]DiffChange = .{};
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .surface_size = geometry.SizeF.init(26, 24),
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

    var pixels: [26 * 24 * 4]u8 = undefined;
    const surface = try ReferenceRenderSurface.init(26, 24, &pixels);
    try surface.renderPass(frame.renderPass(), Color.rgb8(0, 0, 0));

    // Per-cell ink extents: any red coverage in a column marks it inked.
    var ink_width: [2]usize = .{ 0, 0 };
    for (0..2) |cell_index| {
        const cell_start = cell_index * cell;
        var first_ink: ?usize = null;
        var last_ink: usize = 0;
        for (cell_start..cell_start + cell) |x| {
            var inked = false;
            for (0..24) |y| {
                if (pixels[(y * 26 + x) * 4] != 0) {
                    inked = true;
                    break;
                }
            }
            if (inked) {
                if (first_ink == null) first_ink = x - cell_start;
                last_ink = x - cell_start;
            }
        }
        const first = first_ink orelse return error.TestUnexpectedResult;
        ink_width[cell_index] = last_ink + 1 - first;
    }
    // The mono 'i' fills most of its fixed cell (the centered sans 'i'
    // inked ~4.5 px; the mono design carries a serif base of ~9.6 px).
    try std.testing.expect(ink_width[0] >= 8);
    // 'M' inks wide but INSIDE its own cell: with the sans outlines it
    // overflowed 0.83 em of ink into the pixels past both cells.
    try std.testing.expect(ink_width[1] >= 8);
    for (2 * cell..26) |x| {
        for (0..24) |y| {
            try std.testing.expectEqual(@as(u8, 0), pixels[(y * 26 + x) * 4]);
        }
    }
}

test "reference renderer applies shaped glyph y offsets" {
    const shaped_glyphs = [_]Glyph{.{ .id = 1, .x = 0, .y = 1, .advance = 1 }};
    const commands = [_]CanvasCommand{.{ .draw_text = .{
        .id = 1,
        .font_id = 2,
        .size = 2,
        .origin = geometry.PointF.init(1, 3),
        .color = Color.rgb8(255, 0, 0),
        .glyphs = &shaped_glyphs,
    } }};

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [1]RenderResource = undefined;
    var resource_cache_entries: [1]RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [1]RenderResourceCacheAction = undefined;
    var glyphs: [1]GlyphAtlasEntry = undefined;
    var glyph_cache_entries: [1]GlyphAtlasCacheEntry = undefined;
    var glyph_cache_actions: [1]GlyphAtlasCacheAction = undefined;
    var changes: [0]DiffChange = .{};
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .surface_size = geometry.SizeF.init(4, 5),
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

    var pixels: [4 * 5 * 4]u8 = undefined;
    const surface = try ReferenceRenderSurface.init(4, 5, &pixels);
    try surface.renderPass(frame.renderPass(), Color.rgb8(0, 0, 0));

    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 1, 1);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 1, 2);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 1, 3);
}

test "reference renderer draws image resources" {
    const commands = [_]CanvasCommand{.{ .draw_image = .{
        .id = 1,
        .image_id = 42,
        .dst = geometry.RectF.init(0, 0, 4, 4),
        .fit = .contain,
    } }};
    const image_pixels = [_]u8{
        255, 0, 0,   255,
        0,   0, 255, 255,
    };
    const images = [_]ReferenceImage{.{
        .id = 42,
        .width = 2,
        .height = 1,
        .pixels = &image_pixels,
    }};

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [1]RenderResource = undefined;
    var resource_cache_entries: [1]RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [1]RenderResourceCacheAction = undefined;
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [0]DiffChange = .{};
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .surface_size = geometry.SizeF.init(4, 4),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    var pixels: [4 * 4 * 4]u8 = undefined;
    const surface = (try ReferenceRenderSurface.init(4, 4, &pixels)).withImages(&images);
    try surface.renderPass(frame.renderPass(), Color.rgb8(0, 0, 0));

    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 0, 0);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 0, 1);
    try expectPixelRgba8(.{ 225, 0, 137, 255 }, surface, 1, 1);
    try expectPixelRgba8(.{ 137, 0, 225, 255 }, surface, 2, 1);
    try expectPixelRgba8(.{ 0, 0, 255, 255 }, surface, 3, 2);
    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 0, 3);
}

test "reference renderer bilinear-filters scaled images" {
    const commands = [_]CanvasCommand{.{ .draw_image = .{
        .id = 1,
        .image_id = 42,
        .dst = geometry.RectF.init(0, 0, 4, 4),
    } }};
    const image_pixels = [_]u8{
        255, 0,   0,   255,
        0,   255, 0,   255,
        0,   0,   255, 255,
        255, 255, 255, 255,
    };
    const images = [_]ReferenceImage{.{
        .id = 42,
        .width = 2,
        .height = 2,
        .pixels = &image_pixels,
    }};

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [1]RenderResource = undefined;
    var resource_cache_entries: [1]RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [1]RenderResourceCacheAction = undefined;
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [0]DiffChange = .{};
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .surface_size = geometry.SizeF.init(4, 4),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    var pixels: [4 * 4 * 4]u8 = undefined;
    const surface = (try ReferenceRenderSurface.init(4, 4, &pixels)).withImages(&images);
    try surface.renderPass(frame.renderPass(), Color.rgb8(0, 0, 0));

    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 0, 0);
    try expectPixelRgba8(.{ 207, 137, 137, 255 }, surface, 1, 1);
    try expectPixelRgba8(.{ 207, 225, 225, 255 }, surface, 2, 2);
    try expectPixelRgba8(.{ 255, 255, 255, 255 }, surface, 3, 3);
}

test "reference renderer nearest-filters scaled images" {
    const commands = [_]CanvasCommand{.{ .draw_image = .{
        .id = 1,
        .image_id = 42,
        .dst = geometry.RectF.init(0, 0, 4, 4),
        .sampling = .nearest,
    } }};
    const image_pixels = [_]u8{
        255, 0,   0,   255,
        0,   255, 0,   255,
        0,   0,   255, 255,
        255, 255, 255, 255,
    };
    const images = [_]ReferenceImage{.{
        .id = 42,
        .width = 2,
        .height = 2,
        .pixels = &image_pixels,
    }};

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [1]RenderResource = undefined;
    var resource_cache_entries: [1]RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [1]RenderResourceCacheAction = undefined;
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [0]DiffChange = .{};
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .surface_size = geometry.SizeF.init(4, 4),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    var pixels: [4 * 4 * 4]u8 = undefined;
    const surface = (try ReferenceRenderSurface.init(4, 4, &pixels)).withImages(&images);
    try surface.renderPass(frame.renderPass(), Color.rgb8(0, 0, 0));

    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 0, 0);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 1, 1);
    try expectPixelRgba8(.{ 255, 255, 255, 255 }, surface, 2, 2);
    try expectPixelRgba8(.{ 255, 255, 255, 255 }, surface, 3, 3);
}

test "reference renderer filters scaled image alpha premultiplied" {
    const commands = [_]CanvasCommand{.{ .draw_image = .{
        .id = 1,
        .image_id = 42,
        .dst = geometry.RectF.init(0, 0, 4, 1),
    } }};
    const image_pixels = [_]u8{
        255, 0, 0,   255,
        0,   0, 255, 0,
    };
    const images = [_]ReferenceImage{.{
        .id = 42,
        .width = 2,
        .height = 1,
        .pixels = &image_pixels,
    }};

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [1]RenderResource = undefined;
    var resource_cache_entries: [1]RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [1]RenderResourceCacheAction = undefined;
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [0]DiffChange = .{};
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .surface_size = geometry.SizeF.init(4, 1),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    var pixels: [4 * 1 * 4]u8 = undefined;
    const surface = (try ReferenceRenderSurface.init(4, 1, &pixels)).withImages(&images);
    try surface.renderPass(frame.renderPass(), Color.rgba8(0, 0, 0, 0));

    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 0, 0);
    try expectPixelRgba8(.{ 255, 0, 0, 191 }, surface, 1, 0);
    try expectPixelRgba8(.{ 255, 0, 0, 64 }, surface, 2, 0);
    try expectPixelRgba8(.{ 0, 0, 0, 0 }, surface, 3, 0);
}

test "reference renderer skips absent images and rejects corrupt ones" {
    const commands = [_]CanvasCommand{.{ .draw_image = .{
        .id = 1,
        .image_id = 42,
        .dst = geometry.RectF.init(0, 0, 2, 2),
    } }};

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [1]RenderResource = undefined;
    var resource_cache_entries: [1]RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [1]RenderResourceCacheAction = undefined;
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [0]DiffChange = .{};
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .surface_size = geometry.SizeF.init(2, 2),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    // An id with no matching resource is a legitimate transient state
    // (runtime-registered image mid-fetch or just unregistered): the draw
    // skips, presentation succeeds, the clear color shows through.
    var pixels: [2 * 2 * 4]u8 = undefined;
    const surface = try ReferenceRenderSurface.init(2, 2, &pixels);
    try surface.renderPass(frame.renderPass(), Color.rgb8(7, 8, 9));
    try expectPixelRgba8(.{ 7, 8, 9, 255 }, surface, 0, 0);
    try expectPixelRgba8(.{ 7, 8, 9, 255 }, surface, 1, 1);

    // A PRESENT resource with an undersized pixel buffer is corrupt, not
    // transient: still a loud error.
    const corrupt_pixels = [_]u8{ 255, 0, 0, 255 };
    const corrupt = [_]ReferenceImage{.{ .id = 42, .width = 2, .height = 2, .pixels = &corrupt_pixels }};
    const corrupt_surface = (try ReferenceRenderSurface.init(2, 2, &pixels)).withImages(&corrupt);
    try std.testing.expectError(error.ReferenceRenderUnsupportedCommand, corrupt_surface.renderPass(frame.renderPass(), Color.rgb8(0, 0, 0)));
}

test "reference renderer scale-once image panels replay byte-identical samples at any position with the same phase" {
    // The scaled-image panel is pure memoization: at integer device
    // alignment a destination pixel's sample depends only on its offset
    // inside the destination rect, so the panel must produce the same
    // bytes as direct sampling — cold, warm, AND after the draw moves to
    // a different integer position (the position-independence that makes
    // scrolling grids cheap). Fractional alignment must bypass the panel
    // entirely, and changed image content must miss.
    const Scene = struct {
        fn render(dst: geometry.RectF, images: []const ReferenceImage, pixels: []u8, memo: ?*canvas.ReferenceRenderMemo) !void {
            const commands = [_]CanvasCommand{.{ .draw_image = .{
                .id = 1,
                .image_id = 7,
                .dst = dst,
                .fit = .cover,
                .sampling = .linear,
                .radius = Radius.all(2),
            } }};
            var render_commands: [1]RenderCommand = undefined;
            const plan = try (DisplayList{ .commands = &commands }).renderPlan(&render_commands);
            const surface = (try ReferenceRenderSurface.init(32, 32, pixels)).withImages(images).withRenderMemo(memo);
            try surface.renderPass(.{
                .surface_size = geometry.SizeF.init(32, 32),
                .scale = 1,
                .full_repaint = true,
                .commands = plan.commands,
            }, Color.rgb8(9, 12, 20));
        }
    };

    var image_pixels: [8 * 8 * 4]u8 = undefined;
    for (&image_pixels, 0..) |*byte, index| byte.* = @intCast((index * 37 + 11) % 256);
    for (0..8 * 8) |pixel| image_pixels[pixel * 4 + 3] = 255;
    const images = [_]ReferenceImage{.{ .id = 7, .width = 8, .height = 8, .pixels = &image_pixels }};

    var memo = canvas.ReferenceRenderMemo.init(std.testing.allocator);
    defer memo.deinit();
    // The production threshold skips small draws; the test panel is
    // tiny, so cache everything.
    memo.min_pixels = 0;

    var baseline: [32 * 32 * 4]u8 = undefined;
    var pixels: [32 * 32 * 4]u8 = undefined;

    // Cold panel: one miss, bytes equal the unmemoized render.
    const first_rect = geometry.RectF.init(2, 3, 16, 16);
    try Scene.render(first_rect, &images, &baseline, null);
    try Scene.render(first_rect, &images, &pixels, &memo);
    try std.testing.expectEqual(@as(u64, 0), memo.image_scale_hits);
    try std.testing.expectEqual(@as(u64, 1), memo.image_scale_misses);
    try std.testing.expectEqualSlices(u8, &baseline, &pixels);

    // Warm panel at the same position.
    try Scene.render(first_rect, &images, &pixels, &memo);
    try std.testing.expectEqual(@as(u64, 1), memo.image_scale_hits);
    try std.testing.expectEqualSlices(u8, &baseline, &pixels);

    // Moved to a different INTEGER position: still a hit (the panel is
    // position-independent), and still byte-identical to the direct
    // render at the new position.
    const moved_rect = geometry.RectF.init(11, 9, 16, 16);
    try Scene.render(moved_rect, &images, &baseline, null);
    try Scene.render(moved_rect, &images, &pixels, &memo);
    try std.testing.expectEqual(@as(u64, 2), memo.image_scale_hits);
    try std.testing.expectEqual(@as(u64, 1), memo.image_scale_misses);
    try std.testing.expectEqualSlices(u8, &baseline, &pixels);

    // A FRACTIONAL position keys a different subpixel phase: a fresh
    // panel fills (miss) and its bytes still equal direct sampling.
    const fractional_rect = geometry.RectF.init(2.5, 3.25, 16, 16);
    try Scene.render(fractional_rect, &images, &baseline, null);
    try Scene.render(fractional_rect, &images, &pixels, &memo);
    try std.testing.expectEqual(@as(u64, 2), memo.image_scale_hits);
    try std.testing.expectEqual(@as(u64, 2), memo.image_scale_misses);
    try std.testing.expectEqualSlices(u8, &baseline, &pixels);

    // Moved by WHOLE pixels from the fractional position (same phase):
    // a hit, byte-identical at the new position.
    const fractional_moved = geometry.RectF.init(6.5, 8.25, 16, 16);
    try Scene.render(fractional_moved, &images, &baseline, null);
    try Scene.render(fractional_moved, &images, &pixels, &memo);
    try std.testing.expectEqual(@as(u64, 3), memo.image_scale_hits);
    try std.testing.expectEqual(@as(u64, 2), memo.image_scale_misses);
    try std.testing.expectEqualSlices(u8, &baseline, &pixels);

    // Changed image content under the same id: the content hash moves,
    // so the draw misses and matches the direct render of the new
    // pixels.
    var changed_pixels: [8 * 8 * 4]u8 = undefined;
    for (&changed_pixels, 0..) |*byte, index| byte.* = @intCast((index * 53 + 5) % 256);
    for (0..8 * 8) |pixel| changed_pixels[pixel * 4 + 3] = 255;
    const changed_images = [_]ReferenceImage{.{ .id = 7, .width = 8, .height = 8, .pixels = &changed_pixels }};
    try Scene.render(first_rect, &changed_images, &baseline, null);
    try Scene.render(first_rect, &changed_images, &pixels, &memo);
    try std.testing.expectEqual(@as(u64, 3), memo.image_scale_hits);
    try std.testing.expectEqual(@as(u64, 3), memo.image_scale_misses);
    try std.testing.expectEqualSlices(u8, &baseline, &pixels);
}
