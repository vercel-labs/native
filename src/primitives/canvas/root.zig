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
    ChartPathElementListFull,
    ChartLabelBytesFull,
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
// Reserved sans variant ids for inline span styling. The deterministic
// estimator applies per-variant width factors; hosts that have not mapped
// these ids to real faces fall back to the regular sans face, and because
// the measurement seam carries the same id, measured text always matches
// drawn text.
pub const default_sans_medium_font_id: FontId = 3;
pub const default_sans_bold_font_id: FontId = 4;
pub const default_sans_italic_font_id: FontId = 5;
pub const default_sans_bold_italic_font_id: FontId = 6;
pub const default_sans_font_family = FontFamily.geist;
pub const default_mono_font_family = FontFamily.geist_mono;

/// The first font id apps may register faces under. Ids below this are
/// reserved for built-in faces (1-6 are assigned today; the rest of the
/// range keeps future built-ins from colliding with app fonts). A
/// registered id plugs in everywhere a `FontId` rides: token overrides
/// (`TypographyTokenOverrides.font_id`/`mono_font_id`), draw commands,
/// atlas keys, and fingerprints.
pub const min_registered_font_id: FontId = 64;

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
pub const LineCap = drawing_model.LineCap;
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
pub const TextOverflow = text_model.TextOverflow;
pub const TextAlign = text_model.TextAlign;
pub const text_ellipsis = text_model.text_ellipsis;
pub const textEllipsisAdvance = text_model.textEllipsisAdvance;
pub const textLayoutKeysEqual = text_model.textLayoutKeysEqual;
pub const TextLayoutOptions = text_model.TextLayoutOptions;
pub const TextMeasureProvider = text_model.TextMeasureProvider;
/// Batched-measurement invalidation seam (see text_measure_cache.zig):
/// bump when anything that could change a provider's answers changes —
/// font registration, appearance flips, runtime construction. Cached
/// advances and retained wrap results both key on the generation.
pub const bumpTextMeasureGeneration = @import("text_measure_cache.zig").bumpTextMeasureGeneration;
pub const textMeasureGeneration = @import("text_measure_cache.zig").textMeasureGeneration;
/// Batched-measurement observability (per-thread counters) for tests
/// and the render benchmark's provider-call ratchet.
pub const textAdvanceFetchCount = @import("text_measure_cache.zig").textAdvanceFetchCount;
pub const textAdvanceHitCount = @import("text_measure_cache.zig").textAdvanceHitCount;
pub const textSpanWrapCacheHitCount = text_spans.textSpanWrapCacheHitCount;
pub const textSpanWrapCacheMissCount = text_spans.textSpanWrapCacheMissCount;
pub const measureTextWidthForFont = text_model.measureTextWidthForFont;
pub const estimateTextWidthForFont = text_model.estimateTextWidthForFont;
pub const estimateTextWidthForFace = text_model.estimateTextWidthForFace;
pub const estimateTextAdvanceForBytes = text_model.estimateTextAdvanceForBytes;
pub const utf8SequenceLength = text_model.utf8SequenceLength;
/// The fixed pitch (em units) mono runs measure and ink at.
pub const mono_advance_em = text_model.mono_advance_em;
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
pub const TextBuffer = text_model.TextBuffer;

pub const CanvasCommand = command_model.CanvasCommand;
pub const CommandRef = command_model.CommandRef;
pub const DiffKind = command_model.DiffKind;
pub const DiffChange = command_model.DiffChange;
pub const Builder = command_model.Builder;
pub const max_display_list_text_bytes = command_model.max_display_list_text_bytes;

// Canvas render data and cache plans live in `render.zig`; root keeps the public API stable.
pub const max_render_state_stack = render_model.max_render_state_stack;
pub const RenderState = render_model.RenderState;
pub const RenderCommand = render_model.RenderCommand;
pub const CanvasRenderOverride = render_model.CanvasRenderOverride;
pub const CanvasRenderAnimation = render_model.CanvasRenderAnimation;
pub const CanvasRenderAnimationLoop = render_model.CanvasRenderAnimationLoop;
pub const CanvasWidgetLayoutTween = render_model.CanvasWidgetLayoutTween;
pub const layoutTweenProgress = render_model.layoutTweenProgress;
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
pub const max_canvas_frame_dirty_rects = frame_model.max_canvas_frame_dirty_rects;
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
pub const canvasGpuCommandFromRenderCommand = gpu_model.canvasGpuCommandFromRenderCommand;
pub const renderCommandIntersectsDirtyBounds = gpu_model.renderCommandIntersectsDirtyBounds;

// Reference raster renderer lives in reference.zig; root keeps the public API stable.
pub const ReferenceImage = reference_model.ReferenceImage;
pub const ReferenceFont = reference_model.ReferenceFont;
pub const ReferenceRenderSurface = reference_model.ReferenceRenderSurface;
pub const ReferenceRenderMemo = reference_model.ReferenceRenderMemo;

// Deterministic CPU path rasterizer (bezier flattening, scanline AA fill,
// stroke-to-outline) lives in `vector.zig`; it serves the reference
// renderer's path commands, real glyph painting, and icons.
pub const vector = @import("vector.zig");

// Bounded TTF outline parser over the bundled Geist face; feeds real
// glyph outlines to the reference renderer's text painting.
pub const font_ttf = @import("font_ttf.zig");

// SVG icon-subset parser (the stroke-icon dialect/Feather/Tabler dialect, comptime-
// parseable) and the curated built-in icon registry behind
// `<icon name="..."/>` and `Ui.icon`.
pub const svg_icon = @import("svg_icon.zig");
pub const icons = @import("icons.zig");

// Deterministic PNG writer (stored-deflate zlib stream) lives in `png.zig`.
pub const png = @import("png.zig");

// One-image app-icon pipeline: PNG/SVG source in, per-platform icon
// artifacts (.icns/.ico/size sets) out, all through the vector core.
pub const app_icon = @import("app_icon.zig");

pub const Density = token_model.Density;
pub const Easing = token_model.Easing;
pub const ColorScheme = token_model.ColorScheme;
pub const ColorContrast = token_model.ColorContrast;
pub const ThemeOptions = token_model.ThemeOptions;
pub const ThemePack = token_model.ThemePack;
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
pub const ScrollOverscroll = token_model.ScrollOverscroll;
pub const ScrollState = token_model.ScrollState;
pub const VirtualListOptions = token_model.VirtualListOptions;
pub const VirtualListRange = token_model.VirtualListRange;
pub const virtualListRange = token_model.virtualListRange;
pub const virtual_extents = @import("virtual_extents.zig");
pub const VirtualExtentEstimateFn = virtual_extents.VirtualExtentEstimateFn;
pub const VirtualExtentTable = virtual_extents.VirtualExtentTable;
pub const VirtualExtentSyncArgs = virtual_extents.VirtualExtentSyncArgs;
pub const VirtualExtentSyncInfo = virtual_extents.VirtualExtentSyncInfo;
pub const VirtualVariableRangeOptions = virtual_extents.VirtualVariableRangeOptions;
pub const VirtualVariableRange = virtual_extents.VirtualVariableRange;
pub const virtualVariableListRange = virtual_extents.virtualVariableListRange;
pub const max_virtual_measured_items = virtual_extents.max_virtual_measured_items;
pub const max_virtual_extent_items = virtual_extents.max_virtual_extent_items;
pub const LayerTokens = token_model.LayerTokens;
pub const PixelSnapTokens = token_model.PixelSnapTokens;
pub const ControlVisualTokens = token_model.ControlVisualTokens;
pub const ControlTokens = token_model.ControlTokens;
pub const StateTokens = token_model.StateTokens;
pub const ControlMetricTokens = token_model.ControlMetricTokens;
pub const SpinnerStyleToken = token_model.SpinnerStyleToken;
pub const StateTokenOverrides = token_model.StateTokenOverrides;
pub const ControlMetricTokenOverrides = token_model.ControlMetricTokenOverrides;
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
pub const accentOverrides = token_model.accentOverrides;
pub const accentFocusRing = token_model.accentFocusRing;
pub const DesignTokens = token_model.DesignTokens;

// Canvas widget model and built-in factories live in `widgets.zig`; root keeps the public API stable.
pub const WidgetKind = widget_model.WidgetKind;
pub const WidgetCursor = widget_model.WidgetCursor;
pub const WidgetState = widget_model.WidgetState;
pub const WidgetRenderState = widget_model.WidgetRenderState;
pub const WidgetMainAlignment = widget_model.WidgetMainAlignment;
pub const WidgetCrossAlignment = widget_model.WidgetCrossAlignment;
pub const WidgetLayoutStyle = widget_model.WidgetLayoutStyle;
pub const WidgetAnchor = widget_model.WidgetAnchor;
pub const WidgetAnchorPlacement = widget_model.WidgetAnchorPlacement;
pub const WidgetAnchorAlignment = widget_model.WidgetAnchorAlignment;
pub const WidgetStyle = widget_model.WidgetStyle;
pub const WidgetVariant = widget_model.WidgetVariant;
pub const WidgetOverscroll = widget_model.WidgetOverscroll;
pub const WidgetIconPlacement = widget_model.WidgetIconPlacement;
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
pub const WidgetContextMenuItem = widget_model.WidgetContextMenuItem;
pub const Widget = widget_model.Widget;
pub const BuiltinComponentOptions = widget_model.BuiltinComponentOptions;
pub const WidgetCommandPart = widget_model.WidgetCommandPart;
pub const BuiltinSurfacePlacementOptions = widget_model.BuiltinSurfacePlacementOptions;
pub const BuiltinSurfaceBackdropOptions = widget_model.BuiltinSurfaceBackdropOptions;
pub const BuiltinStatusBarOptions = widget_model.BuiltinStatusBarOptions;
pub const BuiltinSurfaceEnterAnimationOptions = widget_model.BuiltinSurfaceEnterAnimationOptions;
pub const builtinComponentWidget = widget_model.builtinComponentWidget;
pub const widgetKindDefaultLayout = widget_model.widgetKindDefaultLayout;
pub const widgetCommandPartId = widget_model.widgetCommandPartId;
pub const builtinSurfaceBackdropWidget = widget_model.builtinSurfaceBackdropWidget;
pub const builtinStatusBarWidget = widget_model.builtinStatusBarWidget;
pub const builtinSurfaceFrame = widget_model.builtinSurfaceFrame;
pub const appendBuiltinSurfaceEnterAnimations = widget_model.appendBuiltinSurfaceEnterAnimations;
pub const builtinSurfaceEnterOffset = widget_model.builtinSurfaceEnterOffset;

pub const max_widget_depth = widget_runtime.max_widget_depth;
pub const max_widget_text_range_rects = widget_runtime.max_widget_text_range_rects;

// Inline styled text runs (mixed-weight/slant/mono/link spans within one
// wrapped paragraph) live in `text_spans.zig`.
pub const text_spans = @import("text_spans.zig");
pub const TextSpan = text_spans.TextSpan;
pub const TextSpanWeight = text_spans.TextSpanWeight;
pub const TextSpanColor = text_spans.TextSpanColor;
pub const TextSpanLayoutOptions = text_spans.TextSpanLayoutOptions;
pub const TextSpanRun = text_spans.TextSpanRun;
pub const TextSpanLayout = text_spans.TextSpanLayout;
pub const layoutTextSpans = text_spans.layoutTextSpans;
pub const textSpanFontId = text_spans.textSpanFontId;
pub const textSpanBounds = text_spans.textSpanBounds;
pub const textSpanRunBounds = text_spans.textSpanRunBounds;
pub const textSpansEqual = text_spans.textSpansEqual;
pub const max_text_spans_per_paragraph = text_spans.max_text_spans_per_paragraph;
pub const max_text_span_runs_per_paragraph = text_spans.max_text_span_runs_per_paragraph;
pub const max_text_span_lines_per_paragraph = text_spans.max_text_span_lines_per_paragraph;

// Chart plot data for the `.chart` widget kind (series, downsampling,
// domain) lives in `chart.zig`.
pub const chart = @import("chart.zig");
pub const ChartSeries = chart.ChartSeries;
pub const ChartSeriesKind = chart.ChartSeriesKind;
pub const ChartSeriesColor = chart.ChartSeriesColor;
pub const ChartData = chart.ChartData;
pub const ChartDomain = chart.ChartDomain;
pub const chartDomain = chart.chartDomain;
pub const chartDataEqual = chart.chartDataEqual;
pub const downsampleChartValues = chart.downsampleChartValues;
pub const downsampledChartLen = chart.downsampledChartLen;
pub const max_chart_points_per_series = chart.max_chart_points_per_series;
pub const max_chart_path_elements_per_frame = chart.max_chart_path_elements_per_frame;
pub const max_chart_label_bytes_per_frame = chart.max_chart_label_bytes_per_frame;
pub const max_chart_value_label_bytes = chart.max_chart_value_label_bytes;
pub const chartTickDecimals = chart.chartTickDecimals;
pub const formatChartValue = chart.formatChartValue;
pub const ChartTickLattice = chart.ChartTickLattice;
pub const chartTickLattice = chart.chartTickLattice;
pub const max_chart_axis_ticks = chart.max_chart_axis_ticks;
pub const chartPointCount = chart.chartPointCount;
pub const chartHoverIndex = chart.chartHoverIndex;

// GitHub-flavored-markdown mapper (markdown source -> widget tree + span
// model) lives in `markdown.zig`; also exported as `native_sdk.markdown`.
pub const markdown = @import("markdown.zig");

// Deterministic key-lookup scratch shared by the per-frame planners and
// the runtime's keyed diffs (see plan_key_index.zig).
pub const plan_key_index = @import("plan_key_index.zig");

// Lazily heap-allocated per-thread scratch: keeps the large planner
// buffers out of the static TLS template every OS thread must clone
// (see lazy_tls.zig for the working-set numbers).
pub const lazy_tls = @import("lazy_tls.zig");

// Experimental markup front-end lives in `ui_markup.zig` / `ui_markup_view.zig`
// (runtime parse + interpret: the dev/hot-reload engine) and
// `ui_markup_compiled.zig` (comptime parse: the release engine, no parser in
// the binary).
pub const ui_markup = @import("ui_markup.zig");
/// Widget provenance (write-back's read half): structural id -> authored
/// markup, plus the minimal-diff edit ops tooling applies to it.
pub const ui_provenance = @import("ui_provenance.zig");
pub const ui_markup_edit = @import("ui_markup_edit.zig");
pub const MarkupView = @import("ui_markup_view.zig").MarkupView;
pub const MarkupBuildDiagnostic = @import("ui_markup_view.zig").BuildDiagnostic;
pub const CompiledMarkupView = @import("ui_markup_compiled.zig").CompiledMarkupView;
pub const CompiledMarkupImports = @import("ui_markup_compiled.zig").CompiledMarkupImports;
/// Fragment hot-reload registration handle (Debug-shaped; see
/// `ui_markup.MarkupFragment`): obtained from a compiled fragment's
/// `.fragment(path)` and handed to `UiApp.Options.fragment_watch`.
pub const MarkupFragment = ui_markup.MarkupFragment;

// The model–view contract (ui_markup_contract.zig): the payload types the
// engines special-case are bound here so the contract module stays
// std-only while apps and the build's emit step get one-call access.
pub const markup_contract_specials = ui_markup.contract.Specials{
    .TextInputEvent = TextInputEvent,
    .ScrollState = ScrollState,
};

/// Reflect an app's Model/Msg into a markup contract (see
/// `ui_markup.contract.describe`).
pub fn describeModelContract(comptime Model: type, comptime Msg: type) ui_markup.contract.Contract {
    return ui_markup.contract.describe(Model, Msg, markup_contract_specials);
}

/// The per-app `zig build model-contract` step's whole program: the app
/// build wires a generated root that hands its own module to this.
pub fn emitModelContractMain(comptime app: type, init: std.process.Init) !void {
    return ui_markup.contract.emitMain(app, markup_contract_specials, init);
}

// Experimental declarative authoring layer lives in `ui.zig`.
pub const ui_builder = @import("ui.zig");
pub const Ui = ui_builder.Ui;
pub const UiKey = ui_builder.UiKey;
pub const UiHandlerEvent = ui_builder.UiHandlerEvent;
pub const uiKey = ui_builder.uiKey;
pub const forSlotKey = ui_builder.forSlotKey;
/// Windowed virtual lists (`Ui.virtualWindow` / `Ui.virtualList`): the
/// window-source seam the app loop installs before each build, the
/// per-build request records it reads back, and the global-key id
/// derivation that ties a list's declared identity to its retained
/// scroll state.
pub const globalWidgetId = ui_builder.globalWidgetId;
pub const VirtualWindowState = ui_builder.VirtualWindowState;
pub const VirtualWindowSourceFn = ui_builder.VirtualWindowSourceFn;
pub const VirtualWindowRecord = ui_builder.VirtualWindowRecord;
pub const max_virtual_windows = ui_builder.max_virtual_windows;
pub const ColorTokenName = ui_builder.ColorTokenName;
pub const RadiusTokenName = ui_builder.RadiusTokenName;
pub const StyleTokenRefs = ui_builder.StyleTokenRefs;
/// The fragment hot-reload seam between the app loop and compiled
/// markup fragments (Debug dev runs only; see `ui_builder`).
pub const MarkupFragmentHost = ui_builder.MarkupFragmentHost;
pub const MarkupFragmentDiagnostic = ui_builder.MarkupFragmentDiagnostic;

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
pub const WidgetClipboardAction = event_model.WidgetClipboardAction;
pub const widgetKeyboardClipboardAction = event_model.widgetKeyboardClipboardAction;
pub const widgetKeyboardNewlineTextEditEvent = event_model.widgetKeyboardNewlineTextEditEvent;
pub const widgetKindSingleLineTextEntry = event_model.widgetKindSingleLineTextEntry;
pub const sanitizedSingleLineTextInputEvent = event_model.sanitizedSingleLineTextInputEvent;
pub const widgetKeyboardControlIntent = event_model.widgetKeyboardControlIntent;
pub const semanticActions = event_model.semanticActions;
pub const widgetSemanticControlIntent = event_model.widgetSemanticControlIntent;
pub const widgetSemanticControlIntentWithActions = event_model.widgetSemanticControlIntentWithActions;
pub const isWidgetActivationKey = event_model.isWidgetActivationKey;
pub const isWidgetTextEntry = event_model.isWidgetTextEntry;
pub const isWidgetMenuOpenArrowKey = event_model.isWidgetMenuOpenArrowKey;
pub const widgetSliderKeyboardValue = event_model.widgetSliderKeyboardValue;
pub const widgetScrollKeyboardIntent = event_model.widgetScrollKeyboardIntent;
pub const widgetScrollKeyboardDelta = event_model.widgetScrollKeyboardDelta;

pub const WidgetLayoutTree = widget_runtime.WidgetLayoutTree;

pub const DisplayList = command_model.DisplayList;

pub const emitWidgetTree = widget_runtime.emitWidgetTree;
/// The chrome-slot command id scheme (widget id + slot) every widget
/// emitter uses — exported so runtime-side tests and tools can pin
/// specific chrome commands (fill 1, border 2, content clip 9, ...).
pub const widgetPartId = widget_runtime.widgetPartId;
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
pub const snapTextOffset = text_model.snapTextOffset;
pub const snapTextRange = text_model.snapTextRange;
pub const snapTextSelection = text_model.snapTextSelection;
pub const textWordSelectionAtOffset = text_model.textWordSelectionAtOffset;
pub const textLineSelectionAtOffset = text_model.textLineSelectionAtOffset;

pub const sampleCanvasRenderAnimations = render_model.sampleCanvasRenderAnimations;

pub const emitWidgetLayout = widget_runtime.emitWidgetLayout;
pub const toggleWidgetKnobCommandId = widget_runtime.toggleWidgetKnobCommandId;
pub const textCaretCommandId = widget_runtime.textCaretCommandId;
pub const spinnerWidgetArcCommandId = widget_runtime.spinnerWidgetArcCommandId;
pub const skeletonWidgetFillCommandId = widget_runtime.skeletonWidgetFillCommandId;
pub const spinnerWidgetRotationCenter = widget_runtime.spinnerWidgetRotationCenter;
pub const spinnerWidgetSegmentCommandId = widget_runtime.spinnerWidgetSegmentCommandId;
pub const spinnerWidgetSegmentCount = widget_runtime.spinnerWidgetSegmentCount;
pub const chartWidgetPlotRect = widget_runtime.chartWidgetPlotRect;
pub const chartWidgetHoverIndex = widget_runtime.chartWidgetHoverIndex;
pub const textSelectionCommandId = widget_runtime.textSelectionCommandId;
pub const toggleWidgetKnobTravel = widget_runtime.toggleWidgetKnobTravel;
pub const widgetControlAimPoint = widget_runtime.widgetControlAimPoint;
pub const textSelectionForWidgetPoint = widget_runtime.textSelectionForWidgetPoint;
pub const textOffsetForWidgetPoint = widget_runtime.textOffsetForWidgetPoint;

// Static text selection (click-drag select + copy in `.text` widgets;
// widget_text_select.zig).
pub const widgetStaticTextSelectable = @import("widget_text_select.zig").widgetStaticTextSelectable;
pub const staticTextSelectionForWidgetPoint = @import("widget_text_select.zig").staticTextSelectionForWidgetPoint;
pub const staticTextOffsetForWidgetPoint = @import("widget_text_select.zig").staticTextOffsetForWidgetPoint;
pub const staticTextSelectionRects = @import("widget_text_select.zig").staticTextSelectionRects;
pub const max_static_text_layout_lines = @import("widget_text_select.zig").max_static_text_layout_lines;
pub const widgetSelectableTextKind = @import("widget_access.zig").widgetSelectableTextKind;
pub const widgetTextInputKind = @import("widget_access.zig").widgetTextInputKind;
pub const widgetTextSelectionRange = @import("widget_access.zig").widgetTextSelectionRange;
pub const textInputViewportForWidget = widget_runtime.textInputViewportForWidget;
pub const textInputClearButtonRect = widget_runtime.textInputClearButtonRect;
pub const textInputClearButtonHitRect = widget_runtime.textInputClearButtonHitRect;
pub const textInputContentExtentForWidget = widget_runtime.textInputContentExtentForWidget;
pub const textInputMaxScrollOffsetForWidget = widget_runtime.textInputMaxScrollOffsetForWidget;
pub const clampedTextInputScrollOffsetForWidget = widget_runtime.clampedTextInputScrollOffsetForWidget;
pub const textInputMaxHorizontalScrollOffsetForWidget = widget_runtime.textInputMaxHorizontalScrollOffsetForWidget;
pub const clampedTextInputHorizontalScrollOffsetForWidget = widget_runtime.clampedTextInputHorizontalScrollOffsetForWidget;
pub const textInputCaretVisibleScrollOffsetForWidget = widget_runtime.textInputCaretVisibleScrollOffsetForWidget;
pub const intrinsicWidgetSize = widget_runtime.intrinsicWidgetSize;
pub const cursorForWidgetHit = widget_runtime.cursorForWidgetHit;
pub const cursorForWidgetTarget = widget_runtime.cursorForWidgetTarget;
/// Whether the engine hit-tests widgets of this kind (widget_access.zig —
/// the single source of truth the runtime, both markup engines, and the
/// markup validator's element list all derive from). Kind-level only: the
/// widget-level predicate is `widgetIsHitTarget`, which also admits any
/// widget carrying a bound press/toggle handler.
pub const widgetKindHitTarget = @import("widget_access.zig").widgetKindHitTarget;
/// Widget-level hit-target-ness: kind-level `widgetKindHitTarget` plus
/// any widget with a bound press/toggle handler (stamped into
/// `semantics.actions` by the builder and both markup engines).
pub const widgetIsHitTarget = @import("widget_access.zig").isHitTarget;
/// Press-claiming predicates (widget_access.zig): where a press gesture
/// stops instead of falling through to the nearest pressable ancestor.
pub const widgetKindClaimsPress = @import("widget_access.zig").widgetKindClaimsPress;
pub const widgetClaimsPress = @import("widget_access.zig").widgetClaimsPress;
/// The overlay-surface kinds the runtime's dismissal machinery closes
/// (Escape, click outside, automation/accessibility dismiss).
pub const widgetKindDismissibleSurface = @import("widget_access.zig").widgetKindDismissibleSurface;
/// Stable per-kind code (assigned at birth, never reused) — the id
/// algorithm's kind input; see widgets.zig.
pub const widgetKindCode = @import("widgets.zig").widgetKindCode;
/// The press fall-through walk (widget_routing.zig): the deepest widget on
/// a hit path that claims presses.
pub const widgetPressTargetForHit = @import("widget_routing.zig").widgetPressTargetForHit;
pub const widgetPressTargetIndexFromNode = @import("widget_routing.zig").widgetPressTargetIndexFromNode;
pub const widgetHoverTargetForHit = @import("widget_routing.zig").widgetHoverTargetForHit;
/// Window-drag regions (`window-drag="true"` / `.window_drag`): the
/// widget-level predicate and the press walk that resolves whether a
/// pointer-down moves the window instead of pressing a widget.
pub const widgetIsWindowDragRegion = @import("widget_access.zig").isWindowDragRegion;
pub const widgetWindowDragTargetIndexFromNode = @import("widget_routing.zig").widgetWindowDragTargetIndexFromNode;
/// Whether widgets of this kind layer their children on top of each other
/// (widget_layout.zig — the source of truth the builder's Debug gap
/// diagnostic, both markup engines, and the markup validator's
/// stack-container list all derive from).
pub const widgetKindStacksChildren = @import("widget_layout.zig").widgetKindStacksChildren;
pub const widgetIsAnchored = @import("widget_tree.zig").widgetIsAnchored;
/// The runtime-scrolled virtual list predicate (widget_tree.zig): a
/// virtualized scroll_view with a DECLARED total item count, whose
/// scroll offset the runtime owns (engine scrolling + native drivers)
/// and whose children are the built window, not the full item set.
pub const widgetVirtualRuntimeScrolled = @import("widget_tree.zig").widgetVirtualRuntimeScrolled;
pub const widgetScrollPhysics = @import("widget_tree.zig").widgetScrollPhysics;
pub const isWidgetHiddenInAncestors = @import("widget_tree.zig").isWidgetHiddenInAncestors;
/// The disclosure family (widget_tree.zig): collapsible widgets whose
/// content lays out at full size and REVEALS, plus the settled/concealed
/// predicates that gate interaction and semantics while a reveal is in
/// flight.
pub const widgetKindDisclosureAnimated = @import("widget_tree.zig").widgetKindDisclosureAnimated;
pub const disclosureSettledOpen = @import("widget_tree.zig").disclosureSettledOpen;
pub const disclosureContentBottom = @import("widget_tree.zig").disclosureContentBottom;
pub const isWidgetConcealedByDisclosure = @import("widget_tree.zig").isWidgetConcealedByDisclosure;
pub const anchoredWidgetFrame = @import("widget_layout.zig").anchoredWidgetFrame;
/// Window-control reservation trigger (widget_layout.zig): true when a
/// laid-out tree left drag-header CONTENT under the OS window-control
/// cluster, so runtimes know to stamp `DesignTokens.window_controls`
/// and re-lay the view clear of it.
pub const windowDragContentUnderWindowControls = @import("widget_layout.zig").windowDragContentUnderWindowControls;
/// Split-pane geometry (widget_layout.zig): divider band width, the
/// fraction clamp band from the panes' min widths, and the in-place
/// subtree re-layout the runtime reconcile uses when it restores a
/// runtime-owned fraction.
pub const splitDividerExtent = @import("widget_layout.zig").splitDividerExtent;
pub const splitFractionBounds = @import("widget_layout.zig").splitFractionBounds;
pub const splitEffectiveFraction = @import("widget_layout.zig").splitEffectiveFraction;
pub const relayoutSplitChildren = @import("widget_layout.zig").relayoutSplitChildren;
pub const slideSplitChildren = @import("widget_layout.zig").slideSplitChildren;
/// The layout audit (layout_audit.zig): a machine pass over a laid-out
/// tree that reports clipped/overflowing text, overlapping flow siblings,
/// content escaping its clip scope, and undersized pointer targets — plus
/// the sweep harness the example suites run across window sizes, density
/// variants, and the pseudo-locale text expansion.
pub const LayoutAuditRuleKind = @import("layout_audit.zig").LayoutAuditRuleKind;
pub const LayoutAuditFinding = @import("layout_audit.zig").LayoutAuditFinding;
pub const LayoutAuditIssues = @import("layout_audit.zig").LayoutAuditIssues;
pub const LayoutAuditSweepPoint = @import("layout_audit.zig").LayoutAuditSweepPoint;
pub const LayoutAuditSweepOptions = @import("layout_audit.zig").LayoutAuditSweepOptions;
pub const auditWidgetLayout = @import("layout_audit.zig").auditWidgetLayout;
pub const formatLayoutAuditFinding = @import("layout_audit.zig").formatLayoutAuditFinding;
pub const expectLayoutAuditSweepClean = @import("layout_audit.zig").expectLayoutAuditSweepClean;
pub const max_layout_audit_findings = @import("layout_audit.zig").max_layout_audit_findings;
pub const max_layout_audit_nodes = @import("layout_audit.zig").max_layout_audit_nodes;
pub const layout_audit_epsilon = @import("layout_audit.zig").layout_audit_epsilon;
pub const pseudo_locale_text_expansion = @import("layout_audit.zig").pseudo_locale_text_expansion;
/// The accessibility audit (a11y_audit.zig): a machine pass over a built
/// widget tree that reports interactive widgets announced with no name,
/// focusable widgets keyboard traversal can never reach, and identically
/// labeled sibling controls — the tree-level half of the a11y checks
/// (the markup lint in ui_markup.zig is the source-level half). The
/// sweep helper (`canvas.a11y.expectA11yAuditSweepClean`, re-exported
/// below) is adopted by the example suites like the layout audit's.
pub const a11y = @import("a11y_audit.zig");
pub const expectA11yAuditSweepClean = a11y.expectA11yAuditSweepClean;
/// Minimum pointer hit-target register (tokens.zig): the floor the layout
/// audit's `hit_target` rule scales per widget size and density.
pub const min_pointer_hit_target = @import("tokens.zig").min_pointer_hit_target;
pub const WidgetTextGeometry = widget_runtime.WidgetTextGeometry;
pub const textGeometryForWidget = widget_runtime.textGeometryForWidget;
pub const virtualWidgetScrollContentExtent = widget_runtime.virtualWidgetScrollContentExtent;
pub const virtualWidgetScrollContentExtentWithTokens = widget_runtime.virtualWidgetScrollContentExtentWithTokens;

pub const writeCanvasGpuPacketJson = serialization.writeCanvasGpuPacketJson;
pub const writeCanvasGpuPacketBinary = serialization.writeCanvasGpuPacketBinary;
pub const writeCanvasGpuPacketBinaryHeader = serialization.writeCanvasGpuPacketBinaryHeader;
pub const writeCanvasGpuCommandBinaryKeyed = serialization.writeCanvasGpuCommandBinaryKeyed;
pub const canvasGpuCommandFingerprint = serialization.canvasGpuCommandFingerprint;
pub const canvasGpuPacketCommandKey = serialization.canvasGpuPacketCommandKey;
pub const binary_packet_magic = serialization.binary_packet_magic;
pub const binary_packet_version = serialization.binary_packet_version;
pub const binary_packet_load_action_patch = serialization.binary_packet_load_action_patch;

test {
    _ = @import("tests.zig");
}
