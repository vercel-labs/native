const std = @import("std");
const command_model = @import("commands.zig");
const drawing_model = @import("drawing.zig");
const text_model = @import("text.zig");
const render_model = @import("render.zig");
const frame_model = @import("frame.zig");
const reference_model = @import("reference.zig");
const gpu_model = @import("gpu.zig");
const token_model = @import("tokens.zig");
const widget_model = @import("widgets.zig");
const widget_runtime = @import("widget_runtime.zig");
const event_model = @import("events.zig");
const serialization = @import("serialization.zig");

pub const Error = error{
    DisplayListFull,
    DiffListFull,
    DuplicateObjectId,
    DuplicateWidgetId,
    GlyphAtlasCacheListFull,
    GlyphAtlasListFull,
    ImageCacheListFull,
    ImageListFull,
    LayerCacheListFull,
    LayerListFull,
    PathGeometryCacheListFull,
    PathGeometryListFull,
    RenderBatchListFull,
    RenderListFull,
    RenderOverrideListFull,
    RenderPipelineCacheListFull,
    RenderResourceCacheListFull,
    RenderResourceListFull,
    TextLayoutCacheListFull,
    TextLayoutLineListFull,
    TextLayoutPlanListFull,
    TextSelectionRectListFull,
    VisualEffectCacheListFull,
    VisualEffectListFull,
    TextEditBufferTooSmall,
    ReferenceRenderSurfaceTooSmall,
    ReferenceRenderUnsupportedCommand,
    RenderEncoderListFull,
    CanvasGpuCommandListFull,
    RenderStackOverflow,
    RenderStackUnderflow,
    InvalidTransform,
    WidgetDepthExceeded,
    WidgetEventRouteListFull,
    WidgetInvalidationListFull,
    WidgetLayoutListFull,
    WidgetSemanticsListFull,
};

pub const ObjectId = u64;
pub const ImageId = u64;
pub const FontId = u64;

pub const default_sans_font_id: FontId = 1;
pub const default_mono_font_id: FontId = 2;
pub const default_sans_font_family = FontFamily.geist;
pub const default_mono_font_family = FontFamily.geist_mono;

pub const default_glyph_atlas_cache_retention_frames: u64 = 120;
pub const default_text_layout_cache_retention_frames: u64 = 120;

// Canvas drawing primitives live in `drawing.zig`; root keeps the public API stable.
pub const Color = drawing_model.Color;
pub const Affine = drawing_model.Affine;
pub const Radius = drawing_model.Radius;
pub const GradientStop = drawing_model.GradientStop;
pub const LinearGradient = drawing_model.LinearGradient;
pub const Fill = drawing_model.Fill;
pub const Stroke = drawing_model.Stroke;
pub const Clip = drawing_model.Clip;
pub const FillRect = drawing_model.FillRect;
pub const StrokeRect = drawing_model.StrokeRect;
pub const FillRoundedRect = drawing_model.FillRoundedRect;
pub const Line = drawing_model.Line;
pub const PathVerb = drawing_model.PathVerb;
pub const PathElement = drawing_model.PathElement;
pub const FillPath = drawing_model.FillPath;
pub const StrokePath = drawing_model.StrokePath;
pub const ImageFit = drawing_model.ImageFit;
pub const ImageSampling = drawing_model.ImageSampling;
pub const DrawImage = drawing_model.DrawImage;
pub const Shadow = drawing_model.Shadow;
pub const Blur = drawing_model.Blur;

// Canvas text data lives in `text.zig`; root keeps the public API stable.
pub const Glyph = text_model.Glyph;
pub const GlyphAtlasKey = text_model.GlyphAtlasKey;
pub const GlyphAtlasEntry = text_model.GlyphAtlasEntry;
pub const GlyphAtlasPlan = text_model.GlyphAtlasPlan;
pub const GlyphAtlasPlanner = text_model.GlyphAtlasPlanner;
pub const GlyphAtlasCacheEntry = text_model.GlyphAtlasCacheEntry;
pub const GlyphAtlasCacheActionKind = text_model.GlyphAtlasCacheActionKind;
pub const GlyphAtlasCacheAction = text_model.GlyphAtlasCacheAction;
pub const GlyphAtlasCachePlan = text_model.GlyphAtlasCachePlan;
pub const GlyphAtlasCachePlanner = text_model.GlyphAtlasCachePlanner;
pub const DrawText = text_model.DrawText;
pub const TextWrap = text_model.TextWrap;
pub const TextAlign = text_model.TextAlign;
pub const TextLayoutOptions = text_model.TextLayoutOptions;
pub const TextLine = text_model.TextLine;
pub const TextLayout = text_model.TextLayout;
pub const TextLayoutKey = text_model.TextLayoutKey;
pub const TextLayoutPlan = text_model.TextLayoutPlan;
pub const TextLayoutPlanSet = text_model.TextLayoutPlanSet;
pub const TextLayoutPlanner = text_model.TextLayoutPlanner;
pub const TextLayoutCacheEntry = text_model.TextLayoutCacheEntry;
pub const TextLayoutCacheActionKind = text_model.TextLayoutCacheActionKind;
pub const TextLayoutCacheAction = text_model.TextLayoutCacheAction;
pub const TextLayoutCachePlan = text_model.TextLayoutCachePlan;
pub const TextLayoutCachePlanner = text_model.TextLayoutCachePlanner;
pub const TextRange = text_model.TextRange;
pub const TextSelectionRect = text_model.TextSelectionRect;
pub const TextSelection = text_model.TextSelection;
pub const TextCaretDirection = text_model.TextCaretDirection;
pub const TextCaretMove = text_model.TextCaretMove;
pub const TextCompositionUpdate = text_model.TextCompositionUpdate;
pub const TextInputEvent = text_model.TextInputEvent;
pub const TextEditState = text_model.TextEditState;

pub const CanvasCommand = command_model.CanvasCommand;
pub const CommandRef = command_model.CommandRef;
pub const DiffKind = command_model.DiffKind;
pub const DiffChange = command_model.DiffChange;
pub const Builder = command_model.Builder;

// Canvas render data and cache plans live in `render.zig`; root keeps the public API stable.
pub const max_render_state_stack = render_model.max_render_state_stack;
pub const RenderState = render_model.RenderState;
pub const RenderCommand = render_model.RenderCommand;
pub const CanvasRenderOverride = render_model.CanvasRenderOverride;
pub const CanvasRenderAnimation = render_model.CanvasRenderAnimation;
pub const applyRenderOverrides = render_model.applyRenderOverrides;
pub const renderOverrideDirtyBounds = render_model.renderOverrideDirtyBounds;
pub const RenderPlan = render_model.RenderPlan;
pub const RenderPlanner = render_model.RenderPlanner;
pub const RenderPipelineKind = render_model.RenderPipelineKind;
pub const RenderBatch = render_model.RenderBatch;
pub const RenderBatchPlanner = render_model.RenderBatchPlanner;
pub const RenderBatchPlan = render_model.RenderBatchPlan;
pub const RenderPipelineCacheEntry = render_model.RenderPipelineCacheEntry;
pub const RenderPipelineCacheActionKind = render_model.RenderPipelineCacheActionKind;
pub const RenderPipelineCacheAction = render_model.RenderPipelineCacheAction;
pub const RenderPipelineCachePlanner = render_model.RenderPipelineCachePlanner;
pub const RenderPipelineCachePlan = render_model.RenderPipelineCachePlan;
pub const RenderPathGeometryKind = render_model.RenderPathGeometryKind;
pub const RenderPathGeometry = render_model.RenderPathGeometry;
pub const RenderPathGeometryPlan = render_model.RenderPathGeometryPlan;
pub const RenderPathGeometryPlanner = render_model.RenderPathGeometryPlanner;
pub const RenderPathGeometryKey = render_model.RenderPathGeometryKey;
pub const RenderPathGeometryCacheEntry = render_model.RenderPathGeometryCacheEntry;
pub const RenderPathGeometryCacheActionKind = render_model.RenderPathGeometryCacheActionKind;
pub const RenderPathGeometryCacheAction = render_model.RenderPathGeometryCacheAction;
pub const RenderPathGeometryCachePlan = render_model.RenderPathGeometryCachePlan;
pub const RenderPathGeometryCachePlanner = render_model.RenderPathGeometryCachePlanner;
pub const RenderImage = render_model.RenderImage;
pub const RenderImagePlan = render_model.RenderImagePlan;
pub const RenderImagePlanner = render_model.RenderImagePlanner;
pub const RenderImageKey = render_model.RenderImageKey;
pub const RenderImageCacheEntry = render_model.RenderImageCacheEntry;
pub const RenderImageCacheActionKind = render_model.RenderImageCacheActionKind;
pub const RenderImageCacheAction = render_model.RenderImageCacheAction;
pub const RenderImageCachePlan = render_model.RenderImageCachePlan;
pub const RenderImageCachePlanner = render_model.RenderImageCachePlanner;
pub const RenderResourceKind = render_model.RenderResourceKind;
pub const RenderResource = render_model.RenderResource;
pub const RenderResourcePlan = render_model.RenderResourcePlan;
pub const RenderResourcePlanner = render_model.RenderResourcePlanner;
pub const RenderResourceKey = render_model.RenderResourceKey;
pub const RenderResourceCacheEntry = render_model.RenderResourceCacheEntry;
pub const RenderResourceCacheActionKind = render_model.RenderResourceCacheActionKind;
pub const RenderResourceCacheAction = render_model.RenderResourceCacheAction;
pub const RenderResourceCachePlan = render_model.RenderResourceCachePlan;
pub const RenderResourceCachePlanner = render_model.RenderResourceCachePlanner;
pub const RenderLayer = render_model.RenderLayer;
pub const RenderLayerPlan = render_model.RenderLayerPlan;
pub const RenderLayerPlanner = render_model.RenderLayerPlanner;
pub const RenderLayerKey = render_model.RenderLayerKey;
pub const RenderLayerCacheEntry = render_model.RenderLayerCacheEntry;
pub const RenderLayerCacheActionKind = render_model.RenderLayerCacheActionKind;
pub const RenderLayerCacheAction = render_model.RenderLayerCacheAction;
pub const RenderLayerCachePlan = render_model.RenderLayerCachePlan;
pub const RenderLayerCachePlanner = render_model.RenderLayerCachePlanner;
pub const VisualEffectKind = render_model.VisualEffectKind;
pub const VisualEffect = render_model.VisualEffect;
pub const VisualEffectPlan = render_model.VisualEffectPlan;
pub const VisualEffectPlanner = render_model.VisualEffectPlanner;
pub const VisualEffectKey = render_model.VisualEffectKey;
pub const VisualEffectCacheEntry = render_model.VisualEffectCacheEntry;
pub const VisualEffectCacheActionKind = render_model.VisualEffectCacheActionKind;
pub const VisualEffectCacheAction = render_model.VisualEffectCacheAction;
pub const VisualEffectCachePlan = render_model.VisualEffectCachePlan;
pub const VisualEffectCachePlanner = render_model.VisualEffectCachePlanner;

// Canvas frame options and diagnostics live in `frame.zig`; root keeps the public API stable.
pub const CanvasFrameOptions = frame_model.CanvasFrameOptions;
pub const CanvasFrameStorage = frame_model.CanvasFrameStorage;
pub const CanvasFrameBudget = frame_model.CanvasFrameBudget;
pub const CanvasFrameBudgetStatus = frame_model.CanvasFrameBudgetStatus;
pub const CanvasFrameDiagnostics = frame_model.CanvasFrameDiagnostics;
pub const CanvasFrameProfileRisk = frame_model.CanvasFrameProfileRisk;
pub const CanvasFrameProfile = frame_model.CanvasFrameProfile;
pub const CanvasRenderPass = frame_model.CanvasRenderPass;
pub const CanvasFrame = frame_model.CanvasFrame;
pub const buildCanvasFrame = frame_model.buildCanvasFrame;

// Canvas GPU packet and encoder data live in `gpu.zig`; root keeps the public API stable.
pub const CanvasRenderPassLoadAction = gpu_model.CanvasRenderPassLoadAction;
pub const RenderEncoderBeginPass = gpu_model.RenderEncoderBeginPass;
pub const RenderEncoderCommand = gpu_model.RenderEncoderCommand;
pub const RenderEncoderPlan = gpu_model.RenderEncoderPlan;
pub const RenderEncoderPlanner = gpu_model.RenderEncoderPlanner;
pub const CanvasGpuCommandKind = gpu_model.CanvasGpuCommandKind;
pub const CanvasGpuRoundedRect = gpu_model.CanvasGpuRoundedRect;
pub const CanvasGpuStrokeRect = gpu_model.CanvasGpuStrokeRect;
pub const CanvasGpuLine = gpu_model.CanvasGpuLine;
pub const CanvasGpuShape = gpu_model.CanvasGpuShape;
pub const CanvasGpuPaint = gpu_model.CanvasGpuPaint;
pub const CanvasGpuImage = gpu_model.CanvasGpuImage;
pub const CanvasGpuText = gpu_model.CanvasGpuText;
pub const CanvasGpuShadow = gpu_model.CanvasGpuShadow;
pub const CanvasGpuBlur = gpu_model.CanvasGpuBlur;
pub const CanvasGpuEffect = gpu_model.CanvasGpuEffect;
pub const CanvasGpuCommand = gpu_model.CanvasGpuCommand;
pub const CanvasGpuPacket = gpu_model.CanvasGpuPacket;
pub const CanvasGpuPacketSummary = gpu_model.CanvasGpuPacketSummary;
pub const CanvasGpuPacketPlanner = gpu_model.CanvasGpuPacketPlanner;

// Reference raster renderer lives in reference.zig; root keeps the public API stable.
pub const ReferenceImage = reference_model.ReferenceImage;
pub const ReferenceRenderSurface = reference_model.ReferenceRenderSurface;

pub const Density = token_model.Density;
pub const Easing = token_model.Easing;
pub const ColorScheme = token_model.ColorScheme;
pub const ColorContrast = token_model.ColorContrast;
pub const ThemeOptions = token_model.ThemeOptions;
pub const ColorTokens = token_model.ColorTokens;
pub const FontFamily = token_model.FontFamily;
pub const TypographyTokens = token_model.TypographyTokens;
pub const SpacingTokens = token_model.SpacingTokens;
pub const RadiusTokens = token_model.RadiusTokens;
pub const StrokeTokens = token_model.StrokeTokens;
pub const ShadowToken = token_model.ShadowToken;
pub const ShadowTokens = token_model.ShadowTokens;
pub const BlurTokens = token_model.BlurTokens;
pub const MotionDuration = token_model.MotionDuration;
pub const MotionAnimationOptions = token_model.MotionAnimationOptions;
pub const MotionTokens = token_model.MotionTokens;
pub const SpringToken = token_model.SpringToken;
pub const BlurTokenRef = token_model.BlurTokenRef;
pub const ScrollPhysics = token_model.ScrollPhysics;
pub const ScrollState = token_model.ScrollState;
pub const VirtualListOptions = token_model.VirtualListOptions;
pub const VirtualListRange = token_model.VirtualListRange;
pub const virtualListRange = token_model.virtualListRange;
pub const LayerTokens = token_model.LayerTokens;
pub const PixelSnapTokens = token_model.PixelSnapTokens;
pub const ControlVisualTokens = token_model.ControlVisualTokens;
pub const ControlTokens = token_model.ControlTokens;
pub const ColorTokenOverrides = token_model.ColorTokenOverrides;
pub const TypographyTokenOverrides = token_model.TypographyTokenOverrides;
pub const SpacingTokenOverrides = token_model.SpacingTokenOverrides;
pub const RadiusTokenOverrides = token_model.RadiusTokenOverrides;
pub const StrokeTokenOverrides = token_model.StrokeTokenOverrides;
pub const ShadowTokenOverrides = token_model.ShadowTokenOverrides;
pub const ShadowTokensOverrides = token_model.ShadowTokensOverrides;
pub const BlurTokenOverrides = token_model.BlurTokenOverrides;
pub const SpringTokenOverrides = token_model.SpringTokenOverrides;
pub const MotionTokenOverrides = token_model.MotionTokenOverrides;
pub const ScrollPhysicsOverrides = token_model.ScrollPhysicsOverrides;
pub const LayerTokenOverrides = token_model.LayerTokenOverrides;
pub const PixelSnapTokenOverrides = token_model.PixelSnapTokenOverrides;
pub const ControlVisualTokenOverrides = token_model.ControlVisualTokenOverrides;
pub const ControlTokenOverrides = token_model.ControlTokenOverrides;
pub const DesignTokenOverrides = token_model.DesignTokenOverrides;
pub const DesignTokens = token_model.DesignTokens;

// Canvas widget model and built-in factories live in `widgets.zig`; root keeps the public API stable.
pub const WidgetKind = widget_model.WidgetKind;
pub const WidgetCursor = widget_model.WidgetCursor;
pub const WidgetState = widget_model.WidgetState;
pub const WidgetRenderState = widget_model.WidgetRenderState;
pub const WidgetMainAlignment = widget_model.WidgetMainAlignment;
pub const WidgetCrossAlignment = widget_model.WidgetCrossAlignment;
pub const WidgetLayoutStyle = widget_model.WidgetLayoutStyle;
pub const WidgetStyle = widget_model.WidgetStyle;
pub const WidgetVariant = widget_model.WidgetVariant;
pub const WidgetSize = widget_model.WidgetSize;
pub const WidgetRole = widget_model.WidgetRole;
pub const BuiltinComponentStyle = widget_model.BuiltinComponentStyle;
pub const BuiltinComponentKind = widget_model.BuiltinComponentKind;
pub const builtin_component_kinds = widget_model.builtin_component_kinds;
pub const builtin_component_names = widget_model.builtin_component_names;
pub const BuiltinComponentDescriptor = widget_model.BuiltinComponentDescriptor;
pub const builtinComponentCount = widget_model.builtinComponentCount;
pub const builtinComponentName = widget_model.builtinComponentName;
pub const builtinComponentDescriptor = widget_model.builtinComponentDescriptor;
pub const WidgetActions = widget_model.WidgetActions;
pub const WidgetSemantics = widget_model.WidgetSemantics;
pub const Widget = widget_model.Widget;
pub const BuiltinComponentOptions = widget_model.BuiltinComponentOptions;
pub const WidgetCommandPart = widget_model.WidgetCommandPart;
pub const BuiltinSurfacePlacementOptions = widget_model.BuiltinSurfacePlacementOptions;
pub const BuiltinSurfaceBackdropOptions = widget_model.BuiltinSurfaceBackdropOptions;
pub const BuiltinStatusBarOptions = widget_model.BuiltinStatusBarOptions;
pub const BuiltinSurfaceEnterAnimationOptions = widget_model.BuiltinSurfaceEnterAnimationOptions;
pub const builtinComponentWidget = widget_model.builtinComponentWidget;
pub const widgetCommandPartId = widget_model.widgetCommandPartId;
pub const builtinSurfaceBackdropWidget = widget_model.builtinSurfaceBackdropWidget;
pub const builtinStatusBarWidget = widget_model.builtinStatusBarWidget;
pub const builtinSurfaceFrame = widget_model.builtinSurfaceFrame;
pub const appendBuiltinSurfaceEnterAnimations = widget_model.appendBuiltinSurfaceEnterAnimations;
pub const builtinSurfaceEnterOffset = widget_model.builtinSurfaceEnterOffset;

pub const max_widget_depth = widget_runtime.max_widget_depth;
pub const max_widget_text_range_rects = widget_runtime.max_widget_text_range_rects;

// Experimental markup front-end lives in `ui_markup.zig` / `ui_markup_view.zig`.
pub const ui_markup = @import("ui_markup.zig");
pub const MarkupView = @import("ui_markup_view.zig").MarkupView;
pub const MarkupBuildDiagnostic = @import("ui_markup_view.zig").BuildDiagnostic;

// Experimental declarative authoring layer lives in `ui.zig`.
pub const ui_builder = @import("ui.zig");
pub const Ui = ui_builder.Ui;
pub const UiKey = ui_builder.UiKey;
pub const UiHandlerEvent = ui_builder.UiHandlerEvent;
pub const uiKey = ui_builder.uiKey;

// Canvas widget event and semantics data lives in `events.zig`; root keeps the public API stable.
pub const WidgetLayoutNode = event_model.WidgetLayoutNode;
pub const WidgetHit = event_model.WidgetHit;
pub const WidgetPointerPhase = event_model.WidgetPointerPhase;
pub const WidgetPointerEvent = event_model.WidgetPointerEvent;
pub const WidgetKeyboardPhase = event_model.WidgetKeyboardPhase;
pub const WidgetKeyboardModifiers = event_model.WidgetKeyboardModifiers;
pub const WidgetKeyboardEvent = event_model.WidgetKeyboardEvent;
pub const WidgetControlIntentKind = event_model.WidgetControlIntentKind;
pub const WidgetControlIntent = event_model.WidgetControlIntent;
pub const WidgetSemanticAction = event_model.WidgetSemanticAction;
pub const WidgetFileDropEvent = event_model.WidgetFileDropEvent;
pub const WidgetDragEvent = event_model.WidgetDragEvent;
pub const WidgetEventPhase = event_model.WidgetEventPhase;
pub const WidgetEventRouteEntry = event_model.WidgetEventRouteEntry;
pub const WidgetEventRoute = event_model.WidgetEventRoute;
pub const WidgetKeyboardRoute = event_model.WidgetKeyboardRoute;
pub const WidgetFocusDirection = event_model.WidgetFocusDirection;
pub const WidgetFocusTarget = event_model.WidgetFocusTarget;
pub const WidgetScrollMetrics = event_model.WidgetScrollMetrics;
pub const WidgetListMetrics = event_model.WidgetListMetrics;
pub const WidgetSemanticsNode = event_model.WidgetSemanticsNode;
pub const WidgetInvalidationKind = event_model.WidgetInvalidationKind;
pub const WidgetInvalidation = event_model.WidgetInvalidation;
pub const widgetKeyboardControlIntent = event_model.widgetKeyboardControlIntent;
pub const semanticActions = event_model.semanticActions;
pub const widgetSemanticControlIntent = event_model.widgetSemanticControlIntent;
pub const widgetSemanticControlIntentWithActions = event_model.widgetSemanticControlIntentWithActions;
pub const isWidgetActivationKey = event_model.isWidgetActivationKey;
pub const widgetSliderKeyboardValue = event_model.widgetSliderKeyboardValue;
pub const widgetScrollKeyboardIntent = event_model.widgetScrollKeyboardIntent;
pub const widgetScrollKeyboardDelta = event_model.widgetScrollKeyboardDelta;

pub const WidgetLayoutTree = widget_runtime.WidgetLayoutTree;

pub const DisplayList = command_model.DisplayList;

pub const emitWidgetTree = widget_runtime.emitWidgetTree;
pub const layoutWidgetTree = widget_runtime.layoutWidgetTree;
pub const layoutWidgetTreeWithTokens = widget_runtime.layoutWidgetTreeWithTokens;

pub const layoutTextRun = text_model.layoutTextRun;
pub const layoutTextRunPlan = text_model.layoutTextRunPlan;
pub const layoutTextCaretRect = text_model.layoutTextCaretRect;
pub const textCaretRectForLayout = text_model.textCaretRectForLayout;
pub const layoutTextSelectionRects = text_model.layoutTextSelectionRects;
pub const textSelectionRectsForLayout = text_model.textSelectionRectsForLayout;
pub const layoutTextOffsetForPoint = text_model.layoutTextOffsetForPoint;
pub const textOffsetForLayoutPoint = text_model.textOffsetForLayoutPoint;
pub const applyTextInputEvent = text_model.applyTextInputEvent;

pub const sampleCanvasRenderAnimations = render_model.sampleCanvasRenderAnimations;

pub const emitWidgetLayout = widget_runtime.emitWidgetLayout;
pub const toggleWidgetKnobCommandId = widget_runtime.toggleWidgetKnobCommandId;
pub const toggleWidgetKnobTravel = widget_runtime.toggleWidgetKnobTravel;
pub const textSelectionForWidgetPoint = widget_runtime.textSelectionForWidgetPoint;
pub const textOffsetForWidgetPoint = widget_runtime.textOffsetForWidgetPoint;
pub const textInputViewportForWidget = widget_runtime.textInputViewportForWidget;
pub const textInputContentExtentForWidget = widget_runtime.textInputContentExtentForWidget;
pub const textInputMaxScrollOffsetForWidget = widget_runtime.textInputMaxScrollOffsetForWidget;
pub const clampedTextInputScrollOffsetForWidget = widget_runtime.clampedTextInputScrollOffsetForWidget;
pub const intrinsicWidgetSize = widget_runtime.intrinsicWidgetSize;
pub const cursorForWidgetHit = widget_runtime.cursorForWidgetHit;
pub const cursorForWidgetTarget = widget_runtime.cursorForWidgetTarget;
pub const WidgetTextGeometry = widget_runtime.WidgetTextGeometry;
pub const textGeometryForWidget = widget_runtime.textGeometryForWidget;
pub const virtualWidgetScrollContentExtent = widget_runtime.virtualWidgetScrollContentExtent;
pub const virtualWidgetScrollContentExtentWithTokens = widget_runtime.virtualWidgetScrollContentExtentWithTokens;

pub const writeCanvasGpuPacketJson = serialization.writeCanvasGpuPacketJson;

test {
    _ = @import("tests.zig");
}
