// The toolkit-owned Android host: a complete Android application around
// the embed C ABI, in plain Java so `native dev --target android` and
// `native package --target android` compile it with nothing but the JDK
// and the Android SDK's build tools — an app project carries zero host
// code, and everything app-specific (application id, names, icons)
// arrives through the generated manifest and resources. The native half
// lives in android_host.c; the pair is the Android mirror of the iOS
// host (src/platform/ios/uikit_host.m).
//
// Presentation: a SurfaceView shows the CPU reference renderer's pixels,
// copied into the surface's window buffer by the native bridge. A
// Choreographer callback pumps `native_sdk_app_frame` and the canvas
// revision gates re-presents, so unchanged frames cost one JNI call.
//
// Input: single-pointer touch sequences forward through the embed
// touch/scroll exports in density-independent points. The touch-slop
// state machine mirrors the iOS host (and UIScrollView's delayed content
// touches): an under-slop touch is a tap, an over-slop move over a
// scrollable widget pans it through wheel-style scroll deltas, and an
// over-slop move elsewhere becomes a pointer drag so sliders and text
// selection keep desktop semantics.
//
// The soft keyboard keys off the embed focus/IME-intent state: while an
// editable text widget owns focus the canvas view holds Android input
// focus and InputMethodManager shows the keyboard; when focus leaves it
// hides. Committed text flows through `native_sdk_app_text` and IME
// composition (setComposingText / finishComposingText) maps onto the
// same `native_sdk_app_ime` set/commit/cancel path the desktop hosts
// drive. Keyboard overlap reports through the viewport's keyboard
// insets: the window stays edge-to-edge (the decor never resizes), the
// IME inset arrives via WindowInsets, and the runtime insets layout by
// the keyboard's residual overlap beyond the safe area.
//
// Layout: display cutout and system-bar insets report as the viewport's
// safe area, which the embed host republishes over the window-chrome
// channel — apps pad via `on_chrome` exactly as they do for the macOS
// titlebar band, and apps without the hook keep the automatic runtime
// inset. Rotation keeps the activity (the manifest claims configChanges)
// so the embedded runtime survives with a resize instead of a restart.
//
// Text metrics: the host registers a Paint-backed measure callback
// before start — the Android mirror of the iOS host's CoreText callback —
// so layout uses real typographic widths instead of the deterministic
// estimator. Launch with the `estimator-text-metrics` boolean extra to
// keep the estimator (before/after comparisons, deterministic goldens).
//
// Audio: the host registers the platform audio service (through the
// native bridge's nativeSetAudioService) before start, mirroring the iOS
// host's player: one android.media.MediaPlayer for local files, verified
// cache entries, and progressive HTTP(S) URL streams, with a parallel
// HttpURLConnection download filling the track cache (part file,
// size-verified, atomic rename), ~500ms position ticks only while
// playing, and one completion at natural end — all reported back through
// nativeAudioEvent. Android additionally owns audio focus: requested on
// play, and a focus loss pauses the player and reports the paused state
// honestly through an immediate position event. See the audio section
// below for the backend rationale and its constraints.

package dev.native_sdk.host;

import android.app.Activity;
import android.content.res.AssetManager;
import android.graphics.Paint;
import android.graphics.Typeface;
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.media.MediaPlayer;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.InputType;
import android.util.LruCache;
import android.view.Choreographer;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.ViewConfiguration;
import android.view.WindowInsets;
import android.view.WindowManager;
import android.view.inputmethod.BaseInputConnection;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputMethodManager;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;

public final class NativeSdkActivity extends Activity implements SurfaceHolder.Callback, Choreographer.FrameCallback {
    private static final int TOUCH_MODE_IDLE = 0;
    // Touch down seen, under slop: undecided between tap / drag / scroll.
    private static final int TOUCH_MODE_PENDING = 1;
    // Over slop on a scrollable widget: forwarding wheel scroll deltas.
    private static final int TOUCH_MODE_SCROLLING = 2;
    // Over slop elsewhere: forwarded pointer down, forwarding drags.
    private static final int TOUCH_MODE_DRAGGING = 3;

    private static final int TOUCH_PHASE_DOWN = 0;
    private static final int TOUCH_PHASE_UP = 1;
    private static final int TOUCH_PHASE_DRAG = 2;
    private static final int TOUCH_PHASE_CANCEL = 3;

    private static final int KEY_PHASE_DOWN = 0;
    private static final int KEY_PHASE_UP = 1;

    private static final int IME_SET_COMPOSITION = 0;
    private static final int IME_COMMIT_COMPOSITION = 1;
    private static final int IME_CANCEL_COMPOSITION = 2;

    // Audio event kinds for nativeAudioEvent (ordinals match the embed
    // ABI's audio event enum in native_sdk_app.h).
    private static final int AUDIO_EVENT_LOADED = 0;
    private static final int AUDIO_EVENT_POSITION = 1;
    private static final int AUDIO_EVENT_COMPLETED = 2;
    private static final int AUDIO_EVENT_FAILED = 3;

    private long nativeApp;
    private CanvasSurfaceView canvasView;
    private boolean surfaceReady;
    private float density = 1f;
    private float safeTop, safeRight, safeBottom, safeLeft;
    private float keyboardBottom;
    private int surfaceWidthPx, surfaceHeightPx;
    private long lastCanvasRevision = -1;
    private boolean hasPresentedRevision;
    private boolean needsPresent;
    private boolean keyboardShown;
    private long focusedTextWidget;
    private final LruCache<String, Double> measureCache = new LruCache<>(16384);
    private final Paint measurePaint = new Paint(Paint.ANTI_ALIAS_FLAG);

    // ------------------------------------------------------- audio state
    // The single platform player behind the embed audio service (see the
    // audio section below). All fields are main-thread only.
    private MediaPlayer audioPlayer;
    private boolean audioPrepared;
    private boolean audioBuffering;
    private boolean audioPendingPlay;
    private long audioPendingSeekMs = -1;
    private java.util.Timer audioTickTimer;
    private java.util.concurrent.atomic.AtomicBoolean audioCacheCancel;
    private AudioFocusRequest audioFocusRequest;
    private boolean audioFocusHeld;
    private final Handler audioMainHandler = new Handler(Looper.getMainLooper());

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        // Export the per-app directory namespace into the process
        // environment before any app code runs: Android gives app
        // processes no per-app HOME of their own, so the host publishes
        // the data directory as HOME and its cache child as TMPDIR — the
        // same env-based convention iOS processes get from the OS — and
        // env-driven directory resolution (the app_dirs primitive's
        // Android mapping) stays honest. `.cache` under that HOME is
        // exactly getCacheDir(), where the audio track cache belongs.
        try {
            android.system.Os.setenv("HOME", getDataDir().getAbsolutePath(), true);
            android.system.Os.setenv("TMPDIR", getCacheDir().getAbsolutePath(), true);
        } catch (Exception e) {
            android.util.Log.e("native-sdk", "env export failed: " + e);
        }

        System.loadLibrary("native_sdk_host");

        // Edge-to-edge: the decor never resizes for system bars, cutouts,
        // or the keyboard — those bands arrive as viewport insets instead,
        // so the embedded runtime owns clearance the same way it does on
        // iOS.
        getWindow().setDecorFitsSystemWindows(false);
        getWindow().getAttributes().layoutInDisplayCutoutMode =
            WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;
        getWindow().setStatusBarColor(android.graphics.Color.TRANSPARENT);
        getWindow().setNavigationBarColor(android.graphics.Color.TRANSPARENT);

        density = getResources().getDisplayMetrics().density;
        canvasView = new CanvasSurfaceView();
        canvasView.getHolder().addCallback(this);
        setContentView(canvasView);

        canvasView.setOnApplyWindowInsetsListener((view, insets) -> {
            android.graphics.Insets bars = insets.getInsets(
                WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
            android.graphics.Insets ime = insets.getInsets(WindowInsets.Type.ime());
            safeTop = bars.top / density;
            safeRight = bars.right / density;
            safeBottom = bars.bottom / density;
            safeLeft = bars.left / density;
            keyboardBottom = ime.bottom / density;
            pushViewport();
            return insets;
        });

        nativeApp = nativeCreate();
        if (nativeApp == 0) {
            android.util.Log.e("native-sdk", "nativeCreate failed");
            finish();
            return;
        }

        // Real text metrics: register the Paint measure callback before
        // start so the installing layout already measures with the fonts
        // presentation would draw with.
        if (getIntent().getBooleanExtra("estimator-text-metrics", false)) {
            android.util.Log.i("native-sdk", "text measure disabled (estimator metrics)");
        } else {
            nativeSetTextMeasure(nativeApp);
        }

        // The platform audio service (registered before start, like the
        // text measure, so the first effect dispatch already sees it):
        // one real player behind the embed audio seam — see the audio
        // section below.
        nativeSetAudioService(nativeApp);

        // Verification harness: `am start --ez native-sdk-automation true`
        // publishes snapshot.txt into the app's files dir, same protocol
        // as the desktop -Dautomation=true runners (readable over
        // `adb shell run-as <application id>` for this debuggable host).
        if (getIntent().getBooleanExtra("native-sdk-automation", false)) {
            File dir = new File(getFilesDir(), "native-sdk-automation");
            dir.mkdirs();
            nativeSetAutomationDir(nativeApp, dir.getAbsolutePath());
        }

        // Packaged assets: the APK carries the app's assets under
        // assets/native-sdk; the embed asset root needs a real directory,
        // so mirror them into the files dir once and point the host there.
        String assetRoot = mirrorPackagedAssets();
        if (assetRoot != null) {
            nativeSetAssetRoot(nativeApp, assetRoot);
        }

        nativeStart(nativeApp);
        nativeActivate(nativeApp);
        Choreographer.getInstance().postFrameCallback(this);
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (nativeApp != 0) nativeActivate(nativeApp);
    }

    @Override
    protected void onPause() {
        if (nativeApp != 0) nativeDeactivate(nativeApp);
        super.onPause();
    }

    @Override
    protected void onDestroy() {
        Choreographer.getInstance().removeFrameCallback(this);
        if (nativeApp != 0) {
            // Stop first: the runtime's shutdown path releases the audio
            // channel through the still-registered service. Zeroing
            // nativeApp afterwards cuts the event path, so a stray
            // asynchronous report cannot reach a dead runtime; then the
            // belt-and-braces teardown below retires whatever survived.
            nativeStop(nativeApp);
            nativeDestroy(nativeApp);
            nativeApp = 0;
        }
        audioReleasePlayer(true);
        super.onDestroy();
    }

    // ------------------------------------------------------------ surface

    @Override
    public void surfaceCreated(SurfaceHolder holder) {
    }

    @Override
    public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {
        if (nativeApp == 0) return;
        nativeSurfaceChanged(nativeApp, holder.getSurface());
        surfaceReady = true;
        surfaceWidthPx = width;
        surfaceHeightPx = height;
        pushViewport();
    }

    @Override
    public void surfaceDestroyed(SurfaceHolder holder) {
        surfaceReady = false;
        if (nativeApp != 0) nativeSurfaceDestroyed(nativeApp);
    }

    // Report the surface size in density-independent points plus the
    // safe-area and keyboard insets; the embed host republishes the safe
    // area over the window-chrome channel and keeps insetting layout by
    // the keyboard's residual overlap beyond it.
    private void pushViewport() {
        if (nativeApp == 0 || !surfaceReady || surfaceWidthPx <= 0 || surfaceHeightPx <= 0) return;
        nativeViewport(nativeApp,
            surfaceWidthPx / density, surfaceHeightPx / density, density,
            safeTop, safeRight, safeBottom, safeLeft,
            0f, 0f, keyboardBottom, 0f);
        needsPresent = true;
    }

    // ------------------------------------------------------------- frames

    @Override
    public void doFrame(long frameTimeNanos) {
        if (nativeApp == 0) return;
        Choreographer.getInstance().postFrameCallback(this);

        // Host-pumped frame: synthesizes the gpu_surface_frame event
        // (first tick installs the widget tree, later ticks re-present).
        nativeFrame(nativeApp);

        // Keyboard show/hide follows the runtime's focus state each tick,
        // not only after forwarded input: focus can also move from key
        // handling or model updates.
        syncTextInput();

        if (!surfaceReady) return;
        long revision = nativeCanvasRevision(nativeApp);
        if (!needsPresent && revision >= 0 && hasPresentedRevision && revision == lastCanvasRevision) return;
        if (nativePresent(nativeApp, density)) {
            if (revision >= 0) {
                lastCanvasRevision = revision;
                hasPresentedRevision = true;
            }
            needsPresent = false;
        }
    }

    // ------------------------------------------- keyboard <-> focus sync

    // Reconcile the platform soft keyboard with the runtime's
    // focus/IME-intent state: keyboard up while an editable text widget
    // owns focus, down when focus leaves — the Android mirror of the iOS
    // host's first-responder sync.
    private void syncTextInput() {
        if (nativeApp == 0 || canvasView == null) return;
        long[] widgetId = new long[1];
        float[] frame = new float[4];
        boolean active = nativeTextInputState(nativeApp, widgetId, frame);
        InputMethodManager input = getSystemService(InputMethodManager.class);
        if (active) {
            boolean widgetChanged = widgetId[0] != focusedTextWidget;
            focusedTextWidget = widgetId[0];
            if (widgetChanged) {
                canvasView.clearComposingState();
                if (keyboardShown) input.restartInput(canvasView);
            }
            if (!keyboardShown) {
                canvasView.requestFocus();
                input.showSoftInput(canvasView, 0);
                keyboardShown = true;
            }
        } else {
            focusedTextWidget = 0;
            if (keyboardShown) {
                canvasView.clearComposingState();
                input.hideSoftInputFromWindow(canvasView.getWindowToken(), 0);
                keyboardShown = false;
            }
        }
    }

    // ------------------------------------------------------- text metrics

    // Paint-backed measure upcall from android_host.c: the typographic
    // width of a single-line run, measured with the same font resolution
    // presentation draws with. Returns a negative value when the bytes
    // are not valid UTF-8 so layout falls back to its estimator.
    @SuppressWarnings("unused") // called from android_host.c
    double measureText(long fontId, double size, byte[] utf8) {
        if (utf8 == null || utf8.length == 0) return 0;
        String text;
        try {
            text = StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(utf8))
                .toString();
        } catch (CharacterCodingException e) {
            return -1;
        }
        double clamped = Math.max(1, size);
        String key = fontId + "/" + clamped + "/" + text;
        Double cached = measureCache.get(key);
        if (cached != null) return cached;
        measurePaint.setTypeface(typefaceForFontId(fontId));
        measurePaint.setTextSize((float) clamped);
        double width = measurePaint.measureText(text);
        measureCache.put(key, width);
        return width;
    }

    // Resolves a canvas font id to the Typeface measurement uses. Ids 3-6
    // are the reserved sans span variants (medium, bold, italic, bold
    // italic); 2 is mono; everything else keeps the regular sans.
    private static Typeface typefaceForFontId(long fontId) {
        if (fontId == 2) return Typeface.MONOSPACE;
        if (fontId == 3) return Typeface.create(Typeface.DEFAULT, 500, false);
        if (fontId == 4) return Typeface.create(Typeface.DEFAULT, Typeface.BOLD);
        if (fontId == 5) return Typeface.create(Typeface.DEFAULT, Typeface.ITALIC);
        if (fontId == 6) return Typeface.create(Typeface.DEFAULT, Typeface.BOLD_ITALIC);
        return Typeface.DEFAULT;
    }

    // -------------------------------------------------------------- audio
    //
    // The platform audio player behind the embed audio service. Backend
    // choice, made deliberately: android.media.MediaPlayer, the platform's
    // in-box media stack, driven from this activity. It covers the whole
    // contract with no dependencies — local files and verified cache
    // entries (synchronous prepare with the real decoded duration),
    // progressive HTTP(S) streaming (playback starts while bytes arrive,
    // never download-then-play), pause/seek/volume mid-stream, one
    // completion listener, and honest buffering reports via the info
    // callbacks. The plausible alternatives lose on this host's terms: a
    // third-party player library is out of the question for the toolkit's
    // in-box host, and a hand-rolled NDK pipeline (a decoder feeding a raw
    // output stream) is an order of magnitude more code to reimplement
    // seeking, buffering, and format coverage the platform already ships.
    // MediaPlayer's honest constraints, all handled below: it cannot seek
    // or pause before prepareAsync completes (a pre-prepared seek is
    // stored and applied on the prepared callback; play before prepared
    // records intent and starts on readiness, mirroring how a stream's
    // play "applies" on every other platform), a released player object is
    // never reusable (each load builds a fresh one), and its callbacks
    // must be consumed on this thread's looper (they are — the player is
    // created on the main thread).
    //
    // Contract mirror of the macOS/iOS hosts: exactly one player at a
    // time, every asynchronous report — the loaded acknowledgment with the
    // real duration, ~500ms position ticks only while playing, buffering
    // flips, exactly one completion, explicit failures — arrives through
    // nativeAudioEvent on the main thread, and the service entry points
    // (called from native code inside runtime dispatch) never emit
    // synchronously: the local-file LOADED acknowledgment defers one
    // main-loop turn, exactly like the macOS host's.
    //
    // The cache fill is a PARALLEL download, not a tee off the player's
    // own connection: a partially buffered stream must never masquerade as
    // a cache entry. One extra request on a track's first (uncached) play
    // buys a stock streaming path and a cache whose entries are whole
    // files by construction: downloaded beside the final name,
    // size-verified against the manifest, and renamed into place — a
    // same-directory rename, so a partial file never occupies the cache
    // name even across a crash.
    //
    // Android divergence, all focus-related: the host requests audio focus
    // on play, and a focus loss (another app took the output route) pauses
    // the player and reports the paused state honestly through one
    // immediate position event with playing=0 — a platform-initiated pause
    // the app did NOT command, so unlike app-driven pause it must echo.
    // Focus regain never auto-resumes: the app (or the person holding the
    // phone) decides. Media-session and notification integration (lock
    // screen controls, background playback beyond the cached process) are
    // out of scope for this host today.

    private AudioAttributes audioAttributes() {
        return new AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build();
    }

    private static String audioUtf8(byte[] bytes) {
        if (bytes == null || bytes.length == 0) return null;
        try {
            return StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes))
                .toString();
        } catch (CharacterCodingException e) {
            return null;
        }
    }

    // Emit one audio report carrying the live position/duration readout of
    // the active player. Main thread only, between runtime entry points.
    private void emitAudioEvent(int kind) {
        if (nativeApp == 0) return;
        long position = 0;
        long duration = 0;
        int playing = 0;
        int buffering = 0;
        MediaPlayer player = audioPlayer;
        if (player != null) {
            if (audioPrepared) {
                try {
                    int current = player.getCurrentPosition();
                    if (current > 0) position = current;
                    int total = player.getDuration();
                    if (total > 0) duration = total;
                    playing = player.isPlaying() ? 1 : 0;
                } catch (IllegalStateException ignored) {
                }
            } else {
                // A stream still preparing: the transport intent is the
                // honest playing flag (un-paused, silent until bytes
                // arrive), with buffering set beside it.
                playing = audioPendingPlay ? 1 : 0;
            }
            buffering = audioBuffering ? 1 : 0;
        }
        if (kind == AUDIO_EVENT_COMPLETED) {
            // A finished player rewinds itself; report the honest
            // terminal position instead.
            position = duration;
            playing = 0;
            buffering = 0;
        }
        nativeAudioEvent(nativeApp, kind, position, duration, playing, buffering);
    }

    // ~500ms position ticks while playing only. java.util.Timer runs on
    // its own thread, deliberately independent of the Choreographer frame
    // pump and any UI Handler cadence (a busy frame loop must not starve
    // or skew the readout); each tick marshals onto the main thread — the
    // runtime's thread — like every other host event.
    private void startAudioTicks() {
        if (audioTickTimer != null) return;
        java.util.Timer timer = new java.util.Timer("native-sdk-audio-ticks", true);
        timer.scheduleAtFixedRate(new java.util.TimerTask() {
            @Override
            public void run() {
                runOnUiThread(() -> {
                    if (audioPlayer == null) {
                        stopAudioTicks();
                        return;
                    }
                    emitAudioEvent(AUDIO_EVENT_POSITION);
                });
            }
        }, 500, 500);
        audioTickTimer = timer;
    }

    private void stopAudioTicks() {
        if (audioTickTimer == null) return;
        audioTickTimer.cancel();
        audioTickTimer = null;
    }

    // Retire the player and its bookkeeping. The cache download is
    // cancelled when a new load replaces the stream mid-flight or the
    // transport stops or fails (a skipped track should not keep burning
    // bandwidth) but ORPHANED on natural completion — it is usually
    // already done, and letting a straggler finish installs the cache
    // entry the completed play earned.
    private void audioReleasePlayer(boolean cancelDownload) {
        stopAudioTicks();
        abandonAudioFocus();
        if (cancelDownload) {
            if (audioCacheCancel != null) audioCacheCancel.set(true);
            audioCacheCancel = null;
        } else {
            audioCacheCancel = null;
        }
        audioPendingPlay = false;
        audioPendingSeekMs = -1;
        audioBuffering = false;
        audioPrepared = false;
        MediaPlayer player = audioPlayer;
        audioPlayer = null;
        if (player == null) return;
        try {
            player.release();
        } catch (Exception ignored) {
        }
    }

    // Natural end of the track (exactly once). Retire-before-emit
    // discipline: the completion Msg routinely starts the NEXT track from
    // inside its own dispatch (a music app auto-advancing), and retiring
    // afterwards would destroy the player that load just installed. The
    // duration is captured first so the event carries the honest terminal
    // position.
    private void audioPlayerCompleted(MediaPlayer player) {
        if (audioPlayer != player) return;
        long duration = 0;
        try {
            int total = player.getDuration();
            if (total > 0) duration = total;
        } catch (IllegalStateException ignored) {
        }
        audioReleasePlayer(false);
        if (nativeApp != 0) {
            nativeAudioEvent(nativeApp, AUDIO_EVENT_COMPLETED, duration, duration, 0, 0);
        }
    }

    // The player died (unreachable host, undecodable payload, mid-stream
    // network loss): one FAILED event, player retired first, cache
    // download cancelled — bytes from a failing source are not
    // trustworthy.
    private void audioPlayerFailed(MediaPlayer player) {
        if (audioPlayer != player) return;
        audioReleasePlayer(true);
        if (nativeApp != 0) {
            nativeAudioEvent(nativeApp, AUDIO_EVENT_FAILED, 0, 0, 0, 0);
        }
    }

    private void installAudioCallbacks(MediaPlayer player) {
        player.setOnCompletionListener(this::audioPlayerCompleted);
        player.setOnErrorListener((mp, what, extra) -> {
            audioPlayerFailed(mp);
            // Consumed: without this the platform follows an error with
            // its own completion callback, and a failure must never
            // masquerade as a finished track.
            return true;
        });
        player.setOnInfoListener((mp, what, extra) -> {
            if (audioPlayer != mp) return false;
            // A stream stalled waiting for bytes (or recovered): flip the
            // honest buffering flag and report the transition NOW as a
            // position event, not at the next 500ms tick.
            if (what == MediaPlayer.MEDIA_INFO_BUFFERING_START) {
                audioBuffering = true;
                emitAudioEvent(AUDIO_EVENT_POSITION);
                return true;
            }
            if (what == MediaPlayer.MEDIA_INFO_BUFFERING_END) {
                audioBuffering = false;
                emitAudioEvent(AUDIO_EVENT_POSITION);
                return true;
            }
            return false;
        });
    }

    // Synchronous local-file load (also the verified-cache-entry path).
    // Returns 0 loaded / 1 missing / 2 decode failure — the macOS host's
    // contract. The LOADED acknowledgment is asynchronous by contract:
    // emitting it inside this service call would re-enter the runtime
    // while it is still dispatching the command that asked for the load,
    // so it posts to the next main-loop turn, guarded on this player
    // still being the loaded one.
    private int audioLoadFile(String path) {
        audioReleasePlayer(true);
        if (path == null) return 1;
        if (!new File(path).isFile()) return 1;
        MediaPlayer player = new MediaPlayer();
        try {
            player.setAudioAttributes(audioAttributes());
            player.setDataSource(path);
            player.prepare();
        } catch (Exception e) {
            player.release();
            return 2;
        }
        installAudioCallbacks(player);
        audioPlayer = player;
        audioPrepared = true;
        audioBuffering = false;
        audioMainHandler.post(() -> {
            if (audioPlayer != player) return;
            emitAudioEvent(AUDIO_EVENT_LOADED);
        });
        return 0;
    }

    @SuppressWarnings("unused") // called from android_host.c
    int audioLoad(byte[] pathUtf8) {
        String path = audioUtf8(pathUtf8);
        return path == null ? 1 : audioLoadFile(path);
    }

    // URL source resolution: verified cache entry first (plays as a plain
    // local file, no network), then a progressive MediaPlayer stream with
    // a parallel cache-filling download. Returns 1 for the cache hit, 0
    // for a started stream, 2 when the URL is unusable; everything
    // asynchronous — readiness, stalls, natural end, network death —
    // arrives as audio events.
    @SuppressWarnings("unused") // called from android_host.c
    int audioLoadUrl(byte[] urlUtf8, byte[] cacheUtf8, long expectedBytes) {
        audioReleasePlayer(true);
        String url = audioUtf8(urlUtf8);
        if (url == null) return 2;
        android.net.Uri uri = android.net.Uri.parse(url);
        if (uri.getScheme() == null) return 2;
        String cachePath = audioUtf8(cacheUtf8);
        if (cachePath != null) {
            File entry = new File(cachePath);
            if (entry.isFile()) {
                if ((expectedBytes == 0 || entry.length() == expectedBytes)
                    && audioLoadFile(cachePath) == 0) {
                    return 1;
                }
                // Partial, stale, or corrupt (right size but undecodable):
                // a bad cache entry never plays, and never survives to
                // fool the next lookup.
                entry.delete();
            }
        }
        MediaPlayer player = new MediaPlayer();
        try {
            player.setAudioAttributes(audioAttributes());
            player.setDataSource(url);
        } catch (Exception e) {
            player.release();
            return 2;
        }
        installAudioCallbacks(player);
        player.setOnPreparedListener(mp -> {
            if (audioPlayer != mp) return;
            // The stream's LOADED acknowledgment: the duration is decoded
            // and playback can roll. Apply what the app commanded while
            // the player could not act on it yet.
            audioPrepared = true;
            audioBuffering = false;
            if (audioPendingSeekMs >= 0) {
                try {
                    mp.seekTo(audioPendingSeekMs, MediaPlayer.SEEK_CLOSEST);
                } catch (IllegalStateException ignored) {
                }
                audioPendingSeekMs = -1;
            }
            if (audioPendingPlay) {
                audioPendingPlay = false;
                try {
                    mp.start();
                    startAudioTicks();
                } catch (IllegalStateException ignored) {
                }
            }
            emitAudioEvent(AUDIO_EVENT_LOADED);
        });
        audioPlayer = player;
        audioPrepared = false;
        // Honest buffering from stream start until playback actually
        // rolls; the info callbacks track stalls afterwards.
        audioBuffering = true;
        player.prepareAsync();
        if (cachePath != null) {
            startAudioCacheDownload(url, cachePath, expectedBytes);
        }
        return 0;
    }

    // Background cache fill: file and network bytes only, no player state,
    // no events. A failed or cancelled download simply leaves no cache
    // entry — the next play streams again.
    private void startAudioCacheDownload(String url, String cachePath, long expectedBytes) {
        final java.util.concurrent.atomic.AtomicBoolean cancelled =
            new java.util.concurrent.atomic.AtomicBoolean(false);
        audioCacheCancel = cancelled;
        Thread thread = new Thread(() -> {
            java.net.HttpURLConnection connection = null;
            File part = new File(cachePath + ".part");
            boolean installed = false;
            try {
                connection = (java.net.HttpURLConnection) new java.net.URL(url).openConnection();
                connection.setConnectTimeout(15000);
                connection.setReadTimeout(30000);
                if (connection.getResponseCode() != 200) return;
                File parent = part.getParentFile();
                if (parent != null) parent.mkdirs();
                try (InputStream in = connection.getInputStream();
                     OutputStream out = new FileOutputStream(part)) {
                    byte[] buffer = new byte[65536];
                    int count;
                    while ((count = in.read(buffer)) > 0) {
                        if (cancelled.get()) return;
                        out.write(buffer, 0, count);
                    }
                }
                if (cancelled.get()) return;
                // Truncated or wrong content: never installed.
                if (expectedBytes != 0 && part.length() != expectedBytes) return;
                File entry = new File(cachePath);
                entry.delete();
                installed = part.renameTo(entry);
            } catch (Exception ignored) {
                // No cache entry; playback is unaffected.
            } finally {
                if (!installed) part.delete();
                if (connection != null) connection.disconnect();
            }
        }, "native-sdk-audio-cache");
        thread.setDaemon(true);
        thread.start();
    }

    // First play claims audio focus (deferred from load so a silent app
    // never takes the route). A rejected request is not fatal — playback
    // proceeds and the platform arbitrates, matching the iOS session
    // posture.
    private void requestAudioFocus() {
        if (audioFocusHeld) return;
        AudioManager manager = getSystemService(AudioManager.class);
        if (manager == null) return;
        if (audioFocusRequest == null) {
            audioFocusRequest = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(audioAttributes())
                .setOnAudioFocusChangeListener(this::onAudioFocusChange, audioMainHandler)
                .build();
        }
        audioFocusHeld =
            manager.requestAudioFocus(audioFocusRequest) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED;
    }

    private void abandonAudioFocus() {
        if (!audioFocusHeld || audioFocusRequest == null) return;
        AudioManager manager = getSystemService(AudioManager.class);
        if (manager != null) manager.abandonAudioFocusRequest(audioFocusRequest);
        audioFocusHeld = false;
    }

    // The system moved the output route to someone else (a call, another
    // media app): the platform is about to silence this player anyway, so
    // make the transport state match — pause explicitly, stop the ticks,
    // and report the paused state NOW through one position event. This is
    // the one pause that must echo: the app did not command it. A
    // transient duck (short notification blip) keeps playing, and focus
    // regain deliberately does not auto-resume.
    private void onAudioFocusChange(int change) {
        if (change != AudioManager.AUDIOFOCUS_LOSS
            && change != AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) {
            return;
        }
        audioFocusHeld = false;
        if (audioPlayer == null) return;
        audioPendingPlay = false;
        if (audioPrepared) {
            try {
                audioPlayer.pause();
            } catch (IllegalStateException ignored) {
            }
        }
        stopAudioTicks();
        emitAudioEvent(AUDIO_EVENT_POSITION);
    }

    // Transport entry points, called from android_host.c inside runtime
    // dispatch on the main thread. Results follow the desktop contract:
    // play and seek return nonzero when they applied, pause/stop/volume
    // results are advisory.

    @SuppressWarnings("unused") // called from android_host.c
    int audioPlay() {
        if (audioPlayer == null) return 0;
        requestAudioFocus();
        if (!audioPrepared) {
            // Stream still preparing: play applies when readiness lands
            // (the prepared callback starts it) — a stream's play is
            // asynchronous by nature on every platform. The ticks start
            // NOW so the un-paused-but-silent state reports honestly
            // (playing=1, buffering=1) while the network catches up.
            audioPendingPlay = true;
            startAudioTicks();
            return 1;
        }
        try {
            audioPlayer.start();
        } catch (IllegalStateException e) {
            return 0;
        }
        startAudioTicks();
        return 1;
    }

    @SuppressWarnings("unused") // called from android_host.c
    int audioPause() {
        if (audioPlayer == null) return 0;
        audioPendingPlay = false;
        if (audioPrepared) {
            try {
                audioPlayer.pause();
            } catch (IllegalStateException ignored) {
            }
        }
        stopAudioTicks();
        return 1;
    }

    @SuppressWarnings("unused") // called from android_host.c
    int audioStop() {
        boolean had = audioPlayer != null;
        audioReleasePlayer(true);
        return had ? 1 : 0;
    }

    @SuppressWarnings("unused") // called from android_host.c
    int audioSeek(long positionMs) {
        if (audioPlayer == null) return 0;
        if (!audioPrepared) {
            // MediaPlayer cannot seek before prepareAsync completes;
            // store the target and apply it on the prepared callback so
            // the seek still lands where the app asked.
            audioPendingSeekMs = positionMs;
            return 1;
        }
        long target = positionMs;
        try {
            int duration = audioPlayer.getDuration();
            if (duration > 0 && target > duration) target = duration;
            audioPlayer.seekTo(target, MediaPlayer.SEEK_CLOSEST);
        } catch (IllegalStateException e) {
            return 0;
        }
        return 1;
    }

    @SuppressWarnings("unused") // called from android_host.c
    int audioSetVolume(double volume) {
        if (audioPlayer == null) return 0;
        float level = (float) volume;
        try {
            audioPlayer.setVolume(level, level);
        } catch (IllegalStateException ignored) {
        }
        return 1;
    }

    // ------------------------------------------------------------- assets

    // Copy the APK's assets/native-sdk tree into files/native-sdk-assets
    // so asset-relative loads resolve against a real directory. Returns
    // null when the app ships no assets.
    private String mirrorPackagedAssets() {
        AssetManager assets = getAssets();
        try {
            String[] entries = assets.list("native-sdk");
            if (entries == null || entries.length == 0) return null;
            File root = new File(getFilesDir(), "native-sdk-assets");
            copyAssetDir(assets, "native-sdk", root);
            return root.getAbsolutePath();
        } catch (Exception e) {
            android.util.Log.e("native-sdk", "asset mirror failed: " + e);
            return null;
        }
    }

    private static void copyAssetDir(AssetManager assets, String path, File dest) throws Exception {
        String[] entries = assets.list(path);
        if (entries == null || entries.length == 0) {
            // A leaf: copy the file bytes.
            File parent = dest.getParentFile();
            if (parent != null) parent.mkdirs();
            try (InputStream in = assets.open(path); OutputStream out = new FileOutputStream(dest)) {
                byte[] buffer = new byte[65536];
                int count;
                while ((count = in.read(buffer)) > 0) out.write(buffer, 0, count);
            }
            return;
        }
        dest.mkdirs();
        for (String entry : entries) {
            copyAssetDir(assets, path + "/" + entry, new File(dest, entry));
        }
    }

    // -------------------------------------------------------- canvas view

    private final class CanvasSurfaceView extends SurfaceView {
        private int touchMode = TOUCH_MODE_IDLE;
        private long touchSequence;
        private float startXPx, startYPx;
        private float lastXPx, lastYPx;
        private final int touchSlopPx;
        private String composingText = "";

        CanvasSurfaceView() {
            super(NativeSdkActivity.this);
            setFocusable(true);
            setFocusableInTouchMode(true);
            touchSlopPx = ViewConfiguration.get(NativeSdkActivity.this).getScaledTouchSlop();
        }

        void clearComposingState() {
            composingText = "";
        }

        private void forwardTouchPhase(int phase, float xPx, float yPx, float pressure) {
            if (nativeApp == 0) return;
            nativeTouch(nativeApp, touchSequence, phase, xPx / density, yPx / density, pressure);
        }

        @Override
        public boolean onTouchEvent(MotionEvent event) {
            if (nativeApp == 0) return false;
            float x = event.getX();
            float y = event.getY();
            switch (event.getActionMasked()) {
                case MotionEvent.ACTION_DOWN:
                    touchSequence += 1;
                    touchMode = TOUCH_MODE_PENDING;
                    startXPx = x;
                    startYPx = y;
                    lastXPx = x;
                    lastYPx = y;
                    return true;
                case MotionEvent.ACTION_MOVE: {
                    if (touchMode == TOUCH_MODE_IDLE) return true;
                    if (touchMode == TOUCH_MODE_PENDING) {
                        float dx = x - startXPx;
                        float dy = y - startYPx;
                        if (dx * dx + dy * dy < (float) touchSlopPx * touchSlopPx) return true;
                        if (nativeScrollableWidgetAt(nativeApp, startXPx / density, startYPx / density)) {
                            touchMode = TOUCH_MODE_SCROLLING;
                        } else {
                            touchMode = TOUCH_MODE_DRAGGING;
                            forwardTouchPhase(TOUCH_PHASE_DOWN, startXPx, startYPx, 1f);
                        }
                    }
                    if (touchMode == TOUCH_MODE_SCROLLING) {
                        // Natural scrolling: finger up moves content up =
                        // offset grows, so the wheel delta is the negated
                        // finger delta.
                        float deltaX = (lastXPx - x) / density;
                        float deltaY = (lastYPx - y) / density;
                        if (deltaX != 0 || deltaY != 0) {
                            nativeScroll(nativeApp, touchSequence, x / density, y / density, deltaX, deltaY);
                        }
                    } else if (touchMode == TOUCH_MODE_DRAGGING) {
                        forwardTouchPhase(TOUCH_PHASE_DRAG, x, y, event.getPressure());
                    }
                    lastXPx = x;
                    lastYPx = y;
                    return true;
                }
                case MotionEvent.ACTION_UP:
                    switch (touchMode) {
                        case TOUCH_MODE_PENDING:
                            // Under-slop touch: a tap at the start point.
                            forwardTouchPhase(TOUCH_PHASE_DOWN, startXPx, startYPx, 1f);
                            forwardTouchPhase(TOUCH_PHASE_UP, startXPx, startYPx, 0f);
                            break;
                        case TOUCH_MODE_DRAGGING:
                            forwardTouchPhase(TOUCH_PHASE_UP, x, y, 0f);
                            break;
                        default:
                            break;
                    }
                    touchMode = TOUCH_MODE_IDLE;
                    syncTextInput();
                    return true;
                case MotionEvent.ACTION_CANCEL:
                    if (touchMode == TOUCH_MODE_DRAGGING) {
                        forwardTouchPhase(TOUCH_PHASE_CANCEL, lastXPx, lastYPx, 0f);
                    }
                    touchMode = TOUCH_MODE_IDLE;
                    syncTextInput();
                    return true;
                default:
                    return super.onTouchEvent(event);
            }
        }

        // --------------------------------------------------- hardware keys

        // Hardware keys (and `adb shell input` injections) arrive here:
        // named control keys forward by name, printable characters commit
        // as text — the split the desktop key/text seam expects.
        @Override
        public boolean onKeyDown(int keyCode, KeyEvent event) {
            if (nativeApp == 0) return super.onKeyDown(keyCode, event);
            String name = keyNameForCode(keyCode);
            if (name != null) {
                emitKeyDownUp(name, modifiersMask(event));
                syncTextInput();
                return true;
            }
            int unicode = event.getUnicodeChar();
            if (unicode != 0 && !event.isCtrlPressed() && !event.isAltPressed()) {
                commitTextToApp(new String(Character.toChars(unicode)));
                syncTextInput();
                return true;
            }
            return super.onKeyDown(keyCode, event);
        }

        private void emitKeyDownUp(String key, int modifiers) {
            nativeKey(nativeApp, KEY_PHASE_DOWN, key, modifiers);
            nativeKey(nativeApp, KEY_PHASE_UP, key, modifiers);
        }

        // ------------------------------------------------ input connection

        @Override
        public boolean onCheckIsTextEditor() {
            return true;
        }

        @Override
        public InputConnection onCreateInputConnection(EditorInfo outAttrs) {
            // Deterministic input for tests and desktop-parity text
            // handling: the runtime owns editing behavior, so system
            // rewriting stays off.
            outAttrs.inputType = InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS;
            outAttrs.imeOptions = EditorInfo.IME_ACTION_DONE | EditorInfo.IME_FLAG_NO_FULLSCREEN;
            return new BaseInputConnection(this, true) {
                // Mirrors the iOS host's insertText: committing identical
                // composed text maps to commit_composition; divergent
                // text cancels before the plain insert so the runtime
                // never double-applies the composition.
                @Override
                public boolean commitText(CharSequence text, int newCursorPosition) {
                    String value = text == null ? "" : text.toString();
                    if (value.isEmpty()) return true;
                    if ("\n".equals(value)) {
                        boolean hadComposition = !composingText.isEmpty();
                        clearComposingState();
                        if (hadComposition) emitIme(IME_COMMIT_COMPOSITION, "", -1);
                        emitKeyDownUp("enter", 0);
                        syncTextInput();
                        return true;
                    }
                    boolean hadComposition = !composingText.isEmpty();
                    String previous = composingText;
                    clearComposingState();
                    if (hadComposition && previous.equals(value)) {
                        emitIme(IME_COMMIT_COMPOSITION, "", -1);
                        return true;
                    }
                    if (hadComposition) emitIme(IME_CANCEL_COMPOSITION, "", -1);
                    commitTextToApp(value);
                    return true;
                }

                // The live composition forwards (with the caret as a
                // UTF-8 byte offset) through the same set_composition
                // path the desktop hosts use, so multi-stage IMEs stay
                // correct.
                @Override
                public boolean setComposingText(CharSequence text, int newCursorPosition) {
                    String value = text == null ? "" : text.toString();
                    if (value.isEmpty()) {
                        boolean hadComposition = !composingText.isEmpty();
                        clearComposingState();
                        if (hadComposition) emitIme(IME_CANCEL_COMPOSITION, "", -1);
                        return true;
                    }
                    composingText = value;
                    long cursorBytes = value.getBytes(StandardCharsets.UTF_8).length;
                    emitIme(IME_SET_COMPOSITION, value, cursorBytes);
                    return true;
                }

                @Override
                public boolean finishComposingText() {
                    boolean hadComposition = !composingText.isEmpty();
                    clearComposingState();
                    if (hadComposition) emitIme(IME_COMMIT_COMPOSITION, "", -1);
                    return true;
                }

                @Override
                public boolean deleteSurroundingText(int beforeLength, int afterLength) {
                    if (!composingText.isEmpty()) {
                        clearComposingState();
                        emitIme(IME_CANCEL_COMPOSITION, "", -1);
                        return true;
                    }
                    if (beforeLength > 0 && afterLength == 0) {
                        for (int i = 0; i < beforeLength; i++) emitKeyDownUp("backspace", 0);
                        return true;
                    }
                    if (afterLength > 0 && beforeLength == 0) {
                        for (int i = 0; i < afterLength; i++) emitKeyDownUp("delete", 0);
                        return true;
                    }
                    return super.deleteSurroundingText(beforeLength, afterLength);
                }

                @Override
                public boolean performEditorAction(int actionCode) {
                    emitKeyDownUp("enter", 0);
                    syncTextInput();
                    return true;
                }

                @Override
                public boolean sendKeyEvent(KeyEvent event) {
                    if (event.getAction() == KeyEvent.ACTION_DOWN) {
                        if (event.getKeyCode() == KeyEvent.KEYCODE_DEL) {
                            if (!composingText.isEmpty()) {
                                clearComposingState();
                                emitIme(IME_CANCEL_COMPOSITION, "", -1);
                                return true;
                            }
                            emitKeyDownUp("backspace", 0);
                            return true;
                        }
                        if (event.getKeyCode() == KeyEvent.KEYCODE_FORWARD_DEL) {
                            emitKeyDownUp("delete", 0);
                            return true;
                        }
                    }
                    return super.sendKeyEvent(event);
                }
            };
        }

        private void emitIme(int kind, String text, long cursor) {
            if (nativeApp == 0) return;
            nativeIme(nativeApp, kind, text.getBytes(StandardCharsets.UTF_8), cursor);
        }

        private void commitTextToApp(String text) {
            if (nativeApp == 0 || text.isEmpty()) return;
            nativeText(nativeApp, text.getBytes(StandardCharsets.UTF_8));
        }
    }

    // Named control keys the runtime's key vocabulary understands; other
    // key codes fall through to their unicode character (as committed
    // text) or the platform default.
    private static String keyNameForCode(int keyCode) {
        switch (keyCode) {
            case KeyEvent.KEYCODE_ENTER:
            case KeyEvent.KEYCODE_NUMPAD_ENTER:
                return "enter";
            case KeyEvent.KEYCODE_DEL:
                return "backspace";
            case KeyEvent.KEYCODE_FORWARD_DEL:
                return "delete";
            case KeyEvent.KEYCODE_ESCAPE:
                return "escape";
            case KeyEvent.KEYCODE_TAB:
                return "tab";
            case KeyEvent.KEYCODE_DPAD_LEFT:
                return "arrowleft";
            case KeyEvent.KEYCODE_DPAD_RIGHT:
                return "arrowright";
            case KeyEvent.KEYCODE_DPAD_UP:
                return "arrowup";
            case KeyEvent.KEYCODE_DPAD_DOWN:
                return "arrowdown";
            case KeyEvent.KEYCODE_MOVE_HOME:
                return "home";
            case KeyEvent.KEYCODE_MOVE_END:
                return "end";
            case KeyEvent.KEYCODE_PAGE_UP:
                return "pageup";
            case KeyEvent.KEYCODE_PAGE_DOWN:
                return "pagedown";
            default:
                return null;
        }
    }

    // The embed modifiers mask (1 primary, 2 command, 4 control, 8
    // option, 16 shift); Android's ctrl doubles as primary, matching the
    // Linux and Windows hosts.
    private static int modifiersMask(KeyEvent event) {
        int mask = 0;
        if (event.isCtrlPressed()) mask |= 1 | 4;
        if (event.isAltPressed()) mask |= 8;
        if (event.isShiftPressed()) mask |= 16;
        return mask;
    }

    // ------------------------------------------------------- JNI bridge

    private native long nativeCreate();
    private native void nativeDestroy(long app);
    private native void nativeStart(long app);
    private native void nativeActivate(long app);
    private native void nativeDeactivate(long app);
    private native void nativeStop(long app);
    private native void nativeSurfaceChanged(long app, android.view.Surface surface);
    private native void nativeSurfaceDestroyed(long app);
    private native void nativeViewport(long app, float width, float height, float scale, float safeTop, float safeRight, float safeBottom, float safeLeft, float keyboardTop, float keyboardRight, float keyboardBottom, float keyboardLeft);
    private native void nativeFrame(long app);
    private native long nativeCanvasRevision(long app);
    private native boolean nativePresent(long app, float scale);
    private native void nativeTouch(long app, long id, int phase, float x, float y, float pressure);
    private native void nativeScroll(long app, long id, float x, float y, float deltaX, float deltaY);
    private native void nativeKey(long app, int phase, String key, int modifiers);
    private native void nativeText(long app, byte[] utf8);
    private native void nativeIme(long app, int kind, byte[] utf8, long cursor);
    private native boolean nativeTextInputState(long app, long[] widgetId, float[] frame);
    private native boolean nativeScrollableWidgetAt(long app, float x, float y);
    private native void nativeSetAssetRoot(long app, String path);
    private native void nativeSetAutomationDir(long app, String path);
    private native void nativeSetTextMeasure(long app);
    private native void nativeSetAudioService(long app);
    private native void nativeAudioEvent(long app, int kind, long positionMs, long durationMs, int playing, int buffering);
    private native String nativeLastError(long app);
}
