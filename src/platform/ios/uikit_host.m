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
// scene through the CPU reference renderer into the host's RETAINED
// staging buffer (`native_sdk_app_render_pixels_damage`, RGBA8): each
// changed frame the embed side rasters only its dirty region and reports
// the damaged rect, so the host uploads exactly that region into a
// shared RGBA8 MTLTexture (`replaceRegion` with the rect) and presents
// it as a fullscreen quad sampled by the same tiny pipeline the macOS
// host's canvas presenter compiles (the render pass converts to the
// drawable's BGRA on the way out, so no CPU swizzle pass exists). A
// CADisplayLink pumps `native_sdk_app_frame` and the canvas revision from
// `native_sdk_app_gpu_frame_state` gates re-renders, so an idle app costs
// one ABI call per tick and acquires no drawable and uploads no bytes;
// a revision bump with no visual change vends no drawable either
// (path=no-damage in the trace). NATIVE_SDK_GPU_FRAME_TRACE=1 prints the
// same per-present/nil-drawable trace lines the macOS host does — now
// carrying the damage rect — plus a once-per-second structural summary
// (ticks, idle short-circuits, presents, drawables acquired, upload
// bytes, present-path CPU).
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
//
// Images: the host registers the platform image decoder
// (`native_sdk_app_set_image_service`) before start, mirroring the macOS
// host's `native_sdk_appkit_decode_image` byte for byte: CGImageSource
// (ImageIO) decodes PNG, JPEG, and every other codec the OS ships into
// straight-alpha RGBA8, so `fx.registerImageBytes` registers real pixels
// (album covers, fetched avatars) instead of declining. Decoding is
// synchronous inside the registration call and the runtime copies the
// pixels into its bounded image registry once — frames then reference the
// registered pixels by id, never re-decoding.

#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>

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

// ---------------------------------------------------------------- image decode
//
// The platform image decoder registered through
// native_sdk_app_set_image_service: CGImageSource (ImageIO) handles PNG,
// JPEG, and every other codec the OS ships — the toolkit bundles none.
// This is the macOS host's native_sdk_appkit_decode_image ported into the
// iOS host with the identical contract: the image draws into a
// premultiplied RGBA8 bitmap context (the only RGBA layout
// CGBitmapContext can render into) and is un-premultiplied in place,
// because the canvas image pipeline expects straight alpha. Returns 1
// decoded, -1 when the decoded pixels do not fit `pixels_len`, 0 for
// undecodable bytes.
static int NativeSdkImageServiceDecode(void *context, const uint8_t *bytes, uintptr_t bytes_len, uint8_t *pixels, uintptr_t pixels_len, uintptr_t *out_width, uintptr_t *out_height) {
    (void)context;
    if (out_width) *out_width = 0;
    if (out_height) *out_height = 0;
    if (!bytes || bytes_len == 0 || !pixels) return 0;
    @autoreleasepool {
        NSData *data = [NSData dataWithBytesNoCopy:(void *)bytes length:bytes_len freeWhenDone:NO];
        CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
        if (!source) return 0;
        CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
        CFRelease(source);
        if (!image) return 0;

        size_t width = CGImageGetWidth(image);
        size_t height = CGImageGetHeight(image);
        if (width == 0 || height == 0 || width > 8192 || height > 8192) {
            CGImageRelease(image);
            return 0;
        }
        if (out_width) *out_width = width;
        if (out_height) *out_height = height;
        size_t byte_len = width * height * 4;
        if (byte_len / 4 / height != width || pixels_len < byte_len) {
            CGImageRelease(image);
            return -1;
        }

        CGColorSpaceRef color_space = CGColorSpaceCreateDeviceRGB();
        if (!color_space) {
            CGImageRelease(image);
            return 0;
        }
        CGContextRef bitmap = CGBitmapContextCreate(pixels, width, height, 8, width * 4, color_space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGColorSpaceRelease(color_space);
        if (!bitmap) {
            CGImageRelease(image);
            return 0;
        }
        memset(pixels, 0, byte_len);
        CGContextSetBlendMode(bitmap, kCGBlendModeCopy);
        CGContextDrawImage(bitmap, CGRectMake(0, 0, (CGFloat)width, (CGFloat)height), image);
        CGContextRelease(bitmap);
        CGImageRelease(image);

        // Un-premultiply: round to nearest so opaque pixels survive exactly.
        for (size_t offset = 0; offset < byte_len; offset += 4) {
            uint8_t alpha = pixels[offset + 3];
            if (alpha == 0) {
                pixels[offset + 0] = 0;
                pixels[offset + 1] = 0;
                pixels[offset + 2] = 0;
            } else if (alpha != 255) {
                pixels[offset + 0] = (uint8_t)MIN(255, ((size_t)pixels[offset + 0] * 255 + alpha / 2) / alpha);
                pixels[offset + 1] = (uint8_t)MIN(255, ((size_t)pixels[offset + 1] * 255 + alpha / 2) / alpha);
                pixels[offset + 2] = (uint8_t)MIN(255, ((size_t)pixels[offset + 2] * 255 + alpha / 2) / alpha);
            }
        }
        return 1;
    }
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

// ------------------------------------------------------- navigation pages
//
// One lightweight page in the platform navigation stack: a plain
// container view holding either the LIVE canvas view (always the top
// page) or a retained snapshot of a shallower page (the pages
// underneath). The page carries no app logic — it exists so a real
// UINavigationController can run its real push/pop transitions and its
// real interactive edge-swipe-back recognizer over the single live
// canvas. See the platform navigation section below for the full
// contract.
@interface NativeSdkNavPageViewController : UIViewController
@property(nonatomic, strong) UIView *contentView;
- (void)installContent:(UIView *)content;
@end

@implementation NativeSdkNavPageViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];
}

/* Install (or move in) the page's single content view, full-bleed with
 * autoresizing — moving the live canvas between pages is an ordinary
 * subview reparent, so the Metal layer keeps its drawables and scale. */
- (void)installContent:(UIView *)content {
    if (self.contentView == content && content.superview == self.viewIfLoaded) return;
    if (self.contentView != content) [self.contentView removeFromSuperview];
    self.contentView = content;
    if (!content) return;
    [self loadViewIfNeeded];
    content.frame = self.view.bounds;
    content.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:content];
}

@end

@interface NativeSdkCanvasViewController : UIViewController <UITabBarDelegate, UINavigationControllerDelegate, UIGestureRecognizerDelegate>
@property(nonatomic) void *nativeApp;
@property(nonatomic, strong) NativeSdkAudioEngine *audioEngine;
/* Declared platform chrome (the app's shell-metadata tab set + optional
 * primary action), projected as REAL native controls: an actual UITabBar
 * with system styling and accessibility, and a real UIButton for the
 * primary action. The canvas stays the full-bleed content region; the
 * bar's overlap rides additionalSafeAreaInsets so the app's layout
 * clears it through the existing chrome-inset channel. Selection is a
 * PROJECTION of the model: each display tick polls
 * native_sdk_app_chrome_selected_tab and moves the bar to match; a tap
 * dispatches the tab's declared command id through
 * native_sdk_app_command and the model answers — the bar is never the
 * source of truth. */
@property(nonatomic, strong) UITabBar *chromeTabBar;
@property(nonatomic, copy) NSArray<NSString *> *chromeTabCommands;
@property(nonatomic, strong) UIButton *chromeActionButton;
@property(nonatomic, copy) NSString *chromeActionCommand;
@property(nonatomic) NSInteger chromeSelectedIndex;
@property(nonatomic) int reportedFormFactor;
/* The live canvas view (the app's single surface). It always lives in
 * the TOP page of the navigation stack below; the tab bar and primary
 * action stay siblings of the stack on this controller's root view, so
 * they hold still through push/pop exactly like the system's own bars. */
@property(nonatomic, strong) NativeSdkCanvasView *canvasView;
/* Platform push/pop navigation (see the section comment below): a real
 * UINavigationController whose lightweight pages wrap the live canvas
 * (top) and retained snapshots (underneath); the model's navigation
 * depth is polled each tick and drives the stack — never the reverse,
 * except the REAL interactive edge-swipe-back gesture, whose completion
 * dispatches the app's declared back command exactly once. */
@property(nonatomic, strong) UINavigationController *navController;
/* Retained shallow-page snapshots, index = depth level (bounded; a
 * level past the cap or without a captured frame keeps NSNull and shows
 * the background wash during a gesture). */
@property(nonatomic, strong) NSMutableArray *navSnapshots;
/* The depth the navigation stack currently reflects (-1 until the app's
 * projection first answers) and the selected tab seen beside it, so a
 * depth change that arrives WITH a tab change reads as a lateral switch
 * and reconciles without a transition. */
@property(nonatomic) NSInteger navAppliedDepth;
@property(nonatomic) NSInteger navAppliedTab;
/* Transition bookkeeping: while a push/pop (host-driven or interactive)
 * runs, depth reconciliation defers to the next tick; navHostTransition
 * marks stack moves this host initiated so the delegate can tell them
 * from the interactive gesture's. */
@property(nonatomic) BOOL navTransitionActive;
@property(nonatomic) BOOL navHostTransition;
/* Whether the most recent damage delivery carried pixels (set by
 * renderAndPresent): the transition pre-render loops its pump until the
 * dispatched change's frame actually lands, because the runtime
 * presents a change on a frame pump after its dispatch, not inside it. */
@property(nonatomic) BOOL lastDeliveryHadDamage;
/* The post-transition cover: the incoming page's exact frame held over
 * the live canvas for a few ticks after a transition lands, while the
 * canvas — freshly re-installed — re-presents underneath. Drawable
 * presents are asynchronous and composite on the render server's
 * schedule, not ours; the cover is what makes the canvas swap-in
 * invisible instead of racing it. */
@property(nonatomic, strong) UIView *navFreezeOverlay;
@property(nonatomic) NSInteger navOverlayTicks;
/* The app's declared back command ("" when the app declares no
 * navigation projection — the gesture never arms without one). */
@property(nonatomic, copy) NSString *navBackCommand;
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
    return (CAMetalLayer *)self.canvasView.layer;
}

// The root view is a plain container: the live canvas rides inside the
// navigation stack's top page (so real push/pop transitions can move
// it), while the declared chrome (tab bar, primary action) stays on this
// root — outside the stack — and holds still through transitions.
- (void)loadView {
    self.view = [[UIView alloc] init];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.device = MTLCreateSystemDefaultDevice();
    self.commandQueue = [self.device newCommandQueue];
    self.viewportScale = 1;

    self.canvasView = [[NativeSdkCanvasView alloc] initWithFrame:self.view.bounds];
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

    // The navigation container: a REAL UINavigationController (bar
    // hidden — apps draw their own headers in canvas) as a child, its
    // root page holding the live canvas. Always present so the view
    // hierarchy is one shape for every app; without a declared
    // navigation projection the stack simply never moves and the
    // edge-swipe recognizer never arms.
    NativeSdkNavPageViewController *root_page = [[NativeSdkNavPageViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root_page];
    nav.navigationBarHidden = YES;
    nav.delegate = self;
    nav.view.backgroundColor = [UIColor whiteColor];
    [self addChildViewController:nav];
    nav.view.frame = self.view.bounds;
    nav.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:nav.view];
    [nav didMoveToParentViewController:self];
    self.navController = nav;
    self.navSnapshots = [NSMutableArray array];
    self.navAppliedDepth = -1;
    self.navAppliedTab = -1;
    self.navBackCommand = @"";
    [root_page installContent:self.canvasView];
    // The REAL interactive pop recognizer: with the navigation bar
    // hidden its default delegate never lets it begin, so this host is
    // the delegate and arms it exactly while the app's projection says a
    // page is open (gestureRecognizerShouldBegin below). The physics,
    // tracking, and cancellation are entirely the system's.
    nav.interactivePopGestureRecognizer.delegate = self;

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

    // The platform image decoder (registered before start, like the audio
    // service, so a boot-effect fx.registerImageBytes already decodes):
    // CGImageSource behind the embed image seam, the same ImageIO family
    // the macOS host decodes through.
    native_sdk_image_service_t imageService = {
        .decode = NativeSdkImageServiceDecode,
    };
    native_sdk_app_set_image_service(self.nativeApp, &imageService, NULL);
    [self logNativeErrorIfAny:@"image_service"];

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

    // Host chrome reports, filed BEFORE start so the pre-install chrome
    // query already carries them: the size class the app can switch
    // shells on (width derivation stays its fallback).
    self.chromeSelectedIndex = -1;
    [self reportFormFactor];

    native_sdk_app_start(self.nativeApp);
    native_sdk_app_activate(self.nativeApp);
    [self logNativeErrorIfAny:@"start"];

    // Declared platform chrome: build the real system controls the shell
    // metadata asks for (nothing when the app declares none).
    [self installDeclaredChrome];

    // The navigation projection's static half: the declared back command
    // the completed edge-swipe dispatches. Without one the projection is
    // inert — the stack never moves and the gesture never begins.
    native_sdk_chrome_item_t back_item = {0};
    if (native_sdk_app_chrome_navigation_back_command(self.nativeApp, &back_item) == 1 && back_item.id) {
        self.navBackCommand = [[NSString alloc] initWithBytes:back_item.id
                                                       length:back_item.id_len
                                                     encoding:NSUTF8StringEncoding] ?: @"";
        NSLog(@"native-sdk: platform navigation projected (back command %@)", self.navBackCommand);
    }

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

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    // Size-class flips (rotation on the larger phones, iPad multitasking)
    // re-report the form factor; the layout pass that accompanies the
    // trait change pushes the viewport, which delivers the changed
    // chrome to the app.
    [self reportFormFactor];
}

- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    [self pushViewport];
}

// Report the view's size in points + contentScale + safe-area insets to the
// embed host (keyboard insets stay zero: IME is M3).
//
// The projected tab bar's overlap folds into the reported BOTTOM inset
// here rather than through additionalSafeAreaInsets: the bar is a
// subview of this same view, so growing the controller's safe area
// would propagate back INTO the bar and squeeze its own item layout.
// The viewport export is the honest seam — the app pads for the bar
// through the identical chrome channel it pads for the home indicator,
// and the bar keeps the system's own safe-area geometry.
- (void)pushViewport {
    if (!self.nativeApp) return;
    CGSize size = self.view.bounds.size;
    if (size.width <= 0 || size.height <= 0) return;
    UIScreen *screen = self.view.window.screen ?: UIScreen.mainScreen;
    CGFloat scale = screen.scale > 0 ? screen.scale : 1;
    self.viewportScale = scale;
    [self metalLayer].contentsScale = scale;
    UIEdgeInsets safe = self.view.safeAreaInsets;
    if (self.chromeTabBar && !CGRectIsEmpty(self.chromeTabBar.frame)) {
        CGFloat bar_overlap = size.height - CGRectGetMinY(self.chromeTabBar.frame);
        safe.bottom = MAX(safe.bottom, bar_overlap);
    }
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

    // The projected tab bar mirrors the MODEL's selected tab each tick
    // (one integer readback): a Msg that moved the model moves the bar,
    // and a tap the app ignored snaps the bar back — model truth wins.
    [self syncDeclaredChromeSelection];

    // Platform navigation mirrors the MODEL's navigation depth each tick
    // (one integer readback). Ordering is load-bearing: this runs BEFORE
    // renderAndPresent, while the retained staging buffer still holds
    // the pre-change frame — the snapshot a push transition slides out
    // from under the incoming live canvas.
    [self syncPlatformNavigation];

    // The post-transition cover comes down a few ticks after the live
    // canvas swapped back in beneath it — enough vsyncs for the flush
    // present to composite, so the removal reveals identical pixels.
    if (self.navFreezeOverlay && !self.navTransitionActive) {
        if (self.navOverlayTicks > 0) {
            self.navOverlayTicks -= 1;
        } else {
            [self.navFreezeOverlay removeFromSuperview];
            self.navFreezeOverlay = nil;
        }
    }

    // Only re-render + blit when the retained canvas actually changed.
    native_sdk_gpu_frame_state_t state = {0};
    BOOL haveState = native_sdk_app_gpu_frame_state(self.nativeApp, &state) == 1;
    if (!self.needsPresent && haveState && self.hasPresentedRevision &&
        state.canvas_revision == self.lastCanvasRevision) {
        if (NativeSdkGpuFrameTraceEnabled()) self.traceIdleTickCount += 1;
        return;
    }

    if ([self renderAndPresent]) {
        // renderAndPresent recorded the revision the DELIVERED buffer
        // reflects (never this tick's sighting): a change whose frame
        // has not presented yet keeps the gate open, so the next tick
        // delivers its damage instead of stranding it off the glass.
        self.needsPresent = NO;
    }
    (void)haveState;
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

    // Damage render: the staging buffer is RETAINED across frames, so the
    // embed side copies only the region the frames since the last call
    // changed (captured off the runtime's own dirty-scissored raster —
    // no full-surface re-render) and names it. A keystroke costs the
    // field's pixels here, not 12+MB of surface.
    native_sdk_canvas_pixels_damage_t rendered = {0};
    if (native_sdk_app_render_pixels_damage(self.nativeApp, scale, self.rgbaBytes, info.byte_len, &rendered) != 1) {
        [self logNativeErrorIfAny:@"render_pixels_damage"];
        return NO;
    }
    const uint64_t renderEndNs = trace ? NativeSdkTimestampNanoseconds() : 0;
    // The delivery names the revision the buffer now reflects; the idle
    // gate compares the live revision against THIS, so a present the
    // runtime produces one pump after its change still gets delivered.
    self.lastCanvasRevision = rendered.revision;
    self.hasPresentedRevision = YES;
    NSUInteger width = rendered.width;
    NSUInteger height = rendered.height;
    if (width == 0 || height == 0 || rendered.byte_len != width * height * 4) {
        // The damage delivery above already consumed the accumulated
        // region: dropping the texture forces the next present to a
        // full upload, so a refused frame can never strand it.
        self.canvasTexture = nil;
        return NO;
    }

    // The canvas texture carries the renderer's bytes verbatim: RGBA8,
    // uploaded straight from the staging buffer (the presenter's render
    // pass converts to the drawable's BGRA — see ensureCanvasPresenter).
    BOOL textureCreated = NO;
    if (!self.canvasTexture || self.canvasTexture.width != width || self.canvasTexture.height != height) {
        MTLTextureDescriptor *descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                               width:width
                                                              height:height
                                                           mipmapped:NO];
        descriptor.usage = MTLTextureUsageShaderRead;
        descriptor.storageMode = MTLStorageModeShared;
        self.canvasTexture = [self.device newTextureWithDescriptor:descriptor];
        textureCreated = YES;
    }
    if (!self.canvasTexture) return NO;

    // Upload only the damaged region (`replaceRegion` with the damage
    // rect; `bytesPerRow` stays the full staging stride so the pointer
    // offset addresses the rect in place). A fresh texture holds no
    // pixels yet, so it takes the full surface regardless of the report.
    NSUInteger damageX = rendered.damage_x;
    NSUInteger damageY = rendered.damage_y;
    NSUInteger damageWidth = rendered.damage_width;
    NSUInteger damageHeight = rendered.damage_height;
    if (textureCreated) {
        damageX = 0;
        damageY = 0;
        damageWidth = width;
        damageHeight = height;
    }
    if (damageX + damageWidth > width || damageY + damageHeight > height) {
        self.canvasTexture = nil;
        return NO;
    }
    const BOOL hasDamage = damageWidth > 0 && damageHeight > 0;
    self.lastDeliveryHadDamage = hasDamage;
    const uint64_t uploadBeginNs = trace ? NativeSdkTimestampNanoseconds() : 0;
    if (hasDamage) {
        [self.canvasTexture replaceRegion:MTLRegionMake2D(damageX, damageY, damageWidth, damageHeight)
                              mipmapLevel:0
                                withBytes:self.rgbaBytes + (damageY * width + damageX) * 4
                              bytesPerRow:width * 4];
    }
    const uint64_t uploadEndNs = trace ? NativeSdkTimestampNanoseconds() : 0;
    const uint64_t uploadBytes = (uint64_t)damageWidth * (uint64_t)damageHeight * 4;
    if (trace) self.traceUploadBytes += uploadBytes;

    CAMetalLayer *layer = [self metalLayer];
    CGSize drawableSize = CGSizeMake(width, height);
    const BOOL drawableSizeChanged = !CGSizeEqualToSize(self.appliedDrawableSize, drawableSize);
    if (drawableSizeChanged) {
        layer.drawableSize = drawableSize;
        self.appliedDrawableSize = drawableSize;
    }

    // No damage and nothing forcing a flush (no viewport/lifecycle
    // re-present pending, texture and drawable both current): the glass
    // already shows this frame — vend no drawable, encode nothing. A
    // revision bump with no visual change costs a copy of zero bytes.
    if (!hasDamage && !textureCreated && !drawableSizeChanged && !self.needsPresent && self.hasPresentedRevision) {
        // Not counted as a present: no drawable moved. The structural
        // counters keep presents == drawables.
        if (trace) {
            fprintf(stderr, "native-sdk: gpu frame-trace path=no-damage render_us=%llu\n",
                    (unsigned long long)((renderEndNs - presentBeginNs) / 1000));
        }
        return YES;
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
        fprintf(stderr, "native-sdk: gpu frame-trace path=present frame=%llu render_us=%llu upload_us=%llu vend_us=%llu upload_bytes=%llu damage=%llux%llu+%llu+%llu total_us=%llu\n",
                (unsigned long long)self.tracePresentCount,
                (unsigned long long)((renderEndNs - presentBeginNs) / 1000),
                (unsigned long long)((uploadEndNs - uploadBeginNs) / 1000),
                (unsigned long long)((vendEndNs - vendBeginNs) / 1000),
                (unsigned long long)uploadBytes,
                (unsigned long long)damageWidth,
                (unsigned long long)damageHeight,
                (unsigned long long)damageX,
                (unsigned long long)damageY,
                (unsigned long long)((presentEndNs - presentBeginNs) / 1000));
    }
    return YES;
}

// ---------------------------------------------------- declared platform chrome
//
// The projection of ShellConfig.chrome onto REAL system controls. The
// honest minimal integration with the single canvas surface: the canvas
// view stays the root and full-bleed; a plain UITabBar (not a
// UITabBarController — there is exactly one content view controller, so
// a container would be a fiction) is pinned to the bottom edge as a
// sibling overlay, and its overlap is folded into
// additionalSafeAreaInsets so the app pads for it through the same
// chrome channel it pads for the home indicator. Icons are the app's
// own declared vocabulary glyphs, rasterized by the embed library
// through the canvas vector core into template images the system tints
// — the artwork is the app's, the bar's styling (background material,
// selection tint, accessibility) is whatever the OS ships.

/* A declared icon name -> template UIImage at the tab-bar glyph size,
 * rasterized at the screen scale so the bar draws it crisp. Nil when the
 * item declares no icon (a text-only tab stays honest). */
- (UIImage *)chromeIconNamed:(const char *)name length:(uintptr_t)length {
    if (!self.nativeApp || !name || length == 0) return nil;
    const CGFloat points = 24;
    CGFloat scale = UIScreen.mainScreen.scale > 0 ? UIScreen.mainScreen.scale : 1;
    const uintptr_t pixels_per_side = (uintptr_t)llround(points * scale);
    const uintptr_t byte_len = pixels_per_side * pixels_per_side * 4;
    uint8_t *bytes = malloc(byte_len);
    if (!bytes) return nil;
    if (native_sdk_app_chrome_icon_pixels(self.nativeApp, name, length, pixels_per_side, bytes, byte_len) != 1) {
        [self logNativeErrorIfAny:@"chrome_icon"];
        free(bytes);
        return nil;
    }
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(bytes, pixels_per_side, pixels_per_side, 8, pixels_per_side * 4, space,
                                                 kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGImageRef cg_image = context ? CGBitmapContextCreateImage(context) : NULL;
    UIImage *image = nil;
    if (cg_image) {
        UIImage *raw = [UIImage imageWithCGImage:cg_image scale:scale orientation:UIImageOrientationUp];
        /* Template mode: the system control owns the tint, exactly like
         * an asset-catalog template icon. */
        image = [raw imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        CGImageRelease(cg_image);
    }
    if (context) CGContextRelease(context);
    CGColorSpaceRelease(space);
    free(bytes);
    return image;
}

- (void)installDeclaredChrome {
    if (!self.nativeApp) return;
    const uintptr_t tab_count = native_sdk_app_chrome_tab_count(self.nativeApp);
    if (tab_count > 0) {
        UITabBar *bar = [[UITabBar alloc] init];
        bar.translatesAutoresizingMaskIntoConstraints = NO;
        bar.delegate = self;
        NSMutableArray<UITabBarItem *> *items = [NSMutableArray arrayWithCapacity:tab_count];
        NSMutableArray<NSString *> *commands = [NSMutableArray arrayWithCapacity:tab_count];
        for (uintptr_t index = 0; index < tab_count; index++) {
            native_sdk_chrome_item_t item = {0};
            if (native_sdk_app_chrome_tab_at(self.nativeApp, index, &item) != 1) continue;
            NSString *identifier = item.id ? [[NSString alloc] initWithBytes:item.id length:item.id_len encoding:NSUTF8StringEncoding] : nil;
            NSString *label = item.label ? [[NSString alloc] initWithBytes:item.label length:item.label_len encoding:NSUTF8StringEncoding] : nil;
            if (!identifier || !label) continue;
            UIImage *icon = [self chromeIconNamed:item.icon length:item.icon_len];
            UITabBarItem *bar_item = [[UITabBarItem alloc] initWithTitle:label image:icon tag:(NSInteger)commands.count];
            [items addObject:bar_item];
            [commands addObject:identifier];
        }
        if (items.count > 0) {
            bar.items = items;
            [self.view addSubview:bar];
            /* The bar spans the bottom edge INCLUDING the home-indicator
             * band (its background material fills to the glass edge,
             * like every system bar), with its top held the standard
             * item-band height above the system safe area so the items
             * keep their full band above the indicator. */
            [NSLayoutConstraint activateConstraints:@[
                [bar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
                [bar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
                [bar.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
                [bar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-49],
            ]];
            self.chromeTabBar = bar;
            self.chromeTabCommands = commands;
            /* The chrome channel now says a native bar owns the tab
             * affordance, so a canvas tab switcher can yield to it. */
            native_sdk_app_set_chrome_tabs_projected(self.nativeApp, 1);
            NSLog(@"native-sdk: declared chrome projected tabs=%lu", (unsigned long)items.count);
            [self syncDeclaredChromeSelection];
        }
    }

    native_sdk_chrome_item_t action = {0};
    if (native_sdk_app_chrome_primary_action(self.nativeApp, &action) == 1) {
        NSString *identifier = action.id ? [[NSString alloc] initWithBytes:action.id length:action.id_len encoding:NSUTF8StringEncoding] : nil;
        NSString *label = action.label ? [[NSString alloc] initWithBytes:action.label length:action.label_len encoding:NSUTF8StringEncoding] : nil;
        if (identifier && label) {
            /* The one primary floating action: a real system button
             * (filled circular configuration), floating above the
             * content's bottom-trailing corner, clear of the bar. */
            UIButtonConfiguration *configuration = [UIButtonConfiguration filledButtonConfiguration];
            configuration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
            UIImage *icon = [self chromeIconNamed:action.icon length:action.icon_len];
            if (icon) configuration.image = icon;
            UIButton *button = [UIButton buttonWithConfiguration:configuration primaryAction:nil];
            if (!icon) [button setTitle:label forState:UIControlStateNormal];
            button.translatesAutoresizingMaskIntoConstraints = NO;
            button.accessibilityLabel = label;
            [button addTarget:self action:@selector(chromeActionPressed:) forControlEvents:UIControlEventTouchUpInside];
            [self.view addSubview:button];
            NSLayoutYAxisAnchor *above = self.chromeTabBar ? self.chromeTabBar.topAnchor
                                                           : self.view.safeAreaLayoutGuide.bottomAnchor;
            [NSLayoutConstraint activateConstraints:@[
                [button.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-16],
                [button.bottomAnchor constraintEqualToAnchor:above constant:-16],
                [button.widthAnchor constraintEqualToConstant:56],
                [button.heightAnchor constraintEqualToConstant:56],
            ]];
            self.chromeActionButton = button;
            self.chromeActionCommand = identifier;
            NSLog(@"native-sdk: declared chrome projected primary action %@", identifier);
        }
    }
}

/* Model -> bar, once per display tick: one integer readback of the
 * model's selected tab (via the app's selected_tab_fn derivation). The
 * bar only ever moves here, so a model change lands visually within a
 * tick and a tap the app ignored snaps back — deterministic both ways. */
- (void)syncDeclaredChromeSelection {
    if (!self.nativeApp || !self.chromeTabBar) return;
    intptr_t selected = native_sdk_app_chrome_selected_tab(self.nativeApp);
    if ((NSInteger)selected == self.chromeSelectedIndex) return;
    self.chromeSelectedIndex = (NSInteger)selected;
    if (selected >= 0 && (NSUInteger)selected < self.chromeTabBar.items.count) {
        self.chromeTabBar.selectedItem = self.chromeTabBar.items[(NSUInteger)selected];
    } else {
        self.chromeTabBar.selectedItem = nil;
    }
    NSLog(@"native-sdk: chrome selected tab -> %ld", (long)selected);
}

/* Bar -> model: a tap dispatches the tab's declared command id through
 * the embed command path (the same path native header buttons use); the
 * app's on_command maps it to a Msg and update moves the model. The
 * command dispatch is synchronous, so the model's answer is read back
 * immediately and the bar lands on whatever the model decided. */
- (void)tabBar:(UITabBar *)tabBar didSelectItem:(UITabBarItem *)item {
    if (!self.nativeApp) return;
    NSUInteger index = (NSUInteger)item.tag;
    if (index >= self.chromeTabCommands.count) return;
    NSString *command = self.chromeTabCommands[index];
    NSLog(@"native-sdk: chrome tab tap -> command %@", command);
    native_sdk_app_command(self.nativeApp, command.UTF8String, [command lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
    [self logNativeErrorIfAny:@"chrome_tab"];
    /* Re-assert model truth now (not next tick): force the compare to
     * re-read even when the model kept the same tab. */
    self.chromeSelectedIndex = -2;
    [self syncDeclaredChromeSelection];
}

- (void)chromeActionPressed:(UIButton *)sender {
    (void)sender;
    if (!self.nativeApp || self.chromeActionCommand.length == 0) return;
    NSString *command = self.chromeActionCommand;
    NSLog(@"native-sdk: chrome primary action -> command %@", command);
    native_sdk_app_command(self.nativeApp, command.UTF8String, [command lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
    [self logNativeErrorIfAny:@"chrome_action"];
}

// ------------------------------------------------------ platform navigation
//
// The projection of the app's navigation depth onto REAL UIKit push/pop
// machinery. The contract, in the declared-chrome shape:
//
// - The MODEL owns navigation state. The app derives a depth from it
//   (`navigation_depth_fn`) and the host polls one integer per tick.
//   Depth grew by one = present the system push transition; shrank by
//   one = present the system pop; anything else — the first sighting, a
//   multi-level jump, or a depth change arriving WITH a selected-tab
//   change (tabs are lateral, never depth) — reconciles the stack with
//   no transition at all.
// - The host has ONE live canvas. At rest it rides the TOP page of a
//   real UINavigationController (bar hidden; pages are plain
//   containers), and the pages underneath hold retained snapshots: on a
//   push, the pre-change frame still sitting in the retained staging
//   buffer (the damage path keeps it current) becomes the outgoing
//   page's snapshot, captured with zero extra renders. One snapshot per
//   depth level, bounded (NativeSdkNavSnapshotCap); a level without one
//   shows the background wash. DURING a host-driven transition both
//   sides are exact CPU bitmaps of the two model states (the incoming
//   one pre-rendered through the ordinary damage delivery, so its
//   pixels are the canvas's own): a Metal drawable present composites
//   on the render server's schedule, not the animation's, so animating
//   the live layer would play the transition against the previous frame
//   and snap at the end — bitmaps make the transition pixel-correct for
//   its whole run, and the live canvas swaps back onto the top page at
//   completion under a brief cover of the same pixels
//   (restoreLiveCanvasAfterTransition). Honesty judgment: a below-page
//   snapshot can be STALE (the shallow page may have changed since its
//   push) — it is only ever visible DURING the interactive gesture, and
//   the fresh render replaces it the moment the gesture completes.
// - The interactive edge-swipe-back is the REAL recognizer
//   (interactivePopGestureRecognizer) with the system's physics, armed
//   only while the projection says a page is open AND the app declared a
//   back command. Completion dispatches that command exactly once
//   through the embed command path (the same journal entry the app's
//   own back button produces); cancellation dispatches nothing and the
//   model is untouched. If the app IGNORES the dispatched command, the
//   next tick's poll sees the un-popped depth and pushes the page back —
//   the navigation mirror of the tab bar snapping back, model truth
//   wins.
// - The tab bar and primary action live on the root view, OUTSIDE the
//   stack, so they hold still through push/pop like the system's own
//   bars, and the safe-area/chrome insets are untouched (the canvas
//   fills the same bounds it always did).

/* Bounded snapshot retention: one full-resolution frame per depth level,
 * at most this many (a phone-scale frame is ~13MB, so the cap bounds the
 * cache near 50MB on pathologically deep stacks; real stacks hold one or
 * two). Levels past the cap keep NSNull and present the background wash
 * during a gesture — bounded memory beats a silent unbounded cache. */
static const NSUInteger NativeSdkNavSnapshotCap = 4;

/* The retained staging buffer as a UIImage — the previously presented
 * frame, captured without rendering anything (the damage path keeps the
 * buffer current). Nil before the first render or across a size change
 * mid-flight; callers fall back to the background wash. */
- (UIImage *)navSnapshotFromRetainedCanvas {
    if (!self.rgbaBytes || !self.canvasTexture) return nil;
    const size_t width = self.canvasTexture.width;
    const size_t height = self.canvasTexture.height;
    if (width == 0 || height == 0) return nil;
    const size_t byte_len = width * height * 4;
    if (self.stagingCapacity < byte_len) return nil;
    NSData *data = [NSData dataWithBytes:self.rgbaBytes length:byte_len];
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    if (!provider) return nil;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    /* The canvas renders an opaque surface, so alpha is skipped rather
     * than interpreted — no premultiply question exists. */
    CGImageRef image = space ? CGImageCreate(width, height, 8, 32, width * 4, space,
                                             kCGBitmapByteOrder32Big | kCGImageAlphaNoneSkipLast,
                                             provider, NULL, false, kCGRenderingIntentDefault)
                             : NULL;
    if (space) CGColorSpaceRelease(space);
    CGDataProviderRelease(provider);
    if (!image) return nil;
    CGFloat scale = self.viewportScale > 0 ? self.viewportScale : 1;
    UIImage *snapshot = [UIImage imageWithCGImage:image scale:scale orientation:UIImageOrientationUp];
    CGImageRelease(image);
    return snapshot;
}

/* A page's content for a stored snapshot slot: the image, or the honest
 * background wash where no frame was retained. */
- (UIView *)navPageContentForSnapshot:(id)stored {
    if ([stored isKindOfClass:[UIImage class]]) {
        UIImageView *image_view = [[UIImageView alloc] initWithImage:(UIImage *)stored];
        return image_view;
    }
    UIView *placeholder = [[UIView alloc] init];
    placeholder.backgroundColor = self.view.backgroundColor;
    return placeholder;
}

/* Model -> stack, once per display tick, BEFORE the tick's render (so
 * the retained buffer still shows the outgoing page). One integer
 * readback; -1 (no projection, or pre-install) leaves the stack alone.
 * While a transition or gesture runs, reconciliation defers — the
 * applied depth stays stale and the next tick retries. */
- (void)syncPlatformNavigation {
    if (!self.nativeApp || !self.navController) return;
    if (self.navTransitionActive) return;
    const intptr_t depth_value = native_sdk_app_chrome_navigation_depth(self.nativeApp);
    if (depth_value < 0) return;
    const NSInteger depth = (NSInteger)depth_value;
    const NSInteger tab = (NSInteger)native_sdk_app_chrome_selected_tab(self.nativeApp);

    if (self.navAppliedDepth < 0) {
        /* First sighting: adopt the model's depth with no transition
         * (launching straight into a deep state must not animate). The
         * launch stack is already one page holding the canvas, so only
         * a deep launch rebuilds anything. */
        if (depth > 0) [self reconcileNavigationStackToDepth:depth];
        self.navAppliedDepth = depth;
        self.navAppliedTab = tab;
        return;
    }
    if (depth == self.navAppliedDepth) {
        self.navAppliedTab = tab;
        return;
    }

    const BOOL tab_moved = tab != self.navAppliedTab;
    if (!tab_moved && depth == self.navAppliedDepth + 1) {
        [self animateNavigationPush];
    } else if (!tab_moved && depth == self.navAppliedDepth - 1) {
        [self animateNavigationPop];
    } else {
        /* Lateral (a tab switch that also changed the visible page's
         * depth) or a multi-level jump: standard platform behavior is
         * no push/pop theater — reconcile instantly. */
        [self reconcileNavigationStackToDepth:depth];
    }
    self.navAppliedDepth = depth;
    self.navAppliedTab = tab;
    NSLog(@"native-sdk: platform navigation depth -> %ld", (long)depth);
}

/* Render the model's CURRENT state onto the live canvas right now,
 * before a transition begins. Two steps, both load-bearing: one extra
 * frame pump (the damage contract presents a dispatched change one pump
 * after its revision bump, so the pump makes the new frame deliverable),
 * then the ordinary delivery + present. Doing this BEFORE the stack
 * moves matters because a drawable presented while a navigation
 * transition is animating composites only after the animation ends —
 * pre-rendering is what makes the incoming page pixel-correct for the
 * transition's whole run instead of snapping afterwards. */
- (void)preRenderLiveCanvasForTransition {
    /* Bounded pump loop: the change is deliverable once the runtime's
     * own present has rastered it, which can take a pump or two after
     * the dispatch. Idle pumps cost microseconds; the pump that rasters
     * is work the transition needs anyway. */
    for (int attempt = 0; attempt < 4; attempt++) {
        native_sdk_app_frame(self.nativeApp);
        self.lastDeliveryHadDamage = NO;
        const BOOL presented = [self renderAndPresent];
        if (NativeSdkGpuFrameTraceEnabled()) {
            native_sdk_gpu_frame_state_t probe = {0};
            const BOOL have = native_sdk_app_gpu_frame_state(self.nativeApp, &probe) == 1;
            fprintf(stderr, "native-sdk: nav pre-render attempt=%d presented=%d damage=%d revision_live=%llu revision_delivered=%llu\n",
                    attempt, presented ? 1 : 0, self.lastDeliveryHadDamage ? 1 : 0,
                    have ? (unsigned long long)probe.canvas_revision : 0,
                    (unsigned long long)self.lastCanvasRevision);
        }
        if (presented && self.lastDeliveryHadDamage) return;
    }
}

/* Depth grew by one: the outgoing frame (the retained buffer BEFORE the
 * pre-render) becomes the current top page's snapshot, the incoming
 * state pre-renders and its exact pixels become the pushed page's
 * content, and the REAL system push slides it in — pixel-correct on
 * both sides for the animation's whole run. The transition animates
 * bitmaps of the two model states deliberately: a drawable present
 * composites on the render server's schedule, so animating the live
 * layer plays the transition against the PREVIOUS frame and snaps at
 * the end — the honest choice is exact CPU pixels during the ~350ms
 * animation, with the live canvas swapped back in at completion
 * (restoreLiveCanvasAfterTransition). */
- (void)animateNavigationPush {
    UIImage *outgoing = [self navSnapshotFromRetainedCanvas];
    [self preRenderLiveCanvasForTransition];
    UIImage *incoming = [self navSnapshotFromRetainedCanvas];
    NativeSdkNavPageViewController *top = (NativeSdkNavPageViewController *)self.navController.topViewController;
    id stored = (outgoing && self.navSnapshots.count < NativeSdkNavSnapshotCap) ? (id)outgoing : (id)[NSNull null];
    [self.navSnapshots addObject:stored];
    [top installContent:[self navPageContentForSnapshot:stored]];
    NativeSdkNavPageViewController *page = [[NativeSdkNavPageViewController alloc] init];
    [page installContent:[self navPageContentForSnapshot:(incoming ?: (id)[NSNull null])]];
    self.navHostTransition = YES;
    [self.navController pushViewController:page animated:YES];
}

/* Depth shrank by one through the model (the app's own back button, a
 * programmatic Msg): the outgoing DEEP frame rides the popped page out
 * while the pre-rendered shallow frame is revealed underneath —
 * bitmaps on both sides, same reasoning as the push. The stored
 * snapshot for the popped level is discarded, and the revealed page's
 * content is the FRESH shallow frame, never the possibly-stale stored
 * one. */
- (void)animateNavigationPop {
    NSArray<__kindof UIViewController *> *stack = self.navController.viewControllers;
    if (stack.count < 2) {
        [self reconcileNavigationStackToDepth:MAX(self.navAppliedDepth - 1, 0)];
        return;
    }
    UIImage *outgoing = [self navSnapshotFromRetainedCanvas];
    [self preRenderLiveCanvasForTransition];
    UIImage *incoming = [self navSnapshotFromRetainedCanvas];
    NativeSdkNavPageViewController *top = (NativeSdkNavPageViewController *)stack.lastObject;
    NativeSdkNavPageViewController *below = (NativeSdkNavPageViewController *)stack[stack.count - 2];
    [top installContent:[self navPageContentForSnapshot:(outgoing ?: (id)[NSNull null])]];
    [below installContent:[self navPageContentForSnapshot:(incoming ?: (id)[NSNull null])]];
    if (self.navSnapshots.count > 0) [self.navSnapshots removeLastObject];
    self.navHostTransition = YES;
    [self.navController popViewControllerAnimated:YES];
}

/* A host-driven transition just landed: put the live canvas back on the
 * top page, but keep the page's transition bitmap ABOVE it for a few
 * ticks while the canvas re-presents underneath (needsPresent flushes
 * the retained texture) — the swap is invisible because the bitmap IS
 * the canvas's current frame. */
- (void)restoreLiveCanvasAfterTransition {
    NativeSdkNavPageViewController *top = (NativeSdkNavPageViewController *)self.navController.topViewController;
    if (top.contentView == self.canvasView) return;
    UIView *cover = top.contentView;
    [top installContent:self.canvasView];
    if (cover) {
        cover.frame = top.view.bounds;
        cover.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [top.view addSubview:cover];
        [self.navFreezeOverlay removeFromSuperview];
        self.navFreezeOverlay = cover;
        self.navOverlayTicks = 3;
    }
    self.needsPresent = YES;
}

/* Rebuild the stack to exactly depth+1 pages with no animation (first
 * sighting, lateral tab switches, multi-level jumps): snapshots for the
 * levels that retained one, the background wash for the rest, the live
 * canvas on top. */
- (void)reconcileNavigationStackToDepth:(NSInteger)depth {
    while ((NSInteger)self.navSnapshots.count > depth) [self.navSnapshots removeLastObject];
    while ((NSInteger)self.navSnapshots.count < depth) [self.navSnapshots addObject:[NSNull null]];
    NSMutableArray<UIViewController *> *pages = [NSMutableArray arrayWithCapacity:(NSUInteger)depth + 1];
    for (NSInteger level = 0; level < depth; level++) {
        NativeSdkNavPageViewController *page = [[NativeSdkNavPageViewController alloc] init];
        [page installContent:[self navPageContentForSnapshot:self.navSnapshots[(NSUInteger)level]]];
        [pages addObject:page];
    }
    NativeSdkNavPageViewController *top = [[NativeSdkNavPageViewController alloc] init];
    [top installContent:self.canvasView];
    [pages addObject:top];
    self.navHostTransition = YES;
    [self.navController setViewControllers:pages animated:NO];
    self.navHostTransition = NO;
    self.needsPresent = YES;
}

/* A completed interactive pop: UIKit already moved the stack (that IS
 * the gesture — real recognizer, real physics), so now the model hears
 * about it: the declared back command dispatches exactly once, the live
 * canvas moves onto the new top page (replacing the stale snapshot the
 * gesture revealed — the honest swap the section comment names), and
 * the applied depth follows the stack so the next tick's poll sees
 * agreement. */
- (void)completeInteractivePop {
    if (self.navSnapshots.count > 0) [self.navSnapshots removeLastObject];
    if (self.navAppliedDepth > 0) self.navAppliedDepth -= 1;
    if (self.nativeApp && self.navBackCommand.length > 0) {
        NSLog(@"native-sdk: navigation swipe-back -> command %@", self.navBackCommand);
        native_sdk_app_command(self.nativeApp,
                               self.navBackCommand.UTF8String,
                               [self.navBackCommand lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
        [self logNativeErrorIfAny:@"navigation_back"];
        /* The dispatch just moved the model to the shallow state; the
         * transition is over, so render it now — the fresh frame both
         * replaces the (possibly stale) revealed snapshot on the glass
         * and covers the canvas swap-in below. */
        [self preRenderLiveCanvasForTransition];
        NativeSdkNavPageViewController *top = (NativeSdkNavPageViewController *)self.navController.topViewController;
        UIImage *fresh = [self navSnapshotFromRetainedCanvas];
        [top installContent:[self navPageContentForSnapshot:(fresh ?: (id)[NSNull null])]];
    }
    [self restoreLiveCanvasAfterTransition];
}

/* Every animated stack move lands here (host pushes/pops and the
 * interactive gesture alike). The transition coordinator's completion
 * is the one honest place cancellation is knowable: a cancelled swipe
 * completes with isCancelled and dispatches nothing — the model was
 * never touched, so there is nothing to undo. */
- (void)navigationController:(UINavigationController *)navigationController
      willShowViewController:(UIViewController *)viewController
                    animated:(BOOL)animated {
    (void)viewController;
    const BOOL host_initiated = self.navHostTransition;
    self.navHostTransition = NO;
    id<UIViewControllerTransitionCoordinator> coordinator = navigationController.transitionCoordinator;
    if (!animated || !coordinator) return;
    self.navTransitionActive = YES;
    __weak NativeSdkCanvasViewController *weakSelf = self;
    [coordinator animateAlongsideTransition:nil
                                 completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
                                     NativeSdkCanvasViewController *strongSelf = weakSelf;
                                     if (!strongSelf) return;
                                     strongSelf.navTransitionActive = NO;
                                     if (context.isCancelled) return;
                                     if (host_initiated) {
                                         [strongSelf restoreLiveCanvasAfterTransition];
                                         return;
                                     }
                                     [strongSelf completeInteractivePop];
                                 }];
}

/* Arm the REAL edge-swipe-back exactly while the projection says a page
 * is open and a back command exists to dispatch; never mid-transition
 * (a second gesture stacked on a running pop is how stacks corrupt). */
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer == self.navController.interactivePopGestureRecognizer) {
        if (self.navTransitionActive) return NO;
        /* The gesture drags the LIVE canvas, so it only begins while
         * the canvas actually sits on the top page (not during the
         * few covered ticks after a transition lands). */
        NativeSdkNavPageViewController *top = (NativeSdkNavPageViewController *)self.navController.topViewController;
        if (top.contentView != self.canvasView) return NO;
        if (self.navBackCommand.length == 0) return NO;
        return self.navController.viewControllers.count > 1;
    }
    return YES;
}

/* The host-reported form factor: the platform's own horizontal size
 * class, reported over the window-chrome channel so apps switch shells
 * on host truth (width derivation stays their fallback). */
- (void)reportFormFactor {
    if (!self.nativeApp) return;
    int form_factor = NATIVE_SDK_FORM_FACTOR_UNKNOWN;
    switch (self.traitCollection.horizontalSizeClass) {
        case UIUserInterfaceSizeClassCompact: form_factor = NATIVE_SDK_FORM_FACTOR_COMPACT; break;
        case UIUserInterfaceSizeClassRegular: form_factor = NATIVE_SDK_FORM_FACTOR_REGULAR; break;
        default: break;
    }
    if (form_factor == self.reportedFormFactor) return;
    self.reportedFormFactor = form_factor;
    native_sdk_app_set_form_factor(self.nativeApp, form_factor);
    [self logNativeErrorIfAny:@"form_factor"];
    NSLog(@"native-sdk: form factor %s",
          form_factor == NATIVE_SDK_FORM_FACTOR_COMPACT ? "compact"
              : form_factor == NATIVE_SDK_FORM_FACTOR_REGULAR ? "regular"
                                                              : "unknown");
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
