const std = @import("std");
const core = @import("core.zig");

pub const launch_timing = @import("launch_timing.zig");

pub const max_canvas_commands_per_view = core.max_canvas_commands_per_view;
pub const max_canvas_gradient_stops_per_view = core.max_canvas_gradient_stops_per_view;
pub const max_canvas_path_elements_per_view = core.max_canvas_path_elements_per_view;
pub const max_canvas_glyphs_per_view = core.max_canvas_glyphs_per_view;
pub const max_canvas_text_bytes_per_view = core.max_canvas_text_bytes_per_view;
pub const max_canvas_widget_nodes_per_view = core.max_canvas_widget_nodes_per_view;
pub const max_canvas_widget_semantics_per_view = core.max_canvas_widget_semantics_per_view;
pub const max_canvas_widget_text_bytes_per_view = core.max_canvas_widget_text_bytes_per_view;

pub const LifecycleEvent = core.LifecycleEvent;
pub const CommandEvent = core.CommandEvent;
pub const Command = core.Command;
pub const CommandSource = core.CommandSource;
pub const ShortcutEvent = core.ShortcutEvent;
pub const Appearance = core.Appearance;
pub const GpuFrame = core.GpuFrame;
pub const GpuSurfaceFrameEvent = core.GpuSurfaceFrameEvent;
pub const GpuSurfaceResizeEvent = core.GpuSurfaceResizeEvent;
pub const GpuSurfaceInputEvent = core.GpuSurfaceInputEvent;
pub const CanvasWidgetPointerEvent = core.CanvasWidgetPointerEvent;
pub const CanvasWidgetKeyboardEvent = core.CanvasWidgetKeyboardEvent;
pub const CanvasWidgetScrollEvent = core.CanvasWidgetScrollEvent;
pub const CanvasWidgetDisplayListChrome = core.CanvasWidgetDisplayListChrome;
pub const CanvasPresentationMode = core.CanvasPresentationMode;
pub const CanvasPresentationResult = core.CanvasPresentationResult;
pub const CanvasWidgetAccessibilityActionKind = core.CanvasWidgetAccessibilityActionKind;
pub const CanvasWidgetAccessibilityAction = core.CanvasWidgetAccessibilityAction;
pub const CanvasWidgetFileDropEvent = core.CanvasWidgetFileDropEvent;
pub const CanvasWidgetDragEvent = core.CanvasWidgetDragEvent;
pub const CanvasWidgetDismissEvent = core.CanvasWidgetDismissEvent;
pub const CanvasWidgetContextPressEvent = core.CanvasWidgetContextPressEvent;
pub const InvalidationReason = core.InvalidationReason;
pub const FrameDiagnostics = core.FrameDiagnostics;
pub const Event = core.Event;
pub const App = core.App;
pub const Options = core.Options;
pub const Runtime = core.Runtime;
pub const TestHarness = core.TestHarness;
pub const DispatchError = core.DispatchError;
pub const max_dispatch_errors = core.max_dispatch_errors;
pub const UiApp = @import("ui_app.zig").UiApp;
pub const UiAppWithFeatures = @import("ui_app.zig").UiAppWithFeatures;
pub const UiAppFeatures = @import("ui_app.zig").UiAppFeatures;

const runtime_frame_profile = @import("frame_profile.zig");
pub const FrameProfile = runtime_frame_profile.FrameProfile;
pub const FrameProfileStage = runtime_frame_profile.FrameProfileStage;
pub const FrameProfileStageStats = runtime_frame_profile.FrameProfileStageStats;
pub const max_frame_profile_samples = runtime_frame_profile.max_frame_profile_samples;

const runtime_effects = @import("effects.zig");
pub const Effects = runtime_effects.Effects;
pub const EffectLine = runtime_effects.EffectLine;
pub const EffectExit = runtime_effects.EffectExit;
pub const EffectExitReason = runtime_effects.EffectExitReason;
pub const EffectExecutor = runtime_effects.EffectExecutor;
pub const EffectOutputMode = runtime_effects.EffectOutputMode;
pub const effect_error_exit_code = runtime_effects.effect_error_exit_code;
pub const max_effects = runtime_effects.max_effects;
pub const max_effect_argv = runtime_effects.max_effect_argv;
pub const max_effect_argv_bytes = runtime_effects.max_effect_argv_bytes;
pub const max_effect_stdin_bytes = runtime_effects.max_effect_stdin_bytes;
pub const max_effect_line_bytes = runtime_effects.max_effect_line_bytes;
pub const max_effect_line_bytes_ceiling = runtime_effects.max_effect_line_bytes_ceiling;
pub const FetchResponseMode = runtime_effects.FetchResponseMode;
pub const max_effect_collect_bytes = runtime_effects.max_effect_collect_bytes;
pub const max_effect_stderr_tail_bytes = runtime_effects.max_effect_stderr_tail_bytes;
pub const max_effect_queue_entries = runtime_effects.max_effect_queue_entries;
pub const EffectResponse = runtime_effects.EffectResponse;
pub const EffectFetchOutcome = runtime_effects.EffectFetchOutcome;
pub const max_effect_url_bytes = runtime_effects.max_effect_url_bytes;
pub const max_effect_fetch_headers = runtime_effects.max_effect_fetch_headers;
pub const max_effect_fetch_header_bytes = runtime_effects.max_effect_fetch_header_bytes;
pub const max_effect_fetch_payload_bytes = runtime_effects.max_effect_fetch_payload_bytes;
pub const max_effect_body_bytes = runtime_effects.max_effect_body_bytes;
pub const default_effect_fetch_timeout_ms = runtime_effects.default_effect_fetch_timeout_ms;
pub const EffectFileOp = runtime_effects.EffectFileOp;
pub const EffectFileOutcome = runtime_effects.EffectFileOutcome;
pub const EffectFileResult = runtime_effects.EffectFileResult;
pub const max_effect_file_path_bytes = runtime_effects.max_effect_file_path_bytes;
pub const max_effect_file_bytes = runtime_effects.max_effect_file_bytes;
pub const EffectClipboardOp = runtime_effects.EffectClipboardOp;
pub const EffectClipboardOutcome = runtime_effects.EffectClipboardOutcome;
pub const EffectClipboardResult = runtime_effects.EffectClipboardResult;
pub const max_effect_clipboard_bytes = runtime_effects.max_effect_clipboard_bytes;
pub const TimerMode = runtime_effects.TimerMode;
pub const EffectTimer = runtime_effects.EffectTimer;
pub const EffectTimerOutcome = runtime_effects.EffectTimerOutcome;
pub const max_effect_timers = runtime_effects.max_effect_timers;
pub const effect_timer_platform_id_base = runtime_effects.effect_timer_platform_id_base;
pub const EffectAudio = runtime_effects.EffectAudio;
pub const EffectAudioEventKind = runtime_effects.EffectAudioEventKind;
pub const EffectAudioSource = runtime_effects.EffectAudioSource;
pub const audioCachePath = runtime_effects.audioCachePath;
pub const max_effect_audio_path_bytes = runtime_effects.max_effect_audio_path_bytes;
pub const EffectHostResult = runtime_effects.EffectHostResult;
pub const HostCallBinding = runtime_effects.HostCallBinding;
pub const max_effect_host_name_bytes = runtime_effects.max_effect_host_name_bytes;
pub const max_effect_host_payload_bytes = runtime_effects.max_effect_host_payload_bytes;
pub const max_effect_host_result_bytes = runtime_effects.max_effect_host_result_bytes;

const runtime_ts_core_host = @import("ts_core_host.zig");
pub const TsCoreHost = runtime_ts_core_host.TsCoreHost;
pub const ts_core_request_key_base = runtime_ts_core_host.request_key_base;
pub const ts_core_timer_key_base = runtime_ts_core_host.timer_key_base;
pub const ts_core_effect_key_base = runtime_ts_core_host.effect_key_base;
pub const ts_core_delay_key_base = runtime_ts_core_host.delay_key_base;
pub const ts_core_clip_write_key_base = runtime_ts_core_host.clip_write_key_base;
pub const ts_core_spawn_key_base = runtime_ts_core_host.spawn_key_base;
pub const ts_core_audio_key_base = runtime_ts_core_host.audio_key_base;

const runtime_ts_ui_app = @import("ts_ui_app.zig");
pub const TsUiApp = runtime_ts_ui_app.TsUiApp;

const runtime_session_journal = @import("session_journal.zig");
const runtime_session_record = @import("session_record.zig");
const runtime_session_replay = @import("session_replay.zig");
const runtime_session_blobs = @import("session_blobs.zig");
pub const session_journal = runtime_session_journal;
pub const session_blobs = runtime_session_blobs;
pub const SessionRecorder = runtime_session_record.SessionRecorder;
pub const SessionRecorderSink = runtime_session_record.RecorderSink;
pub const SessionBlobSink = runtime_session_blobs.SessionBlobSink;
pub const SessionBlobSource = runtime_session_blobs.SessionBlobSource;
pub const SessionBlobDirStore = runtime_session_blobs.DirBlobStore;
pub const SessionHeader = runtime_session_journal.Header;
pub const sessionHeaderNow = runtime_session_record.headerNow;
pub const sessionPlatformName = runtime_session_replay.currentPlatformName;
pub const replaySession = runtime_session_replay.replaySession;
pub const ReplayOptions = runtime_session_replay.ReplayOptions;
pub const ReplayReport = runtime_session_replay.ReplayReport;
pub const ReplayMismatch = runtime_session_replay.ReplayMismatch;
pub const ReplayControl = core.ReplayControl;
pub const EffectResultRecord = runtime_effects.EffectResultRecord;
pub const EffectResultKind = runtime_effects.EffectResultKind;
pub const EffectJournal = runtime_effects.EffectJournal;
pub const max_session_journal_bytes = runtime_session_journal.max_session_journal_bytes;
pub const max_session_record_bytes = runtime_session_journal.max_session_record_bytes;
pub const max_session_event_bytes = runtime_session_journal.max_session_event_bytes;

const runtime_clock = @import("clock.zig");
pub const Clock = runtime_clock.Clock;
pub const TestClock = runtime_clock.TestClock;
pub const nowMs = runtime_clock.nowMs;
pub const nowNanoseconds = runtime_clock.nowNanoseconds;
pub const monotonicMs = runtime_clock.monotonicMs;
pub const monotonicNanoseconds = runtime_clock.monotonicNanoseconds;
pub const setFreestandingMonotonicNanoseconds = runtime_clock.setFreestandingMonotonicNanoseconds;
pub const ImageRegistryBinding = runtime_effects.ImageRegistryBinding;
pub const RegisteredImage = runtime_effects.RegisteredImage;

const runtime_canvas_images = @import("canvas_images.zig");
pub const RegisteredCanvasImage = runtime_canvas_images.RegisteredCanvasImage;
pub const max_registered_canvas_images = runtime_canvas_images.max_registered_canvas_images;
pub const max_registered_canvas_image_pixel_bytes = runtime_canvas_images.max_registered_canvas_image_pixel_bytes;

// The media-surface producer channel (media_surface.zig): the handle
// type `Runtime.acquireMediaSurfaceProducer` returns rides the public
// root so producer callbacks can be TYPED (the docs' mpv recipe takes a
// `MediaSurfaceProducer` parameter), alongside the channel budgets.
const runtime_media_surface = @import("media_surface.zig");
pub const MediaSurfaceProducer = runtime_media_surface.MediaSurfaceProducer;
pub const max_media_surface_channels = runtime_media_surface.max_media_surface_channels;
pub const max_media_surface_pixel_bytes = runtime_media_surface.max_media_surface_pixel_bytes;

const runtime_canvas_fonts = @import("canvas_fonts.zig");
pub const max_registered_canvas_fonts = runtime_canvas_fonts.max_registered_canvas_fonts;
pub const max_registered_canvas_font_bytes = runtime_canvas_fonts.max_registered_canvas_font_bytes;
pub const testing = core.testing;
pub const canvasSurfacePixelSize = core.canvasSurfacePixelSize;
pub const canvasFramePixelSize = core.canvasFramePixelSize;
pub const CanvasPixelSize = core.CanvasPixelSize;

test {
    std.testing.refAllDecls(@This());
    _ = @import("tests.zig");
}
