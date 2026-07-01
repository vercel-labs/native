const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const drawing_model = @import("drawing.zig");
const text_model = @import("text.zig");
const render_model = @import("render.zig");
const event_model = @import("events.zig");
const equality_model = @import("equality.zig");
const widget_runtime = @import("widget_runtime.zig");

const Error = canvas.Error;
const ObjectId = canvas.ObjectId;
const ImageId = canvas.ImageId;
const FontId = canvas.FontId;
const default_sans_font_id = canvas.default_sans_font_id;
const default_mono_font_id = canvas.default_mono_font_id;
const default_sans_font_family = canvas.default_sans_font_family;
const default_mono_font_family = canvas.default_mono_font_family;
const default_glyph_atlas_cache_retention_frames = canvas.default_glyph_atlas_cache_retention_frames;
const default_text_layout_cache_retention_frames = canvas.default_text_layout_cache_retention_frames;
const Color = canvas.Color;
const Affine = canvas.Affine;
const Radius = canvas.Radius;
const GradientStop = canvas.GradientStop;
const LinearGradient = canvas.LinearGradient;
const Fill = canvas.Fill;
const Stroke = canvas.Stroke;
const Clip = canvas.Clip;
const FillRect = canvas.FillRect;
const StrokeRect = canvas.StrokeRect;
const FillRoundedRect = canvas.FillRoundedRect;
const Line = canvas.Line;
const PathVerb = canvas.PathVerb;
const PathElement = canvas.PathElement;
const FillPath = canvas.FillPath;
const StrokePath = canvas.StrokePath;
const ImageFit = canvas.ImageFit;
const ImageSampling = canvas.ImageSampling;
const DrawImage = canvas.DrawImage;
const Shadow = canvas.Shadow;
const Blur = canvas.Blur;
const Glyph = canvas.Glyph;
const GlyphAtlasKey = canvas.GlyphAtlasKey;
const GlyphAtlasEntry = canvas.GlyphAtlasEntry;
const GlyphAtlasPlan = canvas.GlyphAtlasPlan;
const GlyphAtlasPlanner = canvas.GlyphAtlasPlanner;
const GlyphAtlasCacheEntry = canvas.GlyphAtlasCacheEntry;
const GlyphAtlasCacheActionKind = canvas.GlyphAtlasCacheActionKind;
const GlyphAtlasCacheAction = canvas.GlyphAtlasCacheAction;
const GlyphAtlasCachePlan = canvas.GlyphAtlasCachePlan;
const GlyphAtlasCachePlanner = canvas.GlyphAtlasCachePlanner;
const DrawText = canvas.DrawText;
const TextWrap = canvas.TextWrap;
const TextAlign = canvas.TextAlign;
const TextLayoutOptions = canvas.TextLayoutOptions;
const TextLine = canvas.TextLine;
const TextLayout = canvas.TextLayout;
const TextLayoutKey = canvas.TextLayoutKey;
const TextLayoutPlan = canvas.TextLayoutPlan;
const TextLayoutPlanSet = canvas.TextLayoutPlanSet;
const TextLayoutPlanner = canvas.TextLayoutPlanner;
const TextLayoutCacheEntry = canvas.TextLayoutCacheEntry;
const TextLayoutCacheActionKind = canvas.TextLayoutCacheActionKind;
const TextLayoutCacheAction = canvas.TextLayoutCacheAction;
const TextLayoutCachePlan = canvas.TextLayoutCachePlan;
const TextLayoutCachePlanner = canvas.TextLayoutCachePlanner;
const TextRange = canvas.TextRange;
const TextSelectionRect = canvas.TextSelectionRect;
const TextSelection = canvas.TextSelection;
const TextCaretDirection = canvas.TextCaretDirection;
const TextCaretMove = canvas.TextCaretMove;
const TextCompositionUpdate = canvas.TextCompositionUpdate;
const TextInputEvent = canvas.TextInputEvent;
const TextEditState = canvas.TextEditState;
const CanvasCommand = canvas.CanvasCommand;
const CommandRef = canvas.CommandRef;
const DiffKind = canvas.DiffKind;
const DiffChange = canvas.DiffChange;
const Builder = canvas.Builder;
const max_render_state_stack = canvas.max_render_state_stack;
const RenderState = canvas.RenderState;
const RenderCommand = canvas.RenderCommand;
const CanvasRenderOverride = canvas.CanvasRenderOverride;
const CanvasRenderAnimation = canvas.CanvasRenderAnimation;
const applyRenderOverrides = canvas.applyRenderOverrides;
const renderOverrideDirtyBounds = canvas.renderOverrideDirtyBounds;
const RenderPlan = canvas.RenderPlan;
const RenderPlanner = canvas.RenderPlanner;
const RenderPipelineKind = canvas.RenderPipelineKind;
const RenderBatch = canvas.RenderBatch;
const RenderBatchPlanner = canvas.RenderBatchPlanner;
const RenderBatchPlan = canvas.RenderBatchPlan;
const RenderPipelineCacheEntry = canvas.RenderPipelineCacheEntry;
const RenderPipelineCacheActionKind = canvas.RenderPipelineCacheActionKind;
const RenderPipelineCacheAction = canvas.RenderPipelineCacheAction;
const RenderPipelineCachePlanner = canvas.RenderPipelineCachePlanner;
const RenderPipelineCachePlan = canvas.RenderPipelineCachePlan;
const RenderPathGeometryKind = canvas.RenderPathGeometryKind;
const RenderPathGeometry = canvas.RenderPathGeometry;
const RenderPathGeometryPlan = canvas.RenderPathGeometryPlan;
const RenderPathGeometryPlanner = canvas.RenderPathGeometryPlanner;
const RenderPathGeometryKey = canvas.RenderPathGeometryKey;
const RenderPathGeometryCacheEntry = canvas.RenderPathGeometryCacheEntry;
const RenderPathGeometryCacheActionKind = canvas.RenderPathGeometryCacheActionKind;
const RenderPathGeometryCacheAction = canvas.RenderPathGeometryCacheAction;
const RenderPathGeometryCachePlan = canvas.RenderPathGeometryCachePlan;
const RenderPathGeometryCachePlanner = canvas.RenderPathGeometryCachePlanner;
const RenderImage = canvas.RenderImage;
const RenderImagePlan = canvas.RenderImagePlan;
const RenderImagePlanner = canvas.RenderImagePlanner;
const RenderImageKey = canvas.RenderImageKey;
const RenderImageCacheEntry = canvas.RenderImageCacheEntry;
const RenderImageCacheActionKind = canvas.RenderImageCacheActionKind;
const RenderImageCacheAction = canvas.RenderImageCacheAction;
const RenderImageCachePlan = canvas.RenderImageCachePlan;
const RenderImageCachePlanner = canvas.RenderImageCachePlanner;
const RenderResourceKind = canvas.RenderResourceKind;
const RenderResource = canvas.RenderResource;
const RenderResourcePlan = canvas.RenderResourcePlan;
const RenderResourcePlanner = canvas.RenderResourcePlanner;
const RenderResourceKey = canvas.RenderResourceKey;
const RenderResourceCacheEntry = canvas.RenderResourceCacheEntry;
const RenderResourceCacheActionKind = canvas.RenderResourceCacheActionKind;
const RenderResourceCacheAction = canvas.RenderResourceCacheAction;
const RenderResourceCachePlan = canvas.RenderResourceCachePlan;
const RenderResourceCachePlanner = canvas.RenderResourceCachePlanner;
const RenderLayer = canvas.RenderLayer;
const RenderLayerPlan = canvas.RenderLayerPlan;
const RenderLayerPlanner = canvas.RenderLayerPlanner;
const RenderLayerKey = canvas.RenderLayerKey;
const RenderLayerCacheEntry = canvas.RenderLayerCacheEntry;
const RenderLayerCacheActionKind = canvas.RenderLayerCacheActionKind;
const RenderLayerCacheAction = canvas.RenderLayerCacheAction;
const RenderLayerCachePlan = canvas.RenderLayerCachePlan;
const RenderLayerCachePlanner = canvas.RenderLayerCachePlanner;
const VisualEffectKind = canvas.VisualEffectKind;
const VisualEffect = canvas.VisualEffect;
const VisualEffectPlan = canvas.VisualEffectPlan;
const VisualEffectPlanner = canvas.VisualEffectPlanner;
const VisualEffectKey = canvas.VisualEffectKey;
const VisualEffectCacheEntry = canvas.VisualEffectCacheEntry;
const VisualEffectCacheActionKind = canvas.VisualEffectCacheActionKind;
const VisualEffectCacheAction = canvas.VisualEffectCacheAction;
const VisualEffectCachePlan = canvas.VisualEffectCachePlan;
const VisualEffectCachePlanner = canvas.VisualEffectCachePlanner;
const CanvasFrameOptions = canvas.CanvasFrameOptions;
const CanvasFrameStorage = canvas.CanvasFrameStorage;
const CanvasFrameBudget = canvas.CanvasFrameBudget;
const CanvasFrameBudgetStatus = canvas.CanvasFrameBudgetStatus;
const CanvasFrameDiagnostics = canvas.CanvasFrameDiagnostics;
const CanvasFrameProfileRisk = canvas.CanvasFrameProfileRisk;
const CanvasFrameProfile = canvas.CanvasFrameProfile;
const CanvasRenderPass = canvas.CanvasRenderPass;
const CanvasFrame = canvas.CanvasFrame;
const buildCanvasFrame = canvas.buildCanvasFrame;
const CanvasRenderPassLoadAction = canvas.CanvasRenderPassLoadAction;
const RenderEncoderBeginPass = canvas.RenderEncoderBeginPass;
const RenderEncoderCommand = canvas.RenderEncoderCommand;
const RenderEncoderPlan = canvas.RenderEncoderPlan;
const RenderEncoderPlanner = canvas.RenderEncoderPlanner;
const CanvasGpuCommandKind = canvas.CanvasGpuCommandKind;
const CanvasGpuRoundedRect = canvas.CanvasGpuRoundedRect;
const CanvasGpuStrokeRect = canvas.CanvasGpuStrokeRect;
const CanvasGpuLine = canvas.CanvasGpuLine;
const CanvasGpuShape = canvas.CanvasGpuShape;
const CanvasGpuPaint = canvas.CanvasGpuPaint;
const CanvasGpuImage = canvas.CanvasGpuImage;
const CanvasGpuText = canvas.CanvasGpuText;
const CanvasGpuShadow = canvas.CanvasGpuShadow;
const CanvasGpuBlur = canvas.CanvasGpuBlur;
const CanvasGpuEffect = canvas.CanvasGpuEffect;
const CanvasGpuCommand = canvas.CanvasGpuCommand;
const CanvasGpuPacket = canvas.CanvasGpuPacket;
const CanvasGpuPacketSummary = canvas.CanvasGpuPacketSummary;
const CanvasGpuPacketPlanner = canvas.CanvasGpuPacketPlanner;
const ReferenceImage = canvas.ReferenceImage;
const ReferenceRenderSurface = canvas.ReferenceRenderSurface;
const Density = canvas.Density;
const Easing = canvas.Easing;
const ColorScheme = canvas.ColorScheme;
const ColorContrast = canvas.ColorContrast;
const ThemeOptions = canvas.ThemeOptions;
const ColorTokens = canvas.ColorTokens;
const FontFamily = canvas.FontFamily;
const TypographyTokens = canvas.TypographyTokens;
const SpacingTokens = canvas.SpacingTokens;
const RadiusTokens = canvas.RadiusTokens;
const StrokeTokens = canvas.StrokeTokens;
const ShadowToken = canvas.ShadowToken;
const ShadowTokens = canvas.ShadowTokens;
const BlurTokens = canvas.BlurTokens;
const MotionDuration = canvas.MotionDuration;
const MotionAnimationOptions = canvas.MotionAnimationOptions;
const MotionTokens = canvas.MotionTokens;
const SpringToken = canvas.SpringToken;
const BlurTokenRef = canvas.BlurTokenRef;
const ScrollPhysics = canvas.ScrollPhysics;
const ScrollState = canvas.ScrollState;
const VirtualListOptions = canvas.VirtualListOptions;
const VirtualListRange = canvas.VirtualListRange;
const virtualListRange = canvas.virtualListRange;
const LayerTokens = canvas.LayerTokens;
const PixelSnapTokens = canvas.PixelSnapTokens;
const ControlVisualTokens = canvas.ControlVisualTokens;
const ControlTokens = canvas.ControlTokens;
const ColorTokenOverrides = canvas.ColorTokenOverrides;
const TypographyTokenOverrides = canvas.TypographyTokenOverrides;
const SpacingTokenOverrides = canvas.SpacingTokenOverrides;
const RadiusTokenOverrides = canvas.RadiusTokenOverrides;
const StrokeTokenOverrides = canvas.StrokeTokenOverrides;
const ShadowTokenOverrides = canvas.ShadowTokenOverrides;
const ShadowTokensOverrides = canvas.ShadowTokensOverrides;
const BlurTokenOverrides = canvas.BlurTokenOverrides;
const SpringTokenOverrides = canvas.SpringTokenOverrides;
const MotionTokenOverrides = canvas.MotionTokenOverrides;
const ScrollPhysicsOverrides = canvas.ScrollPhysicsOverrides;
const LayerTokenOverrides = canvas.LayerTokenOverrides;
const PixelSnapTokenOverrides = canvas.PixelSnapTokenOverrides;
const ControlVisualTokenOverrides = canvas.ControlVisualTokenOverrides;
const ControlTokenOverrides = canvas.ControlTokenOverrides;
const DesignTokenOverrides = canvas.DesignTokenOverrides;
const DesignTokens = canvas.DesignTokens;
const WidgetKind = canvas.WidgetKind;
const WidgetCursor = canvas.WidgetCursor;
const WidgetState = canvas.WidgetState;
const WidgetRenderState = canvas.WidgetRenderState;
const WidgetMainAlignment = canvas.WidgetMainAlignment;
const WidgetCrossAlignment = canvas.WidgetCrossAlignment;
const WidgetLayoutStyle = canvas.WidgetLayoutStyle;
const WidgetStyle = canvas.WidgetStyle;
const WidgetVariant = canvas.WidgetVariant;
const WidgetSize = canvas.WidgetSize;
const WidgetRole = canvas.WidgetRole;
const BuiltinComponentStyle = canvas.BuiltinComponentStyle;
const BuiltinComponentKind = canvas.BuiltinComponentKind;
const builtin_component_kinds = canvas.builtin_component_kinds;
const builtin_component_names = canvas.builtin_component_names;
const BuiltinComponentDescriptor = canvas.BuiltinComponentDescriptor;
const builtinComponentCount = canvas.builtinComponentCount;
const builtinComponentName = canvas.builtinComponentName;
const builtinComponentDescriptor = canvas.builtinComponentDescriptor;
const WidgetActions = canvas.WidgetActions;
const WidgetSemantics = canvas.WidgetSemantics;
const Widget = canvas.Widget;
const BuiltinComponentOptions = canvas.BuiltinComponentOptions;
const WidgetCommandPart = canvas.WidgetCommandPart;
const BuiltinSurfacePlacementOptions = canvas.BuiltinSurfacePlacementOptions;
const BuiltinSurfaceBackdropOptions = canvas.BuiltinSurfaceBackdropOptions;
const BuiltinStatusBarOptions = canvas.BuiltinStatusBarOptions;
const BuiltinSurfaceEnterAnimationOptions = canvas.BuiltinSurfaceEnterAnimationOptions;
const builtinComponentWidget = canvas.builtinComponentWidget;
const widgetCommandPartId = canvas.widgetCommandPartId;
const builtinSurfaceBackdropWidget = canvas.builtinSurfaceBackdropWidget;
const builtinStatusBarWidget = canvas.builtinStatusBarWidget;
const builtinSurfaceFrame = canvas.builtinSurfaceFrame;
const appendBuiltinSurfaceEnterAnimations = canvas.appendBuiltinSurfaceEnterAnimations;
const builtinSurfaceEnterOffset = canvas.builtinSurfaceEnterOffset;
const max_widget_depth = canvas.max_widget_depth;
const max_widget_text_range_rects = canvas.max_widget_text_range_rects;
const WidgetLayoutNode = canvas.WidgetLayoutNode;
const WidgetHit = canvas.WidgetHit;
const WidgetPointerPhase = canvas.WidgetPointerPhase;
const WidgetPointerEvent = canvas.WidgetPointerEvent;
const WidgetKeyboardPhase = canvas.WidgetKeyboardPhase;
const WidgetKeyboardModifiers = canvas.WidgetKeyboardModifiers;
const WidgetKeyboardEvent = canvas.WidgetKeyboardEvent;
const WidgetControlIntentKind = canvas.WidgetControlIntentKind;
const WidgetControlIntent = canvas.WidgetControlIntent;
const WidgetSemanticAction = canvas.WidgetSemanticAction;
const WidgetFileDropEvent = canvas.WidgetFileDropEvent;
const WidgetDragEvent = canvas.WidgetDragEvent;
const WidgetEventPhase = canvas.WidgetEventPhase;
const WidgetEventRouteEntry = canvas.WidgetEventRouteEntry;
const WidgetEventRoute = canvas.WidgetEventRoute;
const WidgetKeyboardRoute = canvas.WidgetKeyboardRoute;
const WidgetFocusDirection = canvas.WidgetFocusDirection;
const WidgetFocusTarget = canvas.WidgetFocusTarget;
const WidgetScrollMetrics = canvas.WidgetScrollMetrics;
const WidgetListMetrics = canvas.WidgetListMetrics;
const WidgetSemanticsNode = canvas.WidgetSemanticsNode;
const WidgetInvalidationKind = canvas.WidgetInvalidationKind;
const WidgetInvalidation = canvas.WidgetInvalidation;
const widgetKeyboardControlIntent = canvas.widgetKeyboardControlIntent;
const widgetSemanticControlIntent = canvas.widgetSemanticControlIntent;
const widgetSemanticControlIntentWithActions = canvas.widgetSemanticControlIntentWithActions;
const isWidgetActivationKey = canvas.isWidgetActivationKey;
const widgetSliderKeyboardValue = canvas.widgetSliderKeyboardValue;
const widgetScrollKeyboardIntent = canvas.widgetScrollKeyboardIntent;
const widgetScrollKeyboardDelta = canvas.widgetScrollKeyboardDelta;
const WidgetLayoutTree = canvas.WidgetLayoutTree;
const DisplayList = canvas.DisplayList;
const emitWidgetTree = canvas.emitWidgetTree;
const layoutWidgetTree = canvas.layoutWidgetTree;
const layoutWidgetTreeWithTokens = canvas.layoutWidgetTreeWithTokens;
const layoutTextRun = canvas.layoutTextRun;
const layoutTextRunPlan = canvas.layoutTextRunPlan;
const layoutTextCaretRect = canvas.layoutTextCaretRect;
const textCaretRectForLayout = canvas.textCaretRectForLayout;
const layoutTextSelectionRects = canvas.layoutTextSelectionRects;
const textSelectionRectsForLayout = canvas.textSelectionRectsForLayout;
const layoutTextOffsetForPoint = canvas.layoutTextOffsetForPoint;
const textOffsetForLayoutPoint = canvas.textOffsetForLayoutPoint;
const applyTextInputEvent = canvas.applyTextInputEvent;
const sampleCanvasRenderAnimations = canvas.sampleCanvasRenderAnimations;
const emitWidgetLayout = canvas.emitWidgetLayout;
const toggleWidgetKnobCommandId = canvas.toggleWidgetKnobCommandId;
const toggleWidgetKnobTravel = canvas.toggleWidgetKnobTravel;
const textSelectionForWidgetPoint = canvas.textSelectionForWidgetPoint;
const textOffsetForWidgetPoint = canvas.textOffsetForWidgetPoint;
const textInputViewportForWidget = canvas.textInputViewportForWidget;
const textInputContentExtentForWidget = canvas.textInputContentExtentForWidget;
const textInputMaxScrollOffsetForWidget = canvas.textInputMaxScrollOffsetForWidget;
const clampedTextInputScrollOffsetForWidget = canvas.clampedTextInputScrollOffsetForWidget;
const intrinsicWidgetSize = canvas.intrinsicWidgetSize;
const cursorForWidgetHit = canvas.cursorForWidgetHit;
const cursorForWidgetTarget = canvas.cursorForWidgetTarget;
const WidgetTextGeometry = canvas.WidgetTextGeometry;
const textGeometryForWidget = canvas.textGeometryForWidget;
const virtualWidgetScrollContentExtent = canvas.virtualWidgetScrollContentExtent;
const virtualWidgetScrollContentExtentWithTokens = canvas.virtualWidgetScrollContentExtentWithTokens;
const writeCanvasGpuPacketJson = canvas.writeCanvasGpuPacketJson;

const strokeBounds = drawing_model.strokeBounds;
const shadowBounds = drawing_model.shadowBounds;
const semanticActions = event_model.semanticActions;
const defaultSemanticActions = event_model.defaultSemanticActions;
const defaultFocusable = event_model.defaultFocusable;
const textLineBounds = text_model.textLineBounds;
const textBounds = text_model.textBounds;
const estimateTextWidth = text_model.estimateTextWidth;
const estimateTextWidthForFont = text_model.estimateTextWidthForFont;
const estimateTextAdvanceForBytes = text_model.estimateTextAdvanceForBytes;
const estimatedGlyphAdvance = text_model.estimatedGlyphAdvance;
const snapTextSelection = text_model.snapTextSelection;
const snapTextRange = text_model.snapTextRange;
const nextTextOffset = text_model.nextTextOffset;
const nextTextLineEnd = text_model.nextTextLineEnd;
const isTextBreakByte = text_model.isTextBreakByte;
const textLineRange = text_model.textLineRange;
const textLineCaretX = text_model.textLineCaretX;
const motionProgress = render_model.motionProgress;
const renderImageFingerprint = render_model.renderImageFingerprint;
const renderImageFingerprintForResource = render_model.renderImageFingerprintForResource;
const commandsEqual = equality_model.commandsEqual;
const rectsEqual = equality_model.rectsEqual;
const optionalRectsEqual = equality_model.optionalRectsEqual;
const sizesEqual = equality_model.sizesEqual;
const insetsEqual = equality_model.insetsEqual;
const optionalColorsEqual = equality_model.optionalColorsEqual;
const radiiEqual = equality_model.radiiEqual;
const affinesEqual = equality_model.affinesEqual;
const optionalF32Equal = equality_model.optionalF32Equal;
const optionalTextSelectionsEqual = equality_model.optionalTextSelectionsEqual;
const optionalTextRangesEqual = equality_model.optionalTextRangesEqual;
const widgetPartId = widget_runtime.widgetPartId;
const colorWithAlpha = widget_runtime.colorWithAlpha;
const widgetControlHeight = widget_runtime.widgetControlHeight;
const textSelectionFillColor = widget_runtime.textSelectionFillColor;
const transparentColor = widget_runtime.transparentColor;

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
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 9), display_list.commandCount());
    switch (display_list.commands[7]) {
        .fill_rounded_rect => |fill| try expectRect(geometry.RectF.init(100, 12, 60, 8), fill.rect),
        else => return error.TestUnexpectedResult,
    }
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
    try expectLayoutFrame(layout, 4, geometry.RectF.init(button_size.width + search_size.width + 16, (64 - icon_size.height) * 0.5, icon_size.width, icon_size.height));

    var custom_nodes: [4]WidgetLayoutNode = undefined;
    const custom_tokens = DesignTokens{ .typography = .{ .button_size = 18 } };
    const custom_layout = try layoutWidgetTreeWithTokens(row, geometry.RectF.init(0, 0, 400, 64), custom_tokens, &custom_nodes);
    try std.testing.expect(custom_layout.findById(2).?.frame.width > layout.findById(2).?.frame.width);
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
    try std.testing.expectEqual(WidgetCursor.pointing_hand, layout.cursorForHit(layout.hitTest(geometry.PointF.init(16, 16))));
    try std.testing.expectEqual(WidgetCursor.text, layout.cursorForHit(layout.hitTest(geometry.PointF.init(16, 56))));
    try std.testing.expectEqual(WidgetCursor.resize_horizontal, layout.cursorForHit(layout.hitTest(geometry.PointF.init(16, 96))));
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

    var commands: [8]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, .{});
    try std.testing.expectEqual(@as(usize, 8), builder.displayList().commandCount());
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
    try std.testing.expectEqual(@as(usize, 8), display_list.commandCount());
    switch (display_list.commands[0]) {
        .stroke_rect => |stroke| try std.testing.expectEqual(@as(ObjectId, widgetPartId(3, 2)), stroke.id),
        else => return error.UnexpectedCommand,
    }
    switch (display_list.commands[1]) {
        .draw_text => |text| try std.testing.expectEqualStrings("Name", text.text),
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

test "design tokens provide theme and contrast palettes" {
    const light = DesignTokens.theme(.{});
    try std.testing.expectEqual(Density.regular, light.density);
    try std.testing.expectEqualDeep(ColorTokens.light(), light.colors);
    try std.testing.expectEqual(default_sans_font_id, light.typography.font_id);
    try std.testing.expectEqual(default_mono_font_id, light.typography.mono_font_id);
    try std.testing.expectEqual(default_sans_font_family, light.typography.font_family);
    try std.testing.expectEqual(default_mono_font_family, light.typography.mono_font_family);
    try std.testing.expectEqualStrings("Geist", light.typography.bodyFamilyName());
    try std.testing.expectEqualStrings("Geist Mono", light.typography.monoFamilyName());
    try std.testing.expectEqualDeep(Color.rgb8(9, 9, 11), light.colors.text);
    try std.testing.expectEqualDeep(Color.rgb8(24, 24, 27), light.colors.accent);
    try std.testing.expectEqualDeep(Color.rgb8(24, 24, 27), light.colors.focus_ring);

    const dark = DesignTokens.theme(.{ .color_scheme = .dark, .density = .compact });
    try std.testing.expectEqual(Density.compact, dark.density);
    try std.testing.expectEqualDeep(ColorTokens.dark(), dark.colors);
    try std.testing.expectEqualDeep(Color.rgb8(9, 9, 11), dark.colors.background);
    try std.testing.expectEqualDeep(Color.rgb8(250, 250, 250), dark.colors.text);
    try std.testing.expectEqualDeep(Color.rgb8(39, 39, 42), dark.colors.border);
    try std.testing.expectEqualDeep(Color.rgb8(250, 250, 250), dark.colors.accent);
    try std.testing.expectEqualDeep(Color.rgb8(9, 9, 11), dark.colors.accent_text);
    try std.testing.expectEqualDeep(Color.rgb8(212, 212, 216), dark.colors.focus_ring);

    const high_contrast = DesignTokens.theme(.{ .color_scheme = .dark, .contrast = .high, .density = .spacious });
    try std.testing.expectEqual(Density.spacious, high_contrast.density);
    try std.testing.expectEqualDeep(ColorTokens.highContrastDark(), high_contrast.colors);
    try std.testing.expectEqualDeep(Color.rgb8(0, 0, 0), high_contrast.colors.background);
    try std.testing.expectEqualDeep(Color.rgba8(255, 255, 255, 190), high_contrast.colors.border);

    const reduced_motion = DesignTokens.theme(.{ .reduce_motion = true });
    try std.testing.expectEqual(@as(u32, 0), reduced_motion.motion.durationMs(.fast));
    try std.testing.expectEqual(@as(u32, 0), reduced_motion.motion.durationMs(.normal));
    try std.testing.expectEqual(@as(u32, 0), reduced_motion.motion.durationMs(.slow));
    try std.testing.expectEqual(Easing.linear, reduced_motion.motion.easing);
}

test "built-in component catalog covers shadcn component set" {
    const expected_names = [_][]const u8{
        "Accordion",
        "Alert",
        "Avatar",
        "Badge",
        "Breadcrumb",
        "Bubble",
        "Button",
        "Button Group",
        "Card",
        "Checkbox",
        "Combobox",
        "Dialog",
        "Drawer",
        "Dropdown Menu",
        "Input",
        "Pagination",
        "Progress",
        "Radio Group",
        "Resizable",
        "Select",
        "Separator",
        "Sheet",
        "Skeleton",
        "Slider",
        "Spinner",
        "Switch",
        "Table",
        "Tabs",
        "Textarea",
        "Toggle",
        "Toggle Group",
        "Tooltip",
    };
    const enum_len = @typeInfo(BuiltinComponentKind).@"enum".fields.len;
    try std.testing.expectEqual(enum_len, builtinComponentCount());
    try std.testing.expectEqual(enum_len, builtin_component_names.len);
    try std.testing.expectEqual(expected_names.len, builtin_component_names.len);
    for (expected_names, builtin_component_names) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }

    var seen = [_]bool{false} ** enum_len;
    for (builtin_component_kinds, 0..) |kind, index| {
        const descriptor = builtinComponentDescriptor(kind);
        try std.testing.expectEqual(kind, descriptor.kind);
        try std.testing.expectEqualStrings(builtin_component_names[index], descriptor.name);
        try std.testing.expectEqualStrings(builtin_component_names[index], builtinComponentName(kind));
        try std.testing.expectEqual(BuiltinComponentStyle.shadcn, descriptor.style);
        const ordinal = @intFromEnum(kind);
        try std.testing.expectEqual(index, ordinal);
        try std.testing.expect(!seen[ordinal]);
        seen[ordinal] = true;
    }
    for (seen) |value| try std.testing.expect(value);
}

test "built-in component catalog maps to retained widget foundations" {
    try std.testing.expectEqual(WidgetKind.accordion, builtinComponentDescriptor(.accordion).root_widget_kind);
    try std.testing.expectEqual(WidgetKind.alert, builtinComponentDescriptor(.alert).root_widget_kind);
    try std.testing.expectEqual(WidgetKind.avatar, builtinComponentDescriptor(.avatar).root_widget_kind);
    try std.testing.expectEqual(WidgetKind.badge, builtinComponentDescriptor(.badge).root_widget_kind);
    try std.testing.expectEqual(WidgetKind.breadcrumb, builtinComponentDescriptor(.breadcrumb).root_widget_kind);
    try std.testing.expectEqual(WidgetKind.bubble, builtinComponentDescriptor(.bubble).root_widget_kind);
    try std.testing.expectEqual(WidgetKind.button, builtinComponentDescriptor(.button).root_widget_kind);
    try std.testing.expectEqual(WidgetKind.button_group, builtinComponentDescriptor(.button_group).root_widget_kind);
    try std.testing.expectEqual(WidgetKind.card, builtinComponentDescriptor(.card).root_widget_kind);
    try std.testing.expectEqual(WidgetKind.checkbox, builtinComponentDescriptor(.checkbox).root_widget_kind);
    try std.testing.expectEqual(WidgetKind.combobox, builtinComponentDescriptor(.combobox).root_widget_kind);
    try std.testing.expectEqual(WidgetKind.dialog, builtinComponentDescriptor(.dialog).root_widget_kind);
    try std.testing.expectEqual(WidgetKind.drawer, builtinComponentDescriptor(.drawer).root_widget_kind);
    try std.testing.expectEqual(WidgetKind.dropdown_menu, builtinComponentDescriptor(.dropdown_menu).root_widget_kind);
    try std.testing.expectEqual(WidgetKind.input, builtinComponentDescriptor(.input).root_widget_kind);
    try std.testing.expectEqual(WidgetKind.pagination, builtinComponentDescriptor(.pagination).root_widget_kind);
    try std.testing.expectEqual(WidgetKind.progress, builtinComponentDescriptor(.progress).root_widget_kind);
    try std.testing.expectEqual(WidgetKind.radio_group, builtinComponentDescriptor(.radio_group).root_widget_kind);
    try std.testing.expectEqual(WidgetKind.resizable, builtinComponentDescriptor(.resizable).root_widget_kind);
    try std.testing.expectEqual(WidgetKind.separator, builtinComponentDescriptor(.separator).root_widget_kind);
    try std.testing.expectEqual(WidgetKind.slider, builtinComponentDescriptor(.slider).root_widget_kind);
    try std.testing.expectEqual(WidgetKind.skeleton, builtinComponentDescriptor(.skeleton).root_widget_kind);
    try std.testing.expectEqual(WidgetKind.spinner, builtinComponentDescriptor(.spinner).root_widget_kind);
    try std.testing.expectEqual(WidgetKind.switch_control, builtinComponentDescriptor(.switch_control).root_widget_kind);
    try std.testing.expectEqual(WidgetKind.table, builtinComponentDescriptor(.table).root_widget_kind);
    try std.testing.expectEqual(WidgetKind.select, builtinComponentDescriptor(.select).root_widget_kind);
    try std.testing.expectEqual(WidgetKind.sheet, builtinComponentDescriptor(.sheet).root_widget_kind);
    try std.testing.expectEqual(WidgetKind.tabs, builtinComponentDescriptor(.tabs).root_widget_kind);
    try std.testing.expectEqual(WidgetKind.textarea, builtinComponentDescriptor(.textarea).root_widget_kind);
    try std.testing.expectEqual(WidgetKind.toggle_button, builtinComponentDescriptor(.toggle).root_widget_kind);
    try std.testing.expectEqual(WidgetKind.toggle_group, builtinComponentDescriptor(.toggle_group).root_widget_kind);
    try std.testing.expectEqual(WidgetKind.tooltip, builtinComponentDescriptor(.tooltip).root_widget_kind);

    try std.testing.expectEqual(WidgetRole.dialog, builtinComponentDescriptor(.sheet).role);
    try std.testing.expectEqual(WidgetRole.grid, builtinComponentDescriptor(.table).role);
    try std.testing.expectEqual(WidgetRole.switch_control, builtinComponentDescriptor(.switch_control).role);
    try std.testing.expectEqual(WidgetRole.none, builtinComponentDescriptor(.separator).role);
    try std.testing.expect(builtinComponentDescriptor(.accordion).composite);
    try std.testing.expect(builtinComponentDescriptor(.toggle_group).composite);
    try std.testing.expect(!builtinComponentDescriptor(.button).composite);
}

test "built-in component factory creates shadcn widget foundations" {
    for (builtin_component_kinds, 0..) |kind, index| {
        const descriptor = builtinComponentDescriptor(kind);
        const widget = builtinComponentWidget(kind, .{
            .id = @as(ObjectId, @intCast(index + 1)),
            .text = descriptor.name,
        });

        try std.testing.expectEqual(descriptor.root_widget_kind, widget.kind);
        if (descriptor.role != .none) {
            try std.testing.expectEqual(descriptor.role, widget.semantics.role);
        } else {
            try std.testing.expectEqual(WidgetRole.none, widget.semantics.role);
        }
        try std.testing.expectEqualStrings(descriptor.name, widget.text);
    }

    try std.testing.expectEqual(WidgetVariant.primary, builtinComponentWidget(.button, .{}).variant);
    try std.testing.expectEqual(WidgetVariant.outline, builtinComponentWidget(.select, .{}).variant);
    try std.testing.expectEqual(WidgetKind.toggle_button, builtinComponentWidget(.toggle, .{}).kind);
    try std.testing.expectEqual(WidgetVariant.ghost, builtinComponentWidget(.toggle, .{}).variant);
    try std.testing.expectEqual(WidgetSize.sm, builtinComponentWidget(.spinner, .{}).size);
    try std.testing.expectEqualStrings("Search components", builtinComponentWidget(.combobox, .{ .placeholder = "Search components" }).placeholder);
}

test "built-in component factory applies shadcn composite defaults" {
    const button_children = [_]Widget{
        builtinComponentWidget(.button, .{ .id = 2, .text = "One" }),
        builtinComponentWidget(.button, .{ .id = 3, .text = "Two", .variant = .secondary }),
    };
    const card = builtinComponentWidget(.card, .{
        .id = 1,
        .frame = geometry.RectF.init(0, 0, 240, 120),
        .children = &button_children,
    });
    try std.testing.expectEqual(WidgetKind.card, card.kind);
    try std.testing.expectEqual(@as(f32, 16), card.layout.padding.top);
    try std.testing.expectEqual(@as(f32, 16), card.layout.padding.right);
    try std.testing.expectEqual(@as(f32, 16), card.layout.padding.bottom);
    try std.testing.expectEqual(@as(f32, 16), card.layout.padding.left);
    try std.testing.expectEqual(@as(f32, 12), card.layout.gap);
    try std.testing.expect(card.layout.clip_content);
    try std.testing.expectEqual(@as(usize, 2), card.children.len);

    const button_group = builtinComponentWidget(.button_group, .{});
    try std.testing.expectEqual(WidgetKind.button_group, button_group.kind);
    try std.testing.expectEqual(@as(f32, 4), button_group.layout.gap);
    try std.testing.expectEqual(WidgetCrossAlignment.center, button_group.layout.cross_alignment);

    const row_components = [_]BuiltinComponentKind{ .breadcrumb, .pagination, .radio_group, .tabs, .toggle_group };
    const row_kinds = [_]WidgetKind{ .breadcrumb, .pagination, .radio_group, .tabs, .toggle_group };
    for (row_components, row_kinds) |kind, widget_kind| {
        const component = builtinComponentWidget(kind, .{});
        try std.testing.expectEqual(widget_kind, component.kind);
        try std.testing.expectEqual(@as(f32, 4), component.layout.gap);
        try std.testing.expectEqual(WidgetCrossAlignment.center, component.layout.cross_alignment);
        try std.testing.expectEqual(WidgetRole.group, component.semantics.role);
    }

    const panel_components = [_]BuiltinComponentKind{ .accordion, .bubble, .resizable };
    const panel_kinds = [_]WidgetKind{ .accordion, .bubble, .resizable };
    for (panel_components, panel_kinds) |kind, widget_kind| {
        const component = builtinComponentWidget(kind, .{});
        try std.testing.expectEqual(widget_kind, component.kind);
        try std.testing.expect(component.layout.clip_content);
        try std.testing.expectEqual(WidgetRole.group, component.semantics.role);
    }
    try std.testing.expectEqual(@as(f32, 12), builtinComponentWidget(.accordion, .{}).layout.padding.top);
    try std.testing.expectEqual(@as(f32, 16), builtinComponentWidget(.bubble, .{}).layout.padding.top);

    const custom_card = builtinComponentWidget(.card, .{
        .layout = .{ .gap = 24 },
    });
    try std.testing.expectEqual(@as(f32, 0), custom_card.layout.padding.top);
    try std.testing.expectEqual(@as(f32, 24), custom_card.layout.gap);
}

test "built-in accordion renders shadcn disclosure chrome and toggle semantics" {
    const accordion = builtinComponentWidget(.accordion, .{
        .id = 45,
        .frame = geometry.RectF.init(0, 0, 220, 64),
        .text = "Advanced options",
        .state = .{ .selected = true, .focused = true },
        .semantics = .{ .label = "Advanced options" },
    });

    var nodes: [1]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(accordion, accordion.frame, &nodes);
    try std.testing.expectEqual(WidgetCursor.pointing_hand, layout.cursorForHit(layout.hitTest(geometry.PointF.init(12, 12))));
    try std.testing.expectEqual(WidgetCursor.pointing_hand, cursorForWidgetTarget(.accordion, .{}));
    try std.testing.expectEqual(@as(ObjectId, 45), layout.focusTargetById(45).?.id);

    var semantics_buffer: [1]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 1), semantics.len);
    try std.testing.expectEqual(WidgetRole.group, semantics[0].role);
    try std.testing.expectEqualStrings("Advanced options", semantics[0].label);
    try std.testing.expectEqual(@as(?f32, 1), semantics[0].value);
    try std.testing.expectEqual(@as(?bool, true), semantics[0].state.expanded);
    try std.testing.expect(semantics[0].focusable);
    try std.testing.expect(semantics[0].actions.toggle);

    const tokens = DesignTokens{
        .shadow = .{ .sm = .{ .y = 0, .blur = 0, .spread = 0 } },
        .controls = .{
            .accordion = .{
                .background = Color.rgb8(14, 20, 26),
                .foreground = Color.rgb8(230, 236, 242),
                .border = Color.rgb8(64, 74, 84),
                .stroke_width = 1.25,
            },
        },
    };
    var commands: [8]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, accordion, tokens);
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 8), display_list.commandCount());
    switch (display_list.findCommandById(widgetPartId(45, 2)).?.command) {
        .fill_rounded_rect => |fill| try expectFillColor(Color.rgb8(14, 20, 26), fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.findCommandById(widgetPartId(45, 4)).?.command) {
        .draw_line => |line| {
            try std.testing.expect(line.to.y > line.from.y);
            try expectFillColor(Color.rgb8(230, 236, 242), line.stroke.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.findCommandById(widgetPartId(45, 5)).?.command) {
        .draw_line => |line| try std.testing.expect(line.to.y < line.from.y),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.findCommandById(widgetPartId(45, 6)).?.command) {
        .draw_text => |text| try std.testing.expectEqualStrings("Advanced options", text.text),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(display_list.findCommandById(widgetPartId(45, 7)) != null);
}

test "built-in resizable renders shadcn resize grip and drag semantics" {
    const resizable = builtinComponentWidget(.resizable, .{
        .id = 46,
        .frame = geometry.RectF.init(0, 0, 180, 80),
        .semantics = .{ .label = "Resizable panel" },
    });

    var nodes: [1]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(resizable, resizable.frame, &nodes);
    try std.testing.expectEqual(WidgetCursor.resize_horizontal, layout.cursorForHit(layout.hitTest(geometry.PointF.init(174, 40))));

    var semantics_buffer: [1]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 1), semantics.len);
    try std.testing.expectEqual(WidgetRole.group, semantics[0].role);
    try std.testing.expectEqualStrings("Resizable panel", semantics[0].label);
    try std.testing.expect(semantics[0].actions.drag);

    var route_buffer: [1]WidgetEventRouteEntry = undefined;
    const route = try layout.routeDragEvent(.{
        .source_id = 46,
        .point = geometry.PointF.init(174, 40),
        .delta = geometry.OffsetF.init(18, 0),
    }, &route_buffer);
    try std.testing.expect(route.target != null);
    try std.testing.expectEqual(@as(ObjectId, 46), route.target.?.id);
    try std.testing.expectEqual(@as(usize, 1), route.entries.len);

    const tokens = DesignTokens{
        .shadow = .{ .sm = .{ .y = 0, .blur = 0, .spread = 0 } },
        .controls = .{
            .resizable = .{
                .background = Color.rgb8(14, 20, 26),
                .foreground = Color.rgb8(230, 236, 242),
                .border = Color.rgb8(64, 74, 84),
                .stroke_width = 1.5,
            },
        },
    };
    var commands: [6]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, resizable, tokens);
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 6), display_list.commandCount());
    switch (display_list.findCommandById(widgetPartId(46, 2)).?.command) {
        .fill_rounded_rect => |fill| try expectFillColor(Color.rgb8(14, 20, 26), fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.findCommandById(widgetPartId(46, 4)).?.command) {
        .draw_line => |line| {
            try std.testing.expect(line.from.x > 160);
            try expectFillColor(Color.rgb8(230, 236, 242), line.stroke.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.findCommandById(widgetPartId(46, 5)).?.command) {
        .draw_line => |line| {
            try std.testing.expect(line.from.x > 170);
            try expectFillColor(Color.rgb8(230, 236, 242), line.stroke.fill);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "built-in accordion disclosure state controls child layout and semantics" {
    const content = [_]Widget{.{
        .id = 46,
        .kind = .text,
        .frame = geometry.RectF.init(0, 0, 160, 18),
        .text = "Advanced content",
    }};
    const collapsed = builtinComponentWidget(.accordion, .{
        .id = 45,
        .frame = geometry.RectF.init(0, 0, 220, 120),
        .text = "Advanced options",
        .children = &content,
    });

    var collapsed_nodes: [2]WidgetLayoutNode = undefined;
    const collapsed_layout = try layoutWidgetTree(collapsed, collapsed.frame, &collapsed_nodes);
    try std.testing.expectEqual(@as(usize, 1), collapsed_layout.nodeCount());
    try std.testing.expect(collapsed_layout.findById(46) == null);

    var collapsed_semantics_buffer: [2]WidgetSemanticsNode = undefined;
    const collapsed_semantics = try collapsed_layout.collectSemantics(&collapsed_semantics_buffer);
    try std.testing.expectEqual(@as(usize, 1), collapsed_semantics.len);
    try std.testing.expectEqual(@as(?bool, false), collapsed_semantics[0].state.expanded);

    var collapsed_commands: [12]CanvasCommand = undefined;
    var collapsed_builder = Builder.init(&collapsed_commands);
    try collapsed_layout.emitDisplayList(&collapsed_builder, .{});
    try std.testing.expect(collapsed_builder.displayList().findCommandById(widgetPartId(46, 1)) == null);

    var expanded = collapsed;
    expanded.state.selected = true;
    expanded.value = 1;
    var expanded_nodes: [2]WidgetLayoutNode = undefined;
    const expanded_layout = try layoutWidgetTree(expanded, expanded.frame, &expanded_nodes);
    try std.testing.expectEqual(@as(usize, 2), expanded_layout.nodeCount());
    const expanded_child = expanded_layout.findById(46).?;
    try std.testing.expect(expanded_child.frame.y > expanded.frame.y + expanded.layout.padding.top + widgetControlHeight(expanded, .{}));

    var expanded_semantics_buffer: [2]WidgetSemanticsNode = undefined;
    const expanded_semantics = try expanded_layout.collectSemantics(&expanded_semantics_buffer);
    try std.testing.expectEqual(@as(usize, 2), expanded_semantics.len);
    try std.testing.expectEqual(@as(?bool, true), expanded_semantics[0].state.expanded);
    try std.testing.expectEqualStrings("Advanced content", expanded_semantics[1].label);

    var expanded_commands: [12]CanvasCommand = undefined;
    var expanded_builder = Builder.init(&expanded_commands);
    try expanded_layout.emitDisplayList(&expanded_builder, .{});
    try std.testing.expect(expanded_builder.displayList().findCommandById(widgetPartId(46, 1)) != null);
}

test "built-in alert renders shadcn surface chrome and text" {
    const alert = builtinComponentWidget(.alert, .{
        .id = 40,
        .frame = geometry.RectF.init(0, 0, 320, 68),
        .text = "Heads up: this workflow is native-rendered.",
    });
    try std.testing.expectEqual(WidgetKind.alert, alert.kind);
    try std.testing.expectEqual(@as(f32, 16), alert.layout.padding.top);
    try std.testing.expectEqual(@as(f32, 12), alert.layout.gap);
    try std.testing.expect(alert.layout.clip_content);

    var nodes: [2]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(alert, alert.frame, &nodes);
    try std.testing.expectEqual(WidgetKind.alert, layout.hitTest(geometry.PointF.init(12, 12)).?.kind);

    var semantics_buffer: [2]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 1), semantics.len);
    try std.testing.expectEqual(WidgetRole.group, semantics[0].role);
    try std.testing.expectEqualStrings("Heads up: this workflow is native-rendered.", semantics[0].label);

    const tokens = DesignTokens{
        .controls = .{
            .alert = .{
                .background = Color.rgb8(12, 18, 24),
                .foreground = Color.rgb8(235, 240, 245),
                .border = Color.rgb8(54, 64, 74),
                .radius = 10,
                .stroke_width = 2,
            },
        },
    };
    var commands: [8]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, alert, tokens);
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 8), display_list.commandCount());
    switch (display_list.findCommandById(widgetPartId(40, 1)).?.command) {
        .fill_rounded_rect => |fill| {
            try std.testing.expectEqualDeep(Radius.all(10), fill.radius);
            try expectFillColor(Color.rgb8(12, 18, 24), fill.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.findCommandById(widgetPartId(40, 2)).?.command) {
        .stroke_rect => |stroke| {
            try std.testing.expectEqual(@as(f32, 2), stroke.stroke.width);
            try expectFillColor(Color.rgb8(54, 64, 74), stroke.stroke.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.findCommandById(widgetPartId(40, 3)).?.command) {
        .stroke_rect => |stroke| try expectFillColor(Color.rgb8(235, 240, 245), stroke.stroke.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.findCommandById(widgetPartId(40, 6)).?.command) {
        .draw_text => |text| {
            try std.testing.expectEqualStrings("Heads up: this workflow is native-rendered.", text.text);
            try std.testing.expectEqualDeep(Color.rgb8(235, 240, 245), text.color);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "built-in card renders shadcn surface chrome and title" {
    const card = builtinComponentWidget(.card, .{
        .id = 44,
        .frame = geometry.RectF.init(0, 0, 280, 120),
        .text = "Revenue pulse",
    });
    try std.testing.expectEqual(WidgetKind.card, card.kind);
    try std.testing.expectEqual(@as(f32, 16), card.layout.padding.top);
    try std.testing.expectEqual(@as(f32, 12), card.layout.gap);
    try std.testing.expect(card.layout.clip_content);

    var nodes: [2]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(card, card.frame, &nodes);
    try std.testing.expectEqual(WidgetKind.card, layout.hitTest(geometry.PointF.init(12, 12)).?.kind);

    var semantics_buffer: [2]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 1), semantics.len);
    try std.testing.expectEqual(WidgetRole.group, semantics[0].role);
    try std.testing.expectEqualStrings("Revenue pulse", semantics[0].label);

    const tokens = DesignTokens{
        .controls = .{
            .card = .{
                .background = Color.rgb8(10, 16, 22),
                .foreground = Color.rgb8(238, 242, 246),
                .border = Color.rgb8(52, 62, 72),
                .radius = 12,
                .stroke_width = 1.5,
            },
        },
    };
    var commands: [5]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, card, tokens);
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 5), display_list.commandCount());
    switch (display_list.findCommandById(widgetPartId(44, 1)).?.command) {
        .fill_rounded_rect => |fill| {
            try std.testing.expectEqualDeep(Radius.all(12), fill.radius);
            try expectFillColor(Color.rgb8(10, 16, 22), fill.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.findCommandById(widgetPartId(44, 2)).?.command) {
        .stroke_rect => |stroke| {
            try std.testing.expectEqual(@as(f32, 1.5), stroke.stroke.width);
            try expectFillColor(Color.rgb8(52, 62, 72), stroke.stroke.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.findCommandById(widgetPartId(44, 3)).?.command) {
        .draw_text => |text| {
            try std.testing.expectEqualStrings("Revenue pulse", text.text);
            try std.testing.expectEqualDeep(Color.rgb8(238, 242, 246), text.color);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "built-in status bar renders flat app chrome and text semantics" {
    const status_bar = builtinStatusBarWidget(.{
        .id = 47,
        .frame = geometry.RectF.init(0, 120, 360, 32),
        .text = "Canvas frame ready.",
        .background = Color.rgb8(11, 12, 14),
        .foreground = Color.rgb8(235, 236, 240),
        .border = Color.rgb8(42, 44, 48),
    });
    try std.testing.expectEqual(WidgetKind.status_bar, status_bar.kind);
    try std.testing.expectEqual(WidgetRole.text, status_bar.semantics.role);
    try std.testing.expectEqualStrings("Canvas frame ready.", status_bar.semantics.label);
    try std.testing.expectEqual(@as(f32, 7), status_bar.layout.padding.top);
    try std.testing.expectEqual(@as(f32, 14), status_bar.layout.padding.left);

    var nodes: [2]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(status_bar, geometry.RectF.init(0, 0, 360, 160), &nodes);
    try std.testing.expectEqual(WidgetKind.status_bar, layout.hitTest(geometry.PointF.init(12, 140)).?.kind);

    var semantics_buffer: [2]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 1), semantics.len);
    try std.testing.expectEqual(WidgetRole.text, semantics[0].role);
    try std.testing.expectEqualStrings("Canvas frame ready.", semantics[0].label);
    try std.testing.expect(!semantics[0].focusable);

    var commands: [4]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, status_bar, .{});
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 3), display_list.commandCount());
    switch (display_list.findCommandById(widgetPartId(47, 1)).?.command) {
        .fill_rect => |fill| {
            try std.testing.expectEqualDeep(geometry.RectF.init(0, 120, 360, 32), fill.rect);
            try expectFillColor(Color.rgb8(11, 12, 14), fill.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.findCommandById(widgetPartId(47, 2)).?.command) {
        .fill_rect => |fill| {
            try std.testing.expectEqualDeep(geometry.RectF.init(0, 120, 360, 1), fill.rect);
            try expectFillColor(Color.rgb8(42, 44, 48), fill.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.findCommandById(widgetPartId(47, 3)).?.command) {
        .draw_text => |text| {
            try std.testing.expectEqualStrings("Canvas frame ready.", text.text);
            try std.testing.expectEqualDeep(Color.rgb8(235, 236, 240), text.color);
            try std.testing.expect(text.origin.y > 120);
            try std.testing.expect(text.origin.y < 152);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "built-in modal surfaces render shadcn chrome and semantics" {
    const viewport = geometry.RectF.init(0, 52, 1024, 640);
    const backdrop = builtinSurfaceBackdropWidget(.{
        .id = 49,
        .frame = viewport,
        .layer = 20,
    });
    try std.testing.expectEqual(WidgetKind.panel, backdrop.kind);
    try std.testing.expectEqual(@as(?i32, 20), backdrop.layer);
    try std.testing.expectEqualDeep(Color.rgba8(0, 0, 0, 154), backdrop.style.background.?);
    try std.testing.expectEqualDeep(Color.rgba8(0, 0, 0, 0), backdrop.style.border.?);
    try std.testing.expectEqual(@as(?f32, 0), backdrop.style.radius);
    try std.testing.expectEqual(@as(?f32, 0), backdrop.style.stroke_width);
    try std.testing.expect(backdrop.semantics.actions.dismiss);

    const dialog_frame = builtinSurfaceFrame(.dialog, .{
        .bounds = viewport,
        .preferred_size = geometry.SizeF.init(460, 220),
    }).?;
    try std.testing.expectEqualDeep(geometry.RectF.init(282, 262, 460, 220), dialog_frame);
    try std.testing.expect(builtinSurfaceEnterOffset(.dialog, dialog_frame) == null);

    const drawer_frame = builtinSurfaceFrame(.drawer, .{
        .bounds = viewport,
        .preferred_size = geometry.SizeF.init(1024, 260),
    }).?;
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 432, 1024, 260), drawer_frame);
    try std.testing.expectEqualDeep(geometry.OffsetF.init(0, 260), builtinSurfaceEnterOffset(.drawer, drawer_frame).?);

    const sheet_frame = builtinSurfaceFrame(.sheet, .{
        .bounds = viewport,
        .preferred_size = geometry.SizeF.init(380, 640),
    }).?;
    try std.testing.expectEqualDeep(geometry.RectF.init(644, 52, 380, 640), sheet_frame);
    try std.testing.expectEqualDeep(geometry.OffsetF.init(380, 0), builtinSurfaceEnterOffset(.sheet, sheet_frame).?);

    try std.testing.expect(builtinSurfaceFrame(.card, .{ .bounds = viewport }) == null);
    try std.testing.expect(builtinSurfaceEnterOffset(.card, viewport) == null);

    const fade_parts = [_]WidgetCommandPart{
        .{ .widget_id = 70, .slot = 1 },
        .{ .widget_id = 71, .slot = 4 },
    };
    var dialog_animations: [5]CanvasRenderAnimation = undefined;
    var dialog_animation_count: usize = 0;
    try appendBuiltinSurfaceEnterAnimations(.dialog, .{
        .surface_id = 50,
        .frame = dialog_frame,
        .start_ns = 99,
        .content = &fade_parts,
    }, &dialog_animations, &dialog_animation_count);
    try std.testing.expectEqual(@as(usize, 5), dialog_animation_count);
    try std.testing.expectEqual(widgetCommandPartId(.{ .widget_id = 50, .slot = 1 }), dialog_animations[0].id);
    try std.testing.expectEqual(@as(u64, 99), dialog_animations[0].start_ns);
    try std.testing.expectEqual(@as(?f32, 0), dialog_animations[0].from_opacity);
    try std.testing.expectEqual(@as(?f32, 1), dialog_animations[0].to_opacity);
    try std.testing.expect(dialog_animations[0].from_transform == null);
    try std.testing.expectEqual(widgetCommandPartId(.{ .widget_id = 70, .slot = 1 }), dialog_animations[3].id);
    try std.testing.expectEqual(widgetCommandPartId(.{ .widget_id = 71, .slot = 4 }), dialog_animations[4].id);

    var drawer_animations: [3]CanvasRenderAnimation = undefined;
    var drawer_animation_count: usize = 0;
    try appendBuiltinSurfaceEnterAnimations(.drawer, .{
        .surface_id = 51,
        .frame = drawer_frame,
        .start_ns = 120,
    }, &drawer_animations, &drawer_animation_count);
    try std.testing.expectEqual(@as(usize, 3), drawer_animation_count);
    try std.testing.expectEqual(widgetCommandPartId(.{ .widget_id = 51, .slot = 2 }), drawer_animations[1].id);
    try std.testing.expectEqualDeep(Affine.translate(0, drawer_frame.height), drawer_animations[1].from_transform.?);
    try std.testing.expectEqualDeep(Affine.identity(), drawer_animations[1].to_transform.?);
    try std.testing.expect(drawer_animations[1].from_opacity == null);

    var reduced_animations: [1]CanvasRenderAnimation = undefined;
    var reduced_animation_count: usize = 0;
    try appendBuiltinSurfaceEnterAnimations(.sheet, .{
        .surface_id = 52,
        .frame = sheet_frame,
        .motion = MotionTokens.reduced(),
    }, &reduced_animations, &reduced_animation_count);
    try std.testing.expectEqual(@as(usize, 0), reduced_animation_count);
    try appendBuiltinSurfaceEnterAnimations(.card, .{
        .surface_id = 53,
        .frame = viewport,
    }, &reduced_animations, &reduced_animation_count);
    try std.testing.expectEqual(@as(usize, 0), reduced_animation_count);

    const dialog = builtinComponentWidget(.dialog, .{
        .id = 50,
        .frame = geometry.RectF.init(0, 0, 320, 160),
        .text = "Edit profile",
    });
    const drawer = builtinComponentWidget(.drawer, .{
        .id = 51,
        .frame = geometry.RectF.init(340, 0, 280, 180),
        .text = "Command drawer",
    });
    const sheet = builtinComponentWidget(.sheet, .{
        .id = 52,
        .frame = geometry.RectF.init(640, 0, 260, 220),
        .text = "Inspector",
    });

    try std.testing.expectEqual(WidgetKind.dialog, dialog.kind);
    try std.testing.expectEqual(WidgetKind.drawer, drawer.kind);
    try std.testing.expectEqual(WidgetKind.sheet, sheet.kind);
    try std.testing.expectEqual(@as(f32, 20), dialog.layout.padding.top);
    try std.testing.expectEqual(@as(f32, 16), sheet.layout.gap);
    try std.testing.expect(dialog.layout.clip_content);
    try std.testing.expect(drawer.layout.clip_content);
    try std.testing.expect(sheet.layout.clip_content);

    const root = Widget{ .kind = .stack, .children = &.{ backdrop, dialog, drawer, sheet } };
    var nodes: [5]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 920, 240), &nodes);
    try std.testing.expectEqual(WidgetKind.panel, layout.hitTest(geometry.PointF.init(300, 220)).?.kind);
    try std.testing.expectEqual(WidgetKind.dialog, layout.hitTest(geometry.PointF.init(12, 12)).?.kind);
    try std.testing.expectEqual(WidgetKind.drawer, layout.hitTest(geometry.PointF.init(352, 12)).?.kind);
    try std.testing.expectEqual(WidgetKind.sheet, layout.hitTest(geometry.PointF.init(652, 12)).?.kind);

    var semantics_buffer: [5]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 4), semantics.len);
    try std.testing.expectEqual(WidgetRole.group, semantics[0].role);
    try std.testing.expectEqualStrings("Surface backdrop", semantics[0].label);
    try std.testing.expect(semantics[0].actions.dismiss);
    try std.testing.expect(semantics[0].state.expanded == null);
    try std.testing.expectEqual(WidgetRole.dialog, semantics[1].role);
    try std.testing.expectEqualStrings("Edit profile", semantics[1].label);
    try std.testing.expect(semantics[1].actions.dismiss);
    try std.testing.expect(semantics[1].state.expanded == null);
    try std.testing.expectEqual(WidgetRole.dialog, semantics[2].role);
    try std.testing.expectEqualStrings("Command drawer", semantics[2].label);
    try std.testing.expect(semantics[2].actions.dismiss);
    try std.testing.expect(semantics[2].state.expanded == null);
    try std.testing.expectEqual(WidgetRole.dialog, semantics[3].role);
    try std.testing.expectEqualStrings("Inspector", semantics[3].label);
    try std.testing.expect(semantics[3].actions.dismiss);
    try std.testing.expect(semantics[3].state.expanded == null);

    const tokens = DesignTokens{
        .shadow = .{ .md = .{ .y = 0, .blur = 0, .spread = 0 } },
        .controls = .{
            .dialog = .{
                .background = Color.rgb8(11, 17, 23),
                .foreground = Color.rgb8(240, 244, 248),
                .border = Color.rgb8(55, 65, 75),
                .radius = 14,
                .stroke_width = 1.25,
            },
            .drawer = .{
                .background = Color.rgb8(12, 18, 24),
                .foreground = Color.rgb8(241, 245, 249),
                .border = Color.rgb8(56, 66, 76),
                .radius = 16,
                .stroke_width = 1.5,
            },
            .sheet = .{
                .background = Color.rgb8(13, 19, 25),
                .foreground = Color.rgb8(242, 246, 250),
                .border = Color.rgb8(57, 67, 77),
                .radius = 12,
                .stroke_width = 1.75,
            },
        },
    };
    var commands: [18]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, tokens);
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 18), display_list.commandCount());
    switch (display_list.findCommandById(widgetPartId(49, 2)).?.command) {
        .fill_rounded_rect => |fill| {
            try std.testing.expectEqualDeep(Radius.all(0), fill.radius);
            try expectFillColor(Color.rgba8(0, 0, 0, 154), fill.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.findCommandById(widgetPartId(49, 3)).?.command) {
        .stroke_rect => |stroke| {
            try std.testing.expectEqual(@as(f32, 0), stroke.stroke.width);
            try expectFillColor(Color.rgba8(0, 0, 0, 0), stroke.stroke.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.findCommandById(widgetPartId(50, 2)).?.command) {
        .fill_rounded_rect => |fill| {
            try std.testing.expectEqualDeep(Radius.all(14), fill.radius);
            try expectFillColor(Color.rgb8(11, 17, 23), fill.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.findCommandById(widgetPartId(51, 3)).?.command) {
        .stroke_rect => |stroke| {
            try std.testing.expectEqual(@as(f32, 1.5), stroke.stroke.width);
            try expectFillColor(Color.rgb8(56, 66, 76), stroke.stroke.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.findCommandById(widgetPartId(52, 4)).?.command) {
        .draw_text => |text| {
            try std.testing.expectEqualStrings("Inspector", text.text);
            try std.testing.expectEqualDeep(Color.rgb8(242, 246, 250), text.color);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "built-in component widgets expose shadcn semantics and render tokens" {
    const children = [_]Widget{
        builtinComponentWidget(.button, .{
            .id = 2,
            .frame = geometry.RectF.init(16, 16, 96, 34),
            .text = "Save",
            .command = "settings.save",
        }),
        builtinComponentWidget(.input, .{
            .id = 3,
            .frame = geometry.RectF.init(16, 58, 160, 34),
            .text = "zero-native",
            .semantics = .{ .label = "Project name" },
        }),
        builtinComponentWidget(.switch_control, .{
            .id = 4,
            .frame = geometry.RectF.init(16, 104, 120, 30),
            .text = "Live",
            .value = 1,
        }),
        builtinComponentWidget(.toggle, .{
            .id = 6,
            .frame = geometry.RectF.init(150, 104, 72, 30),
            .text = "Bold",
            .state = .{ .selected = true },
        }),
        builtinComponentWidget(.table, .{
            .id = 5,
            .frame = geometry.RectF.init(16, 144, 180, 72),
            .semantics = .{ .label = "Deployments" },
        }),
    };
    const root = builtinComponentWidget(.card, .{
        .id = 1,
        .frame = geometry.RectF.init(0, 0, 240, 240),
        .semantics = .{ .label = "Settings" },
        .children = &children,
    });

    var nodes: [8]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, root.frame, &nodes);

    var semantics_buffer: [8]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 6), semantics.len);
    try std.testing.expectEqual(WidgetRole.group, semantics[0].role);
    try std.testing.expectEqualStrings("Settings", semantics[0].label);
    try std.testing.expectEqual(WidgetRole.button, semantics[1].role);
    try std.testing.expectEqualStrings("Save", semantics[1].label);
    try std.testing.expect(semantics[1].actions.press);
    try std.testing.expectEqual(WidgetRole.textbox, semantics[2].role);
    try std.testing.expectEqualStrings("Project name", semantics[2].label);
    try std.testing.expectEqualStrings("zero-native", semantics[2].text_value);
    try std.testing.expectEqual(WidgetRole.switch_control, semantics[3].role);
    try std.testing.expectEqual(@as(?f32, 1), semantics[3].value);
    try std.testing.expect(semantics[3].actions.toggle);
    try std.testing.expectEqual(WidgetRole.button, semantics[4].role);
    try std.testing.expectEqual(@as(?f32, 1), semantics[4].value);
    try std.testing.expect(semantics[4].actions.toggle);
    try std.testing.expect(!semantics[4].actions.press);
    try std.testing.expectEqual(WidgetRole.grid, semantics[5].role);
    try std.testing.expectEqualStrings("Deployments", semantics[5].label);

    const button = builtinComponentWidget(.button, .{
        .id = 10,
        .frame = geometry.RectF.init(0, 0, 120, 34),
        .text = "Primary",
    });
    var commands: [4]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, button, .{});

    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 3), display_list.commandCount());
    switch (display_list.commands[0]) {
        .fill_rounded_rect => |fill| try expectFillColor(ColorTokens.light().accent, fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[2]) {
        .draw_text => |text| try std.testing.expectEqualDeep(ColorTokens.light().accent_text, text.color),
        else => return error.TestUnexpectedResult,
    }
}

test "built-in toggle renders shadcn toggle button tokens" {
    const toggle = builtinComponentWidget(.toggle, .{
        .id = 14,
        .frame = geometry.RectF.init(0, 0, 84, 32),
        .text = "Bold",
        .state = .{ .selected = true },
    });
    try std.testing.expectEqual(WidgetKind.toggle_button, toggle.kind);
    try std.testing.expectEqual(WidgetVariant.ghost, toggle.variant);

    var nodes: [1]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(toggle, toggle.frame, &nodes);
    try std.testing.expectEqual(WidgetKind.toggle_button, layout.hitTest(geometry.PointF.init(12, 12)).?.kind);

    var semantics_buffer: [1]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 1), semantics.len);
    try std.testing.expectEqual(WidgetRole.button, semantics[0].role);
    try std.testing.expectEqualStrings("Bold", semantics[0].label);
    try std.testing.expectEqual(@as(?f32, 1), semantics[0].value);
    try std.testing.expect(semantics[0].actions.toggle);
    try std.testing.expect(!semantics[0].actions.press);

    const tokens = DesignTokens{
        .controls = .{
            .toggle_button = .{
                .background = Color.rgb8(18, 24, 30),
                .active_background = Color.rgb8(44, 52, 60),
                .foreground = Color.rgb8(242, 246, 250),
                .border = Color.rgb8(68, 78, 88),
                .radius = 6,
                .stroke_width = 1.5,
            },
        },
    };
    var commands: [3]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, toggle, tokens);
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 3), display_list.commandCount());
    switch (display_list.commands[0]) {
        .fill_rounded_rect => |fill| {
            try std.testing.expectEqualDeep(Radius.all(6), fill.radius);
            try expectFillColor(Color.rgb8(44, 52, 60), fill.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[1]) {
        .stroke_rect => |stroke| {
            try std.testing.expectEqual(@as(f32, 1.5), stroke.stroke.width);
            try expectFillColor(Color.rgb8(68, 78, 88), stroke.stroke.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[2]) {
        .draw_text => |text| {
            try std.testing.expectEqualStrings("Bold", text.text);
            try std.testing.expectEqualDeep(Color.rgb8(242, 246, 250), text.color);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "built-in component primitive widgets render distinct shadcn chrome" {
    const widgets = [_]Widget{
        builtinComponentWidget(.avatar, .{
            .id = 20,
            .frame = geometry.RectF.init(0, 0, 40, 40),
            .text = "ZN",
            .semantics = .{ .label = "Zero Native" },
        }),
        builtinComponentWidget(.badge, .{
            .id = 21,
            .frame = geometry.RectF.init(48, 8, 72, 24),
            .text = "Beta",
        }),
        builtinComponentWidget(.separator, .{
            .id = 22,
            .frame = geometry.RectF.init(0, 52, 160, 1),
        }),
        builtinComponentWidget(.skeleton, .{
            .id = 23,
            .frame = geometry.RectF.init(0, 64, 120, 20),
        }),
        builtinComponentWidget(.spinner, .{
            .id = 24,
            .frame = geometry.RectF.init(132, 60, 28, 28),
            .value = 0.25,
        }),
    };

    const root = Widget{ .kind = .stack, .children = &widgets };
    var nodes: [8]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(root, geometry.RectF.init(0, 0, 180, 100), &nodes);

    var semantics_buffer: [4]WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buffer);
    try std.testing.expectEqual(@as(usize, 3), semantics.len);
    try std.testing.expectEqual(WidgetRole.image, semantics[0].role);
    try std.testing.expectEqualStrings("Zero Native", semantics[0].label);
    try std.testing.expectEqual(WidgetRole.text, semantics[1].role);
    try std.testing.expectEqualStrings("Beta", semantics[1].label);
    try std.testing.expectEqual(WidgetRole.progressbar, semantics[2].role);

    var commands: [20]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, .{});

    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 16), display_list.commandCount());
    try std.testing.expect(display_list.commands[0] == .fill_rounded_rect);
    switch (display_list.commands[1]) {
        .draw_text => |text| try std.testing.expectEqualStrings("ZN", text.text),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(display_list.commands[2] == .stroke_rect);
    switch (display_list.commands[3]) {
        .fill_rounded_rect => |fill| try expectFillColor(ColorTokens.light().accent, fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[5]) {
        .draw_text => |text| try std.testing.expectEqualStrings("Beta", text.text),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(display_list.commands[6] == .fill_rect);
    try std.testing.expect(display_list.commands[7] == .fill_rounded_rect);
    for (display_list.commands[8..16]) |command| {
        try std.testing.expect(command == .draw_line);
    }

    const image_avatar = builtinComponentWidget(.avatar, .{
        .id = 30,
        .frame = geometry.RectF.init(0, 0, 40, 40),
        .image_id = 42,
    });
    var image_commands: [5]CanvasCommand = undefined;
    var image_builder = Builder.init(&image_commands);
    try emitWidgetTree(&image_builder, image_avatar, .{});
    const image_display_list = image_builder.displayList();
    try std.testing.expectEqual(@as(usize, 5), image_display_list.commandCount());
    try std.testing.expect(image_display_list.commands[0] == .fill_rounded_rect);
    try std.testing.expect(image_display_list.commands[1] == .push_clip);
    switch (image_display_list.commands[2]) {
        .draw_image => |image| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(30, 3)), image.id);
            try std.testing.expectEqual(@as(ImageId, 42), image.image_id);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(image_display_list.commands[3] == .pop_clip);
    try std.testing.expect(image_display_list.commands[4] == .stroke_rect);
}

test "design token overrides compose with built-in themes" {
    const overrides = DesignTokenOverrides{
        .colors = .{
            .accent = Color.rgb8(12, 34, 56),
            .accent_text = Color.rgb8(240, 244, 248),
            .focus_ring = Color.rgb8(96, 165, 250),
        },
        .typography = .{
            .font_family = .system_sans,
            .button_size = 16,
        },
        .spacing = .{ .md = 14 },
        .radius = .{ .md = 6, .xl = 18 },
        .stroke = .{ .focus = 3 },
        .shadow = .{ .md = .{ .blur = 32, .spread = -16 } },
        .blur = .{ .md = 22 },
        .motion = .{
            .normal_ms = 140,
            .easing = .emphasized,
            .spring = .{ .damping = 20 },
        },
        .scroll = .{
            .wheel_multiplier = 1.25,
            .rubberband_max_extent = 120,
        },
        .layer = .{ .overlay = 240 },
        .pixel_snap = .{ .geometry = true, .text = true, .scale = 2 },
        .controls = .{
            .button_primary = .{
                .background = Color.rgb8(11, 47, 91),
                .foreground = Color.rgb8(245, 250, 255),
                .border = Color.rgb8(9, 36, 72),
                .radius = 9,
                .stroke_width = 2,
            },
            .button_secondary = .{
                .hover_background = Color.rgb8(36, 42, 48),
                .active_background = Color.rgb8(48, 56, 64),
            },
            .toggle_button = .{
                .background = Color.rgb8(18, 24, 30),
                .hover_background = Color.rgb8(32, 38, 44),
                .active_background = Color.rgb8(44, 52, 60),
                .foreground = Color.rgb8(242, 246, 250),
                .border = Color.rgb8(68, 78, 88),
            },
            .select = .{
                .background = Color.rgb8(17, 23, 29),
                .foreground = Color.rgb8(226, 234, 242),
                .border = Color.rgb8(68, 78, 88),
            },
            .input = .{
                .background = Color.rgb8(16, 22, 28),
                .foreground = Color.rgb8(224, 231, 238),
                .border = Color.rgb8(66, 76, 86),
                .radius = 6,
                .stroke_width = 1.25,
            },
            .text_field = .{
                .background = Color.rgb8(15, 20, 25),
                .foreground = Color.rgb8(225, 232, 240),
                .border = Color.rgb8(65, 75, 85),
                .radius = 5,
                .stroke_width = 1.5,
            },
            .search_field = .{
                .background = Color.rgb8(18, 24, 30),
                .foreground = Color.rgb8(210, 220, 230),
            },
            .combobox = .{
                .background = Color.rgb8(20, 26, 32),
                .foreground = Color.rgb8(212, 222, 232),
                .border = Color.rgb8(69, 79, 89),
            },
            .textarea = .{
                .background = Color.rgb8(19, 25, 31),
                .foreground = Color.rgb8(211, 221, 231),
                .border = Color.rgb8(67, 77, 87),
            },
            .list_item = .{
                .hover_background = Color.rgb8(28, 34, 40),
                .active_background = Color.rgb8(38, 46, 54),
                .foreground = Color.rgb8(235, 240, 245),
            },
            .menu_item = .{
                .hover_background = Color.rgb8(30, 36, 42),
                .active_background = Color.rgb8(40, 48, 56),
                .foreground = Color.rgb8(238, 244, 250),
                .radius = 6,
            },
            .data_cell = .{
                .background = Color.rgb8(17, 23, 29),
                .active_background = Color.rgb8(35, 43, 51),
                .foreground = Color.rgb8(232, 238, 244),
                .border = Color.rgb8(61, 71, 81),
            },
            .segmented_control = .{
                .active_background = Color.rgb8(42, 50, 58),
                .foreground = Color.rgb8(250, 252, 255),
            },
            .checkbox = .{
                .active_background = Color.rgb8(44, 54, 64),
                .foreground = Color.rgb8(248, 250, 252),
                .border = Color.rgb8(76, 88, 100),
            },
            .radio = .{
                .active_background = Color.rgb8(46, 58, 70),
                .foreground = Color.rgb8(249, 251, 253),
                .border = Color.rgb8(78, 90, 102),
            },
            .toggle = .{
                .background = Color.rgb8(50, 56, 64),
                .active_background = Color.rgb8(58, 72, 86),
                .foreground = Color.rgb8(252, 252, 253),
            },
            .slider = .{
                .background = Color.rgb8(52, 58, 64),
                .active_background = Color.rgb8(62, 78, 94),
                .foreground = Color.rgb8(245, 248, 250),
            },
            .progress = .{
                .background = Color.rgb8(54, 60, 66),
                .active_background = Color.rgb8(66, 84, 102),
            },
            .scrollbar = .{
                .background = Color.rgb8(24, 30, 36),
                .foreground = Color.rgb8(148, 160, 172),
                .radius = 4,
            },
            .accordion = .{
                .background = Color.rgb8(13, 19, 25),
                .foreground = Color.rgb8(235, 241, 247),
                .border = Color.rgb8(59, 69, 79),
            },
            .alert = .{
                .background = Color.rgb8(14, 20, 26),
                .foreground = Color.rgb8(236, 242, 248),
                .border = Color.rgb8(60, 70, 80),
            },
            .bubble = .{
                .background = Color.rgb8(14, 20, 27),
                .foreground = Color.rgb8(236, 243, 250),
                .border = Color.rgb8(60, 71, 82),
            },
            .card = .{
                .background = Color.rgb8(15, 21, 27),
                .foreground = Color.rgb8(237, 243, 249),
                .border = Color.rgb8(61, 71, 81),
            },
            .dialog = .{
                .background = Color.rgb8(17, 23, 31),
                .foreground = Color.rgb8(238, 244, 250),
                .border = Color.rgb8(63, 73, 85),
            },
            .drawer = .{
                .background = Color.rgb8(18, 24, 32),
                .foreground = Color.rgb8(239, 245, 251),
                .border = Color.rgb8(64, 74, 86),
            },
            .sheet = .{
                .background = Color.rgb8(19, 25, 33),
                .foreground = Color.rgb8(240, 246, 252),
                .border = Color.rgb8(65, 75, 87),
            },
            .panel = .{
                .background = Color.rgb8(16, 22, 28),
                .border = Color.rgb8(58, 68, 78),
                .radius = 16,
                .stroke_width = 2.5,
            },
            .resizable = .{
                .background = Color.rgb8(17, 23, 30),
                .foreground = Color.rgb8(238, 244, 251),
                .border = Color.rgb8(63, 73, 84),
            },
            .popover = .{
                .background = Color.rgb8(18, 24, 32),
                .border = Color.rgb8(62, 72, 84),
            },
            .menu_surface = .{
                .background = Color.rgb8(20, 26, 34),
                .border = Color.rgb8(66, 76, 88),
            },
            .dropdown_menu = .{
                .background = Color.rgb8(21, 27, 35),
                .foreground = Color.rgb8(241, 245, 249),
                .border = Color.rgb8(67, 77, 89),
            },
            .tooltip = .{
                .background = Color.rgb8(238, 242, 246),
                .foreground = Color.rgb8(18, 24, 30),
            },
            .avatar = .{
                .background = Color.rgb8(32, 38, 44),
                .foreground = Color.rgb8(235, 240, 245),
                .border = Color.rgb8(72, 82, 92),
            },
            .badge = .{
                .background = Color.rgb8(24, 48, 96),
                .foreground = Color.rgb8(244, 248, 255),
                .border = Color.rgb8(28, 56, 112),
            },
            .separator = .{
                .background = Color.rgb8(70, 78, 86),
            },
            .skeleton = .{
                .background = Color.rgb8(34, 40, 46),
                .radius = 7,
            },
            .spinner = .{
                .foreground = Color.rgb8(238, 242, 246),
                .stroke_width = 2,
            },
        },
        .density = .spacious,
    };
    const base = DesignTokens.theme(.{ .color_scheme = .dark, .reduce_motion = true });
    const tokens = base.withOverrides(overrides);

    try std.testing.expectEqualDeep(ColorTokens.dark().background, tokens.colors.background);
    try std.testing.expectEqualDeep(Color.rgb8(12, 34, 56), tokens.colors.accent);
    try std.testing.expectEqualDeep(Color.rgb8(240, 244, 248), tokens.colors.accent_text);
    try std.testing.expectEqualDeep(Color.rgb8(96, 165, 250), tokens.colors.focus_ring);
    try std.testing.expectEqual(FontFamily.system_sans, tokens.typography.font_family);
    try std.testing.expectEqual(default_mono_font_family, tokens.typography.mono_font_family);
    try std.testing.expectEqual(@as(f32, 16), tokens.typography.button_size);
    try std.testing.expectEqual(@as(f32, 14), tokens.spacing.md);
    try std.testing.expectEqual(@as(f32, 6), tokens.radius.md);
    try std.testing.expectEqual(@as(f32, 18), tokens.radius.xl);
    try std.testing.expectEqual(@as(f32, 3), tokens.stroke.focus);
    try std.testing.expectEqual(@as(f32, 32), tokens.shadow.md.blur);
    try std.testing.expectEqual(@as(f32, -16), tokens.shadow.md.spread);
    try std.testing.expectEqual(@as(f32, 22), tokens.blur.md);
    try std.testing.expectEqual(@as(u32, 0), tokens.motion.durationMs(.fast));
    try std.testing.expectEqual(@as(u32, 140), tokens.motion.durationMs(.normal));
    try std.testing.expectEqual(Easing.emphasized, tokens.motion.easing);
    try std.testing.expectEqual(@as(f32, 20), tokens.motion.spring.damping);
    try std.testing.expectEqual(@as(f32, 1.25), tokens.scroll.wheel_multiplier);
    try std.testing.expectEqual(@as(f32, 120), tokens.scroll.rubberband_max_extent);
    try std.testing.expectEqual(@as(i32, 240), tokens.layer.overlay);
    try std.testing.expect(tokens.pixel_snap.geometry);
    try std.testing.expect(tokens.pixel_snap.text);
    try std.testing.expectEqual(@as(f32, 2), tokens.pixel_snap.scale);
    try std.testing.expectEqualDeep(Color.rgb8(11, 47, 91), tokens.controls.button_primary.background.?);
    try std.testing.expectEqualDeep(Color.rgb8(245, 250, 255), tokens.controls.button_primary.foreground.?);
    try std.testing.expectEqualDeep(Color.rgb8(9, 36, 72), tokens.controls.button_primary.border.?);
    try std.testing.expectEqual(@as(f32, 9), tokens.controls.button_primary.radius.?);
    try std.testing.expectEqual(@as(f32, 2), tokens.controls.button_primary.stroke_width.?);
    try std.testing.expect(tokens.controls.button_secondary.background == null);
    try std.testing.expectEqualDeep(Color.rgb8(36, 42, 48), tokens.controls.button_secondary.hover_background.?);
    try std.testing.expectEqualDeep(Color.rgb8(48, 56, 64), tokens.controls.button_secondary.active_background.?);
    try std.testing.expectEqualDeep(Color.rgb8(18, 24, 30), tokens.controls.toggle_button.background.?);
    try std.testing.expectEqualDeep(Color.rgb8(32, 38, 44), tokens.controls.toggle_button.hover_background.?);
    try std.testing.expectEqualDeep(Color.rgb8(44, 52, 60), tokens.controls.toggle_button.active_background.?);
    try std.testing.expectEqualDeep(Color.rgb8(242, 246, 250), tokens.controls.toggle_button.foreground.?);
    try std.testing.expectEqualDeep(Color.rgb8(68, 78, 88), tokens.controls.toggle_button.border.?);
    try std.testing.expectEqualDeep(Color.rgb8(17, 23, 29), tokens.controls.select.background.?);
    try std.testing.expectEqualDeep(Color.rgb8(226, 234, 242), tokens.controls.select.foreground.?);
    try std.testing.expectEqualDeep(Color.rgb8(68, 78, 88), tokens.controls.select.border.?);
    try std.testing.expectEqualDeep(Color.rgb8(16, 22, 28), tokens.controls.input.background.?);
    try std.testing.expectEqualDeep(Color.rgb8(224, 231, 238), tokens.controls.input.foreground.?);
    try std.testing.expectEqualDeep(Color.rgb8(66, 76, 86), tokens.controls.input.border.?);
    try std.testing.expectEqual(@as(f32, 6), tokens.controls.input.radius.?);
    try std.testing.expectEqual(@as(f32, 1.25), tokens.controls.input.stroke_width.?);
    try std.testing.expectEqualDeep(Color.rgb8(15, 20, 25), tokens.controls.text_field.background.?);
    try std.testing.expectEqualDeep(Color.rgb8(225, 232, 240), tokens.controls.text_field.foreground.?);
    try std.testing.expectEqualDeep(Color.rgb8(65, 75, 85), tokens.controls.text_field.border.?);
    try std.testing.expectEqual(@as(f32, 5), tokens.controls.text_field.radius.?);
    try std.testing.expectEqual(@as(f32, 1.5), tokens.controls.text_field.stroke_width.?);
    try std.testing.expectEqualDeep(Color.rgb8(18, 24, 30), tokens.controls.search_field.background.?);
    try std.testing.expectEqualDeep(Color.rgb8(210, 220, 230), tokens.controls.search_field.foreground.?);
    try std.testing.expectEqualDeep(Color.rgb8(20, 26, 32), tokens.controls.combobox.background.?);
    try std.testing.expectEqualDeep(Color.rgb8(212, 222, 232), tokens.controls.combobox.foreground.?);
    try std.testing.expectEqualDeep(Color.rgb8(69, 79, 89), tokens.controls.combobox.border.?);
    try std.testing.expectEqualDeep(Color.rgb8(19, 25, 31), tokens.controls.textarea.background.?);
    try std.testing.expectEqualDeep(Color.rgb8(211, 221, 231), tokens.controls.textarea.foreground.?);
    try std.testing.expectEqualDeep(Color.rgb8(67, 77, 87), tokens.controls.textarea.border.?);
    try std.testing.expectEqualDeep(Color.rgb8(28, 34, 40), tokens.controls.list_item.hover_background.?);
    try std.testing.expectEqualDeep(Color.rgb8(38, 46, 54), tokens.controls.list_item.active_background.?);
    try std.testing.expectEqualDeep(Color.rgb8(235, 240, 245), tokens.controls.list_item.foreground.?);
    try std.testing.expectEqualDeep(Color.rgb8(30, 36, 42), tokens.controls.menu_item.hover_background.?);
    try std.testing.expectEqualDeep(Color.rgb8(40, 48, 56), tokens.controls.menu_item.active_background.?);
    try std.testing.expectEqualDeep(Color.rgb8(238, 244, 250), tokens.controls.menu_item.foreground.?);
    try std.testing.expectEqual(@as(f32, 6), tokens.controls.menu_item.radius.?);
    try std.testing.expectEqualDeep(Color.rgb8(17, 23, 29), tokens.controls.data_cell.background.?);
    try std.testing.expectEqualDeep(Color.rgb8(35, 43, 51), tokens.controls.data_cell.active_background.?);
    try std.testing.expectEqualDeep(Color.rgb8(232, 238, 244), tokens.controls.data_cell.foreground.?);
    try std.testing.expectEqualDeep(Color.rgb8(61, 71, 81), tokens.controls.data_cell.border.?);
    try std.testing.expectEqualDeep(Color.rgb8(42, 50, 58), tokens.controls.segmented_control.active_background.?);
    try std.testing.expectEqualDeep(Color.rgb8(250, 252, 255), tokens.controls.segmented_control.foreground.?);
    try std.testing.expectEqualDeep(Color.rgb8(44, 54, 64), tokens.controls.checkbox.active_background.?);
    try std.testing.expectEqualDeep(Color.rgb8(248, 250, 252), tokens.controls.checkbox.foreground.?);
    try std.testing.expectEqualDeep(Color.rgb8(76, 88, 100), tokens.controls.checkbox.border.?);
    try std.testing.expectEqualDeep(Color.rgb8(46, 58, 70), tokens.controls.radio.active_background.?);
    try std.testing.expectEqualDeep(Color.rgb8(249, 251, 253), tokens.controls.radio.foreground.?);
    try std.testing.expectEqualDeep(Color.rgb8(78, 90, 102), tokens.controls.radio.border.?);
    try std.testing.expectEqualDeep(Color.rgb8(50, 56, 64), tokens.controls.toggle.background.?);
    try std.testing.expectEqualDeep(Color.rgb8(58, 72, 86), tokens.controls.toggle.active_background.?);
    try std.testing.expectEqualDeep(Color.rgb8(252, 252, 253), tokens.controls.toggle.foreground.?);
    try std.testing.expectEqualDeep(Color.rgb8(52, 58, 64), tokens.controls.slider.background.?);
    try std.testing.expectEqualDeep(Color.rgb8(62, 78, 94), tokens.controls.slider.active_background.?);
    try std.testing.expectEqualDeep(Color.rgb8(245, 248, 250), tokens.controls.slider.foreground.?);
    try std.testing.expectEqualDeep(Color.rgb8(54, 60, 66), tokens.controls.progress.background.?);
    try std.testing.expectEqualDeep(Color.rgb8(66, 84, 102), tokens.controls.progress.active_background.?);
    try std.testing.expectEqualDeep(Color.rgb8(24, 30, 36), tokens.controls.scrollbar.background.?);
    try std.testing.expectEqualDeep(Color.rgb8(148, 160, 172), tokens.controls.scrollbar.foreground.?);
    try std.testing.expectEqual(@as(f32, 4), tokens.controls.scrollbar.radius.?);
    try std.testing.expectEqualDeep(Color.rgb8(13, 19, 25), tokens.controls.accordion.background.?);
    try std.testing.expectEqualDeep(Color.rgb8(235, 241, 247), tokens.controls.accordion.foreground.?);
    try std.testing.expectEqualDeep(Color.rgb8(59, 69, 79), tokens.controls.accordion.border.?);
    try std.testing.expectEqualDeep(Color.rgb8(14, 20, 26), tokens.controls.alert.background.?);
    try std.testing.expectEqualDeep(Color.rgb8(236, 242, 248), tokens.controls.alert.foreground.?);
    try std.testing.expectEqualDeep(Color.rgb8(60, 70, 80), tokens.controls.alert.border.?);
    try std.testing.expectEqualDeep(Color.rgb8(14, 20, 27), tokens.controls.bubble.background.?);
    try std.testing.expectEqualDeep(Color.rgb8(236, 243, 250), tokens.controls.bubble.foreground.?);
    try std.testing.expectEqualDeep(Color.rgb8(60, 71, 82), tokens.controls.bubble.border.?);
    try std.testing.expectEqualDeep(Color.rgb8(15, 21, 27), tokens.controls.card.background.?);
    try std.testing.expectEqualDeep(Color.rgb8(237, 243, 249), tokens.controls.card.foreground.?);
    try std.testing.expectEqualDeep(Color.rgb8(61, 71, 81), tokens.controls.card.border.?);
    try std.testing.expectEqualDeep(Color.rgb8(17, 23, 31), tokens.controls.dialog.background.?);
    try std.testing.expectEqualDeep(Color.rgb8(238, 244, 250), tokens.controls.dialog.foreground.?);
    try std.testing.expectEqualDeep(Color.rgb8(63, 73, 85), tokens.controls.dialog.border.?);
    try std.testing.expectEqualDeep(Color.rgb8(18, 24, 32), tokens.controls.drawer.background.?);
    try std.testing.expectEqualDeep(Color.rgb8(239, 245, 251), tokens.controls.drawer.foreground.?);
    try std.testing.expectEqualDeep(Color.rgb8(64, 74, 86), tokens.controls.drawer.border.?);
    try std.testing.expectEqualDeep(Color.rgb8(19, 25, 33), tokens.controls.sheet.background.?);
    try std.testing.expectEqualDeep(Color.rgb8(240, 246, 252), tokens.controls.sheet.foreground.?);
    try std.testing.expectEqualDeep(Color.rgb8(65, 75, 87), tokens.controls.sheet.border.?);
    try std.testing.expectEqualDeep(Color.rgb8(16, 22, 28), tokens.controls.panel.background.?);
    try std.testing.expectEqualDeep(Color.rgb8(58, 68, 78), tokens.controls.panel.border.?);
    try std.testing.expectEqual(@as(f32, 16), tokens.controls.panel.radius.?);
    try std.testing.expectEqual(@as(f32, 2.5), tokens.controls.panel.stroke_width.?);
    try std.testing.expectEqualDeep(Color.rgb8(17, 23, 30), tokens.controls.resizable.background.?);
    try std.testing.expectEqualDeep(Color.rgb8(238, 244, 251), tokens.controls.resizable.foreground.?);
    try std.testing.expectEqualDeep(Color.rgb8(63, 73, 84), tokens.controls.resizable.border.?);
    try std.testing.expectEqualDeep(Color.rgb8(18, 24, 32), tokens.controls.popover.background.?);
    try std.testing.expectEqualDeep(Color.rgb8(62, 72, 84), tokens.controls.popover.border.?);
    try std.testing.expectEqualDeep(Color.rgb8(20, 26, 34), tokens.controls.menu_surface.background.?);
    try std.testing.expectEqualDeep(Color.rgb8(66, 76, 88), tokens.controls.menu_surface.border.?);
    try std.testing.expectEqualDeep(Color.rgb8(21, 27, 35), tokens.controls.dropdown_menu.background.?);
    try std.testing.expectEqualDeep(Color.rgb8(241, 245, 249), tokens.controls.dropdown_menu.foreground.?);
    try std.testing.expectEqualDeep(Color.rgb8(67, 77, 89), tokens.controls.dropdown_menu.border.?);
    try std.testing.expectEqualDeep(Color.rgb8(238, 242, 246), tokens.controls.tooltip.background.?);
    try std.testing.expectEqualDeep(Color.rgb8(18, 24, 30), tokens.controls.tooltip.foreground.?);
    try std.testing.expectEqualDeep(Color.rgb8(32, 38, 44), tokens.controls.avatar.background.?);
    try std.testing.expectEqualDeep(Color.rgb8(235, 240, 245), tokens.controls.avatar.foreground.?);
    try std.testing.expectEqualDeep(Color.rgb8(72, 82, 92), tokens.controls.avatar.border.?);
    try std.testing.expectEqualDeep(Color.rgb8(24, 48, 96), tokens.controls.badge.background.?);
    try std.testing.expectEqualDeep(Color.rgb8(244, 248, 255), tokens.controls.badge.foreground.?);
    try std.testing.expectEqualDeep(Color.rgb8(28, 56, 112), tokens.controls.badge.border.?);
    try std.testing.expectEqualDeep(Color.rgb8(70, 78, 86), tokens.controls.separator.background.?);
    try std.testing.expectEqualDeep(Color.rgb8(34, 40, 46), tokens.controls.skeleton.background.?);
    try std.testing.expectEqual(@as(f32, 7), tokens.controls.skeleton.radius.?);
    try std.testing.expectEqualDeep(Color.rgb8(238, 242, 246), tokens.controls.spinner.foreground.?);
    try std.testing.expectEqual(@as(f32, 2), tokens.controls.spinner.stroke_width.?);
    try std.testing.expectEqual(Density.spacious, tokens.density);

    const rebuilt = DesignTokens.themeWithOverrides(.{ .color_scheme = .dark, .reduce_motion = true }, overrides);
    try std.testing.expectEqualDeep(tokens, rebuilt);
    try std.testing.expectEqualDeep(tokens, overrides.apply(base));
}

test "design token overrides flow into widget display lists" {
    const tokens = DesignTokens.themeWithOverrides(.{}, .{
        .colors = .{
            .accent = Color.rgb8(80, 40, 120),
            .accent_text = Color.rgb8(250, 250, 255),
            .focus_ring = Color.rgb8(180, 120, 255),
        },
        .stroke = .{ .focus = 4 },
        .radius = .{ .md = 5 },
    });
    const button = Widget{
        .id = 42,
        .kind = .button,
        .frame = geometry.RectF.init(0, 0, 120, 36),
        .text = "Brand",
        .state = .{ .selected = true, .focused = true },
    };

    var commands: [4]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, button, tokens);
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 4), display_list.commandCount());
    switch (display_list.commands[0]) {
        .fill_rounded_rect => |fill| {
            try expectFillColor(tokens.colors.accent, fill.fill);
            try std.testing.expectEqualDeep(Radius.all(5), fill.radius);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[2]) {
        .stroke_rect => |stroke| {
            try expectFillColor(tokens.colors.focus_ring, stroke.stroke.fill);
            try std.testing.expectEqual(@as(f32, 4), stroke.stroke.width);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[3]) {
        .draw_text => |text| try std.testing.expectEqualDeep(tokens.colors.accent_text, text.color),
        else => return error.TestUnexpectedResult,
    }
}

test "typography tokens expose customizable font family metadata" {
    const tokens = TypographyTokens{
        .font_id = 7,
        .mono_font_id = 8,
        .font_family = .system_sans,
        .mono_font_family = .system_mono,
    };
    try std.testing.expectEqual(@as(FontId, 7), tokens.font_id);
    try std.testing.expectEqual(@as(FontId, 8), tokens.mono_font_id);
    try std.testing.expectEqualStrings("system-ui", tokens.bodyFamilyName());
    try std.testing.expectEqualStrings("ui-monospace", tokens.monoFamilyName());
}

test "themed design tokens flow into widget display lists" {
    const tokens = DesignTokens.theme(.{ .color_scheme = .dark, .contrast = .high });
    const button = Widget{
        .id = 9,
        .kind = .button,
        .frame = geometry.RectF.init(8, 8, 96, 32),
        .text = "Run",
        .state = .{ .selected = true, .focused = true },
    };

    var commands: [4]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, button, tokens);
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 4), display_list.commandCount());

    switch (display_list.commands[0]) {
        .fill_rounded_rect => |fill| try expectFillColor(tokens.colors.accent, fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[1]) {
        .stroke_rect => |stroke| try expectFillColor(tokens.colors.border, stroke.stroke.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[2]) {
        .stroke_rect => |stroke| try expectFillColor(tokens.colors.focus_ring, stroke.stroke.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[3]) {
        .draw_text => |text| try std.testing.expectEqualDeep(tokens.colors.accent_text, text.color),
        else => return error.TestUnexpectedResult,
    }
}

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
    try std.testing.expectEqual(WidgetRole.switch_control, semantics[3].role);
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

    var button_commands: [3]CanvasCommand = undefined;
    var button_builder = Builder.init(&button_commands);
    try emitWidgetTree(&button_builder, children[1], tokens);
    const button_display_list = button_builder.displayList();
    try std.testing.expectEqual(@as(usize, 3), button_display_list.commandCount());
    switch (button_display_list.commands[1]) {
        .stroke_rect => |stroke| {
            try std.testing.expectEqual(@as(f32, 4), stroke.stroke.width);
            try expectFillColor(tokens.colors.focus_ring, stroke.stroke.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (button_display_list.commands[2]) {
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
    var commands: [3]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, text_field, tokens);
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 3), display_list.commandCount());
    switch (display_list.commands[1]) {
        .stroke_rect => |stroke| {
            try std.testing.expectEqual(@as(f32, 3), stroke.stroke.width);
            try expectFillColor(tokens.colors.focus_ring, stroke.stroke.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[2]) {
        .draw_text => |text| try std.testing.expectEqualStrings("search terms", text.text),
        else => return error.TestUnexpectedResult,
    }
}

test "widget inputs expose textbox semantics and render shadcn input tokens" {
    const input = Widget{
        .id = 18,
        .kind = .input,
        .frame = geometry.RectF.init(10, 12, 180, 36),
        .text = "zero-native",
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
    try std.testing.expectEqualStrings("zero-native", semantics[0].text_value);
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
            try std.testing.expectEqualStrings("zero-native", text.text);
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
    var commands: [5]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, select, tokens);
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 5), display_list.commandCount());
    switch (display_list.commands[0]) {
        .fill_rounded_rect => |fill| {
            try expectFillColor(Color.rgb8(20, 24, 28), fill.fill);
            try std.testing.expectEqualDeep(Radius.all(5), fill.radius);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[1]) {
        .stroke_rect => |stroke| {
            try std.testing.expectEqual(@as(f32, 3), stroke.stroke.width);
            try expectFillColor(tokens.colors.focus_ring, stroke.stroke.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[2]) {
        .draw_text => |text| {
            try std.testing.expectEqualStrings("Production", text.text);
            try std.testing.expectEqualDeep(Color.rgb8(238, 242, 246), text.color);
            try std.testing.expect(text.text_layout != null);
            try std.testing.expect(text.text_layout.?.max_width < select.frame.width);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[3]) {
        .draw_line => |line| try expectFillColor(Color.rgb8(238, 242, 246), line.stroke.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[4]) {
        .draw_line => |line| try expectFillColor(Color.rgb8(238, 242, 246), line.stroke.fill),
        else => return error.TestUnexpectedResult,
    }

    var placeholder_commands: [5]CanvasCommand = undefined;
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
    try expectRectApprox(geometry.RectF.init(112.042, 21.25, 1, 17.5), search_geometry.caret_bounds.?);
    try std.testing.expectEqual(@as(usize, 0), search_geometry.selection_rect_count);

    const tokens = DesignTokens{
        .colors = .{ .focus_ring = Color.rgb8(1, 2, 3), .text_muted = Color.rgb8(90, 91, 92) },
        .stroke = .{ .focus = 3 },
    };
    var commands: [9]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, search_field, tokens);
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 9), display_list.commandCount());
    switch (display_list.commands[1]) {
        .stroke_rect => |stroke| {
            try std.testing.expectEqual(@as(f32, 3), stroke.stroke.width);
            try expectFillColor(tokens.colors.focus_ring, stroke.stroke.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[2]) {
        .draw_line => |line| try std.testing.expectEqual(@as(ObjectId, widgetPartId(10, 3)), line.id),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[7]) {
        .draw_text => |text| try std.testing.expectEqualStrings("customers", text.text),
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
    try std.testing.expectEqual(@as(usize, 10), display_list.commandCount());
    switch (display_list.commands[7]) {
        .draw_text => |text| {
            try std.testing.expectEqualStrings("components", text.text);
            try std.testing.expect(text.text_layout != null);
            try std.testing.expect(text.text_layout.?.max_width < combobox.frame.width);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[8]) {
        .draw_line => |line| try std.testing.expectEqual(@as(ObjectId, widgetPartId(14, 12)), line.id),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[9]) {
        .draw_line => |line| try std.testing.expectEqual(@as(ObjectId, widgetPartId(14, 13)), line.id),
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

    var commands: [6]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, textarea, .{});
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 6), display_list.commandCount());
    switch (display_list.commands[2]) {
        .push_clip => |clip| try expectRectApprox(textInputViewportForWidget(textarea, .{}).?, clip.rect),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[3]) {
        .draw_text => |text| {
            try std.testing.expectEqualStrings("First line Second line", text.text);
            try std.testing.expect(text.text_layout != null);
            try std.testing.expectEqual(TextWrap.word, text.text_layout.?.wrap);
            try std.testing.expect(text.origin.y < textarea.frame.y + textarea.frame.height * 0.5);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[4]) {
        .draw_line => |line| try expectFillColor(ColorTokens.light().focus_ring, line.stroke.fill),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(CanvasCommand.pop_clip, display_list.commands[5]);
}

test "widget text fields render selection caret and composition ranges" {
    const affordance_color = Color.rgb8(40, 80, 120);
    const tokens = DesignTokens{
        .colors = .{ .focus_ring = Color.rgb8(10, 20, 30) },
        .controls = .{
            .text_field = .{ .active_background = affordance_color },
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
    try expectRectApprox(geometry.RectF.init(28.036, 19.25, 24.57, 17.5), text_geometry.selection_bounds.?);
    try std.testing.expectEqual(@as(usize, 1), text_geometry.composition_rect_count);
    try expectRectApprox(geometry.RectF.init(36.464, 19.25, 16.142, 17.5), text_geometry.composition_bounds.?);

    var commands: [6]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, tokens);
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 5), display_list.commandCount());
    switch (display_list.commands[2]) {
        .fill_rounded_rect => |selection| try expectFillColor(textSelectionFillColor(composing, tokens), selection.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[3]) {
        .draw_text => |text| {
            try std.testing.expectEqualStrings("abcdef", text.text);
            try std.testing.expect(text.text_layout != null);
            try std.testing.expectEqual(TextWrap.none, text.text_layout.?.wrap);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[4]) {
        .draw_line => |line| try expectFillColor(affordance_color, line.stroke.fill),
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
    var caret_commands: [4]CanvasCommand = undefined;
    var caret_builder = Builder.init(&caret_commands);
    try emitWidgetTree(&caret_builder, caret, tokens);
    const caret_display_list = caret_builder.displayList();
    try std.testing.expectEqual(@as(usize, 4), caret_display_list.commandCount());
    switch (caret_display_list.commands[3]) {
        .draw_line => |line| {
            try expectFillColor(affordance_color, line.stroke.fill);
            try std.testing.expectEqual(line.from.x, line.to.x);
        },
        else => return error.TestUnexpectedResult,
    }
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

    var commands: [6]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, field, tokens);

    var nodes: [1]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(field, field.frame, &nodes);
    const text_geometry = layout.textGeometry(11, tokens).?;
    try std.testing.expectEqual(@as(usize, 2), text_geometry.selection_rect_count);
    try expectRectApprox(geometry.RectF.init(8, 10, 14.01, 25), text_geometry.selection_bounds.?);

    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 5), display_list.commandCount());
    switch (display_list.commands[2]) {
        .fill_rounded_rect => |selection| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(11, 3)), selection.id);
            try expectRectApprox(geometry.RectF.init(14.68, 10, 6.78, 12.5), selection.rect);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[3]) {
        .fill_rounded_rect => |selection| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(11, 13)), selection.id);
            try expectRectApprox(geometry.RectF.init(8, 22.5, 14.01, 12.5), selection.rect);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[4]) {
        .draw_text => |text| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(11, 4)), text.id);
            try std.testing.expectEqualStrings("AB CD", text.text);
            try std.testing.expectEqual(TextWrap.word, text.text_layout.?.wrap);
            try std.testing.expectEqual(@as(f32, 20), text.text_layout.?.max_width);
        },
        else => return error.TestUnexpectedResult,
    }
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
    try std.testing.expectEqual(@as(usize, 6), display_list.commandCount());
    try std.testing.expect(display_list.commands[0] == .shadow);
    try std.testing.expectEqual(@as(?ObjectId, widgetPartId(1, 2)), display_list.commands[1].objectId());
    try std.testing.expect(display_list.commands[1] == .fill_rounded_rect);
    try std.testing.expectEqual(@as(?ObjectId, widgetPartId(2, 1)), display_list.commands[3].objectId());

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
    try expectLayoutFrame(layout, 2, geometry.RectF.init(26, 30, 168, 28));
    try expectLayoutFrame(layout, 3, geometry.RectF.init(26, 60, 168, 28));

    var commands: [8]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, .{});
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 6), display_list.commandCount());
    try std.testing.expect(display_list.commands[0] == .shadow);
    try std.testing.expectEqual(@as(?ObjectId, widgetPartId(1, 2)), display_list.commands[1].objectId());
    try std.testing.expectEqual(@as(?ObjectId, widgetPartId(2, 1)), display_list.commands[3].objectId());

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

test "widget dropdown menus expose menu semantics with shadcn surface chrome" {
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
    try expectLayoutFrame(layout, 12, geometry.RectF.init(16, 20, 152, 28));
    try expectLayoutFrame(layout, 13, geometry.RectF.init(16, 50, 128, 1));
    try expectLayoutFrame(layout, 14, geometry.RectF.init(16, 53, 152, 28));
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
    try expectLayoutFrame(layout, 2, geometry.RectF.init(0, 0, 320, 28));
    try expectLayoutFrame(layout, 3, geometry.RectF.init(0, 0, 160, 28));
    try expectLayoutFrame(layout, 5, geometry.RectF.init(0, 30, 320, 28));
    try expectLayoutFrame(layout, 6, geometry.RectF.init(0, 30, 160, 28));
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
    try expectLayoutFrame(layout, 22, geometry.RectF.init(0, 0, 320, 28));
    try expectLayoutFrame(layout, 23, geometry.RectF.init(0, 0, 160, 28));
    try expectLayoutFrame(layout, 25, geometry.RectF.init(0, 30, 320, 28));
    try expectLayoutFrame(layout, 26, geometry.RectF.init(0, 30, 160, 28));

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
    try expectRect(geometry.RectF.init(9, 69, 102, 32), focus_invalidations[0].dirty_bounds);
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
        geometry.RectF.init(9, 11, 98, 78),
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
        geometry.RectF.init(7, 9, 102, 38),
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
    try std.testing.expectEqual(@as(usize, 9), frame.renderPass().commandCount());

    var pixels: [240 * 128 * 4]u8 = undefined;
    const surface = try ReferenceRenderSurface.init(240, 128, &pixels);
    try surface.renderPass(frame.renderPass(), Color.rgb8(0, 0, 0));

    try expectPixelRgba8(.{ 255, 255, 255, 255 }, surface, 220, 20);
    try expectPixelRgba8(.{ 24, 24, 27, 255 }, surface, 20, 100);
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

    var commands: [4]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, button, tokens);

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

    var commands: [15]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, .{ .id = 20, .kind = .button, .frame = geometry.RectF.init(0, 0, 120, 32), .text = "Primary", .variant = .primary }, tokens);
    try emitWidgetTree(&builder, .{ .id = 21, .kind = .button, .frame = geometry.RectF.init(0, 40, 120, 32), .text = "Secondary", .variant = .secondary }, tokens);
    try emitWidgetTree(&builder, .{ .id = 22, .kind = .button, .frame = geometry.RectF.init(0, 80, 120, 32), .text = "Outline", .variant = .outline }, tokens);
    try emitWidgetTree(&builder, .{ .id = 23, .kind = .button, .frame = geometry.RectF.init(0, 120, 120, 32), .text = "Ghost", .variant = .ghost }, tokens);
    try emitWidgetTree(&builder, .{ .id = 24, .kind = .button, .frame = geometry.RectF.init(0, 160, 120, 32), .text = "Delete", .variant = .destructive }, tokens);

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
        .fill_rounded_rect => |fill| try expectFillColor(tokens.colors.destructive, fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[14]) {
        .draw_text => |text| try std.testing.expectEqualDeep(tokens.colors.destructive_text, text.color),
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

    var commands: [9]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, .{ .id = 30, .kind = .button, .frame = geometry.RectF.init(0, 0, 120, 32), .text = "Primary", .variant = .primary, .state = .{ .hovered = true } }, tokens);
    try emitWidgetTree(&builder, .{ .id = 31, .kind = .button, .frame = geometry.RectF.init(0, 40, 120, 32), .text = "Secondary", .variant = .secondary, .state = .{ .pressed = true } }, tokens);
    try emitWidgetTree(&builder, .{ .id = 32, .kind = .button, .frame = geometry.RectF.init(0, 80, 120, 32), .text = "Local", .variant = .primary, .style = .{ .accent = Color.rgb8(1, 2, 3), .accent_foreground = Color.rgb8(4, 5, 6), .border = Color.rgb8(7, 8, 9) } }, tokens);

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
    try std.testing.expectEqual(@as(usize, 18), display_list.commandCount());
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
    switch (display_list.commands[5]) {
        .draw_line => |line| try expectFillColor(Color.rgb8(210, 220, 230), line.stroke.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[10]) {
        .draw_text => |text| {
            try std.testing.expectEqualStrings("Search", text.text);
            try std.testing.expectEqualDeep(Color.rgb8(210, 220, 230), text.color);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[11]) {
        .fill_rounded_rect => |fill| try expectFillColor(Color.rgb8(28, 32, 36), fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[12]) {
        .stroke_rect => |stroke| try expectFillColor(Color.rgb8(96, 106, 116), stroke.stroke.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[13]) {
        .push_clip => {},
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[14]) {
        .draw_text => |text| try std.testing.expectEqualDeep(Color.rgb8(236, 240, 244), text.color),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(CanvasCommand.pop_clip, display_list.commands[15]);
    switch (display_list.commands[16]) {
        .fill_rounded_rect => |fill| try expectFillColor(Color.rgb8(52, 62, 72), fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[17]) {
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

    var commands: [3]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, .{
        .id = 55,
        .kind = .menu_item,
        .frame = geometry.RectF.init(0, 0, 180, 30),
        .text = "Copy token",
        .state = .{ .selected = true },
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
            .toggle = .{
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
    try emitWidgetTree(&builder, .{ .id = 62, .kind = .toggle, .frame = geometry.RectF.init(0, 80, 140, 32), .text = "Live", .value = 1 }, tokens);
    try emitWidgetTree(&builder, .{ .id = 63, .kind = .slider, .frame = geometry.RectF.init(0, 124, 160, 32), .value = 0.25 }, tokens);
    try emitWidgetTree(&builder, .{ .id = 64, .kind = .progress, .frame = geometry.RectF.init(0, 172, 160, 8), .value = 0.5 }, tokens);

    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 18), display_list.commandCount());
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
        .draw_line => |line| try expectFillColor(Color.rgb8(250, 252, 255), line.stroke.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[8]) {
        .fill_rounded_rect => |fill| try expectFillColor(Color.rgb8(34, 70, 108), fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[10]) {
        .fill_rounded_rect => |fill| try expectFillColor(Color.rgb8(248, 250, 252), fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[12]) {
        .fill_rounded_rect => |fill| try expectFillColor(Color.rgb8(50, 56, 64), fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[13]) {
        .fill_rounded_rect => |fill| try expectFillColor(Color.rgb8(38, 76, 114), fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[14]) {
        .fill_rounded_rect => |fill| try expectFillColor(Color.rgb8(246, 248, 250), fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[16]) {
        .fill_rounded_rect => |fill| try expectFillColor(Color.rgb8(52, 58, 66), fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[17]) {
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

    var commands: [11]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, .{ .id = 80, .kind = .button, .variant = .primary, .frame = geometry.RectF.init(0, 0, 120, 32), .text = "Save" }, tokens);
    try emitWidgetTree(&builder, .{ .id = 81, .kind = .text_field, .frame = geometry.RectF.init(0, 40, 160, 34), .text = "Name" }, tokens);
    try emitWidgetTree(&builder, .{ .id = 82, .kind = .checkbox, .frame = geometry.RectF.init(0, 86, 40, 24) }, tokens);
    try emitWidgetTree(&builder, .{ .id = 83, .kind = .panel, .frame = geometry.RectF.init(0, 120, 180, 90), .style = .{ .radius = 6, .stroke_width = 1 } }, tokens);

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

    var commands: [12]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, .{ .id = 40, .kind = .button, .frame = geometry.RectF.init(0, 0, 120, 32), .text = "Small", .size = .sm }, tokens);
    try emitWidgetTree(&builder, .{ .id = 41, .kind = .button, .frame = geometry.RectF.init(0, 40, 120, 32), .text = "Large", .size = .lg }, tokens);
    try emitWidgetTree(&builder, .{ .id = 42, .kind = .text_field, .frame = geometry.RectF.init(0, 80, 120, 32), .text = "Input", .size = .sm }, tokens);
    try emitWidgetTree(&builder, .{ .id = 43, .kind = .checkbox, .frame = geometry.RectF.init(0, 120, 80, 20), .size = .lg }, tokens);

    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 11), display_list.commandCount());
    switch (display_list.commands[0]) {
        .fill_rounded_rect => |fill| try std.testing.expectEqualDeep(Radius.all(6), fill.radius),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[2]) {
        .draw_text => |text| {
            try std.testing.expectEqual(@as(f32, 13), text.size);
            try std.testing.expect(text.text_layout != null);
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
            try std.testing.expectEqual(@as(f32, 15), text.size);
            try std.testing.expect(text.text_layout != null);
            try std.testing.expectApproxEqAbs(@as(f32, 92), text.text_layout.?.max_width, 0.001);
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
        .fill_rounded_rect => |fill| try std.testing.expectApproxEqAbs(@as(f32, 15.75), fill.rect.width, 0.001),
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

    var commands: [8]CanvasCommand = undefined;
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

    var compact_button_commands: [4]CanvasCommand = undefined;
    var compact_button_builder = Builder.init(&compact_button_commands);
    try emitWidgetTree(&compact_button_builder, button, .{ .density = .compact });
    switch (compact_button_builder.displayList().commands[2]) {
        .draw_text => |text| {
            try std.testing.expectApproxEqAbs(@as(f32, 10.5), text.origin.x, 0.001);
            try std.testing.expect(text.text_layout != null);
            try std.testing.expectApproxEqAbs(@as(f32, 119), text.text_layout.?.max_width, 0.001);
            try std.testing.expectEqual(TextAlign.center, text.text_layout.?.alignment);
        },
        else => return error.TestUnexpectedResult,
    }

    var regular_button_commands: [4]CanvasCommand = undefined;
    var regular_button_builder = Builder.init(&regular_button_commands);
    try emitWidgetTree(&regular_button_builder, button, .{ .density = .regular });
    switch (regular_button_builder.displayList().commands[2]) {
        .draw_text => |text| {
            try std.testing.expectApproxEqAbs(@as(f32, 12), text.origin.x, 0.001);
            try std.testing.expect(text.text_layout != null);
            try std.testing.expectApproxEqAbs(@as(f32, 116), text.text_layout.?.max_width, 0.001);
            try std.testing.expectEqual(TextAlign.center, text.text_layout.?.alignment);
        },
        else => return error.TestUnexpectedResult,
    }

    var spacious_button_commands: [4]CanvasCommand = undefined;
    var spacious_button_builder = Builder.init(&spacious_button_commands);
    try emitWidgetTree(&spacious_button_builder, button, .{ .density = .spacious });
    switch (spacious_button_builder.displayList().commands[2]) {
        .draw_text => |text| {
            try std.testing.expectApproxEqAbs(@as(f32, 13.5), text.origin.x, 0.001);
            try std.testing.expect(text.text_layout != null);
            try std.testing.expectApproxEqAbs(@as(f32, 113), text.text_layout.?.max_width, 0.001);
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
        .fill_rounded_rect => |fill| try std.testing.expectApproxEqAbs(@as(f32, 12.25), fill.rect.width, 0.001),
        else => return error.TestUnexpectedResult,
    }

    var regular_checkbox_commands: [2]CanvasCommand = undefined;
    var regular_checkbox_builder = Builder.init(&regular_checkbox_commands);
    try emitWidgetTree(&regular_checkbox_builder, checkbox, .{ .density = .regular });
    switch (regular_checkbox_builder.displayList().commands[0]) {
        .fill_rounded_rect => |fill| try std.testing.expectApproxEqAbs(@as(f32, 14), fill.rect.width, 0.001),
        else => return error.TestUnexpectedResult,
    }

    var spacious_checkbox_commands: [2]CanvasCommand = undefined;
    var spacious_checkbox_builder = Builder.init(&spacious_checkbox_commands);
    try emitWidgetTree(&spacious_checkbox_builder, checkbox, .{ .density = .spacious });
    switch (spacious_checkbox_builder.displayList().commands[0]) {
        .fill_rounded_rect => |fill| try std.testing.expectApproxEqAbs(@as(f32, 15.75), fill.rect.width, 0.001),
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

    var commands: [8]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayListWithState(&builder, tokens, .{ .focused_id = 2, .focus_visible_id = 2, .hovered_id = 2, .pressed_id = 2 });

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
    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(?ObjectId, widgetPartId(2, 1)), display_list.commands[0].objectId());
    try std.testing.expectEqual(@as(?ObjectId, widgetPartId(3, 1)), display_list.commands[3].objectId());
    try std.testing.expectEqual(@as(ObjectId, 3), layout.hitTest(geometry.PointF.init(20, 20)).?.id);
}

test "widget emitter renders checkbox radio toggle and slider controls" {
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
        .kind = .toggle,
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
    try std.testing.expectEqual(@as(usize, 19), display_list.commandCount());
    switch (display_list.commands[0]) {
        .fill_rounded_rect => |fill| try expectFillColor(tokens.colors.accent, fill.fill),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(display_list.commands[3] == .draw_line);
    try std.testing.expect(display_list.commands[4] == .draw_line);
    switch (display_list.commands[5]) {
        .draw_text => |text| try std.testing.expectEqualStrings("Live", text.text),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[6]) {
        .fill_rounded_rect => |fill| try expectFillColor(tokens.colors.surface, fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[9]) {
        .fill_rounded_rect => |fill| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(11, 4)), fill.id);
            try expectFillColor(tokens.colors.accent, fill.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[10]) {
        .draw_text => |text| try std.testing.expectEqualStrings("Monthly", text.text),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[11]) {
        .fill_rounded_rect => |fill| try expectFillColor(tokens.colors.accent, fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[14]) {
        .draw_text => |text| try std.testing.expectEqualStrings("Mode", text.text),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[16]) {
        .fill_rounded_rect => |fill| try expectRect(geometry.RectF.init(0, 138, 40, 4), fill.rect),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[18]) {
        .stroke_rect => |stroke| {
            try std.testing.expectEqual(@as(ObjectId, widgetPartId(13, 4)), stroke.id);
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
                try std.testing.expectEqualDeep(box.rect, focus.rect);
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
                try std.testing.expectEqualDeep(circle.rect, focus.rect);
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
    const switch_track = switch_display_list.findCommandById(widgetPartId(22, 2)).?.command;
    const switch_focus = switch_display_list.findCommandById(widgetPartId(22, 4)).?.command;
    switch (switch_track) {
        .stroke_rect => |track| switch (switch_focus) {
            .stroke_rect => |focus| {
                try std.testing.expectEqualDeep(track.rect, focus.rect);
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

    try expectRectApprox(
        geometry.RectF.init(8, 15.2, 21.6, 21.6),
        layout.renderStateDirtyBoundsWithTokens(.{}, .{ .focused_id = 20, .focus_visible_id = 20 }, tokens),
    );
    try expectRect(
        geometry.RectF.init(8, 54, 60, 28),
        layout.renderStateDirtyBoundsWithTokens(.{}, .{ .focused_id = 21, .focus_visible_id = 21 }, tokens),
    );
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
    var commands: [6]CanvasCommand = undefined;
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
    try std.testing.expectEqual(@as(usize, 6), display_list.commandCount());
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
    switch (display_list.commands[3]) {
        .fill_rounded_rect => |fill| try expectFillColor(tokens.colors.accent, fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[4]) {
        .stroke_rect => |stroke| {
            try std.testing.expectEqual(@as(f32, 3), stroke.stroke.width);
            try expectFillColor(tokens.colors.focus_ring, stroke.stroke.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.commands[5]) {
        .draw_text => |text| try std.testing.expectEqualDeep(tokens.colors.accent_text, text.color),
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
    try expectRectApprox(geometry.RectF.init(0, 0, 83.448, 21), batch_plan.bounds);
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
    try std.testing.expect(std.mem.indexOf(u8, packet_json, "\"width\":1,\"height\":1,\"pixels\":[11,22,33,255]") != null);
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
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 0, 1);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 1, 1);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 2, 1);
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

    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 1, 1);
    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 2, 1);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 3, 1);
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

    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 1, 1);
    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 2, 1);
    try expectPixelRgba8(.{ 255, 0, 0, 255 }, surface, 3, 1);
    try expectPixelRgba8(.{ 0, 0, 0, 255 }, surface, 4, 1);
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

test "reference renderer rejects unsupported images" {
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

    var pixels: [2 * 2 * 4]u8 = undefined;
    const surface = try ReferenceRenderSurface.init(2, 2, &pixels);
    try std.testing.expectError(error.ReferenceRenderUnsupportedCommand, surface.renderPass(frame.renderPass(), Color.rgb8(0, 0, 0)));
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
    try expectRectApprox(geometry.RectF.init(2, 8, 15.78, 12.5), textBounds(.{
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
    try expectRect(geometry.RectF.init(4, 8, 13, 17.5), textBounds(.{
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
    try expectRectApprox(geometry.RectF.init(0, 0, 7.01, 48), textBounds(text));

    const commands = [_]CanvasCommand{.{ .draw_text = text }};
    var render_commands: [1]RenderCommand = undefined;
    const render_plan = try (DisplayList{ .commands = &commands }).renderPlan(&render_commands);
    try std.testing.expectEqual(@as(usize, 1), render_plan.commandCount());
    try expectRectApprox(geometry.RectF.init(0, 0, 7.01, 48), render_plan.commands[0].bounds);

    var pixels: [16 * 32 * 4]u8 = [_]u8{0} ** (16 * 32 * 4);
    const surface = try ReferenceRenderSurface.init(16, 32, &pixels);
    try surface.renderPass(.{
        .commands = render_plan.commands,
        .surface_size = geometry.SizeF.init(16, 32),
        .full_repaint = true,
    }, Color.rgb8(0, 0, 0));
    try expectPixelRgba8([4]u8{ 255, 255, 255, 255 }, surface, 1, 1);
    try expectPixelRgba8([4]u8{ 255, 255, 255, 255 }, surface, 1, 13);
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
    try expectRectApprox(geometry.RectF.init(4, 10, 24.23, 14), layout.lines[0].bounds);
    try std.testing.expectEqual(@as(usize, 6), layout.lines[1].text_start);
    try std.testing.expectEqual(@as(usize, 5), layout.lines[1].text_len);
    try std.testing.expectEqual(@as(f32, 34), layout.lines[1].baseline);
    try std.testing.expectEqual(@as(usize, 12), layout.lines[2].text_start);
    try std.testing.expectEqual(@as(usize, 4), layout.lines[2].text_len);
    try std.testing.expectEqual(@as(usize, 17), layout.lines[3].text_start);
    try std.testing.expectEqual(@as(usize, 4), layout.lines[3].text_len);
    try expectRectApprox(geometry.RectF.init(4, 10, 26.7, 56), layout.bounds);
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
    try expectRectApprox(geometry.RectF.init(14.23, 10, 9.54, 14), centered.layout.lines[0].bounds);
    try expectRectApprox(geometry.RectF.init(14.23, 10, 9.54, 14), centered.layout.bounds);

    var end_lines: [1]TextLine = undefined;
    const end = try layoutTextRun(text, .{ .max_width = 30, .line_height = 14, .alignment = .end }, &end_lines);
    try expectRectApprox(geometry.RectF.init(24.46, 10, 9.54, 14), end.lines[0].bounds);

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
    try expectRectApprox(geometry.RectF.init(28.23, 10, 1, 14), try layoutTextCaretRect(text, options, 5, &caret_lines));

    var selection_lines: [2]TextLine = undefined;
    var selection_rects: [2]TextSelectionRect = undefined;
    const rects = try layoutTextSelectionRects(text, options, TextRange.init(3, 8), &selection_lines, &selection_rects);
    try std.testing.expectEqual(@as(usize, 2), rects.len);
    try std.testing.expectEqualDeep(TextRange.init(3, 5), rects[0].range);
    try expectRectApprox(geometry.RectF.init(19.57, 10, 8.66, 14), rects[0].rect);
    try std.testing.expectEqualDeep(TextRange.init(6, 8), rects[1].range);
    try expectRectApprox(geometry.RectF.init(4, 24, 13.95, 14), rects[1].rect);

    const dashboard_value = DrawText{
        .font_id = default_sans_font_id,
        .size = 17,
        .origin = geometry.PointF.init(0, 17),
        .color = Color.rgb8(0, 0, 0),
        .text = "$13.4M",
    };
    var dashboard_value_lines: [1]TextLine = undefined;
    try expectRectApprox(
        geometry.RectF.init(55.709, 0, 1, 21.25),
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

test "text layout measures utf8 scalars for fallback wrapping" {
    const text = DrawText{
        .font_id = 1,
        .size = 10,
        .origin = geometry.PointF.init(2, 18),
        .color = Color.rgb8(0, 0, 0),
        .text = "éééé éé",
    };

    var lines: [3]TextLine = undefined;
    const layout = try layoutTextRun(text, .{ .max_width = 20, .line_height = 12, .wrap = .word }, &lines);
    try std.testing.expectEqual(@as(usize, 3), layout.lineCount());
    try std.testing.expectEqual(@as(usize, 0), layout.lines[0].text_start);
    try std.testing.expectEqual(@as(usize, 6), layout.lines[0].text_len);
    try expectRectApprox(geometry.RectF.init(2, 8, 19.5, 12), layout.lines[0].bounds);
    try std.testing.expectEqual(@as(usize, 6), layout.lines[1].text_start);
    try std.testing.expectEqual(@as(usize, 2), layout.lines[1].text_len);
    try expectRectApprox(geometry.RectF.init(2, 20, 6.5, 12), layout.lines[1].bounds);
    try std.testing.expectEqual(@as(usize, 9), layout.lines[2].text_start);
    try std.testing.expectEqual(@as(usize, 4), layout.lines[2].text_len);
    try expectRectApprox(geometry.RectF.init(2, 32, 13, 12), layout.lines[2].bounds);
    try expectRectApprox(geometry.RectF.init(2, 8, 19.5, 36), layout.bounds);

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
    try expectRectApprox(geometry.RectF.init(4, 10, 26.7, 56), first.entries[0].bounds);
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

fn expectRect(expected: geometry.RectF, actual: ?geometry.RectF) !void {
    try std.testing.expect(actual != null);
    try std.testing.expectEqualDeep(expected, actual.?);
}

fn expectRectApprox(expected: geometry.RectF, actual: ?geometry.RectF) !void {
    try std.testing.expect(actual != null);
    try std.testing.expectApproxEqAbs(expected.x, actual.?.x, 0.001);
    try std.testing.expectApproxEqAbs(expected.y, actual.?.y, 0.001);
    try std.testing.expectApproxEqAbs(expected.width, actual.?.width, 0.001);
    try std.testing.expectApproxEqAbs(expected.height, actual.?.height, 0.001);
}

fn expectPixelRgba8(expected: [4]u8, surface: ReferenceRenderSurface, x: usize, y: usize) !void {
    try std.testing.expectEqualDeep(expected, surface.pixelRgba8(x, y));
}

fn expectVisiblePixel(pixel: [4]u8) !void {
    try std.testing.expect(pixel[3] > 0);
    try std.testing.expect(pixel[0] != 0 or pixel[1] != 0 or pixel[2] != 0);
}

fn referenceSurfaceSignature(pixels: []const u8) u64 {
    var hash: u64 = 14695981039346656037;
    for (pixels) |byte| {
        hash = (hash ^ byte) *% 1099511628211;
    }
    return hash;
}

fn expectLayoutFrame(layout: WidgetLayoutTree, id: ObjectId, expected: geometry.RectF) !void {
    const node = layout.findById(id) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualDeep(expected, node.frame);
}

fn expectRouteEntry(entry: WidgetEventRouteEntry, phase: WidgetEventPhase, id: ObjectId) !void {
    try std.testing.expectEqual(phase, entry.phase);
    try std.testing.expectEqual(id, entry.id);
}

fn expectFillColor(expected: Color, actual: Fill) !void {
    switch (actual) {
        .color => |color| try std.testing.expectEqualDeep(expected, color),
        else => return error.TestUnexpectedResult,
    }
}

fn expectGpuPaintColor(expected: Color, actual: CanvasGpuPaint) !void {
    switch (actual) {
        .color => |color| try std.testing.expectEqualDeep(expected, color),
        else => return error.TestUnexpectedResult,
    }
}
