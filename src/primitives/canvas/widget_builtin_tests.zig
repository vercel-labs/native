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

test "icon widgets render built-in vector icons as tinted path commands" {
    const icon = Widget{
        .id = 61,
        .kind = WidgetKind.icon,
        .frame = geometry.RectF.init(0, 0, 24, 24),
        .text = "check",
    };
    const tokens = DesignTokens{};
    var commands: [8]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, icon, tokens);
    const display_list = builder.displayList();
    // Transform in, one stroke per shape, inverse transform out.
    try std.testing.expectEqual(@as(usize, 3), display_list.commandCount());
    switch (display_list.findCommandById(widgetPartId(61, 2)).?.command) {
        .stroke_path => |stroke| {
            // Stroke width is in viewBox units (scaled by the wrapping
            // transform); currentColor resolves to the text token.
            try std.testing.expectEqual(@as(f32, 2), stroke.stroke.width);
            try expectFillColor(tokens.colors.text, stroke.stroke.fill);
            // The elements are the comptime-parsed registry storage:
            // zero per-frame geometry copies, static lifetime.
            const registered = canvas.icons.find("check").?;
            try std.testing.expectEqual(registered.elements.ptr, stroke.elements.ptr);
            // The authored linecap rides the command: the built-in set
            // declares round caps, so the emitted stroke carries them
            // instead of the wire default (butt).
            try std.testing.expectEqual(canvas.LineCap.round, stroke.cap);
        },
        else => return error.TestUnexpectedResult,
    }

    // The icon paints real ink through the reference renderer and is
    // byte-identical across runs.
    var render_commands: [4]RenderCommand = undefined;
    const plan = try (DisplayList{ .commands = display_list.commands }).renderPlan(&render_commands);
    var pixels: [24 * 24 * 4]u8 = undefined;
    @memset(&pixels, 0);
    const surface = try ReferenceRenderSurface.init(24, 24, &pixels);
    try surface.renderPass(.{
        .commands = plan.commands,
        .surface_size = geometry.SizeF.init(24, 24),
        .full_repaint = true,
    }, Color.rgb8(255, 255, 255));
    var ink: usize = 0;
    var index: usize = 0;
    while (index < pixels.len) : (index += 4) {
        if (pixels[index] < 250) ink += 1;
    }
    try std.testing.expect(ink > 20);
    // Regenerated when geometry edge coverage moved to linear-light
    // blending (the icon is a vector path): same coverage, smoother
    // fringe bytes.
    try std.testing.expectEqual(@as(u64, 5692773564953859754), support.referenceSurfaceSignature(&pixels));

    // A non-registry text keeps the historical glyph rendering.
    const glyph = Widget{
        .id = 62,
        .kind = WidgetKind.icon,
        .frame = geometry.RectF.init(0, 0, 24, 24),
        .text = "+",
    };
    var glyph_commands: [4]CanvasCommand = undefined;
    var glyph_builder = Builder.init(&glyph_commands);
    try emitWidgetTree(&glyph_builder, glyph, tokens);
    switch (glyph_builder.displayList().findCommandById(widgetPartId(62, 1)).?.command) {
        .draw_text => |text| try std.testing.expectEqualStrings("+", text.text),
        else => return error.TestUnexpectedResult,
    }
}

test "checkbox check mark strokes one anti-aliased vector path" {
    const checkbox = Widget{
        .id = 63,
        .kind = WidgetKind.checkbox,
        .frame = geometry.RectF.init(0, 0, 24, 24),
        .value = 1,
    };
    const tokens = DesignTokens{};
    var commands: [8]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, checkbox, tokens);
    const display_list = builder.displayList();
    // The mark is ONE stroked polyline through the vector core — move
    // plus two lines, round caps (and the vector core's round joins at
    // the vee vertex), the same rasterization the built-in stroke icons
    // get — not a pair of hard-edged line commands.
    switch (display_list.findCommandById(widgetPartId(63, 4)).?.command) {
        .stroke_path => |stroke| {
            try std.testing.expectEqual(@as(usize, 3), stroke.elements.len);
            try std.testing.expectEqual(PathVerb.move_to, stroke.elements[0].verb);
            try std.testing.expectEqual(PathVerb.line_to, stroke.elements[1].verb);
            try std.testing.expectEqual(PathVerb.line_to, stroke.elements[2].verb);
            try std.testing.expectEqual(@as(f32, 2), stroke.stroke.width);
            try std.testing.expectEqual(canvas.LineCap.round, stroke.cap);
        },
        else => return error.TestUnexpectedResult,
    }

    // Rasterized, the diagonal carries partial-coverage edge pixels —
    // anti-aliasing a binary point-in-capsule test can never produce —
    // and the whole render pins byte-identical.
    var render_commands: [8]RenderCommand = undefined;
    const plan = try (DisplayList{ .commands = display_list.commands }).renderPlan(&render_commands);
    var pixels: [24 * 24 * 4]u8 = undefined;
    @memset(&pixels, 0);
    const surface = try ReferenceRenderSurface.init(24, 24, &pixels);
    try surface.renderPass(.{
        .commands = plan.commands,
        .surface_size = geometry.SizeF.init(24, 24),
        .full_repaint = true,
    }, Color.rgb8(255, 255, 255));
    // Sample strictly inside the accent fill (the 16px box spans y 4-20;
    // stay clear of its border ring and corners) and count pixels that
    // blend between the dark fill and the light mark.
    var partial: usize = 0;
    var y: usize = 6;
    while (y < 18) : (y += 1) {
        var x: usize = 2;
        while (x < 14) : (x += 1) {
            const value = pixels[(y * 24 + x) * 4];
            if (value > 60 and value < 200) partial += 1;
        }
    }
    try std.testing.expect(partial >= 4);
    try std.testing.expectEqual(@as(u64, 10271374105851145327), support.referenceSurfaceSignature(&pixels));
}

test "a builder accumulating two widget trees keeps each checkbox mark's own geometry" {
    const tokens = DesignTokens{};
    const first = Widget{
        .id = 63,
        .kind = WidgetKind.checkbox,
        .frame = geometry.RectF.init(0, 0, 24, 24),
        .value = 1,
    };
    const second = Widget{
        .id = 64,
        .kind = WidgetKind.checkbox,
        .frame = geometry.RectF.init(40, 8, 48, 48),
        .value = 1,
    };

    // Snapshot the first mark's vertices from a solo emit, deep-copied
    // before any other emission runs.
    var solo_commands: [8]CanvasCommand = undefined;
    var solo_builder = Builder.init(&solo_commands);
    try emitWidgetTree(&solo_builder, first, tokens);
    var expected: [3]canvas.PathElement = undefined;
    switch (solo_builder.displayList().findCommandById(widgetPartId(63, 4)).?.command) {
        .stroke_path => |stroke| {
            try std.testing.expectEqual(@as(usize, 3), stroke.elements.len);
            @memcpy(&expected, stroke.elements[0..3]);
        },
        else => return error.TestUnexpectedResult,
    }

    // One builder accumulating two separately emitted trees: the first
    // tree's mark command must still describe the FIRST checkbox after
    // the second emit — its elements live in builder-owned storage, so
    // no later emission can overwrite them out from under the retained
    // display list.
    var commands: [16]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, first, tokens);
    try emitWidgetTree(&builder, second, tokens);
    switch (builder.displayList().findCommandById(widgetPartId(63, 4)).?.command) {
        .stroke_path => |stroke| {
            try std.testing.expectEqual(@as(usize, 3), stroke.elements.len);
            for (expected, stroke.elements) |expected_element, element| {
                try std.testing.expectEqual(expected_element.verb, element.verb);
                try std.testing.expectEqual(expected_element.points[0], element.points[0]);
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "app-registered icons draw through the widget paths like built-ins" {
    var buffer = canvas.svg_icon.IconBuffer{};
    const parsed = try canvas.svg_icon.parse(
        "<svg viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\"><line x1=\"4\" y1=\"12\" x2=\"20\" y2=\"12\"/></svg>",
        &buffer,
    );
    const app_table = [_]canvas.icons.Entry{.{ .name = "app-rule", .icon = &parsed }};
    canvas.icons.registerAppIcons(&app_table);
    defer canvas.icons.registerAppIcons(&.{});

    const tokens = DesignTokens{};
    const icon = Widget{
        .id = 65,
        .kind = WidgetKind.icon,
        .frame = geometry.RectF.init(0, 0, 24, 24),
        .text = "app-rule",
    };
    var commands: [8]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, icon, tokens);
    switch (builder.displayList().findCommandById(widgetPartId(65, 2)).?.command) {
        .stroke_path => |stroke| {
            try std.testing.expectEqual(parsed.elements.ptr, stroke.elements.ptr);
            try expectFillColor(tokens.colors.text, stroke.stroke.fill);
        },
        else => return error.TestUnexpectedResult,
    }

    // The same name renders inside a button via the icon channel.
    const button = Widget{
        .id = 66,
        .kind = WidgetKind.button,
        .frame = geometry.RectF.init(0, 0, 44, 34),
        .icon = "app-rule",
    };
    var button_commands: [8]CanvasCommand = undefined;
    var button_builder = Builder.init(&button_commands);
    try emitWidgetTree(&button_builder, button, tokens);
    switch (button_builder.displayList().findCommandById(widgetPartId(66, 6)).?.command) {
        .stroke_path => |stroke| try std.testing.expectEqual(parsed.elements.ptr, stroke.elements.ptr),
        else => return error.TestUnexpectedResult,
    }
}

test "an unresolved explicit icon name draws the missing-icon fallback, never a silent gap" {
    const tokens = DesignTokens{};
    // The explicit channel (`Widget.icon`) is where bound markup names
    // and app: references land; a name that resolves nowhere must stay
    // VISIBLE - the slashed-circle fallback draws where the icon would.
    const icon = Widget{
        .id = 71,
        .kind = WidgetKind.icon,
        .frame = geometry.RectF.init(0, 0, 24, 24),
        .icon = "sparkle-pony",
    };
    var commands: [8]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, icon, tokens);
    switch (builder.displayList().findCommandById(widgetPartId(71, 2)).?.command) {
        .stroke_path => |stroke| try std.testing.expectEqual(canvas.icons.missing_icon.elements.ptr, stroke.elements.ptr),
        else => return error.TestUnexpectedResult,
    }

    // Same honesty inside a button's inline icon slot.
    const button = Widget{
        .id = 72,
        .kind = WidgetKind.button,
        .frame = geometry.RectF.init(0, 0, 44, 34),
        .icon = "app:never-registered",
    };
    var button_commands: [8]CanvasCommand = undefined;
    var button_builder = Builder.init(&button_commands);
    try emitWidgetTree(&button_builder, button, tokens);
    switch (button_builder.displayList().findCommandById(widgetPartId(72, 6)).?.command) {
        .stroke_path => |stroke| try std.testing.expectEqual(canvas.icons.missing_icon.elements.ptr, stroke.elements.ptr),
        else => return error.TestUnexpectedResult,
    }
}

test "buttons draw an inline vector icon and label as one widget with one tint" {
    const tokens = DesignTokens{};
    const button = Widget{
        .id = 63,
        .kind = WidgetKind.button,
        .frame = geometry.RectF.init(0, 0, 120, 34),
        .text = "Save",
        .icon = "save",
    };
    var commands: [16]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, button, tokens);
    const display_list = builder.displayList();
    // Shadow + fill + border + transform-in + icon strokes +
    // transform-out + label.
    const label = switch (display_list.findCommandById(widgetPartId(63, 4)).?.command) {
        .draw_text => |text| text,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("Save", label.text);
    const icon_stroke = switch (display_list.findCommandById(widgetPartId(63, 6)).?.command) {
        .stroke_path => |stroke| stroke,
        else => return error.TestUnexpectedResult,
    };
    // Icon and label share the button's content tint, and the icon sits
    // before the label (the transform carries the placement; compare the
    // translation against the label origin).
    try expectFillColor(label.color, icon_stroke.stroke.fill);
    const registered = canvas.icons.find("save").?;
    try std.testing.expectEqual(registered.elements.ptr, icon_stroke.elements.ptr);

    // Disabled: BOTH the icon stroke and the label drop to the same
    // half-strength wash of the button's own ink — the whole control
    // fades as one piece, and the tint keeps tracking through the
    // disabled state (the tint-tracking cost of the old overlay idiom).
    var disabled = button;
    disabled.state.disabled = true;
    var disabled_commands: [16]CanvasCommand = undefined;
    var disabled_builder = Builder.init(&disabled_commands);
    try emitWidgetTree(&disabled_builder, disabled, tokens);
    const disabled_list = disabled_builder.displayList();
    const disabled_ink = Color.rgba(tokens.colors.text.r, tokens.colors.text.g, tokens.colors.text.b, 0.5);
    switch (disabled_list.findCommandById(widgetPartId(63, 4)).?.command) {
        .draw_text => |text| try std.testing.expectEqualDeep(disabled_ink, text.color),
        else => return error.TestUnexpectedResult,
    }
    switch (disabled_list.findCommandById(widgetPartId(63, 6)).?.command) {
        .stroke_path => |stroke| try expectFillColor(disabled_ink, stroke.stroke.fill),
        else => return error.TestUnexpectedResult,
    }

    // Icon-only (empty label): the icon centers in the button and no
    // label command is emitted.
    var icon_only = button;
    icon_only.text = "";
    var icon_only_commands: [16]CanvasCommand = undefined;
    var icon_only_builder = Builder.init(&icon_only_commands);
    try emitWidgetTree(&icon_only_builder, icon_only, tokens);
    const icon_only_list = icon_only_builder.displayList();
    try std.testing.expect(icon_only_list.findCommandById(widgetPartId(63, 4)) == null);
    try std.testing.expect(icon_only_list.findCommandById(widgetPartId(63, 6)) != null);
}

test "disabled filled buttons mute their border with the fill" {
    // A disabled primary button washes its fill to half strength; the
    // border must wash with it, in the SAME hue — a full-strength
    // accent edge over the washed fill read as a focus ring on every
    // idle disabled button (the "Comment button wearing an outline at
    // rest" regression), and the old neutral-gray border made the
    // faded fill look like a live secondary control. Destructive is
    // the quiet borderless chip, so its edge stays at width 0 in both
    // states — nothing to wash.
    const tokens = DesignTokens{};
    const button = Widget{
        .id = 71,
        .kind = WidgetKind.button,
        .frame = geometry.RectF.init(0, 0, 120, 34),
        .text = "Comment",
        .variant = .primary,
    };
    var commands: [8]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, button, tokens);
    switch (builder.displayList().findCommandById(widgetPartId(71, 2)).?.command) {
        .stroke_rect => |stroke| try expectFillColor(tokens.colors.accent, stroke.stroke.fill),
        else => return error.TestUnexpectedResult,
    }

    var disabled = button;
    disabled.state.disabled = true;
    var disabled_commands: [8]CanvasCommand = undefined;
    var disabled_builder = Builder.init(&disabled_commands);
    try emitWidgetTree(&disabled_builder, disabled, tokens);
    const washed_border = Color.rgba(tokens.colors.accent.r, tokens.colors.accent.g, tokens.colors.accent.b, 0.5 * tokens.colors.accent.a);
    switch (disabled_builder.displayList().findCommandById(widgetPartId(71, 2)).?.command) {
        .stroke_rect => |stroke| try expectFillColor(washed_border, stroke.stroke.fill),
        else => return error.TestUnexpectedResult,
    }

    // No focus ring on the idle disabled control either.
    try std.testing.expect(disabled_builder.displayList().findCommandById(widgetPartId(71, 3)) == null);

    var chip = button;
    chip.variant = .destructive;
    var chip_commands: [8]CanvasCommand = undefined;
    var chip_builder = Builder.init(&chip_commands);
    try emitWidgetTree(&chip_builder, chip, tokens);
    switch (chip_builder.displayList().findCommandById(widgetPartId(71, 2)).?.command) {
        .stroke_rect => |stroke| try std.testing.expectEqual(@as(f32, 0), stroke.stroke.width),
        else => return error.TestUnexpectedResult,
    }
}

/// The flush-group segment assertions, shared by the tree-walk and
/// layout-walk halves of the test below so the two emission paths are
/// pinned to the SAME bar: leading corners on the first segment,
/// squared middles, trailing corners on the last, and a border-band
/// clip (part slot 0) on every non-first segment — the seam-collapse
/// mechanism — while the first segment keeps its full unclipped border.
fn expectFlushButtonGroupSegments(display_list: anytype) !void {
    switch (display_list.findCommandById(widgetPartId(2, 1)).?.command) {
        .fill_rounded_rect => |fill| try std.testing.expectEqualDeep(Radius{ .top_left = 10, .bottom_left = 10 }, fill.radius),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.findCommandById(widgetPartId(3, 1)).?.command) {
        .fill_rounded_rect => |fill| try std.testing.expectEqualDeep(Radius{}, fill.radius),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.findCommandById(widgetPartId(4, 1)).?.command) {
        .fill_rounded_rect => |fill| try std.testing.expectEqualDeep(Radius{ .top_right = 10, .bottom_right = 10 }, fill.radius),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(display_list.findCommandById(widgetPartId(2, 0)) == null);
    switch (display_list.findCommandById(widgetPartId(3, 0)).?.command) {
        .push_clip => |clip| {
            // The clip's left edge sits half a stroke inside the
            // segment frame, excluding exactly the 1px border band the
            // left neighbor already painted.
            try std.testing.expectEqual(@as(f32, 80.5), clip.rect.x);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(display_list.findCommandById(widgetPartId(4, 0)) != null);
}

test "flush button groups collapse corners and interior seams in both render walks" {
    const tokens = DesignTokens{};
    const segments = [_]Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 80, 32), .text = "Cut", .variant = .outline },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(80, 0, 80, 32), .text = "Copy", .variant = .outline },
        .{ .id = 4, .kind = .button, .frame = geometry.RectF.init(160, 0, 80, 32), .text = "Paste", .variant = .outline },
    };
    const group = Widget{
        .id = 1,
        .kind = .button_group,
        .frame = geometry.RectF.init(0, 0, 240, 32),
        .children = &segments,
    };

    // Tree walk.
    var commands: [16]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, group, tokens);
    try expectFlushButtonGroupSegments(builder.displayList());

    // Layout walk — the segment stamp must land identically here or a
    // live app and a static docs scene would render different bars.
    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(group, group.frame, &nodes);
    var layout_commands: [16]CanvasCommand = undefined;
    var layout_builder = Builder.init(&layout_commands);
    try layout.emitDisplayList(&layout_builder, tokens);
    try expectFlushButtonGroupSegments(layout_builder.displayList());

    // A spaced group (gap > 0) is separate buttons by request: full
    // corners, full borders, no seam clips.
    var spaced = group;
    spaced.layout = .{ .gap = 8 };
    var spaced_commands: [16]CanvasCommand = undefined;
    var spaced_builder = Builder.init(&spaced_commands);
    try emitWidgetTree(&spaced_builder, spaced, tokens);
    const spaced_list = spaced_builder.displayList();
    switch (spaced_list.findCommandById(widgetPartId(2, 1)).?.command) {
        .fill_rounded_rect => |fill| try std.testing.expectEqualDeep(Radius.all(10), fill.radius),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(spaced_list.findCommandById(widgetPartId(3, 0)) == null);
    try std.testing.expect(spaced_list.findCommandById(widgetPartId(4, 0)) == null);
}

test "detached button groups render chip members with the group table and the metric gap" {
    // A detached-register token set with every channel stated, so the
    // assertions read the table straight back: rest wash, ink-inverted
    // selected fill under the knockout ink, full corners, no borders,
    // and the metric gap standing in for the author's gap-0.
    var tokens = DesignTokens{};
    tokens.controls.button_group_style = .detached;
    tokens.controls.button_group = .{
        .background = Color.rgba8(0, 0, 0, 20),
        .hover_background = Color.rgba8(0, 0, 0, 20),
        .active_background = Color.rgb8(23, 23, 23),
        .foreground = Color.rgb8(23, 23, 23),
        .active_foreground = Color.rgb8(255, 255, 255),
        .stroke_width = 0,
    };
    tokens.metrics.button_group_gap = 8;

    const segments = [_]Widget{
        .{ .id = 2, .kind = .button, .frame = geometry.RectF.init(0, 0, 80, 32), .text = "Albums", .state = .{ .selected = true } },
        .{ .id = 3, .kind = .button, .frame = geometry.RectF.init(80, 0, 80, 32), .text = "Songs" },
    };
    const group = Widget{
        .id = 1,
        .kind = .button_group,
        .frame = geometry.RectF.init(0, 0, 240, 32),
        .children = &segments,
    };

    // Tree walk: the selected member wears the ink-inverted fill, the
    // unselected member the rest wash, both on FULL corners with no
    // seam clips and no visible border.
    var commands: [16]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, group, tokens);
    const list = builder.displayList();
    switch (list.findCommandById(widgetPartId(2, 1)).?.command) {
        .fill_rounded_rect => |fill| {
            try expectFillColor(Color.rgb8(23, 23, 23), fill.fill);
            try std.testing.expectEqualDeep(Radius.all(10), fill.radius);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (list.findCommandById(widgetPartId(3, 1)).?.command) {
        .fill_rounded_rect => |fill| {
            try expectFillColor(Color.rgba8(0, 0, 0, 20), fill.fill);
            try std.testing.expectEqualDeep(Radius.all(10), fill.radius);
        },
        else => return error.TestUnexpectedResult,
    }
    // No seam clips anywhere: a chip has no shared boundary.
    try std.testing.expect(list.findCommandById(widgetPartId(2, 0)) == null);
    try std.testing.expect(list.findCommandById(widgetPartId(3, 0)) == null);
    // The chips are borderless: the border stroke carries zero width.
    switch (list.findCommandById(widgetPartId(2, 2)).?.command) {
        .stroke_rect => |stroke| try std.testing.expectEqual(@as(f32, 0), stroke.stroke.width),
        else => return error.TestUnexpectedResult,
    }
    // Knockout ink on the selected label, the stated rest ink elsewhere.
    switch (list.findCommandById(widgetPartId(2, 4)).?.command) {
        .draw_text => |text| try std.testing.expectEqualDeep(Color.rgb8(255, 255, 255), text.color),
        else => return error.TestUnexpectedResult,
    }
    switch (list.findCommandById(widgetPartId(3, 4)).?.command) {
        .draw_text => |text| try std.testing.expectEqualDeep(Color.rgb8(23, 23, 23), text.color),
        else => return error.TestUnexpectedResult,
    }

    // Layout walk: the same chips, and the metric gap separates the
    // members the author left at gap 0.
    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTreeWithTokens(group, group.frame, tokens, &nodes);
    try std.testing.expectEqual(@as(f32, 0), layout.nodes[1].frame.x);
    const second_x = layout.nodes[2].frame.x;
    const first_max_x = layout.nodes[1].frame.maxX();
    try std.testing.expectApproxEqAbs(@as(f32, 8), second_x - first_max_x, 0.001);
    var layout_commands: [16]CanvasCommand = undefined;
    var layout_builder = Builder.init(&layout_commands);
    try layout.emitDisplayList(&layout_builder, tokens);
    switch (layout_builder.displayList().findCommandById(widgetPartId(2, 1)).?.command) {
        .fill_rounded_rect => |fill| {
            try expectFillColor(Color.rgb8(23, 23, 23), fill.fill);
            try std.testing.expectEqualDeep(Radius.all(10), fill.radius);
        },
        else => return error.TestUnexpectedResult,
    }

    // An author-stated gap still wins over the metric.
    var spaced = group;
    spaced.layout = .{ .gap = 4 };
    var spaced_nodes: [4]WidgetLayoutNode = undefined;
    const spaced_layout = try layoutWidgetTreeWithTokens(spaced, spaced.frame, tokens, &spaced_nodes);
    try std.testing.expectApproxEqAbs(@as(f32, 4), spaced_layout.nodes[2].frame.x - spaced_layout.nodes[1].frame.maxX(), 0.001);
}

test "underline tab strips separate triggers by the tabs metric gap" {
    // The underline register's inter-trigger spacing: a strip whose
    // author left the gap at 0 flows its triggers `tabs_gap` apart, an
    // author-stated gap still wins over the metric, and the house pill
    // register (metric 0 by default) keeps its flush triggers.
    var tokens = DesignTokens{};
    tokens.controls.tabs_indicator = .underline;
    tokens.metrics.tabs_gap = 24;

    const triggers = [_]Widget{
        .{ .id = 2, .kind = .segmented_control, .frame = geometry.RectF.init(0, 0, 80, 32), .text = "One", .state = .{ .selected = true } },
        .{ .id = 3, .kind = .segmented_control, .frame = geometry.RectF.init(0, 0, 80, 32), .text = "Two" },
    };
    const strip = Widget{
        .id = 1,
        .kind = .tabs,
        .frame = geometry.RectF.init(0, 0, 240, 32),
        .children = &triggers,
    };
    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTreeWithTokens(strip, strip.frame, tokens, &nodes);
    try std.testing.expectEqual(@as(f32, 0), layout.nodes[1].frame.x);
    try std.testing.expectApproxEqAbs(@as(f32, 24), layout.nodes[2].frame.x - layout.nodes[1].frame.maxX(), 0.001);

    // An author-stated gap still wins over the metric.
    var spaced = strip;
    spaced.layout = .{ .gap = 4 };
    var spaced_nodes: [4]WidgetLayoutNode = undefined;
    const spaced_layout = try layoutWidgetTreeWithTokens(spaced, spaced.frame, tokens, &spaced_nodes);
    try std.testing.expectApproxEqAbs(@as(f32, 4), spaced_layout.nodes[2].frame.x - spaced_layout.nodes[1].frame.maxX(), 0.001);

    // The house pill register ignores the metric even when a token set
    // states one: gap-0 triggers stay flush inside the container wash.
    var pill_tokens = DesignTokens{};
    pill_tokens.metrics.tabs_gap = 24;
    var pill_nodes: [4]WidgetLayoutNode = undefined;
    const pill_layout = try layoutWidgetTreeWithTokens(strip, strip.frame, pill_tokens, &pill_nodes);
    try std.testing.expectApproxEqAbs(@as(f32, 0), pill_layout.nodes[2].frame.x - pill_layout.nodes[1].frame.maxX(), 0.001);
}

test "the bubble reaction pill straddles the bottom edge on the page plane" {
    const surfaces = @import("widget_render_surfaces.zig");
    const tokens = DesignTokens{};
    const message = [_]Widget{.{
        .id = 8,
        .kind = .text,
        .frame = geometry.RectF.init(12, 10, 176, 18),
        .text = "On my way",
    }};
    var bubble = Widget{
        .id = 7,
        .kind = .bubble,
        .frame = geometry.RectF.init(0, 0, 200, 38),
        .variant = .primary,
        .text = "+2",
        .text_alignment = .end,
        .children = &message,
    };

    // The pure geometry the emit and the damage outset share: the pill
    // hangs three quarters below the frame's bottom edge, docked 12
    // points in from the trailing edge (text_alignment end — the markup
    // default), never consuming layout space.
    const pill = surfaces.bubbleWidgetReactionsPillRect(bubble, tokens).?;
    try std.testing.expectApproxEqAbs(bubble.frame.maxY() - pill.height * 0.25, pill.y, 0.001);
    try std.testing.expectApproxEqAbs(bubble.frame.maxX() - 12, pill.maxX(), 0.001);
    // The capsule floor: a short run never collapses the pill narrower
    // than it is tall.
    try std.testing.expect(pill.width >= pill.height);
    bubble.text_alignment = .start;
    const leading = surfaces.bubbleWidgetReactionsPillRect(bubble, tokens).?;
    try std.testing.expectApproxEqAbs(bubble.frame.x + 12, leading.x, 0.001);
    bubble.text_alignment = .end;

    // Emitted chrome: the page-background ring behind (part 4), the
    // muted capsule (part 5), and the run in PLAIN foreground ink
    // (part 6) — the pill sits on the conversation plane, so a primary
    // bubble's knockout cascade never re-inks it.
    var commands: [10]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, bubble, tokens);
    const list = builder.displayList();
    switch (list.findCommandById(widgetPartId(7, 4)).?.command) {
        .fill_rounded_rect => |ring| try expectFillColor(tokens.colors.background, ring.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (list.findCommandById(widgetPartId(7, 5)).?.command) {
        .fill_rounded_rect => |fill| {
            try expectFillColor(tokens.colors.surface_subtle, fill.fill);
            // Capsule: the corner arc is half the pill's height.
            try std.testing.expectApproxEqAbs(fill.rect.height * 0.5, fill.radius.top_left, 0.001);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (list.findCommandById(widgetPartId(7, 6)).?.command) {
        .draw_text => |text| {
            try std.testing.expectEqualStrings("+2", text.text);
            try std.testing.expectEqualDeep(tokens.colors.text, text.color);
        },
        else => return error.TestUnexpectedResult,
    }

    // No run, no pill: a plain bubble keeps its classic command set.
    var plain = bubble;
    plain.text = "";
    var plain_commands: [10]CanvasCommand = undefined;
    var plain_builder = Builder.init(&plain_commands);
    try emitWidgetTree(&plain_builder, plain, tokens);
    try std.testing.expect(plain_builder.displayList().findCommandById(widgetPartId(7, 4)) == null);
    try std.testing.expect(plain_builder.displayList().findCommandById(widgetPartId(7, 5)) == null);
    try std.testing.expect(plain_builder.displayList().findCommandById(widgetPartId(7, 6)) == null);

    // The layout walk paints the same pill — a live app and a static
    // docs scene must render the same thread.
    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(bubble, bubble.frame, &nodes);
    var layout_commands: [10]CanvasCommand = undefined;
    var layout_builder = Builder.init(&layout_commands);
    try layout.emitDisplayList(&layout_builder, tokens);
    const layout_list = layout_builder.displayList();
    switch (layout_list.findCommandById(widgetPartId(7, 5)).?.command) {
        .fill_rounded_rect => |fill| try expectFillColor(tokens.colors.surface_subtle, fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (layout_list.findCommandById(widgetPartId(7, 6)).?.command) {
        .draw_text => |text| try std.testing.expectEqualDeep(tokens.colors.text, text.color),
        else => return error.TestUnexpectedResult,
    }
}

test "bubbles wear capsule chrome and re-ink their content by variant" {
    const tokens = DesignTokens{};
    const message = [_]Widget{.{
        .id = 8,
        .kind = .text,
        .frame = geometry.RectF.init(12, 10, 176, 18),
        .text = "On my way",
    }};
    const bubble = Widget{
        .id = 7,
        .kind = .bubble,
        .frame = geometry.RectF.init(0, 0, 200, 38),
        .children = &message,
    };

    // The received side (default variant): the muted wash in a capsule
    // arc — `radius.lg + 12` = 22, which closes a one-line bubble into
    // a full pill — with NO drop shadow (part 1) and NO hairline
    // (part 3): a bubble sits in the conversation plane, not above it.
    var commands: [8]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, bubble, tokens);
    const received_list = builder.displayList();
    switch (received_list.findCommandById(widgetPartId(7, 2)).?.command) {
        .fill_rounded_rect => |fill| {
            try std.testing.expectEqualDeep(Radius.all(22), fill.radius);
            try expectFillColor(tokens.colors.surface_subtle, fill.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(received_list.findCommandById(widgetPartId(7, 1)) == null);
    try std.testing.expect(received_list.findCommandById(widgetPartId(7, 3)) == null);

    // The sent side (primary): the monochrome accent fill, and the ink
    // cascade re-inks the message to the knockout foreground without
    // the author touching the child text.
    var sent = bubble;
    sent.variant = .primary;
    var sent_commands: [8]CanvasCommand = undefined;
    var sent_builder = Builder.init(&sent_commands);
    try emitWidgetTree(&sent_builder, sent, tokens);
    const sent_list = sent_builder.displayList();
    switch (sent_list.findCommandById(widgetPartId(7, 2)).?.command) {
        .fill_rounded_rect => |fill| try expectFillColor(tokens.colors.accent, fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (sent_list.findCommandById(widgetPartId(8, 1)).?.command) {
        .draw_text => |text| try std.testing.expectEqualDeep(tokens.colors.accent_text, text.color),
        else => return error.TestUnexpectedResult,
    }

    // Outline is the framed variant — the page fill plus the hairline —
    // and ghost is chromeless: content only, no fill, no stroke.
    var outline = bubble;
    outline.variant = .outline;
    var outline_commands: [8]CanvasCommand = undefined;
    var outline_builder = Builder.init(&outline_commands);
    try emitWidgetTree(&outline_builder, outline, tokens);
    const outline_list = outline_builder.displayList();
    switch (outline_list.findCommandById(widgetPartId(7, 2)).?.command) {
        .fill_rounded_rect => |fill| try expectFillColor(tokens.colors.background, fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (outline_list.findCommandById(widgetPartId(7, 3)).?.command) {
        .stroke_rect => |stroke| try expectFillColor(tokens.colors.border, stroke.stroke.fill),
        else => return error.TestUnexpectedResult,
    }
    var ghost = bubble;
    ghost.variant = .ghost;
    var ghost_commands: [8]CanvasCommand = undefined;
    var ghost_builder = Builder.init(&ghost_commands);
    try emitWidgetTree(&ghost_builder, ghost, tokens);
    try std.testing.expect(ghost_builder.displayList().findCommandById(widgetPartId(7, 2)) == null);
    try std.testing.expect(ghost_builder.displayList().findCommandById(widgetPartId(7, 3)) == null);

    // The layout walk stamps the same chrome AND the same ink cascade —
    // a live app and a static docs scene must render the same thread.
    var nodes: [4]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(sent, sent.frame, &nodes);
    var layout_commands: [8]CanvasCommand = undefined;
    var layout_builder = Builder.init(&layout_commands);
    try layout.emitDisplayList(&layout_builder, tokens);
    const layout_list = layout_builder.displayList();
    switch (layout_list.findCommandById(widgetPartId(7, 2)).?.command) {
        .fill_rounded_rect => |fill| {
            try std.testing.expectEqualDeep(Radius.all(22), fill.radius);
            try expectFillColor(tokens.colors.accent, fill.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (layout_list.findCommandById(widgetPartId(8, 1)).?.command) {
        .draw_text => |text| try std.testing.expectEqualDeep(tokens.colors.accent_text, text.color),
        else => return error.TestUnexpectedResult,
    }
}

test "list and menu items draw a leading vector icon with the label shifted right" {
    const tokens = DesignTokens{};
    const plain = Widget{
        .id = 70,
        .kind = WidgetKind.list_item,
        .frame = geometry.RectF.init(0, 0, 180, 32),
        .text = "Projects",
    };
    var plain_commands: [8]CanvasCommand = undefined;
    var plain_builder = Builder.init(&plain_commands);
    try emitWidgetTree(&plain_builder, plain, tokens);
    const plain_label = switch (plain_builder.displayList().findCommandById(widgetPartId(70, 3)).?.command) {
        .draw_text => |text| text,
        else => return error.TestUnexpectedResult,
    };

    var iconed = plain;
    iconed.icon = "folder";
    var commands: [16]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, iconed, tokens);
    const display_list = builder.displayList();
    const label = switch (display_list.findCommandById(widgetPartId(70, 3)).?.command) {
        .draw_text => |text| text,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("Projects", label.text);
    // The label shifts right to clear the leading icon slot.
    try std.testing.expect(label.origin.x > plain_label.origin.x);
    const icon_stroke = switch (display_list.findCommandById(widgetPartId(70, 5)).?.command) {
        .stroke_path => |stroke| stroke,
        else => return error.TestUnexpectedResult,
    };
    // Icon and label share the row's content tint.
    try expectFillColor(label.color, icon_stroke.stroke.fill);
    const registered = canvas.icons.find("folder").?;
    try std.testing.expectEqual(registered.elements.ptr, icon_stroke.elements.ptr);

    // menu_item keeps the same leading-icon slot contract even though
    // it draws with its own emitter (menu rows add the trailing
    // checkmark slot and drop the focus ring).
    var menu = iconed;
    menu.kind = WidgetKind.menu_item;
    menu.icon = "trash";
    var menu_commands: [16]CanvasCommand = undefined;
    var menu_builder = Builder.init(&menu_commands);
    try emitWidgetTree(&menu_builder, menu, tokens);
    try std.testing.expect(menu_builder.displayList().findCommandById(widgetPartId(70, 5)) != null);

    // Intrinsic row width grows by the shared icon metrics; height holds.
    const plain_size = canvas.intrinsicWidgetSize(plain, tokens);
    const iconed_size = canvas.intrinsicWidgetSize(iconed, tokens);
    try std.testing.expect(iconed_size.width > plain_size.width);
    try std.testing.expectEqual(plain_size.height, iconed_size.height);
}

test "menu rows wash the active row, never outline, and checkmark the committed row" {
    const tokens = DesignTokens{};
    const base = Widget{
        .id = 73,
        .kind = WidgetKind.menu_item,
        .frame = geometry.RectF.init(0, 0, 180, 32),
        .text = "Staging",
    };

    // An idle row is quiet: no wash, no outline, no checkmark.
    var idle_commands: [8]CanvasCommand = undefined;
    var idle_builder = Builder.init(&idle_commands);
    try emitWidgetTree(&idle_builder, base, tokens);
    try std.testing.expect(idle_builder.displayList().findCommandById(widgetPartId(73, 1)) == null);
    try std.testing.expect(idle_builder.displayList().findCommandById(widgetPartId(73, 2)) == null);
    try std.testing.expect(idle_builder.displayList().findCommandById(widgetPartId(73, 13)) == null);

    // The keyboard's active row paints the SAME full-row wash hover
    // uses — and deliberately NO focus-ring outline (slot 2 stays
    // empty; inside a menu the wash IS the keyboard affordance).
    var focused = base;
    focused.state.focused = true;
    var focused_commands: [8]CanvasCommand = undefined;
    var focused_builder = Builder.init(&focused_commands);
    try emitWidgetTree(&focused_builder, focused, tokens);
    const focused_wash = switch (focused_builder.displayList().findCommandById(widgetPartId(73, 1)).?.command) {
        .fill_rounded_rect => |fill| fill,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(focused_builder.displayList().findCommandById(widgetPartId(73, 2)) == null);
    var hovered = base;
    hovered.state.hovered = true;
    var hovered_commands: [8]CanvasCommand = undefined;
    var hovered_builder = Builder.init(&hovered_commands);
    try emitWidgetTree(&hovered_builder, hovered, tokens);
    const hovered_wash = switch (hovered_builder.displayList().findCommandById(widgetPartId(73, 1)).?.command) {
        .fill_rounded_rect => |fill| fill,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualDeep(hovered_wash.fill, focused_wash.fill);

    // The COMMITTED row wears the registry checkmark at the trailing
    // marker slot in the row's own content tint — and no wash: commit
    // and highlight are independent affordances.
    var committed = base;
    committed.state.selected = true;
    var committed_commands: [8]CanvasCommand = undefined;
    var committed_builder = Builder.init(&committed_commands);
    try emitWidgetTree(&committed_builder, committed, tokens);
    try std.testing.expect(committed_builder.displayList().findCommandById(widgetPartId(73, 1)) == null);
    const check_stroke = switch (committed_builder.displayList().findCommandById(widgetPartId(73, 13)).?.command) {
        .stroke_path => |stroke| stroke,
        else => return error.TestUnexpectedResult,
    };
    const check = canvas.icons.find("check").?;
    try std.testing.expectEqual(check.elements.ptr, check_stroke.elements.ptr);
    const label = switch (committed_builder.displayList().findCommandById(widgetPartId(73, 3)).?.command) {
        .draw_text => |text| text,
        else => return error.TestUnexpectedResult,
    };
    try expectFillColor(label.color, check_stroke.stroke.fill);

    // A row that is committed AND under the keyboard carries both: the
    // wash and the checkmark.
    var both = base;
    both.state.selected = true;
    both.state.focused = true;
    var both_commands: [8]CanvasCommand = undefined;
    var both_builder = Builder.init(&both_commands);
    try emitWidgetTree(&both_builder, both, tokens);
    try std.testing.expect(both_builder.displayList().findCommandById(widgetPartId(73, 1)) != null);
    try std.testing.expect(both_builder.displayList().findCommandById(widgetPartId(73, 13)) != null);
    try std.testing.expect(both_builder.displayList().findCommandById(widgetPartId(73, 2)) == null);
}

test "the quiet-surface knob silences the hover wash and nothing else" {
    // The quiet-tile doctrine: hover washes belong to acting controls;
    // on an image-forward content tile the pointer rests on content, so
    // hover paints nothing (the cursor is the affordance). The knob is
    // `WidgetStyle.quiet_hover`, and it must remove ONLY the hover fill
    // — the press wash (the visible moment of commitment) and the focus
    // ring stay.
    const tokens = DesignTokens{};
    const base = Widget{
        .id = 74,
        .kind = WidgetKind.list_item,
        .frame = geometry.RectF.init(0, 0, 160, 160),
        .style = .{ .quiet_hover = true },
    };

    // Hovered: no state fill at slot 1 — the row emitter skips the wash
    // rect entirely, exactly like a row at rest.
    var hovered = base;
    hovered.state.hovered = true;
    var hovered_commands: [8]CanvasCommand = undefined;
    var hovered_builder = Builder.init(&hovered_commands);
    try emitWidgetTree(&hovered_builder, hovered, tokens);
    try std.testing.expect(hovered_builder.displayList().findCommandById(widgetPartId(74, 1)) == null);

    // Control: the same hovered row WITHOUT the knob paints the muted
    // hover wash — proving the knob, not the setup, is what went quiet.
    var loud = hovered;
    loud.style.quiet_hover = false;
    var loud_commands: [8]CanvasCommand = undefined;
    var loud_builder = Builder.init(&loud_commands);
    try emitWidgetTree(&loud_builder, loud, tokens);
    const loud_wash = switch (loud_builder.displayList().findCommandById(widgetPartId(74, 1)).?.command) {
        .fill_rounded_rect => |fill| fill,
        else => return error.TestUnexpectedResult,
    };
    try expectFillColor(tokens.colors.surface_subtle, loud_wash.fill);

    // Pressed (even while still hovered): the pressed wash paints — the
    // knob never reaches the press channel.
    var pressed = base;
    pressed.state.hovered = true;
    pressed.state.pressed = true;
    var pressed_commands: [8]CanvasCommand = undefined;
    var pressed_builder = Builder.init(&pressed_commands);
    try emitWidgetTree(&pressed_builder, pressed, tokens);
    const pressed_wash = switch (pressed_builder.displayList().findCommandById(widgetPartId(74, 1)).?.command) {
        .fill_rounded_rect => |fill| fill,
        else => return error.TestUnexpectedResult,
    };
    try expectFillColor(tokens.colors.surface_pressed, pressed_wash.fill);

    // Focused: the standard focus ring still strokes at slot 2 — quiet
    // surfaces stay honest keyboard citizens.
    var focused = base;
    focused.state.focused = true;
    var focused_commands: [8]CanvasCommand = undefined;
    var focused_builder = Builder.init(&focused_commands);
    try emitWidgetTree(&focused_builder, focused, tokens);
    try std.testing.expect(focused_builder.displayList().findCommandById(widgetPartId(74, 2)) != null);
}

test "icon buttons draw registry names as vector icons and keep the glyph fallback" {
    const tokens = DesignTokens{};
    const vector = Widget{
        .id = 64,
        .kind = WidgetKind.icon_button,
        .frame = geometry.RectF.init(0, 0, 34, 34),
        .text = "play",
    };
    var commands: [12]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, vector, tokens);
    switch (builder.displayList().findCommandById(widgetPartId(64, 4)).?.command) {
        .stroke_path => |stroke| {
            const registered = canvas.icons.find("play").?;
            try std.testing.expectEqual(registered.elements.ptr, stroke.elements.ptr);
        },
        else => return error.TestUnexpectedResult,
    }

    // widget.icon works too (and wins over text).
    var by_field = vector;
    by_field.text = "";
    by_field.icon = "pause";
    var field_commands: [12]CanvasCommand = undefined;
    var field_builder = Builder.init(&field_commands);
    try emitWidgetTree(&field_builder, by_field, tokens);
    switch (field_builder.displayList().findCommandById(widgetPartId(64, 4)).?.command) {
        .stroke_path => |stroke| {
            const registered = canvas.icons.find("pause").?;
            try std.testing.expectEqual(registered.elements.ptr, stroke.elements.ptr);
        },
        else => return error.TestUnexpectedResult,
    }

    // Non-registry text keeps the historical glyph rendering.
    var glyph = vector;
    glyph.text = "+";
    var glyph_commands: [12]CanvasCommand = undefined;
    var glyph_builder = Builder.init(&glyph_commands);
    try emitWidgetTree(&glyph_builder, glyph, tokens);
    switch (glyph_builder.displayList().findCommandById(widgetPartId(64, 3)).?.command) {
        .draw_text => |text| try std.testing.expectEqualStrings("+", text.text),
        else => return error.TestUnexpectedResult,
    }
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
    // The default palette is the house neutral register (see
    // ColorTokens): near-black foreground, MONOCHROME near-black
    // primary, mid-gray ring.
    try std.testing.expectEqualDeep(Color.rgb8(10, 10, 10), light.colors.text);
    try std.testing.expectEqualDeep(Color.rgb8(23, 23, 23), light.colors.accent);
    try std.testing.expectEqualDeep(Color.rgb8(161, 161, 161), light.colors.focus_ring);

    const dark = DesignTokens.theme(.{ .color_scheme = .dark, .density = .compact });
    try std.testing.expectEqual(Density.compact, dark.density);
    try std.testing.expectEqualDeep(ColorTokens.dark(), dark.colors);
    try std.testing.expectEqualDeep(Color.rgb8(10, 10, 10), dark.colors.background);
    try std.testing.expectEqualDeep(Color.rgb8(250, 250, 250), dark.colors.text);
    // Dark hairlines are translucent white, not a gray fill.
    try std.testing.expectEqualDeep(Color.rgba8(255, 255, 255, 26), dark.colors.border);
    // The monochrome primary flips in dark: porcelain fill, near-black
    // accent text.
    try std.testing.expectEqualDeep(Color.rgb8(229, 229, 229), dark.colors.accent);
    try std.testing.expectEqualDeep(Color.rgb8(23, 23, 23), dark.colors.accent_text);
    try std.testing.expectEqualDeep(Color.rgb8(115, 115, 115), dark.colors.focus_ring);

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

test "built-in component catalog covers house component set" {
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
        try std.testing.expectEqual(BuiltinComponentStyle.house, descriptor.style);
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

test "built-in component factory creates house widget foundations" {
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

test "built-in component factory applies house composite defaults" {
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
    // house cards carry 24px of content padding (16 compact).
    try std.testing.expectEqual(@as(f32, 24), card.layout.padding.top);
    try std.testing.expectEqual(@as(f32, 24), card.layout.padding.right);
    try std.testing.expectEqual(@as(f32, 24), card.layout.padding.bottom);
    try std.testing.expectEqual(@as(f32, 24), card.layout.padding.left);
    try std.testing.expectEqual(@as(f32, 12), card.layout.gap);
    try std.testing.expectEqual(@as(f32, 16), builtinComponentWidget(.card, .{ .size = .sm }).layout.padding.top);
    try std.testing.expect(card.layout.clip_content);
    try std.testing.expectEqual(@as(usize, 2), card.children.len);

    const button_group = builtinComponentWidget(.button_group, .{});
    try std.testing.expectEqual(WidgetKind.button_group, button_group.kind);
    try std.testing.expectEqual(@as(f32, 4), button_group.layout.gap);
    try std.testing.expectEqual(WidgetCrossAlignment.center, button_group.layout.cross_alignment);

    const row_components = [_]BuiltinComponentKind{ .breadcrumb, .pagination, .radio_group, .toggle_group };
    const row_kinds = [_]WidgetKind{ .breadcrumb, .pagination, .radio_group, .toggle_group };
    // Pagination sits on the tighter 2px rhythm; the other strips keep 4.
    const row_gaps = [_]f32{ 4, 2, 4, 4 };
    for (row_components, row_kinds, row_gaps) |kind, widget_kind, gap| {
        const component = builtinComponentWidget(kind, .{});
        try std.testing.expectEqual(widget_kind, component.kind);
        try std.testing.expectEqual(gap, component.layout.gap);
        try std.testing.expectEqual(WidgetCrossAlignment.center, component.layout.cross_alignment);
        try std.testing.expectEqual(WidgetRole.group, component.semantics.role);
    }

    // The house TabsList: a muted rounded container hugging its
    // triggers with 3px of padding and no gap between them.
    const tabs = builtinComponentWidget(.tabs, .{});
    try std.testing.expectEqual(WidgetKind.tabs, tabs.kind);
    try std.testing.expectEqual(@as(f32, 3), tabs.layout.padding.top);
    try std.testing.expectEqual(@as(f32, 0), tabs.layout.gap);
    try std.testing.expectEqual(WidgetCrossAlignment.center, tabs.layout.cross_alignment);
    try std.testing.expectEqual(WidgetRole.group, tabs.semantics.role);

    const panel_components = [_]BuiltinComponentKind{ .accordion, .bubble, .resizable };
    const panel_kinds = [_]WidgetKind{ .accordion, .bubble, .resizable };
    for (panel_components, panel_kinds) |kind, widget_kind| {
        const component = builtinComponentWidget(kind, .{});
        try std.testing.expectEqual(widget_kind, component.kind);
        try std.testing.expect(component.layout.clip_content);
        try std.testing.expectEqual(WidgetRole.group, component.semantics.role);
    }
    // house accordion items are borderless rows: no built-in inset —
    // the chrome draws the trigger band and hairline separator.
    try std.testing.expectEqual(@as(f32, 0), builtinComponentWidget(.accordion, .{}).layout.padding.top);
    // the chat bubble hugs its message: 10px vertical / 12px horizontal,
    // so one body line closes into a capsule under the pill-arc chrome.
    try std.testing.expectEqual(@as(f32, 10), builtinComponentWidget(.bubble, .{}).layout.padding.top);
    try std.testing.expectEqual(@as(f32, 12), builtinComponentWidget(.bubble, .{}).layout.padding.left);

    // Defaults merge PER FIELD: an explicit gap wins for the gap alone
    // and the untouched padding keeps the house content inset — a custom
    // gap must not silently strip the card hug (nor a custom trigger gap
    // the TabsList hug, which leaves triggers flush against the
    // container's rounded corners).
    const custom_card = builtinComponentWidget(.card, .{
        .layout = .{ .gap = 24 },
    });
    try std.testing.expectEqual(@as(f32, 24), custom_card.layout.padding.top);
    try std.testing.expectEqual(@as(f32, 24), custom_card.layout.gap);
    const custom_tabs = builtinComponentWidget(.tabs, .{
        .layout = .{ .gap = 4 },
    });
    try std.testing.expectEqual(@as(f32, 3), custom_tabs.layout.padding.top);
    try std.testing.expectEqual(@as(f32, 4), custom_tabs.layout.gap);
    const padded_card = builtinComponentWidget(.card, .{
        .layout = .{ .padding = geometry.InsetsF.all(8) },
    });
    try std.testing.expectEqual(@as(f32, 8), padded_card.layout.padding.top);
    try std.testing.expectEqual(@as(f32, 12), padded_card.layout.gap);
    try std.testing.expect(padded_card.layout.clip_content);
}

test "built-in accordion renders house disclosure chrome and toggle semantics" {
    const accordion = builtinComponentWidget(.accordion, .{
        .id = 45,
        .frame = geometry.RectF.init(0, 0, 220, 64),
        .text = "Advanced options",
        .state = .{ .selected = true, .focused = true },
        .semantics = .{ .label = "Advanced options" },
    });

    var nodes: [1]WidgetLayoutNode = undefined;
    const layout = try layoutWidgetTree(accordion, accordion.frame, &nodes);
    // Accordion headers are controls: native arrow, never the link hand.
    try std.testing.expectEqual(WidgetCursor.arrow, layout.cursorForHit(layout.hitTest(geometry.PointF.init(12, 12))));
    try std.testing.expectEqual(WidgetCursor.arrow, cursorForWidgetTarget(.accordion, .{}));
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
    var commands: [12]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, accordion, tokens);
    const display_list = builder.displayList();
    // Background fill (themed token), hairline separator, trigger text,
    // the chevron-down icon (flip transform pair around the icon's own
    // transform pair plus its stroke path — the item is expanded), the
    // focus ring, and the content clip push/pop.
    try std.testing.expectEqual(@as(usize, 11), display_list.commandCount());
    switch (display_list.findCommandById(widgetPartId(45, 1)).?.command) {
        .fill_rounded_rect => |fill| try expectFillColor(Color.rgb8(14, 20, 26), fill.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.findCommandById(widgetPartId(45, 2)).?.command) {
        .draw_line => |line| {
            // The hairline separator on the item's bottom edge.
            try std.testing.expect(line.to.x > line.from.x);
            try std.testing.expectEqual(line.from.y, line.to.y);
            try std.testing.expectEqual(@as(f32, 64), line.from.y);
            try std.testing.expectEqual(@as(f32, 1.25), line.stroke.width);
            try expectFillColor(Color.rgb8(64, 74, 84), line.stroke.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.findCommandById(widgetPartId(45, 5)).?.command) {
        // The registry chevron-down: a stroke path, not text glyphs.
        .stroke_path => {},
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.findCommandById(widgetPartId(45, 6)).?.command) {
        .draw_text => |text| {
            try std.testing.expectEqualStrings("Advanced options", text.text);
            try std.testing.expectEqualDeep(Color.rgb8(230, 236, 242), text.color);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(display_list.findCommandById(widgetPartId(45, 7)) != null);
}

test "built-in resizable renders house resize grip and drag semantics" {
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
    // The disclosure contract: collapsed content still LAYS OUT — at
    // full size, ready for the runtime's disclosure tween to reveal it
    // without a single re-wrap — but stays concealed everywhere that
    // matters: semantics, hit testing, and the emitted display list
    // are indistinguishable from a content-less item.
    try std.testing.expectEqual(@as(usize, 2), collapsed_layout.nodeCount());
    const concealed_child = collapsed_layout.findById(46) orelse return error.TestUnexpectedResult;
    const concealed_probe = geometry.PointF.init(concealed_child.frame.x + 4, concealed_child.frame.y + 4);
    if (collapsed_layout.hitTest(concealed_probe)) |hit| {
        try std.testing.expect(hit.id != 46);
    }

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

test "built-in alert renders house surface chrome and text" {
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
    var commands: [12]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, alert, tokens);
    const display_list = builder.displayList();
    // Surface fill, hairline border, the info icon (transform pair
    // around three stroke paths), the title text, and the content clip
    // push/pop.
    try std.testing.expectEqual(@as(usize, 10), display_list.commandCount());
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
    switch (display_list.findCommandById(widgetPartId(40, 4)).?.command) {
        // The registry info icon: stroke paths, tinted like the text.
        .stroke_path => |path| try expectFillColor(Color.rgb8(235, 240, 245), path.stroke.fill),
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.findCommandById(widgetPartId(40, 10)).?.command) {
        .draw_text => |text| {
            try std.testing.expectEqualStrings("Heads up: this workflow is native-rendered.", text.text);
            try std.testing.expectEqualDeep(Color.rgb8(235, 240, 245), text.color);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "built-in card renders house surface chrome and title" {
    const card = builtinComponentWidget(.card, .{
        .id = 44,
        .frame = geometry.RectF.init(0, 0, 280, 120),
        .text = "Revenue pulse",
    });
    try std.testing.expectEqual(WidgetKind.card, card.kind);
    try std.testing.expectEqual(@as(f32, 24), card.layout.padding.top);
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

test "built-in modal surfaces render house chrome and semantics" {
    const viewport = geometry.RectF.init(0, 52, 1024, 640);
    const backdrop = builtinSurfaceBackdropWidget(.{
        .id = 49,
        .frame = viewport,
        .layer = 20,
    });
    try std.testing.expectEqual(WidgetKind.panel, backdrop.kind);
    try std.testing.expectEqual(@as(?i32, 20), backdrop.layer);
    // The backdrop is the dismiss hit target, not the dim: modal chrome
    // paints the scrim itself, so the default backdrop fill is fully
    // transparent.
    try std.testing.expectEqualDeep(Color.rgba8(0, 0, 0, 0), backdrop.style.background.?);
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
    var commands: [24]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, tokens);
    const display_list = builder.displayList();
    // 17 chrome/text/clip commands (the transparent backdrop casts no
    // drop shadow) plus the three modal scrims (a backdrop blur and a
    // wash fill per dialog/drawer/sheet).
    try std.testing.expectEqual(@as(usize, 23), display_list.commandCount());
    switch (display_list.findCommandById(widgetPartId(49, 2)).?.command) {
        .fill_rounded_rect => |fill| {
            try std.testing.expectEqualDeep(Radius.all(0), fill.radius);
            try expectFillColor(Color.rgba8(0, 0, 0, 0), fill.fill);
        },
        else => return error.TestUnexpectedResult,
    }
    // Each modal surface scrims the WHOLE root bounds: a real backdrop
    // blur of the already-painted content (slot 13), then the
    // translucent wash (slot 14) — token-driven from blur.scrim and
    // colors.scrim.
    const root_bounds = geometry.RectF.init(0, 0, 920, 240);
    for ([_]ObjectId{ 50, 51, 52 }) |surface_id| {
        switch (display_list.findCommandById(widgetPartId(surface_id, 13)).?.command) {
            .blur => |blur| {
                try std.testing.expectEqualDeep(root_bounds, blur.rect);
                try std.testing.expectEqual(@as(f32, 4), blur.radius);
            },
            else => return error.TestUnexpectedResult,
        }
        switch (display_list.findCommandById(widgetPartId(surface_id, 14)).?.command) {
            .fill_rect => |fill| {
                try std.testing.expectEqualDeep(root_bounds, fill.rect);
                try expectFillColor(Color.rgba8(0, 0, 0, 26), fill.fill);
            },
            else => return error.TestUnexpectedResult,
        }
    }
    // The backdrop panel (49) is not a modal surface: no scrim slots.
    try std.testing.expect(display_list.findCommandById(widgetPartId(49, 13)) == null);
    try std.testing.expect(display_list.findCommandById(widgetPartId(49, 14)) == null);
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

test "modal scrim is token-driven and never behind anchored surfaces" {
    // Anchored/floating surfaces are not modal: no scrim slots for the
    // popover, the menu surface, or the tooltip — only the dialog.
    const children = [_]Widget{
        .{ .id = 60, .kind = .popover, .frame = geometry.RectF.init(8, 8, 200, 120) },
        builtinComponentWidget(.dropdown_menu, .{ .id = 61, .frame = geometry.RectF.init(220, 8, 180, 140) }),
        builtinComponentWidget(.tooltip, .{ .id = 62, .frame = geometry.RectF.init(420, 8, 120, 32), .text = "Hint" }),
        builtinComponentWidget(.dialog, .{ .id = 63, .frame = geometry.RectF.init(200, 160, 240, 140) }),
    };
    const root = Widget{
        .id = 1,
        .kind = .stack,
        .frame = geometry.RectF.init(0, 0, 640, 360),
        .children = &children,
    };

    var commands: [24]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, root, .{});
    const display_list = builder.displayList();
    for ([_]ObjectId{ 60, 61, 62 }) |anchored_id| {
        try std.testing.expect(display_list.findCommandById(widgetPartId(anchored_id, 13)) == null);
        try std.testing.expect(display_list.findCommandById(widgetPartId(anchored_id, 14)) == null);
    }
    switch (display_list.findCommandById(widgetPartId(63, 13)).?.command) {
        .blur => |blur| {
            // The scrim blurs the whole tree the dialog covers, not just
            // the dialog frame.
            try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 640, 360), blur.rect);
            try std.testing.expectEqual(@as(f32, 4), blur.radius);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (display_list.findCommandById(widgetPartId(63, 14)).?.command) {
        .fill_rect => |fill| try expectFillColor(Color.rgba8(0, 0, 0, 26), fill.fill),
        else => return error.TestUnexpectedResult,
    }

    // Themes opt out per channel: zero blur leaves only the wash, and a
    // zero-alpha wash with zero blur removes the scrim entirely.
    const wash_only = DesignTokens{ .blur = .{ .scrim = 0 } };
    var wash_commands: [24]CanvasCommand = undefined;
    var wash_builder = Builder.init(&wash_commands);
    try emitWidgetTree(&wash_builder, root, wash_only);
    const wash_list = wash_builder.displayList();
    try std.testing.expect(wash_list.findCommandById(widgetPartId(63, 13)) == null);
    try std.testing.expect(wash_list.findCommandById(widgetPartId(63, 14)) != null);

    const no_scrim = DesignTokens{
        .colors = .{ .scrim = Color.rgba8(0, 0, 0, 0) },
        .blur = .{ .scrim = 0 },
    };
    var bare_commands: [24]CanvasCommand = undefined;
    var bare_builder = Builder.init(&bare_commands);
    try emitWidgetTree(&bare_builder, root, no_scrim);
    const bare_list = bare_builder.displayList();
    try std.testing.expect(bare_list.findCommandById(widgetPartId(63, 13)) == null);
    try std.testing.expect(bare_list.findCommandById(widgetPartId(63, 14)) == null);
}

test "built-in component widgets expose house semantics and render tokens" {
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
            .text = "native-sdk",
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
    try std.testing.expectEqualStrings("native-sdk", semantics[2].text_value);
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
    var commands: [5]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, button, .{});

    // Fill + border + label: the button register is flat, so the fill
    // leads its chrome directly.
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

test "built-in toggle renders house toggle button tokens" {
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

test "built-in component primitive widgets render distinct house chrome" {
    const widgets = [_]Widget{
        builtinComponentWidget(.avatar, .{
            .id = 20,
            .frame = geometry.RectF.init(0, 0, 40, 40),
            .text = "NS",
            .semantics = .{ .label = "Native SDK" },
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
    try std.testing.expectEqualStrings("Native SDK", semantics[0].label);
    try std.testing.expectEqual(WidgetRole.text, semantics[1].role);
    try std.testing.expectEqualStrings("Beta", semantics[1].label);
    try std.testing.expectEqual(WidgetRole.progressbar, semantics[2].role);

    var commands: [20]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try layout.emitDisplayList(&builder, .{});

    const display_list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 9), display_list.commandCount());
    try std.testing.expect(display_list.commands[0] == .fill_rounded_rect);
    switch (display_list.commands[1]) {
        .draw_text => |text| try std.testing.expectEqualStrings("NS", text.text),
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
    // The spinner (house arc register): ONE stroked arc in the page
    // ink — no track — with the stroke scaling at 1/12 of the box
    // (28px box -> 2.333px stroke).
    switch (display_list.commands[8]) {
        .stroke_path => |arc| {
            try expectFillColor(ColorTokens.light().text, arc.stroke.fill);
            try std.testing.expectApproxEqAbs(@as(f32, 28.0 * 2.0 / 24.0), arc.stroke.width, 0.001);
            // A 288-degree sweep needs four <=90-degree cubic segments
            // after the initial move.
            try std.testing.expectEqual(@as(usize, 5), arc.elements.len);
            // The measured reference arc ends in semicircles: the arc
            // register opts into round caps rather than inheriting the
            // wire default (butt).
            try std.testing.expectEqual(canvas.LineCap.round, arc.cap);
        },
        else => return error.TestUnexpectedResult,
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
            // The draw carries the pill radius itself: the render plan
            // flattens clip stacks to rects, so this mask is what rounds
            // the avatar image in every renderer.
            try std.testing.expectEqual(@as(f32, 20), image.radius.top_left);
            try std.testing.expectEqual(@as(f32, 20), image.radius.bottom_right);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(image_display_list.commands[3] == .pop_clip);
    try std.testing.expect(image_display_list.commands[4] == .stroke_rect);
}

test "spinner segmented register emits one pill per segment; the trail bakes only under reduced motion" {
    const spinner = builtinComponentWidget(.spinner, .{
        .id = 7,
        .frame = geometry.RectF.init(0, 0, 20, 20),
    });

    // Animated world: one fill_path pill per segment, each addressable
    // by its segment command id, every one at the dial ink's FULL
    // alpha — the live trail is the runtime's staggered opacity loops,
    // and those MULTIPLY emitted alpha, so a baked trail here would
    // double-darken under them.
    const tokens = DesignTokens.theme(.{ .pack = .geist });
    try std.testing.expectEqual(canvas.SpinnerStyleToken.segmented, tokens.metrics.spinner_style);
    const count = canvas.spinnerWidgetSegmentCount(tokens);
    try std.testing.expectEqual(@as(usize, 12), count);
    var commands: [16]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, spinner, tokens);
    const display_list = builder.displayList();
    try std.testing.expectEqual(count, display_list.commandCount());
    for (display_list.commands[0..count], 0..) |command, segment| {
        switch (command) {
            .fill_path => |pill| {
                try std.testing.expectEqual(canvas.spinnerWidgetSegmentCommandId(7, segment), pill.id);
                // The pack's dial ink: gray at full strength.
                try expectFillColor(tokens.controls.spinner.foreground.?, pill.fill);
                // A stadium: move, edge, two-cubic cap, edge, two-cubic
                // cap, close.
                try std.testing.expectEqual(@as(usize, 8), pill.elements.len);
            },
            else => return error.TestUnexpectedResult,
        }
    }

    // Reduced motion: the runtime never arms the loops, so the trail
    // must be baked — segment 0 (the head, twelve o'clock at value 0)
    // at full ink, its CLOCKWISE neighbor the oldest (dimmest), and
    // the counterclockwise neighbor barely faded.
    const still_tokens = DesignTokens.theme(.{ .pack = .geist, .reduce_motion = true });
    var still_commands: [16]CanvasCommand = undefined;
    var still_builder = Builder.init(&still_commands);
    try emitWidgetTree(&still_builder, spinner, still_tokens);
    const still_list = still_builder.displayList();
    try std.testing.expectEqual(count, still_list.commandCount());
    const tail = still_tokens.metrics.spinner_tail_opacity;
    const expected_alphas = [3]f32{
        1,
        1 - (1 - tail) * (11.0 / 12.0),
        1 - (1 - tail) * (1.0 / 12.0),
    };
    const probe_segments = [3]usize{ 0, 1, 11 };
    for (probe_segments, expected_alphas) |segment, expected_alpha| {
        switch (still_list.commands[segment]) {
            .fill_path => |pill| switch (pill.fill) {
                .color => |color| try std.testing.expectApproxEqAbs(expected_alpha, color.a, 0.001),
                else => return error.TestUnexpectedResult,
            },
            else => return error.TestUnexpectedResult,
        }
    }
}

test "avatar initials center on the circle: layout alignment is the ONE centering pass" {
    // The draw's origin must be the frame start — the `.center`
    // text_layout shifts the line inside `max_width`, and a pre-centered
    // origin stacked a second offset on top, parking the initials right
    // of the circle center (the docs preview regression).
    const avatar = support.builtinComponentWidget(.avatar, .{
        .id = 20,
        .frame = geometry.RectF.init(100, 60, 40, 40),
        .text = "ZN",
    });
    var commands: [4]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try support.emitWidgetTree(&builder, avatar, .{});

    const display_list = builder.displayList();
    const draw_text = switch (display_list.commands[1]) {
        .draw_text => |text| text,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(f32, 100), draw_text.origin.x);

    var lines: [2]support.TextLine = undefined;
    const layout = try support.layoutTextRun(draw_text, draw_text.text_layout.?, &lines);
    try std.testing.expectEqual(@as(usize, 1), layout.lines.len);
    const line = layout.lines[0];
    const ink_center = line.bounds.x + line.bounds.width / 2;
    const frame_center = avatar.frame.x + avatar.frame.width / 2;
    try std.testing.expectApproxEqAbs(frame_center, ink_center, 0.5);
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
            .overscroll = .rubber_band,
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
            .switch_control = .{
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
    try std.testing.expectEqual(canvas.ScrollOverscroll.rubber_band, tokens.scroll.overscroll);
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
    try std.testing.expectEqualDeep(Color.rgb8(50, 56, 64), tokens.controls.switch_control.background.?);
    try std.testing.expectEqualDeep(Color.rgb8(58, 72, 86), tokens.controls.switch_control.active_background.?);
    try std.testing.expectEqualDeep(Color.rgb8(252, 252, 253), tokens.controls.switch_control.foreground.?);
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
        // Default-size buttons draw the lg radius rung, so that is the
        // override that must flow through to the chrome.
        .radius = .{ .lg = 5 },
    });
    const button = Widget{
        .id = 42,
        .kind = .button,
        .frame = geometry.RectF.init(0, 0, 120, 36),
        .text = "Brand",
        .state = .{ .selected = true, .focused = true },
    };

    var commands: [5]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, button, tokens);
    // Fill + border + focus ring + label — the button register is flat.
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

    var commands: [5]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, button, tokens);
    // Fill + border + focus ring + label — the button register is flat.
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

test "widget text at intrinsic width does not wrap under geometry pixel snapping" {
    // Geometry snapping can shave up to half a device pixel off the frame
    // that intrinsic sizing measured; the text emitter hands the shaved
    // quantum back to the wrap budget so an exact-fit label ("Sort")
    // never breaks into "Sor"/"t". Regression for the snapped-frame wrap
    // seam surfaced when the estimator became the bundled face's real
    // advance table.
    const scales = [_]f32{ 1, 2 };
    for (scales) |scale| {
        const tokens = DesignTokens{ .pixel_snap = .{ .geometry = true, .text = true, .scale = scale } };
        var label = Widget{ .id = 7, .kind = .text, .text = "Sort" };
        label.size = .sm;
        const children = [_]Widget{ Widget{ .id = 2, .kind = .stack, .layout = .{ .grow = 1 } }, label };
        const row = Widget{ .id = 1, .kind = .row, .layout = .{ .gap = 10, .cross_alignment = .center }, .children = &children };

        var nodes: [4]WidgetLayoutNode = undefined;
        const layout = try canvas.layoutWidgetTreeWithTokens(row, geometry.RectF.init(0, 0, 400, 34), tokens, &nodes);

        var commands: [8]CanvasCommand = undefined;
        var builder = Builder.init(&commands);
        try canvas.emitWidgetLayout(&builder, layout, tokens);
        var seen = false;
        for (builder.displayList().commands) |command| switch (command) {
            .draw_text => |text| {
                seen = true;
                var lines: [4]TextLine = undefined;
                const text_layout = try canvas.layoutTextRun(text, text.text_layout.?, &lines);
                try std.testing.expectEqual(@as(usize, 1), text_layout.lineCount());
            },
            else => {},
        };
        try std.testing.expect(seen);
    }
}

test "label-exact controls at intrinsic width never elide under geometry pixel snapping" {
    // The elision twin of the wrap seam above: a control sized exactly
    // to its measured label sits at a fractional width, and render-time
    // geometry snapping can shave up to half a device pixel off that
    // frame — past the elision slack, so real glyphs swap for an
    // ellipsis (system monitor's "PID" sort chip painting "PI…").
    // Intrinsic measured-label widths now ceil to the snap grid
    // (`pixelSnapCeil` in widget_layout.zig), so the snapped frame is
    // never narrower than the label it was measured for. Sweep every
    // widget family that hugs a measured label and elides at its frame
    // edge, at both snap scales, across labels whose fractional widths
    // land on both sides of the rounding boundary.
    const kinds = [_]canvas.WidgetKind{
        .toggle_button, .button,   .toggle, .segmented_control,
        .menu_item,     .checkbox, .radio,  .switch_control,
        .tooltip,       .badge,    .list_item,
    };
    const labels = [_][]const u8{ "PID", "CPU", "Memory", "Name", "Filter processes", "Quarterly report" };
    const scales = [_]f32{ 1, 2 };
    for (scales) |scale| {
        const tokens = DesignTokens{ .pixel_snap = .{ .geometry = true, .text = true, .scale = scale } };
        for (kinds) |kind| for (labels) |label_text| {
            var label = Widget{ .id = 7, .kind = kind, .text = label_text };
            label.size = .sm;
            // The grow spacer pushes the hug-sized control to the right
            // edge, so the snapped left edge (not the fixed right one)
            // carries the fractional remainder — the shave that trips
            // the cliff.
            const children = [_]Widget{ Widget{ .id = 2, .kind = .stack, .layout = .{ .grow = 1 } }, label };
            const row = Widget{ .id = 1, .kind = .row, .layout = .{ .gap = 10, .cross_alignment = .center }, .children = &children };

            var nodes: [4]WidgetLayoutNode = undefined;
            const layout = try canvas.layoutWidgetTreeWithTokens(row, geometry.RectF.init(0, 0, 400, 40), tokens, &nodes);

            var commands: [16]CanvasCommand = undefined;
            var builder = Builder.init(&commands);
            try canvas.emitWidgetLayout(&builder, layout, tokens);
            var seen = false;
            for (builder.displayList().commands) |command| switch (command) {
                .draw_text => |text| {
                    seen = true;
                    var lines: [4]TextLine = undefined;
                    const text_layout = try canvas.layoutTextRun(text, text.text_layout.?, &lines);
                    for (text_layout.lines) |line| try std.testing.expect(!line.isElided());
                },
                else => {},
            };
            try std.testing.expect(seen);
        };
    }
}

test "geometry pixel snapping off keeps label-exact intrinsic widths bit-identical" {
    // The ceil-to-grid rule is gated on `pixel_snap.geometry`: themes
    // without geometry snapping have no snap shave to defend against,
    // and their intrinsic widths must stay the exact fractional
    // measurement — bit-identical layout, so no golden moves for
    // non-snapping themes.
    const off = DesignTokens{};
    const text_off = DesignTokens{ .pixel_snap = .{ .geometry = false, .text = true, .scale = 2 } };
    const kinds = [_]canvas.WidgetKind{ .toggle_button, .segmented_control, .menu_item, .checkbox, .tooltip, .badge };
    for (kinds) |kind| {
        var chip = Widget{ .id = 3, .kind = kind, .text = "Memory" };
        chip.size = .sm;
        const exact = canvas.intrinsicWidgetSize(chip, off);
        try std.testing.expectEqual(exact.width, canvas.intrinsicWidgetSize(chip, text_off).width);
        // A snapping theme may only ever widen, and by less than two
        // snap steps (one step per ceil; the menu row ceils its label
        // base and its check-reserve total separately).
        const snapped = canvas.intrinsicWidgetSize(chip, DesignTokens{ .pixel_snap = .{ .geometry = true, .text = true, .scale = 2 } });
        try std.testing.expect(snapped.width >= exact.width);
        try std.testing.expect(snapped.width - exact.width < 1.0);
    }
}

test "theme packs resolve by name and compose with every theme axis" {
    const DesignTokensT = canvas.DesignTokens;
    // Manifest-facing name resolution: known packs resolve, typos are
    // null so callers can raise a teaching error with the valid list.
    try std.testing.expectEqual(canvas.ThemePack.house, canvas.ThemePack.fromName("house").?);
    try std.testing.expectEqual(canvas.ThemePack.geist, canvas.ThemePack.fromName("geist").?);
    try std.testing.expectEqual(@as(?canvas.ThemePack, null), canvas.ThemePack.fromName("neon"));

    // The default pack IS the house register: ThemeOptions without a
    // pack must resolve byte-identically to before packs existed.
    const house = DesignTokensT.theme(.{});
    const house_explicit = DesignTokensT.theme(.{ .pack = .house });
    try std.testing.expectEqualDeep(house, house_explicit);

    // The pack changes the register while the scheme axis keeps
    // working through it: geist light and dark differ from house and
    // from each other, and the monochrome-primary identity flips with
    // the scheme exactly like the house register's does.
    const geist_light = DesignTokensT.theme(.{ .pack = .geist });
    const geist_dark = DesignTokensT.theme(.{ .pack = .geist, .color_scheme = .dark });
    try std.testing.expect(!std.meta.eql(geist_light.colors, house.colors));
    try std.testing.expect(!std.meta.eql(geist_light.colors, geist_dark.colors));
    try std.testing.expect(geist_light.colors.background.r > geist_dark.colors.background.r);

    // Scheme-independent axes apply on top of any pack: reduce_motion
    // zeroes the pack's motion register, density passes through.
    const geist_reduced = DesignTokensT.theme(.{ .pack = .geist, .reduce_motion = true, .density = .compact });
    try std.testing.expectEqual(@as(u32, 0), geist_reduced.motion.normal_ms);
    try std.testing.expectEqual(canvas.Density.compact, geist_reduced.density);

    // Overrides layer over a pack the same way they layer over the
    // house register.
    const overridden = DesignTokensT.themeWithOverrides(.{ .pack = .geist }, .{
        .metrics = .{ .control_height = 44 },
        .states = .{ .disabled_alpha = 0.4 },
    });
    try std.testing.expectEqual(@as(f32, 44), overridden.metrics.control_height);
    try std.testing.expectEqual(@as(f32, 0.4), overridden.states.disabled_alpha);
    // Fields the override left null keep the pack's values.
    try std.testing.expectEqual(geist_light.metrics.control_height_lg, overridden.metrics.control_height_lg);
}

test "hairline borders snap to whole device columns with smooth arcs" {
    const snapHairlineStrokeRect = @import("widget_render_style.zig").snapHairlineStrokeRect;
    const white = Color{ .r = 1, .g = 1, .b = 1, .a = 1 };

    // Inactive without the geometry token or a usable scale.
    const unsnapped: StrokeRect = .{ .rect = geometry.RectF.init(4, 3, 24, 14), .radius = Radius.all(6), .stroke = .{ .fill = .{ .color = white }, .width = 1 } };
    const off = DesignTokens{ .pixel_snap = .{ .geometry = false, .scale = 1 } };
    try std.testing.expectEqual(unsnapped.rect.x, snapHairlineStrokeRect(off, unsnapped).rect.x);

    // 1x: a 1px border pulls its centerline half a pixel inward so the
    // band covers exactly one column with its outer edge on the frame.
    const at_1x = DesignTokens{ .pixel_snap = .{ .geometry = true, .scale = 1 } };
    const snapped = snapHairlineStrokeRect(at_1x, unsnapped);
    try std.testing.expectEqual(@as(f32, 4.5), snapped.rect.x);
    try std.testing.expectEqual(@as(f32, 3.5), snapped.rect.y);
    try std.testing.expectEqual(@as(f32, 23), snapped.rect.width);
    try std.testing.expectEqual(@as(f32, 1), snapped.stroke.width);
    // The outer arc keeps the frame's radius: centerline radius shrinks
    // by the half-width inset.
    try std.testing.expectEqual(@as(f32, 5.5), snapped.radius.top_left);

    // Wider borders keep true geometry (device width above the
    // hairline range).
    const wide: StrokeRect = .{ .rect = geometry.RectF.init(4, 3, 24, 14), .radius = Radius.all(6), .stroke = .{ .fill = .{ .color = white }, .width = 3 } };
    try std.testing.expectEqual(@as(f32, 4), snapHairlineStrokeRect(at_1x, wide).rect.x);

    // Fractional scale: snapping happens on the DEVICE grid. At 1.25x a
    // 1px logical border snaps to one device pixel (0.8 logical) — the
    // floor of its exact 1.25-device width — and a frame edge at
    // logical 4 (device 5) pulls the centerline to device 5.5 =
    // logical 4.4.
    const at_fractional = DesignTokens{ .pixel_snap = .{ .geometry = true, .scale = 1.25 } };
    const fractional = snapHairlineStrokeRect(at_fractional, unsnapped);
    try std.testing.expectEqual(@as(f32, 4.4), fractional.rect.x);
    try std.testing.expectEqual(@as(f32, 0.8), fractional.stroke.width);

    // At 1.5x the exact device width of a 1px logical border is 1.5 —
    // between grid widths — and the snap takes the FLOOR: one device
    // column (2/3 logical), the crisp-and-light choice, never two. The
    // frame edge at logical 4 (device 6) pulls the centerline to
    // device 6.5.
    const at_halfstep = DesignTokens{ .pixel_snap = .{ .geometry = true, .scale = 1.5 } };
    const halfstep = snapHairlineStrokeRect(at_halfstep, unsnapped);
    try std.testing.expectEqual(@as(f32, 6.5 / 1.5), halfstep.rect.x);
    try std.testing.expectEqual(@as(f32, 1.0 / 1.5), halfstep.stroke.width);

    // A stroke whose device width rounds to zero stays unsnapped — the
    // floor's one-pixel minimum never darkens a sub-half-pixel stroke.
    var whisper = unsnapped;
    whisper.stroke.width = 0.25;
    try std.testing.expectEqual(@as(f32, 0.25), snapHairlineStrokeRect(at_halfstep, whisper).stroke.width);
    try std.testing.expectEqual(unsnapped.rect.x, snapHairlineStrokeRect(at_halfstep, whisper).rect.x);

    // Rendered at 1x, the straight runs land as exactly one full-alpha
    // column inside the frame — no half-covered neighbors — while the
    // corners keep fractional arc coverage from the continuous field.
    var pixels: [40 * 24 * 4]u8 = undefined;
    const surface = try ReferenceRenderSurface.init(40, 24, &pixels);
    const bounds = geometry.RectF.init(0, 0, 40, 24);
    const command = RenderCommand{
        .command = .{ .stroke_rect = snapped },
        .local_bounds = bounds,
        .bounds = bounds,
    };
    try surface.renderPass(.{
        .surface_size = geometry.SizeF.init(40, 24),
        .scale = 1,
        .full_repaint = true,
        .commands = &.{command},
    }, Color{ .r = 0, .g = 0, .b = 0, .a = 0 });
    // Mid-height row: outside column empty, frame column fully inked,
    // next column inside empty again.
    try std.testing.expectEqual(@as(u8, 0), surface.pixelRgba8(3, 10)[3]);
    try std.testing.expectEqual(@as(u8, 255), surface.pixelRgba8(4, 10)[3]);
    try std.testing.expectEqual(@as(u8, 0), surface.pixelRgba8(5, 10)[3]);
    // Mid-width column: same on the top run.
    try std.testing.expectEqual(@as(u8, 0), surface.pixelRgba8(16, 2)[3]);
    try std.testing.expectEqual(@as(u8, 255), surface.pixelRgba8(16, 3)[3]);
    try std.testing.expectEqual(@as(u8, 0), surface.pixelRgba8(16, 4)[3]);
    // Corner pixels carry fractional arc coverage — smooth, not binary.
    const corner = surface.pixelRgba8(5, 4)[3];
    try std.testing.expect(corner > 0 and corner < 255);
}

test "single-line fields clip and horizontally scroll an overflowing value" {
    const long_text = "a value far too long for a narrow single-line field to show at once";
    const field = Widget{
        .id = 7,
        .kind = .text_field,
        .frame = geometry.RectF.init(10, 12, 120, 32),
        .text = long_text,
        .text_selection = TextSelection.collapsed(long_text.len),
        .state = .{ .focused = true },
        .semantics = .{ .label = "Name" },
        // The retained offset channel: an oversized write clamps to the
        // farthest the value can scroll, exactly like the textarea's
        // vertical offset does.
        .value = 100000,
    };
    const max_offset = support.textInputMaxHorizontalScrollOffsetForWidget(field, .{});
    try std.testing.expect(max_offset > 0);
    try std.testing.expectEqual(max_offset, support.clampedTextInputHorizontalScrollOffsetForWidget(field, .{}, 100000));

    var zero_offset_field = field;
    zero_offset_field.value = 0;

    var commands: [8]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, field, .{});
    const display_list = builder.displayList();
    var zero_commands: [8]CanvasCommand = undefined;
    var zero_builder = Builder.init(&zero_commands);
    try emitWidgetTree(&zero_builder, zero_offset_field, .{});
    const zero_display_list = zero_builder.displayList();

    // Fill, border, offset focus ring, clip, text, caret, pop.
    try std.testing.expectEqual(@as(usize, 7), display_list.commandCount());
    const viewport = textInputViewportForWidget(field, .{}).?;
    switch (display_list.commands[3]) {
        .push_clip => |clip| {
            try std.testing.expectEqual(widgetPartId(7, 16), clip.id);
            try expectRectApprox(viewport, clip.rect);
        },
        else => return error.TestUnexpectedResult,
    }
    // The draw-text origin shifts left by exactly the clamped offset.
    const scrolled_origin = switch (display_list.commands[4]) {
        .draw_text => |text| text.origin,
        else => return error.TestUnexpectedResult,
    };
    const resting_origin = switch (zero_display_list.commands[4]) {
        .draw_text => |text| text.origin,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectApproxEqAbs(resting_origin.x - max_offset, scrolled_origin.x, 0.001);
    try std.testing.expectEqual(resting_origin.y, scrolled_origin.y);
    // The end-of-value caret rides the same origin, landing inside the
    // clip instead of past the field's border.
    switch (display_list.commands[5]) {
        .fill_rect => |caret| {
            try std.testing.expect(caret.rect.x >= viewport.x - 0.001);
            try std.testing.expect(caret.rect.maxX() <= viewport.maxX() + 0.001);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(CanvasCommand.pop_clip, display_list.commands[6]);
}

test "the caret keep-visible offset scrolls to the caret and returns home" {
    const long_text = "a value far too long for a narrow single-line field to show at once";
    var field = Widget{
        .id = 7,
        .kind = .text_field,
        .frame = geometry.RectF.init(10, 12, 120, 32),
        .text = long_text,
        .text_selection = TextSelection.collapsed(long_text.len),
        .state = .{ .focused = true },
        .semantics = .{ .label = "Name" },
    };
    const max_offset = support.textInputMaxHorizontalScrollOffsetForWidget(field, .{});
    try std.testing.expect(max_offset > 0);

    // Caret at the end, unscrolled: the recompute scrolls forward far
    // enough that the caret sits inside the visible span.
    const end_offset = support.textInputCaretVisibleScrollOffsetForWidget(field, .{}, 0);
    try std.testing.expect(end_offset > 0);
    try std.testing.expect(end_offset <= max_offset + 0.001);
    field.value = end_offset;
    const viewport = textInputViewportForWidget(field, .{}).?;
    const end_geometry = textGeometryForWidget(field, .{});
    const end_caret = end_geometry.caret_bounds.?;
    try std.testing.expect(end_caret.x >= viewport.x - 0.001);
    try std.testing.expect(end_caret.maxX() <= viewport.maxX() + 0.001);

    // Home: caret back at byte zero scrolls all the way back — the field
    // never shows trailing emptiness while text could fill it.
    field.text_selection = TextSelection.collapsed(0);
    try std.testing.expectEqual(@as(f32, 0), support.textInputCaretVisibleScrollOffsetForWidget(field, .{}, end_offset));

    // A value that fits never scrolls and never adjusts.
    var short = field;
    short.text = "short";
    short.text_selection = TextSelection.collapsed(5);
    try std.testing.expectEqual(@as(f32, 0), support.textInputMaxHorizontalScrollOffsetForWidget(short, .{}));
    try std.testing.expectEqual(@as(f32, 0), support.textInputCaretVisibleScrollOffsetForWidget(short, .{}, 25));
}

test "scrolled single-line selection rects shift with the text origin" {
    const long_text = "a value far too long for a narrow single-line field to show at once";
    const scrolled = Widget{
        .id = 7,
        .kind = .text_field,
        .frame = geometry.RectF.init(10, 12, 120, 32),
        .text = long_text,
        .text_selection = .{ .anchor = 2, .focus = 9 },
        .state = .{ .focused = true },
        .semantics = .{ .label = "Name" },
        .value = 20,
    };
    var resting = scrolled;
    resting.value = 0;

    var commands: [10]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, scrolled, .{});
    const display_list = builder.displayList();
    var resting_commands: [10]CanvasCommand = undefined;
    var resting_builder = Builder.init(&resting_commands);
    try emitWidgetTree(&resting_builder, resting, .{});
    const resting_display_list = resting_builder.displayList();

    // Fill, border, focus ring, clip, selection rect, text, selected
    // glyphs, pop — the same shape at both offsets.
    try std.testing.expectEqual(display_list.commandCount(), resting_display_list.commandCount());
    const scrolled_selection = switch (display_list.commands[4]) {
        .fill_rect => |rect| rect.rect,
        else => return error.TestUnexpectedResult,
    };
    const resting_selection = switch (resting_display_list.commands[4]) {
        .fill_rect => |rect| rect.rect,
        else => return error.TestUnexpectedResult,
    };
    const scrolled_text = switch (display_list.commands[5]) {
        .draw_text => |text| text.origin,
        else => return error.TestUnexpectedResult,
    };
    const resting_text = switch (resting_display_list.commands[5]) {
        .draw_text => |text| text.origin,
        else => return error.TestUnexpectedResult,
    };
    // Selection geometry and the draw-text origin move together, by
    // exactly the scroll offset.
    try std.testing.expectApproxEqAbs(@as(f32, 20), resting_selection.x - scrolled_selection.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 20), resting_text.x - scrolled_text.x, 0.001);
    try std.testing.expectApproxEqAbs(resting_selection.width, scrolled_selection.width, 0.001);
}

test "short single-line values emit no clip and an unshifted origin" {
    const field = Widget{
        .id = 7,
        .kind = .text_field,
        .frame = geometry.RectF.init(10, 12, 120, 32),
        .text = "short",
        .text_selection = TextSelection.collapsed(5),
        .state = .{ .focused = true },
        .semantics = .{ .label = "Name" },
        // A stale offset on a value that fits clamps to zero: fitting
        // fields render exactly as they did before fields scrolled.
        .value = 40,
    };
    var commands: [8]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, field, .{});
    const display_list = builder.displayList();
    // Fill, border, offset focus ring, text, caret — no clip pair.
    try std.testing.expectEqual(@as(usize, 5), display_list.commandCount());
    for (display_list.commands) |command| {
        try std.testing.expect(command != .push_clip and command != .pop_clip);
    }
    var zero = field;
    zero.value = 0;
    var zero_commands: [8]CanvasCommand = undefined;
    var zero_builder = Builder.init(&zero_commands);
    try emitWidgetTree(&zero_builder, zero, .{});
    const zero_display_list = zero_builder.displayList();
    switch (display_list.commands[3]) {
        .draw_text => |text| {
            try std.testing.expectEqual(switch (zero_display_list.commands[3]) {
                .draw_text => |zero_text| zero_text.origin.x,
                else => return error.TestUnexpectedResult,
            }, text.origin.x);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "search fields clip an overflowing value and keep chrome outside the clip" {
    const long_text = "an overflowing search query that runs past the narrow field";
    const field = Widget{
        .id = 9,
        .kind = .search_field,
        .frame = geometry.RectF.init(10, 12, 140, 32),
        .text = long_text,
        .text_selection = TextSelection.collapsed(long_text.len),
        .state = .{ .focused = true },
        .semantics = .{ .label = "Search" },
        .value = 100000,
    };
    try std.testing.expect(support.textInputMaxHorizontalScrollOffsetForWidget(field, .{}) > 0);

    var commands: [24]CanvasCommand = undefined;
    var builder = Builder.init(&commands);
    try emitWidgetTree(&builder, field, .{});
    const display_list = builder.displayList();

    var clip_index: ?usize = null;
    var pop_index: ?usize = null;
    var text_index: ?usize = null;
    var caret_index: ?usize = null;
    var clear_transform_index: ?usize = null;
    for (display_list.commands, 0..) |command, index| {
        switch (command) {
            .push_clip => |clip| {
                try std.testing.expectEqual(widgetPartId(9, 7), clip.id);
                try expectRectApprox(textInputViewportForWidget(field, .{}).?, clip.rect);
                clip_index = index;
            },
            .pop_clip => pop_index = index,
            .draw_text => |text| {
                if (text.id == widgetPartId(9, 9)) text_index = index;
            },
            .fill_rect => |caret| {
                if (caret.id == widgetPartId(9, 11)) caret_index = index;
            },
            .transform => {
                if (clear_transform_index == null and pop_index != null) clear_transform_index = index;
            },
            else => {},
        }
    }
    // Text and caret sit inside the clip pair; the trailing clear
    // affordance draws after the pop, outside it.
    try std.testing.expect(clip_index.? < text_index.?);
    try std.testing.expect(text_index.? < caret_index.?);
    try std.testing.expect(caret_index.? < pop_index.?);
    try std.testing.expect(pop_index.? < clear_transform_index.?);
}
