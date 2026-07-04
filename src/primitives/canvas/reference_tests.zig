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

    try std.testing.expectEqual(@as(u64, 12197497484215834747), referenceSurfaceSignature(&pixels));
    try expectVisiblePixel(surface.pixelRgba8(6, 6));
    try expectVisiblePixel(surface.pixelRgba8(20, 8));
    try expectVisiblePixel(surface.pixelRgba8(6, 16));
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

test "reference renderer strokes paths" {
    const elements = [_]PathElement{
        .{ .verb = .move_to, .points = .{ geometry.PointF.init(0.5, 1.5), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(2.5, 1.5), geometry.PointF.zero(), geometry.PointF.zero() } },
    };
    const commands = [_]CanvasCommand{.{ .stroke_path = .{
        .id = 1,
        .elements = &elements,
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
    // The round end cap only partially covers the pixel left of the
    // segment start; the anti-aliased vector core reports 75% coverage
    // there (the historical point-sampled renderer filled it solid).
    try expectPixelRgba8(.{ 191, 0, 0, 255 }, surface, 0, 1);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 1, 1);
    try expectPixelRgba8(.{ 191, 0, 0, 255 }, surface, 2, 1);
    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 3, 1);
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

test "reference renderer centers mono glyph ink inside the fixed pitch cell" {
    // No mono face is bundled: mono runs charge a fixed 0.6 em cell and
    // ink the bundled SANS outline. Left-aligned ink read as clumps with
    // stray gaps ("i nl i ne"); real mono faces center narrow glyphs in
    // the cell, so the reference render must too. At size 20 the cell is
    // 12 px; sans 'i' ink is ~4.5 px wide, so centered ink starts ~3 px in
    // and ends ~3 px short — never hugging either cell edge.
    const size: f32 = 20;
    const cell: usize = 12; // 0.6 em at size 20
    const commands = [_]CanvasCommand{.{ .draw_text = .{
        .id = 1,
        .font_id = default_mono_font_id,
        .size = size,
        .origin = geometry.PointF.init(0, 20),
        .color = Color.rgb8(255, 0, 0),
        .text = "il",
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
        // Ink exists and sits centered: at least 2 px of cell padding on
        // each side (left-aligned ink starts at column 0/1 and fails).
        const first = first_ink orelse return error.TestUnexpectedResult;
        try std.testing.expect(first >= 2);
        try std.testing.expect(last_ink <= cell - 3);
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
