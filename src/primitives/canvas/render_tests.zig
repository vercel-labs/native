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

test "builder records replayable commands" {
    var commands: [8]CanvasCommand = undefined;
    var builder = Builder.init(&commands);

    try builder.pushClip(.{ .id = 1, .rect = geometry.RectF.init(0, 0, 320, 240), .radius = Radius.all(8) });
    try builder.pushOpacity(0.75);
    try builder.fillRoundedRect(.{
        .id = 2,
        .rect = geometry.RectF.init(12, 16, 180, 96),
        .radius = Radius.all(12),
        .fill = .{ .color = Color.rgb8(17, 24, 39) },
    });
    try builder.popOpacity();
    try builder.popClip();

    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 5), display_list.commandCount());
    try std.testing.expect(display_list.commands[0] == .push_clip);
    try std.testing.expect(display_list.commands[2] == .fill_rounded_rect);
}

test "builder reports fixed buffer overflow" {
    var commands: [1]CanvasCommand = undefined;
    var builder = Builder.init(&commands);

    try builder.pushOpacity(1);
    try std.testing.expectError(error.DisplayListFull, builder.popOpacity());
}

test "display list finds commands and computes conservative bounds" {
    const path = [_]PathElement{
        .{ .verb = .move_to, .points = .{ geometry.PointF.init(5, 5), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .cubic_to, .points = .{ geometry.PointF.init(15, 30), geometry.PointF.init(20, 0), geometry.PointF.init(35, 35) } },
        .{ .verb = .close },
    };

    var commands: [3]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try builder.strokeRect(.{
        .id = 1,
        .rect = geometry.RectF.init(10, 10, 100, 40),
        .stroke = .{ .fill = .{ .color = Color.rgb8(0, 0, 0) }, .width = 4 },
    });
    try builder.fillPath(.{
        .id = 2,
        .elements = &path,
        .fill = .{ .color = Color.rgb8(255, 255, 255) },
    });
    try builder.shadow(.{
        .id = 3,
        .rect = geometry.RectF.init(20, 20, 40, 20),
        .offset = .{ .dx = 0, .dy = 8 },
        .blur = 12,
        .spread = -4,
        .color = Color.rgba8(0, 0, 0, 64),
    });

    const display_list = builder.displayList();
    const path_ref = display_list.findCommandById(2).?;
    try std.testing.expectEqual(@as(usize, 1), path_ref.index);
    try std.testing.expectEqual(@as(?ObjectId, 2), path_ref.command.objectId());
    try std.testing.expect(display_list.findCommandById(99) == null);

    try expectRect(geometry.RectF.init(8, 8, 104, 44), display_list.commands[0].bounds());
    try expectRect(geometry.RectF.init(5, 0, 30, 35), display_list.commands[1].bounds());
    try expectRect(geometry.RectF.init(4, 12, 72, 52), display_list.commands[2].bounds());
    try expectRect(geometry.RectF.init(4, 0, 108, 64), display_list.bounds());
}

test "display list diffs changed added removed and unkeyed scene commands" {
    const previous_commands = [_]CanvasCommand{
        .{ .push_opacity = 1 },
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 100, 100), .fill = .{ .color = Color.rgb8(255, 255, 255) } } },
        .{ .fill_rect = .{ .id = 2, .rect = geometry.RectF.init(120, 0, 40, 40), .fill = .{ .color = Color.rgb8(17, 24, 39) } } },
        .{ .draw_image = .{ .id = 3, .image_id = 8, .dst = geometry.RectF.init(180, 0, 32, 32) } },
    };
    const next_commands = [_]CanvasCommand{
        .{ .push_opacity = 0.5 },
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(10, 0, 100, 100), .fill = .{ .color = Color.rgb8(255, 255, 255) } } },
        .{ .fill_rect = .{ .id = 2, .rect = geometry.RectF.init(120, 0, 40, 40), .fill = .{ .color = Color.rgb8(17, 24, 39) } } },
        .{ .blur = .{ .id = 4, .rect = geometry.RectF.init(220, 0, 24, 24), .radius = 6 } },
    };

    var changes: [8]DiffChange = undefined;
    const diff = try DisplayList.diff(.{ .commands = &previous_commands }, .{ .commands = &next_commands }, &changes);
    try std.testing.expectEqual(@as(usize, 4), diff.len);
    try std.testing.expectEqual(DiffKind.scene_changed, diff[0].kind);
    try std.testing.expectEqual(@as(?ObjectId, null), diff[0].id);
    try std.testing.expect(diff[0].dirty_bounds != null);
    try std.testing.expectEqual(DiffKind.changed, diff[1].kind);
    try std.testing.expectEqual(@as(?ObjectId, 1), diff[1].id);
    try std.testing.expectEqual(@as(?usize, 1), diff[1].previous_index);
    try std.testing.expectEqual(@as(?usize, 1), diff[1].next_index);
    try expectRect(geometry.RectF.init(0, 0, 110, 100), diff[1].dirty_bounds);
    try std.testing.expectEqual(DiffKind.removed, diff[2].kind);
    try std.testing.expectEqual(@as(?ObjectId, 3), diff[2].id);
    try expectRect(geometry.RectF.init(180, 0, 32, 32), diff[2].dirty_bounds);
    try std.testing.expectEqual(DiffKind.added, diff[3].kind);
    try std.testing.expectEqual(@as(?ObjectId, 4), diff[3].id);
    try expectRect(geometry.RectF.init(214, -6, 36, 36), diff[3].dirty_bounds);
}

test "display list diff treats empty transitions as full scene changes" {
    const commands = [_]CanvasCommand{.{ .draw_text = .{
        .id = 1,
        .origin = geometry.PointF.init(0, 16),
        .size = 13,
        .color = Color.rgb8(255, 255, 255),
        .text = "Initial retained canvas install",
        .text_layout = .{ .max_width = 140, .line_height = 18, .wrap = .word },
    } }};

    var changes: [2]DiffChange = undefined;
    const added = try DisplayList.diff(.{}, .{ .commands = &commands }, &changes);
    try std.testing.expectEqual(@as(usize, 1), added.len);
    try std.testing.expectEqual(DiffKind.scene_changed, added[0].kind);
    try std.testing.expectEqual(@as(?ObjectId, null), added[0].id);
    try std.testing.expectEqual(@as(?geometry.RectF, null), added[0].dirty_bounds);

    const removed = try DisplayList.diff(.{ .commands = &commands }, .{}, &changes);
    try std.testing.expectEqual(@as(usize, 1), removed.len);
    try std.testing.expectEqual(DiffKind.scene_changed, removed[0].kind);
    try std.testing.expectEqual(@as(?ObjectId, null), removed[0].id);
    try std.testing.expectEqual(@as(?geometry.RectF, null), removed[0].dirty_bounds);
}

test "display list diff ignores unchanged keyed commands" {
    const commands = [_]CanvasCommand{
        .{ .fill_rounded_rect = .{
            .id = 1,
            .rect = geometry.RectF.init(8, 8, 120, 40),
            .radius = Radius.all(10),
            .fill = .{ .color = Color.rgb8(15, 23, 42) },
        } },
    };

    var changes: [1]DiffChange = undefined;
    const diff = try DisplayList.diff(.{ .commands = &commands }, .{ .commands = &commands }, &changes);
    try std.testing.expectEqual(@as(usize, 0), diff.len);
}

test "display list diff rejects duplicate object ids" {
    const commands = [_]CanvasCommand{
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 10, 10), .fill = .{ .color = Color.rgb8(255, 255, 255) } } },
        .{ .blur = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 10, 10), .radius = 4 } },
    };

    var changes: [2]DiffChange = undefined;
    try std.testing.expectError(error.DuplicateObjectId, DisplayList.diff(.{ .commands = &commands }, .{}, &changes));
}

test "affine transforms points and conservative rect bounds" {
    const transform = Affine.translate(10, 5).multiply(Affine.scale(2, 3));
    try std.testing.expectEqualDeep(geometry.PointF.init(14, 14), transform.transformPoint(geometry.PointF.init(2, 3)));
    try std.testing.expectEqualDeep(geometry.RectF.init(10, 5, 20, 15), transform.transformRect(geometry.RectF.init(0, 0, 10, 5)));
    const inverse = transform.inverse().?;
    const restored = inverse.transformPoint(geometry.PointF.init(14, 14));
    try std.testing.expectApproxEqAbs(@as(f32, 2), restored.x, 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, 3), restored.y, 0.00001);
    try std.testing.expect(Affine.scale(0, 1).inverse() == null);
}

test "render plan resolves transform clip and opacity state" {
    const commands = [_]CanvasCommand{
        .{ .push_clip = .{ .id = 90, .rect = geometry.RectF.init(10, 10, 50, 50) } },
        .{ .push_opacity = 0.5 },
        .{ .transform = Affine.translate(10, 0) },
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 30, 30), .fill = .{ .color = Color.rgb8(255, 255, 255) } } },
        .pop_opacity,
        .{ .fill_rect = .{ .id = 2, .rect = geometry.RectF.init(0, 0, 4, 4), .fill = .{ .color = Color.rgb8(0, 0, 0) } } },
        .pop_clip,
        .{ .fill_rect = .{ .id = 3, .rect = geometry.RectF.init(0, 0, 4, 4), .fill = .{ .color = Color.rgb8(17, 24, 39) } } },
    };

    var render_commands: [4]RenderCommand = undefined;
    const plan = try (DisplayList{ .commands = &commands }).renderPlan(&render_commands);
    try std.testing.expectEqual(@as(usize, 2), plan.commandCount());

    try std.testing.expectEqual(@as(?ObjectId, 1), plan.commands[0].id);
    try std.testing.expectEqual(@as(f32, 0.5), plan.commands[0].opacity);
    try expectRect(geometry.RectF.init(10, 10, 50, 50), plan.commands[0].clip);
    try std.testing.expectEqualDeep(Affine.translate(10, 0), plan.commands[0].transform);
    try expectRect(geometry.RectF.init(0, 0, 30, 30), plan.commands[0].local_bounds);
    try std.testing.expectEqualDeep(geometry.RectF.init(10, 10, 30, 20), plan.commands[0].bounds);

    try std.testing.expectEqual(@as(?ObjectId, 3), plan.commands[1].id);
    try std.testing.expectEqual(@as(f32, 1), plan.commands[1].opacity);
    try std.testing.expect(plan.commands[1].clip == null);
    try std.testing.expectEqualDeep(Affine.translate(10, 0), plan.commands[1].transform);
    try expectRect(geometry.RectF.init(0, 0, 4, 4), plan.commands[1].local_bounds);
    try std.testing.expectEqualDeep(geometry.RectF.init(10, 0, 4, 4), plan.commands[1].bounds);
    try expectRect(geometry.RectF.init(10, 0, 30, 30), plan.bounds);
}

test "render plan reports output and stack errors" {
    const draw_commands = [_]CanvasCommand{
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 10, 10), .fill = .{ .color = Color.rgb8(255, 255, 255) } } },
    };
    var empty_render_commands: [0]RenderCommand = .{};
    try std.testing.expectError(error.RenderListFull, (DisplayList{ .commands = &draw_commands }).renderPlan(&empty_render_commands));

    const bad_clip_commands = [_]CanvasCommand{.pop_clip};
    var render_commands: [1]RenderCommand = undefined;
    try std.testing.expectError(error.RenderStackUnderflow, (DisplayList{ .commands = &bad_clip_commands }).renderPlan(&render_commands));

    const bad_opacity_commands = [_]CanvasCommand{.pop_opacity};
    try std.testing.expectError(error.RenderStackUnderflow, (DisplayList{ .commands = &bad_opacity_commands }).renderPlan(&render_commands));
}

test "render batch plan groups adjacent commands by pipeline and state" {
    const stops = [_]GradientStop{
        .{ .offset = 0, .color = Color.rgb8(255, 255, 255) },
        .{ .offset = 1, .color = Color.rgb8(24, 24, 27) },
    };
    const commands = [_]CanvasCommand{
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 20, 20), .fill = .{ .color = Color.rgb8(255, 255, 255) } } },
        .{ .fill_rounded_rect = .{ .id = 2, .rect = geometry.RectF.init(24, 0, 20, 20), .radius = Radius.all(4), .fill = .{ .color = Color.rgb8(24, 24, 27) } } },
        .{ .fill_rect = .{ .id = 3, .rect = geometry.RectF.init(48, 0, 20, 20), .fill = .{ .linear_gradient = .{
            .start = geometry.PointF.init(48, 0),
            .end = geometry.PointF.init(68, 20),
            .stops = &stops,
        } } } },
        .{ .draw_text = .{
            .id = 4,
            .font_id = 1,
            .size = 12,
            .origin = geometry.PointF.init(72, 18),
            .color = Color.rgb8(15, 23, 42),
            .text = "Hi",
        } },
    };

    var render_commands: [4]RenderCommand = undefined;
    const render_plan = try (DisplayList{ .commands = &commands }).renderPlan(&render_commands);
    var batches: [4]RenderBatch = undefined;
    const batch_plan = try render_plan.batchPlan(&batches);

    try std.testing.expectEqual(@as(usize, 3), batch_plan.batchCount());
    try std.testing.expectEqual(RenderPipelineKind.solid, batch_plan.batches[0].pipeline);
    try std.testing.expectEqual(@as(usize, 0), batch_plan.batches[0].command_start);
    try std.testing.expectEqual(@as(usize, 2), batch_plan.batches[0].command_count);
    try expectRect(geometry.RectF.init(0, 0, 44, 20), batch_plan.batches[0].bounds);
    try std.testing.expectEqual(RenderPipelineKind.linear_gradient, batch_plan.batches[1].pipeline);
    try std.testing.expectEqual(@as(usize, 2), batch_plan.batches[1].command_start);
    try std.testing.expectEqual(RenderPipelineKind.glyph_run, batch_plan.batches[2].pipeline);
    try std.testing.expectEqual(@as(usize, 3), batch_plan.batches[2].command_start);
    // Text command bounds carry the ink allowance (right 0.35em,
    // bottom/left 0.1em) past the metric box.
    try expectRectApprox(geometry.RectF.init(0, 0, 87.684, 22.2), batch_plan.bounds);
}

test "render batch plan respects clip opacity and output limits" {
    const commands = [_]CanvasCommand{
        .{ .push_opacity = 0.5 },
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 20, 20), .fill = .{ .color = Color.rgb8(255, 255, 255) } } },
        .pop_opacity,
        .{ .fill_rect = .{ .id = 2, .rect = geometry.RectF.init(24, 0, 20, 20), .fill = .{ .color = Color.rgb8(24, 24, 27) } } },
        .{ .push_clip = .{ .rect = geometry.RectF.init(48, 0, 20, 20) } },
        .{ .fill_rect = .{ .id = 3, .rect = geometry.RectF.init(48, 0, 20, 20), .fill = .{ .color = Color.rgb8(15, 23, 42) } } },
        .pop_clip,
    };

    var render_commands: [3]RenderCommand = undefined;
    const render_plan = try (DisplayList{ .commands = &commands }).renderPlan(&render_commands);
    var batches: [3]RenderBatch = undefined;
    const batch_plan = try render_plan.batchPlan(&batches);

    try std.testing.expectEqual(@as(usize, 3), batch_plan.batchCount());
    try std.testing.expectEqual(@as(f32, 0.5), batch_plan.batches[0].opacity);
    try std.testing.expect(batch_plan.batches[0].clip == null);
    try std.testing.expectEqual(@as(f32, 1), batch_plan.batches[1].opacity);
    try std.testing.expect(batch_plan.batches[1].clip == null);
    try expectRect(geometry.RectF.init(48, 0, 20, 20), batch_plan.batches[2].clip);

    var empty_batches: [0]RenderBatch = .{};
    try std.testing.expectError(error.RenderBatchListFull, render_plan.batchPlan(&empty_batches));
}

test "render path geometry plan estimates fill and stroke tessellation" {
    const path = [_]PathElement{
        .{ .verb = .move_to, .points = .{ geometry.PointF.init(0, 0), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(20, 0), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .quad_to, .points = .{ geometry.PointF.init(24, 16), geometry.PointF.init(12, 22), geometry.PointF.zero() } },
        .{ .verb = .cubic_to, .points = .{ geometry.PointF.init(8, 26), geometry.PointF.init(-4, 18), geometry.PointF.init(0, 0) } },
        .{ .verb = .close },
    };
    const commands = [_]CanvasCommand{
        .{ .fill_path = .{
            .id = 1,
            .elements = &path,
            .fill = .{ .color = Color.rgb8(255, 255, 255) },
        } },
        .{ .transform = Affine.scale(2, 2) },
        .{ .stroke_path = .{
            .id = 2,
            .elements = &path,
            .stroke = .{ .fill = .{ .color = Color.rgb8(24, 24, 27) }, .width = 2 },
        } },
    };

    var render_commands: [2]RenderCommand = undefined;
    const render_plan = try (DisplayList{ .commands = &commands }).renderPlan(&render_commands);
    var geometries: [2]RenderPathGeometry = undefined;
    const geometry_plan = try render_plan.pathGeometryPlan(&geometries);

    try std.testing.expectEqual(@as(usize, 2), geometry_plan.geometryCount());
    try std.testing.expectEqual(@as(usize, 130), geometry_plan.vertexCount());
    try std.testing.expectEqual(@as(usize, 228), geometry_plan.indexCount());

    try std.testing.expectEqual(RenderPathGeometryKind.fill, geometry_plan.geometries[0].kind);
    try std.testing.expectEqual(@as(?ObjectId, 1), geometry_plan.geometries[0].id);
    try std.testing.expectEqual(@as(usize, 0), geometry_plan.geometries[0].command_index);
    try std.testing.expectEqual(@as(usize, 5), geometry_plan.geometries[0].element_count);
    try std.testing.expectEqual(@as(usize, 1), geometry_plan.geometries[0].contour_count);
    try std.testing.expectEqual(@as(usize, 2), geometry_plan.geometries[0].line_segment_count);
    try std.testing.expectEqual(@as(usize, 1), geometry_plan.geometries[0].quadratic_segment_count);
    try std.testing.expectEqual(@as(usize, 1), geometry_plan.geometries[0].cubic_segment_count);
    try std.testing.expectEqual(@as(usize, 26), geometry_plan.geometries[0].flattened_segment_count);
    try std.testing.expectEqual(@as(usize, 26), geometry_plan.geometries[0].vertex_count);
    try std.testing.expectEqual(@as(usize, 72), geometry_plan.geometries[0].index_count);
    try std.testing.expectEqual(@as(f32, 0), geometry_plan.geometries[0].stroke_width);

    try std.testing.expectEqual(RenderPathGeometryKind.stroke, geometry_plan.geometries[1].kind);
    try std.testing.expectEqual(@as(?ObjectId, 2), geometry_plan.geometries[1].id);
    try std.testing.expectEqual(@as(usize, 1), geometry_plan.geometries[1].command_index);
    try std.testing.expectEqual(@as(usize, 26), geometry_plan.geometries[1].flattened_segment_count);
    try std.testing.expectEqual(@as(usize, 104), geometry_plan.geometries[1].vertex_count);
    try std.testing.expectEqual(@as(usize, 156), geometry_plan.geometries[1].index_count);
    try std.testing.expectEqual(@as(f32, 4), geometry_plan.geometries[1].stroke_width);
    try expectRect(geometry.RectF.init(-4, 0, 28, 26), geometry_plan.geometries[0].bounds);
    try expectRect(geometry.RectF.init(-10, -2, 60, 56), geometry_plan.geometries[1].bounds);
}

test "render path geometry fingerprint tracks geometry not paint" {
    const path = [_]PathElement{
        .{ .verb = .move_to, .points = .{ geometry.PointF.init(0, 0), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(20, 0), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(0, 20), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .close },
    };
    const changed_path = [_]PathElement{
        .{ .verb = .move_to, .points = .{ geometry.PointF.init(0, 0), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(24, 0), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(0, 20), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .close },
    };
    const commands = [_]CanvasCommand{.{ .fill_path = .{
        .id = 9,
        .elements = &path,
        .fill = .{ .color = Color.rgb8(255, 255, 255) },
    } }};
    const recolored_commands = [_]CanvasCommand{.{ .fill_path = .{
        .id = 9,
        .elements = &path,
        .fill = .{ .color = Color.rgb8(255, 0, 0) },
    } }};
    const reshaped_commands = [_]CanvasCommand{.{ .fill_path = .{
        .id = 9,
        .elements = &changed_path,
        .fill = .{ .color = Color.rgb8(255, 255, 255) },
    } }};

    var render_commands: [1]RenderCommand = undefined;
    const render_plan = try (DisplayList{ .commands = &commands }).renderPlan(&render_commands);
    var geometries: [1]RenderPathGeometry = undefined;
    const geometry_plan = try render_plan.pathGeometryPlan(&geometries);

    var recolored_render_commands: [1]RenderCommand = undefined;
    const recolored_render_plan = try (DisplayList{ .commands = &recolored_commands }).renderPlan(&recolored_render_commands);
    var recolored_geometries: [1]RenderPathGeometry = undefined;
    const recolored_geometry_plan = try recolored_render_plan.pathGeometryPlan(&recolored_geometries);

    var reshaped_render_commands: [1]RenderCommand = undefined;
    const reshaped_render_plan = try (DisplayList{ .commands = &reshaped_commands }).renderPlan(&reshaped_render_commands);
    var reshaped_geometries: [1]RenderPathGeometry = undefined;
    const reshaped_geometry_plan = try reshaped_render_plan.pathGeometryPlan(&reshaped_geometries);

    try std.testing.expectEqual(geometry_plan.geometries[0].fingerprint, recolored_geometry_plan.geometries[0].fingerprint);
    try std.testing.expect(geometry_plan.geometries[0].fingerprint != reshaped_geometry_plan.geometries[0].fingerprint);
}

test "render path geometry cache plan uploads retains and evicts geometries" {
    const previous_geometries = [_]RenderPathGeometry{
        .{ .kind = .fill, .command_index = 0, .id = 1, .bounds = geometry.RectF.init(0, 0, 20, 20), .vertex_count = 3, .index_count = 3, .fingerprint = 11 },
        .{ .kind = .stroke, .command_index = 1, .id = 2, .bounds = geometry.RectF.init(24, 0, 20, 20), .vertex_count = 4, .index_count = 6, .stroke_width = 2, .fingerprint = 22 },
    };
    var previous_entries: [2]RenderPathGeometryCacheEntry = undefined;
    var previous_actions: [2]RenderPathGeometryCacheAction = undefined;
    const previous_cache = try (RenderPathGeometryPlan{ .geometries = &previous_geometries }).cachePlan(&.{}, 1, &previous_entries, &previous_actions);
    try std.testing.expectEqual(@as(usize, 2), previous_cache.entryCount());
    try std.testing.expectEqual(@as(usize, 2), previous_cache.uploadCount());

    const next_geometries = [_]RenderPathGeometry{
        .{ .kind = .fill, .command_index = 0, .id = 1, .bounds = geometry.RectF.init(0, 0, 20, 20), .vertex_count = 3, .index_count = 3, .fingerprint = 11 },
        .{ .kind = .stroke, .command_index = 1, .id = 3, .bounds = geometry.RectF.init(48, 0, 20, 20), .vertex_count = 8, .index_count = 12, .stroke_width = 4, .fingerprint = 33 },
    };
    var next_entries: [2]RenderPathGeometryCacheEntry = undefined;
    var next_actions: [3]RenderPathGeometryCacheAction = undefined;
    const next_cache = try (RenderPathGeometryPlan{ .geometries = &next_geometries }).cachePlan(previous_cache.entries, 2, &next_entries, &next_actions);
    try std.testing.expectEqual(@as(usize, 2), next_cache.entryCount());
    try std.testing.expectEqual(@as(usize, 1), next_cache.retainCount());
    try std.testing.expectEqual(@as(usize, 1), next_cache.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), next_cache.evictCount());
    try std.testing.expectEqual(RenderPathGeometryCacheActionKind.retain, next_cache.actions[0].kind);
    try std.testing.expectEqual(@as(?ObjectId, 1), next_cache.actions[0].key.id);
    try std.testing.expectEqual(RenderPathGeometryCacheActionKind.upload, next_cache.actions[1].kind);
    try std.testing.expectEqual(@as(?ObjectId, 3), next_cache.actions[1].key.id);
    try std.testing.expectEqual(RenderPathGeometryCacheActionKind.evict, next_cache.actions[2].kind);
    try std.testing.expectEqual(@as(?ObjectId, 2), next_cache.actions[2].key.id);
}

test "render path geometry plans report output overflow" {
    const path = [_]PathElement{
        .{ .verb = .move_to, .points = .{ geometry.PointF.init(0, 0), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(20, 0), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(0, 20), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .close },
    };
    const commands = [_]CanvasCommand{.{ .fill_path = .{
        .id = 1,
        .elements = &path,
        .fill = .{ .color = Color.rgb8(255, 255, 255) },
    } }};

    var render_commands: [1]RenderCommand = undefined;
    const render_plan = try (DisplayList{ .commands = &commands }).renderPlan(&render_commands);
    var no_geometries: [0]RenderPathGeometry = .{};
    try std.testing.expectError(error.PathGeometryListFull, render_plan.pathGeometryPlan(&no_geometries));

    const geometries = [_]RenderPathGeometry{.{ .kind = .fill, .command_index = 0, .id = 1, .bounds = geometry.RectF.init(0, 0, 20, 20), .vertex_count = 3, .index_count = 3, .fingerprint = 11 }};
    var no_entries: [0]RenderPathGeometryCacheEntry = .{};
    var actions: [1]RenderPathGeometryCacheAction = undefined;
    try std.testing.expectError(error.PathGeometryCacheListFull, (RenderPathGeometryPlan{ .geometries = &geometries }).cachePlan(&.{}, 1, &no_entries, &actions));

    var entries: [1]RenderPathGeometryCacheEntry = undefined;
    var no_actions: [0]RenderPathGeometryCacheAction = .{};
    try std.testing.expectError(error.PathGeometryCacheListFull, (RenderPathGeometryPlan{ .geometries = &geometries }).cachePlan(&.{}, 1, &entries, &no_actions));
}

test "render layer plan groups composited commands by state" {
    const commands = [_]CanvasCommand{
        .{ .push_opacity = 0.5 },
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 20, 20), .fill = .{ .color = Color.rgb8(255, 255, 255) } } },
        .{ .fill_rect = .{ .id = 2, .rect = geometry.RectF.init(24, 0, 20, 20), .fill = .{ .color = Color.rgb8(24, 24, 27) } } },
        .pop_opacity,
        .{ .push_clip = .{ .rect = geometry.RectF.init(48, 0, 20, 20) } },
        .{ .fill_rect = .{ .id = 3, .rect = geometry.RectF.init(48, 0, 20, 20), .fill = .{ .color = Color.rgb8(15, 23, 42) } } },
        .pop_clip,
        .{ .transform = Affine.translate(10, 0) },
        .{ .fill_rect = .{ .id = 4, .rect = geometry.RectF.init(72, 0, 20, 20), .fill = .{ .color = Color.rgb8(37, 99, 235) } } },
    };

    var render_commands: [4]RenderCommand = undefined;
    const render_plan = try (DisplayList{ .commands = &commands }).renderPlan(&render_commands);
    var layers: [3]RenderLayer = undefined;
    const layer_plan = try render_plan.layerPlan(&layers);

    try std.testing.expectEqual(@as(usize, 3), layer_plan.layerCount());
    try std.testing.expectEqual(@as(usize, 1), layer_plan.opacityLayerCount());
    try std.testing.expectEqual(@as(usize, 1), layer_plan.clipLayerCount());
    try std.testing.expectEqual(@as(usize, 1), layer_plan.transformLayerCount());
    try std.testing.expectEqual(@as(usize, 0), layer_plan.layers[0].command_start);
    try std.testing.expectEqual(@as(usize, 2), layer_plan.layers[0].command_count);
    try std.testing.expect(layer_plan.layers[0].id == null);
    try std.testing.expectEqual(@as(f32, 0.5), layer_plan.layers[0].opacity);
    try expectRect(geometry.RectF.init(0, 0, 44, 20), layer_plan.layers[0].bounds);
    try std.testing.expectEqual(@as(?ObjectId, 3), layer_plan.layers[1].id);
    try expectRect(geometry.RectF.init(48, 0, 20, 20), layer_plan.layers[1].clip);
    try std.testing.expectEqual(@as(?ObjectId, 4), layer_plan.layers[2].id);
    try std.testing.expectEqualDeep(Affine.translate(10, 0), layer_plan.layers[2].transform);
    try expectRect(geometry.RectF.init(82, 0, 20, 20), layer_plan.layers[2].bounds);

    const changed_commands = [_]CanvasCommand{
        .{ .push_opacity = 0.5 },
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 20, 20), .fill = .{ .color = Color.rgb8(255, 0, 0) } } },
        .{ .fill_rect = .{ .id = 2, .rect = geometry.RectF.init(24, 0, 20, 20), .fill = .{ .color = Color.rgb8(24, 24, 27) } } },
        .pop_opacity,
    };
    var changed_render_commands: [2]RenderCommand = undefined;
    const changed_render_plan = try (DisplayList{ .commands = &changed_commands }).renderPlan(&changed_render_commands);
    var changed_layers: [1]RenderLayer = undefined;
    const changed_layer_plan = try changed_render_plan.layerPlan(&changed_layers);
    try std.testing.expect(layer_plan.layers[0].fingerprint != changed_layer_plan.layers[0].fingerprint);
}

test "render layer cache plan uploads retains and evicts layers" {
    const previous_layers = [_]RenderLayer{
        .{ .command_start = 0, .command_count = 1, .id = 1, .bounds = geometry.RectF.init(0, 0, 20, 20), .opacity = 0.5, .fingerprint = 11 },
        .{ .command_start = 1, .command_count = 1, .id = 2, .bounds = geometry.RectF.init(24, 0, 20, 20), .clip = geometry.RectF.init(24, 0, 20, 20), .fingerprint = 22 },
    };
    var previous_entries: [2]RenderLayerCacheEntry = undefined;
    var previous_actions: [2]RenderLayerCacheAction = undefined;
    const previous_cache = try (RenderLayerPlan{ .layers = &previous_layers }).cachePlan(&.{}, 1, &previous_entries, &previous_actions);
    try std.testing.expectEqual(@as(usize, 2), previous_cache.entryCount());
    try std.testing.expectEqual(@as(usize, 2), previous_cache.uploadCount());

    const next_layers = [_]RenderLayer{
        .{ .command_start = 0, .command_count = 1, .id = 1, .bounds = geometry.RectF.init(0, 0, 20, 20), .opacity = 0.5, .fingerprint = 11 },
        .{ .command_start = 1, .command_count = 1, .id = 3, .bounds = geometry.RectF.init(48, 0, 20, 20), .transform = Affine.translate(10, 0), .fingerprint = 33 },
    };
    var next_entries: [2]RenderLayerCacheEntry = undefined;
    var next_actions: [3]RenderLayerCacheAction = undefined;
    const next_cache = try (RenderLayerPlan{ .layers = &next_layers }).cachePlan(previous_cache.entries, 2, &next_entries, &next_actions);
    try std.testing.expectEqual(@as(usize, 2), next_cache.entryCount());
    try std.testing.expectEqual(@as(usize, 1), next_cache.retainCount());
    try std.testing.expectEqual(@as(usize, 1), next_cache.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), next_cache.evictCount());
    try std.testing.expectEqual(RenderLayerCacheActionKind.retain, next_cache.actions[0].kind);
    try std.testing.expectEqual(@as(?ObjectId, 1), next_cache.actions[0].key.id);
    try std.testing.expectEqual(RenderLayerCacheActionKind.upload, next_cache.actions[1].kind);
    try std.testing.expectEqual(@as(?ObjectId, 3), next_cache.actions[1].key.id);
    try std.testing.expectEqual(RenderLayerCacheActionKind.evict, next_cache.actions[2].kind);
    try std.testing.expectEqual(@as(?ObjectId, 2), next_cache.actions[2].key.id);
}

test "render layer plans report output overflow" {
    const commands = [_]CanvasCommand{
        .{ .push_opacity = 0.5 },
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 20, 20), .fill = .{ .color = Color.rgb8(255, 255, 255) } } },
        .pop_opacity,
    };
    var render_commands: [1]RenderCommand = undefined;
    const render_plan = try (DisplayList{ .commands = &commands }).renderPlan(&render_commands);
    var no_layers: [0]RenderLayer = .{};
    try std.testing.expectError(error.LayerListFull, render_plan.layerPlan(&no_layers));

    const layers = [_]RenderLayer{.{ .command_start = 0, .command_count = 1, .id = 1, .bounds = geometry.RectF.init(0, 0, 20, 20), .opacity = 0.5, .fingerprint = 11 }};
    var no_entries: [0]RenderLayerCacheEntry = .{};
    var actions: [1]RenderLayerCacheAction = undefined;
    try std.testing.expectError(error.LayerCacheListFull, (RenderLayerPlan{ .layers = &layers }).cachePlan(&.{}, 1, &no_entries, &actions));

    var entries: [1]RenderLayerCacheEntry = undefined;
    var no_actions: [0]RenderLayerCacheAction = .{};
    try std.testing.expectError(error.LayerCacheListFull, (RenderLayerPlan{ .layers = &layers }).cachePlan(&.{}, 1, &entries, &no_actions));
}

test "render pipeline cache plan uploads retains and evicts pipelines" {
    const first_batches = [_]RenderBatch{
        .{ .pipeline = .solid, .command_start = 0, .command_count = 1 },
        .{ .pipeline = .linear_gradient, .command_start = 1, .command_count = 1 },
        .{ .pipeline = .solid, .command_start = 2, .command_count = 1 },
    };
    var first_entries: [2]RenderPipelineCacheEntry = undefined;
    var first_actions: [2]RenderPipelineCacheAction = undefined;
    const first_cache = try (RenderBatchPlan{ .batches = &first_batches }).cachePlan(&.{}, 1, &first_entries, &first_actions);

    try std.testing.expectEqual(@as(usize, 2), first_cache.entryCount());
    try std.testing.expectEqual(@as(usize, 2), first_cache.actionCount());
    try std.testing.expectEqual(@as(usize, 2), first_cache.uploadCount());
    try std.testing.expectEqual(RenderPipelineKind.solid, first_cache.entries[0].pipeline);
    try std.testing.expectEqual(RenderPipelineKind.linear_gradient, first_cache.entries[1].pipeline);
    try std.testing.expectEqual(@as(u64, 1), first_cache.entries[0].last_used_frame);

    const second_batches = [_]RenderBatch{
        .{ .pipeline = .linear_gradient, .command_start = 0, .command_count = 1 },
        .{ .pipeline = .glyph_run, .command_start = 1, .command_count = 1 },
    };
    var second_entries: [2]RenderPipelineCacheEntry = undefined;
    var second_actions: [3]RenderPipelineCacheAction = undefined;
    const second_cache = try (RenderBatchPlan{ .batches = &second_batches }).cachePlan(first_cache.entries, 2, &second_entries, &second_actions);

    try std.testing.expectEqual(@as(usize, 2), second_cache.entryCount());
    try std.testing.expectEqual(@as(usize, 3), second_cache.actionCount());
    try std.testing.expectEqual(@as(usize, 1), second_cache.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), second_cache.retainCount());
    try std.testing.expectEqual(@as(usize, 1), second_cache.evictCount());
    try std.testing.expectEqual(RenderPipelineCacheActionKind.retain, second_cache.actions[0].kind);
    try std.testing.expectEqual(RenderPipelineKind.linear_gradient, second_cache.actions[0].pipeline);
    try std.testing.expectEqual(@as(usize, 0), second_cache.actions[0].batch_index.?);
    try std.testing.expectEqual(@as(usize, 1), second_cache.actions[0].cache_index.?);
    try std.testing.expectEqual(RenderPipelineCacheActionKind.upload, second_cache.actions[1].kind);
    try std.testing.expectEqual(RenderPipelineKind.glyph_run, second_cache.actions[1].pipeline);
    try std.testing.expectEqual(RenderPipelineCacheActionKind.evict, second_cache.actions[2].kind);
    try std.testing.expectEqual(RenderPipelineKind.solid, second_cache.actions[2].pipeline);
}

test "render pipeline cache plan reports output overflow" {
    const batches = [_]RenderBatch{.{ .pipeline = .solid, .command_start = 0, .command_count = 1 }};
    var no_entries: [0]RenderPipelineCacheEntry = .{};
    var actions: [1]RenderPipelineCacheAction = undefined;
    try std.testing.expectError(error.RenderPipelineCacheListFull, (RenderBatchPlan{ .batches = &batches }).cachePlan(&.{}, 1, &no_entries, &actions));

    var entries: [1]RenderPipelineCacheEntry = undefined;
    var no_actions: [0]RenderPipelineCacheAction = .{};
    try std.testing.expectError(error.RenderPipelineCacheListFull, (RenderBatchPlan{ .batches = &batches }).cachePlan(&.{}, 1, &entries, &no_actions));
}

test "render image plan deduplicates texture cache inputs" {
    const commands = [_]CanvasCommand{
        .{ .draw_image = .{
            .id = 1,
            .image_id = 42,
            .dst = geometry.RectF.init(0, 0, 20, 20),
        } },
        .{ .draw_image = .{
            .id = 2,
            .image_id = 42,
            .src = geometry.RectF.init(4, 4, 12, 12),
            .dst = geometry.RectF.init(48, 0, 20, 20),
            .opacity = 0.5,
            .fit = .cover,
        } },
        .{ .draw_image = .{
            .id = 3,
            .image_id = 77,
            .dst = geometry.RectF.init(80, 0, 16, 16),
        } },
    };

    var render_commands: [3]RenderCommand = undefined;
    const render_plan = try (DisplayList{ .commands = &commands }).renderPlan(&render_commands);
    var images: [2]RenderImage = undefined;
    const image_plan = try render_plan.imagePlan(&images);

    try std.testing.expectEqual(@as(usize, 2), image_plan.imageCount());
    try std.testing.expectEqual(@as(usize, 3), image_plan.drawCount());
    try std.testing.expectEqual(@as(ImageId, 42), image_plan.images[0].image_id);
    try std.testing.expect(image_plan.images[0].id == null);
    try std.testing.expectEqual(@as(usize, 2), image_plan.images[0].draw_count);
    try expectRect(geometry.RectF.init(0, 0, 68, 20), image_plan.images[0].bounds);
    try std.testing.expectEqual(renderImageFingerprint(42), image_plan.images[0].fingerprint);
    try std.testing.expectEqual(@as(ImageId, 77), image_plan.images[1].image_id);
    try std.testing.expectEqual(@as(?ObjectId, 3), image_plan.images[1].id);
}

test "render image plan carries provided image resources" {
    const image_pixels = [_]u8{
        255, 0,   0,   255,
        0,   255, 0,   255,
        0,   0,   255, 255,
        255, 255, 255, 255,
    };
    const image_resources = [_]ReferenceImage{.{
        .id = 42,
        .width = 2,
        .height = 2,
        .pixels = &image_pixels,
    }};
    const commands = [_]CanvasCommand{.{ .draw_image = .{
        .id = 1,
        .image_id = 42,
        .dst = geometry.RectF.init(0, 0, 20, 20),
    } }};

    var render_commands: [1]RenderCommand = undefined;
    const render_plan = try (DisplayList{ .commands = &commands }).renderPlan(&render_commands);
    var images: [1]RenderImage = undefined;
    const image_plan = try render_plan.imagePlanWithResources(&image_resources, &images);

    try std.testing.expectEqual(@as(usize, 1), image_plan.imageCount());
    try std.testing.expectEqual(@as(ImageId, 42), image_plan.images[0].image_id);
    try std.testing.expectEqual(@as(usize, 2), image_plan.images[0].width);
    try std.testing.expectEqual(@as(usize, 2), image_plan.images[0].height);
    try std.testing.expectEqualSlices(u8, &image_pixels, image_plan.images[0].pixels);
    try std.testing.expect(image_plan.images[0].fingerprint != renderImageFingerprint(42));
    try std.testing.expectEqual(renderImageFingerprintForResource(42, image_resources[0]), image_plan.images[0].fingerprint);
}

test "render image cache plan uploads retains and evicts textures" {
    const previous_images = [_]RenderImage{
        .{ .image_id = 8, .command_index = 0, .id = 1, .draw_count = 1, .bounds = geometry.RectF.init(0, 0, 20, 20), .fingerprint = renderImageFingerprint(8) },
        .{ .image_id = 9, .command_index = 1, .id = 2, .draw_count = 1, .bounds = geometry.RectF.init(24, 0, 20, 20), .fingerprint = renderImageFingerprint(9) },
    };
    var previous_entries: [2]RenderImageCacheEntry = undefined;
    var previous_actions: [2]RenderImageCacheAction = undefined;
    const previous_cache = try (RenderImagePlan{ .images = &previous_images }).cachePlan(&.{}, 1, &previous_entries, &previous_actions);
    try std.testing.expectEqual(@as(usize, 2), previous_cache.entryCount());
    try std.testing.expectEqual(@as(usize, 2), previous_cache.uploadCount());
    try std.testing.expectEqual(@as(u64, 1), previous_cache.entries[0].last_used_frame);

    const next_images = [_]RenderImage{
        .{ .image_id = 8, .command_index = 0, .id = 1, .draw_count = 1, .bounds = geometry.RectF.init(0, 0, 20, 20), .fingerprint = renderImageFingerprint(8) },
        .{ .image_id = 10, .command_index = 1, .id = 3, .draw_count = 1, .bounds = geometry.RectF.init(48, 0, 20, 20), .fingerprint = renderImageFingerprint(10) },
    };
    var next_entries: [2]RenderImageCacheEntry = undefined;
    var next_actions: [3]RenderImageCacheAction = undefined;
    const next_cache = try (RenderImagePlan{ .images = &next_images }).cachePlan(previous_cache.entries, 2, &next_entries, &next_actions);

    try std.testing.expectEqual(@as(usize, 2), next_cache.entryCount());
    try std.testing.expectEqual(@as(usize, 3), next_cache.actionCount());
    try std.testing.expectEqual(@as(usize, 1), next_cache.retainCount());
    try std.testing.expectEqual(@as(usize, 1), next_cache.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), next_cache.evictCount());
    try std.testing.expectEqual(RenderImageCacheActionKind.retain, next_cache.actions[0].kind);
    try std.testing.expectEqual(@as(ImageId, 8), next_cache.actions[0].key.image_id);
    try std.testing.expectEqual(@as(?usize, 0), next_cache.actions[0].image_index);
    try std.testing.expectEqual(@as(?usize, 0), next_cache.actions[0].cache_index);
    try std.testing.expectEqual(RenderImageCacheActionKind.upload, next_cache.actions[1].kind);
    try std.testing.expectEqual(@as(ImageId, 10), next_cache.actions[1].key.image_id);
    try std.testing.expectEqual(RenderImageCacheActionKind.evict, next_cache.actions[2].kind);
    try std.testing.expectEqual(@as(ImageId, 9), next_cache.actions[2].key.image_id);
    try std.testing.expectEqual(@as(u64, 2), next_cache.entries[0].last_used_frame);
}

test "render image plans report output overflow" {
    const commands = [_]CanvasCommand{.{ .draw_image = .{
        .id = 1,
        .image_id = 1,
        .dst = geometry.RectF.init(0, 0, 10, 10),
    } }};

    var render_commands: [1]RenderCommand = undefined;
    const render_plan = try (DisplayList{ .commands = &commands }).renderPlan(&render_commands);
    var no_images: [0]RenderImage = .{};
    try std.testing.expectError(error.ImageListFull, render_plan.imagePlan(&no_images));

    const images = [_]RenderImage{.{ .image_id = 1, .command_index = 0, .id = 1, .draw_count = 1, .bounds = geometry.RectF.init(0, 0, 10, 10), .fingerprint = renderImageFingerprint(1) }};
    var no_entries: [0]RenderImageCacheEntry = .{};
    var actions: [1]RenderImageCacheAction = undefined;
    try std.testing.expectError(error.ImageCacheListFull, (RenderImagePlan{ .images = &images }).cachePlan(&.{}, 1, &no_entries, &actions));

    var entries: [1]RenderImageCacheEntry = undefined;
    var no_actions: [0]RenderImageCacheAction = .{};
    try std.testing.expectError(error.ImageCacheListFull, (RenderImagePlan{ .images = &images }).cachePlan(&.{}, 1, &entries, &no_actions));
}

test "resource plan collects renderer cache inputs" {
    const stops = [_]GradientStop{
        .{ .offset = 0, .color = Color.rgb8(255, 255, 255) },
        .{ .offset = 1, .color = Color.rgb8(59, 130, 246) },
    };
    const glyphs = [_]Glyph{.{ .id = 7, .x = 0, .y = 0, .advance = 9 }};
    const commands = [_]CanvasCommand{
        .{ .fill_rounded_rect = .{
            .id = 1,
            .rect = geometry.RectF.init(0, 0, 100, 40),
            .radius = Radius.all(8),
            .fill = .{ .linear_gradient = .{
                .start = geometry.PointF.init(0, 0),
                .end = geometry.PointF.init(100, 40),
                .stops = &stops,
            } },
        } },
        .{ .draw_image = .{ .id = 2, .image_id = 99, .dst = geometry.RectF.init(8, 8, 32, 32) } },
        .{ .draw_text = .{
            .id = 3,
            .font_id = 5,
            .size = 14,
            .origin = geometry.PointF.init(48, 24),
            .color = Color.rgb8(15, 23, 42),
            .text = "Hi",
            .glyphs = &glyphs,
        } },
        .{ .shadow = .{
            .id = 4,
            .rect = geometry.RectF.init(0, 0, 100, 40),
            .offset = geometry.OffsetF.init(0, 8),
            .blur = 16,
            .spread = -4,
            .color = Color.rgba8(0, 0, 0, 64),
        } },
        .{ .blur = .{ .id = 5, .rect = geometry.RectF.init(0, 0, 20, 20), .radius = 6 } },
    };

    var resources: [5]RenderResource = undefined;
    const plan = try (DisplayList{ .commands = &commands }).resourcePlan(&resources);
    try std.testing.expectEqual(@as(usize, 5), plan.resourceCount());
    try std.testing.expectEqual(RenderResourceKind.linear_gradient, plan.resources[0].kind);
    try std.testing.expectEqual(@as(?ObjectId, 1), plan.resources[0].id);
    try std.testing.expectEqual(@as(usize, 2), plan.resources[0].gradient_stop_count);
    try expectRect(geometry.RectF.init(0, 0, 100, 40), plan.resources[0].bounds);

    try std.testing.expectEqual(RenderResourceKind.image, plan.resources[1].kind);
    try std.testing.expectEqual(@as(ImageId, 99), plan.resources[1].image_id);
    try expectRect(geometry.RectF.init(8, 8, 32, 32), plan.resources[1].bounds);

    try std.testing.expectEqual(RenderResourceKind.glyph_run, plan.resources[2].kind);
    try std.testing.expectEqual(@as(FontId, 5), plan.resources[2].font_id);
    try std.testing.expectEqual(@as(usize, 1), plan.resources[2].glyph_count);
    try std.testing.expectEqual(@as(usize, 2), plan.resources[2].text_len);

    try std.testing.expectEqual(RenderResourceKind.shadow, plan.resources[3].kind);
    try expectRect(geometry.RectF.init(-20, -12, 140, 80), plan.resources[3].bounds);

    try std.testing.expectEqual(RenderResourceKind.blur, plan.resources[4].kind);
    try expectRect(geometry.RectF.init(-6, -6, 32, 32), plan.resources[4].bounds);
}

test "resource plan collects gradient resources for lines and paths" {
    const stops = [_]GradientStop{
        .{ .offset = 0, .color = Color.rgb8(255, 255, 255) },
        .{ .offset = 1, .color = Color.rgb8(24, 24, 27) },
    };
    const path = [_]PathElement{
        .{ .verb = .move_to, .points = .{ geometry.PointF.init(4, 4), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(20, 20), geometry.PointF.zero(), geometry.PointF.zero() } },
    };
    const gradient_fill = Fill{ .linear_gradient = .{
        .start = geometry.PointF.init(0, 0),
        .end = geometry.PointF.init(20, 20),
        .stops = &stops,
    } };
    const commands = [_]CanvasCommand{
        .{ .draw_line = .{
            .id = 1,
            .from = geometry.PointF.init(0, 0),
            .to = geometry.PointF.init(20, 20),
            .stroke = .{ .fill = gradient_fill, .width = 2 },
        } },
        .{ .fill_path = .{
            .id = 2,
            .elements = &path,
            .fill = gradient_fill,
        } },
    };

    var resources: [2]RenderResource = undefined;
    const plan = try (DisplayList{ .commands = &commands }).resourcePlan(&resources);
    try std.testing.expectEqual(@as(usize, 2), plan.resourceCount());
    try std.testing.expectEqual(RenderResourceKind.linear_gradient, plan.resources[0].kind);
    try std.testing.expectEqual(@as(usize, 0), plan.resources[0].command_index);
    try std.testing.expectEqual(@as(?ObjectId, 1), plan.resources[0].id);
    try std.testing.expectEqual(@as(usize, 2), plan.resources[0].gradient_stop_count);
    try expectRect(geometry.RectF.init(-1, -1, 22, 22), plan.resources[0].bounds);
    try std.testing.expectEqual(RenderResourceKind.linear_gradient, plan.resources[1].kind);
    try std.testing.expectEqual(@as(usize, 1), plan.resources[1].command_index);
    try std.testing.expectEqual(@as(?ObjectId, 2), plan.resources[1].id);
    try expectRect(geometry.RectF.init(4, 4, 16, 16), plan.resources[1].bounds);
}

test "resource cache plan uploads retains and evicts resources" {
    const stops = [_]GradientStop{
        .{ .offset = 0, .color = Color.rgb8(255, 255, 255) },
        .{ .offset = 1, .color = Color.rgb8(24, 24, 27) },
    };
    const first_commands = [_]CanvasCommand{
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 20, 20), .fill = .{ .linear_gradient = .{
            .start = geometry.PointF.init(0, 0),
            .end = geometry.PointF.init(20, 20),
            .stops = &stops,
        } } } },
        .{ .draw_image = .{ .id = 2, .image_id = 8, .dst = geometry.RectF.init(24, 0, 20, 20) } },
    };
    const second_commands = [_]CanvasCommand{
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 20, 20), .fill = .{ .linear_gradient = .{
            .start = geometry.PointF.init(0, 0),
            .end = geometry.PointF.init(20, 20),
            .stops = &stops,
        } } } },
        .{ .draw_text = .{
            .id = 3,
            .font_id = 7,
            .size = 12,
            .origin = geometry.PointF.init(24, 16),
            .color = Color.rgb8(15, 23, 42),
            .text = "Hi",
        } },
    };

    var first_resources: [2]RenderResource = undefined;
    const first_plan = try (DisplayList{ .commands = &first_commands }).resourcePlan(&first_resources);
    var first_entries: [2]RenderResourceCacheEntry = undefined;
    var first_actions: [2]RenderResourceCacheAction = undefined;
    const first_cache = try first_plan.cachePlan(&.{}, 1, &first_entries, &first_actions);
    try std.testing.expectEqual(@as(usize, 2), first_cache.entryCount());
    try std.testing.expectEqual(@as(usize, 2), first_cache.actionCount());
    try std.testing.expectEqual(RenderResourceCacheActionKind.upload, first_cache.actions[0].kind);
    try std.testing.expectEqual(RenderResourceCacheActionKind.upload, first_cache.actions[1].kind);
    try std.testing.expectEqual(@as(u64, 1), first_cache.entries[0].last_used_frame);

    var second_resources: [2]RenderResource = undefined;
    const second_plan = try (DisplayList{ .commands = &second_commands }).resourcePlan(&second_resources);
    var second_entries: [2]RenderResourceCacheEntry = undefined;
    var second_actions: [3]RenderResourceCacheAction = undefined;
    const second_cache = try second_plan.cachePlan(first_cache.entries, 2, &second_entries, &second_actions);

    try std.testing.expectEqual(@as(usize, 2), second_cache.entryCount());
    try std.testing.expectEqual(@as(usize, 3), second_cache.actionCount());
    try std.testing.expectEqual(RenderResourceCacheActionKind.retain, second_cache.actions[0].kind);
    try std.testing.expectEqual(@as(?usize, 0), second_cache.actions[0].cache_index);
    try std.testing.expectEqual(RenderResourceCacheActionKind.upload, second_cache.actions[1].kind);
    try std.testing.expectEqual(RenderResourceKind.glyph_run, second_cache.actions[1].key.kind);
    try std.testing.expectEqual(RenderResourceCacheActionKind.evict, second_cache.actions[2].kind);
    try std.testing.expectEqual(RenderResourceKind.image, second_cache.actions[2].key.kind);
    try std.testing.expectEqual(@as(u64, 2), second_cache.entries[0].last_used_frame);
}

test "resource cache plan treats changed fingerprints as uploads" {
    const first_stops = [_]GradientStop{
        .{ .offset = 0, .color = Color.rgb8(255, 255, 255) },
        .{ .offset = 1, .color = Color.rgb8(24, 24, 27) },
    };
    const second_stops = [_]GradientStop{
        .{ .offset = 0, .color = Color.rgb8(255, 255, 255) },
        .{ .offset = 1, .color = Color.rgb8(37, 99, 235) },
    };
    const first_commands = [_]CanvasCommand{.{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 20, 20), .fill = .{ .linear_gradient = .{
        .start = geometry.PointF.init(0, 0),
        .end = geometry.PointF.init(20, 20),
        .stops = &first_stops,
    } } } }};
    const second_commands = [_]CanvasCommand{.{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 20, 20), .fill = .{ .linear_gradient = .{
        .start = geometry.PointF.init(0, 0),
        .end = geometry.PointF.init(20, 20),
        .stops = &second_stops,
    } } } }};

    var first_resources: [1]RenderResource = undefined;
    const first_plan = try (DisplayList{ .commands = &first_commands }).resourcePlan(&first_resources);
    var first_entries: [1]RenderResourceCacheEntry = undefined;
    var first_actions: [1]RenderResourceCacheAction = undefined;
    const first_cache = try first_plan.cachePlan(&.{}, 1, &first_entries, &first_actions);

    var second_resources: [1]RenderResource = undefined;
    const second_plan = try (DisplayList{ .commands = &second_commands }).resourcePlan(&second_resources);
    try std.testing.expect(first_plan.resources[0].fingerprint != second_plan.resources[0].fingerprint);

    var second_entries: [1]RenderResourceCacheEntry = undefined;
    var second_actions: [2]RenderResourceCacheAction = undefined;
    const second_cache = try second_plan.cachePlan(first_cache.entries, 2, &second_entries, &second_actions);
    try std.testing.expectEqual(@as(usize, 2), second_cache.actionCount());
    try std.testing.expectEqual(RenderResourceCacheActionKind.upload, second_cache.actions[0].kind);
    try std.testing.expectEqual(RenderResourceCacheActionKind.evict, second_cache.actions[1].kind);
}

test "resource cache plan reports output overflow" {
    const commands = [_]CanvasCommand{
        .{ .draw_image = .{ .id = 1, .image_id = 1, .dst = geometry.RectF.init(0, 0, 10, 10) } },
    };
    var resources: [1]RenderResource = undefined;
    const plan = try (DisplayList{ .commands = &commands }).resourcePlan(&resources);

    var no_entries: [0]RenderResourceCacheEntry = .{};
    var actions: [1]RenderResourceCacheAction = undefined;
    try std.testing.expectError(error.RenderResourceCacheListFull, plan.cachePlan(&.{}, 1, &no_entries, &actions));

    var entries: [1]RenderResourceCacheEntry = undefined;
    var no_actions: [0]RenderResourceCacheAction = .{};
    try std.testing.expectError(error.RenderResourceCacheListFull, plan.cachePlan(&.{}, 1, &entries, &no_actions));
}

test "resource plan reports output overflow" {
    const commands = [_]CanvasCommand{
        .{ .draw_image = .{ .id = 1, .image_id = 1, .dst = geometry.RectF.init(0, 0, 10, 10) } },
    };
    var resources: [0]RenderResource = .{};
    try std.testing.expectError(error.RenderResourceListFull, (DisplayList{ .commands = &commands }).resourcePlan(&resources));
}

test "visual effect plan collects shadow and blur cache inputs" {
    const commands = [_]CanvasCommand{
        .{ .shadow = .{
            .id = 7,
            .rect = geometry.RectF.init(10, 20, 30, 40),
            .radius = Radius.all(5),
            .offset = .{ .dx = 3, .dy = 4 },
            .blur = 12,
            .spread = -2,
            .color = Color.rgba8(0, 0, 0, 96),
        } },
        .{ .blur = .{
            .id = 0,
            .rect = geometry.RectF.init(80, 90, 20, 10),
            .radius = 6,
        } },
    };

    var effects: [2]VisualEffect = undefined;
    const plan = try (DisplayList{ .commands = &commands }).visualEffectPlan(&effects);
    try std.testing.expectEqual(@as(usize, 2), plan.effectCount());
    try std.testing.expectEqual(@as(usize, 1), plan.shadowCount());
    try std.testing.expectEqual(@as(usize, 1), plan.blurCount());
    try std.testing.expectEqual(VisualEffectKind.shadow, plan.effects[0].kind);
    try std.testing.expectEqual(@as(?ObjectId, 7), plan.effects[0].id);
    try expectRect(geometry.RectF.init(-1, 10, 58, 68), plan.effects[0].bounds);
    try std.testing.expect(radiiEqual(Radius.all(5), plan.effects[0].radius));
    try std.testing.expectEqual(@as(f32, 12), plan.effects[0].blur);
    try std.testing.expectEqual(@as(f32, -2), plan.effects[0].spread);
    try std.testing.expectEqual(VisualEffectKind.blur, plan.effects[1].kind);
    try std.testing.expect(plan.effects[1].id == null);
    try expectRect(geometry.RectF.init(74, 84, 32, 22), plan.effects[1].bounds);
    try std.testing.expectEqual(@as(f32, 6), plan.effects[1].blur);

    var cache_entries: [2]VisualEffectCacheEntry = undefined;
    var cache_actions: [2]VisualEffectCacheAction = undefined;
    const cache_plan = try plan.cachePlan(&.{}, 1, &cache_entries, &cache_actions);
    try std.testing.expectEqual(@as(usize, 2), cache_plan.actionCount());
    const key = cache_plan.actions[1].key;
    try std.testing.expectEqual(VisualEffectKind.blur, key.kind);
    try std.testing.expect(key.id == null);
    try std.testing.expectEqual(@as(usize, 1), key.command_index);
}

test "visual effect cache plan uploads retains and evicts effects" {
    const first_commands = [_]CanvasCommand{
        .{ .shadow = .{
            .id = 1,
            .rect = geometry.RectF.init(0, 0, 20, 20),
            .blur = 8,
            .color = Color.rgba8(0, 0, 0, 64),
        } },
        .{ .blur = .{
            .id = 2,
            .rect = geometry.RectF.init(30, 0, 20, 20),
            .radius = 4,
        } },
    };
    const second_commands = [_]CanvasCommand{
        .{ .shadow = .{
            .id = 1,
            .rect = geometry.RectF.init(0, 0, 20, 20),
            .blur = 8,
            .color = Color.rgba8(0, 0, 0, 64),
        } },
        .{ .blur = .{
            .id = 2,
            .rect = geometry.RectF.init(30, 0, 20, 20),
            .radius = 10,
        } },
    };

    var first_effects: [2]VisualEffect = undefined;
    const first_plan = try (DisplayList{ .commands = &first_commands }).visualEffectPlan(&first_effects);
    var first_entries: [2]VisualEffectCacheEntry = undefined;
    var first_actions: [2]VisualEffectCacheAction = undefined;
    const first_cache = try first_plan.cachePlan(&.{}, 1, &first_entries, &first_actions);
    try std.testing.expectEqual(@as(usize, 2), first_cache.entryCount());
    try std.testing.expectEqual(@as(usize, 2), first_cache.uploadCount());
    try std.testing.expectEqual(@as(u64, 1), first_cache.entries[0].last_used_frame);

    var second_effects: [2]VisualEffect = undefined;
    const second_plan = try (DisplayList{ .commands = &second_commands }).visualEffectPlan(&second_effects);
    var second_entries: [2]VisualEffectCacheEntry = undefined;
    var second_actions: [3]VisualEffectCacheAction = undefined;
    const second_cache = try second_plan.cachePlan(first_cache.entries, 2, &second_entries, &second_actions);
    try std.testing.expectEqual(@as(usize, 2), second_cache.entryCount());
    try std.testing.expectEqual(@as(usize, 1), second_cache.retainCount());
    try std.testing.expectEqual(@as(usize, 1), second_cache.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), second_cache.evictCount());
    try std.testing.expectEqual(VisualEffectCacheActionKind.retain, second_cache.actions[0].kind);
    try std.testing.expectEqual(VisualEffectKind.shadow, second_cache.actions[0].key.kind);
    try std.testing.expectEqual(VisualEffectCacheActionKind.upload, second_cache.actions[1].kind);
    try std.testing.expectEqual(VisualEffectKind.blur, second_cache.actions[1].key.kind);
    try std.testing.expectEqual(VisualEffectCacheActionKind.evict, second_cache.actions[2].kind);
    try std.testing.expectEqual(VisualEffectKind.blur, second_cache.actions[2].key.kind);
    try std.testing.expectEqual(@as(u64, 2), second_cache.entries[0].last_used_frame);
}

test "visual effect plans report output overflow" {
    const commands = [_]CanvasCommand{.{ .shadow = .{
        .id = 1,
        .rect = geometry.RectF.init(0, 0, 10, 10),
        .blur = 4,
        .color = Color.rgba8(0, 0, 0, 64),
    } }};
    var no_effects: [0]VisualEffect = .{};
    try std.testing.expectError(error.VisualEffectListFull, (DisplayList{ .commands = &commands }).visualEffectPlan(&no_effects));

    var effects: [1]VisualEffect = undefined;
    const plan = try (DisplayList{ .commands = &commands }).visualEffectPlan(&effects);
    var no_entries: [0]VisualEffectCacheEntry = .{};
    var actions: [1]VisualEffectCacheAction = undefined;
    try std.testing.expectError(error.VisualEffectCacheListFull, plan.cachePlan(&.{}, 1, &no_entries, &actions));

    var entries: [1]VisualEffectCacheEntry = undefined;
    var no_actions: [0]VisualEffectCacheAction = .{};
    try std.testing.expectError(error.VisualEffectCacheListFull, plan.cachePlan(&.{}, 1, &entries, &no_actions));
}

test "glyph atlas plan deduplicates shaped glyph keys" {
    const first_glyphs = [_]Glyph{
        .{ .id = 10, .x = 0.10, .y = 0, .advance = 8 },
        .{ .id = 11, .x = 8.25, .y = 0, .advance = 8 },
    };
    const second_glyphs = [_]Glyph{
        .{ .id = 10, .x = 0.20, .y = 0, .advance = 8 },
        .{ .id = 10, .x = 0.55, .y = 0, .advance = 8 },
    };
    const commands = [_]CanvasCommand{
        .{ .draw_text = .{
            .id = 1,
            .font_id = 7,
            .size = 16,
            .origin = geometry.PointF.init(12, 24),
            .color = Color.rgb8(15, 23, 42),
            .glyphs = &first_glyphs,
        } },
        .{ .draw_text = .{
            .id = 2,
            .font_id = 7,
            .size = 16,
            .origin = geometry.PointF.init(12, 24),
            .color = Color.rgb8(15, 23, 42),
            .glyphs = &second_glyphs,
        } },
    };

    var entries: [4]GlyphAtlasEntry = undefined;
    const plan = try (DisplayList{ .commands = &commands }).glyphAtlasPlan(&entries);
    try std.testing.expectEqual(@as(usize, 3), plan.entryCount());
    try std.testing.expectEqual(@as(FontId, 7), plan.entries[0].key.font_id);
    try std.testing.expectEqual(@as(u32, 10), plan.entries[0].key.glyph_id);
    try std.testing.expectEqual(@as(u8, 0), plan.entries[0].key.subpixel_x);
    try std.testing.expectEqual(@as(u32, 11), plan.entries[1].key.glyph_id);
    try std.testing.expectEqual(@as(u8, 1), plan.entries[1].key.subpixel_x);
    try std.testing.expectEqual(@as(u32, 10), plan.entries[2].key.glyph_id);
    try std.testing.expectEqual(@as(u8, 2), plan.entries[2].key.subpixel_x);
}

test "glyph atlas plan honors shaped fallback font overrides" {
    const glyphs = [_]Glyph{
        .{ .id = 41, .x = 0, .y = 0, .advance = 8 },
        .{ .id = 9001, .font_id = 11, .x = 8, .y = 0, .advance = 14 },
        .{ .id = 42, .x = 22, .y = 0, .advance = 8 },
    };
    const commands = [_]CanvasCommand{.{ .draw_text = .{
        .id = 1,
        .font_id = 7,
        .size = 16,
        .origin = geometry.PointF.init(12, 24),
        .color = Color.rgb8(15, 23, 42),
        .text = "A🙂B",
        .glyphs = &glyphs,
    } }};

    var entries: [3]GlyphAtlasEntry = undefined;
    const plan = try (DisplayList{ .commands = &commands }).glyphAtlasPlan(&entries);
    try std.testing.expectEqual(@as(usize, 3), plan.entryCount());
    try std.testing.expectEqual(@as(FontId, 7), plan.entries[0].key.font_id);
    try std.testing.expectEqual(@as(FontId, 11), plan.entries[1].key.font_id);
    try std.testing.expectEqual(@as(u32, 9001), plan.entries[1].key.glyph_id);
    try std.testing.expectEqual(@as(FontId, 7), plan.entries[2].key.font_id);

    const primary_only = [_]Glyph{
        .{ .id = 41, .x = 0, .y = 0, .advance = 8 },
        .{ .id = 9001, .x = 8, .y = 0, .advance = 14 },
        .{ .id = 42, .x = 22, .y = 0, .advance = 8 },
    };
    const primary_commands = [_]CanvasCommand{.{ .draw_text = .{
        .id = 1,
        .font_id = 7,
        .size = 16,
        .origin = geometry.PointF.init(12, 24),
        .color = Color.rgb8(15, 23, 42),
        .text = "A🙂B",
        .glyphs = &primary_only,
    } }};

    var changes: [1]DiffChange = undefined;
    const diff = try DisplayList.diff(.{ .commands = &primary_commands }, .{ .commands = &commands }, &changes);
    try std.testing.expectEqual(@as(usize, 1), diff.len);
    try std.testing.expectEqual(DiffKind.changed, diff[0].kind);

    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try (DisplayList{ .commands = &commands }).writeJson(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"font\":11") != null);
}

test "glyph atlas plan falls back to utf8 scalar glyph keys" {
    const commands = [_]CanvasCommand{.{ .draw_text = .{
        .id = 1,
        .font_id = 3,
        .size = 12,
        .origin = geometry.PointF.init(0.5, 8.75),
        .color = Color.rgb8(15, 23, 42),
        .text = "A é",
    } }};

    var entries: [2]GlyphAtlasEntry = undefined;
    const plan = try (DisplayList{ .commands = &commands }).glyphAtlasPlan(&entries);
    try std.testing.expectEqual(@as(usize, 2), plan.entryCount());
    try std.testing.expectEqual(@as(u32, 'A'), plan.entries[0].key.glyph_id);
    try std.testing.expectEqual(@as(u8, 2), plan.entries[0].key.subpixel_x);
    try std.testing.expectEqual(@as(u8, 3), plan.entries[0].key.subpixel_y);
    try std.testing.expectEqual(@as(usize, 0), plan.entries[0].glyph_index);
    try std.testing.expectEqual(@as(u32, 0x00e9), plan.entries[1].key.glyph_id);
    try std.testing.expectEqual(@as(u8, 2), plan.entries[1].key.subpixel_x);
    try std.testing.expectEqual(@as(usize, 2), plan.entries[1].glyph_index);
}

test "glyph atlas plan reports output overflow" {
    const glyphs = [_]Glyph{.{ .id = 10, .x = 0, .y = 0 }};
    const commands = [_]CanvasCommand{.{ .draw_text = .{
        .id = 1,
        .font_id = 1,
        .size = 14,
        .origin = geometry.PointF.init(0, 0),
        .color = Color.rgb8(0, 0, 0),
        .glyphs = &glyphs,
    } }};
    var entries: [0]GlyphAtlasEntry = .{};
    try std.testing.expectError(error.GlyphAtlasListFull, (DisplayList{ .commands = &commands }).glyphAtlasPlan(&entries));
}

test "glyph atlas cache plan uploads retains and evicts glyphs" {
    const previous = [_]GlyphAtlasCacheEntry{
        .{
            .key = .{ .font_id = 1, .glyph_id = 65, .size = 14, .subpixel_x = 0, .subpixel_y = 0 },
            .last_used_frame = 3,
        },
        .{
            .key = .{ .font_id = 1, .glyph_id = 66, .size = 14, .subpixel_x = 0, .subpixel_y = 0 },
            .last_used_frame = 3,
        },
    };
    const atlas_entries = [_]GlyphAtlasEntry{
        .{
            .key = .{ .font_id = 1, .glyph_id = 65, .size = 14, .subpixel_x = 0, .subpixel_y = 0 },
            .command_index = 0,
            .glyph_index = 0,
        },
        .{
            .key = .{ .font_id = 1, .glyph_id = 67, .size = 14, .subpixel_x = 0, .subpixel_y = 0 },
            .command_index = 0,
            .glyph_index = 1,
        },
    };

    var cache_entries: [2]GlyphAtlasCacheEntry = undefined;
    var cache_actions: [3]GlyphAtlasCacheAction = undefined;
    const cache = try (GlyphAtlasPlan{ .entries = &atlas_entries }).cachePlan(&previous, 4, &cache_entries, &cache_actions);

    try std.testing.expectEqual(@as(usize, 2), cache.entryCount());
    try std.testing.expectEqual(@as(usize, 3), cache.actionCount());
    try std.testing.expectEqual(@as(usize, 1), cache.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), cache.retainCount());
    try std.testing.expectEqual(@as(usize, 1), cache.evictCount());
    try std.testing.expectEqual(@as(u64, 4), cache.entries[0].last_used_frame);
    try std.testing.expectEqual(GlyphAtlasCacheActionKind.retain, cache.actions[0].kind);
    try std.testing.expectEqual(@as(u32, 65), cache.actions[0].key.glyph_id);
    try std.testing.expectEqual(@as(usize, 0), cache.actions[0].atlas_index.?);
    try std.testing.expectEqual(@as(usize, 0), cache.actions[0].cache_index.?);
    try std.testing.expectEqual(GlyphAtlasCacheActionKind.upload, cache.actions[1].kind);
    try std.testing.expectEqual(@as(u32, 67), cache.actions[1].key.glyph_id);
    try std.testing.expectEqual(@as(usize, 1), cache.actions[1].atlas_index.?);
    try std.testing.expect(cache.actions[1].cache_index == null);
    try std.testing.expectEqual(GlyphAtlasCacheActionKind.evict, cache.actions[2].kind);
    try std.testing.expectEqual(@as(u32, 66), cache.actions[2].key.glyph_id);
    try std.testing.expect(cache.actions[2].atlas_index == null);
    try std.testing.expectEqual(@as(usize, 1), cache.actions[2].cache_index.?);
}

test "glyph atlas cache plan keeps recent unused glyphs warm" {
    const previous = [_]GlyphAtlasCacheEntry{
        .{
            .key = .{ .font_id = 1, .glyph_id = 65, .size = 14 },
            .last_used_frame = 3,
        },
        .{
            .key = .{ .font_id = 1, .glyph_id = 66, .size = 14 },
            .last_used_frame = 3,
        },
    };
    const atlas_entries = [_]GlyphAtlasEntry{.{
        .key = .{ .font_id = 1, .glyph_id = 65, .size = 14 },
        .command_index = 0,
        .glyph_index = 0,
    }};

    var warm_entries: [2]GlyphAtlasCacheEntry = undefined;
    var warm_actions: [2]GlyphAtlasCacheAction = undefined;
    const warm = try (GlyphAtlasPlan{ .entries = &atlas_entries }).cachePlanWithRetention(&previous, 4, 2, &warm_entries, &warm_actions);
    try std.testing.expectEqual(@as(usize, 2), warm.entryCount());
    try std.testing.expectEqual(@as(usize, 0), warm.uploadCount());
    try std.testing.expectEqual(@as(usize, 2), warm.retainCount());
    try std.testing.expectEqual(@as(usize, 0), warm.evictCount());
    try std.testing.expectEqual(@as(u64, 4), warm.entries[0].last_used_frame);
    try std.testing.expectEqual(@as(u64, 3), warm.entries[1].last_used_frame);
    try std.testing.expectEqual(@as(?usize, 0), warm.actions[0].atlas_index);
    try std.testing.expectEqual(@as(?usize, 0), warm.actions[0].cache_index);
    try std.testing.expect(warm.actions[1].atlas_index == null);
    try std.testing.expectEqual(@as(?usize, 1), warm.actions[1].cache_index);

    var stale_entries: [2]GlyphAtlasCacheEntry = undefined;
    var stale_actions: [2]GlyphAtlasCacheAction = undefined;
    const stale = try (GlyphAtlasPlan{ .entries = &atlas_entries }).cachePlanWithRetention(&previous, 6, 2, &stale_entries, &stale_actions);
    try std.testing.expectEqual(@as(usize, 1), stale.entryCount());
    try std.testing.expectEqual(@as(usize, 1), stale.retainCount());
    try std.testing.expectEqual(@as(usize, 1), stale.evictCount());
    try std.testing.expectEqual(GlyphAtlasCacheActionKind.evict, stale.actions[1].kind);
    try std.testing.expectEqual(@as(u32, 66), stale.actions[1].key.glyph_id);
    try std.testing.expectEqual(@as(?usize, 1), stale.actions[1].cache_index);
}

test "glyph atlas cache plan reports output overflow" {
    const atlas_entries = [_]GlyphAtlasEntry{.{
        .key = .{ .font_id = 1, .glyph_id = 65, .size = 14 },
        .command_index = 0,
        .glyph_index = 0,
    }};
    var no_cache_entries: [0]GlyphAtlasCacheEntry = .{};
    var cache_actions: [1]GlyphAtlasCacheAction = undefined;
    try std.testing.expectError(error.GlyphAtlasCacheListFull, (GlyphAtlasPlan{ .entries = &atlas_entries }).cachePlan(&.{}, 1, &no_cache_entries, &cache_actions));

    var cache_entries: [1]GlyphAtlasCacheEntry = undefined;
    var no_cache_actions: [0]GlyphAtlasCacheAction = .{};
    try std.testing.expectError(error.GlyphAtlasCacheListFull, (GlyphAtlasPlan{ .entries = &atlas_entries }).cachePlan(&.{}, 1, &cache_entries, &no_cache_actions));
}

test "canvas frame budget tracks glyph and text cache churn" {
    const status = (CanvasFrameBudget{
        .max_glyph_atlas_entries = 8,
        .max_glyph_atlas_uploads = 1,
        .max_glyph_atlas_evicts = 1,
        .max_text_layouts = 8,
        .max_text_layout_lines = 8,
        .max_text_layout_uploads = 1,
        .max_text_layout_evicts = 1,
    }).status(.{
        .glyph_atlas_entry_count = 4,
        .glyph_atlas_upload_count = 2,
        .glyph_atlas_evict_count = 2,
        .text_layout_count = 3,
        .text_layout_line_count = 3,
        .text_layout_upload_count = 2,
        .text_layout_evict_count = 2,
    });

    try std.testing.expect(status.ok() == false);
    try std.testing.expect(!status.glyph_atlas_entries_over);
    try std.testing.expect(status.glyph_atlas_uploads_over);
    try std.testing.expect(status.glyph_atlas_evicts_over);
    try std.testing.expect(!status.text_layouts_over);
    try std.testing.expect(!status.text_layout_lines_over);
    try std.testing.expect(status.text_layout_uploads_over);
    try std.testing.expect(status.text_layout_evicts_over);
    try std.testing.expectEqual(@as(usize, 4), status.exceededCount());
}

test "canvas frame plan builds first frame renderer packet" {
    const stops = [_]GradientStop{
        .{ .offset = 0, .color = Color.rgb8(255, 255, 255) },
        .{ .offset = 1, .color = Color.rgb8(24, 24, 27) },
    };
    const commands = [_]CanvasCommand{
        .{ .fill_rounded_rect = .{
            .id = 1,
            .rect = geometry.RectF.init(16, 16, 160, 72),
            .radius = Radius.all(12),
            .fill = .{ .linear_gradient = .{
                .start = geometry.PointF.init(16, 16),
                .end = geometry.PointF.init(176, 88),
                .stops = &stops,
            } },
        } },
        .{ .draw_text = .{
            .id = 2,
            .font_id = 5,
            .size = 14,
            .origin = geometry.PointF.init(28, 48),
            .color = Color.rgb8(15, 23, 42),
            .text = "OK",
        } },
    };

    var render_commands: [2]RenderCommand = undefined;
    var render_batches: [2]RenderBatch = undefined;
    var pipeline_cache_entries: [2]RenderPipelineCacheEntry = undefined;
    var pipeline_cache_actions: [2]RenderPipelineCacheAction = undefined;
    var resources: [2]RenderResource = undefined;
    var resource_cache_entries: [2]RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [2]RenderResourceCacheAction = undefined;
    var glyphs: [2]GlyphAtlasEntry = undefined;
    var glyph_cache_entries: [2]GlyphAtlasCacheEntry = undefined;
    var glyph_cache_actions: [2]GlyphAtlasCacheAction = undefined;
    var text_layout_plans: [1]TextLayoutPlan = undefined;
    var text_layout_lines: [1]TextLine = undefined;
    var text_layout_cache_entries: [1]TextLayoutCacheEntry = undefined;
    var text_layout_cache_actions: [1]TextLayoutCacheAction = undefined;
    var changes: [2]DiffChange = undefined;
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .frame_index = 7,
        .timestamp_ns = 88,
        .surface_size = geometry.SizeF.init(320, 200),
        .scale = 2,
        .budget = .{
            .max_commands = 1,
            .max_batches = 2,
            .max_encoder_commands = 13,
            .max_pipelines = 2,
            .max_pipeline_uploads = 1,
            .max_resources = 2,
            .max_resource_uploads = 1,
            .max_glyph_atlas_entries = 2,
        },
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .pipeline_cache_entries = &pipeline_cache_entries,
        .pipeline_cache_actions = &pipeline_cache_actions,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .glyph_atlas_cache_entries = &glyph_cache_entries,
        .glyph_atlas_cache_actions = &glyph_cache_actions,
        .text_layout_plans = &text_layout_plans,
        .text_layout_lines = &text_layout_lines,
        .text_layout_cache_entries = &text_layout_cache_entries,
        .text_layout_cache_actions = &text_layout_cache_actions,
        .changes = &changes,
    });

    try std.testing.expectEqual(@as(u64, 7), frame.frame_index);
    try std.testing.expectEqual(@as(u64, 88), frame.timestamp_ns);
    try std.testing.expectEqualDeep(geometry.SizeF.init(320, 200), frame.surface_size);
    try std.testing.expectEqual(@as(f32, 2), frame.scale);
    try std.testing.expect(frame.full_repaint);
    try std.testing.expect(frame.requiresRender());
    try std.testing.expectEqual(@as(usize, 2), frame.render_plan.commandCount());
    try std.testing.expectEqual(@as(usize, 2), frame.batch_plan.batchCount());
    try std.testing.expectEqual(RenderPipelineKind.linear_gradient, frame.batch_plan.batches[0].pipeline);
    try std.testing.expectEqual(RenderPipelineKind.glyph_run, frame.batch_plan.batches[1].pipeline);
    try std.testing.expectEqual(@as(usize, 2), frame.pipeline_cache_plan.entryCount());
    try std.testing.expectEqual(@as(usize, 2), frame.pipeline_cache_plan.actionCount());
    try std.testing.expectEqual(@as(usize, 2), frame.pipeline_cache_plan.uploadCount());
    try std.testing.expectEqual(RenderPipelineCacheActionKind.upload, frame.pipeline_cache_plan.actions[0].kind);
    try std.testing.expectEqual(RenderPipelineKind.linear_gradient, frame.pipeline_cache_plan.actions[0].pipeline);
    try std.testing.expectEqual(RenderPipelineKind.glyph_run, frame.pipeline_cache_plan.actions[1].pipeline);
    try std.testing.expectEqual(@as(usize, 2), frame.resource_plan.resourceCount());
    try std.testing.expectEqual(@as(usize, 2), frame.resource_cache_plan.entryCount());
    try std.testing.expectEqual(@as(usize, 2), frame.resource_cache_plan.actionCount());
    try std.testing.expectEqual(RenderResourceCacheActionKind.upload, frame.resource_cache_plan.actions[0].kind);
    try std.testing.expectEqual(RenderResourceCacheActionKind.upload, frame.resource_cache_plan.actions[1].kind);
    try std.testing.expectEqual(@as(usize, 2), frame.resource_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 2), frame.glyph_atlas_plan.entryCount());
    try std.testing.expectEqual(@as(usize, 2), frame.glyph_atlas_cache_plan.entryCount());
    try std.testing.expectEqual(@as(usize, 2), frame.glyph_atlas_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), frame.text_layout_plan.planCount());
    try std.testing.expectEqual(@as(usize, 1), frame.text_layout_plan.lineCount());
    try std.testing.expectEqual(@as(usize, 1), frame.text_layout_cache_plan.entryCount());
    try std.testing.expectEqual(@as(usize, 1), frame.text_layout_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 0), frame.changes.len);
    try expectRect(geometry.RectF.init(0, 0, 320, 200), frame.dirty_bounds);

    const render_pass = frame.renderPass();
    try std.testing.expect(render_pass.requiresRender());
    try std.testing.expectEqual(CanvasRenderPassLoadAction.clear, render_pass.loadAction());
    try std.testing.expectEqual(@as(u64, 7), render_pass.frame_index);
    try std.testing.expectEqual(@as(u64, 88), render_pass.timestamp_ns);
    try std.testing.expectEqualDeep(geometry.SizeF.init(320, 200), render_pass.surface_size);
    try std.testing.expectEqual(@as(f32, 2), render_pass.scale);
    try std.testing.expectEqual(@as(usize, 2), render_pass.commandCount());
    try std.testing.expectEqual(@as(usize, 2), render_pass.batchCount());
    try std.testing.expectEqual(@as(usize, 2), render_pass.pipelineActionCount());
    try std.testing.expectEqual(@as(usize, 0), render_pass.pathGeometryCount());
    try std.testing.expectEqual(@as(usize, 0), render_pass.pathGeometryActionCount());
    try std.testing.expectEqual(@as(usize, 0), render_pass.pathGeometryVertexCount());
    try std.testing.expectEqual(@as(usize, 0), render_pass.pathGeometryIndexCount());
    try std.testing.expectEqual(@as(usize, 0), render_pass.imageCount());
    try std.testing.expectEqual(@as(usize, 0), render_pass.imageActionCount());
    try std.testing.expectEqual(@as(usize, 0), render_pass.layerCount());
    try std.testing.expectEqual(@as(usize, 0), render_pass.layerActionCount());
    try std.testing.expectEqual(@as(usize, 14), render_pass.encoderCommandCount());
    try std.testing.expectEqual(@as(usize, 7), render_pass.encoderCacheActionCount());
    try std.testing.expectEqual(@as(usize, 2), render_pass.encoderBindPipelineCount());
    try std.testing.expectEqual(@as(usize, 2), render_pass.encoderDrawBatchCount());
    try std.testing.expectEqual(@as(usize, 2), render_pass.resourceCount());
    try std.testing.expectEqual(@as(usize, 2), render_pass.resourceActionCount());
    try std.testing.expectEqual(@as(usize, 2), render_pass.glyphAtlasEntryCount());
    try std.testing.expectEqual(@as(usize, 2), render_pass.glyphAtlasActionCount());
    try std.testing.expectEqual(@as(usize, 1), render_pass.textLayoutCount());
    try std.testing.expectEqual(@as(usize, 1), render_pass.textLayoutLineCount());
    try std.testing.expectEqual(@as(usize, 1), render_pass.textLayoutActionCount());
    try std.testing.expectEqual(RenderPipelineCacheActionKind.upload, render_pass.pipeline_actions[0].kind);
    try std.testing.expectEqual(RenderResourceCacheActionKind.upload, render_pass.resource_actions[0].kind);
    try std.testing.expectEqual(GlyphAtlasCacheActionKind.upload, render_pass.glyph_atlas_actions[0].kind);
    try std.testing.expectEqual(TextLayoutCacheActionKind.upload, render_pass.text_layout_actions[0].kind);
    try expectRect(geometry.RectF.init(0, 0, 320, 200), render_pass.scissorBounds());

    var encoder_commands: [16]RenderEncoderCommand = undefined;
    const encoder_plan = try render_pass.encoderPlan(&encoder_commands);
    try std.testing.expectEqual(@as(usize, 14), encoder_plan.commandCount());
    try std.testing.expectEqual(@as(usize, 7), encoder_plan.cacheActionCount());
    try std.testing.expectEqual(@as(usize, 2), encoder_plan.bindPipelineCount());
    try std.testing.expectEqual(@as(usize, 2), encoder_plan.drawBatchCount());
    switch (encoder_plan.commands[0]) {
        .begin_pass => |begin| {
            try std.testing.expectEqual(CanvasRenderPassLoadAction.clear, begin.load_action);
            try std.testing.expectEqualDeep(geometry.SizeF.init(320, 200), begin.surface_size);
        },
        else => return error.TestExpectedEqual,
    }
    switch (encoder_plan.commands[1]) {
        .set_scissor => |bounds| try expectRect(geometry.RectF.init(0, 0, 320, 200), bounds),
        else => return error.TestExpectedEqual,
    }
    switch (encoder_plan.commands[encoder_plan.commands.len - 1]) {
        .end_pass => {},
        else => return error.TestExpectedEqual,
    }

    var render_pass_json_buffer: [8192]u8 = undefined;
    var render_pass_json_writer = std.Io.Writer.fixed(&render_pass_json_buffer);
    try render_pass.writeJson(&render_pass_json_writer);
    const render_pass_json = render_pass_json_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, render_pass_json, "\"loadAction\":\"clear\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, render_pass_json, "\"scissorBounds\":[0,0,320,200]") != null);
    try std.testing.expect(std.mem.indexOf(u8, render_pass_json, "\"commands\":[{\"index\":0,\"id\":1,\"opacity\":1,\"clip\":null,\"transform\":[1,0,0,1,0,0],\"localBounds\":[16,16,160,72],\"bounds\":[16,16,160,72],\"command\":{\"op\":\"fill_rounded_rect\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, render_pass_json, "\"batches\":[{\"pipeline\":\"linear_gradient\",\"commandStart\":0,\"commandCount\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, render_pass_json, "\"pipelineActions\":[{\"kind\":\"upload\",\"pipeline\":\"linear_gradient\",\"batchIndex\":0,\"cacheIndex\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, render_pass_json, "\"pathGeometries\":[],\"pathGeometryActions\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, render_pass_json, "\"images\":[],\"imageActions\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, render_pass_json, "\"layers\":[],\"layerActions\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, render_pass_json, "\"resources\":[{\"kind\":\"linear_gradient\",\"commandIndex\":0,\"id\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, render_pass_json, "\"resourceActions\":[{\"kind\":\"upload\",\"key\":{\"kind\":\"linear_gradient\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, render_pass_json, "\"glyphAtlasEntries\":[{\"key\":{\"fontId\":5,\"glyphId\":79") != null);
    try std.testing.expect(std.mem.indexOf(u8, render_pass_json, "\"glyphAtlasActions\":[{\"kind\":\"upload\",\"key\":{\"fontId\":5,\"glyphId\":79") != null);
    try std.testing.expect(std.mem.indexOf(u8, render_pass_json, "\"textLayouts\":[{\"key\":{\"fontId\":5,\"size\":14") != null);
    try std.testing.expect(std.mem.indexOf(u8, render_pass_json, "\"textLayoutActions\":[{\"kind\":\"upload\",\"key\":{\"fontId\":5,\"size\":14") != null);

    const diagnostics = frame.diagnostics();
    try std.testing.expectEqual(@as(u64, 7), diagnostics.frame_index);
    try std.testing.expectEqual(@as(usize, 2), diagnostics.command_count);
    try std.testing.expectEqual(@as(usize, 2), diagnostics.batch_count);
    try std.testing.expectEqual(@as(usize, 14), diagnostics.encoder_command_count);
    try std.testing.expectEqual(@as(usize, 7), diagnostics.encoder_cache_action_count);
    try std.testing.expectEqual(@as(usize, 2), diagnostics.encoder_bind_pipeline_count);
    try std.testing.expectEqual(@as(usize, 2), diagnostics.encoder_draw_batch_count);
    try std.testing.expectEqual(@as(usize, 2), diagnostics.pipeline_count);
    try std.testing.expectEqual(@as(usize, 2), diagnostics.pipeline_upload_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.pipeline_retain_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.pipeline_evict_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.path_geometry_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.path_geometry_vertex_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.path_geometry_index_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.path_geometry_upload_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.path_geometry_retain_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.path_geometry_evict_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.image_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.image_upload_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.image_retain_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.image_evict_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.layer_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.layer_opacity_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.layer_clip_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.layer_transform_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.layer_upload_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.layer_retain_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.layer_evict_count);
    try std.testing.expectEqual(@as(usize, 2), diagnostics.resource_count);
    try std.testing.expectEqual(@as(usize, 2), diagnostics.resource_upload_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.resource_retain_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.resource_evict_count);
    try std.testing.expectEqual(@as(usize, 2), diagnostics.glyph_atlas_entry_count);
    try std.testing.expectEqual(@as(usize, 2), diagnostics.glyph_atlas_upload_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.glyph_atlas_retain_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.glyph_atlas_evict_count);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.text_layout_count);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.text_layout_line_count);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.text_layout_upload_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.text_layout_retain_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.text_layout_evict_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.change_count);
    try std.testing.expect(diagnostics.full_repaint);
    try std.testing.expect(diagnostics.requires_render);
    try expectRect(geometry.RectF.init(0, 0, 320, 200), diagnostics.dirty_bounds);
    try std.testing.expect(!diagnostics.budgetOk());
    try std.testing.expect(diagnostics.budget_status.commands_over);
    try std.testing.expect(!diagnostics.budget_status.batches_over);
    try std.testing.expect(diagnostics.budget_status.encoder_commands_over);
    try std.testing.expect(!diagnostics.budget_status.pipelines_over);
    try std.testing.expect(diagnostics.budget_status.pipeline_uploads_over);
    try std.testing.expect(!diagnostics.budget_status.path_geometries_over);
    try std.testing.expect(!diagnostics.budget_status.path_geometry_uploads_over);
    try std.testing.expect(!diagnostics.budget_status.images_over);
    try std.testing.expect(!diagnostics.budget_status.image_uploads_over);
    try std.testing.expect(!diagnostics.budget_status.layers_over);
    try std.testing.expect(!diagnostics.budget_status.layer_uploads_over);
    try std.testing.expect(!diagnostics.budget_status.resources_over);
    try std.testing.expect(diagnostics.budget_status.resource_uploads_over);
    try std.testing.expect(!diagnostics.budget_status.glyph_atlas_entries_over);
    try std.testing.expect(!diagnostics.budget_status.text_layouts_over);
    try std.testing.expect(!diagnostics.budget_status.text_layout_lines_over);
    try std.testing.expect(!diagnostics.budget_status.changes_over);
    try std.testing.expectEqual(@as(usize, 2), diagnostics.gpu_packet_command_count);
    try std.testing.expectEqual(@as(usize, 7), diagnostics.gpu_packet_cache_action_count);
    try std.testing.expectEqual(@as(usize, 2), diagnostics.gpu_packet_cached_resource_command_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.gpu_packet_unsupported_command_count);
    try std.testing.expect(diagnostics.gpu_packet_representable);
    try std.testing.expectEqual(@as(usize, 4), diagnostics.budget_status.exceededCount());
    try std.testing.expectEqual(@as(usize, 4), frame.budgetStatus().exceededCount());

    var diagnostics_json_buffer: [2048]u8 = undefined;
    var diagnostics_json_writer = std.Io.Writer.fixed(&diagnostics_json_buffer);
    try frame.writeDiagnosticsJson(&diagnostics_json_writer);
    try std.testing.expectEqualStrings(
        "{\"frameIndex\":7,\"commandCount\":2,\"batchCount\":2,\"encoderCommandCount\":14,\"encoderCacheActionCount\":7,\"encoderBindPipelineCount\":2,\"encoderDrawBatchCount\":2,\"pipelineCount\":2,\"pipelineUploadCount\":2,\"pipelineRetainCount\":0,\"pipelineEvictCount\":0,\"pathGeometryCount\":0,\"pathGeometryVertexCount\":0,\"pathGeometryIndexCount\":0,\"pathGeometryUploadCount\":0,\"pathGeometryRetainCount\":0,\"pathGeometryEvictCount\":0,\"layerCount\":0,\"layerOpacityCount\":0,\"layerClipCount\":0,\"layerTransformCount\":0,\"layerUploadCount\":0,\"layerRetainCount\":0,\"layerEvictCount\":0,\"imageCount\":0,\"imageUploadCount\":0,\"imageRetainCount\":0,\"imageEvictCount\":0,\"resourceCount\":2,\"resourceUploadCount\":2,\"resourceRetainCount\":0,\"resourceEvictCount\":0,\"visualEffectCount\":0,\"visualEffectShadowCount\":0,\"visualEffectBlurCount\":0,\"visualEffectUploadCount\":0,\"visualEffectRetainCount\":0,\"visualEffectEvictCount\":0,\"glyphAtlasEntryCount\":2,\"glyphAtlasUploadCount\":2,\"glyphAtlasRetainCount\":0,\"glyphAtlasEvictCount\":0,\"textLayoutCount\":1,\"textLayoutLineCount\":1,\"textLayoutUploadCount\":1,\"textLayoutRetainCount\":0,\"textLayoutEvictCount\":0,\"gpuPacketCommandCount\":2,\"gpuPacketCacheActionCount\":7,\"gpuPacketCachedResourceCommandCount\":2,\"gpuPacketUnsupportedCommandCount\":0,\"gpuPacketRepresentable\":true,\"changeCount\":0,\"budgetExceededCount\":4,\"budgetOk\":false,\"fullRepaint\":true,\"requiresRender\":true,\"dirtyBounds\":[0,0,320,200]}",
        diagnostics_json_writer.buffered(),
    );

    var clean_json_buffer: [2048]u8 = undefined;
    var clean_json_writer = std.Io.Writer.fixed(&clean_json_buffer);
    try (CanvasFrameDiagnostics{ .frame_index = 8 }).writeJson(&clean_json_writer);
    try std.testing.expectEqualStrings(
        "{\"frameIndex\":8,\"commandCount\":0,\"batchCount\":0,\"encoderCommandCount\":0,\"encoderCacheActionCount\":0,\"encoderBindPipelineCount\":0,\"encoderDrawBatchCount\":0,\"pipelineCount\":0,\"pipelineUploadCount\":0,\"pipelineRetainCount\":0,\"pipelineEvictCount\":0,\"pathGeometryCount\":0,\"pathGeometryVertexCount\":0,\"pathGeometryIndexCount\":0,\"pathGeometryUploadCount\":0,\"pathGeometryRetainCount\":0,\"pathGeometryEvictCount\":0,\"layerCount\":0,\"layerOpacityCount\":0,\"layerClipCount\":0,\"layerTransformCount\":0,\"layerUploadCount\":0,\"layerRetainCount\":0,\"layerEvictCount\":0,\"imageCount\":0,\"imageUploadCount\":0,\"imageRetainCount\":0,\"imageEvictCount\":0,\"resourceCount\":0,\"resourceUploadCount\":0,\"resourceRetainCount\":0,\"resourceEvictCount\":0,\"visualEffectCount\":0,\"visualEffectShadowCount\":0,\"visualEffectBlurCount\":0,\"visualEffectUploadCount\":0,\"visualEffectRetainCount\":0,\"visualEffectEvictCount\":0,\"glyphAtlasEntryCount\":0,\"glyphAtlasUploadCount\":0,\"glyphAtlasRetainCount\":0,\"glyphAtlasEvictCount\":0,\"textLayoutCount\":0,\"textLayoutLineCount\":0,\"textLayoutUploadCount\":0,\"textLayoutRetainCount\":0,\"textLayoutEvictCount\":0,\"gpuPacketCommandCount\":0,\"gpuPacketCacheActionCount\":0,\"gpuPacketCachedResourceCommandCount\":0,\"gpuPacketUnsupportedCommandCount\":0,\"gpuPacketRepresentable\":true,\"changeCount\":0,\"budgetExceededCount\":0,\"budgetOk\":true,\"fullRepaint\":false,\"requiresRender\":false,\"dirtyBounds\":null}",
        clean_json_writer.buffered(),
    );
}

test "render encoder plan skips clean passes and reports output overflow" {
    var clean_encoder_commands: [1]RenderEncoderCommand = undefined;
    const clean_plan = try (CanvasRenderPass{}).encoderPlan(&clean_encoder_commands);
    try std.testing.expectEqual(@as(usize, 0), clean_plan.commandCount());

    const batches = [_]RenderBatch{.{ .pipeline = .solid, .command_start = 0, .command_count = 1 }};
    const pass = CanvasRenderPass{
        .full_repaint = true,
        .batches = &batches,
    };
    var encoder_commands: [4]RenderEncoderCommand = undefined;
    const plan = try pass.encoderPlan(&encoder_commands);
    try std.testing.expectEqual(@as(usize, 4), plan.commandCount());
    try std.testing.expectEqual(@as(usize, 1), plan.bindPipelineCount());
    try std.testing.expectEqual(@as(usize, 1), plan.drawBatchCount());

    var too_small: [3]RenderEncoderCommand = undefined;
    try std.testing.expectError(error.RenderEncoderListFull, pass.encoderPlan(&too_small));
}

test "canvas render pass builds gpu packet for backend handoff" {
    const stops = [_]GradientStop{
        .{ .offset = 0, .color = Color.rgb8(255, 255, 255) },
        .{ .offset = 1, .color = Color.rgb8(37, 99, 235) },
    };
    const path = [_]PathElement{
        .{ .verb = .move_to, .points = .{ geometry.PointF.init(0, 0), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(12, 0), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(0, 12), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .close },
    };
    const commands = [_]CanvasCommand{
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 12, 12), .fill = .{ .color = Color.rgb8(255, 255, 255) } } },
        .{ .fill_rounded_rect = .{ .id = 2, .rect = geometry.RectF.init(16, 0, 24, 12), .radius = .{ .top_left = 3, .top_right = 5, .bottom_right = 6, .bottom_left = 2 }, .fill = .{ .linear_gradient = .{
            .start = geometry.PointF.init(16, 0),
            .end = geometry.PointF.init(40, 12),
            .stops = &stops,
        } } } },
        .{ .stroke_rect = .{ .id = 8, .rect = geometry.RectF.init(42, 0, 12, 12), .radius = Radius.all(3), .stroke = .{
            .fill = .{ .color = Color.rgb8(203, 213, 225) },
            .width = 2,
        } } },
        .{ .draw_line = .{ .id = 9, .from = geometry.PointF.init(58, 2), .to = geometry.PointF.init(70, 14), .stroke = .{
            .fill = .{ .linear_gradient = .{
                .start = geometry.PointF.init(58, 2),
                .end = geometry.PointF.init(70, 14),
                .stops = &stops,
            } },
            .width = 3,
        } } },
        .{ .fill_path = .{ .id = 3, .elements = &path, .fill = .{ .color = Color.rgb8(15, 23, 42) } } },
        .{ .draw_image = .{
            .id = 4,
            .image_id = 42,
            .src = geometry.RectF.init(4, 8, 32, 24),
            .dst = geometry.RectF.init(44, 0, 16, 16),
            .opacity = 0.75,
            .fit = .cover,
            .sampling = .nearest,
        } },
        .{ .draw_text = .{
            .id = 5,
            .font_id = 7,
            .size = 12,
            .origin = geometry.PointF.init(0, 32),
            .color = Color.rgb8(15, 23, 42),
            .text = "Hi",
            .text_layout = .{ .max_width = 80, .line_height = 16 },
        } },
        .{ .shadow = .{
            .id = 6,
            .rect = geometry.RectF.init(0, 36, 40, 20),
            .radius = Radius.all(6),
            .offset = geometry.OffsetF.init(2, 3),
            .blur = 8,
            .spread = 1,
            .color = Color.rgba8(15, 23, 42, 60),
        } },
        .{ .blur = .{ .id = 7, .rect = geometry.RectF.init(44, 36, 20, 20), .radius = 4 } },
    };

    var render_commands: [commands.len]RenderCommand = undefined;
    var render_batches: [commands.len]RenderBatch = undefined;
    var pipeline_cache_entries: [commands.len]RenderPipelineCacheEntry = undefined;
    var pipeline_cache_actions: [commands.len]RenderPipelineCacheAction = undefined;
    var path_geometries: [1]RenderPathGeometry = undefined;
    var path_geometry_cache_entries: [1]RenderPathGeometryCacheEntry = undefined;
    var path_geometry_cache_actions: [1]RenderPathGeometryCacheAction = undefined;
    var images: [1]RenderImage = undefined;
    var image_cache_entries: [1]RenderImageCacheEntry = undefined;
    var image_cache_actions: [1]RenderImageCacheAction = undefined;
    var resources: [6]RenderResource = undefined;
    var resource_cache_entries: [6]RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [6]RenderResourceCacheAction = undefined;
    var visual_effects: [2]VisualEffect = undefined;
    var visual_effect_cache_entries: [2]VisualEffectCacheEntry = undefined;
    var visual_effect_cache_actions: [2]VisualEffectCacheAction = undefined;
    var glyphs: [2]GlyphAtlasEntry = undefined;
    var glyph_cache_entries: [2]GlyphAtlasCacheEntry = undefined;
    var glyph_cache_actions: [2]GlyphAtlasCacheAction = undefined;
    var text_layouts: [1]TextLayoutPlan = undefined;
    var text_layout_lines: [1]TextLine = undefined;
    var text_layout_cache_entries: [1]TextLayoutCacheEntry = undefined;
    var text_layout_cache_actions: [1]TextLayoutCacheAction = undefined;
    var changes: [commands.len]DiffChange = undefined;
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .frame_index = 11,
        .timestamp_ns = 1234,
        .surface_size = geometry.SizeF.init(96, 72),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .pipeline_cache_entries = &pipeline_cache_entries,
        .pipeline_cache_actions = &pipeline_cache_actions,
        .path_geometries = &path_geometries,
        .path_geometry_cache_entries = &path_geometry_cache_entries,
        .path_geometry_cache_actions = &path_geometry_cache_actions,
        .images = &images,
        .image_cache_entries = &image_cache_entries,
        .image_cache_actions = &image_cache_actions,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .visual_effects = &visual_effects,
        .visual_effect_cache_entries = &visual_effect_cache_entries,
        .visual_effect_cache_actions = &visual_effect_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .glyph_atlas_cache_entries = &glyph_cache_entries,
        .glyph_atlas_cache_actions = &glyph_cache_actions,
        .text_layout_plans = &text_layouts,
        .text_layout_lines = &text_layout_lines,
        .text_layout_cache_entries = &text_layout_cache_entries,
        .text_layout_cache_actions = &text_layout_cache_actions,
        .changes = &changes,
    });

    var gpu_commands: [commands.len]CanvasGpuCommand = undefined;
    const packet = try frame.gpuPacket(&gpu_commands);
    try std.testing.expect(packet.requiresRender());
    try std.testing.expect(packet.fullyRepresentable());
    try std.testing.expectEqual(@as(u64, 11), packet.frame_index);
    try std.testing.expectEqual(@as(u64, 1234), packet.timestamp_ns);
    try std.testing.expectEqual(CanvasRenderPassLoadAction.clear, packet.load_action);
    try expectRect(geometry.RectF.init(0, 0, 96, 72), packet.scissor.?);
    try std.testing.expectEqual(@as(usize, commands.len), packet.commandCount());
    try std.testing.expectEqual(frame.renderPass().batchCount(), packet.batch_count);
    try std.testing.expectEqual(frame.renderPass().encoderCacheActionCount(), packet.cacheActionCount());
    try std.testing.expectEqual(@as(usize, 7), packet.cachedResourceCommandCount());
    try std.testing.expectEqual(@as(usize, 0), packet.unsupported_command_count);

    try std.testing.expectEqual(CanvasGpuCommandKind.fill_rect_solid, packet.commands[0].kind);
    try std.testing.expectEqual(@as(?RenderPipelineKind, .solid), packet.commands[0].pipeline);
    switch (packet.commands[0].shape) {
        .rect => |rect_value| try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 12, 12), rect_value),
        else => return error.TestExpectedEqual,
    }
    try expectGpuPaintColor(Color.rgb8(255, 255, 255), packet.commands[0].paint);
    try std.testing.expect(!packet.commands[0].usesCachedResource());
    try std.testing.expectEqual(CanvasGpuCommandKind.fill_rounded_rect_gradient, packet.commands[1].kind);
    try std.testing.expectEqual(@as(?RenderPipelineKind, .linear_gradient), packet.commands[1].pipeline);
    switch (packet.commands[1].shape) {
        .rounded_rect => |rounded_rect| {
            try std.testing.expectEqualDeep(geometry.RectF.init(16, 0, 24, 12), rounded_rect.rect);
            try std.testing.expectEqualDeep(Radius{ .top_left = 3, .top_right = 5, .bottom_right = 6, .bottom_left = 2 }, rounded_rect.radius);
        },
        else => return error.TestExpectedEqual,
    }
    switch (packet.commands[1].paint) {
        .linear_gradient => |gradient| {
            try std.testing.expectEqualDeep(geometry.PointF.init(16, 0), gradient.start);
            try std.testing.expectEqualDeep(geometry.PointF.init(40, 12), gradient.end);
            try std.testing.expectEqual(@as(usize, 2), gradient.stops.len);
        },
        else => return error.TestExpectedEqual,
    }
    try std.testing.expect(packet.commands[1].uses_resource);
    try std.testing.expectEqual(CanvasGpuCommandKind.stroke_rect_solid, packet.commands[2].kind);
    switch (packet.commands[2].shape) {
        .stroke_rect => |stroke_rect| {
            try std.testing.expectEqualDeep(geometry.RectF.init(42, 0, 12, 12), stroke_rect.rect);
            try std.testing.expectEqualDeep(Radius.all(3), stroke_rect.radius);
            try std.testing.expectEqual(@as(f32, 2), stroke_rect.width);
        },
        else => return error.TestExpectedEqual,
    }
    try expectGpuPaintColor(Color.rgb8(203, 213, 225), packet.commands[2].paint);
    try std.testing.expectEqual(@as(f32, 2), packet.commands[2].stroke_width);
    try std.testing.expectEqual(CanvasGpuCommandKind.draw_line_gradient, packet.commands[3].kind);
    switch (packet.commands[3].shape) {
        .line => |line| {
            try std.testing.expectEqualDeep(geometry.PointF.init(58, 2), line.from);
            try std.testing.expectEqualDeep(geometry.PointF.init(70, 14), line.to);
            try std.testing.expectEqual(@as(f32, 3), line.width);
        },
        else => return error.TestExpectedEqual,
    }
    switch (packet.commands[3].paint) {
        .linear_gradient => |gradient| {
            try std.testing.expectEqualDeep(geometry.PointF.init(58, 2), gradient.start);
            try std.testing.expectEqualDeep(geometry.PointF.init(70, 14), gradient.end);
        },
        else => return error.TestExpectedEqual,
    }
    try std.testing.expectEqual(CanvasGpuCommandKind.fill_path, packet.commands[4].kind);
    try std.testing.expect(packet.commands[4].uses_path_geometry);
    switch (packet.commands[4].shape) {
        .path => |elements| {
            try std.testing.expectEqual(@as(usize, 4), elements.len);
            try std.testing.expectEqual(PathVerb.move_to, elements[0].verb);
            try std.testing.expectEqual(PathVerb.line_to, elements[1].verb);
            try std.testing.expectEqual(PathVerb.close, elements[3].verb);
        },
        else => return error.TestExpectedEqual,
    }
    try expectGpuPaintColor(Color.rgb8(15, 23, 42), packet.commands[4].paint);
    try std.testing.expectEqual(CanvasGpuCommandKind.draw_image, packet.commands[5].kind);
    try std.testing.expect(packet.commands[5].uses_image);
    try std.testing.expect(packet.commands[5].image != null);
    try std.testing.expectEqual(@as(ImageId, 42), packet.commands[5].image.?.image_id);
    try std.testing.expectEqualDeep(geometry.RectF.init(4, 8, 32, 24), packet.commands[5].image.?.src.?);
    try std.testing.expectEqualDeep(geometry.RectF.init(44, 0, 16, 16), packet.commands[5].image.?.dst);
    try std.testing.expectEqual(@as(f32, 0.75), packet.commands[5].image.?.opacity);
    try std.testing.expectEqual(ImageFit.cover, packet.commands[5].image.?.fit);
    try std.testing.expectEqual(ImageSampling.nearest, packet.commands[5].image.?.sampling);
    try std.testing.expectEqual(CanvasGpuCommandKind.draw_text, packet.commands[6].kind);
    try std.testing.expect(packet.commands[6].uses_glyph_atlas);
    try std.testing.expect(packet.commands[6].uses_text_layout);
    try expectGpuPaintColor(Color.rgb8(15, 23, 42), packet.commands[6].paint);
    try std.testing.expect(packet.commands[6].text != null);
    try std.testing.expectEqual(@as(FontId, 7), packet.commands[6].text.?.font_id);
    try std.testing.expectEqual(@as(f32, 12), packet.commands[6].text.?.size);
    try std.testing.expectEqualDeep(geometry.PointF.init(0, 32), packet.commands[6].text.?.origin);
    try std.testing.expectEqualDeep(Color.rgb8(15, 23, 42), packet.commands[6].text.?.color);
    try std.testing.expectEqualStrings("Hi", packet.commands[6].text.?.text);
    try std.testing.expect(packet.commands[6].text.?.text_layout != null);
    try std.testing.expectEqual(@as(f32, 80), packet.commands[6].text.?.text_layout.?.max_width);
    try std.testing.expectEqual(@as(f32, 16), packet.commands[6].text.?.text_layout.?.line_height);
    try std.testing.expectEqual(CanvasGpuCommandKind.shadow, packet.commands[7].kind);
    try std.testing.expect(packet.commands[7].uses_visual_effect);
    switch (packet.commands[7].effect) {
        .shadow => |shadow| {
            try std.testing.expectEqualDeep(geometry.RectF.init(0, 36, 40, 20), shadow.rect);
            try std.testing.expectEqualDeep(Radius.all(6), shadow.radius);
            try std.testing.expectEqualDeep(geometry.OffsetF.init(2, 3), shadow.offset);
            try std.testing.expectEqual(@as(f32, 8), shadow.blur);
            try std.testing.expectEqual(@as(f32, 1), shadow.spread);
            try std.testing.expectEqualDeep(Color.rgba8(15, 23, 42, 60), shadow.color);
        },
        else => return error.TestExpectedEqual,
    }
    try std.testing.expectEqual(CanvasGpuCommandKind.blur, packet.commands[8].kind);
    try std.testing.expect(packet.commands[8].uses_visual_effect);
    switch (packet.commands[8].effect) {
        .blur => |blur| {
            try std.testing.expectEqualDeep(geometry.RectF.init(44, 36, 20, 20), blur.rect);
            try std.testing.expectEqual(@as(f32, 4), blur.radius);
        },
        else => return error.TestExpectedEqual,
    }

    var packet_json_buffer: [16384]u8 = undefined;
    var packet_json_writer = std.Io.Writer.fixed(&packet_json_buffer);
    try packet.writeJson(&packet_json_writer);
    const packet_json = packet_json_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, packet_json, "\"loadAction\":\"clear\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, packet_json, "\"commandCount\":9") != null);
    try std.testing.expect(std.mem.indexOf(u8, packet_json, "\"kind\":\"fill_rounded_rect_gradient\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, packet_json, "\"shape\":{\"kind\":\"rounded_rect\",\"rect\":[16,0,24,12],\"radius\":[3,5,6,2]}") != null);
    try std.testing.expect(std.mem.indexOf(u8, packet_json, "\"paint\":{\"kind\":\"linear_gradient\",\"start\":[16,0],\"end\":[40,12]") != null);
    try std.testing.expect(std.mem.indexOf(u8, packet_json, "\"shape\":{\"kind\":\"path\",\"path\":[{\"verb\":\"move_to\",\"points\":[[0,0]]},{\"verb\":\"line_to\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, packet_json, "\"image\":{\"image\":42,\"src\":[4,8,32,24],\"dst\":[44,0,16,16],\"opacity\":0.75,\"fit\":\"cover\",\"sampling\":\"nearest\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, packet_json, "\"text\":{\"font\":7,\"size\":12,\"origin\":[0,32]") != null);
    try std.testing.expect(std.mem.indexOf(u8, packet_json, "\"effect\":{\"kind\":\"shadow\",\"rect\":[0,36,40,20],\"radius\":[6,6,6,6],\"offset\":[2,3],\"blur\":8,\"spread\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, packet_json, "\"effect\":{\"kind\":\"blur\",\"rect\":[44,36,20,20],\"radius\":4}") != null);
}

test "canvas gpu packet skips clean passes and reports output overflow" {
    var clean_gpu_commands: [1]CanvasGpuCommand = undefined;
    const clean_packet = try (CanvasRenderPass{}).gpuPacket(&clean_gpu_commands);
    try std.testing.expect(!clean_packet.requiresRender());
    try std.testing.expect(clean_packet.fullyRepresentable());
    try std.testing.expectEqual(@as(usize, 0), clean_packet.commandCount());
    var clean_packet_json_buffer: [512]u8 = undefined;
    var clean_packet_json_writer = std.Io.Writer.fixed(&clean_packet_json_buffer);
    try clean_packet.writeJson(&clean_packet_json_writer);
    try std.testing.expectEqualStrings(
        "{\"frameIndex\":0,\"timestampNs\":0,\"surfaceWidth\":0,\"surfaceHeight\":0,\"scale\":1,\"loadAction\":\"skip\",\"requiresRender\":false,\"scissorBounds\":null,\"commandCount\":0,\"cacheActionCount\":0,\"cachedResourceCommandCount\":0,\"unsupportedCommandCount\":0,\"representable\":true,\"images\":[],\"imageActions\":[],\"commands\":[]}",
        clean_packet_json_writer.buffered(),
    );

    const render_commands = [_]RenderCommand{.{
        .command = .{ .fill_rect = .{
            .id = 1,
            .rect = geometry.RectF.init(0, 0, 10, 10),
            .fill = .{ .color = Color.rgb8(255, 255, 255) },
        } },
        .id = 1,
        .local_bounds = geometry.RectF.init(0, 0, 10, 10),
        .bounds = geometry.RectF.init(0, 0, 10, 10),
    }};
    const pass = CanvasRenderPass{
        .full_repaint = true,
        .commands = &render_commands,
    };
    var no_gpu_commands: [0]CanvasGpuCommand = .{};
    try std.testing.expectError(error.CanvasGpuCommandListFull, pass.gpuPacket(&no_gpu_commands));
}

test "canvas gpu packet text serializes engine measured line breaks" {
    // Tight intrinsic box: max_width equals the engine-measured width, so
    // the engine keeps one line and the packet must carry it unbroken —
    // the host draws these lines verbatim instead of re-wrapping with its
    // own line breaker.
    const tight_width = estimateTextWidth("Songs", 12);
    // 70 explicit lines exceed the packet line budget (64): the serializer
    // must fall back to `null` so the host keeps its wrapping fallback.
    const overflow_text = "a\n" ** 70;
    const commands = [_]CanvasGpuCommand{
        .{
            .command_index = 0,
            .kind = .draw_text,
            .pipeline = .glyph_run,
            .text = .{
                .font_id = 1,
                .size = 12,
                .origin = geometry.PointF.init(4, 40),
                .color = Color.rgb8(0, 0, 0),
                .text = "Songs",
                .text_layout = .{ .max_width = tight_width, .line_height = 16 },
            },
            .uses_glyph_atlas = true,
            .uses_text_layout = true,
        },
        .{
            .command_index = 1,
            .kind = .draw_text,
            .pipeline = .glyph_run,
            .text = .{
                .font_id = 1,
                .size = 12,
                .origin = geometry.PointF.init(4, 40),
                .color = Color.rgb8(0, 0, 0),
                .text = "Song s",
                .text_layout = .{ .max_width = estimateTextWidth("Song", 12) + 1, .line_height = 16 },
            },
            .uses_glyph_atlas = true,
            .uses_text_layout = true,
        },
        .{
            .command_index = 2,
            .kind = .draw_text,
            .pipeline = .glyph_run,
            .text = .{
                .font_id = 1,
                .size = 12,
                .origin = geometry.PointF.init(4, 40),
                .color = Color.rgb8(0, 0, 0),
                .text = overflow_text,
                .text_layout = .{ .line_height = 16 },
            },
            .uses_glyph_atlas = true,
            .uses_text_layout = true,
        },
        .{
            .command_index = 3,
            .kind = .draw_text,
            .pipeline = .glyph_run,
            .text = .{
                .font_id = 1,
                .size = 12,
                .origin = geometry.PointF.init(4, 40),
                .color = Color.rgb8(0, 0, 0),
                .text = "Free",
            },
            .uses_glyph_atlas = true,
        },
        // Multibyte exact fit: every byte of a UTF-8-heavy string rides one
        // unbroken line — the live-window shape of the system-monitor
        // "drops one trailing glyph per multibyte codepoint" finding, whose
        // packet leg was the host re-wrapping tight boxes.
        .{
            .command_index = 4,
            .kind = .draw_text,
            .pipeline = .glyph_run,
            .text = .{
                .font_id = 1,
                .size = 12,
                .origin = geometry.PointF.init(4, 40),
                .color = Color.rgb8(0, 0, 0),
                .text = "Live \xc2\xb7 every 2 s",
                .text_layout = .{ .max_width = estimateTextWidth("Live \xc2\xb7 every 2 s", 12), .line_height = 16 },
            },
            .uses_glyph_atlas = true,
            .uses_text_layout = true,
        },
    };
    const packet = CanvasGpuPacket{ .load_action = .clear, .commands = &commands };

    var packet_json_buffer: [16384]u8 = undefined;
    var packet_json_writer = std.Io.Writer.fixed(&packet_json_buffer);
    try packet.writeJson(&packet_json_writer);
    const packet_json = packet_json_writer.buffered();

    // Exact-fit box: exactly one line, the full text, at the pen origin.
    try std.testing.expect(std.mem.indexOf(u8, packet_json, "\"lines\":[{\"x\":4,\"baseline\":40,\"text\":\"Songs\"}]") != null);
    // Engine word wrap carries through: the trailing break is trimmed and
    // the second line advances one line height.
    try std.testing.expect(std.mem.indexOf(u8, packet_json, "\"lines\":[{\"x\":4,\"baseline\":40,\"text\":\"Song\"},{\"x\":4,\"baseline\":56,\"text\":\"s\"}]") != null);
    // Line-budget overflow degrades to null (host wrapping fallback).
    try std.testing.expect(std.mem.indexOf(u8, packet_json, "\"lines\":null") != null);
    // Multibyte exact fit: one line, all bytes present, tail intact.
    try std.testing.expect(std.mem.indexOf(u8, packet_json, "\"lines\":[{\"x\":4,\"baseline\":40,\"text\":\"Live \xc2\xb7 every 2 s\"}]") != null);
    // No layout options -> no lines key at all.
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, packet_json, "\"lines\":"));
}

test "canvas gpu packet serializes image upload payloads" {
    const image_pixels = [_]u8{ 11, 22, 33, 255 };
    const image_resources = [_]ReferenceImage{.{
        .id = 42,
        .width = 1,
        .height = 1,
        .pixels = &image_pixels,
    }};
    const commands = [_]CanvasCommand{.{ .draw_image = .{
        .id = 7,
        .image_id = 42,
        .dst = geometry.RectF.init(0, 0, 8, 8),
        .sampling = .nearest,
    } }};

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var images: [1]RenderImage = undefined;
    var image_cache_entries: [1]RenderImageCacheEntry = undefined;
    var image_cache_actions: [1]RenderImageCacheAction = undefined;
    var resources: [1]RenderResource = undefined;
    var resource_cache_entries: [1]RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [1]RenderResourceCacheAction = undefined;
    var glyph_atlas_entries: [0]GlyphAtlasEntry = .{};
    var changes: [1]DiffChange = undefined;
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .frame_index = 12,
        .surface_size = geometry.SizeF.init(8, 8),
        .image_resources = &image_resources,
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .images = &images,
        .image_cache_entries = &image_cache_entries,
        .image_cache_actions = &image_cache_actions,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyph_atlas_entries,
        .changes = &changes,
    });

    var gpu_commands: [1]CanvasGpuCommand = undefined;
    const packet = try frame.gpuPacket(&gpu_commands);
    try std.testing.expectEqual(@as(usize, 1), packet.images.len);
    try std.testing.expectEqual(@as(usize, 1), packet.image_actions.len);
    try std.testing.expectEqualSlices(u8, &image_pixels, packet.images[0].pixels);

    var packet_json_buffer: [2048]u8 = undefined;
    var packet_json_writer = std.Io.Writer.fixed(&packet_json_buffer);
    try packet.writeJson(&packet_json_writer);
    const packet_json = packet_json_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, packet_json, "\"images\":[{\"imageId\":42") != null);
    // Pixels never ride packet JSON — uploads travel the binary
    // side-channel; the packet carries the id + fingerprint reference.
    try std.testing.expect(std.mem.indexOf(u8, packet_json, "\"width\":1,\"height\":1,\"fingerprint\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, packet_json, "\"pixels\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, packet_json, "\"imageActions\":[{\"kind\":\"upload\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, packet_json, "\"image\":{\"image\":42") != null);

    var retained_render_commands: [1]RenderCommand = undefined;
    var retained_render_batches: [1]RenderBatch = undefined;
    var retained_images: [1]RenderImage = undefined;
    var retained_image_cache_entries: [1]RenderImageCacheEntry = undefined;
    var retained_image_cache_actions: [1]RenderImageCacheAction = undefined;
    var retained_resources: [1]RenderResource = undefined;
    var retained_resource_cache_entries: [1]RenderResourceCacheEntry = undefined;
    var retained_resource_cache_actions: [1]RenderResourceCacheAction = undefined;
    var retained_glyph_atlas_entries: [0]GlyphAtlasEntry = .{};
    var retained_changes: [1]DiffChange = undefined;
    const retained_frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .frame_index = 13,
        .surface_size = geometry.SizeF.init(8, 8),
        .full_repaint = true,
        .previous_image_cache = frame.image_cache_plan.entries,
        .image_resources = &image_resources,
    }, .{
        .render_commands = &retained_render_commands,
        .render_batches = &retained_render_batches,
        .images = &retained_images,
        .image_cache_entries = &retained_image_cache_entries,
        .image_cache_actions = &retained_image_cache_actions,
        .resources = &retained_resources,
        .resource_cache_entries = &retained_resource_cache_entries,
        .resource_cache_actions = &retained_resource_cache_actions,
        .glyph_atlas_entries = &retained_glyph_atlas_entries,
        .changes = &retained_changes,
    });
    try std.testing.expectEqual(@as(usize, 0), retained_frame.image_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), retained_frame.image_cache_plan.retainCount());

    var retained_gpu_commands: [1]CanvasGpuCommand = undefined;
    const retained_packet = try retained_frame.gpuPacket(&retained_gpu_commands);
    var retained_packet_json_buffer: [2048]u8 = undefined;
    var retained_packet_json_writer = std.Io.Writer.fixed(&retained_packet_json_buffer);
    try retained_packet.writeJson(&retained_packet_json_writer);
    const retained_packet_json = retained_packet_json_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, retained_packet_json, "\"imageActions\":[{\"kind\":\"retain\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, retained_packet_json, "\"width\":1,\"height\":1,\"fingerprint\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, retained_packet_json, "\"pixels\"") == null);
}

test "canvas frame plan carries path geometry cache actions" {
    const path = [_]PathElement{
        .{ .verb = .move_to, .points = .{ geometry.PointF.init(0, 0), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(20, 0), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(0, 20), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .close },
    };
    const commands = [_]CanvasCommand{.{ .fill_path = .{
        .id = 1,
        .elements = &path,
        .fill = .{ .color = Color.rgb8(255, 255, 255) },
    } }};

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var pipeline_cache_entries: [1]RenderPipelineCacheEntry = undefined;
    var pipeline_cache_actions: [1]RenderPipelineCacheAction = undefined;
    var path_geometries: [1]RenderPathGeometry = undefined;
    var path_geometry_cache_entries: [1]RenderPathGeometryCacheEntry = undefined;
    var path_geometry_cache_actions: [1]RenderPathGeometryCacheAction = undefined;
    var resources: [0]RenderResource = .{};
    var resource_cache_entries: [0]RenderResourceCacheEntry = .{};
    var resource_cache_actions: [0]RenderResourceCacheAction = .{};
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [1]DiffChange = undefined;
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .frame_index = 4,
        .surface_size = geometry.SizeF.init(64, 64),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .pipeline_cache_entries = &pipeline_cache_entries,
        .pipeline_cache_actions = &pipeline_cache_actions,
        .path_geometries = &path_geometries,
        .path_geometry_cache_entries = &path_geometry_cache_entries,
        .path_geometry_cache_actions = &path_geometry_cache_actions,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    try std.testing.expectEqual(@as(usize, 1), frame.path_geometry_plan.geometryCount());
    try std.testing.expectEqual(@as(usize, 3), frame.path_geometry_plan.vertexCount());
    try std.testing.expectEqual(@as(usize, 3), frame.path_geometry_plan.indexCount());
    try std.testing.expectEqual(@as(usize, 1), frame.path_geometry_cache_plan.entryCount());
    try std.testing.expectEqual(@as(usize, 1), frame.path_geometry_cache_plan.uploadCount());
    try std.testing.expectEqual(RenderPathGeometryCacheActionKind.upload, frame.path_geometry_cache_plan.actions[0].kind);

    const render_pass = frame.renderPass();
    try std.testing.expectEqual(@as(usize, 1), render_pass.pathGeometryCount());
    try std.testing.expectEqual(@as(usize, 1), render_pass.pathGeometryActionCount());
    try std.testing.expectEqual(@as(usize, 3), render_pass.pathGeometryVertexCount());
    try std.testing.expectEqual(@as(usize, 3), render_pass.pathGeometryIndexCount());
    try std.testing.expectEqual(@as(usize, 2), render_pass.encoderCacheActionCount());

    var encoder_commands: [8]RenderEncoderCommand = undefined;
    const encoder_plan = try render_pass.encoderPlan(&encoder_commands);
    try std.testing.expectEqual(@as(usize, 7), encoder_plan.commandCount());
    try std.testing.expectEqual(@as(usize, 2), encoder_plan.cacheActionCount());
    switch (encoder_plan.commands[2]) {
        .pipeline_cache => |action| try std.testing.expectEqual(RenderPipelineKind.path, action.pipeline),
        else => return error.TestExpectedEqual,
    }
    switch (encoder_plan.commands[3]) {
        .path_geometry_cache => |action| {
            try std.testing.expectEqual(RenderPathGeometryCacheActionKind.upload, action.kind);
            try std.testing.expectEqual(RenderPathGeometryKind.fill, action.key.kind);
            try std.testing.expectEqual(@as(?ObjectId, 1), action.key.id);
        },
        else => return error.TestExpectedEqual,
    }

    const diagnostics = frame.diagnostics();
    try std.testing.expectEqual(@as(usize, 1), diagnostics.path_geometry_count);
    try std.testing.expectEqual(@as(usize, 3), diagnostics.path_geometry_vertex_count);
    try std.testing.expectEqual(@as(usize, 3), diagnostics.path_geometry_index_count);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.path_geometry_upload_count);
}

test "canvas frame plan carries image cache actions" {
    const commands = [_]CanvasCommand{.{ .draw_image = .{
        .id = 1,
        .image_id = 42,
        .dst = geometry.RectF.init(8, 8, 24, 24),
    } }};

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var pipeline_cache_entries: [1]RenderPipelineCacheEntry = undefined;
    var pipeline_cache_actions: [1]RenderPipelineCacheAction = undefined;
    var images: [1]RenderImage = undefined;
    var image_cache_entries: [1]RenderImageCacheEntry = undefined;
    var image_cache_actions: [1]RenderImageCacheAction = undefined;
    var resources: [1]RenderResource = undefined;
    var resource_cache_entries: [1]RenderResourceCacheEntry = undefined;
    var resource_cache_actions: [1]RenderResourceCacheAction = undefined;
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [1]DiffChange = undefined;
    const frame = try (DisplayList{ .commands = &commands }).framePlan(null, .{
        .frame_index = 6,
        .surface_size = geometry.SizeF.init(64, 64),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .pipeline_cache_entries = &pipeline_cache_entries,
        .pipeline_cache_actions = &pipeline_cache_actions,
        .images = &images,
        .image_cache_entries = &image_cache_entries,
        .image_cache_actions = &image_cache_actions,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    try std.testing.expectEqual(@as(usize, 1), frame.image_plan.imageCount());
    try std.testing.expectEqual(@as(usize, 1), frame.image_plan.drawCount());
    try std.testing.expectEqual(@as(ImageId, 42), frame.image_plan.images[0].image_id);
    try std.testing.expectEqual(@as(usize, 1), frame.image_cache_plan.entryCount());
    try std.testing.expectEqual(@as(usize, 1), frame.image_cache_plan.uploadCount());
    try std.testing.expectEqual(RenderImageCacheActionKind.upload, frame.image_cache_plan.actions[0].kind);

    const render_pass = frame.renderPass();
    try std.testing.expectEqual(@as(usize, 1), render_pass.imageCount());
    try std.testing.expectEqual(@as(usize, 1), render_pass.imageActionCount());
    try std.testing.expectEqual(@as(usize, 3), render_pass.encoderCacheActionCount());

    var encoder_commands: [8]RenderEncoderCommand = undefined;
    const encoder_plan = try render_pass.encoderPlan(&encoder_commands);
    try std.testing.expectEqual(@as(usize, 8), encoder_plan.commandCount());
    try std.testing.expectEqual(@as(usize, 3), encoder_plan.cacheActionCount());
    switch (encoder_plan.commands[2]) {
        .pipeline_cache => |action| try std.testing.expectEqual(RenderPipelineKind.image, action.pipeline),
        else => return error.TestExpectedEqual,
    }
    switch (encoder_plan.commands[3]) {
        .image_cache => |action| {
            try std.testing.expectEqual(RenderImageCacheActionKind.upload, action.kind);
            try std.testing.expectEqual(@as(ImageId, 42), action.key.image_id);
        },
        else => return error.TestExpectedEqual,
    }

    const diagnostics = frame.diagnostics();
    try std.testing.expectEqual(@as(usize, 1), diagnostics.image_count);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.image_upload_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.image_retain_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.image_evict_count);

    const profile = frame.profile();
    try std.testing.expectEqual(@as(u64, 6), profile.frame_index);
    try std.testing.expect(profile.requires_render);
    try std.testing.expect(profile.full_repaint);
    try std.testing.expectEqual(@as(usize, 3), profile.cache_action_count);
    try std.testing.expectEqual(@as(usize, 3), profile.cache_upload_count);
    try std.testing.expectEqual(@as(usize, 1), profile.image_count);
    try std.testing.expectEqual(CanvasFrameProfileRisk.high, profile.risk);
}

test "canvas frame plan carries resource cache retain upload and evict actions" {
    const stops = [_]GradientStop{
        .{ .offset = 0, .color = Color.rgb8(255, 255, 255) },
        .{ .offset = 1, .color = Color.rgb8(24, 24, 27) },
    };
    const previous_commands = [_]CanvasCommand{
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 20, 20), .fill = .{ .linear_gradient = .{
            .start = geometry.PointF.init(0, 0),
            .end = geometry.PointF.init(20, 20),
            .stops = &stops,
        } } } },
        .{ .draw_image = .{ .id = 2, .image_id = 8, .dst = geometry.RectF.init(24, 0, 20, 20) } },
    };
    const next_commands = [_]CanvasCommand{
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 20, 20), .fill = .{ .linear_gradient = .{
            .start = geometry.PointF.init(0, 0),
            .end = geometry.PointF.init(20, 20),
            .stops = &stops,
        } } } },
        .{ .draw_text = .{
            .id = 3,
            .font_id = 7,
            .size = 12,
            .origin = geometry.PointF.init(24, 16),
            .color = Color.rgb8(15, 23, 42),
            .text = "Hi",
        } },
    };

    var previous_render_commands: [2]RenderCommand = undefined;
    var previous_render_batches: [2]RenderBatch = undefined;
    var previous_resources: [2]RenderResource = undefined;
    var previous_cache_entries: [2]RenderResourceCacheEntry = undefined;
    var previous_cache_actions: [2]RenderResourceCacheAction = undefined;
    var previous_glyphs: [0]GlyphAtlasEntry = .{};
    var previous_changes: [0]DiffChange = .{};
    const previous_frame = try (DisplayList{ .commands = &previous_commands }).framePlan(null, .{
        .frame_index = 1,
    }, .{
        .render_commands = &previous_render_commands,
        .render_batches = &previous_render_batches,
        .resources = &previous_resources,
        .resource_cache_entries = &previous_cache_entries,
        .resource_cache_actions = &previous_cache_actions,
        .glyph_atlas_entries = &previous_glyphs,
        .changes = &previous_changes,
    });

    var next_render_commands: [2]RenderCommand = undefined;
    var next_render_batches: [2]RenderBatch = undefined;
    var next_resources: [2]RenderResource = undefined;
    var next_cache_entries: [2]RenderResourceCacheEntry = undefined;
    var next_cache_actions: [3]RenderResourceCacheAction = undefined;
    var next_glyphs: [2]GlyphAtlasEntry = undefined;
    var next_glyph_cache_entries: [2]GlyphAtlasCacheEntry = undefined;
    var next_glyph_cache_actions: [2]GlyphAtlasCacheAction = undefined;
    var next_changes: [2]DiffChange = undefined;
    const next_frame = try (DisplayList{ .commands = &next_commands }).framePlan(.{ .commands = &previous_commands }, .{
        .frame_index = 2,
        .previous_resource_cache = previous_frame.resource_cache_plan.entries,
    }, .{
        .render_commands = &next_render_commands,
        .render_batches = &next_render_batches,
        .resources = &next_resources,
        .resource_cache_entries = &next_cache_entries,
        .resource_cache_actions = &next_cache_actions,
        .glyph_atlas_entries = &next_glyphs,
        .glyph_atlas_cache_entries = &next_glyph_cache_entries,
        .glyph_atlas_cache_actions = &next_glyph_cache_actions,
        .changes = &next_changes,
    });

    try std.testing.expectEqual(@as(usize, 2), next_frame.resource_cache_plan.entryCount());
    try std.testing.expectEqual(@as(usize, 3), next_frame.resource_cache_plan.actionCount());
    try std.testing.expectEqual(@as(usize, 1), next_frame.resource_cache_plan.retainCount());
    try std.testing.expectEqual(@as(usize, 1), next_frame.resource_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 1), next_frame.resource_cache_plan.evictCount());
    try std.testing.expectEqual(RenderResourceCacheActionKind.retain, next_frame.resource_cache_plan.actions[0].kind);
    try std.testing.expectEqual(RenderResourceKind.linear_gradient, next_frame.resource_cache_plan.actions[0].key.kind);
    try std.testing.expectEqual(RenderResourceCacheActionKind.upload, next_frame.resource_cache_plan.actions[1].kind);
    try std.testing.expectEqual(RenderResourceKind.glyph_run, next_frame.resource_cache_plan.actions[1].key.kind);
    try std.testing.expectEqual(RenderResourceCacheActionKind.evict, next_frame.resource_cache_plan.actions[2].kind);
    try std.testing.expectEqual(RenderResourceKind.image, next_frame.resource_cache_plan.actions[2].key.kind);
    try std.testing.expectEqual(@as(u64, 2), next_frame.resource_cache_plan.entries[0].last_used_frame);
    try std.testing.expectEqual(@as(usize, 2), next_frame.glyph_atlas_cache_plan.uploadCount());

    const diagnostics = next_frame.diagnostics();
    try std.testing.expectEqual(@as(usize, 1), diagnostics.resource_retain_count);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.resource_upload_count);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.resource_evict_count);
    try std.testing.expectEqual(@as(usize, 2), diagnostics.glyph_atlas_upload_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.glyph_atlas_retain_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.glyph_atlas_evict_count);
    try std.testing.expectEqual(@as(usize, 2), diagnostics.change_count);
}

test "canvas frame plan clips incremental dirty bounds to surface" {
    const previous_commands = [_]CanvasCommand{
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 40, 40), .fill = .{ .color = Color.rgb8(255, 255, 255) } } },
        .{ .fill_rect = .{ .id = 2, .rect = geometry.RectF.init(70, 0, 20, 20), .fill = .{ .color = Color.rgb8(0, 0, 0) } } },
    };
    const next_commands = [_]CanvasCommand{
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(20, 0, 40, 40), .fill = .{ .color = Color.rgb8(255, 255, 255) } } },
        .{ .fill_rect = .{ .id = 2, .rect = geometry.RectF.init(70, 0, 20, 20), .fill = .{ .color = Color.rgb8(0, 0, 0) } } },
    };

    var render_commands: [2]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [0]RenderResource = .{};
    var resource_cache_entries: [0]RenderResourceCacheEntry = .{};
    var resource_cache_actions: [0]RenderResourceCacheAction = .{};
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [2]DiffChange = undefined;
    const frame = try (DisplayList{ .commands = &next_commands }).framePlan(.{ .commands = &previous_commands }, .{
        .surface_size = geometry.SizeF.init(50, 50),
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    try std.testing.expect(!frame.full_repaint);
    try std.testing.expect(frame.requiresRender());
    try std.testing.expectEqual(@as(usize, 1), frame.batch_plan.batchCount());
    try std.testing.expectEqual(@as(usize, 1), frame.changes.len);
    try std.testing.expectEqual(DiffKind.changed, frame.changes[0].kind);
    try std.testing.expectEqual(@as(?ObjectId, 1), frame.changes[0].id);
    try expectRect(geometry.RectF.init(0, 0, 50, 40), frame.dirty_bounds);

    const render_pass = frame.renderPass();
    try std.testing.expect(render_pass.requiresRender());
    try std.testing.expectEqual(CanvasRenderPassLoadAction.load, render_pass.loadAction());
    try std.testing.expectEqual(@as(usize, 2), render_pass.commandCount());
    try std.testing.expectEqual(@as(usize, 1), render_pass.batchCount());
    try expectRect(geometry.RectF.init(0, 0, 50, 40), render_pass.scissorBounds());

    var gpu_commands: [2]CanvasGpuCommand = undefined;
    const packet = try frame.gpuPacket(&gpu_commands);
    try std.testing.expect(packet.requiresRender());
    try std.testing.expect(packet.fullyRepresentable());
    try std.testing.expectEqual(CanvasRenderPassLoadAction.load, packet.load_action);
    try std.testing.expectEqual(@as(usize, 1), packet.commandCount());
    try std.testing.expectEqual(@as(?ObjectId, 1), packet.commands[0].id);
    const packet_summary = frame.gpuPacketSummary();
    try std.testing.expectEqual(packet.commandCount(), packet_summary.command_count);
    try std.testing.expectEqual(packet.cachedResourceCommandCount(), packet_summary.cached_resource_command_count);
    try std.testing.expectEqual(packet.unsupported_command_count, packet_summary.unsupported_command_count);
    try expectRect(geometry.RectF.init(0, 0, 50, 40), packet.scissor.?);
    var packet_json_buffer: [2048]u8 = undefined;
    var packet_json_writer = std.Io.Writer.fixed(&packet_json_buffer);
    try packet.writeJson(&packet_json_writer);
    const packet_json = packet_json_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, packet_json, "\"loadAction\":\"load\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, packet_json, "\"scissorBounds\":[0,0,50,40]") != null);

    const profile = frame.profile();
    try std.testing.expect(profile.requires_render);
    try std.testing.expect(!profile.full_repaint);
    try std.testing.expectEqual(@as(f32, 2500), profile.surface_area);
    try std.testing.expectEqual(@as(f32, 2000), profile.dirty_area);
    try std.testing.expectEqual(@as(f32, 0.8), profile.dirty_ratio);
    try std.testing.expectEqual(CanvasFrameProfileRisk.high, profile.risk);

    var profile_json_buffer: [1024]u8 = undefined;
    var profile_json_writer = std.Io.Writer.fixed(&profile_json_buffer);
    try frame.writeProfileJson(&profile_json_writer);
    const profile_json = profile_json_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, profile_json, "\"dirtyArea\":2000") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile_json, "\"risk\":\"high\"") != null);
}

test "canvas frame plan leaves unchanged retained frame clean" {
    const commands = [_]CanvasCommand{
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 40, 40), .fill = .{ .color = Color.rgb8(255, 255, 255) } } },
    };

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [0]RenderResource = .{};
    var resource_cache_entries: [0]RenderResourceCacheEntry = .{};
    var resource_cache_actions: [0]RenderResourceCacheAction = .{};
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [1]DiffChange = undefined;
    const frame = try (DisplayList{ .commands = &commands }).framePlan(.{ .commands = &commands }, .{}, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    try std.testing.expect(!frame.full_repaint);
    try std.testing.expect(!frame.requiresRender());
    try std.testing.expectEqual(@as(usize, 1), frame.render_plan.commandCount());
    try std.testing.expectEqual(@as(usize, 1), frame.batch_plan.batchCount());
    try std.testing.expectEqual(@as(usize, 0), frame.changes.len);
    try std.testing.expect(frame.dirty_bounds == null);

    const render_pass = frame.renderPass();
    try std.testing.expect(!render_pass.requiresRender());
    try std.testing.expectEqual(CanvasRenderPassLoadAction.skip, render_pass.loadAction());
    try std.testing.expect(render_pass.scissorBounds() == null);
    try std.testing.expectEqual(@as(usize, 1), render_pass.commandCount());
    try std.testing.expectEqual(@as(usize, 1), render_pass.batchCount());

    const profile = frame.profile();
    try std.testing.expect(!profile.requires_render);
    try std.testing.expectEqual(CanvasFrameProfileRisk.idle, profile.risk);
    try std.testing.expectEqual(@as(usize, 0), profile.encoder_command_count);
    try std.testing.expectEqual(@as(usize, 0), profile.work_units);
}

test "canvas frame plan applies render overrides without display list changes" {
    const commands = [_]CanvasCommand{.{ .fill_rect = .{
        .id = 1,
        .rect = geometry.RectF.init(0, 0, 10, 10),
        .fill = .{ .color = Color.rgb8(255, 0, 0) },
    } }};
    const overrides = [_]CanvasRenderOverride{.{
        .id = 1,
        .opacity = 0.5,
        .transform = Affine.translate(10, 0),
    }};

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [0]RenderResource = .{};
    var resource_cache_entries: [0]RenderResourceCacheEntry = .{};
    var resource_cache_actions: [0]RenderResourceCacheAction = .{};
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [1]DiffChange = undefined;
    const frame = try (DisplayList{ .commands = &commands }).framePlan(.{ .commands = &commands }, .{
        .surface_size = geometry.SizeF.init(40, 20),
        .render_overrides = &overrides,
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    try std.testing.expect(!frame.full_repaint);
    try std.testing.expect(frame.requiresRender());
    try std.testing.expectEqual(@as(usize, 0), frame.changes.len);
    try expectRect(geometry.RectF.init(0, 0, 20, 10), frame.dirty_bounds);
    try std.testing.expectEqual(@as(usize, 1), frame.render_plan.commandCount());
    try std.testing.expectEqual(@as(f32, 0.5), frame.render_plan.commands[0].opacity);
    try std.testing.expectEqualDeep(Affine.translate(10, 0), frame.render_plan.commands[0].transform);
    try std.testing.expectEqualDeep(geometry.RectF.init(10, 0, 10, 10), frame.render_plan.commands[0].bounds);

    const render_pass = frame.renderPass();
    try std.testing.expectEqual(CanvasRenderPassLoadAction.load, render_pass.loadAction());
    try expectRect(geometry.RectF.init(0, 0, 20, 10), render_pass.scissorBounds());

    var pixels: [40 * 20 * 4]u8 = undefined;
    const surface = try ReferenceRenderSurface.init(40, 20, &pixels);
    surface.clear(Color.rgb8(0, 0, 0));
    try surface.renderPass(render_pass, Color.rgb8(0, 0, 0));
    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 5, 5);
    try expectPixelRgba8(.{ 128, 0, 0, 255 }, surface, 15, 5);

    var clean_render_commands: [1]RenderCommand = undefined;
    var clean_render_batches: [1]RenderBatch = undefined;
    var clean_changes: [1]DiffChange = undefined;
    const clean_frame = try (DisplayList{ .commands = &commands }).framePlan(.{ .commands = &commands }, .{
        .surface_size = geometry.SizeF.init(40, 20),
        .previous_render_overrides = &overrides,
        .render_overrides = &overrides,
    }, .{
        .render_commands = &clean_render_commands,
        .render_batches = &clean_render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &clean_changes,
    });

    try std.testing.expect(!clean_frame.requiresRender());
    try std.testing.expect(clean_frame.dirty_bounds == null);
    try std.testing.expectEqualDeep(geometry.RectF.init(10, 0, 10, 10), clean_frame.render_plan.commands[0].bounds);
}

test "canvas render animations sample overrides for frame planning" {
    const animations = [_]CanvasRenderAnimation{.{
        .id = 1,
        .start_ns = 1_000,
        .duration_ms = 1000,
        .easing = .linear,
        .from_opacity = 0,
        .to_opacity = 1,
        .from_transform = Affine.translate(0, 0),
        .to_transform = Affine.translate(20, 0),
    }};

    var overrides: [1]CanvasRenderOverride = undefined;
    const sampled = try sampleCanvasRenderAnimations(&animations, 500_001_000, &overrides);
    try std.testing.expectEqual(@as(usize, 1), sampled.len);
    try std.testing.expectEqual(@as(ObjectId, 1), sampled[0].id);
    try std.testing.expectEqual(@as(f32, 0.5), sampled[0].opacity.?);
    try std.testing.expectEqualDeep(Affine.translate(10, 0), sampled[0].transform.?);

    const commands = [_]CanvasCommand{.{ .fill_rect = .{
        .id = 1,
        .rect = geometry.RectF.init(0, 0, 10, 10),
        .fill = .{ .color = Color.rgb8(255, 0, 0) },
    } }};
    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [0]RenderResource = .{};
    var resource_cache_entries: [0]RenderResourceCacheEntry = .{};
    var resource_cache_actions: [0]RenderResourceCacheAction = .{};
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [1]DiffChange = undefined;
    const frame = try (DisplayList{ .commands = &commands }).framePlan(.{ .commands = &commands }, .{
        .surface_size = geometry.SizeF.init(40, 20),
        .render_overrides = sampled,
    }, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    });

    try std.testing.expectEqual(@as(usize, 0), frame.changes.len);
    try expectRect(geometry.RectF.init(0, 0, 20, 10), frame.dirty_bounds);
    try std.testing.expectEqual(@as(f32, 0.5), frame.render_plan.commands[0].opacity);
    try std.testing.expectEqualDeep(Affine.translate(10, 0), frame.render_plan.commands[0].transform);

    var empty_overrides: [0]CanvasRenderOverride = .{};
    try std.testing.expectError(error.RenderOverrideListFull, sampleCanvasRenderAnimations(&animations, 500_001_000, &empty_overrides));
}

test "motion tokens build render animations" {
    const tokens = MotionTokens{
        .fast_ms = 90,
        .normal_ms = 160,
        .slow_ms = 320,
        .easing = .linear,
        .spring = .{ .mass = 2, .stiffness = 180, .damping = 22 },
    };

    try std.testing.expectEqual(@as(u32, 90), tokens.durationMs(.fast));
    try std.testing.expectEqual(@as(u32, 160), tokens.durationMs(.normal));
    try std.testing.expectEqual(@as(u32, 320), tokens.durationMs(.slow));

    const animation = tokens.animation(.{
        .id = 7,
        .start_ns = 10_000,
        .duration = .slow,
        .from_opacity = 0,
        .to_opacity = 1,
        .from_transform = Affine.translate(0, 0),
        .to_transform = Affine.translate(16, 0),
    });

    try std.testing.expectEqual(@as(ObjectId, 7), animation.id);
    try std.testing.expectEqual(@as(u64, 10_000), animation.start_ns);
    try std.testing.expectEqual(@as(u32, 320), animation.duration_ms);
    try std.testing.expectEqual(Easing.linear, animation.easing);
    try std.testing.expectEqual(@as(f32, 2), animation.spring.mass);
    try std.testing.expectEqual(@as(f32, 180), animation.spring.stiffness);
    try std.testing.expectEqual(@as(f32, 22), animation.spring.damping);

    var overrides: [1]CanvasRenderOverride = undefined;
    const sampled = try sampleCanvasRenderAnimations(&.{animation}, animation.start_ns + 160_000_000, &overrides);
    try std.testing.expectEqual(@as(usize, 1), sampled.len);
    try std.testing.expectEqual(@as(ObjectId, 7), sampled[0].id);
    try std.testing.expectEqual(@as(f32, 0.5), sampled[0].opacity.?);
    try std.testing.expectEqualDeep(Affine.translate(8, 0), sampled[0].transform.?);

    const override_animation = tokens.animation(.{
        .id = 8,
        .easing = .emphasized,
        .spring = .{ .mass = 3, .stiffness = 140, .damping = 18 },
    });
    try std.testing.expectEqual(Easing.emphasized, override_animation.easing);
    try std.testing.expectEqual(@as(f32, 3), override_animation.spring.mass);
    try std.testing.expectEqual(@as(f32, 140), override_animation.spring.stiffness);
    try std.testing.expectEqual(@as(f32, 18), override_animation.spring.damping);

    const reduced = MotionTokens.reduced();
    try std.testing.expectEqual(@as(u32, 0), reduced.durationMs(.fast));
    try std.testing.expectEqual(@as(u32, 0), reduced.durationMs(.normal));
    try std.testing.expectEqual(@as(u32, 0), reduced.durationMs(.slow));
    const reduced_animation = reduced.animation(.{
        .id = 9,
        .duration = .slow,
        .from_opacity = 0,
        .to_opacity = 1,
    });
    try std.testing.expectEqual(@as(u32, 0), reduced_animation.duration_ms);
    try std.testing.expectEqual(Easing.linear, reduced_animation.easing);
    try std.testing.expectEqual(@as(f32, 1), motionProgress(reduced_animation, reduced_animation.start_ns));
}

test "canvas frame plan reports diff storage overflow" {
    const next_commands = [_]CanvasCommand{
        .{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 40, 40), .fill = .{ .color = Color.rgb8(255, 255, 255) } } },
    };

    var render_commands: [1]RenderCommand = undefined;
    var render_batches: [1]RenderBatch = undefined;
    var resources: [0]RenderResource = .{};
    var resource_cache_entries: [0]RenderResourceCacheEntry = .{};
    var resource_cache_actions: [0]RenderResourceCacheAction = .{};
    var glyphs: [0]GlyphAtlasEntry = .{};
    var changes: [0]DiffChange = .{};
    try std.testing.expectError(error.DiffListFull, (DisplayList{ .commands = &next_commands }).framePlan(.{}, .{}, .{
        .render_commands = &render_commands,
        .render_batches = &render_batches,
        .resources = &resources,
        .resource_cache_entries = &resource_cache_entries,
        .resource_cache_actions = &resource_cache_actions,
        .glyph_atlas_entries = &glyphs,
        .changes = &changes,
    }));
}
