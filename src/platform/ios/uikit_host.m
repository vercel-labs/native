// The toolkit-owned iOS host: a complete UIKit application around the
// embed C ABI (src/embed/c_api.zig). `native dev --target ios` and
// `native package --target ios` compile this file against the app's
// embed static library — an app project carries zero host code, and
// everything app-specific (bundle id, names, icons) arrives through the
// generated Info.plist and asset catalog. The host tier is built ON the
// embed ABI, not beside it: a hand-written host (see
// examples/mobile-canvas/ios) remains a first-class standalone use.
//
// Presentation mirrors the macOS raster path in
// src/platform/macos/appkit_host.m — the embed host renders the retained
// scene through the CPU reference renderer (`native_sdk_app_render_pixels`,
// RGBA8); the host uploads those bytes into a shared RGBA8 MTLTexture and
// presents it as a fullscreen quad sampled by the same tiny pipeline the
// macOS host's canvas presenter compiles (the render pass converts to the
// drawable's BGRA on the way out, so no CPU swizzle pass exists). A
// CADisplayLink pumps `native_sdk_app_frame` and the canvas revision from
// `native_sdk_app_gpu_frame_state` gates re-renders, so an idle app costs
// one ABI call per tick and acquires no drawable and uploads no bytes.
// The embed pixel ABI carries no damage rects (the desktop dirty-rect
// machinery lives behind the packet path, which mobile bypasses), so a
// changed frame re-renders and re-uploads the full surface — the gate is
// the revision, not a region. NATIVE_SDK_GPU_FRAME_TRACE=1 prints the
// same per-present/nil-drawable trace lines the macOS host does, plus a
// once-per-second structural summary (ticks, idle short-circuits,
// presents, drawables acquired, upload bytes, present-path CPU).
//
// Lifecycle follows the app's scene state the way the macOS host follows
// window occlusion: on entering the background the display link pauses
// (a backgrounded app presents nothing, and Metal work submitted from
// the background is killed by the watchdog); returning to the foreground
// resumes the pump and re-presents the retained canvas once even when
// the revision is unchanged, because the drawable pool may have been
// purged while covered — the mobile mirror of the macOS occlusion
// observer's glass flush. Resign/become-active additionally forward
// `native_sdk_app_deactivate`/`activate`, matching the Android host's
// onPause/onResume.
//
// Input: UITouch sequences forward through the ABI touch/scroll exports
// in the same point coordinate space the viewport export established
// (view points; the render scale multiplies pixels, not input). A
// touch-slop state machine mirrors UIScrollView's delayed content
// touches: an under-slop touch is a tap (pointer_down + pointer_up), an
// over-slop move over a scrollable widget pans it through the existing
// scroll reconciliation (`native_sdk_app_scroll` wheel deltas), and an
// over-slop move elsewhere becomes pointer_down + pointer_drag so sliders
// and text selection keep desktop semantics. Long-press is not modeled by
// the embed ABI, so the host does not synthesize one.
//
// The platform keyboard keys off `native_sdk_app_text_input_state`: while
// an editable text widget owns focus the canvas view holds UIKit first
// responder (system keyboard up); when focus leaves it resigns (keyboard
// down). Typed characters flow through `native_sdk_app_text` and marked
// text (UITextInput composition, dead keys, CJK) maps onto the same
// `native_sdk_app_ime` set/commit/cancel path the macOS host drives from
// NSTextInputClient — see appkit_host.m setMarkedText:/insertText:.
//
// Layout: the viewport export carries the view's safe-area insets, which
// the embed host republishes over the window-chrome channel — apps pad
// via `on_chrome` exactly as they do for the macOS titlebar band, and
// apps without the hook keep the automatic runtime inset.
//
// Text metrics: the host registers a CoreText-backed measure callback
// (`native_sdk_app_set_text_measure`) before start, mirroring the macOS
// host's `native_sdk_appkit_measure_text` — layout then uses real
// typographic widths instead of the deterministic estimator. Glyph
// RENDERING stays the reference renderer's shapes; only measurement
// changes. Launch with --estimator-text-metrics to keep the estimator
// (before/after comparisons, deterministic goldens).
//
// Audio: the host registers the platform audio service
// (`native_sdk_app_set_audio_service`) before start, mirroring the macOS
// AppKit host's player: one AVAudioPlayer for local files and verified
// cache entries, one AVPlayer for progressive URL streams (with a parallel
// NSURLSession download filling the track cache: part file, size-verified,
// atomic rename), ~500ms position ticks only while playing, and one
// completion at natural end — all reported back through
// `native_sdk_app_audio_event`. iOS additionally owns an audio session:
// category playback (configured at registration), activated on the first
// play, and system interruptions (a phone call, another app's exclusive
// audio) pause the player and report the paused state honestly through an
// immediate position event. Background audio and now-playing-center
// integration are out of scope for this host today.

#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <AVFoundation/AVFoundation.h>

#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdlib.h>

#include "native_sdk_app.h"

// Zig's std.debug stack-trace symbolication (pulled in by the embed lib's
// panic path) references `_dyld_get_image_header_containing_address`, which
// the iOS SDK marks __API_UNAVAILABLE(ios). Provide the documented
// replacement (dladdr) under the old symbol so the static lib links; it
// only runs while formatting a panic trace.
const struct mach_header *_dyld_get_image_header_containing_address(const void *address) {
    Dl_info info;
    if (dladdr(address, &info) != 0 && info.dli_fbase != NULL) {
        return (const struct mach_header *)info.dli_fbase;
    }
    return NULL;
}

// ---------------------------------------------------------------- frame trace

/* Frame-trace mode (NATIVE_SDK_GPU_FRAME_TRACE=1): the iOS mirror of the
 * macOS host's trace — one stderr line per REAL present naming how long
 * nextDrawable held the main thread and how many bytes the frame
 * uploaded, plus a once-per-second cumulative summary (display ticks,
 * idle short-circuits, presents, drawables acquired, upload bytes,
 * present-path CPU time). The summary is how the idle law shows up as a
 * number: an idle app's drawable/upload counters must not move. */
static BOOL NativeSdkGpuFrameTraceEnabled(void) {
    static BOOL enabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *value = getenv("NATIVE_SDK_GPU_FRAME_TRACE");
        enabled = value && value[0] != 0 && strcmp(value, "0") != 0;
    });
    return enabled;
}

static uint64_t NativeSdkTimestampNanoseconds(void) {
    return (uint64_t)([[NSDate date] timeIntervalSince1970] * 1000000000.0);
}

// ------------------------------------------------------------ text metrics

// Italicizes a resolved sans face for the reserved italic span font ids
// (5 and 6) — the iOS mirror of appkit_host.m's NativeSdkItalicSansFont.
// Prefers a real italic face from the same family via font descriptor
// traits (SF has one; Geist does not ship a sans italic) and falls back to
// a sheared descriptor matrix so a future draw path slants visibly. The
// shear leaves advance widths unchanged, so measurement matches the
// upright face either way.
static UIFont *NativeSdkItalicSansFont(UIFont *font) {
    if (!font) return nil;
    UIFontDescriptor *italic = [font.fontDescriptor fontDescriptorWithSymbolicTraits:
        (font.fontDescriptor.symbolicTraits | UIFontDescriptorTraitItalic)];
    if (italic) {
        UIFont *converted = [UIFont fontWithDescriptor:italic size:font.pointSize];
        if (converted && (converted.fontDescriptor.symbolicTraits & UIFontDescriptorTraitItalic) != 0) return converted;
    }
    UIFontDescriptor *oblique = [font.fontDescriptor fontDescriptorWithMatrix:CGAffineTransformMake(1, 0, 0.2, 1, 0, 0)];
    UIFont *sheared = oblique ? [UIFont fontWithDescriptor:oblique size:font.pointSize] : nil;
    return sheared ?: font;
}

// Resolves the weighted sans faces behind the reserved span font ids 3
// (medium) and 4/6 (bold) — the iOS mirror of appkit_host.m's
// NativeSdkWeightedSansFont: explicit weighted candidate names first
// (Geist Medium / Geist Bold when bundled), then the matching SF weight.
// Never answers with the regular face, so weighted span ids always measure
// (and will draw) heavier than regular.
static UIFont *NativeSdkWeightedSansFont(NSArray<NSString *> *names, UIFontWeight systemWeight, CGFloat size) {
    for (NSString *name in names) {
        UIFont *font = [UIFont fontWithName:name size:size];
        if (font) return font;
    }
    return [UIFont systemFontOfSize:size weight:systemWeight];
}

// Resolves a canvas font id to the UIFont measurement uses — the iOS
// mirror of appkit_host.m's NativeSdkFontForFontId (Geist when bundled,
// system fonts otherwise). Ids 3-6 are the reserved sans span variants
// (medium, bold, italic, bold italic); everything else keeps the regular
// sans/mono candidates. Resolved fonts are cached per (font id, size).
static UIFont *NativeSdkFontForFontId(uint64_t value, CGFloat size) {
    static NSCache<NSString *, UIFont *> *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 256;
    });
    NSString *key = [NSString stringWithFormat:@"%llu/%.3f", (unsigned long long)value, (double)size];
    UIFont *cached = [cache objectForKey:key];
    if (cached) return cached;
    UIFont *font = nil;
    if (value == 2) {
        NSArray<NSString *> *candidates = @[ @"Geist Mono", @"GeistMono-Regular", @"Geist Mono Regular" ];
        for (NSString *name in candidates) {
            font = [UIFont fontWithName:name size:size];
            if (font) break;
        }
        if (!font) font = [UIFont monospacedSystemFontOfSize:size weight:UIFontWeightRegular];
    } else {
        NSArray<NSString *> *candidates = @[ @"Geist", @"Geist-Regular", @"Geist Sans", @"Geist Sans Regular" ];
        UIFont *base = nil;
        for (NSString *name in candidates) {
            base = [UIFont fontWithName:name size:size];
            if (base) break;
        }
        if (!base) base = [UIFont systemFontOfSize:size];
        switch (value) {
        case 3:
            font = NativeSdkWeightedSansFont(@[ @"Geist-Medium", @"Geist Medium" ], UIFontWeightMedium, size);
            break;
        case 4:
            font = NativeSdkWeightedSansFont(@[ @"Geist-Bold", @"Geist Bold" ], UIFontWeightBold, size);
            break;
        case 5:
            font = NativeSdkItalicSansFont(base);
            break;
        case 6:
            font = NativeSdkItalicSansFont(NativeSdkWeightedSansFont(@[ @"Geist-Bold", @"Geist Bold" ], UIFontWeightBold, size));
            break;
        default:
            font = base;
            break;
        }
    }
    if (font) [cache setObject:font forKey:key];
    return font;
}

// CoreText-backed measure callback registered over the embed ABI: the
// typographic width of a single-line run, measured with the same font
// resolution and string-attribute metrics ([NSString sizeWithAttributes:])
// the macOS packet renderer draws with. Returns a negative value when the
// bytes are not valid UTF-8 so layout falls back to its estimator. Shaped
// widths are memoized shim-side.
static double NativeSdkMeasureText(void *context, uint64_t font_id, double size, const char *text, uintptr_t text_len) {
    (void)context;
    if (!text || text_len == 0) return 0;
    CGFloat clamped = MAX(1, size);
    @autoreleasepool {
        NSString *value = [[NSString alloc] initWithBytes:text length:text_len encoding:NSUTF8StringEncoding];
        if (!value) return -1;
        static NSCache<NSString *, NSNumber *> *widthCache = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            widthCache = [[NSCache alloc] init];
            widthCache.countLimit = 16384;
        });
        NSString *key = [NSString stringWithFormat:@"%llu/%.3f/%@", (unsigned long long)font_id, (double)clamped, value];
        NSNumber *cached = [widthCache objectForKey:key];
        if (cached) return cached.doubleValue;
        UIFont *font = NativeSdkFontForFontId(font_id, clamped);
        if (!font) return -1;
        double width = [value sizeWithAttributes:@{ NSFontAttributeName : font }].width;
        [widthCache setObject:@(width) forKey:key];
        return width;
    }
}

// --------------------------------------------------------------------- audio
//
// The platform audio player behind the embed audio service, ported from the
// macOS AppKit host (appkit_host.m, audio section) with the same contract:
// exactly one of audioPlayer/streamPlayer is non-nil, local files and
// verified cache hits play on AVAudioPlayer, URL sources stream on AVPlayer
// while a PARALLEL NSURLSession download fills the cache (a partially
// buffered stream must never masquerade as a cache entry), and every
// asynchronous report — the loaded acknowledgment with the real duration,
// ~500ms position ticks only while playing, buffering flips, exactly one
// completion, explicit failures — arrives through
// native_sdk_app_audio_event on the main thread. Every entry point is
// main-thread only; asynchronous sources (KVO, notifications, the download
// completion) hop to the main queue before touching player state, and the
// service callbacks never emit synchronously (the runtime is mid-dispatch
// when they run) — the local-file LOADED acknowledgment defers one loop
// turn exactly like the macOS host's.
//
// iOS divergences from the macOS implementation, all session-related:
// AVAudioSession gets the playback category at registration, is activated
// on the first play, and AVAudioSessionInterruptionNotification (began)
// pauses the transport and reports the paused state honestly through one
// immediate position event with playing=0 — an interruption is a
// platform-initiated pause the app did NOT command, so unlike app-driven
// pause it must echo. Interruption end never auto-resumes: the app (or the
// person holding the phone) decides.

/* KVO contexts for the streaming player, mirroring the macOS host: the
 * AVPlayerItem's status flip is the stream's loaded/failed report and the
 * AVPlayer's timeControlStatus is the honest buffering signal (waiting to
 * play at the requested rate IS buffering — un-paused, but silent). */
static void *NativeSdkStreamItemStatusContext = &NativeSdkStreamItemStatusContext;
static void *NativeSdkStreamTimeControlContext = &NativeSdkStreamTimeControlContext;

/* CMTime helpers without linking CoreMedia's conversion functions — the
 * struct and its flag constants are header-only, same trick as macOS. */
static double NativeSdkSecondsFromCMTime(CMTime time) {
    if ((time.flags & kCMTimeFlags_Valid) == 0) return 0.0;
    if ((time.flags & (kCMTimeFlags_Indefinite | kCMTimeFlags_PositiveInfinity | kCMTimeFlags_NegativeInfinity)) != 0) return 0.0;
    if (time.timescale == 0) return 0.0;
    return (double)time.value / (double)time.timescale;
}

static CMTime NativeSdkCMTimeFromMs(uint64_t ms) {
    CMTime time;
    time.value = (CMTimeValue)ms;
    time.timescale = 1000;
    time.flags = kCMTimeFlags_Valid;
    time.epoch = 0;
    return time;
}

@interface NativeSdkAudioEngine : NSObject <AVAudioPlayerDelegate>
@property(nonatomic) void *nativeApp;
/* The app's single local-file player and the shared position-tick timer. */
@property(nonatomic, strong) AVAudioPlayer *audioPlayer;
@property(nonatomic, strong) NSTimer *audioPositionTimer;
/* URL sources ride AVPlayer: progressive playback starts while bytes are
 * still arriving, and seek/volume keep working mid-stream. */
@property(nonatomic, strong) AVPlayer *streamPlayer;
@property(nonatomic, strong) AVPlayerItem *streamItem;
@property(nonatomic) BOOL streamObservingStatus;
@property(nonatomic) BOOL streamLoadedEmitted;
/* The honest buffering mirror emitted with every audio event: YES from
 * stream start until playback actually rolls, then tracks
 * timeControlStatus. */
@property(nonatomic) BOOL streamBuffering;
@property(nonatomic, strong) id streamEndObserver;
@property(nonatomic, strong) id streamFailObserver;
@property(nonatomic, strong) NSURLSessionDownloadTask *audioCacheDownload;
/* Session state: the playback category is set once at engine creation;
 * activation is deferred to the first play so a silent app never claims
 * the audio route. */
@property(nonatomic) BOOL sessionActivated;
@property(nonatomic, strong) id interruptionObserver;
@end

@implementation NativeSdkAudioEngine

- (instancetype)init {
    if ((self = [super init])) {
        /* Playback category: honest foreground media playback (respects
         * neither the ring/silent switch nor other apps' audio — the
         * category for music, matching what fx.playAudio promises). No
         * background modes: playback pauses with the app, and that limit
         * is documented rather than papered over. */
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
        __weak NativeSdkAudioEngine *weakSelf = self;
        self.interruptionObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:AVAudioSessionInterruptionNotification
                        object:[AVAudioSession sharedInstance]
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
                        [weakSelf handleSessionInterruption:note];
                    }];
    }
    return self;
}

- (void)invalidate {
    [self audioStop];
    if (self.interruptionObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.interruptionObserver];
        self.interruptionObserver = nil;
    }
    self.nativeApp = NULL;
}

- (void)dealloc {
    [self invalidate];
}

/* The system took the audio route (phone call, alarm, another app's
 * exclusive session): both player kinds are already silenced by the OS,
 * so make the transport state match — pause explicitly, stop the tick
 * timer, and report the paused state NOW through one position event.
 * This is the one pause that must echo: the app did not command it.
 * Interruption end deliberately does not auto-resume. */
- (void)handleSessionInterruption:(NSNotification *)note {
    NSUInteger type = [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    if (type != AVAudioSessionInterruptionTypeBegan) return;
    if (!self.audioPlayer && !self.streamPlayer) return;
    [self.audioPlayer pause];
    [self.streamPlayer pause];
    self.sessionActivated = NO;
    [self stopAudioPositionTimer];
    [self emitAudioEventOfKind:NATIVE_SDK_AUDIO_EVENT_POSITION];
}

/* Emit one audio report carrying the live position/duration readout of
 * whichever player is active. Main thread only. */
- (void)emitAudioEventOfKind:(int)kind {
    if (!self.nativeApp) return;
    AVAudioPlayer *player = self.audioPlayer;
    AVPlayer *stream = self.streamPlayer;
    uint64_t position_ms = 0;
    uint64_t duration_ms = 0;
    int playing = 0;
    int buffering = 0;
    if (player) {
        NSTimeInterval position = player.currentTime;
        NSTimeInterval duration = player.duration;
        if (position > 0) position_ms = (uint64_t)llround(position * 1000.0);
        if (duration > 0) duration_ms = (uint64_t)llround(duration * 1000.0);
        playing = player.isPlaying ? 1 : 0;
    } else if (stream) {
        double position = NativeSdkSecondsFromCMTime(stream.currentTime);
        double duration = self.streamItem ? NativeSdkSecondsFromCMTime(self.streamItem.duration) : 0.0;
        if (position > 0) position_ms = (uint64_t)llround(position * 1000.0);
        if (duration > 0) duration_ms = (uint64_t)llround(duration * 1000.0);
        /* rate > 0 is the transport intent (un-paused); the buffering
         * flag beside it says whether audio is actually coming out. */
        playing = stream.rate > 0 ? 1 : 0;
        buffering = self.streamBuffering ? 1 : 0;
    }
    if (kind == NATIVE_SDK_AUDIO_EVENT_COMPLETED) {
        /* A finished player rewinds itself to zero; report the honest
         * terminal position instead. */
        position_ms = duration_ms;
        playing = 0;
        buffering = 0;
    }
    native_sdk_app_audio_event(self.nativeApp, kind, position_ms, duration_ms, playing, buffering);
}

- (void)stopAudioPositionTimer {
    [self.audioPositionTimer invalidate];
    self.audioPositionTimer = nil;
}

- (void)audioPositionTimerFired:(NSTimer *)timer {
    (void)timer;
    if (!self.audioPlayer && !self.streamPlayer) {
        [self stopAudioPositionTimer];
        return;
    }
    [self emitAudioEventOfKind:NATIVE_SDK_AUDIO_EVENT_POSITION];
}

- (int)audioLoadPath:(NSString *)path {
    [self audioStop];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return 1;
    NSError *error = nil;
    AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path]
                                                                   error:&error];
    if (!player || error) return 2;
    player.delegate = self;
    if (![player prepareToPlay]) return 2;
    self.audioPlayer = player;
    /* The LOADED acknowledgment is asynchronous by contract: emitting it
     * inside this service call would re-enter the runtime while it is
     * still dispatching the command that asked for the load. Next loop
     * turn, and only if this player is still the loaded one. */
    __weak NativeSdkAudioEngine *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        NativeSdkAudioEngine *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.audioPlayer != player) return;
        [strongSelf emitAudioEventOfKind:NATIVE_SDK_AUDIO_EVENT_LOADED];
    });
    return 0;
}

/* URL sources: verified cache entry first (plays as a plain local file,
 * no network), then a progressive AVPlayer stream with a parallel
 * cache-filling download. Returns 1 for the cache hit, 0 for a started
 * stream, 2 when the URL cannot be parsed; everything asynchronous —
 * readiness, stalls, natural end, network death — arrives as audio
 * events. */
- (int)audioLoadURL:(NSString *)urlString cachePath:(NSString *)cachePath expectedBytes:(uint64_t)expectedBytes {
    [self audioStop];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url || !url.scheme) return 2;
    if (cachePath.length > 0) {
        NSFileManager *manager = [NSFileManager defaultManager];
        NSDictionary *attributes = [manager attributesOfItemAtPath:cachePath error:nil];
        if (attributes) {
            unsigned long long size = [attributes fileSize];
            if (expectedBytes == 0 || size == (unsigned long long)expectedBytes) {
                if ([self audioLoadPath:cachePath] == 0) return 1;
                /* An entry with the right size that will not decode is
                 * corrupt — fall through to discard and re-stream. */
            }
            /* Partial, stale, or corrupt: a bad cache entry never plays,
             * and never survives to fool the next lookup. */
            [manager removeItemAtPath:cachePath error:nil];
        }
    }
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    AVPlayer *player = [AVPlayer playerWithPlayerItem:item];
    /* The default stall policy: start as soon as sustained playback is
     * likely, keep rolling through short gaps. Stated explicitly because
     * immediate progressive start is the contract here. */
    player.automaticallyWaitsToMinimizeStalling = YES;
    self.streamItem = item;
    self.streamPlayer = player;
    self.streamBuffering = YES;
    self.streamLoadedEmitted = NO;
    [item addObserver:self
           forKeyPath:@"status"
              options:NSKeyValueObservingOptionNew
              context:NativeSdkStreamItemStatusContext];
    [player addObserver:self
             forKeyPath:@"timeControlStatus"
                options:NSKeyValueObservingOptionNew
                context:NativeSdkStreamTimeControlContext];
    self.streamObservingStatus = YES;
    __weak NativeSdkAudioEngine *weakSelf = self;
    self.streamEndObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                    object:item
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
                    (void)note;
                    [weakSelf streamDidPlayToEnd];
                }];
    self.streamFailObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:AVPlayerItemFailedToPlayToEndTimeNotification
                    object:item
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
                    (void)note;
                    [weakSelf streamDidFail];
                }];
    if (cachePath.length > 0) {
        [self startAudioCacheDownloadFrom:url toPath:cachePath expectedBytes:expectedBytes];
    }
    return 0;
}

/* The cache fill is a PARALLEL download, not a tee off the player's own
 * connection: an AVAssetResourceLoader tee needs a custom URL scheme plus
 * a hand-rolled range-request server, and a partially buffered stream
 * must never masquerade as a cache entry. One extra request on a track's
 * first (uncached) play buys a stock streaming path and a cache whose
 * entries are whole files by construction: downloaded beside the final
 * name, size-verified against the manifest, and renamed into place — a
 * same-directory rename, so a partial file never occupies the cache name
 * even across a crash. */
- (void)startAudioCacheDownloadFrom:(NSURL *)url toPath:(NSString *)cachePath expectedBytes:(uint64_t)expectedBytes {
    NSURLSessionDownloadTask *task = [[NSURLSession sharedSession]
        downloadTaskWithURL:url
          completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
              /* Background queue: file moves only, no engine state. A
               * failed or cancelled download simply leaves no cache
               * entry — the next play streams again. */
              if (error || !location) return;
              if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                  NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
                  if (status != 200) return;
              }
              NSFileManager *manager = [NSFileManager defaultManager];
              NSString *directory = [cachePath stringByDeletingLastPathComponent];
              [manager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
              NSString *partPath = [cachePath stringByAppendingPathExtension:@"part"];
              [manager removeItemAtPath:partPath error:nil];
              if (![manager moveItemAtURL:location toURL:[NSURL fileURLWithPath:partPath] error:nil]) return;
              NSDictionary *attributes = [manager attributesOfItemAtPath:partPath error:nil];
              unsigned long long size = attributes ? [attributes fileSize] : 0;
              if (expectedBytes != 0 && size != (unsigned long long)expectedBytes) {
                  /* Truncated or wrong content: never installed. */
                  [manager removeItemAtPath:partPath error:nil];
                  return;
              }
              [manager removeItemAtPath:cachePath error:nil];
              [manager moveItemAtPath:partPath toPath:cachePath error:nil];
          }];
    self.audioCacheDownload = task;
    [task resume];
}

/* Release the stream player and its observers. The download is cancelled
 * when a new load replaces the stream mid-flight (a skipped track should
 * not keep burning bandwidth) but ORPHANED on natural completion — it is
 * usually already done, and letting a straggler finish installs the
 * cache entry the completed play earned. */
- (void)audioTearDownStreamCancellingDownload:(BOOL)cancelDownload {
    AVPlayerItem *item = self.streamItem;
    AVPlayer *player = self.streamPlayer;
    if (self.streamObservingStatus) {
        [item removeObserver:self forKeyPath:@"status" context:NativeSdkStreamItemStatusContext];
        [player removeObserver:self forKeyPath:@"timeControlStatus" context:NativeSdkStreamTimeControlContext];
        self.streamObservingStatus = NO;
    }
    if (self.streamEndObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.streamEndObserver];
        self.streamEndObserver = nil;
    }
    if (self.streamFailObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.streamFailObserver];
        self.streamFailObserver = nil;
    }
    [player pause];
    self.streamItem = nil;
    self.streamPlayer = nil;
    self.streamBuffering = NO;
    self.streamLoadedEmitted = NO;
    if (cancelDownload) [self.audioCacheDownload cancel];
    self.audioCacheDownload = nil;
}

/* Item status flipped (main queue, hopped from KVO): readyToPlay is the
 * stream's LOADED acknowledgment — the duration is decoded and playback
 * is rolling or about to; failed is the honest terminal report for an
 * unreachable host or an undecodable payload. */
- (void)streamItemStatusChanged {
    AVPlayerItem *item = self.streamItem;
    if (!item) return;
    if (item.status == AVPlayerItemStatusReadyToPlay) {
        if (self.streamLoadedEmitted) return;
        self.streamLoadedEmitted = YES;
        [self emitAudioEventOfKind:NATIVE_SDK_AUDIO_EVENT_LOADED];
        return;
    }
    if (item.status == AVPlayerItemStatusFailed) {
        [self streamDidFail];
    }
}

/* timeControlStatus flipped (main queue, hopped from KVO): waiting to
 * play at the requested rate IS buffering. Emit the transition
 * immediately as a position report so the UI flips its buffering state
 * now, not at the next 500ms tick. */
- (void)streamTimeControlChanged {
    AVPlayer *player = self.streamPlayer;
    if (!player) return;
    BOOL buffering = player.timeControlStatus == AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate;
    if (buffering == self.streamBuffering) return;
    self.streamBuffering = buffering;
    [self emitAudioEventOfKind:NATIVE_SDK_AUDIO_EVENT_POSITION];
}

/* Natural end of a streamed track. Same retire-before-emit discipline as
 * the AVAudioPlayer delegate below: the completion Msg routinely starts
 * the NEXT track from inside its own dispatch, and tearing down
 * afterwards would destroy the player that load just installed. The
 * duration is captured first so the event still carries the honest
 * terminal position. */
- (void)streamDidPlayToEnd {
    if (!self.streamPlayer) return;
    [self stopAudioPositionTimer];
    uint64_t duration_ms = 0;
    if (self.streamItem) {
        double duration = NativeSdkSecondsFromCMTime(self.streamItem.duration);
        if (duration > 0) duration_ms = (uint64_t)llround(duration * 1000.0);
    }
    [self audioTearDownStreamCancellingDownload:NO];
    if (self.nativeApp) {
        native_sdk_app_audio_event(self.nativeApp, NATIVE_SDK_AUDIO_EVENT_COMPLETED, duration_ms, duration_ms, 0, 0);
    }
}

/* A stream died mid-flight (network loss, server reset, undecodable
 * bytes) or never became playable (offline with a cold cache): one
 * FAILED event, player retired first. The cache download is cancelled
 * too — bytes from a failing source are not trustworthy. */
- (void)streamDidFail {
    if (!self.streamPlayer) return;
    [self stopAudioPositionTimer];
    [self audioTearDownStreamCancellingDownload:YES];
    if (self.nativeApp) {
        native_sdk_app_audio_event(self.nativeApp, NATIVE_SDK_AUDIO_EVENT_FAILED, 0, 0, 0, 0);
    }
}

/* First play activates the audio session (deferred from init so a silent
 * app never claims the route); re-activation after an interruption is
 * the same call. Activation failure is not fatal — playback proceeds and
 * the OS arbitrates. */
- (void)activateSessionForPlayback {
    if (self.sessionActivated) return;
    self.sessionActivated = [[AVAudioSession sharedInstance] setActive:YES error:nil];
}

- (int)audioPlay {
    [self activateSessionForPlayback];
    if (self.streamPlayer) {
        /* AVPlayer's play is asynchronous by nature (it starts when
         * buffered bytes allow), so a stream's play always "applies" —
         * readiness and stalls report through the event stream. */
        [self.streamPlayer play];
    } else {
        AVAudioPlayer *player = self.audioPlayer;
        if (!player) return 0;
        if (![player play]) return 0;
    }
    if (!self.audioPositionTimer) {
        /* Common modes so the readout keeps ticking while UIKit tracks a
         * touch (UITrackingRunLoopMode) — the mobile mirror of macOS
         * keeping ticks alive through menus and live-resize. */
        NSTimer *tick = [NSTimer timerWithTimeInterval:0.5
                                                target:self
                                              selector:@selector(audioPositionTimerFired:)
                                              userInfo:nil
                                               repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:tick forMode:NSRunLoopCommonModes];
        self.audioPositionTimer = tick;
    }
    return 1;
}

- (int)audioPause {
    if (self.streamPlayer) {
        [self.streamPlayer pause];
        [self stopAudioPositionTimer];
        return 1;
    }
    AVAudioPlayer *player = self.audioPlayer;
    if (!player) return 0;
    [player pause];
    [self stopAudioPositionTimer];
    return 1;
}

- (int)audioStop {
    [self stopAudioPositionTimer];
    if (self.streamPlayer) {
        /* Replacement or explicit stop mid-stream: the cache download
         * dies with the playback — a skipped track should not keep
         * burning bandwidth (its next play streams and fills again). */
        [self audioTearDownStreamCancellingDownload:YES];
        return 1;
    }
    AVAudioPlayer *player = self.audioPlayer;
    if (!player) return 0;
    player.delegate = nil;
    [player stop];
    self.audioPlayer = nil;
    return 1;
}

- (int)audioSeekToMs:(uint64_t)positionMs {
    if (self.streamPlayer) {
        /* Mid-stream seek: AVPlayer clamps to the seekable ranges it has
         * (or fetches the range it needs); exact tolerance keeps the
         * readout honest against the requested position. */
        CMTime zero = NativeSdkCMTimeFromMs(0);
        [self.streamPlayer seekToTime:NativeSdkCMTimeFromMs(positionMs)
                      toleranceBefore:zero
                       toleranceAfter:zero];
        return 1;
    }
    AVAudioPlayer *player = self.audioPlayer;
    if (!player) return 0;
    NSTimeInterval target = (NSTimeInterval)positionMs / 1000.0;
    if (target > player.duration) target = player.duration;
    player.currentTime = target;
    return 1;
}

- (int)audioSetVolume:(double)volume {
    if (self.streamPlayer) {
        self.streamPlayer.volume = (float)volume;
        return 1;
    }
    AVAudioPlayer *player = self.audioPlayer;
    if (!player) return 0;
    player.volume = (float)volume;
    return 1;
}

/* AVPlayer/AVPlayerItem KVO can fire on background threads (and
 * synchronously inside a service call); every entry point above is
 * main-thread, between-runtime-turns only, so hop before touching player
 * state or emitting. */
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey, id> *)change context:(void *)context {
    if (context == NativeSdkStreamItemStatusContext) {
        __weak NativeSdkAudioEngine *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf streamItemStatusChanged];
        });
        return;
    }
    if (context == NativeSdkStreamTimeControlContext) {
        __weak NativeSdkAudioEngine *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf streamTimeControlChanged];
        });
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

/* AVAudioPlayerDelegate: natural end of the track. `flag` is NO when
 * playback died on a decode error mid-file — report that honestly as a
 * failure, never as a completion. The finished player is retired BEFORE
 * the event is emitted: the completion Msg routinely starts the NEXT
 * track from inside its own dispatch (a music app auto-advancing), and
 * retiring afterwards would destroy the player that load just installed. */
- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    if (player != self.audioPlayer) return;
    [self stopAudioPositionTimer];
    uint64_t duration_ms = 0;
    if (player.duration > 0) duration_ms = (uint64_t)llround(player.duration * 1000.0);
    player.delegate = nil;
    self.audioPlayer = nil;
    if (self.nativeApp) {
        native_sdk_app_audio_event(self.nativeApp,
                                   flag ? NATIVE_SDK_AUDIO_EVENT_COMPLETED : NATIVE_SDK_AUDIO_EVENT_FAILED,
                                   flag ? duration_ms : 0,
                                   duration_ms,
                                   0,
                                   0);
    }
}

- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer *)player error:(NSError *)error {
    (void)error;
    if (player != self.audioPlayer) return;
    [self stopAudioPositionTimer];
    player.delegate = nil;
    self.audioPlayer = nil;
    [self emitAudioEventOfKind:NATIVE_SDK_AUDIO_EVENT_FAILED];
}

@end

// The C callback table registered through native_sdk_app_set_audio_service;
// context is the (view-controller-retained) engine. These run INSIDE
// runtime dispatch on the main thread — they mutate player state and
// return synchronously, and every report the calls provoke is emitted on a
// later run-loop turn.

static int NativeSdkAudioServiceLoad(void *context, const char *path, uintptr_t path_len) {
    NativeSdkAudioEngine *engine = (__bridge NativeSdkAudioEngine *)context;
    NSString *value = [[NSString alloc] initWithBytes:path length:path_len encoding:NSUTF8StringEncoding];
    if (!value) return 1;
    return [engine audioLoadPath:value];
}

static int NativeSdkAudioServiceLoadUrl(void *context, const char *url, uintptr_t url_len, const char *cache_path, uintptr_t cache_path_len, uint64_t expected_bytes) {
    NativeSdkAudioEngine *engine = (__bridge NativeSdkAudioEngine *)context;
    NSString *urlValue = [[NSString alloc] initWithBytes:url length:url_len encoding:NSUTF8StringEncoding];
    if (!urlValue) return 2;
    NSString *cacheValue = @"";
    if (cache_path && cache_path_len > 0) {
        cacheValue = [[NSString alloc] initWithBytes:cache_path length:cache_path_len encoding:NSUTF8StringEncoding] ?: @"";
    }
    return [engine audioLoadURL:urlValue cachePath:cacheValue expectedBytes:expected_bytes];
}

static int NativeSdkAudioServicePlay(void *context) {
    return [(__bridge NativeSdkAudioEngine *)context audioPlay];
}

static int NativeSdkAudioServicePause(void *context) {
    return [(__bridge NativeSdkAudioEngine *)context audioPause];
}

static int NativeSdkAudioServiceStop(void *context) {
    return [(__bridge NativeSdkAudioEngine *)context audioStop];
}

static int NativeSdkAudioServiceSeek(void *context, uint64_t position_ms) {
    return [(__bridge NativeSdkAudioEngine *)context audioSeekToMs:position_ms];
}

static int NativeSdkAudioServiceSetVolume(void *context, double volume) {
    return [(__bridge NativeSdkAudioEngine *)context audioSetVolume:volume];
}

// ---------------------------------------------------------------- UITextInput
// Index-based position/range objects over the local marked-text store (the
// "document" the system IME edits is the composition only, matching the
// macOS host's NSTextInputClient implementation).

@interface NativeSdkTextPosition : UITextPosition
@property(nonatomic) NSInteger index;
+ (instancetype)positionWithIndex:(NSInteger)index;
@end

@implementation NativeSdkTextPosition
+ (instancetype)positionWithIndex:(NSInteger)index {
    NativeSdkTextPosition *position = [[self alloc] init];
    position.index = index;
    return position;
}
@end

@interface NativeSdkTextRange : UITextRange
@property(nonatomic) NSInteger location;
@property(nonatomic) NSInteger length;
+ (instancetype)rangeWithLocation:(NSInteger)location length:(NSInteger)length;
@end

@implementation NativeSdkTextRange
+ (instancetype)rangeWithLocation:(NSInteger)location length:(NSInteger)length {
    NativeSdkTextRange *range = [[self alloc] init];
    range.location = location;
    range.length = length;
    return range;
}
- (BOOL)isEmpty {
    return self.length == 0;
}
- (UITextPosition *)start {
    return [NativeSdkTextPosition positionWithIndex:self.location];
}
- (UITextPosition *)end {
    return [NativeSdkTextPosition positionWithIndex:self.location + self.length];
}
@end

typedef NS_ENUM(NSInteger, NativeSdkTouchMode) {
    NativeSdkTouchModeIdle = 0,
    // Touch down seen, under slop: undecided between tap / drag / scroll.
    NativeSdkTouchModePending,
    // Over slop on a scrollable widget: forwarding wheel scroll deltas.
    NativeSdkTouchModeScrolling,
    // Over slop elsewhere: forwarded pointer_down, forwarding pointer_drag.
    NativeSdkTouchModeDragging,
};

static const CGFloat NativeSdkTouchSlop = 8.0;

@interface NativeSdkCanvasView : UIView <UIKeyInput, UITextInput>
@property(nonatomic) void *nativeApp;
@property(nonatomic, weak) UITouch *trackedTouch;
@property(nonatomic) NativeSdkTouchMode touchMode;
@property(nonatomic) CGPoint touchStartPoint;
@property(nonatomic) CGPoint touchLastPoint;
@property(nonatomic) uint64_t touchSequence;
@property(nonatomic, copy) NSString *markedText;
@property(nonatomic) NSRange markedSelectedRange;
@property(nonatomic) uint64_t focusedTextWidget;
@property(nonatomic, copy) NSDictionary<NSAttributedStringKey, id> *markedTextStyle;
@property(nonatomic, weak) id<UITextInputDelegate> inputDelegate;
@end

@implementation NativeSdkCanvasView

+ (Class)layerClass {
    return [CAMetalLayer class];
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _markedText = @"";
        _markedSelectedRange = NSMakeRange(NSNotFound, 0);
        self.multipleTouchEnabled = NO;
    }
    return self;
}

- (BOOL)canBecomeFirstResponder {
    return YES;
}

// ------------------------------------------------------------------- touch

- (void)forwardTouchPhase:(int)phase point:(CGPoint)point pressure:(float)pressure {
    if (!self.nativeApp) return;
    native_sdk_app_touch(self.nativeApp, self.touchSequence, phase, (float)point.x, (float)point.y, pressure);
}

// True when an overflowing scrollable widget's bounds contain the point —
// the pan-to-scroll decision UIScrollView makes with delayed content
// touches, taken from the semantics export instead of a native hierarchy.
- (BOOL)scrollableWidgetAtPoint:(CGPoint)point {
    if (!self.nativeApp) return NO;
    uintptr_t count = native_sdk_app_widget_semantics_count(self.nativeApp);
    for (uintptr_t index = 0; index < count; index++) {
        native_sdk_widget_semantics_t node = {0};
        if (native_sdk_app_widget_semantics_at(self.nativeApp, index, &node) != 1) continue;
        if (!node.has_scroll) continue;
        if (node.scroll_content_extent <= node.scroll_viewport_extent) continue;
        if (point.x < node.x || point.x > node.x + node.width) continue;
        if (point.y < node.y || point.y > node.y + node.height) continue;
        return YES;
    }
    return NO;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.trackedTouch) return;
    UITouch *touch = touches.anyObject;
    self.trackedTouch = touch;
    self.touchSequence += 1;
    self.touchMode = NativeSdkTouchModePending;
    self.touchStartPoint = [touch locationInView:self];
    self.touchLastPoint = self.touchStartPoint;
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!self.trackedTouch || ![touches containsObject:self.trackedTouch]) return;
    CGPoint point = [self.trackedTouch locationInView:self];

    if (self.touchMode == NativeSdkTouchModePending) {
        CGFloat dx = point.x - self.touchStartPoint.x;
        CGFloat dy = point.y - self.touchStartPoint.y;
        if (dx * dx + dy * dy < NativeSdkTouchSlop * NativeSdkTouchSlop) return;
        if ([self scrollableWidgetAtPoint:self.touchStartPoint]) {
            self.touchMode = NativeSdkTouchModeScrolling;
        } else {
            self.touchMode = NativeSdkTouchModeDragging;
            [self forwardTouchPhase:NATIVE_SDK_TOUCH_PHASE_DOWN point:self.touchStartPoint pressure:1];
        }
    }

    if (self.touchMode == NativeSdkTouchModeScrolling) {
        // Natural scrolling: finger up moves content up = offset grows, so
        // the wheel delta is the negated finger delta.
        float deltaX = (float)(self.touchLastPoint.x - point.x);
        float deltaY = (float)(self.touchLastPoint.y - point.y);
        if (self.nativeApp && (deltaX != 0 || deltaY != 0)) {
            native_sdk_app_scroll(self.nativeApp, self.touchSequence, (float)point.x, (float)point.y, deltaX, deltaY);
        }
    } else if (self.touchMode == NativeSdkTouchModeDragging) {
        [self forwardTouchPhase:NATIVE_SDK_TOUCH_PHASE_DRAG point:point pressure:1];
    }
    self.touchLastPoint = point;
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!self.trackedTouch || ![touches containsObject:self.trackedTouch]) return;
    CGPoint point = [self.trackedTouch locationInView:self];
    switch (self.touchMode) {
        case NativeSdkTouchModePending:
            // Under-slop touch: a tap at the start point.
            [self forwardTouchPhase:NATIVE_SDK_TOUCH_PHASE_DOWN point:self.touchStartPoint pressure:1];
            [self forwardTouchPhase:NATIVE_SDK_TOUCH_PHASE_UP point:self.touchStartPoint pressure:0];
            break;
        case NativeSdkTouchModeDragging:
            [self forwardTouchPhase:NATIVE_SDK_TOUCH_PHASE_UP point:point pressure:0];
            break;
        default:
            break;
    }
    [self resetTouchTracking];
    [self syncTextInput];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!self.trackedTouch || ![touches containsObject:self.trackedTouch]) return;
    if (self.touchMode == NativeSdkTouchModeDragging) {
        [self forwardTouchPhase:NATIVE_SDK_TOUCH_PHASE_CANCEL point:self.touchLastPoint pressure:0];
    }
    [self resetTouchTracking];
    [self syncTextInput];
}

- (void)resetTouchTracking {
    self.trackedTouch = nil;
    self.touchMode = NativeSdkTouchModeIdle;
}

// ------------------------------------------------- keyboard <-> focus sync

// Reconcile UIKit first responder with the runtime's focus/IME-intent
// state: keyboard up while an editable text widget owns focus, down when
// focus leaves. Called after every dispatched input and once per display
// tick (focus can also move from key handling or model updates).
- (void)syncTextInput {
    if (!self.nativeApp || !self.window) return;
    native_sdk_text_input_state_t state = {0};
    if (native_sdk_app_text_input_state(self.nativeApp, &state) != 1) return;
    if (state.active) {
        if (state.widget_id != self.focusedTextWidget) {
            self.focusedTextWidget = state.widget_id;
            [self clearMarkedTextState];
        }
        if (!self.isFirstResponder) [self becomeFirstResponder];
    } else {
        self.focusedTextWidget = 0;
        if (self.isFirstResponder) {
            [self clearMarkedTextState];
            [self resignFirstResponder];
        }
    }
}

- (void)clearMarkedTextState {
    self.markedText = @"";
    self.markedSelectedRange = NSMakeRange(NSNotFound, 0);
}

- (void)emitKeyDownUp:(NSString *)key {
    if (!self.nativeApp) return;
    const char *bytes = key.UTF8String ?: "";
    uintptr_t length = [key lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    native_sdk_app_key(self.nativeApp, NATIVE_SDK_KEY_PHASE_DOWN, bytes, length, "", 0, 0);
    native_sdk_app_key(self.nativeApp, NATIVE_SDK_KEY_PHASE_UP, bytes, length, "", 0, 0);
}

- (void)emitImeEvent:(int)kind text:(NSString *)text cursor:(intptr_t)cursor {
    if (!self.nativeApp) return;
    NSString *value = text ?: @"";
    native_sdk_app_ime(self.nativeApp,
                        kind,
                        value.UTF8String ?: "",
                        [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
                        cursor);
}

// -------------------------------------------------------------- UIKeyInput

- (BOOL)hasText {
    if (!self.nativeApp || self.focusedTextWidget == 0) return self.markedText.length > 0;
    native_sdk_widget_semantics_t node = {0};
    if (native_sdk_app_widget_semantics_by_id(self.nativeApp, self.focusedTextWidget, &node) != 1) return NO;
    return node.text_len > 0;
}

// Mirrors appkit_host.m insertText: committing identical marked text maps
// to commit_composition; divergent marked text cancels before the plain
// text insert so the runtime never double-applies the composition.
- (void)insertText:(NSString *)text {
    if (text.length == 0) return;
    if ([text isEqualToString:@"\n"]) {
        BOOL hadMarkedText = self.markedText.length > 0;
        [self clearMarkedTextState];
        if (hadMarkedText) {
            [self emitImeEvent:NATIVE_SDK_IME_COMMIT_COMPOSITION text:@"" cursor:-1];
        }
        [self emitKeyDownUp:@"enter"];
        [self syncTextInput];
        return;
    }

    BOOL hadMarkedText = self.markedText.length > 0;
    NSString *previousMarkedText = self.markedText;
    [self clearMarkedTextState];

    if (hadMarkedText && [previousMarkedText isEqualToString:text]) {
        [self emitImeEvent:NATIVE_SDK_IME_COMMIT_COMPOSITION text:@"" cursor:-1];
        return;
    }
    if (hadMarkedText) {
        [self emitImeEvent:NATIVE_SDK_IME_CANCEL_COMPOSITION text:@"" cursor:-1];
    }
    if (self.nativeApp) {
        native_sdk_app_text(self.nativeApp,
                             text.UTF8String ?: "",
                             [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
    }
}

- (void)deleteBackward {
    if (self.markedText.length > 0) {
        [self clearMarkedTextState];
        [self emitImeEvent:NATIVE_SDK_IME_CANCEL_COMPOSITION text:@"" cursor:-1];
        return;
    }
    [self emitKeyDownUp:@"backspace"];
}

// ------------------------------------------------------------- UITextInput

- (NSString *)textInRange:(UITextRange *)range {
    NativeSdkTextRange *value = (NativeSdkTextRange *)range;
    if (!value || value.location < 0) return @"";
    NSInteger max = (NSInteger)self.markedText.length;
    NSInteger location = MIN(value.location, max);
    NSInteger length = MIN(value.length, max - location);
    return [self.markedText substringWithRange:NSMakeRange(location, length)];
}

- (void)replaceRange:(UITextRange *)range withText:(NSString *)text {
    (void)range;
    [self insertText:text];
}

- (UITextRange *)selectedTextRange {
    NSInteger caret = (NSInteger)self.markedText.length;
    if (self.markedSelectedRange.location != NSNotFound) {
        caret = MIN((NSInteger)(self.markedSelectedRange.location + self.markedSelectedRange.length), caret);
    }
    return [NativeSdkTextRange rangeWithLocation:caret length:0];
}

- (void)setSelectedTextRange:(UITextRange *)range {
    NativeSdkTextRange *value = (NativeSdkTextRange *)range;
    if (!value) return;
    self.markedSelectedRange = NSMakeRange(MAX(0, value.location), MAX(0, value.length));
}

- (UITextRange *)markedTextRange {
    if (self.markedText.length == 0) return nil;
    return [NativeSdkTextRange rangeWithLocation:0 length:(NSInteger)self.markedText.length];
}

// Marked text is the live composition: forward it (with the caret as a
// UTF-8 byte offset) through the same set_composition path the desktop
// hosts use, so dead keys and multi-stage IMEs stay correct.
- (void)setMarkedText:(NSString *)markedText selectedRange:(NSRange)selectedRange {
    NSString *text = markedText ?: @"";
    BOOL hadMarkedText = self.markedText.length > 0;
    if (text.length == 0) {
        [self clearMarkedTextState];
        if (hadMarkedText) {
            [self emitImeEvent:NATIVE_SDK_IME_CANCEL_COMPOSITION text:@"" cursor:-1];
        }
        return;
    }

    NSUInteger cursor = text.length;
    if (selectedRange.location != NSNotFound) {
        cursor = MIN(text.length, selectedRange.location + selectedRange.length);
        self.markedSelectedRange = selectedRange;
    } else {
        self.markedSelectedRange = NSMakeRange(text.length, 0);
    }
    self.markedText = text;
    intptr_t cursorBytes = (intptr_t)[[text substringToIndex:cursor] lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    [self emitImeEvent:NATIVE_SDK_IME_SET_COMPOSITION text:text cursor:cursorBytes];
}

- (void)unmarkText {
    BOOL hadMarkedText = self.markedText.length > 0;
    [self clearMarkedTextState];
    if (hadMarkedText) {
        [self emitImeEvent:NATIVE_SDK_IME_COMMIT_COMPOSITION text:@"" cursor:-1];
    }
}

- (UITextPosition *)beginningOfDocument {
    return [NativeSdkTextPosition positionWithIndex:0];
}

- (UITextPosition *)endOfDocument {
    return [NativeSdkTextPosition positionWithIndex:(NSInteger)self.markedText.length];
}

- (UITextRange *)textRangeFromPosition:(UITextPosition *)fromPosition toPosition:(UITextPosition *)toPosition {
    NSInteger from = ((NativeSdkTextPosition *)fromPosition).index;
    NSInteger to = ((NativeSdkTextPosition *)toPosition).index;
    return [NativeSdkTextRange rangeWithLocation:MIN(from, to) length:ABS(to - from)];
}

- (UITextPosition *)positionFromPosition:(UITextPosition *)position offset:(NSInteger)offset {
    NSInteger index = ((NativeSdkTextPosition *)position).index + offset;
    if (index < 0 || index > (NSInteger)self.markedText.length) return nil;
    return [NativeSdkTextPosition positionWithIndex:index];
}

- (UITextPosition *)positionFromPosition:(UITextPosition *)position inDirection:(UITextLayoutDirection)direction offset:(NSInteger)offset {
    NSInteger delta = (direction == UITextLayoutDirectionLeft || direction == UITextLayoutDirectionUp) ? -offset : offset;
    return [self positionFromPosition:position offset:delta];
}

- (NSComparisonResult)comparePosition:(UITextPosition *)position toPosition:(UITextPosition *)other {
    NSInteger a = ((NativeSdkTextPosition *)position).index;
    NSInteger b = ((NativeSdkTextPosition *)other).index;
    if (a < b) return NSOrderedAscending;
    if (a > b) return NSOrderedDescending;
    return NSOrderedSame;
}

- (NSInteger)offsetFromPosition:(UITextPosition *)fromPosition toPosition:(UITextPosition *)toPosition {
    return ((NativeSdkTextPosition *)toPosition).index - ((NativeSdkTextPosition *)fromPosition).index;
}

- (id<UITextInputTokenizer>)tokenizer {
    return [[UITextInputStringTokenizer alloc] initWithTextInput:self];
}

- (UITextPosition *)positionWithinRange:(UITextRange *)range farthestInDirection:(UITextLayoutDirection)direction {
    if (direction == UITextLayoutDirectionLeft || direction == UITextLayoutDirectionUp) return range.start;
    return range.end;
}

- (UITextRange *)characterRangeByExtendingPosition:(UITextPosition *)position inDirection:(UITextLayoutDirection)direction {
    NSInteger index = ((NativeSdkTextPosition *)position).index;
    if (direction == UITextLayoutDirectionLeft || direction == UITextLayoutDirectionUp) {
        return [NativeSdkTextRange rangeWithLocation:0 length:index];
    }
    return [NativeSdkTextRange rangeWithLocation:index length:(NSInteger)self.markedText.length - index];
}

- (NSWritingDirection)baseWritingDirectionForPosition:(UITextPosition *)position inDirection:(UITextStorageDirection)direction {
    (void)position;
    (void)direction;
    return NSWritingDirectionNatural;
}

- (void)setBaseWritingDirection:(NSWritingDirection)writingDirection forRange:(UITextRange *)range {
    (void)writingDirection;
    (void)range;
}

- (CGRect)focusedWidgetRect {
    if (!self.nativeApp) return CGRectZero;
    native_sdk_text_input_state_t state = {0};
    if (native_sdk_app_text_input_state(self.nativeApp, &state) != 1 || !state.active) return CGRectZero;
    return CGRectMake(state.x, state.y, state.width, state.height);
}

- (CGRect)firstRectForRange:(UITextRange *)range {
    (void)range;
    CGRect rect = [self focusedWidgetRect];
    return CGRectIsEmpty(rect) ? self.bounds : rect;
}

- (CGRect)caretRectForPosition:(UITextPosition *)position {
    (void)position;
    CGRect rect = [self focusedWidgetRect];
    if (CGRectIsEmpty(rect)) return CGRectMake(0, 0, 2, 24);
    return CGRectMake(CGRectGetMaxX(rect) - 2, rect.origin.y, 2, rect.size.height);
}

- (NSArray<UITextSelectionRect *> *)selectionRectsForRange:(UITextRange *)range {
    (void)range;
    return @[];
}

- (UITextPosition *)closestPositionToPoint:(CGPoint)point {
    (void)point;
    return [self endOfDocument];
}

- (UITextPosition *)closestPositionToPoint:(CGPoint)point withinRange:(UITextRange *)range {
    (void)point;
    return range.end;
}

- (UITextRange *)characterRangeAtPoint:(CGPoint)point {
    (void)point;
    return nil;
}

// -------------------------------------------------------- UITextInputTraits
// Deterministic input for tests and desktop-parity text handling: the
// runtime owns editing behavior, so system rewriting stays off.

- (UITextAutocorrectionType)autocorrectionType {
    return UITextAutocorrectionTypeNo;
}

- (UITextSpellCheckingType)spellCheckingType {
    return UITextSpellCheckingTypeNo;
}

- (UITextSmartQuotesType)smartQuotesType {
    return UITextSmartQuotesTypeNo;
}

- (UITextSmartDashesType)smartDashesType {
    return UITextSmartDashesTypeNo;
}

- (UITextSmartInsertDeleteType)smartInsertDeleteType {
    return UITextSmartInsertDeleteTypeNo;
}

- (UITextAutocapitalizationType)autocapitalizationType {
    return UITextAutocapitalizationTypeNone;
}

@end

@interface NativeSdkCanvasViewController : UIViewController
@property(nonatomic) void *nativeApp;
@property(nonatomic, strong) NativeSdkAudioEngine *audioEngine;
@property(nonatomic, strong) id<MTLDevice> device;
@property(nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property(nonatomic, strong) id<MTLTexture> canvasTexture;
/* The canvas presenter: the fullscreen-quad pipeline + nearest sampler
 * that draws the RGBA8 canvas texture into the BGRA8 drawable — the
 * iOS twin of appkit_host.m's ensureCanvasPresenter. Compiled once from
 * source on first present. */
@property(nonatomic, strong) id<MTLRenderPipelineState> canvasRenderPipeline;
@property(nonatomic, strong) id<MTLSamplerState> canvasSampler;
@property(nonatomic, strong) CADisplayLink *displayLink;
@property(nonatomic) uint8_t *rgbaBytes;
@property(nonatomic) size_t stagingCapacity;
@property(nonatomic) uint64_t lastCanvasRevision;
@property(nonatomic) BOOL hasPresentedRevision;
@property(nonatomic) BOOL needsPresent;
@property(nonatomic) CGFloat viewportScale;
/* The drawable size last applied to the layer: reassigning drawableSize
 * every present invalidates the layer's drawable pool on some OS
 * releases, so it is only written when the rendered pixel size actually
 * changed (mirroring the macOS host's updateDrawableSize compare). */
@property(nonatomic) CGSize appliedDrawableSize;
/* Scene-lifecycle observer tokens (background/foreground pump pausing,
 * resign/become-active runtime activation), removed on teardown. */
@property(nonatomic, strong) NSArray<id> *lifecycleObservers;
/* Frame-trace counters (NATIVE_SDK_GPU_FRAME_TRACE=1 only): cumulative
 * structural truth for the present path — how many display ticks ran,
 * how many short-circuited idle, how many drawables were acquired, and
 * how many bytes rode replaceRegion. Zero cost while the trace is off. */
@property(nonatomic) uint64_t traceTickCount;
@property(nonatomic) uint64_t traceIdleTickCount;
@property(nonatomic) uint64_t tracePresentCount;
@property(nonatomic) uint64_t traceDrawableCount;
@property(nonatomic) uint64_t traceNilDrawableCount;
@property(nonatomic) uint64_t traceUploadBytes;
@property(nonatomic) uint64_t tracePresentCpuNs;
@property(nonatomic) uint64_t traceLastSummaryNs;
@end

@implementation NativeSdkCanvasViewController

- (CAMetalLayer *)metalLayer {
    return (CAMetalLayer *)self.view.layer;
}

- (NativeSdkCanvasView *)canvasView {
    return (NativeSdkCanvasView *)self.view;
}

- (void)loadView {
    self.view = [[NativeSdkCanvasView alloc] init];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.device = MTLCreateSystemDefaultDevice();
    self.commandQueue = [self.device newCommandQueue];
    self.viewportScale = 1;

    CAMetalLayer *layer = [self metalLayer];
    layer.device = self.device;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    // The drawable is only ever a render-pass target (the canvas texture
    // is sampled INTO it by the presenter quad; nothing blits from or
    // samples the drawable itself), so it keeps the compositor-optimal
    // framebuffer-only default.
    layer.framebufferOnly = YES;
    layer.opaque = YES;
    self.view.backgroundColor = [UIColor whiteColor];

    self.nativeApp = native_sdk_app_create();
    if (!self.nativeApp) {
        NSLog(@"native-sdk: native_sdk_app_create failed");
        return;
    }
    [self canvasView].nativeApp = self.nativeApp;

    // Real text metrics (M5): register the CoreText measure callback before
    // start so the installing layout already measures with the fonts
    // presentation would draw with. The estimator opt-out is a LAUNCH
    // ARGUMENT (simctl launch <udid> <bundle> --estimator-text-metrics),
    // not an environment variable: the simulator's launchd replays a
    // previous launch's SIMCTL_CHILD_* environment, so env toggles are not
    // deterministic across relaunches; process arguments are.
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--estimator-text-metrics"]) {
        NSLog(@"native-sdk: text measure disabled (estimator metrics)");
    } else {
        native_sdk_app_set_text_measure(self.nativeApp, NativeSdkMeasureText, NULL);
        [self logNativeErrorIfAny:@"text_measure"];
        NSLog(@"native-sdk: CoreText text measure registered");
    }

    // The platform audio service (registered before start, like the text
    // measure, so the first effect dispatch already sees it): one real
    // player behind the embed audio seam — AVAudioPlayer for local files
    // and verified cache entries, AVPlayer for progressive URL streams.
    self.audioEngine = [[NativeSdkAudioEngine alloc] init];
    self.audioEngine.nativeApp = self.nativeApp;
    native_sdk_audio_service_t audioService = {
        .load = NativeSdkAudioServiceLoad,
        .load_url = NativeSdkAudioServiceLoadUrl,
        .play = NativeSdkAudioServicePlay,
        .pause = NativeSdkAudioServicePause,
        .stop = NativeSdkAudioServiceStop,
        .seek = NativeSdkAudioServiceSeek,
        .set_volume = NativeSdkAudioServiceSetVolume,
    };
    native_sdk_app_set_audio_service(self.nativeApp, &audioService, (__bridge void *)self.audioEngine);
    [self logNativeErrorIfAny:@"audio_service"];

    // Verification harness: with NATIVE_SDK_AUTOMATION set (simctl launch
    // exports SIMCTL_CHILD_* into the app) the embedded runtime publishes
    // snapshot.txt into the app's data container, same protocol as the
    // desktop -Dautomation=true runners.
    if (getenv("NATIVE_SDK_AUTOMATION")) {
        NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
            stringByAppendingPathComponent:@"native-sdk-automation"];
        if (dir) {
            native_sdk_app_set_automation_dir(self.nativeApp,
                                               dir.UTF8String,
                                               [dir lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
            [self logNativeErrorIfAny:@"automation"];
            NSLog(@"native-sdk: automation dir %@", dir);
        }
    }

    // Packaged assets: `native package` bundles the app's assets/ into an
    // Assets directory inside the app bundle; point the embed host at it
    // before start so asset-relative loads resolve. (Not "Resources": a
    // bundle-root directory of that name makes CFBundle read the .app as
    // a deep macOS-layout bundle and archive stamping breaks.) Absent in
    // the dev loop's minimal bundle when the app ships no assets.
    NSString *assetRoot = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Assets"];
    BOOL assetRootIsDir = NO;
    if ([NSFileManager.defaultManager fileExistsAtPath:assetRoot isDirectory:&assetRootIsDir] && assetRootIsDir) {
        native_sdk_app_set_asset_root(self.nativeApp,
                                       assetRoot.UTF8String,
                                       [assetRoot lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
        [self logNativeErrorIfAny:@"asset_root"];
    }

    native_sdk_app_start(self.nativeApp);
    native_sdk_app_activate(self.nativeApp);
    [self logNativeErrorIfAny:@"start"];

    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayLinkTick:)];
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

    // Scene lifecycle: the pump follows the app's visibility the way the
    // macOS host follows window occlusion. A backgrounded app presents
    // nothing — the display link pauses (GPU work submitted from the
    // background is killed by the watchdog, and pixels nobody can see
    // are pure battery drain) — and the runtime hears about activation
    // honestly (deactivate on resign-active, activate on become-active;
    // the Android host's onPause/onResume mirror). Returning to the
    // foreground marks needsPresent: the drawable pool may have been
    // purged while covered, so the retained canvas re-presents once even
    // though its revision is unchanged — the mobile mirror of the macOS
    // occlusion observer's glass flush. The launch-time first present
    // needs no special case here: until the first present lands,
    // hasPresentedRevision stays NO and every tick presents.
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    __weak NativeSdkCanvasViewController *weakSelf = self;
    self.lifecycleObservers = @[
        [center addObserverForName:UIApplicationWillResignActiveNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
                            (void)note;
                            NativeSdkCanvasViewController *strongSelf = weakSelf;
                            if (strongSelf.nativeApp) native_sdk_app_deactivate(strongSelf.nativeApp);
                        }],
        [center addObserverForName:UIApplicationDidBecomeActiveNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
                            (void)note;
                            NativeSdkCanvasViewController *strongSelf = weakSelf;
                            if (strongSelf.nativeApp) native_sdk_app_activate(strongSelf.nativeApp);
                        }],
        [center addObserverForName:UIApplicationDidEnterBackgroundNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
                            (void)note;
                            weakSelf.displayLink.paused = YES;
                        }],
        [center addObserverForName:UIApplicationWillEnterForegroundNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
                            (void)note;
                            NativeSdkCanvasViewController *strongSelf = weakSelf;
                            if (!strongSelf) return;
                            strongSelf.needsPresent = YES;
                            strongSelf.displayLink.paused = NO;
                        }],
    ];
}

- (void)dealloc {
    [self.displayLink invalidate];
    for (id observer in self.lifecycleObservers) {
        [[NSNotificationCenter defaultCenter] removeObserver:observer];
    }
    if (self.nativeApp) {
        // Stop first: the runtime's shutdown path releases the audio
        // channel through the still-registered service. Then cut the
        // engine's event path before the app is destroyed so a stray
        // asynchronous report cannot reach a dead runtime.
        native_sdk_app_stop(self.nativeApp);
        self.audioEngine.nativeApp = NULL;
        native_sdk_app_destroy(self.nativeApp);
    }
    [self.audioEngine invalidate];
    free(self.rgbaBytes);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self pushViewport];
}

- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    [self pushViewport];
}

// Report the view's size in points + contentScale + safe-area insets to the
// embed host (keyboard insets stay zero: IME is M3).
- (void)pushViewport {
    if (!self.nativeApp) return;
    CGSize size = self.view.bounds.size;
    if (size.width <= 0 || size.height <= 0) return;
    UIScreen *screen = self.view.window.screen ?: UIScreen.mainScreen;
    CGFloat scale = screen.scale > 0 ? screen.scale : 1;
    self.viewportScale = scale;
    [self metalLayer].contentsScale = scale;
    UIEdgeInsets safe = self.view.safeAreaInsets;
    native_sdk_app_viewport(self.nativeApp,
                             (float)size.width, (float)size.height, (float)scale,
                             (__bridge void *)[self metalLayer],
                             (float)safe.top, (float)safe.right, (float)safe.bottom, (float)safe.left,
                             0, 0, 0, 0);
    [self logNativeErrorIfAny:@"viewport"];
    self.needsPresent = YES;
}

- (void)displayLinkTick:(CADisplayLink *)link {
    if (!self.nativeApp) return;
    if (NativeSdkGpuFrameTraceEnabled()) {
        self.traceTickCount += 1;
        [self emitFrameTraceSummaryIfDue];
    }

    // Host-pumped frame: synthesizes the gpu_surface_frame event (first
    // tick installs the widget tree, later ticks re-present).
    native_sdk_app_frame(self.nativeApp);

    // Keyboard show/hide follows the runtime's focus state each tick, not
    // only after shim-forwarded input: focus can also move from keyboard
    // handling (tab/escape) or model updates.
    [[self canvasView] syncTextInput];

    // Only re-render + blit when the retained canvas actually changed.
    native_sdk_gpu_frame_state_t state = {0};
    BOOL haveState = native_sdk_app_gpu_frame_state(self.nativeApp, &state) == 1;
    if (!self.needsPresent && haveState && self.hasPresentedRevision &&
        state.canvas_revision == self.lastCanvasRevision) {
        if (NativeSdkGpuFrameTraceEnabled()) self.traceIdleTickCount += 1;
        return;
    }

    if ([self renderAndPresent]) {
        if (haveState) {
            self.lastCanvasRevision = state.canvas_revision;
            self.hasPresentedRevision = YES;
        }
        self.needsPresent = NO;
    }
}

/* Once-per-second cumulative counter line while the frame trace is on. */
- (void)emitFrameTraceSummaryIfDue {
    const uint64_t now = NativeSdkTimestampNanoseconds();
    if (self.traceLastSummaryNs != 0 && now - self.traceLastSummaryNs < 1000000000ull) return;
    if (self.traceLastSummaryNs != 0) {
        fprintf(stderr,
                "native-sdk: gpu frame-trace summary ticks=%llu idle=%llu presents=%llu drawables=%llu nil=%llu upload_bytes=%llu present_cpu_us=%llu\n",
                (unsigned long long)self.traceTickCount,
                (unsigned long long)self.traceIdleTickCount,
                (unsigned long long)self.tracePresentCount,
                (unsigned long long)self.traceDrawableCount,
                (unsigned long long)self.traceNilDrawableCount,
                (unsigned long long)self.traceUploadBytes,
                (unsigned long long)(self.tracePresentCpuNs / 1000));
    }
    self.traceLastSummaryNs = now;
}

- (BOOL)ensureStagingCapacity:(size_t)byteLength {
    if (self.stagingCapacity >= byteLength && self.rgbaBytes) return YES;
    free(self.rgbaBytes);
    self.rgbaBytes = malloc(byteLength);
    self.stagingCapacity = self.rgbaBytes ? byteLength : 0;
    return self.stagingCapacity != 0;
}

// The canvas presenter, mirrored from appkit_host.m's
// ensureCanvasPresenter: a four-vertex fullscreen quad whose fragment
// stage samples the canvas texture with nearest filtering (the canvas is
// already rasterized at device scale — presentation must not resample
// it). Sampling is what makes the pixel formats independent: the shader
// reads RGBA semantics from the RGBA8 canvas texture and the pass writes
// them into the BGRA8 drawable, so the RGBA -> BGRA conversion the old
// blit path paid for with a CPU swizzle over every frame's bytes now
// happens inside the render pass for free.
- (BOOL)ensureCanvasPresenter {
    if (self.canvasRenderPipeline && self.canvasSampler) return YES;
    if (!self.device) return NO;

    static NSString *shaderSource =
        @"#include <metal_stdlib>\n"
        @"using namespace metal;\n"
        @"struct NativeSdkCanvasVertexOut { float4 position [[position]]; float2 uv; };\n"
        @"vertex NativeSdkCanvasVertexOut native_sdk_canvas_vertex(uint vertex_id [[vertex_id]]) {\n"
        @"  constexpr float2 positions[4] = { float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0) };\n"
        @"  constexpr float2 uvs[4] = { float2(0.0, 1.0), float2(1.0, 1.0), float2(0.0, 0.0), float2(1.0, 0.0) };\n"
        @"  NativeSdkCanvasVertexOut out;\n"
        @"  out.position = float4(positions[vertex_id], 0.0, 1.0);\n"
        @"  out.uv = uvs[vertex_id];\n"
        @"  return out;\n"
        @"}\n"
        @"fragment float4 native_sdk_canvas_fragment(NativeSdkCanvasVertexOut in [[stage_in]], texture2d<float> canvas_texture [[texture(0)]], sampler texture_sampler [[sampler(0)]]) {\n"
        @"  return canvas_texture.sample(texture_sampler, in.uv);\n"
        @"}\n";

    NSError *libraryError = nil;
    id<MTLLibrary> library = [self.device newLibraryWithSource:shaderSource options:nil error:&libraryError];
    if (!library) return NO;
    id<MTLFunction> vertexFunction = [library newFunctionWithName:@"native_sdk_canvas_vertex"];
    id<MTLFunction> fragmentFunction = [library newFunctionWithName:@"native_sdk_canvas_fragment"];
    if (!vertexFunction || !fragmentFunction) return NO;

    MTLRenderPipelineDescriptor *pipelineDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    pipelineDescriptor.label = @"native-sdk canvas presenter";
    pipelineDescriptor.vertexFunction = vertexFunction;
    pipelineDescriptor.fragmentFunction = fragmentFunction;
    pipelineDescriptor.colorAttachments[0].pixelFormat = [self metalLayer].pixelFormat;

    NSError *pipelineError = nil;
    id<MTLRenderPipelineState> pipeline = [self.device newRenderPipelineStateWithDescriptor:pipelineDescriptor error:&pipelineError];
    if (!pipeline) return NO;

    MTLSamplerDescriptor *samplerDescriptor = [[MTLSamplerDescriptor alloc] init];
    samplerDescriptor.minFilter = MTLSamplerMinMagFilterNearest;
    samplerDescriptor.magFilter = MTLSamplerMinMagFilterNearest;
    samplerDescriptor.mipFilter = MTLSamplerMipFilterNotMipmapped;
    samplerDescriptor.sAddressMode = MTLSamplerAddressModeClampToEdge;
    samplerDescriptor.tAddressMode = MTLSamplerAddressModeClampToEdge;
    id<MTLSamplerState> sampler = [self.device newSamplerStateWithDescriptor:samplerDescriptor];
    if (!sampler) return NO;

    self.canvasRenderPipeline = pipeline;
    self.canvasSampler = sampler;
    return YES;
}

- (BOOL)renderAndPresent {
    const BOOL trace = NativeSdkGpuFrameTraceEnabled();
    const uint64_t presentBeginNs = trace ? NativeSdkTimestampNanoseconds() : 0;
    float scale = (float)self.viewportScale;

    native_sdk_canvas_pixels_t info = {0};
    if (native_sdk_app_render_pixel_size(self.nativeApp, scale, &info) != 1) return NO;
    if (info.width == 0 || info.height == 0 || info.byte_len != info.width * info.height * 4) return NO;
    if (![self ensureStagingCapacity:info.byte_len]) return NO;
    if (![self ensureCanvasPresenter]) return NO;

    native_sdk_canvas_pixels_t rendered = {0};
    if (native_sdk_app_render_pixels(self.nativeApp, scale, self.rgbaBytes, info.byte_len, &rendered) != 1) {
        [self logNativeErrorIfAny:@"render_pixels"];
        return NO;
    }
    const uint64_t renderEndNs = trace ? NativeSdkTimestampNanoseconds() : 0;
    NSUInteger width = rendered.width;
    NSUInteger height = rendered.height;
    if (width == 0 || height == 0 || rendered.byte_len != width * height * 4) return NO;

    // The canvas texture carries the renderer's bytes verbatim: RGBA8,
    // uploaded straight from the staging buffer (the presenter's render
    // pass converts to the drawable's BGRA — see ensureCanvasPresenter).
    if (!self.canvasTexture || self.canvasTexture.width != width || self.canvasTexture.height != height) {
        MTLTextureDescriptor *descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                               width:width
                                                              height:height
                                                           mipmapped:NO];
        descriptor.usage = MTLTextureUsageShaderRead;
        descriptor.storageMode = MTLStorageModeShared;
        self.canvasTexture = [self.device newTextureWithDescriptor:descriptor];
    }
    if (!self.canvasTexture) return NO;
    const uint64_t uploadBeginNs = trace ? NativeSdkTimestampNanoseconds() : 0;
    [self.canvasTexture replaceRegion:MTLRegionMake2D(0, 0, width, height)
                          mipmapLevel:0
                            withBytes:self.rgbaBytes
                          bytesPerRow:width * 4];
    const uint64_t uploadEndNs = trace ? NativeSdkTimestampNanoseconds() : 0;
    if (trace) self.traceUploadBytes += (uint64_t)width * (uint64_t)height * 4;

    CAMetalLayer *layer = [self metalLayer];
    CGSize drawableSize = CGSizeMake(width, height);
    if (!CGSizeEqualToSize(self.appliedDrawableSize, drawableSize)) {
        layer.drawableSize = drawableSize;
        self.appliedDrawableSize = drawableSize;
    }

    // Drawable acquisition discipline: a CAMetalLayer vends a small fixed
    // pool of drawables, and nextDrawable is the one call in this path
    // that can BLOCK the main thread — the pool hands one back on the
    // compositor's schedule, not ours. So the host acquires a drawable
    // (a) only on frames that will really present (the canvas-revision
    // gate in displayLinkTick already decided that) and (b) only after
    // every CPU cost of the frame — the reference render and the texture
    // upload — has been paid, so the block is the residual wait for the
    // glass, never a hold across our own work. Acquiring early or on
    // every tick is the classic stall-and-power sink: an idle app would
    // pin a drawable per vsync and the throttled pool would pace the
    // whole run loop.
    const uint64_t vendBeginNs = trace ? NativeSdkTimestampNanoseconds() : 0;
    id<CAMetalDrawable> drawable = [layer nextDrawable];
    const uint64_t vendEndNs = trace ? NativeSdkTimestampNanoseconds() : 0;
    if (trace) {
        if (drawable) self.traceDrawableCount += 1;
        else self.traceNilDrawableCount += 1;
    }
    if (!drawable) {
        // A declined drawable (mid-resize flux, transient pool pressure):
        // needsPresent stays armed upstream, so the next tick retries —
        // the retained canvas texture already holds the frame.
        if (trace) {
            self.tracePresentCpuNs += NativeSdkTimestampNanoseconds() - renderEndNs;
            fprintf(stderr, "native-sdk: gpu frame-trace path=nil-drawable vend_us=%llu\n",
                    (unsigned long long)((vendEndNs - vendBeginNs) / 1000));
        }
        return NO;
    }
    if (drawable.texture.width != width || drawable.texture.height != height) return NO;

    MTLRenderPassDescriptor *descriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    descriptor.colorAttachments[0].texture = drawable.texture;
    // The quad covers every drawable pixel, so the pass needs no load; a
    // clear is the cheapest correct load action on a tiled GPU.
    descriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    descriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    if (!commandBuffer) return NO;
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:descriptor];
    [encoder setRenderPipelineState:self.canvasRenderPipeline];
    [encoder setFragmentTexture:self.canvasTexture atIndex:0];
    [encoder setFragmentSamplerState:self.canvasSampler atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [encoder endEncoding];
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
    if (trace) {
        const uint64_t presentEndNs = NativeSdkTimestampNanoseconds();
        self.tracePresentCount += 1;
        /* Present-path CPU excludes the reference render: upload +
         * drawable vend + encode/commit. The render is the renderer's
         * cost, not the presentation seam's. */
        self.tracePresentCpuNs += presentEndNs - renderEndNs;
        fprintf(stderr, "native-sdk: gpu frame-trace path=present frame=%llu render_us=%llu upload_us=%llu vend_us=%llu upload_bytes=%llu total_us=%llu\n",
                (unsigned long long)self.tracePresentCount,
                (unsigned long long)((renderEndNs - presentBeginNs) / 1000),
                (unsigned long long)((uploadEndNs - uploadBeginNs) / 1000),
                (unsigned long long)((vendEndNs - vendBeginNs) / 1000),
                (unsigned long long)((uint64_t)width * (uint64_t)height * 4),
                (unsigned long long)((presentEndNs - presentBeginNs) / 1000));
    }
    return YES;
}

- (void)logNativeErrorIfAny:(NSString *)stage {
    const char *name = native_sdk_app_last_error_name(self.nativeApp);
    if (name && name[0] != '\0') {
        NSLog(@"native-sdk: %@ error %s", stage, name);
    }
}

@end

@interface NativeSdkAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation NativeSdkAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[NativeSdkCanvasViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([NativeSdkAppDelegate class]));
    }
}
