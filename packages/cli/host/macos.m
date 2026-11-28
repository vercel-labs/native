// native macOS host: window, event pump, and a retained display list replayed with
// CoreGraphics + CoreText. Everything above this layer (DOM, style, layout, paint) is
// TypeScript compiled by scriptc.

// WebGL draws through a CGL OpenGL 4.1 core context per canvas. The API is deprecated, which these
// warnings say; it still works, and it is the narrow boundary ANGLE can replace later. AppKit pulls
// in an OpenGL header of its own, so this has to come before every import.
#define GL_SILENCE_DEPRECATION 1

#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>
#import <CoreImage/CoreImage.h>
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>
#include <OpenGL/gl3ext.h>
#include <OpenGL/CGLIOSurface.h>
#include <IOSurface/IOSurface.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <string.h>
#include <math.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <sqlite3.h>
#include "svg-filter.h"
#include "compositor/metal.h"
#include <mach-o/dyld.h>
#include <pthread.h>

enum {
  EV_NONE = 0, EV_QUIT = 1, EV_DOWN = 2, EV_UP = 3, EV_MOVE = 4, EV_RESIZE = 5, EV_LEAVE = 6,
  EV_OTHER = 7, EV_KEY = 8, EV_WHEEL = 9, EV_SETTINGS = 10, EV_AXFOCUS = 11, EV_AXSELRANGE = 12,
  EV_DROP = 13, EV_MENU = 14, EV_CONTEXT = 15, EV_WINDOWMOVE = 16, EV_FULLSCREEN = 17,
  EV_FOCUS = 18, EV_BLUR = 19, EV_VISIBILITY = 20, EV_MESSAGE = 21, EV_WINDOWCLOSED = 22,
  EV_APPQUIT = 23, EV_COMPOSE = 24, EV_KEYUP = 25, EV_AXACTION = 26, EV_IMAGE = 27,
};
enum {
  CMD_FILL = 0, CMD_TEXT = 1, CMD_CLIP = 2, CMD_UNCLIP = 3, CMD_RING = 4, CMD_IMAGE = 5,
  CMD_FILL_ROUND = 6, CMD_RING_ROUND = 7, CMD_CLIP_ROUND = 8,
  CMD_GRADIENT_LINEAR = 9, CMD_GRADIENT_RADIAL = 10, CMD_CANVAS = 11,
  CMD_SHADOW = 12, CMD_SHADOW_INSET = 13, CMD_TEXT_SHADOW = 14, CMD_TRANSFORM = 15,
  CMD_GRADIENT_CONIC = 16, CMD_POLY = 17, CMD_CLIP_POLY = 18, CMD_LINE = 19,
  CMD_EFFECT_PUSH = 20, CMD_EFFECT_POP = 21, CMD_CLIP_ELLIPSE = 22, CMD_CLIP_SHAPE = 23,
  CMD_MASK_PUSH = 24, CMD_MASK_SPLIT = 25, CMD_MASK_POP = 26,
  CMD_PERSPECTIVE_PUSH = 27, CMD_PERSPECTIVE_POP = 28,
  CMD_LAYER_REF = 29, CMD_VIDEO = 30,
};

/** The property kind a scroll container's push carries (shared/props.ts's PK_SCROLL). */
#define CMD_PK_SCROLL 8

// Keys reported by host_event_key(). KEY_TEXT means "insert host_event_text()".
enum {
  KEY_TEXT = 0, KEY_BACKSPACE = 1, KEY_ENTER = 2, KEY_LEFT = 3, KEY_RIGHT = 4, KEY_UP = 5, KEY_DOWN = 6,
  KEY_HOME = 7, KEY_END = 8, KEY_ESCAPE = 9, KEY_TAB = 10, KEY_DELETE = 11, KEY_SELECT_ALL = 12, KEY_OTHER = 13, KEY_COPY = 14,
  KEY_CUT = 15, KEY_PASTE = 16,
};
enum { MOD_META = 1, MOD_SHIFT = 2, MOD_ALT = 4, MOD_CTRL = 8 };

typedef struct {
  int kind;
  // The property-tree node a push opens: the element it belongs to, and its PK_* kind. Drawing
  // commands leave both zero. The replay ignores them; the layerizer reads them.
  int32_t serial;
  int32_t pkind;
  // The layer a CMD_LAYER_REF draws.
  int32_t layer;
  // A number unique within the frame, which the runtime keeps to edit this command in place.
  int32_t handle;
  int32_t image; // decoded image id for CMD_IMAGE
  double x, y, w, h, radius, line_width, line_height, size, weight;
  // The part of an image a CMD_IMAGE draws, in image pixels; an empty rect for the whole image.
  double sx, sy, sw, sh;
  // Corner radii for the rounded-rect commands, two per corner in CSS's order: top-left,
  // top-right, bottom-right, bottom-left, horizontal then vertical.
  double r[8];
  double p0, p1, p2, p3; // gradient geometry: the two ends, or the centre and radii
  // Shadow offset and blur for the shadow commands; `line_width` carries the spread.
  double dx, dy, blur;
  // Letter and word spacing for a text command.
  double letter, word;
  int smooth; // whether an image is drawn with interpolation (image-rendering: auto)
  uint32_t color;
  // The shadow color of a shadowed text run.
  uint32_t shadow_color;
  // The text-emphasis mark a text run draws: its style in the low byte and 1 in the next for a
  // mark under the text, and the colour it is drawn in.
  uint32_t emphasis;
  uint32_t emphasis_color;
  // The projected quad a CMD_PERSPECTIVE_PUSH warps its box to: TL, TR, BR, BL in page space.
  double q[8];
  // An alpha a later frame may set on a composited opacity group without re-recording its spec.
  int alpha_override;
  double alpha;
  char *text;
  size_t len;
} Cmd;

typedef struct {
  Cmd *cmds;
  size_t count, cap;
} CmdList;

// A layer's commands beside the top-level list. The layer's sublist is complete when its pop
// arrives, and the parent list keeps a CMD_LAYER_REF where the layer's box painted.
typedef struct {
  int32_t serial, kind;
  CmdList list;
} LayerEntry;

#define MAX_LAYERS 4096
#define MAX_LAYER_DEPTH 64

static CmdList g_root = { NULL, 0, 0 };
static LayerEntry g_layers[MAX_LAYERS];
static int g_layer_count = 0;
// The list being replayed, and the frame it belongs to, are per thread: a raster worker replays
// a chunk of its own while the main thread draws the frame before it.
static _Thread_local CmdList *g_list = &g_root;
static CmdList *g_parents[MAX_LAYER_DEPTH];
static int32_t g_open_serial[MAX_LAYER_DEPTH];
static int32_t g_open_kind[MAX_LAYER_DEPTH];
static int32_t g_open_layer[MAX_LAYER_DEPTH];
static int g_open_depth = 0;
/** How deep the pushes skipped for want of a layer are: everything inside them paints flat. */
static int g_skip_depth = 0;
/** The list the commands go to now: -1 for the root, else the layer id. */
static int32_t g_cur_list_id = -1;
/** How many commands one list may hold; a handle packs the list id and the index. */
#define CMD_HANDLE_STRIDE 262144

// Layer rasters for the window path.
//
// A layer's commands are rastered once into a bitmap and cached; the window path draws that
// bitmap where the ref sits, so a frame that only moves a transform or fades a group redraws a
// handful of tiles instead of replaying every layer's commands. The flat snapshot path keeps
// replaying the commands, so its pixels are exactly what they always were.

typedef struct {
  CGImageRef image;
  int x, y, w, h; // the ink box, in device pixels
  double scale;   // the scale the raster was made at
} LayerImage;

static LayerImage g_layer_image[MAX_LAYERS];
// Per thread: a raster worker's replay never draws a layer from the cache the window keeps, and
// that cache is the main thread's own.
static _Thread_local int g_layer_images_on = 0;
/** The page size of the frame being replayed, in points. */
static _Thread_local double g_replay_w = 0, g_replay_h = 0;
static uint32_t g_background = 0xffffffff;
/** Set when a frame carries a backdrop-filter, whose pixels only a bitmap can be read back from. */
static int g_needs_backdrop = 0;
/** A compositor frame repaints only the regions that moved, so every backdrop filter it replays
 *  still sees the pixels behind it that the window already holds: it draws the result the last
 *  paint kept instead of filtering again. */
static int g_reuse_backdrops = 0;
/** A throwaway raster — the damage verification's reference frame, the compositor's flat
 *  fallback. It keeps what it filters (it is a full frame, the source a kept backdrop wants) but
 *  never reuses a kept one: it is the reference the frame drawn next is compared with. */
static int g_reference_paint = 0;
/** A damaged frame supplies its own background fills, clipped to the regions it repaints. */
static int g_skip_background = 0;
/** A compositor frame presents an already-recorded list but repaints only its moving layers. */
static int g_present_region = 0;
/** Whether the last full frame the window's compositor drew was chunked: the compositor draws
 *  the frames after it too, and a damaged frame can patch the picture it left. */
static int g_pic_chunked = 0;
// The frame as it was presented, in device pixels, so a damaged frame paints the damaged region
// over the last picture instead of drawing the whole page again. Two textures alternate: the
// last picture is read while this frame's is drawn.
static int g_pic_tex[2] = {-1, -1};
static int g_pic_cur = -1; // the picture the last presented frame made; -1 when there is none
static int g_pic_w = 0, g_pic_h = 0;
static int g_patch_tex = -1, g_patch_w = 0, g_patch_h = 0; // a damaged frame's region raster
static int32_t g_damage_count = 0;
static double g_damage_rects[16][4];
/** A full paint bumps it; a chunk the window's compositor can't key by content keeps its tiles
 *  only within one paint. */
static unsigned long g_paint_serial = 1;
/** Bumped when something a command doesn't name changes how it rasters (a font registered or
 *  reset), so the window's compositor doesn't keep tiles a chunk's own commands still match. */
static unsigned long g_raster_epoch = 1;

static NSWindow *g_window = nil;
static NSView *g_view = nil;
/// Whether the window's frames go through the compositor; defined with the window compositing.
static int window_compositing(void);
/** Whether a headless run composites every frame into a texture; defined with the compositor. */
static int headless_live(void);
/** Composites the frame the paint recorded into the window's drawable; defined with the compositor. */
static int window_composite(void);
/** Set while a damaged display list is being presented: the frame patches the previous chunks. */
static int g_damage_frame = 0;
static int g_quit = 0, g_resized = 0, g_cursor = 0;
/** The window moved, changed key state, was hidden or changed fullscreen; a menu item was chosen;
 *  the app was asked to quit. Each waits for host_poll to hand its event out. */
static int g_moved = 0, g_key_state = 0, g_visibility_changed = 0, g_fullscreen_changed = 0;
static int g_menu_pending = 0, g_menu_index = -1, g_menu_choice = -1, g_menu_popup_open = 0;
static int g_app_quit = 0;
/** Set while the runtime closes the window itself, so the press of the red button's equivalent
 *  doesn't ask the page a second time. */
static int g_close_approved = 0;
/** This window's identity: its id, the name it was opened with, and the window that opened it. */
static int32_t g_win_id = 0, g_opener_id = 0;
static NSString *g_win_name = @"";
static NSString *g_win_title = @"";
/** The pipes to the window that opened this one: fd 3 carries its messages in, fd 4 ours out. */
static int g_parent_write = -1, g_parent_read = -1;
static char *g_parent_buf = NULL;
static size_t g_parent_len = 0, g_parent_cap = 0;
/** The accessibility tree the runtime last handed over, as the JSON of runtime/ax-tree.ts. */
static NSString *g_ax_json = nil;
/** The NSAccessibilityElements built from g_ax_json: the web area's children. */
static NSArray *g_ax_roots = nil;
/** The page's root, AXWebArea, made with the first tree. */
static NSAccessibilityElement *g_ax_web_area = nil;
/** The elements of the last tree by node uid, so the next tree keeps the objects clients hold. */
static NSMutableDictionary *g_ax_by_uid = nil;
/** Whether a client has asked for the tree; the runtime builds none until one does. */
static int g_ax_active = 0;
/** Clients' actions waiting for the runtime, oldest first, and the one EV_AXACTION carries now. */
static NSMutableArray *g_ax_queue = nil;
static int32_t g_ax_action_kind = 0, g_ax_action_uid = 0;
static NSString *g_ax_action_text = nil;
/** The node the tree says holds DOM focus, so a change posts the focused-element notification. */
static NSInteger g_ax_focused_id = 0;
/** The click count of the last mouse-down, as AppKit counted it. */
static int32_t g_clicks = 1;
/** An image cursor a `cursor: url(…)` asked for, or nil for the keyword in g_cursor. */
static NSCursor *g_cursor_image = nil;
static double g_ex = 0, g_ey = 0, g_dx = 0, g_dy = 0;
/** The wheel's gesture phase: 0 none, 1 began, 2 changed, 3 ended, 4 cancelled, then the same
 *  four for the momentum that follows the fingers lifting. */
static int32_t g_wheel_phase = 0;
static int32_t g_key = KEY_OTHER, g_mods = 0, g_key_repeat = 0;
static NSString *g_key_text = @"";
/** An input method's composition: the phase and text the next EV_COMPOSE carries (-1 for none),
 *  the marked text AppKit last gave the view, and where the caret sits in the view, in CSS
 *  pixels, which is where the candidate window is put. */
static int32_t g_compose_phase = -1;
static NSString *g_compose_text = @"";
static NSString *g_marked_text = nil;
static int g_key_pending = 0;
static double g_caret_x = 0, g_caret_y = 0, g_caret_w = 1, g_caret_h = 16;
/** The files a drag from outside the app dropped on the window, waiting for EV_DROP. */
static NSArray<NSString *> *g_drop_files = nil;
static int g_drop_pending = 0;
static NSMutableDictionary<NSString *, NSFont *> *g_fonts = nil;

// Filled in with the line, font and metric caches below; registration and reset drop them.
static void clear_text_caches(void);
static CTFontRef font_ref(NSFont *f);

static NSString *str_from(const uint8_t *s, size_t n);
static int32_t new_window_id(void);
static void apply_menu_bar(void);
static void close_children(void);
static void set_fill(CGContextRef ctx, uint32_t c);
static void set_stroke(CGContextRef ctx, uint32_t c);
static double device_round(double v);
static CGRect snapped_rect(double x, double y, double w, double h);

// ---------------------------------------------------------------------------
// Fonts and text

static NSFontWeight weight_for(double w) {
  if (w < 150) return NSFontWeightUltraLight;
  if (w < 250) return NSFontWeightThin;
  if (w < 350) return NSFontWeightLight;
  if (w < 450) return NSFontWeightRegular;
  if (w < 550) return NSFontWeightMedium;
  if (w < 650) return NSFontWeightSemibold;
  if (w < 750) return NSFontWeightBold;
  if (w < 850) return NSFontWeightHeavy;
  return NSFontWeightBlack;
}

// One @font-face: the descriptor its file gave, the family it belongs to (family id minus
// FF_CUSTOM), and the CSS weight range and style it covers. A family can have several faces.
@interface HFontFace : NSObject
@property (nonatomic, strong) NSFontDescriptor *desc;
@property (nonatomic) int family;
@property (nonatomic) double lo;
@property (nonatomic) double hi;
@property (nonatomic) int italic;
// The face's unicode-range as "lo-hi" pairs joined by commas; "" when it covers everything.
@property (nonatomic, strong) NSString *ranges;
// The face's own font-feature-settings, and the font-stretch percentage it covers.
@property (nonatomic, strong) NSString *features;
@property (nonatomic) double stretch;
@end
@implementation HFontFace
@end

static NSMutableArray<HFontFace *> *g_faces = nil;

/**
 * Forgets every @font-face the last page registered, and the fonts made from them: a batch runs
 * its pages in one process, and each page's custom families start at the same family ids, so a
 * face left behind would answer for the next page's family of that id.
 */

void host_register_font(const uint8_t *path, size_t path_len, double family, double lo, double hi,
                        double italic, const uint8_t *ranges, size_t ranges_len,
                        const uint8_t *features, size_t features_len, double stretch) {
  clear_text_caches();
  g_raster_epoch++;
  @autoreleasepool {
    if (!g_faces) g_faces = [NSMutableArray array];
    NSString *p = str_from(path, path_len);
    NSURL *url = [NSURL fileURLWithPath:p];
    CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url, kCTFontManagerScopeProcess, NULL);
    NSArray *descs = CFBridgingRelease(CTFontManagerCreateFontDescriptorsFromURL((__bridge CFURLRef)url));
    HFontFace *face = [HFontFace new];
    // The file's own descriptor stays as it is: @font-face usually names the family something
    // else, and fontDescriptorWithFamily: on a descriptor that came from a file makes one
    // CoreText can't resolve, which would silently fall back to the system font. The family is
    // only a label anyway: face_for picks the face by the id stored here.
    face.desc = descs.count > 0 ? descs[0] : [NSFont systemFontOfSize:12].fontDescriptor;
    face.family = (int)family;
    face.lo = lo;
    face.hi = hi;
    face.italic = italic != 0;
    face.ranges = ranges_len > 0 ? str_from(ranges, ranges_len) : @"";
    face.features = features_len > 0 ? str_from(features, features_len) : @"";
    face.stretch = stretch;
    [g_faces addObject:face];
  }
}

static NSFont *system_design(double size, double w, NSFontDescriptorSystemDesign design);
// Cache of cascade-entry fonts: the run's base font and the line's chosen font must be the
// same object, or re-tagging a stretch of the line can shift its advances.
static NSMutableDictionary<NSString *, NSFont *> *g_entry_fonts = nil;
static void add_family_faces(NSFont *base, int family, NSString *ranges);

// A face the system already has, named by local() in an @font-face src. The descriptor is the
// font's own, so a name the system resolves to a real font becomes a face of the rule's family.
// Returns 1 when the name resolved, 0 when the system has no such font: the runtime then tries
// the next source of the rule.
int32_t host_register_font_local(const uint8_t *name, size_t name_len, double family, double lo,
  double hi, double italic, const uint8_t *ranges, size_t ranges_len,
  const uint8_t *features, size_t features_len, double stretch) {
  clear_text_caches();
  g_raster_epoch++;
  @autoreleasepool {
    NSString *n = str_from(name, name_len);
    // A local() may name one of the standard font families as well as an installed face: the
    // system UI keywords open the system's design of that name, as a font-family would.
    NSString *key = n.lowercaseString;
    NSFont *design = nil;
    if ([key isEqualToString:@"ui-serif"]) design = system_design(12, 400, NSFontDescriptorSystemDesignSerif);
    else if ([key isEqualToString:@"ui-rounded"]) design = system_design(12, 400, NSFontDescriptorSystemDesignRounded);
    else if ([key isEqualToString:@"ui-monospace"]) design = system_design(12, 400, NSFontDescriptorSystemDesignMonospaced);
    else if ([key isEqualToString:@"ui-sans-serif"] || [key isEqualToString:@"system-ui"] ||
             [key isEqualToString:@"-apple-system"] || [key isEqualToString:@"blinkmacsystemfont"]) {
      design = [NSFont systemFontOfSize:12];
    }
    // A standard family is a family, not one face: it brings its own bold and italic, as the
    // design is a whole family in the system.
    if (design != nil) {
      add_family_faces(design, (int)family, ranges_len > 0 ? str_from(ranges, ranges_len) : @"");
      return 1;
    }
    NSFont *font = [NSFont fontWithName:n size:12];
    if (font == nil) return 0;
    if (!g_faces) g_faces = [NSMutableArray array];
    HFontFace *face = [HFontFace new];
    face.desc = font.fontDescriptor;
    face.family = (int)family;
    face.lo = lo;
    face.hi = hi;
    face.italic = italic != 0;
    face.ranges = ranges_len > 0 ? str_from(ranges, ranges_len) : @"";
    face.features = features_len > 0 ? str_from(features, features_len) : @"";
    face.stretch = stretch;
    [g_faces addObject:face];
    return 1;
  }
}


// An installed family named by a font-family list, as a browser picks it: the system's own faces
// of that family, so its bold and italic are real ones rather than drawn in. Each face is
// registered with the weight range and style it covers, the way a @font-face face is; a trait the
// family has no face for is left out, and the text gets the synthesized one instead.
static void add_named_face(NSFont *font, int family, double lo, double hi, BOOL italic, NSString *ranges) {
  if (font == nil) return;
  if (!g_faces) g_faces = [NSMutableArray array];
  HFontFace *face = [HFontFace new];
  face.desc = font.fontDescriptor;
  face.family = family;
  face.lo = lo;
  face.hi = hi;
  face.italic = italic ? 1 : 0;
  face.ranges = ranges ?: @"";
  face.features = @"";
  face.stretch = 100;
  [g_faces addObject:face];
}

// Registers a family's faces from one of them: the regular face, and the bold and italic the
// system can make of it, each with the weight range and style it covers.
static void add_family_faces(NSFont *base, int fam, NSString *ranges) {
  if (base == nil) return;
  NSFontManager *fm = [NSFontManager sharedFontManager];
  add_named_face(base, fam, 400, 400, NO, ranges);
  NSFont *bold = [fm convertFont:base toHaveTrait:NSBoldFontMask];
  if (bold != nil && ([fm traitsOfFont:bold] & NSBoldFontMask) != 0) add_named_face(bold, fam, 600, 900, NO, ranges);
  NSFont *ital = [fm convertFont:base toHaveTrait:NSItalicFontMask];
  if (ital != nil && ([fm traitsOfFont:ital] & NSItalicFontMask) != 0) add_named_face(ital, fam, 400, 400, YES, ranges);
  if (bold != nil && ital != nil) {
    NSFont *bi = [fm convertFont:bold toHaveTrait:NSItalicFontMask];
    if (bi != nil && ([fm traitsOfFont:bi] & NSItalicFontMask) != 0 && ([fm traitsOfFont:bi] & NSBoldFontMask) != 0) {
      add_named_face(bi, fam, 600, 900, YES, ranges);
    }
  }
}

// Returns 1 when the system resolved the name to a font, 0 when it has none: the family then falls
// back the way an unknown family does.
int32_t host_register_font_named(const uint8_t *name, size_t name_len, double family) {
  clear_text_caches();
  g_raster_epoch++;
  @autoreleasepool {
    NSString *n = str_from(name, name_len);
    NSFont *base = [NSFont fontWithName:n size:12];
    if (base == nil) return 0;
    add_family_faces(base, (int)family, @"");
    return 1;
  }
}

// The settings a run asks of its font besides its face: OpenType features, variation axes, the
// kinds of face it may synthesize (weight 1, style 2, small caps 4), and the colour palette it
// draws its COLR glyphs with.
@interface HFontRun : NSObject
@property NSArray *features;
@property NSDictionary *variations;
@property int synth;
@property int palette;
@property NSDictionary *paletteColors;
// font-size-adjust: the x-height to font-size ratio the text aims for, or -1 for none.
@property double adjust;
// font-kerning: 1 for normal, 0 for none, -1 for auto (the font's own default).
@property int kerning;
// font-stretch: the width the text asks for, as a percentage of normal.
@property double stretch;
// The families after the first in a font-family list, as cascade entries, and whether the
// primary face is restricted to a unicode-range (so CoreText falls the rest of the text to them).
@property NSArray *cascade;
// The language the text is in, as a BCP 47 tag: the system's own fallback follows it, so the font
// a script gets is the one its language asks for.
@property NSString *lang;
@end
@implementation HFontRun
@end

// One cascade entry: the CSS family value, and the palette (if any) its own rule gives it.
@interface HFontFallback : NSObject
@property int family;
@property int palette;
@property NSDictionary *paletteColors;
@end
@implementation HFontFallback
@end

// One run per distinct combination, in registration order. A run arrives as sections: feature
// settings and variation axes, each a list of `tag=value` pairs joined by semicolons, the
// synthesis mask, and the colour palette, each behind a letter:
// `f:liga=0;tnum=1|v:wght=700|s:7|p:2:3=ff00ffff,7=ff0000ff`.
static NSMutableArray<HFontRun *> *g_font_runs = nil;

// CoreText's font descriptor keys for a colour font's palette and its overridden colours. The
// SDK headers don't declare them, but the framework exports them, and a descriptor takes the
// palette index and a dictionary of palette-entry index to CGColor.
extern const CFStringRef kCTFontPaletteAttribute;
extern const CFStringRef kCTFontPaletteColorsAttribute;

// The four-character code CoreText names a variation axis by, such as 'wght'.
static uint32_t axis_code(NSString *tag) {
  uint32_t code = 0;
  for (NSUInteger i = 0; i < 4; i++) {
    unichar c = i < tag.length ? [tag characterAtIndex:i] : 0;
    code = code << 8 | (c & 0xFF);
  }
  return code;
}

double host_register_features(const uint8_t *spec, size_t spec_len) {
  @autoreleasepool {
    if (!g_font_runs) g_font_runs = [NSMutableArray array];
    HFontRun *run = [HFontRun new];
    run.features = @[];
    run.variations = @{};
    run.synth = 7;
    run.palette = -1;
    run.paletteColors = @{};
    run.adjust = -1;
    run.kerning = -1;
    run.stretch = 100;
    run.lang = @"";
    run.cascade = @[];
    NSString *text = str_from(spec, spec_len);
    for (NSString *section in [text componentsSeparatedByString:@"|"]) {
      if (section.length < 2) continue;
      NSString *body = [section substringFromIndex:2];
      if ([section hasPrefix:@"s:"]) {
        run.synth = [body intValue];
        continue;
      }
      if ([section hasPrefix:@"t:"]) {
        run.stretch = [body doubleValue];
        continue;
      }
      if ([section hasPrefix:@"k:"]) {
        run.kerning = [body intValue];
        continue;
      }
      if ([section hasPrefix:@"g:"]) {
        run.lang = body;
        continue;
      }
      if ([section hasPrefix:@"a:"]) {
        run.adjust = [body doubleValue];
        continue;
      }
      if ([section hasPrefix:@"p:"]) {
        // The palette index, then any entry overrides as `index=rrggbbaa` pairs.
        NSArray *parts = [body componentsSeparatedByString:@":"];
        run.palette = [[parts objectAtIndex:0] intValue];
        NSMutableDictionary *colors = [NSMutableDictionary dictionary];
        if (parts.count > 1) {
          static CGColorSpaceRef srgb = NULL;
          if (!srgb) srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
          for (NSString *pair in [[parts objectAtIndex:1] componentsSeparatedByString:@","]) {
            NSRange eq = [pair rangeOfString:@"="];
            if (eq.location == NSNotFound) continue;
            unsigned int hex = 0;
            NSScanner *scan = [NSScanner scannerWithString:[pair substringFromIndex:eq.location + 1]];
            if (![scan scanHexInt:&hex]) continue;
            CGFloat comps[4] = {
              ((hex >> 24) & 255) / 255.0, ((hex >> 16) & 255) / 255.0,
              ((hex >> 8) & 255) / 255.0, (hex & 255) / 255.0,
            };
            CGColorRef col = CGColorCreate(srgb, comps);
            colors[@([[pair substringToIndex:eq.location] intValue])] = (__bridge id)col;
            CGColorRelease(col);
          }
        }
        run.paletteColors = colors;
        continue;
      }
      if ([section hasPrefix:@"c:"]) {
        // Cascade entries separated by semicolons, each `family` or `family=palette[:colours]`.
        NSMutableArray *cascade = [NSMutableArray array];
        for (NSString *entry in [body componentsSeparatedByString:@";"]) {
          if (entry.length == 0) continue;
          HFontFallback *fb = [HFontFallback new];
          fb.palette = -1;
          fb.paletteColors = @{};
          NSRange eq = [entry rangeOfString:@"="];
          if (eq.location == NSNotFound) {
            fb.family = [entry intValue];
          } else {
            fb.family = [[entry substringToIndex:eq.location] intValue];
            NSString *rest = [entry substringFromIndex:eq.location + 1];
            NSRange colon = [rest rangeOfString:@":"];
            NSString *palText = colon.location == NSNotFound ? rest : [rest substringToIndex:colon.location];
            fb.palette = [palText intValue];
            if (colon.location != NSNotFound) {
              NSMutableDictionary *colors = [NSMutableDictionary dictionary];
              static CGColorSpaceRef srgb2 = NULL;
              if (!srgb2) srgb2 = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
              for (NSString *pair in [[rest substringFromIndex:colon.location + 1] componentsSeparatedByString:@","]) {
                NSRange e2 = [pair rangeOfString:@"="];
                if (e2.location == NSNotFound) continue;
                unsigned int hex = 0;
                NSScanner *scan = [NSScanner scannerWithString:[pair substringFromIndex:e2.location + 1]];
                if (![scan scanHexInt:&hex]) continue;
                CGFloat comps[4] = {
                  ((hex >> 24) & 255) / 255.0, ((hex >> 16) & 255) / 255.0,
                  ((hex >> 8) & 255) / 255.0, (hex & 255) / 255.0,
                };
                CGColorRef col = CGColorCreate(srgb2, comps);
                colors[@([[pair substringToIndex:e2.location] intValue])] = (__bridge id)col;
                CGColorRelease(col);
              }
              fb.paletteColors = colors;
            }
          }
          [cascade addObject:fb];
        }
        run.cascade = cascade;
        continue;
      }
      BOOL variations = [section hasPrefix:@"v:"];
      if (!variations && ![section hasPrefix:@"f:"]) continue;
      NSMutableArray *settings = [NSMutableArray array];
      NSMutableDictionary *axes = [NSMutableDictionary dictionary];
      for (NSString *pair in [body componentsSeparatedByString:@";"]) {
        NSRange eq = [pair rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *tag = [pair substringToIndex:eq.location];
        NSString *v = [pair substringFromIndex:eq.location + 1];
        if (tag.length != 4) continue;
        if (variations) axes[@(axis_code(tag))] = @(v.doubleValue);
        else {
          [settings addObject:@{
            (__bridge id)kCTFontOpenTypeFeatureTag: tag,
            (__bridge id)kCTFontOpenTypeFeatureValue: @(v.intValue),
          }];
        }
      }
      if (variations) run.variations = axes;
      else run.features = settings;
    }
    [g_font_runs addObject:run];
    return (double)g_font_runs.count;
  }
}

// Whether the host draws the run's glyphs thicker or slanted itself, because the family has no
// bold or italic face: one dictionary per kind, keyed like the font cache.
static NSMutableDictionary<NSString *, NSNumber *> *g_fake_bold = nil;
static NSMutableDictionary<NSString *, NSNumber *> *g_fake_italic = nil;

static BOOL fake_flag(NSMutableDictionary<NSString *, NSNumber *> *d, double size, double weight) {
  if (!d) return NO;
  NSNumber *flag = d[[NSString stringWithFormat:@"%g/%g", size, weight]];
  return flag.boolValue;
}

static BOOL font_is_fake_bold(double size, double weight) { return fake_flag(g_fake_bold, size, weight); }
static BOOL font_is_fake_italic(double size, double weight) { return fake_flag(g_fake_italic, size, weight); }

// A page's faces belong to it: a family id is an index into the page's own tables, so a batch that
// renders several pages in one process starts each page without the last one's faces, and the
// resolved fonts cached by the packed weight (which carries the family) go with them.
// The line-break opportunities a page asked for, in registration order (see the ICU helpers below).
static NSMutableDictionary *g_break_ids = nil;  // "value|locale|text" -> id
static NSMutableArray *g_break_lists = nil;    // id - 1 -> the offsets it breaks at

// Measuring or painting the same text again should not shape it again, and the font's metrics do
// not change between frames. One cache per thread keeps the main thread out of the raster
// workers' way; a font change bumps a generation and each thread drops its own cache on its next
// lookup. Lines are keyed by the runtime's text pointer, so a hit is a probe and a memcmp rather
// than a fresh key, hash or copy; the CTFont is resolved once per font so new streamed text does
// not match a descriptor for every line.
typedef struct {
  double size, weight, scale;
  double ascent, descent, gap, x_height;      // CSS px
  double ascent_dev, descent_dev, gap_dev;    // whole device pixels
} TextMetric;
#define TEXT_METRIC_SLOTS 256

// One line the host has shaped, with a copy of its bytes to check a match. A pointer cache in
// front of the table turns the common case (the runtime hands back the same buffer every frame)
// into a pointer probe and a memcmp, with no string, key, hash or dictionary allocation; a new
// buffer with the same text still hits through the content table.
typedef struct {
  uint32_t len;
  int resolved;      // built with the resolved CTFont (measurement) rather than the NSFont
  double size;
  double weight;
  double letter;
  double word;
  char *text;
  CTLineRef line;
} LineEntry;
#define LINE_SLOTS 512

typedef struct {
  const void *ptr;
  uint32_t len;
  int resolved;
  double size;
  double weight;
  double letter;
  double word;
  LineEntry *entry;
} PtrEntry;
#define PTR_SLOTS 256

@interface HTextCache : NSObject {
@public
  int generation;
  int metric_count;
  TextMetric metrics[TEXT_METRIC_SLOTS];
  LineEntry lines[LINE_SLOTS];
  PtrEntry ptrs[PTR_SLOTS];
}
@property (nonatomic, strong) NSMapTable<NSFont *, id> *fonts;
@end

@implementation HTextCache
- (instancetype)init {
  if ((self = [super init]) != nil) {
    _fonts = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory |
                      NSPointerFunctionsObjectPointerPersonality
                                  valueOptions:NSPointerFunctionsStrongMemory];
    generation = -1;
  }
  return self;
}
- (void)dealloc {
  for (int i = 0; i < LINE_SLOTS; i++) {
    if (lines[i].line != NULL) CFRelease(lines[i].line);
    free(lines[i].text);
  }
}
@end

static _Atomic int g_text_generation = 0;

static void clear_thread_lines(HTextCache *cache) {
  for (int i = 0; i < LINE_SLOTS; i++) {
    LineEntry *entry = &cache->lines[i];
    if (entry->line != NULL) CFRelease(entry->line);
    free(entry->text);
    memset(entry, 0, sizeof(*entry));
  }
  memset(cache->ptrs, 0, sizeof(cache->ptrs));
}

static HTextCache *thread_text_cache(void) {
  NSMutableDictionary *thread = [[NSThread currentThread] threadDictionary];
  HTextCache *cache = thread[@"htmlc.text.cache"];
  if (cache == nil) {
    cache = [HTextCache new];
    thread[@"htmlc.text.cache"] = cache;
  }
  int generation = atomic_load(&g_text_generation);
  if (cache->generation != generation) {
    clear_thread_lines(cache);
    [cache.fonts removeAllObjects];
    cache->metric_count = 0;
    cache->generation = generation;
  }
  return cache;
}

void host_reset_fonts(void) {
  clear_text_caches();
  g_raster_epoch++;
  if (g_faces) [g_faces removeAllObjects];
  if (g_fonts) [g_fonts removeAllObjects];
  if (g_entry_fonts) [g_entry_fonts removeAllObjects];
  if (g_fake_bold) [g_fake_bold removeAllObjects];
  if (g_fake_italic) [g_fake_italic removeAllObjects];
  if (g_break_ids) [g_break_ids removeAllObjects];
  if (g_break_lists) [g_break_lists removeAllObjects];
}


// Line break opportunities come from the system's ICU — the same UAX #14 implementation a
// browser uses — so a run breaks where Chrome's does. The locale carries the line-break value as
// ICU's `lb` keyword (strict, normal, loose); the positions are registered once per run of text,
// language and value, and read back by index, which keeps the FFI to plain numbers. ICU is opened
// by name rather than linked, so a system without it only loses the extra opportunities.
typedef uint16_t UChar;
typedef struct UBreakIterator UBreakIterator;

static UBreakIterator *(*p_ubrk_open)(int32_t, const char *, const UChar *, int32_t, int32_t *);
static int32_t (*p_ubrk_first)(UBreakIterator *);
static int32_t (*p_ubrk_next)(UBreakIterator *);
static void (*p_ubrk_close)(UBreakIterator *);
static int32_t (*p_u_getIntPropertyValue)(int32_t, int32_t);

static BOOL load_icu(void) {
  static int state = 0;  // 0 unknown, 1 loaded, 2 missing
  if (state == 0) {
    void *lib = dlopen("/usr/lib/libicucore.dylib", RTLD_LAZY);
    if (lib != NULL) {
      p_ubrk_open = dlsym(lib, "ubrk_open");
      p_ubrk_first = dlsym(lib, "ubrk_first");
      p_ubrk_next = dlsym(lib, "ubrk_next");
      p_ubrk_close = dlsym(lib, "ubrk_close");
      p_u_getIntPropertyValue = dlsym(lib, "u_getIntPropertyValue");
    }
    state = (p_ubrk_open && p_ubrk_first && p_ubrk_next && p_ubrk_close) ? 1 : 2;
  }
  return state == 1;
}

// The prefix characters CSS keeps off the start of a line (UAX #14 class PR), and the
// inseparable ones `line-break: loose` lets it start with (class IN).
static BOOL css_prefix_char(uint32_t c) {
  return c == 0x00B1 || c == 0x20AC || c == 0x2116 || c == 0xFE69 || c == 0xFF04 || c == 0xFFE1 ||
    c == 0xFFE5 || c == 0xFFE6;
}

// Whether the text is in a language whose typography the line-break values tailors: the prefix
// rule is CJK's, and a German or unknown-language run keeps the default UAX #14 behavior.
static BOOL css_cjk_locale(NSString *lang) {
  NSString *l = [lang lowercaseString];
  return [l hasPrefix:@"ja"] || [l hasPrefix:@"zh"] || [l hasPrefix:@"ko"];
}

static BOOL css_inseparable_char(uint32_t c) {
  return c == 0x2024 || c == 0x2025 || c == 0x2026 || c == 0x22EF || c == 0xFE19;
}

static NSArray *icu_line_breaks(NSString *text, NSString *lang, int lb) {
  NSUInteger n = text.length;
  UChar *buf = malloc(sizeof(UChar) * (n > 0 ? n : 1));
  if (buf == NULL) return @[];
  [text getCharacters:buf range:NSMakeRange(0, n)];
  char locale[128];
  const char *base = (lang.length > 0 ? lang : @"en").UTF8String;
  // CSS's line-break values are ICU's lb keywords: without one, ICU takes the locale's own
  // default (strict for Japanese and Chinese), which is not what `normal` asks for.
  const char *kw = lb == 3 ? "@lb=strict" : lb == 2 ? "@lb=normal" : lb == 1 ? "@lb=loose" : "";
  snprintf(locale, sizeof(locale), "%s%s", base != NULL ? base : "en", kw);
  int32_t status = 0;
  UBreakIterator *bi = p_ubrk_open(2 /* UBRK_LINE */, locale, buf, (int32_t)n, &status);
  NSMutableArray *out = [NSMutableArray array];
  if (bi != NULL) {
    for (int32_t p = p_ubrk_first(bi); p != -1 /* UBRK_DONE */; p = p_ubrk_next(bi)) {
      if (p > 0 && p < (int32_t)n) [out addObject:@(p)];
    }
    p_ubrk_close(bi);
  }
  // CSS's line-break values go past UAX #14 in two places a browser settles itself: a prefix
  // character (PR: ± € № ﹩ ＄ ￡ ￥ ￦) does not start a line under `strict` or `normal`, and an
  // inseparable character (IN: … ‥ ⋯ ︙) may under `loose`.
  if ((lb == 2 || lb == 3) && css_cjk_locale(lang)) {
    NSMutableArray *kept = [NSMutableArray array];
    for (NSNumber *o in out) {
      NSUInteger at = o.unsignedIntegerValue;
      uint32_t c = at < n ? buf[at] : 0;
      if (!css_prefix_char(c)) [kept addObject:o];
    }
    out = kept;
  } else if (lb == 1) {
    NSMutableIndexSet *seen = [NSMutableIndexSet indexSet];
    for (NSNumber *o in out) [seen addIndex:o.unsignedIntegerValue];
    for (NSUInteger i = 1; i < n; i++) {
      if (css_inseparable_char(buf[i]) && ![seen containsIndex:i]) {
        [out addObject:@((int32_t)i)];
      }
    }
    [out sortUsingSelector:@selector(compare:)];
  }
  free(buf);
  return out;
}

int32_t host_register_line_breaks(const uint8_t *text, size_t n, const uint8_t *lang, size_t lang_len,
                                  int32_t lb) {
  @autoreleasepool {
    NSString *t = str_from(text, n);
    // A run that is only letters, digits and spaces breaks where the space handling below breaks
    // it, and a huge one would only fill the cache.
    if (t.length == 0 || t.length > 8192 || !load_icu()) return 0;
    NSString *l = str_from(lang, lang_len);
    if (g_break_ids == nil) {
      g_break_ids = [NSMutableDictionary dictionary];
      g_break_lists = [NSMutableArray array];
    }
    NSString *key = [NSString stringWithFormat:@"%d|%@|%@", lb, l, t];
    NSNumber *hit = g_break_ids[key];
    if (hit != nil) return hit.intValue;
    [g_break_lists addObject:icu_line_breaks(t, l, lb)];
    int32_t id = (int32_t)g_break_lists.count;
    g_break_ids[key] = @(id);
    return id;
  }
}

int32_t host_line_break_count(int32_t id) {
  if (g_break_lists == nil || id <= 0 || id > (int32_t)g_break_lists.count) return 0;
  return (int32_t)[g_break_lists[(NSUInteger)(id - 1)] count];
}

int32_t host_line_break_at(int32_t id, int32_t i) {
  if (g_break_lists == nil || id <= 0 || id > (int32_t)g_break_lists.count) return -1;
  NSArray *list = g_break_lists[(NSUInteger)(id - 1)];
  if (i < 0 || i >= (int32_t)list.count) return -1;
  return [list[(NSUInteger)i] intValue];
}

/**
 * Whether a soft wrap opportunity next to an atomic inline is suppressed by the character on the
 * other side. CSS adds the opportunity itself, past what UAX #14 would give (a no-break space, a
 * colon or other punctuation still lets the atomic box wrap), except for the characters whose own
 * line-break class glues them to what follows or precedes: GL, CM, WJ and ZWJ. U+00A0 is the one
 * glue that leaves the opportunity in place, as CSS Text asks.
 */
int32_t host_atomic_break_forbidden(int32_t cp) {
  if (cp <= 0 || cp > 0x10FFFF) return 0;
  if (cp == 0x00A0) return 0;
  if (!load_icu() || p_u_getIntPropertyValue == NULL) return 0;
  int32_t cls = p_u_getIntPropertyValue(cp, 0x1008 /* UCHAR_LINE_BREAK */);
  return cls == 9 /* CM */ || cls == 12 /* GL */ || cls == 30 /* WJ */ || cls == 42 /* ZWJ */;
}

/// The text matrix every run draws with: glyphs are y-up, and the display list's space is y-down,
/// so the text matrix turns them over once.
static CGAffineTransform upright_text_matrix(void) { return CGAffineTransformMakeScale(1, -1); }

/// The text matrix that slants a run the host italicizes itself: the same turn over as any other
/// run, and a shear of a quarter of the glyphs' height on top of it, which is about the slant of
/// an italic face. The glyphs' baseline stays where the run put it, so its advance is unchanged,
/// as a browser's synthetic oblique leaves it.
static CGAffineTransform fake_italic_matrix(void) {
  return CGAffineTransformMake(1, 0, 0.25, -1, 0, 0);
}

// How far a text-emphasis mark's centre sits beyond the font's ascent or descent, and how big
// each shape is, both in ems: the gap leaves the mark clear of the tallest and lowest letters,
// and the sizes are the ones a browser draws, where an open mark is about twice a filled dot.
static double emphasis_gap(double size) { return size * 0.17; }

// Fills a disc, or strokes a ring, of `diameter` centred at (cx, cy). A ring is drawn inside the
// diameter, so an open mark and a filled one of the same size cover the same box.
static void emphasis_disc(CGContextRef ctx, double cx, double cy, double diameter, double ring) {
  if (ring <= 0) {
    CGContextFillEllipseInRect(ctx, CGRectMake(cx - diameter / 2, cy - diameter / 2, diameter, diameter));
    return;
  }
  double r = diameter / 2 - ring / 2;
  CGContextSetLineWidth(ctx, ring);
  CGContextStrokeEllipseInRect(ctx, CGRectMake(cx - r, cy - r, 2 * r, 2 * r));
}

/// The dot an emphasis mark is filled with, slanted a quarter turn for a sesame. The space is
/// y down, so the slant leans the way a sesame's does on the page.
static void emphasis_sesame(CGContextRef ctx, double cx, double cy, double size, double ring) {
  CGContextSaveGState(ctx);
  CGContextTranslateCTM(ctx, cx, cy);
  CGContextRotateCTM(ctx, -M_PI / 4);
  CGRect r = CGRectMake(-size * 0.175, -size * 0.1, size * 0.35, size * 0.2);
  if (ring <= 0) CGContextFillEllipseInRect(ctx, r);
  else {
    CGContextSetLineWidth(ctx, ring);
    CGContextStrokeEllipseInRect(ctx, r);
  }
  CGContextRestoreGState(ctx);
}

/// One emphasis mark, centred at (cx, cy) in the display list's space. `style` is a TEXTE_* id:
/// the shapes come as a filled one and then its open kind, so a style's shape is its half and its
/// fill is how odd it is.
static void draw_emphasis_mark(CGContextRef ctx, int style, double cx, double cy, double size) {
  int shape = (style - 1) / 2;
  BOOL open = (style % 2) == 0;
  switch (shape) {
    case 0: // dot: a small disc, or a ring of the circle's size
      if (open) emphasis_disc(ctx, cx, cy, size * 0.22, size * 0.03);
      else emphasis_disc(ctx, cx, cy, size * 0.125, 0);
      break;
    case 1: // circle
      emphasis_disc(ctx, cx, cy, size * 0.22, open ? size * 0.055 : 0);
      break;
    case 2: // double-circle: a ring with a smaller one inside it
      emphasis_disc(ctx, cx, cy, size * 0.45, open ? size * 0.025 : size * 0.075);
      if (open) emphasis_disc(ctx, cx, cy, size * 0.2, size * 0.025);
      else emphasis_disc(ctx, cx, cy, size * 0.2, 0);
      break;
    case 3: // triangle, pointing away from the text
      {
        double w = size * 0.225;
        double h = size * 0.2;
        CGContextMoveToPoint(ctx, cx, cy - h);
        CGContextAddLineToPoint(ctx, cx - w, cy + h / 2);
        CGContextAddLineToPoint(ctx, cx + w, cy + h / 2);
        CGContextClosePath(ctx);
        if (open) {
          CGContextSetLineWidth(ctx, size * 0.03);
          CGContextStrokePath(ctx);
        } else {
          CGContextFillPath(ctx);
        }
      }
      break;
    default: // sesame: a dot drawn aslant
      emphasis_sesame(ctx, cx, cy, size, open ? size * 0.03 : 0);
      break;
  }
}

/// The marks of a run: one per glyph that takes up room, centred on the glyph's advance, above or
/// below the whole line by the font's own ascent or descent. `baseline` is where the line's
/// baseline sits in the display list's space, and `spec` packs the style in its low byte and 1 in
/// the next for a mark under the text.
static void draw_emphasis(CGContextRef ctx, CTLineRef line, double x, double baseline, double size,
                          NSFont *font, int spec, uint32_t color) {
  int style = spec & 0xff;
  if (style <= 0) return;
  double cy = (spec >> 8) & 1
    ? baseline + (-font.descender + emphasis_gap(size))
    : baseline - (font.ascender + emphasis_gap(size));
  CGContextSaveGState(ctx);
  set_fill(ctx, color);
  set_stroke(ctx, color);
  CFArrayRef runs = CTLineGetGlyphRuns(line);
  CFIndex count = CFArrayGetCount(runs);
  for (CFIndex i = 0; i < count; i++) {
    CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, i);
    CFIndex n = CTRunGetGlyphCount(run);
    if (n <= 0) continue;
    CGPoint *pos = malloc((size_t)n * sizeof(CGPoint));
    CGSize *adv = malloc((size_t)n * sizeof(CGSize));
    if (!pos || !adv) { free(pos); free(adv); continue; }
    CTRunGetPositions(run, CFRangeMake(0, n), pos);
    CTRunGetAdvances(run, CFRangeMake(0, n), adv);
    for (CFIndex g = 0; g < n; g++) {
      // A combining mark adds no advance of its own: it shares the mark of the glyph it sits on.
      if (adv[g].width <= 0) continue;
      draw_emphasis_mark(ctx, style, device_round(x + pos[g].x + adv[g].width / 2), cy, size);
    }
    free(pos);
    free(adv);
  }
  CGContextRestoreGState(ctx);
}

/// The glyphs of a run the host bolded itself are stroked as they are filled, by a stroke a
/// twenty-fourth of the font size wide, as browsers embolden text by about that much.
static void fake_bold_stroke(CGContextRef ctx, double size, uint32_t color) {
  CGContextSetTextDrawingMode(ctx, kCGTextFillStroke);
  CGContextSetLineWidth(ctx, size / 24.0);
  CGContextSetRGBStrokeColor(ctx, ((color >> 24) & 255) / 255.0, ((color >> 16) & 255) / 255.0,
                             ((color >> 8) & 255) / 255.0, (color & 255) / 255.0);
}

// The system font in one of its designs — New York, SF Rounded, SF Mono — at a size and weight,
// or nil when this system has no such design.
static NSFont *system_design(double size, double w, NSFontDescriptorSystemDesign design) {
  if (@available(macOS 10.15, *)) {
    NSFontDescriptor *d = [[NSFont systemFontOfSize:size weight:weight_for(w)].fontDescriptor
      fontDescriptorWithDesign:design];
    NSFont *f = d != nil ? [NSFont fontWithDescriptor:d size:size] : nil;
    if (f != nil) return f;
  }
  return nil;
}

// How far a face's weight range is from the wanted weight, in CSS's search order: a face that
// covers the weight comes first; below 400 the lighter faces are tried first, above 500 the
// heavier ones, and in 400..500 the range is tried before either side. Ties go to the nearer one.
static double weight_distance(double w, double lo, double hi) {
  if (w >= lo && w <= hi) return 0;
  BOOL above = lo > w;
  double near = above ? lo - w : w - hi;
  int cat;
  if (w < 400) cat = above ? 2 : 1;
  else if (w > 500) cat = above ? 1 : 2;
  else cat = above ? 3 : 2;
  return cat * 1000000.0 + near;
}

// The font-stretch the run being built asks for; face_for reads it while matching.
static double g_stretch_request = 100;

// The face a family gives a weight and style, as CSS's font matching picks it: a face of the style
// the text asks for comes before any other, then the nearest font-stretch, then CSS's weight order.
static HFontFace *face_for(int family, double w, BOOL italic) {
  HFontFace *best = nil;
  double bestDist = 0;
  for (HFontFace *face in g_faces) {
    if (face.family != family) continue;
    double stretchDist = face.stretch == g_stretch_request ? 0 : 1 + fabs(face.stretch - g_stretch_request) / 1000.0;
    double dist = (face.italic == (italic ? 1 : 0) ? 0 : 1000000000.0) +
      stretchDist * 100000000.0 + weight_distance(w, face.lo, face.hi);
    if (best == nil || dist < bestDist) { best = face; bestDist = dist; }
  }
  return best;
}

// `weight` is the CSS font-weight, plus 1000 for italic, plus 10000 times the font family id
// (0 system, 1 monospace, 2 serif, 3 and up for @font-face fonts in declaration order), plus
// 10000000 times the OpenType feature run (0 for none). Packing them into one argument keeps the
// FFI signatures small, and the features ride along to every measure and draw of the run.
// The font a family value stands for when it has no @font-face face: the system font, the
// generic families, or an installed family already registered by name.
static NSFont *base_font_for(int family, double size, double w, BOOL italic) {
  NSFont *f = nil;
  HFontFace *mf = family >= 7 && g_faces ? face_for(family - 7, w, italic) : nil;
  if (mf) f = [NSFont fontWithDescriptor:mf.desc size:size];
  if (!f && family == 1) {
    f = [NSFont fontWithName:(w >= 600 ? @"Menlo-Bold" : @"Menlo") size:size];
    if (!f) f = [NSFont fontWithName:@"Menlo" size:size];
    if (!f) f = [NSFont monospacedSystemFontOfSize:size weight:weight_for(w)];
  }
  if (!f && family == 2) f = [NSFont fontWithName:@"Times New Roman" size:size];
  // `sans-serif` is Chrome's Helvetica on macOS, not the system UI font: a page that names only
  // the generic sans measures and draws in the face a browser picks for it.
  if (!f && family == 6) f = [NSFont fontWithName:(w >= 600 ? @"Helvetica-Bold" : @"Helvetica") size:size];
  if (!f && family == 3) f = system_design(size, w, NSFontDescriptorSystemDesignSerif);
  if (!f && family == 4) f = system_design(size, w, NSFontDescriptorSystemDesignRounded);
  if (!f && family == 5) f = system_design(size, w, NSFontDescriptorSystemDesignMonospaced);
  if (!f) f = [NSFont systemFontOfSize:size weight:weight_for(w)];
  if (italic && !mf) {
    NSFontDescriptor *d = [f.fontDescriptor fontDescriptorWithSymbolicTraits:NSFontDescriptorTraitItalic];
    NSFont *it = d ? [NSFont fontWithDescriptor:d size:size] : nil;
    if (it) f = it;
  }
  return f;
}

// A face's own feature-settings string as CoreText settings, merged with the run's settings (the
// run wins a tag they share).
static NSArray *merged_feature_list(NSString *faceSpec, NSArray *run) {
  if (faceSpec.length == 0) return run;
  NSMutableArray *out = [NSMutableArray array];
  NSMutableDictionary *byTag = [NSMutableDictionary dictionary];
  for (NSString *pair in [faceSpec componentsSeparatedByString:@";"]) {
    NSRange eq = [pair rangeOfString:@"="];
    if (eq.location == NSNotFound) continue;
    NSString *tag = [pair substringToIndex:eq.location];
    if (tag.length != 4) continue;
    byTag[tag] = @([[pair substringFromIndex:eq.location + 1] intValue]);
  }
  for (NSDictionary *d in run) {
    NSString *tag = d[(__bridge id)kCTFontOpenTypeFeatureTag];
    NSNumber *v = d[(__bridge id)kCTFontOpenTypeFeatureValue];
    if (tag != nil && v != nil) byTag[tag] = v;
  }
  for (NSString *tag in byTag) {
    [out addObject:@{
      (__bridge id)kCTFontOpenTypeFeatureTag: tag,
      (__bridge id)kCTFontOpenTypeFeatureValue: byTag[tag],
    }];
  }
  return out;
}

static NSFont *family_font(HFontFallback *fb, double size, double weight, BOOL italic, NSString *lang);
static NSArray *language_cascade(NSFont *f, NSString *lang);

static NSFont *font_for(double size, double weight) {
  if (!g_fonts) g_fonts = [NSMutableDictionary dictionary];
  NSString *key = [NSString stringWithFormat:@"%g/%g", size, weight];
  NSFont *f = g_fonts[key];
  if (!f) {
    double run = floor(weight / 10000000.0);
    double pack = weight - run * 10000000.0;
    double family = floor(pack / 10000.0);
    double rest = pack - family * 10000.0;
    BOOL italic = rest >= 1000;
    double w = italic ? rest - 1000 : rest;
    HFontRun *info = run >= 1 && g_font_runs && run <= g_font_runs.count
      ? g_font_runs[(NSUInteger)(run - 1)] : nil;
    int synth = info ? info.synth : 7;
    g_stretch_request = info != nil ? info.stretch : 100;
    int face = (int)family - 7;
    BOOL fakeBold = NO;
    HFontFace *matched = face >= 0 && g_faces ? face_for(face, w, italic) : nil;
    // font-size-adjust scales the face so its x-height is that share of the requested size.
    if (info != nil && info.adjust > 0 && matched != nil) {
      NSFont *probe = [NSFont fontWithDescriptor:matched.desc size:size];
      double xh = probe != nil ? CTFontGetXHeight((__bridge CTFontRef)probe) : 0;
      if (xh > 0) size = size * info.adjust * size / xh;
    }
    if (matched) {
      f = [NSFont fontWithDescriptor:matched.desc size:size];
      // A family with no bold face gets one drawn in, as a browser emboldens the text itself.
      if ((synth & 1) && w >= 600 && matched.hi < 600) fakeBold = YES;
    }
    if (!f && family == 1) {
      // Chrome's fixed-width family on macOS is Menlo; the system's monospaced face (SF Mono)
      // stands in when it isn't installed.
      f = [NSFont fontWithName:(w >= 600 ? @"Menlo-Bold" : @"Menlo") size:size];
      if (!f) f = [NSFont fontWithName:@"Menlo" size:size];
      if (!f) f = [NSFont monospacedSystemFontOfSize:size weight:weight_for(w)];
    }
    if (!f && family == 2) f = [NSFont fontWithName:@"Times New Roman" size:size];
    if (!f && family == 6) f = [NSFont fontWithName:(w >= 600 ? @"Helvetica-Bold" : @"Helvetica") size:size];
    // The system's other designs: New York, SF Rounded and SF Mono. A system without them falls
    // back to the system font, as an unknown family does.
    if (!f && family == 3) f = system_design(size, w, NSFontDescriptorSystemDesignSerif);
    if (!f && family == 4) f = system_design(size, w, NSFontDescriptorSystemDesignRounded);
    if (!f && family == 5) f = system_design(size, w, NSFontDescriptorSystemDesignMonospaced);
    if (!f) f = [NSFont systemFontOfSize:size weight:weight_for(w)];
    // A first family the host has no face for leaves the rest of the list as what the text is
    // drawn in, so the run's base font (and so its line metrics) is the first entry that is
    // there. A system or generic family always has a font of its own, so it stays the base
    // whatever the list names after it.
    if (family >= 7 && !matched && info != nil && info.cascade.count > 0) {
      for (HFontFallback *fb0 in info.cascade) {
        NSFont *entry = family_font(fb0, size, w, italic, info.lang);
        if (entry != nil) { f = entry; break; }
      }
    }
    // A family from @font-face has only the faces it declared, so its italic face is the one
    // face_for picked; the generic families ask CoreText for an italic face instead.
    if (italic && !matched) {
      NSFontDescriptor *d = [f.fontDescriptor fontDescriptorWithSymbolicTraits:NSFontDescriptorTraitItalic];
      NSFont *it = d ? [NSFont fontWithDescriptor:d size:size] : nil;
      if (it) f = it;
    }
    // The feature settings, variation axes and colour palette travel on the font itself, so
    // measuring a run and drawing it agree. A run names its palette explicitly, including
    // palette 0 for `normal` on a colour font: NSFont's own default follows the system
    // appearance (a dark appearance picks the font's dark palette), while CSS's `normal` is the
    // font's palette 0. A font with no run keeps its descriptor untouched.
    NSArray *features = merged_feature_list(matched ? matched.features : @"", info ? info.features : @[]);
    BOOL hasLang = info != nil && info.lang.length > 0;
    // A face that covers a weight range is a variable one: font-weight sets its wght axis,
    // font-size its opsz axis and a font-stretch its wdth axis, as a browser does. The run's own
    // font-variation-settings override each of them, and a static face has no axis to set.
    NSMutableDictionary *axes = info != nil && info.variations.count > 0 ? [info.variations mutableCopy] : nil;
    if (matched != nil && matched.hi > matched.lo) {
      if (axes == nil) axes = [NSMutableDictionary dictionary];
      if (axes[@(axis_code(@"wght"))] == nil && w >= matched.lo && w <= matched.hi)
        axes[@(axis_code(@"wght"))] = @(w);
      if (axes[@(axis_code(@"opsz"))] == nil) axes[@(axis_code(@"opsz"))] = @((double)size);
      if (axes[@(axis_code(@"wdth"))] == nil && g_stretch_request != 100)
        axes[@(axis_code(@"wdth"))] = @(g_stretch_request);
    }
    if ((axes != nil && axes.count > 0) || (info && info.palette >= 0) || features.count > 0 || hasLang) {
      NSMutableDictionary *attrs = [f.fontDescriptor.fontAttributes mutableCopy];
      if (features.count > 0) attrs[(__bridge id)kCTFontFeatureSettingsAttribute] = features;
      // The language the run is in, which CoreText's cascade follows when the family list has no
      // character: the system's font for Chinese or Arabic depends on the language, not the script.
      if (hasLang) {
        attrs[(__bridge id)kCTFontLanguagesAttribute] = @[info.lang];
        NSArray *cascadeList = language_cascade(f, info.lang);
        if (cascadeList != nil) attrs[(__bridge id)kCTFontCascadeListAttribute] = cascadeList;
      }
      if (axes != nil && axes.count > 0) attrs[(__bridge id)kCTFontVariationAttribute] = axes;
      if (info.palette >= 0) {
        attrs[(__bridge id)kCTFontPaletteAttribute] = @(info.palette);
        if (info.paletteColors.count > 0) attrs[(__bridge id)kCTFontPaletteColorsAttribute] = info.paletteColors;
      }
      NSFontDescriptor *d = [NSFontDescriptor fontDescriptorWithFontAttributes:attrs];
      NSFont *withAttrs = [NSFont fontWithDescriptor:d size:size];
      if (withAttrs) f = withAttrs;
    }
    // A family with no italic face gets one slanted at drawing time, which leaves the measured
    // advance alone, as a browser's synthetic oblique does.
    BOOL fakeItalic = italic && (synth & 2) && !(matched && matched.italic) &&
      !(CTFontGetSymbolicTraits((__bridge CTFontRef)f) & kCTFontTraitItalic);
    if (!g_fake_bold) g_fake_bold = [NSMutableDictionary dictionary];
    if (!g_fake_italic) g_fake_italic = [NSMutableDictionary dictionary];
    g_fake_bold[key] = @(fakeBold);
    g_fake_italic[key] = @(fakeItalic);
    g_fonts[key] = f;
  }
  return f;
}

// A line of text. `letter` is added after each character and `word` to each space as well, the
// way letter-spacing and word-spacing work; both are zero for ordinary text.
// The run a packed font weight names, or nil for the plain font.
static HFontRun *run_for_weight(double weight) {
  double run = floor(weight / 10000000.0);
  return run >= 1 && g_font_runs && run <= g_font_runs.count ? g_font_runs[(NSUInteger)(run - 1)] : nil;
}

// The face a packed font weight's own family gives its weight and style, as font_for picks it.
static HFontFace *face_for_weight(double weight) {
  double run = floor(weight / 10000000.0);
  double pack = weight - run * 10000000.0;
  double family = floor(pack / 10000.0);
  double rest = pack - family * 10000.0;
  BOOL italic = rest >= 1000;
  double w = italic ? rest - 1000 : rest;
  int face = (int)family - 7;
  return face >= 0 && g_faces ? face_for(face, w, italic) : nil;
}

// Does a face's unicode-range cover a character? An empty range covers everything.
static BOOL ranges_have(NSString *ranges, uint32_t cp) {
  if (ranges.length == 0) return YES;
  for (NSString *part in [ranges componentsSeparatedByString:@","]) {
    NSArray *ends = [part componentsSeparatedByString:@"-"];
    long lo = [ends[0] longLongValue];
    long hi = ends.count > 1 ? [ends[1] longLongValue] : lo;
    if ((long)cp >= lo && (long)cp <= hi) return YES;
  }
  return NO;
}

// A cascade entry's font: its family's face, with the palette its own rule gives it. CoreText
// ignores palette attributes on cascade-list descriptors, so the line is split into ranges with
// one font attribute each instead (see make_line_spaced).
static NSFont *family_font(HFontFallback *fb, double size, double weight, BOOL italic, NSString *lang) {
  if (!g_entry_fonts) g_entry_fonts = [NSMutableDictionary dictionary];
  NSString *ck = [NSString stringWithFormat:@"%g|%d|%d|%d|%@", size, fb.family, fb.palette, italic ? 1 : 0, lang];
  NSFont *hit = g_entry_fonts[ck];
  if (hit != nil) return hit;
  NSFont *base = base_font_for(fb.family, size, weight, italic);
  if (base == nil) return nil;
  NSFont *f = base;
  if (lang.length > 0 || fb.palette >= 0 || fb.paletteColors.count > 0) {
    NSMutableDictionary *attrs = [base.fontDescriptor.fontAttributes mutableCopy];
    if (lang.length > 0) {
      attrs[(__bridge id)kCTFontLanguagesAttribute] = @[lang];
      NSArray *cascadeList = language_cascade(base, lang);
      if (cascadeList != nil) attrs[(__bridge id)kCTFontCascadeListAttribute] = cascadeList;
    }
    if (fb.palette >= 0) attrs[(__bridge id)kCTFontPaletteAttribute] = @(fb.palette);
    if (fb.paletteColors.count > 0) attrs[(__bridge id)kCTFontPaletteColorsAttribute] = fb.paletteColors;
    NSFont *withAttrs = [NSFont fontWithDescriptor:[NSFontDescriptor fontDescriptorWithFontAttributes:attrs] size:size];
    if (withAttrs != nil) f = withAttrs;
  }
  // A font built from explicit colours or a language depends on the run; the rest are shared.
  if (fb.paletteColors.count == 0 && lang.length == 0) g_entry_fonts[ck] = f;
  return f;
}

// The system's fallback fonts for a language, as a cascade list: CoreText's own order for the
// script (Hiragino for Japanese, PingFang for Chinese, Geeza Pro for Arabic, …). The languages
// attribute alone does not change which face a missing glyph gets, so the list is asked for.
static NSArray *language_cascade(NSFont *f, NSString *lang) {
  if (lang.length == 0) return nil;
  CFArrayRef list = CTFontCopyDefaultCascadeListForLanguages((__bridge CTFontRef)f, (__bridge CFArrayRef)@[lang]);
  if (list == NULL) return nil;
  NSArray *out = [NSArray arrayWithArray:(__bridge NSArray *)list];
  CFRelease(list);
  return out;
}

// Whether a font has a glyph for a code point.
static BOOL font_has_char(NSFont *f, uint32_t cp) {
  UniChar units[2];
  CFIndex n = 1;
  if (cp > 0xFFFF) {
    uint32_t v = cp - 0x10000;
    units[0] = (UniChar)(0xD800 + (v >> 10));
    units[1] = (UniChar)(0xDC00 + (v & 0x3FF));
    n = 2;
  } else {
    units[0] = (UniChar)cp;
  }
  CGGlyph glyphs[2] = {0, 0};
  if (!CTFontGetGlyphsForCharacters((__bridge CTFontRef)f, units, glyphs, n)) return NO;
  for (CFIndex i = 0; i < n; i++) if (glyphs[i] == 0) return NO;
  return YES;
}

// The font one character takes: the first family that covers it — the unicode-range of a family
// from @font-face, the character set of a system one — then the rest of the list, then the system
// font.
static NSFont *char_font(uint32_t cp, NSFont *primary, HFontFace *primaryFace, BOOL primaryIsSystem,
                         HFontRun *info, NSArray *fbFonts, NSArray *fbFaces, NSFont *system) {
  // The first family is tried first. A face that names a unicode-range is what decides there,
  // even where the face has no glyph for a character inside it; a face that names none covers
  // the characters its font has and leaves the rest to the next family, as a system family
  // (system-ui, sans-serif, ui-serif…) does. A name the host has no face for keeps nothing back:
  // the rest of the list is the text's font.
  // A system or generic family has the system's own fallback behind it, which follows the run's
  // language — Hiragino for Japanese, PingFang for Chinese, Geeza Pro for Arabic — so it answers
  // for every character and the families after it are for a family with no font at all.
  if (primaryFace == nil && primaryIsSystem) return primary;
  // A face that names a unicode-range decides by it, even where it has no glyph for a character
  // inside the range; a face that names none covers the characters its font has.
  if (primaryFace != nil) {
    BOOL covers = primaryFace.ranges.length > 0 ? ranges_have(primaryFace.ranges, cp)
      : font_has_char(primary, cp);
    if (covers) return primary;
  }
  for (NSUInteger i = 0; i < info.cascade.count; i++) {
    HFontFace *entryFace = fbFaces[i];
    NSFont *f = fbFonts[i];
    if ((id)f == [NSNull null]) continue;
    if ((id)entryFace == [NSNull null]) return f;  // a system family: it carries the cascade
    if (entryFace.ranges.length > 0) {
      if (ranges_have(entryFace.ranges, cp)) return f;
      continue;
    }
    // A face with no range covers only the characters its font has: a webfont that lacks the
    // script falls through to the next entry instead of drawing tofu over it.
    if (font_has_char(f, cp)) return f;
  }
  return primaryFace == nil ? primary : system;
}

// The word separators inter-word justification stretches: the space, the no-break space, the
// Ethiopic, Aegean, Ugaritic and Phoenician word separators (CSS Text's set).
static BOOL word_separator(uint32_t cp) {
  return cp == 0x20 || cp == 0xA0 || cp == 0x1361 || cp == 0x10100 || cp == 0x10101 ||
    cp == 0x1039F || cp == 0x1091F;
}

static CTLineRef make_line_with_fonts(const char *s, size_t n, double size, double weight,
                                     double letter, double word, BOOL resolved) {
  NSString *str = [[NSString alloc] initWithBytes:s length:n encoding:NSUTF8StringEncoding];
  if (!str) str = @"";
  NSFont *primary = font_for(size, weight);
  CTFontRef primaryRef = resolved ? font_ref(primary) : NULL;
  NSDictionary *attrs = @{
    (__bridge id)kCTFontAttributeName : primaryRef ? (__bridge id)primaryRef : (id)primary,
    (__bridge id)kCTForegroundColorFromContextAttributeName : @YES,
  };
  HFontRun *info = run_for_weight(weight);
  g_stretch_request = info != nil ? info.stretch : 100;
  HFontFace *primaryFace = face_for_weight(weight);
  // The line walks the list whenever there is one: a family covers some of the characters and
  // leaves the rest to the families after it, whether that coverage is a face's unicode-range or
  // the characters its font has.
  BOOL ranged = info != nil && info.cascade.count > 0;
  if (!ranged && letter == 0 && word == 0) {
    NSAttributedString *as = [[NSAttributedString alloc] initWithString:str attributes:attrs];
    return CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);
  }
  NSMutableAttributedString *as = [[NSMutableAttributedString alloc] initWithString:str attributes:attrs];
  if (ranged) {
    // Give each stretch of characters the font its unicode-range falls in, so both the
    // measurement and the drawing of the line follow the font-family list and each family's
    // palette. Surrogate pairs count as one character.
    double runPacked = floor(weight / 10000000.0);
    double pack = weight - runPacked * 10000000.0;
    double familyPart = floor(pack / 10000.0);
    double wAndItalic = pack - familyPart * 10000.0;
    BOOL italic = wAndItalic >= 1000;
    double w = italic ? wAndItalic - 1000 : wAndItalic;
    NSMutableArray *fbFonts = [NSMutableArray array];
    NSMutableArray *fbFaces = [NSMutableArray array];
    for (HFontFallback *fb in info.cascade) {
      HFontFace *mf = fb.family >= 7 && g_faces ? face_for(fb.family - 7, w, italic) : nil;
      NSFont *f = family_font(fb, size, w, italic, info.lang);
      [fbFaces addObject:(id)mf ?: (id)[NSNull null]];
      [fbFonts addObject:(id)f ?: (id)[NSNull null]];
    }
    NSFont *systemFont = base_font_for(0, size, w, italic);
    NSUInteger len = as.length;
    NSUInteger i = 0;
    while (i < len) {
      uint32_t cp = [str characterAtIndex:i];
      NSUInteger units = 1;
      if (cp >= 0xD800 && cp <= 0xDBFF && i + 1 < len) {
        cp = 0x10000 + ((cp - 0xD800) << 10) + ([str characterAtIndex:i + 1] - 0xDC00);
        units = 2;
      }
      NSFont *chosen = char_font(cp, primary, primaryFace, familyPart < 6, info, fbFonts, fbFaces, systemFont);
      NSUInteger j = i + units;
      while (j < len) {
        uint32_t cp2 = [str characterAtIndex:j];
        NSUInteger u2 = 1;
        if (cp2 >= 0xD800 && cp2 <= 0xDBFF && j + 1 < len) {
          cp2 = 0x10000 + ((cp2 - 0xD800) << 10) + ([str characterAtIndex:j + 1] - 0xDC00);
          u2 = 2;
        }
        if (char_font(cp2, primary, primaryFace, familyPart < 6, info, fbFonts, fbFaces, systemFont) != chosen) break;
        j += u2;
      }
      // A stretch that keeps the primary font already carries it: re-tagging it with a second
      // instance of the same face can shift its advances a hair.
      if (chosen != primary) {
        CTFontRef chosenRef = resolved ? font_ref(chosen) : NULL;
        [as addAttribute:(__bridge id)kCTFontAttributeName
                   value:chosenRef ? (__bridge id)chosenRef : (id)chosen
                   range:NSMakeRange(i, j - i)];
      }
      i = j;
    }
  }
  NSUInteger len = as.length;
  // Kerning is the gap a glyph advance gets; the last character gets one too, as browsers add
  // the trailing letter spacing to the run's width. A zero kern attribute would also turn the
  // font's own kerning off, so it is only added when there is spacing to add — except for a run
  // whose font-kerning is none, which asks for exactly that.
  HFontRun *kerningInfo = run_for_weight(weight);
  if (letter != 0 || word != 0) [as addAttribute:NSKernAttributeName value:@(letter) range:NSMakeRange(0, len)];
  else if (kerningInfo != nil && kerningInfo.kerning == 0) [as addAttribute:NSKernAttributeName value:@(0) range:NSMakeRange(0, len)];
  if (word != 0) {
    // Each word separator takes the word spacing as well as the letter spacing; the astral
    // separators are a surrogate pair, so the loop walks code points.
    NSUInteger i = 0;
    while (i < len) {
      unichar c = [str characterAtIndex:i];
      uint32_t cp = c;
      NSUInteger units = 1;
      if (c >= 0xD800 && c <= 0xDBFF && i + 1 < len) {
        cp = 0x10000 + (((uint32_t)c - 0xD800) << 10) + ([str characterAtIndex:i + 1] - 0xDC00);
        units = 2;
      }
      if (word_separator(cp)) {
        [as addAttribute:NSKernAttributeName value:@(letter + word) range:NSMakeRange(i, units)];
      }
      i += units;
    }
  }
  return CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);
}

/** The CTFont for an NSFont, resolved once per thread. Only measurement asks for it: a painted
 *  line draws through the NSFont path the host has always used. */
static CTFontRef font_ref(NSFont *f) {
  HTextCache *cache = thread_text_cache();
  id hit = [cache.fonts objectForKey:f];
  if (hit != nil) return (__bridge CTFontRef)hit;
  CTFontRef ct = CTFontCreateWithFontDescriptor((__bridge CTFontDescriptorRef)f.fontDescriptor,
                                                f.pointSize, NULL);
  if (ct != NULL) [cache.fonts setObject:(__bridge id)ct forKey:f];
  return ct;
}

static void clear_text_caches(void) { atomic_fetch_add(&g_text_generation, 1); }

static unsigned line_hash(const char *s, uint32_t len, int resolved, double size, double weight,
                           double letter, double word) {
  uint64_t h = 1469598103934665603ull ^ len ^ (uint64_t)(resolved ? 1 : 0);
  for (uint32_t i = 0; i < len; i++) { h ^= (unsigned char)s[i]; h *= 1099511628211ull; }
  uint64_t bits = 0;
  memcpy(&bits, &size, sizeof(bits)); h = h * 1099511628211ull ^ bits;
  memcpy(&bits, &weight, sizeof(bits)); h = h * 1099511628211ull ^ bits;
  memcpy(&bits, &letter, sizeof(bits)); h = h * 1099511628211ull ^ bits;
  memcpy(&bits, &word, sizeof(bits)); h = h * 1099511628211ull ^ bits;
  return (unsigned)(h & (LINE_SLOTS - 1));
}

static int line_matches(const LineEntry *entry, const char *s, uint32_t len, int resolved,
                        double size, double weight, double letter, double word) {
  return entry->line != NULL && entry->len == len && entry->resolved == resolved &&
    entry->size == size && entry->weight == weight && entry->letter == letter &&
    entry->word == word && memcmp(entry->text, s, len) == 0;
}

static int ptr_matches(const PtrEntry *entry, const char *s, uint32_t len, int resolved,
                       double size, double weight, double letter, double word) {
  return entry->entry != NULL && entry->ptr == (const void *)s && entry->len == len &&
    entry->resolved == resolved && entry->size == size && entry->weight == weight &&
    entry->letter == letter && entry->word == word && memcmp(entry->entry->text, s, len) == 0;
}

static void ptr_remember(HTextCache *cache, const char *s, uint32_t len, int resolved, double size,
                         double weight, double letter, double word, LineEntry *entry) {
  PtrEntry *slot = &cache->ptrs[(((uintptr_t)s >> 4) ^ len) & (PTR_SLOTS - 1)];
  slot->ptr = s;
  slot->len = len;
  slot->resolved = resolved;
  slot->size = size;
  slot->weight = weight;
  slot->letter = letter;
  slot->word = word;
  slot->entry = entry;
}

/** A line for this text, font and spacing, shaped once per thread and kept. The caller owns a
 *  reference. A run the runtime hands back at the same address hits the pointer cache; text in a
 *  new buffer hits the content table. */
static CTLineRef line_for_text(const char *s, size_t n, double size, double weight,
                               double letter, double word, BOOL resolved) {
  HTextCache *cache = thread_text_cache();
  uint32_t len = (uint32_t)n;
  int use_ct = resolved ? 1 : 0;
  PtrEntry *fast = &cache->ptrs[(((uintptr_t)s >> 4) ^ len) & (PTR_SLOTS - 1)];
  if (ptr_matches(fast, s, len, use_ct, size, weight, letter, word)) {
    return (CTLineRef)CFRetain(fast->entry->line);
  }
  unsigned at = line_hash(s, len, use_ct, size, weight, letter, word);
  for (int probe = 0; probe < 32; probe++, at = (at + 1) & (LINE_SLOTS - 1)) {
    LineEntry *entry = &cache->lines[at];
    if (entry->line == NULL) break;
    if (line_matches(entry, s, len, use_ct, size, weight, letter, word)) {
      ptr_remember(cache, s, len, use_ct, size, weight, letter, word, entry);
      return (CTLineRef)CFRetain(entry->line);
    }
  }
  CTLineRef line = make_line_with_fonts(s, n, size, weight, letter, word, resolved);
  if (line == NULL) return NULL;
  char *text = (char *)malloc(len ? len : 1);
  if (text == NULL) return line;
  memcpy(text, s, len);
  at = line_hash(s, len, use_ct, size, weight, letter, word);
  int slot = -1;
  for (int probe = 0; probe < 32; probe++, at = (at + 1) & (LINE_SLOTS - 1)) {
    if (cache->lines[at].line == NULL) { slot = (int)at; break; }
  }
  if (slot < 0) {
    // The table filled: drop it and take the entry's own slot.
    clear_thread_lines(cache);
    free(text);
    text = (char *)malloc(len ? len : 1);
    if (text == NULL) return line;
    memcpy(text, s, len);
    slot = (int)line_hash(s, len, use_ct, size, weight, letter, word);
    fast = &cache->ptrs[(((uintptr_t)s >> 4) ^ len) & (PTR_SLOTS - 1)];
  }
  LineEntry *entry = &cache->lines[slot];
  entry->len = len;
  entry->resolved = use_ct;
  entry->size = size;
  entry->weight = weight;
  entry->letter = letter;
  entry->word = word;
  entry->text = text;
  entry->line = line;
  // The table keeps a reference of its own: the caller owns the one the line was created with.
  CFRetain(line);
  ptr_remember(cache, s, len, use_ct, size, weight, letter, word, entry);
  return line;
}

static double window_scale(void) {
  return g_window ? g_window.backingScaleFactor : 1.0;
}

/** The font's metrics at this size and weight, read once per size, packed weight and scale. */
static TextMetric text_metric(double size, double weight) {
  double scale = window_scale();
  HTextCache *cache = thread_text_cache();
  for (int i = 0; i < cache->metric_count; i++) {
    TextMetric *m = &cache->metrics[i];
    if (m->size == size && m->weight == weight && m->scale == scale) return *m;
  }
  if (cache->metric_count >= TEXT_METRIC_SLOTS) cache->metric_count = 0;
  TextMetric m;
  NSFont *f = font_for(size, weight);
  m.size = size;
  m.weight = weight;
  m.scale = scale;
  m.ascent = f.ascender;
  m.descent = -f.descender;
  m.gap = f.leading;
  m.x_height = f.xHeight;
  m.ascent_dev = round(m.ascent * scale);
  m.descent_dev = round(m.descent * scale);
  m.gap_dev = round(m.gap * scale);
  cache->metrics[cache->metric_count++] = m;
  return m;
}

double host_font_ascent(double size, double weight) { return text_metric(size, weight).ascent; }
double host_font_descent(double size, double weight) { return text_metric(size, weight).descent; }
double host_font_line_gap(double size, double weight) { return text_metric(size, weight).gap; }
double host_font_x_height(double size, double weight) { return text_metric(size, weight).x_height; }

// Line boxes are laid out in whole device pixels: Chrome rounds each of the font's ascent,
// descent and line gap to a whole device pixel, which makes a normal line box and a baseline whole
// device pixels too. These report those numbers, still counted in device pixels; the runtime
// divides by the backing scale to get CSS px. Canvas text keeps the CSS-px metrics above, since a
// canvas font bounding box is in CSS pixels on every display.
double host_font_ascent_device(double size, double weight) { return text_metric(size, weight).ascent_dev; }
double host_font_descent_device(double size, double weight) { return text_metric(size, weight).descent_dev; }
double host_font_line_gap_device(double size, double weight) { return text_metric(size, weight).gap_dev; }

// A CSS-px position moved to the nearest whole device pixel, so a run drawn at a fractional
// position still lands on the pixel grid (back in CSS px, since the display list is user space).
static double device_round(double v) {
  double scale = g_window ? g_window.backingScaleFactor : 1.0;
  return round(v * scale) / scale;
}

// Where a line box's baseline sits: the font's ascent, a whole device pixel, plus half the
// leading, floored when it isn't a whole device pixel. The same numbers the runtime's layout uses
// (see fontDeviceMetrics in runtime/style.ts), so painting and layout agree on every line.
static double text_baseline(NSFont *f, double y, double line_height) {
  double scale = g_window ? g_window.backingScaleFactor : 1.0;
  double ascent = round(f.ascender * scale), descent = round(-f.descender * scale);
  return y + (ascent + floor((line_height * scale - ascent - descent) / 2)) / scale;
}

/** Defined with the frame timings below. */
static int frame_times(void);
static double now_ms(void);

// How long shaping text has taken since the frame line last asked: the share of a layout that is
// measuring text. Only a run that asks for frame timings pays to read the clock.
static double g_text_shape_ms = 0;

/** Milliseconds spent shaping text since the last call, for the frame line. */
double host_text_shape_time(void) {
  double ms = g_text_shape_ms;
  g_text_shape_ms = 0;
  return ms;
}

double host_measure_text(const uint8_t *s, size_t n, double size, double weight, double letter, double word) {
  double started = frame_times() ? now_ms() : 0;
  double w;
  @autoreleasepool {
    CTLineRef line = line_for_text((const char *)s, n, size, weight, letter, word, YES);
    w = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    CFRelease(line);
  }
  if (started != 0) g_text_shape_ms += now_ms() - started;
  return w;
}

// What measureText reports about a run: its advance and the ink it covers, then the font's own
// ascent and descent. Packed as seven little-endian doubles (width, ink left, ink right, ink
// ascent, ink descent, font ascent, font descent) for the runtime to unpack. The ink is measured
// with the glyph paths, so a run of spaces — which covers no pixels — reports zeros, as a
// browser's metrics do.
typedef void (*metrics_cb)(const uint8_t *, size_t);

void host_text_metrics(const uint8_t *s, size_t n, double size, double weight, double letter, double word, metrics_cb cb) {
  @autoreleasepool {
    CTLineRef line = line_for_text((const char *)s, n, size, weight, letter, word, YES);
    // The font's box is the font's, whatever the run holds: an empty run still sits in it.
    NSFont *f = font_for(size, weight);
    double m[7] = { CTLineGetTypographicBounds(line, NULL, NULL, NULL), 0, 0, 0, 0, f.ascender, -f.descender };
    CGRect ink = CTLineGetBoundsWithOptions(line, kCTLineBoundsUseGlyphPathBounds);
    if (!CGRectIsNull(ink) && !CGRectIsEmpty(ink)) {
      m[1] = -ink.origin.x;
      m[2] = ink.origin.x + ink.size.width;
      m[3] = ink.origin.y + ink.size.height;
      m[4] = -ink.origin.y;
    }
    CFRelease(line);
    cb((const uint8_t *)m, sizeof(m));
  }
}

// ---------------------------------------------------------------------------
// Frame timings

/** Whether NATIVE_FRAME_TIMES asks for per-frame stage times, read once. */
static int frame_times(void) {
  static int on = -1;
  if (on < 0) {
    const char *env = getenv("NATIVE_FRAME_TIMES");
    on = env != NULL && env[0] != 0 && strcmp(env, "0") != 0;
  }
  return on;
}

/** The monotonic clock in milliseconds, for the stage timings. */
static double now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}

// The replay's own time in the last drawRect, which host_present reports as its own stage.
static double g_last_replay_ms = 0;
/** The index a replay stops at, for replaying a span of a list; SIZE_MAX replays to its end. */
static _Thread_local size_t g_replay_limit = (size_t)-1;
static int g_font_info_logged = 0;

// The macOS 26.7 SDK no longer declares these CoreGraphics getters, though the framework still
// exports them; the frame-time log below is their only reader.
extern CGColorSpaceRef CGContextGetColorSpace(CGContextRef ctx);
extern bool CGContextGetAllowsFontSmoothing(CGContextRef ctx);
extern bool CGContextGetShouldSmoothFonts(CGContextRef ctx);
extern bool CGContextGetAllowsFontSubpixelPositioning(CGContextRef ctx);
extern bool CGContextGetAllowsFontSubpixelQuantization(CGContextRef ctx);

// What the window's context uses to draw text, reported once: tile rasterization has to copy it
// or text comes out lighter in a transparent layer.
static void log_window_font_info(CGContextRef ctx) {
  if (g_font_info_logged) return;
  g_font_info_logged = 1;
  char space[128] = "";
  CGColorSpaceRef cs = CGContextGetColorSpace(ctx);
  CFStringRef name = cs ? CGColorSpaceCopyName(cs) : NULL;
  if (name != NULL) {
    if (!CFStringGetCString(name, space, sizeof(space), kCFStringEncodingUTF8)) space[0] = 0;
    CFRelease(name);
  }
  fprintf(stderr, "native: window font smoothing allows=%d should=%d subpixel-positioning=%d subpixel-quantization=%d colorspace=%s\n",
          CGContextGetAllowsFontSmoothing(ctx) ? 1 : 0,
          CGContextGetShouldSmoothFonts(ctx) ? 1 : 0,
          CGContextGetAllowsFontSubpixelPositioning(ctx) ? 1 : 0,
          CGContextGetAllowsFontSubpixelQuantization(ctx) ? 1 : 0,
          space);
}

// ---------------------------------------------------------------------------
// Display list

static Cmd *push_cmd(void) {
  CmdList *l = g_list;
  if (l->count == l->cap) {
    l->cap = l->cap ? l->cap * 2 : 256;
    l->cmds = realloc(l->cmds, l->cap * sizeof(Cmd));
  }
  size_t at = l->count++;
  Cmd *c = &l->cmds[at];
  memset(c, 0, sizeof(Cmd));
  c->handle = (g_cur_list_id + 1) * CMD_HANDLE_STRIDE + (int32_t)at;
  return c;
}

/** Drops every cached layer raster: the frame about to be recorded replaces their commands. */
static void free_layer_images(void) {
  for (int i = 0; i < MAX_LAYERS; i++) {
    if (g_layer_image[i].image != NULL) CGImageRelease(g_layer_image[i].image);
    g_layer_image[i].image = NULL;
    g_layer_image[i].scale = 0;
  }
}

/** Frees the text a list's commands hold and empties the list. */
static void clear_list(CmdList *l) {
  for (size_t i = 0; i < l->count; i++) free(l->cmds[i].text);
  l->count = 0;
}

void host_begin(uint32_t background) {
  // A new paint: the window's compositor drops the tiles it rastered for the old one.
  g_paint_serial++;
  g_damage_frame = 0;
  free_layer_images();
  clear_list(&g_root);
  for (int i = 0; i < g_layer_count; i++) clear_list(&g_layers[i].list);
  g_layer_count = 0;
  g_open_depth = 0;
  g_skip_depth = 0;
  g_cur_list_id = -1;
  g_list = &g_root;
  g_background = background;
  g_needs_backdrop = 0;
  g_skip_background = 0;
  g_damage_count = 0;
}

/** Reads "x,y,w,h;x,y,w,h" into the frame's damage rectangles. */
static void parse_damage_rects(const uint8_t *s, size_t n) {
  g_damage_count = 0;
  char *buf = (char *)malloc(n + 1);
  if (buf == NULL) return;
  memcpy(buf, s, n);
  buf[n] = 0;
  const char *p = buf;
  while (*p != 0 && g_damage_count < 16) {
    char *end = NULL;
    double v[4];
    int i = 0;
    for (; i < 4; i++) {
      v[i] = strtod(p, &end);
      if (end == p) break;
      p = end;
      while (*p == ',' || *p == ' ') p++;
    }
    if (i < 4) break;
    for (int k = 0; k < 4; k++) g_damage_rects[g_damage_count][k] = v[k];
    g_damage_count++;
    while (*p == ';' || *p == ' ') p++;
  }
  free(buf);
}

void host_damage_begin(uint32_t background, const uint8_t *rects, size_t n) {
  host_begin(background);
  g_damage_frame = 1;
  parse_damage_rects(rects, n);
  g_skip_background = 1;
}

/**
 * Opens a layer: from here to the matching host_layer_pop the commands are the element's own
 * content, a sublist of its own so the compositor can raster it once. The parent list keeps a
 * CMD_LAYER_REF where the box painted, and replaying the ref draws the sublist where it stands,
 * so the flat output is unchanged.
 */
void host_layer_push(int32_t serial, int32_t kind) {
  // Past the depth or layer budget a box paints flat: the pushes inside it skip too, so the
  // nesting stays balanced and the frame is exactly the flat list.
  if (g_skip_depth > 0) {
    g_skip_depth++;
    return;
  }
  if (g_open_depth >= MAX_LAYER_DEPTH || g_layer_count >= MAX_LAYERS) {
    g_skip_depth = 1;
    return;
  }
  int id = g_layer_count++;
  g_layers[id].serial = serial;
  g_layers[id].kind = kind;
  g_layers[id].list.count = 0;
  g_parents[g_open_depth] = g_list;
  g_open_serial[g_open_depth] = serial;
  g_open_kind[g_open_depth] = kind;
  g_open_layer[g_open_depth] = id;
  g_open_depth++;
  g_cur_list_id = id;
  g_list = &g_layers[id].list;
}

void host_layer_pop(void) {
  if (g_skip_depth > 0) {
    g_skip_depth--;
    return;
  }
  if (g_open_depth == 0) return;
  g_open_depth--;
  g_list = g_parents[g_open_depth];
  g_cur_list_id = g_open_depth == 0 ? -1 : g_open_layer[g_open_depth - 1];
  Cmd *c = push_cmd();
  c->kind = CMD_LAYER_REF;
  c->layer = g_open_layer[g_open_depth];
  c->serial = g_open_serial[g_open_depth];
  c->pkind = g_open_kind[g_open_depth];
}

/** The number of layers the last frame recorded. */
int32_t host_layer_count(void) { return g_layer_count; }

void host_clip_push(int32_t serial, int32_t pkind, double x, double y, double w, double h, double radius) {
  Cmd *c = push_cmd();
  c->kind = CMD_CLIP;
  c->serial = serial; c->pkind = pkind;
  c->x = x; c->y = y; c->w = w; c->h = h; c->radius = radius;
}

void host_clip_pop(void) {
  push_cmd()->kind = CMD_UNCLIP;
}

// Restores the state a transform pushed, the same way a clip's pop does.
void host_state_pop(void) {
  push_cmd()->kind = CMD_UNCLIP;
}

// Multiplies the user space of everything drawn until the matching pop by a matrix, for a CSS
// transform: the command saves the state the way a clip does, and its pop restores it.
static Cmd *push_transform(int32_t serial, int32_t pkind, double a, double b, double c, double d, double e, double f) {
  Cmd *cmd = push_cmd();
  cmd->kind = CMD_TRANSFORM;
  cmd->serial = serial; cmd->pkind = pkind;
  cmd->p0 = a; cmd->p1 = b; cmd->p2 = c; cmd->p3 = d;
  cmd->r[0] = e;
  cmd->r[1] = f;
  return cmd;
}

void host_transform_push(int32_t serial, int32_t pkind, double a, double b, double c, double d, double e, double f) {
  push_transform(serial, pkind, a, b, c, d, e, f);
}

/** The same, reporting the command's handle so a later frame can move its matrix in place. */
int32_t host_transform_push_indexed(int32_t serial, int32_t pkind,
                                    double a, double b, double c, double d, double e, double f) {
  return push_transform(serial, pkind, a, b, c, d, e, f)->handle;
}

void host_fill_rect(double x, double y, double w, double h, double radius, uint32_t color) {
  Cmd *c = push_cmd();
  c->kind = CMD_FILL;
  c->x = x; c->y = y; c->w = w; c->h = h; c->radius = radius; c->color = color;
}

// A text-decoration line from x0 to x1, `thickness` tall, whose top edge is `y`. `style` is a
// TDS_* value: solid, double, dotted, dashed or wavy.
void host_fill_line(double x0, double x1, double y, double thickness, uint32_t color, double style) {
  Cmd *c = push_cmd();
  c->kind = CMD_LINE;
  c->x = x0; c->w = x1 - x0; c->y = y;
  c->line_width = thickness; c->color = color; c->radius = style;
}

void host_fill_ring(double x, double y, double w, double h, double radius, double line_width, uint32_t color) {
  Cmd *c = push_cmd();
  c->kind = CMD_RING;
  c->x = x; c->y = y; c->w = w; c->h = h; c->radius = radius; c->line_width = line_width; c->color = color;
}

// A filled polygon (or several, as one path): "x,y x,y x,y" points, subpaths separated by ';'.
// A border side is a quadrilateral; sides that share a colour go in one path so their corners
// meet without an antialiased seam.
void host_fill_poly(const uint8_t *s, size_t n, uint32_t color) {
  Cmd *c = push_cmd();
  c->kind = CMD_POLY;
  c->color = color;
  c->text = malloc(n + 1);
  memcpy(c->text, s, n);
  c->text[n] = 0;
  c->len = n;
}

// Clips everything until the matching host_clip_pop to a polygon, as a clip rect does.
void host_clip_push_poly(int32_t serial, int32_t pkind, const uint8_t *s, size_t n) {
  Cmd *c = push_cmd();
  c->kind = CMD_CLIP_POLY;
  c->serial = serial; c->pkind = pkind;
  c->text = malloc(n + 1);
  memcpy(c->text, s, n);
  c->text[n] = 0;
  c->len = n;
}

// Clips everything until the matching pop to a clip-path ellipse centred on (cx, cy).
void host_clip_push_ellipse(int32_t serial, int32_t pkind, double cx, double cy, double rx, double ry) {
  Cmd *c = push_cmd();
  c->kind = CMD_CLIP_ELLIPSE;
  c->serial = serial; c->pkind = pkind;
  c->p0 = cx; c->p1 = cy; c->p2 = rx; c->p3 = ry;
}

// Clips to one or more closed subpaths — "x,y x,y; x,y …" points, one subpath per ';' — filled
// with `evenodd` choosing the even-odd rule over the non-zero one. Unlike a border's polygon the
// vertices aren't snapped: the shape is the author's, not a pixel grid.
void host_clip_push_shape(int32_t serial, int32_t pkind, const uint8_t *s, size_t n, double evenodd) {
  Cmd *c = push_cmd();
  c->kind = CMD_CLIP_SHAPE;
  c->serial = serial; c->pkind = pkind;
  c->p0 = evenodd;
  c->text = malloc(n + 1);
  memcpy(c->text, s, n);
  c->text[n] = 0;
  c->len = n;
}

// The per-corner-radius versions: eight radii, top-left to bottom-left, horizontal then vertical.
static void set_radii(Cmd *c, double tlx, double tly, double trx, double try_, double brx, double bry, double blx, double bly) {
  c->r[0] = tlx; c->r[1] = tly; c->r[2] = trx; c->r[3] = try_;
  c->r[4] = brx; c->r[5] = bry; c->r[6] = blx; c->r[7] = bly;
}

void host_fill_round_rect(double x, double y, double w, double h,
                          double tlx, double tly, double trx, double try_, double brx, double bry, double blx, double bly,
                          uint32_t color) {
  Cmd *c = push_cmd();
  c->kind = CMD_FILL_ROUND;
  c->x = x; c->y = y; c->w = w; c->h = h; c->color = color;
  set_radii(c, tlx, tly, trx, try_, brx, bry, blx, bly);
}

void host_fill_round_ring(double x, double y, double w, double h,
                          double tlx, double tly, double trx, double try_, double brx, double bry, double blx, double bly,
                          double line_width, uint32_t color) {
  Cmd *c = push_cmd();
  c->kind = CMD_RING_ROUND;
  c->x = x; c->y = y; c->w = w; c->h = h; c->line_width = line_width; c->color = color;
  set_radii(c, tlx, tly, trx, try_, brx, bry, blx, bly);
}

void host_clip_push_round(int32_t serial, int32_t pkind, double x, double y, double w, double h,
                          double tlx, double tly, double trx, double try_, double brx, double bry, double blx, double bly) {
  Cmd *c = push_cmd();
  c->kind = CMD_CLIP_ROUND;
  c->serial = serial; c->pkind = pkind;
  c->x = x; c->y = y; c->w = w; c->h = h;
  set_radii(c, tlx, tly, trx, try_, brx, bry, blx, bly);
}

// An outer box-shadow behind the box: the border box grown by `spread`, cast with `blur`, and
// clipped away inside the border box as CSS says.
void host_shadow_outer(double x, double y, double w, double h,
                       double tlx, double tly, double trx, double try_, double brx, double bry, double blx, double bly,
                       double dx, double dy, double blur, double spread, uint32_t color) {
  Cmd *c = push_cmd();
  c->kind = CMD_SHADOW;
  c->x = x; c->y = y; c->w = w; c->h = h;
  c->dx = dx; c->dy = dy; c->blur = blur; c->line_width = spread; c->color = color;
  set_radii(c, tlx, tly, trx, try_, brx, bry, blx, bly);
}

// An inset box-shadow inside the border box (`x, y, w, h, r` is the padding box): the shadow of
// everything outside the box shrunk by `spread` and moved by the offset, clipped to the box.
void host_shadow_inset(double x, double y, double w, double h,
                       double tlx, double tly, double trx, double try_, double brx, double bry, double blx, double bly,
                       double dx, double dy, double blur, double spread, uint32_t color) {
  Cmd *c = push_cmd();
  c->kind = CMD_SHADOW_INSET;
  c->x = x; c->y = y; c->w = w; c->h = h;
  c->dx = dx; c->dy = dy; c->blur = blur; c->line_width = spread; c->color = color;
  set_radii(c, tlx, tly, trx, try_, brx, bry, blx, bly);
}

// ---------------------------------------------------------------------------
// Images
//
// Decoded images are cached by path for the life of the process; the id is an index into that
// cache, and a path that failed to decode keeps its slot, so it is only tried once.
//
// The pixels are made on the decode pool below, off the thread that paints. host_image_load reads
// the header, which holds the size and the EXIF orientation, and answers with an id before the
// pixels exist; the draw of a pending image paints nothing, as a browser paints nothing for an
// image it hasn't decoded yet, and host_poll reports EV_IMAGE when a decode lands so the page can
// repaint with it. `NATIVE_IMAGE_WORKERS=0` decodes at load on the calling thread instead.

typedef struct {
  int state;       // 0 pending, 1 decoded, -1 failed
  CGImageRef img;  // the pixels once state is 1; kept for the life of the process
  int w, h;        // the size it paints at, with its EXIF orientation applied
} ImageSlot;

static ImageSlot *g_image_slots = NULL;
static int g_image_count = 0, g_image_cap = 0;
static NSMutableDictionary<NSString *, NSNumber *> *g_image_ids = nil;

/** Guards the slot table and the decode queue; a worker publishes a slot's pixels under it. */
static pthread_mutex_t g_image_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_image_idle = PTHREAD_COND_INITIALIZER;
static int g_image_pending = 0;   // decodes queued or running
static int g_image_events = 0;    // decoded since the poll last said so

/**
 * The image with its EXIF orientation applied, so the pixels below are the ones a browser paints
 * by default (image-orientation: from-image). Orientations 5-8 swap the image's dimensions.
 */
static CGImageRef image_oriented(CGImageRef img, int o) {
  if (o < 2 || o > 8) return NULL;
  size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
  int swap = o >= 5;
  size_t nw = swap ? h : w, nh = swap ? w : h;
  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx = CGBitmapContextCreate(NULL, nw, nh, 8, 0, space,
                                           kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(space);
  if (!ctx) return NULL;
  CGAffineTransform t;
  switch (o) {
    case 2: t = CGAffineTransformMake(-1, 0, 0, 1, (CGFloat)w, 0); break;
    case 3: t = CGAffineTransformMake(-1, 0, 0, -1, (CGFloat)w, (CGFloat)h); break;
    case 4: t = CGAffineTransformMake(1, 0, 0, -1, 0, (CGFloat)h); break;
    case 5: t = CGAffineTransformMake(0, -1, -1, 0, (CGFloat)h, (CGFloat)w); break;
    case 6: t = CGAffineTransformMake(0, -1, 1, 0, 0, (CGFloat)w); break;
    case 7: t = CGAffineTransformMake(0, 1, 1, 0, 0, 0); break;
    default: t = CGAffineTransformMake(0, 1, -1, 0, (CGFloat)h, 0); break;
  }
  CGContextConcatCTM(ctx, t);
  CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h), img);
  CGImageRef out = CGBitmapContextCreateImage(ctx);
  CGContextRelease(ctx);
  return out;
}

// The decode pool: a few threads that turn one file's pixels into an ImageSlot. The queue holds
// the CGImageSource made at load, so the header read on the calling thread isn't repeated.

typedef struct {
  int32_t id;
  CGImageSourceRef src;
  int orientation; // 0 when the file's EXIF orientation is not applied
} ImageJob;

#define IMAGE_MAX_WORKERS 4
static ImageJob *g_image_queue = NULL;
static int g_image_queue_count = 0, g_image_queue_cap = 0, g_image_queue_next = 0;
static int g_image_pool_started = 0, g_image_pool_threads = 0;
static pthread_t g_image_pool_thread[IMAGE_MAX_WORKERS];
static pthread_cond_t g_image_wake = PTHREAD_COND_INITIALIZER;

/** The pixels of a file: decoded now, so a later draw only paints them. */
static CGImageRef decode_image(CGImageSourceRef src, int orientation) {
  CFStringRef keys[1] = { kCGImageSourceShouldCacheImmediately };
  CFBooleanRef values[1] = { kCFBooleanTrue };
  CFDictionaryRef opts = CFDictionaryCreate(NULL, (const void **)keys, (const void **)values, 1,
                                            &kCFTypeDictionaryKeyCallBacks,
                                            &kCFTypeDictionaryValueCallBacks);
  CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, opts);
  if (opts) CFRelease(opts);
  if (img && orientation >= 2 && orientation <= 8) {
    CGImageRef fixed = image_oriented(img, orientation);
    if (fixed) {
      CGImageRelease(img);
      img = fixed;
    }
  }
  return img;
}

/** Keeps a decode's pixels in its slot and tells the poll there is news. */
static void publish_image(int32_t id, CGImageRef img) {
  pthread_mutex_lock(&g_image_lock);
  ImageSlot *slot = &g_image_slots[id];
  if (img != NULL) {
    slot->img = img; // the slot owns it for the life of the process
    slot->state = 1;
  } else {
    slot->state = -1;
  }
  g_image_pending--;
  g_image_events++;
  if (g_image_pending == 0) pthread_cond_broadcast(&g_image_idle);
  pthread_mutex_unlock(&g_image_lock);
}

static void *image_worker(void *unused) {
  (void)unused;
  for (;;) {
    pthread_mutex_lock(&g_image_lock);
    while (g_image_queue_next >= g_image_queue_count) pthread_cond_wait(&g_image_wake, &g_image_lock);
    ImageJob job = g_image_queue[g_image_queue_next++];
    pthread_mutex_unlock(&g_image_lock);
    CGImageRef img = NULL;
    @autoreleasepool {
      img = decode_image(job.src, job.orientation);
    }
    CFRelease(job.src);
    publish_image(job.id, img);
  }
  return NULL;
}

/** Starts the pool on first use; `NATIVE_IMAGE_WORKERS=0` decodes at load instead. */
static void start_image_pool(void) {
  if (g_image_pool_started) return;
  g_image_pool_started = 1;
  const char *env = getenv("NATIVE_IMAGE_WORKERS");
  if (env != NULL && strcmp(env, "0") == 0) return;
  long cores = sysconf(_SC_NPROCESSORS_ONLN);
  int n = cores > 1 ? (int)cores - 1 : 0;
  if (n > IMAGE_MAX_WORKERS) n = IMAGE_MAX_WORKERS;
  int started = 0;
  for (int i = 0; i < n; i++) {
    if (pthread_create(&g_image_pool_thread[i], NULL, image_worker, NULL) != 0) break;
    started++;
  }
  g_image_pool_threads = started;
}

/** Queues a decode; the caller has already counted it in g_image_pending. */
static void queue_image(int32_t id, CGImageSourceRef src, int orientation) {
  pthread_mutex_lock(&g_image_lock);
  if (g_image_queue_count == g_image_queue_cap) {
    int cap = g_image_queue_cap ? g_image_queue_cap * 2 : 16;
    ImageJob *grown = (ImageJob *)realloc(g_image_queue, (size_t)cap * sizeof(*grown));
    if (grown) {
      g_image_queue = grown;
      g_image_queue_cap = cap;
    }
  }
  if (g_image_queue_count < g_image_queue_cap) {
    g_image_queue[g_image_queue_count].id = id;
    g_image_queue[g_image_queue_count].src = src;
    g_image_queue[g_image_queue_count].orientation = orientation;
    g_image_queue_count++;
    pthread_cond_signal(&g_image_wake);
  } else {
    // No room to queue it: the caller's thread decodes it rather than losing the image.
    pthread_mutex_unlock(&g_image_lock);
    CGImageRef img = NULL;
    @autoreleasepool {
      img = decode_image(src, orientation);
    }
    CFRelease(src);
    publish_image(id, img);
    return;
  }
  pthread_mutex_unlock(&g_image_lock);
}

/** Reserves a slot for a file whose header has been read; the pixels come later. */
static int32_t image_slot_new(int w, int h) {
  pthread_mutex_lock(&g_image_lock);
  if (g_image_count == g_image_cap) {
    int cap = g_image_cap ? g_image_cap * 2 : 32;
    ImageSlot *grown = (ImageSlot *)realloc(g_image_slots, (size_t)cap * sizeof(*grown));
    if (!grown) {
      pthread_mutex_unlock(&g_image_lock);
      return -1;
    }
    g_image_slots = grown;
    g_image_cap = cap;
  }
  int32_t id = (int32_t)g_image_count++;
  g_image_slots[id].state = 0;
  g_image_slots[id].img = NULL;
  g_image_slots[id].w = w;
  g_image_slots[id].h = h;
  pthread_mutex_unlock(&g_image_lock);
  return id;
}

int32_t host_image_load(const uint8_t *path, size_t path_len, int32_t oriented) {
  @autoreleasepool {
    start_image_pool();
    if (!g_image_ids) g_image_ids = [NSMutableDictionary dictionary];
    NSString *p = str_from(path, path_len);
    // Each file can be loaded twice: as its EXIF data says, or raw for image-orientation: none.
    NSString *key = oriented ? p : [@"none:" stringByAppendingString:p];
    NSNumber *hit = g_image_ids[key];
    if (hit) return hit.intValue;
    CGImageSourceRef src = NULL;
    int pw = 0, ph = 0, o = 1;
    if (p.length > 0) {
      NSURL *url = [NSURL fileURLWithPath:p];
      src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
      if (src) {
        CFDictionaryRef props = CGImageSourceCopyPropertiesAtIndex(src, 0, NULL);
        if (props) {
          CFNumberRef n = (CFNumberRef)CFDictionaryGetValue(props, kCGImagePropertyPixelWidth);
          if (n && CFGetTypeID(n) == CFNumberGetTypeID()) CFNumberGetValue(n, kCFNumberIntType, &pw);
          n = (CFNumberRef)CFDictionaryGetValue(props, kCGImagePropertyPixelHeight);
          if (n && CFGetTypeID(n) == CFNumberGetTypeID()) CFNumberGetValue(n, kCFNumberIntType, &ph);
          if (oriented) {
            // The orientation ImageIO reports is the EXIF one, which CSS applies by default.
            n = (CFNumberRef)CFDictionaryGetValue(props, kCGImagePropertyOrientation);
            if (n && CFGetTypeID(n) == CFNumberGetTypeID()) CFNumberGetValue(n, kCFNumberIntType, &o);
          }
          CFRelease(props);
        }
      }
    }
    if (src == NULL) return -1; // no file to read: nothing to decode or report
    // Orientations 5-8 turn the image a quarter, so the size it paints at is the swapped one.
    int w = o >= 5 ? ph : pw, h = o >= 5 ? pw : ph;
    int32_t id = image_slot_new(w > 0 ? w : 0, h > 0 ? h : 0);
    if (id < 0) {
      CFRelease(src);
      return -1;
    }
    g_image_ids[key] = @(id);
    pthread_mutex_lock(&g_image_lock);
    g_image_pending++;
    pthread_mutex_unlock(&g_image_lock);
    if (g_image_pool_threads == 0) {
      // No pool: the decode runs here, before the call answers, as it always did.
      CGImageRef img = NULL;
      @autoreleasepool {
        img = decode_image(src, oriented ? o : 0);
      }
      CFRelease(src);
      publish_image(id, img);
      return id;
    }
    queue_image(id, src, oriented ? o : 0);
    return id;
  }
}

static CGImageRef image_at(int32_t id) {
  if (id < 0 || id >= g_image_count) return NULL;
  pthread_mutex_lock(&g_image_lock);
  CGImageRef img = g_image_slots[id].state == 1 ? g_image_slots[id].img : NULL;
  pthread_mutex_unlock(&g_image_lock);
  return img; // the slot keeps its reference for the life of the process
}

double host_image_width(int32_t id) {
  if (id < 0 || id >= g_image_count) return 0;
  return (double)g_image_slots[id].w;
}

double host_image_height(int32_t id) {
  if (id < 0 || id >= g_image_count) return 0;
  return (double)g_image_slots[id].h;
}

/** 1 once the image's decode is over, whether it made pixels or failed; 0 while it is running. */
int32_t host_image_ready(int32_t id) {
  if (id < 0 || id >= g_image_count) return 1;
  pthread_mutex_lock(&g_image_lock);
  int state = g_image_slots[id].state;
  pthread_mutex_unlock(&g_image_lock);
  return state != 0;
}

/** 1 when the image's decode failed, so the page hears an error instead of a load. */
int32_t host_image_failed(int32_t id) {
  if (id < 0 || id >= g_image_count) return 1;
  pthread_mutex_lock(&g_image_lock);
  int failed = g_image_slots[id].state < 0;
  pthread_mutex_unlock(&g_image_lock);
  return failed;
}

/** Waits for every queued decode: a snapshot that paints images before they are ready would not
 *  be the picture the page settles on. */
void host_images_settled(void) {
  start_image_pool();
  pthread_mutex_lock(&g_image_lock);
  while (g_image_pending > 0) pthread_cond_wait(&g_image_idle, &g_image_lock);
  pthread_mutex_unlock(&g_image_lock);
}

/** 1 when a decode has landed since the last call, for the poll to report. */
static int take_image_event(void) {
  int holds = 0;
  pthread_mutex_lock(&g_image_lock);
  if (g_image_events > 0) {
    g_image_events = 0;
    holds = 1;
  }
  pthread_mutex_unlock(&g_image_lock);
  return holds;
}

// Places an image in the display list, scaled to a rect in the current (y down) user space.
// `alpha` comes from the painted element's opacity.
void host_image_draw(int32_t id, double x, double y, double w, double h, double alpha, double smooth) {
  if (id < 0) return;
  Cmd *c = push_cmd();
  c->kind = CMD_IMAGE;
  c->image = id;
  c->x = x; c->y = y; c->w = w; c->h = h; c->size = alpha; c->color = 0xffffffff;
  c->smooth = smooth > 0.5;
}

// Places the part of an image within a source rect, in image pixels, into a rect in the current
// (y down) user space: one slice of a picture cut up for a border image.
void host_image_draw_part(int32_t id, double x, double y, double w, double h,
                          double sx, double sy, double sw, double sh, double alpha, double smooth) {
  if (id < 0) return;
  Cmd *c = push_cmd();
  c->kind = CMD_IMAGE;
  c->image = id;
  c->x = x; c->y = y; c->w = w; c->h = h; c->size = alpha; c->color = 0xffffffff;
  c->smooth = smooth > 0.5;
  c->sx = sx; c->sy = sy; c->sw = sw; c->sh = sh;
}
// ---------------------------------------------------------------------------
// Video
//
// A <video> is AVFoundation's: the player decodes the file and an
// AVPlayerItemVideoOutput hands over the frame for the player's current time, which replay draws
// like an image into the element's box. The runtime drives the player (play, pause, seek, volume,
// rate) and asks for a frame each time the page paints.

#define VIDEO_MAX 16
static AVPlayer *g_video_player[VIDEO_MAX] = { nil };
static AVPlayerItemVideoOutput *g_video_output[VIDEO_MAX] = { nil };
static CIContext *g_video_context = nil;

static int32_t video_index(int32_t id) {
  return id > 0 && id <= VIDEO_MAX ? id - 1 : -1;
}

/** AVFoundation reports its loading and decoding callbacks on the main queue, so a headless run
 *  that never enters AppKit's run loop has to service it itself. */
static void pump_run_loop(void) {
  CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.001, true);
}

int32_t host_video_open(const uint8_t *path, size_t n) {
  @autoreleasepool {
    NSURL *url = [NSURL fileURLWithPath:str_from(path, n)];
    for (int i = 0; i < VIDEO_MAX; i++) {
      if (g_video_player[i] != nil) continue;
      AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
      AVPlayer *player = [AVPlayer playerWithPlayerItem:item];
      NSDictionary *attrs = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA) };
      AVPlayerItemVideoOutput *output = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:attrs];
      [item addOutput:output];
      g_video_player[i] = player;
      g_video_output[i] = output;
      return i + 1;
    }
    return -1;
  }
}

void host_video_close(int32_t id) {
  int32_t i = video_index(id);
  if (i < 0) return;
  [g_video_player[i] pause];
  g_video_player[i] = nil;
  g_video_output[i] = nil;
}

void host_video_play(int32_t id) {
  pump_run_loop();
  int32_t i = video_index(id);
  if (i >= 0 && g_video_player[i] != nil) [g_video_player[i] play];
}

void host_video_pause(int32_t id) {
  int32_t i = video_index(id);
  if (i >= 0 && g_video_player[i] != nil) [g_video_player[i] pause];
}

void host_video_seek(int32_t id, double time) {
  pump_run_loop();
  int32_t i = video_index(id);
  if (i < 0 || g_video_player[i] == nil) return;
  CMTime at = CMTimeMakeWithSeconds(time < 0 ? 0 : time, 600);
  [g_video_player[i] seekToTime:at toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
}

double host_video_time(int32_t id) {
  pump_run_loop();
  int32_t i = video_index(id);
  if (i < 0 || g_video_player[i] == nil) return 0;
  CMTime t = g_video_player[i].currentTime;
  if (!CMTIME_IS_NUMERIC(t)) return 0;
  double seconds = CMTimeGetSeconds(t);
  return seconds != seconds ? 0 : seconds;
}

double host_video_duration(int32_t id) {
  int32_t i = video_index(id);
  if (i < 0 || g_video_player[i] == nil || g_video_player[i].currentItem == nil) return -1;
  CMTime d = g_video_player[i].currentItem.duration;
  if (!CMTIME_IS_NUMERIC(d)) return -1;
  double seconds = CMTimeGetSeconds(d);
  return seconds != seconds ? -1 : seconds;
}

double host_video_width(int32_t id) {
  int32_t i = video_index(id);
  if (i < 0 || g_video_player[i] == nil || g_video_player[i].currentItem == nil) return 0;
  CGSize size = g_video_player[i].currentItem.presentationSize;
  return size.width > 0 ? size.width : 0;
}

double host_video_height(int32_t id) {
  int32_t i = video_index(id);
  if (i < 0 || g_video_player[i] == nil || g_video_player[i].currentItem == nil) return 0;
  CGSize size = g_video_player[i].currentItem.presentationSize;
  return size.height > 0 ? size.height : 0;
}

int32_t host_video_ready(int32_t id) {
  pump_run_loop();
  int32_t i = video_index(id);
  if (i < 0 || g_video_player[i] == nil || g_video_player[i].currentItem == nil) return -1;
  AVPlayerItemStatus status = g_video_player[i].currentItem.status;
  if (status == AVPlayerItemStatusReadyToPlay) return 1;
  if (status == AVPlayerItemStatusFailed) return -1;
  return 0;
}

void host_video_set_volume(int32_t id, double volume) {
  int32_t i = video_index(id);
  if (i >= 0 && g_video_player[i] != nil) g_video_player[i].volume = (float)(volume < 0 ? 0 : volume > 1 ? 1 : volume);
}

void host_video_set_muted(int32_t id, int32_t muted) {
  int32_t i = video_index(id);
  if (i >= 0 && g_video_player[i] != nil) g_video_player[i].muted = muted != 0;
}

void host_video_set_rate(int32_t id, double rate) {
  int32_t i = video_index(id);
  if (i >= 0 && g_video_player[i] != nil) g_video_player[i].rate = (float)(rate > 0 ? rate : 1);
}

/** What canPlayType answers on this host: AVFoundation plays MP4/MOV/M4A and its audio, not
 *  WebM or Ogg. */
int32_t host_video_can_play(const uint8_t *type, size_t n) {
  char t[256];
  size_t at = 0;
  for (size_t i = 0; i < n && at + 1 < sizeof(t); i++) {
    unsigned char ch = type[i];
    if (ch >= 'A' && ch <= 'Z') ch = (unsigned char)(ch - 'A' + 'a');
    t[at++] = (char)ch;
  }
  t[at] = '\0';
  if (strstr(t, "video/mp4") || strstr(t, "video/quicktime") || strstr(t, "video/x-m4v") ||
      strstr(t, "audio/mp4") || strstr(t, "audio/aac") || strstr(t, "audio/mpeg") ||
      strstr(t, "audio/wav") || strstr(t, "audio/x-wav") || strstr(t, "audio/x-m4a") ||
      strstr(t, "audio/m4a")) return 2;
  return 0;
}

void host_video_draw(int32_t id, double x, double y, double w, double h, double alpha) {
  if (id < 0) return;
  Cmd *c = push_cmd();
  c->kind = CMD_VIDEO;
  c->image = id;
  c->x = x; c->y = y; c->w = w; c->h = h; c->size = alpha;
}


// ---------------------------------------------------------------------------
// Canvas 2D

// A stroke's dash pattern is at most this many lengths; a longer one is cut there.
#define DASH_MAX 32

// A <canvas> owns a bitmap context of its own. The context's user space is the canvas's: top-left
// origin, y down, device pixels, with `base` taking that space to the bitmap's y-up space. Canvas
// operations run as they are called, and the bitmap is drawn into the display list as an image
// when the page paints (CMD_CANVAS), so a canvas has no commands of its own in the list.
//
// Paths are built in device space: the CTM in effect when a segment is added is baked in, as the
// canvas API requires. Filling and clipping therefore replay the path with an identity CTM, and a
// stroke scales its pen by the CTM in effect at stroke time.

#define MAX_STOPS 4096

typedef struct {
  double x0, y0, r0, x1, y1, r1;
  int radial;
  CGColorSpaceRef space;
  size_t n, cap;
  double *loc;
  uint32_t *col;
  CGGradientRef grad;
} Gradient;

static void gradient_clear(Gradient *g);
static void gradient_parse(Gradient *g, const uint8_t *def, size_t n);

#define FILTER_MAX 8

// One full circle of the current path, kept as the elements it became in device space: the move
// and the four curves an arc turns into. A fill of the circles can replay them exactly.
typedef struct {
  double cx, cy, r;
  CGPoint move;
  CGPoint curve[4][3];
} Circle;

// A canvas fill the GPU draws from the shape itself. The edge's coverage comes from the shape's
// distance to the pixel, so a fill at a fractional position is smooth without multisampling.
enum { CGPU_RECT = 1, CGPU_OVAL };

typedef struct {
  int kind;       // CGPU_*
  uint32_t color; // the fill's colour, as the canvas holds it (0xRRGGBBAA)
  double alpha;   // the globalAlpha it is painted with
  double m[6];    // local space -> device pixels
  double x, y, w, h;
} CanvasGpuCmd;

typedef struct {
  CGContextRef ctx;
  CGMutablePathRef path;
  // While the path holds nothing but full circles, the circles are also kept here in device
  // space: the canvas statistics count them, and a fill of them can be drawn without
  // re-tessellating the arcs. Anything else in the path turns pathKind into 2 for good.
  int pathKind; // 0 nothing drawn yet, 1 full circles only, 2 other geometry
  int circleCount, circleCap;
  Circle *circles;
  double curX, curY; // the path's current point, device space
  int havePoint;
  double w, h; // bitmap pixels
  CGImageRef image; // cached bitmap for the display list; dropped when the canvas changes
  CGAffineTransform base;
  double alpha;
  int composite;
  // Styles live here rather than in the CG context: the runtime keeps the canvas state stack and
  // puts these back after a restore, the same way it puts back the transform and clip.
  int fillKind, strokeKind; // 0 colour, 1 gradient
  uint32_t fillColor, strokeColor;
  // The gradient each style is painting with. Bounded by the canvas count: a style's definition
  // replaces the last one, so a page that makes a gradient a frame holds no more than one each.
  Gradient fillGrad, strokeGrad;
  double fontSize, fontWeight;
  double lineWidth;
  int cap, join;
  // The dash pattern the pen is broken into, in user units, and how far into it a stroke starts.
  // A pattern holds at most DASH_MAX lengths; anything longer is cut there.
  double dash[DASH_MAX];
  int dashCount;
  double dashOffset;
  // The filter chain drawing operations go through. Each entry is a CSS filter function: `kind`
  // from the FILTER_* list, its one argument in `a` (b, c and d are for functions that grow more).
  struct { int kind; double a, b, c, d; } filter[FILTER_MAX];
  int filterCount;
  CGContextRef scratch; // where a filtered operation paints before the chain runs
  struct GlCanvas *gl; // null unless the canvas was given a "webgl2" context
  // A 2D canvas the window's compositor draws from a texture of its own: the bitmap is copied in
  // when `gen` (which every change moves) has passed the generation the texture holds. Two
  // textures take turns, so a frame never writes the one the last frame may still be reading.
  unsigned long gen, tex_gen;
  int tex[2], tex_w, tex_h, tex_cur;
  // The backend that made tex[2], for a GPU flush or a readback of one.
  CompBackend *backend;
  // GPU fills waiting for the canvas texture (NATIVE_GPU_CANVAS=1): shapes the sdf shaders draw
  // straight into tex[k]. gpu_dirty is set when the texture holds draws the bitmap does not, and
  // any operation that needs the bitmap flushes and reads it back first.
  CanvasGpuCmd *gpu;
  int gpu_count, gpu_cap;
  int gpu_cleared; // the batch starts from a full-canvas clear
  int gpu_dirty;   // the texture or the batch holds draws the bitmap does not
  int gpu_unsynced; // the texture holds draws the bitmap has not taken back yet
  // Clips in effect. The GPU batch only runs with none, so a clip flushes it first.
  int clip_depth;
  int *clip_saved;
  int clip_saved_n, clip_saved_cap;
  // The one shape the current path describes (HINT_*), and the circles of a path that holds only
  // full circles (the grain canvas's per-bucket path). A path that is anything else is
  // HINT_GENERAL and stays on the CPU.
  int hint;
  double hint_x, hint_y, hint_w, hint_h;
  double hint_m[6];
  int hint_circles;
  int circle_count, circle_cap;
  struct { double cx, cy, r; double m[6]; } *circles;
  int path_fresh;  // beginPath since the last element
  int path_moved;  // the last element was a moveTo, at path_mx, path_my
  double path_mx, path_my;
  double path_mm[6];
} Canvas;

enum { HINT_NONE, HINT_RECT, HINT_OVALS, HINT_GENERAL };

enum {
  FILTER_BLUR = 1,
  FILTER_BRIGHTNESS,
  FILTER_CONTRAST,
  FILTER_SATURATE,
  FILTER_GRAYSCALE,
  FILTER_SEPIA,
  FILTER_HUE_ROTATE,
  FILTER_INVERT,
  FILTER_OPACITY,
};

// One drawing operation, as the filter machinery hands it around: the shape to paint and what to
// paint it with. The path operations read the canvas's current path.
enum { OP_FILL, OP_STROKE, OP_FILL_RECT, OP_STROKE_RECT, OP_TEXT };

typedef struct {
  int kind; // OP_*
  int flag; // the fill rule for OP_FILL, and stroke rather than fill for OP_TEXT
  double x, y, w, h, maxWidth;
  const uint8_t *text;
  size_t n;
} CanvasOp;

static Canvas **g_canvases = NULL;
static size_t g_canvas_count = 0, g_canvas_cap = 0;

static Canvas *canvas_at(int32_t id) {
  if (id < 0 || (size_t)id >= g_canvas_count) return NULL;
  return g_canvases[(size_t)id];
}

// --- GPU canvas ------------------------------------------------------------------------------
//
// A 2D canvas can draw its solid fills with the sdf shaders, straight into the texture the
// compositor samples (NATIVE_GPU_CANVAS=1). Shapes whose edges the shaders can describe (a rect,
// an oval, a path of full circles) are queued; everything else flushes the queue, reads the
// texture back into the bitmap, and runs on the CPU as before. The bitmap is authoritative
// whenever anything reads it.

/** Whether fills take the GPU path. Off until the pixels match Chrome on the canvas parity set. */
static int canvas_gpu_on(void) {
  static int on = -1;
  if (on < 0) {
    const char *env = getenv("NATIVE_GPU_CANVAS");
    on = env != NULL && env[0] == '1' && env[1] == 0;
  }
  return on;
}

static void canvas_gpu_flush(Canvas *c);
static void canvas_gpu_sync(Canvas *c);
static void canvas_gpu_replay_cpu(Canvas *c);

/** Whether this canvas can have its fills drawn on the GPU: a 2D canvas, with a solid fill, the
 *  default composite, no filter and no clip. */
static int canvas_gpu_ready(Canvas *c) {
  return canvas_gpu_on() && c->ctx != NULL && c->gl == NULL && c->filterCount == 0 &&
         c->clip_depth == 0 && c->composite == 0 && c->fillKind == 0 && c->alpha > 0;
}

/** The context's transform, as a, b, c, d, tx, ty. */
static void canvas_ctm(Canvas *c, double m[6]) {
  CGAffineTransform t = CGContextGetCTM(c->ctx);
  m[0] = t.a; m[1] = t.b; m[2] = t.c; m[3] = t.d; m[4] = t.tx; m[5] = t.ty;
}

static void canvas_gpu_push(Canvas *c, int kind, const double m[6], double x, double y,
                            double w, double h) {
  if (c->gpu_count == c->gpu_cap) {
    c->gpu_cap = c->gpu_cap ? c->gpu_cap * 2 : 32;
    c->gpu = realloc(c->gpu, (size_t)c->gpu_cap * sizeof(CanvasGpuCmd));
  }
  if (c->gpu == NULL) { c->gpu_count = 0; c->gpu_cap = 0; return; }
  CanvasGpuCmd *q = &c->gpu[c->gpu_count++];
  q->kind = kind;
  q->color = c->fillColor;
  q->alpha = c->alpha;
  memcpy(q->m, m, 6 * sizeof(double));
  q->x = x; q->y = y; q->w = w; q->h = h;
  c->gpu_dirty = 1;
}

/** Forgets the shape description of the path being built. */
static void canvas_hint_begin(Canvas *c) {
  c->hint = HINT_NONE;
  c->circle_count = 0;
  c->path_fresh = 1;
  c->path_moved = 0;
}

/** The path is something other than the hint described. */
static void canvas_hint_general(Canvas *c) {
  c->hint = HINT_GENERAL;
  c->circle_count = 0;
}

/** Adds one full circle to the path's circle list, when the hint is one shape family so far. */
static void canvas_hint_circle(Canvas *c, double cx, double cy, double r, const double m[6]) {
  if (c->hint != HINT_NONE && c->hint != HINT_OVALS) { canvas_hint_general(c); return; }
  if (c->circle_count == c->circle_cap) {
    c->circle_cap = c->circle_cap ? c->circle_cap * 2 : 64;
    c->circles = realloc(c->circles, (size_t)c->circle_cap * sizeof(*c->circles));
  }
  if (c->circles == NULL) { c->circle_count = 0; c->circle_cap = 0; canvas_hint_general(c); return; }
  c->circles[c->circle_count].cx = cx;
  c->circles[c->circle_count].cy = cy;
  c->circles[c->circle_count].r = r;
  memcpy(c->circles[c->circle_count].m, m, 6 * sizeof(double));
  c->circle_count++;
  c->hint = HINT_OVALS;
}

// WebGL canvases: the bitmap above is filled from the GL drawing buffer instead of drawn into.
static void gl_present_canvas(Canvas *c);
static void gl_resize_canvas(int32_t id, double w, double h);

static void canvas_changed(Canvas *c) {
  c->gen++;
  if (c->image) {
    CGImageRelease(c->image);
    c->image = NULL;
  }
}

// Paints one operation, running it through the filter chain when there is one.
static void canvas_op(Canvas *c, CanvasOp *op);
static void canvas_do(Canvas *c, CanvasOp *op);

// CoreGraphics has no public "set this CTM"; concatenating the current CTM's inverse with the
// wanted transform comes to the same thing.
static void context_set_ctm(CGContextRef ctx, CGAffineTransform m) {
  CGAffineTransform inv = CGAffineTransformInvert(CGContextGetCTM(ctx));
  CGContextConcatCTM(ctx, CGAffineTransformConcat(m, inv));
}

static void canvas_make_context(Canvas *c) {
  // Canvas space is top-left origin, y down; this is the bitmap context's y-up space flipped.
  c->base = CGAffineTransformMake(1, 0, 0, -1, 0, c->h);
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  c->ctx = CGBitmapContextCreate(NULL, (size_t)c->w, (size_t)c->h, 8, 0, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(cs);
  context_set_ctm(c->ctx, c->base);
  CGContextSetAlpha(c->ctx, c->alpha);
  CGContextSetLineWidth(c->ctx, c->lineWidth);
}

// Clears the canvas back to transparent and resets it, as setting width or height does.
static void canvas_reset(Canvas *c) {
  if (c->ctx) CGContextRelease(c->ctx);
  if (c->path) CGPathRelease(c->path);
  if (c->scratch) CGContextRelease(c->scratch);
  canvas_changed(c);
  c->ctx = NULL;
  c->scratch = NULL;
  c->path = CGPathCreateMutable();
  c->pathKind = 0;
  c->circleCount = 0;
  c->havePoint = 0;
  c->alpha = 1;
  c->composite = 0;
  c->filterCount = 0;
  c->fillKind = c->strokeKind = 0;
  c->fillColor = c->strokeColor = 0x000000ff;
  gradient_clear(&c->fillGrad);
  gradient_clear(&c->strokeGrad);
  c->fontSize = 10;
  c->fontWeight = 400;
  c->lineWidth = 1;
  c->cap = c->join = 0;
  c->dashCount = 0;
  c->dashOffset = 0;
  c->gpu_count = 0;
  c->gpu_cleared = 0;
  c->gpu_dirty = 0;
  c->gpu_unsynced = 0;
  c->clip_depth = 0;
  c->clip_saved_n = 0;
  canvas_hint_begin(c);
  canvas_make_context(c);
}

int32_t host_canvas_create(double w, double h) {
  Canvas *c = calloc(1, sizeof(Canvas));
  if (w < 1 || w > 16384) w = w < 1 ? 1 : 16384;
  if (h < 1 || h > 16384) h = h < 1 ? 1 : 16384;
  c->w = floor(w);
  c->h = floor(h);
  if (g_canvas_count == g_canvas_cap) {
    g_canvas_cap = g_canvas_cap ? g_canvas_cap * 2 : 8;
    g_canvases = realloc(g_canvases, g_canvas_cap * sizeof(Canvas *));
  }
  int32_t id = (int32_t)g_canvas_count;
  g_canvases[g_canvas_count++] = c;
  canvas_reset(c);
  return id;
}

void host_canvas_resize(int32_t id, double w, double h) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  if (w < 1 || w > 16384) w = w < 1 ? 1 : 16384;
  if (h < 1 || h > 16384) h = h < 1 ? 1 : 16384;
  c->w = floor(w);
  c->h = floor(h);
  canvas_reset(c);
  gl_resize_canvas(id, c->w, c->h);
}

void host_canvas_save(int32_t id) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  CGContextSaveGState(c->ctx);
  // The clip depth comes back with the state, since a restore puts back the clip too.
  if (c->clip_saved_n == c->clip_saved_cap) {
    c->clip_saved_cap = c->clip_saved_cap ? c->clip_saved_cap * 2 : 16;
    c->clip_saved = realloc(c->clip_saved, (size_t)c->clip_saved_cap * sizeof(int));
  }
  if (c->clip_saved != NULL) c->clip_saved[c->clip_saved_n++] = c->clip_depth;
}

void host_canvas_restore(int32_t id) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  // The queued fills were drawn without the clip this restore may remove; they land first.
  canvas_gpu_sync(c);
  CGContextRestoreGState(c->ctx);
  if (c->clip_saved_n > 0) c->clip_depth = c->clip_saved[--c->clip_saved_n];
}

void host_canvas_set_transform(int32_t id, double a, double b, double c0, double d, double e, double f) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  CGAffineTransform m = CGAffineTransformMake(a, b, c0, d, e, f);
  context_set_ctm(c->ctx, CGAffineTransformConcat(m, c->base));
}

static const CGBlendMode kComposites[] = {
  kCGBlendModeNormal, kCGBlendModePlusLighter, kCGBlendModeCopy, kCGBlendModeDestinationOut,
  kCGBlendModeMultiply, kCGBlendModeScreen, kCGBlendModeOverlay, kCGBlendModeDarken, kCGBlendModeLighten,
  kCGBlendModeXOR, kCGBlendModeSourceIn, kCGBlendModeSourceOut, kCGBlendModeSourceAtop,
  kCGBlendModeDestinationIn, kCGBlendModeDestinationAtop, kCGBlendModeDestinationOver,
};

void host_canvas_set_alpha(int32_t id, double a) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  c->alpha = a;
  CGContextSetAlpha(c->ctx, a);
}

void host_canvas_set_composite(int32_t id, int32_t mode) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  size_t n = sizeof(kComposites) / sizeof(kComposites[0]);
  c->composite = mode;
  CGContextSetBlendMode(c->ctx, (mode >= 0 && (size_t)mode < n) ? kComposites[mode] : kCGBlendModeNormal);
}

void host_canvas_set_line_width(int32_t id, double w) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  c->lineWidth = w;
}

void host_canvas_set_line_cap(int32_t id, int32_t cap) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  c->cap = cap < 0 ? 0 : (cap > 2 ? 2 : cap);
}

void host_canvas_set_line_join(int32_t id, int32_t join) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  c->join = join < 0 ? 0 : (join > 2 ? 2 : join);
}

// The dash pattern comes as text, "<offset> <d0> <d1> …", the way a gradient definition does,
// in user units; the stroke scales it by the transform in effect, as it does the pen width.
// A run of all-zero lengths has no gaps to draw, so it strokes solid, as the SVG spec says.
void host_canvas_set_line_dash(int32_t id, const uint8_t *s, size_t n) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  c->dashCount = 0;
  c->dashOffset = 0;
  char *buf = malloc(n + 1);
  if (!buf) return;
  memcpy(buf, s, n);
  buf[n] = 0;
  char *p = buf;
  c->dashOffset = strtod(p, &p);
  if (!isfinite(c->dashOffset)) c->dashOffset = 0;
  int positive = 0;
  while (*p) {
    char *end = p;
    double d = strtod(p, &end);
    if (end == p) break;
    p = end;
    if (!(d > 0)) d = d < 0 || !isfinite(d) ? 0 : d;
    if (d > 0) positive = 1;
    if (c->dashCount < DASH_MAX) c->dash[c->dashCount++] = d;
  }
  if (!positive) c->dashCount = 0;
  free(buf);
}

void host_canvas_set_fill_color(int32_t id, uint32_t color) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  c->fillKind = 0;
  c->fillColor = color;
}

void host_canvas_set_stroke_color(int32_t id, uint32_t color) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  c->strokeKind = 0;
  c->strokeColor = color;
}

void host_canvas_set_fill_gradient(int32_t id, const uint8_t *def, size_t n) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  gradient_parse(&c->fillGrad, def, n);
  c->fillKind = 1;
}

void host_canvas_set_stroke_gradient(int32_t id, const uint8_t *def, size_t n) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  gradient_parse(&c->strokeGrad, def, n);
  c->strokeKind = 1;
}

void host_canvas_set_font(int32_t id, double size, double weight) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  c->fontSize = size;
  c->fontWeight = weight;
}

// The filter chain, as the runtime packed it: "kind a" per function, ';' between. An empty
// definition is no filter at all.
void host_canvas_set_filter(int32_t id, const uint8_t *def, size_t n) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  c->filterCount = 0;
  size_t i = 0;
  while (i < n && c->filterCount < FILTER_MAX) {
    char buf[128];
    size_t k = 0;
    while (i < n && def[i] != ';' && k < sizeof(buf) - 1) buf[k++] = (char)def[i++];
    while (i < n && def[i] != ';') i++;
    if (i < n) i++; // past the ';'
    buf[k] = 0;
    char *end = buf;
    int kind = (int)strtod(end, &end);
    double a = strtod(end, &end);
    if (kind < FILTER_BLUR || kind > FILTER_OPACITY) continue;
    if (!(a >= 0)) a = 0; // no filter function takes a negative argument
    if (kind == FILTER_BLUR && a > 250) a = 250;
    int at = c->filterCount++;
    c->filter[at].kind = kind;
    c->filter[at].a = a;
    c->filter[at].b = c->filter[at].c = c->filter[at].d = 0;
  }
}

// An inline SVG filter: the region's pixels are read out of the bitmap, the chain runs over them
// (the portable engine in svg-filter.c), and the result replaces them. The region is in bitmap
// pixels, already clamped to the bitmap by the runtime.
void host_canvas_svg_filter(int32_t id, const uint8_t *def, size_t n, int32_t linear,
                            double x, double y, double w, double h) {
  Canvas *c = canvas_at(id);
  if (!c || !c->ctx || !(w > 0) || !(h > 0)) return;
  canvas_gpu_sync(c);
  uint8_t *data = CGBitmapContextGetData(c->ctx);
  if (!data) return;
  size_t rowBytes = CGBitmapContextGetBytesPerRow(c->ctx);
  int x0 = (int)floor(x), y0 = (int)floor(y);
  int x1 = (int)ceil(x + w), y1 = (int)ceil(y + h);
  if (x0 < 0) x0 = 0;
  if (y0 < 0) y0 = 0;
  if (x1 > (int)c->w) x1 = (int)c->w;
  if (y1 > (int)c->h) y1 = (int)c->h;
  int iw = x1 - x0, ih = y1 - y0;
  if (iw <= 0 || ih <= 0) return;
  uint8_t *buf = (uint8_t *)malloc((size_t)iw * (size_t)ih * 4);
  if (!buf) return;
  // kCGImageAlphaPremultipliedLast is premultiplied RGBA, which is the engine's layout.
  for (int row = 0; row < ih; row++) {
    memcpy(buf + (size_t)row * (size_t)iw * 4,
           data + (size_t)(y0 + row) * rowBytes + (size_t)x0 * 4, (size_t)iw * 4);
  }
  svg_filter_apply(buf, iw, ih, (const char *)def, n, linear != 0);
  for (int row = 0; row < ih; row++) {
    memcpy(data + (size_t)(y0 + row) * rowBytes + (size_t)x0 * 4,
           buf + (size_t)row * (size_t)iw * 4, (size_t)iw * 4);
  }
  free(buf);
  canvas_changed(c);
}

// --- Gradients --------------------------------------------------------------

// The canvas holds each style's gradient definition, so a page that makes a gradient every frame
// keeps no more than the one it is painting with. These are the pieces that definition owns.

static void gradient_clear(Gradient *g) {
  if (g->grad) CGGradientRelease(g->grad);
  if (g->space) CGColorSpaceRelease(g->space);
  free(g->loc);
  free(g->col);
  memset(g, 0, sizeof(*g));
}

static void gradient_rebuild(Gradient *g) {
  if (g->grad) {
    CGGradientRelease(g->grad);
    g->grad = NULL;
  }
  if (g->n == 0) return;
  double *comp = malloc(g->n * 4 * sizeof(double));
  for (size_t i = 0; i < g->n; i++) {
    uint32_t c = g->col[i];
    // CoreGraphics takes a gradient's stops in straight (unpremultiplied) components and does the
    // premultiplication itself as it fades from one stop to the next, which is the fade a canvas
    // paints: a stop that fades to transparent keeps its colour and loses its alpha. Handing it
    // premultiplied components multiplies a translucent stop by its alpha twice, so every gradient
    // that fades to transparent paints darker than a browser's by the stop's own alpha — the sun
    // glow in the canvas example at 0.85 came out 15% dim.
    comp[i * 4 + 0] = ((c >> 24) & 255) / 255.0;
    comp[i * 4 + 1] = ((c >> 16) & 255) / 255.0;
    comp[i * 4 + 2] = ((c >> 8) & 255) / 255.0;
    comp[i * 4 + 3] = (c & 255) / 255.0;
  }
  g->grad = CGGradientCreateWithColorComponents(g->space, comp, g->loc, g->n);
  free(comp);
}

// Parses the runtime's text definition of a canvas gradient into `g`, replacing what it held:
// "l;x0,y0,x1,y1" or "r;x0,y0,r0,x1,y1,r1", then one "colour,offset" per stop, colour packed
// 0xRRGGBBAA like every other host colour. The runtime writes the stops sorted by offset.
static void gradient_parse(Gradient *g, const uint8_t *def, size_t n) {
  if (g->grad) {
    CGGradientRelease(g->grad);
    g->grad = NULL;
  }
  g->n = 0;
  char *buf = malloc(n + 1);
  if (!buf) return;
  memcpy(buf, def, n);
  buf[n] = 0;
  const char *p = buf;
  int radial = *p == 'r';
  if (*p) p++;
  if (*p == ';') p++;
  double v[6];
  int nv = 0;
  while (nv < 6) {
    char *end;
    v[nv] = strtod(p, &end);
    if (end == p) break;
    nv++;
    p = end;
    if (*p != ',') break;
    p++;
  }
  if (radial ? nv < 6 : nv < 4) {
    free(buf);
    return;
  }
  g->radial = radial;
  if (radial) {
    g->x0 = v[0]; g->y0 = v[1]; g->r0 = v[2] < 0 ? 0 : v[2];
    g->x1 = v[3]; g->y1 = v[4]; g->r1 = v[5] < 0 ? 0 : v[5];
  } else {
    g->x0 = v[0]; g->y0 = v[1]; g->x1 = v[2]; g->y1 = v[3];
  }
  g->space = g->space ? g->space : CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  while (*p == ';' && g->n < MAX_STOPS) {
    p++;
    char *end;
    unsigned long long c = strtoull(p, &end, 10);
    if (end == p) break;
    p = end;
    if (*p == ',') p++;
    double off = strtod(p, &end);
    if (end == p) break;
    p = end;
    if (g->n == g->cap) {
      g->cap = g->cap ? g->cap * 2 : 4;
      g->loc = realloc(g->loc, g->cap * sizeof(double));
      g->col = realloc(g->col, g->cap * sizeof(uint32_t));
    }
    g->loc[g->n] = off < 0 ? 0 : off > 1 ? 1 : off;
    g->col[g->n] = (uint32_t)c;
    g->n++;
  }
  free(buf);
  gradient_rebuild(g);
}

// Paints the gradient inside the current clip. Gradient coordinates are in the user space in
// effect when it is painted, so they are carried to device space and the gradient is drawn with
// an identity CTM, like the paths it fills.
static void gradient_paint(CGContextRef ctx, Gradient *g, CGAffineTransform m) {
  if (!g->grad) return;
  CGPoint p0 = CGPointApplyAffineTransform(CGPointMake(g->x0, g->y0), m);
  CGPoint p1 = CGPointApplyAffineTransform(CGPointMake(g->x1, g->y1), m);
  double scale = sqrt(fabs(m.a * m.d - m.b * m.c));
  if (!(scale > 0)) scale = 1;
  CGContextSaveGState(ctx);
  context_set_ctm(ctx, CGAffineTransformIdentity);
  CGContextClip(ctx);
  if (!g->radial) {
    CGContextDrawLinearGradient(ctx, g->grad, p0, p1,
                                kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
  } else {
    CGContextDrawRadialGradient(ctx, g->grad, p0, g->r0 * scale, p1, g->r1 * scale,
                                kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
  }
  CGContextRestoreGState(ctx);
}

// --- Paths ------------------------------------------------------------------

// A point in the bitmap's own pixels. CoreGraphics drops a path whose coordinates run to billions
// — an SVG image whose ratio is extreme draws a rect that tall — so a coordinate is kept within a
// range far outside any bitmap, where the path still fills what can be seen.
static double canvas_coord(double v) {
  return v < -1e7 ? -1e7 : v > 1e7 ? 1e7 : v;
}

static CGPoint canvas_point(Canvas *c, double x, double y) {
  CGPoint p = CGPointApplyAffineTransform(CGPointMake(x, y), CGContextGetCTM(c->ctx));
  return CGPointMake(canvas_coord(p.x), canvas_coord(p.y));
}

// Copies a path's elements onto the canvas path one by one. Appending with CGPathAddPath would
// keep the source's leading MoveTo, which starts a new subpath there: an arc added that way is
// closed with a chord of its own when the path is filled.
typedef struct {
  CGMutablePathRef dst;
  int skipMove;
} ElementCopy;

static void canvas_copy_element(void *info, const CGPathElement *el) {
  ElementCopy *e = info;
  CGPoint *p = el->points;
  switch (el->type) {
    case kCGPathElementMoveToPoint:
      // A arc that continues a subpath has no move of its own: the next element's line from the
      // current point is the connection the canvas spec asks for.
      if (e->skipMove) { e->skipMove = 0; return; }
      CGPathMoveToPoint(e->dst, NULL, p[0].x, p[0].y);
      break;
    case kCGPathElementAddLineToPoint:
      CGPathAddLineToPoint(e->dst, NULL, p[0].x, p[0].y);
      break;
    case kCGPathElementAddQuadCurveToPoint:
      CGPathAddQuadCurveToPoint(e->dst, NULL, p[0].x, p[0].y, p[1].x, p[1].y);
      break;
    case kCGPathElementAddCurveToPoint:
      CGPathAddCurveToPoint(e->dst, NULL, p[0].x, p[0].y, p[1].x, p[1].y, p[2].x, p[2].y);
      break;
    case kCGPathElementCloseSubpath:
      CGPathCloseSubpath(e->dst);
      break;
  }
}

// Adds a path built in user space to the canvas path, baking in the current transform. With
// `connect`, the path continues the canvas path's current subpath instead of starting its own.
static void canvas_add_path(Canvas *c, CGPathRef p, int connect) {
  CGAffineTransform m = CGContextGetCTM(c->ctx);
  CGMutablePathRef d = CGPathCreateMutableCopyByTransformingPath(p, &m);
  ElementCopy e = { c->path, connect && !CGPathIsEmpty(c->path) };
  CGPathApply(d, &e, canvas_copy_element);
  CGPathRelease(d);
}

void host_canvas_begin_path(int32_t id) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  CGPathRelease(c->path);
  c->path = CGPathCreateMutable();
  c->pathKind = 0;
  c->circleCount = 0;
  c->havePoint = 0;
  canvas_hint_begin(c);
}

// A circle of user-space radius r, drawn under m, comes out as an ellipse whose semi-axes are
// r times the transform's two singular values. It may be kept as a circle only when the longer
// axis minus the shorter is under 1/255 of a pixel at that radius, so the two shapes cannot
// differ by a visible coverage level. The returned radius uses the longer axis, which covers
// the ellipse for the group boxes (they decide which circles share a fill, and a box that
// covers its shape can only group shapes together, never apart).
static int canvas_circle_transform(CGAffineTransform m, double r, double *radius) {
  double a2 = m.a * m.a + m.b * m.b, c2 = m.c * m.c + m.d * m.d;
  double dot = m.a * m.c + m.b * m.d;
  double half = (a2 - c2) / 2;
  double mid = (a2 + c2) / 2;
  double spread = sqrt(half * half + dot * dot);
  double long2 = mid + spread;
  double short2 = mid - spread > 0 ? mid - spread : 0;
  if (!(long2 > 0)) return 0;
  double longer = sqrt(long2), shorter = sqrt(short2);
  if ((longer - shorter) * r > 1.0 / 255.0) return 0;
  *radius = r * longer;
  return 1;
}

static void canvas_path_other(Canvas *c) {
  c->pathKind = 2;
}

static void canvas_record_circle(Canvas *c, const Circle *circle) {
  if (c->circleCount == c->circleCap) {
    int cap = c->circleCap ? c->circleCap * 2 : 64;
    Circle *p = realloc(c->circles, (size_t)cap * sizeof(Circle));
    if (!p) {
      canvas_path_other(c);
      return;
    }
    c->circles = p;
    c->circleCap = cap;
  }
  c->circles[c->circleCount++] = *circle;
  if (c->pathKind == 0) c->pathKind = 1;
}

// Reads a path that must be one move and four curves, the shape CGPathAddArc makes of a full
// circle, into the circle record. Anything else leaves the path ineligible for the split.
typedef struct {
  Circle *circle;
  int move;
  int curves;
} CircleWalk;

static void canvas_circle_element(void *info, const CGPathElement *el) {
  CircleWalk *w = info;
  CGPoint *p = el->points;
  if (el->type == kCGPathElementMoveToPoint && w->move == 0 && w->curves == 0) {
    w->circle->move = p[0];
    w->move = 1;
  } else if (el->type == kCGPathElementAddCurveToPoint && w->move == 1 && w->curves < 4) {
    w->circle->curve[w->curves][0] = p[0];
    w->circle->curve[w->curves][1] = p[1];
    w->circle->curve[w->curves][2] = p[2];
    w->curves++;
  } else {
    w->curves = -1;
  }
}

static int canvas_read_circle(CGPathRef path, Circle *circle) {
  CircleWalk w = { circle, 0, 0 };
  CGPathApply(path, &w, canvas_circle_element);
  return w.move == 1 && w.curves == 4;
}

void host_canvas_move_to(int32_t id, double x, double y) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  CGPoint p = canvas_point(c, x, y);
  CGPathMoveToPoint(c->path, NULL, p.x, p.y);
  c->curX = p.x;
  c->curY = p.y;
  c->havePoint = 1;
  if (c->hint == HINT_RECT) canvas_hint_general(c);
  canvas_ctm(c, c->path_mm);
  c->path_mx = x;
  c->path_my = y;
  c->path_moved = 1;
  c->path_fresh = 0;
}

void host_canvas_line_to(int32_t id, double x, double y) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  CGPoint p = canvas_point(c, x, y);
  CGPathAddLineToPoint(c->path, NULL, p.x, p.y);
  canvas_path_other(c);
  c->curX = p.x;
  c->curY = p.y;
  c->havePoint = 1;
  canvas_hint_general(c);
  c->path_fresh = 0;
  c->path_moved = 0;
}

void host_canvas_quadratic_to(int32_t id, double cx, double cy, double x, double y) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  CGPoint cp = canvas_point(c, cx, cy), p = canvas_point(c, x, y);
  CGPathAddQuadCurveToPoint(c->path, NULL, cp.x, cp.y, p.x, p.y);
  canvas_path_other(c);
  c->curX = p.x;
  c->curY = p.y;
  c->havePoint = 1;
  canvas_hint_general(c);
  c->path_fresh = 0;
  c->path_moved = 0;
}

void host_canvas_bezier_to(int32_t id, double c1x, double c1y, double c2x, double c2y, double x, double y) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  CGPoint a = canvas_point(c, c1x, c1y), b = canvas_point(c, c2x, c2y), p = canvas_point(c, x, y);
  CGPathAddCurveToPoint(c->path, NULL, a.x, a.y, b.x, b.y, p.x, p.y);
  canvas_path_other(c);
  c->curX = p.x;
  c->curY = p.y;
  c->havePoint = 1;
  canvas_hint_general(c);
  c->path_fresh = 0;
  c->path_moved = 0;
}

void host_canvas_close_path(int32_t id) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  CGPathCloseSubpath(c->path);
  canvas_path_other(c);
  canvas_hint_general(c);
  c->path_fresh = 0;
  c->path_moved = 0;
}

// Arcs and rects go through a user-space path, so the transform applies to them exactly.
void host_canvas_arc(int32_t id, double cx, double cy, double r, double start, double end, int32_t ccw) {
  Canvas *c = canvas_at(id);
  if (!c || !(r >= 0)) return;
  // A full circle is kept in the circle list for the fill path, provided the segment adds no
  // other geometry, the transform leaves it circular to within the pixel gate, and the arc
  // starts where the path already is (or opens the path).
  int full = fabs(fabs(end - start) - 2 * M_PI) < 1e-6;
  // The same path is what the sdf shaders draw when it holds one full circle: a lone
  // arc, or a moveTo to the arc's own start point followed by an arc.
  double hm[6];
  canvas_ctm(c, hm);
  int hintCircle = full && r > 0 &&
                   (c->path_fresh || (c->path_moved &&
                    fabs(cx + r * cos(start) - c->path_mx) < 1e-6 &&
                    fabs(cy + r * sin(start) - c->path_my) < 1e-6 &&
                    memcmp(hm, c->path_mm, sizeof hm) == 0));
  if (hintCircle) canvas_hint_circle(c, cx, cy, r, hm);
  else canvas_hint_general(c);
  double radius = 0;
  CGAffineTransform m = CGContextGetCTM(c->ctx);
  if (full && r > 0 && canvas_circle_transform(m, r, &radius)) {
    CGPoint sp = canvas_point(c, cx + r * cos(start), cy + r * sin(start));
    CGPoint cp = canvas_point(c, cx, cy);
    if (!c->havePoint || (fabs(sp.x - c->curX) < 1e-6 && fabs(sp.y - c->curY) < 1e-6)) {
      CGMutablePathRef p = CGPathCreateMutable();
      CGPathAddArc(p, NULL, cx, cy, r, start, end, ccw ? true : false);
      CGAffineTransform ctm = CGContextGetCTM(c->ctx);
      CGMutablePathRef d = CGPathCreateMutableCopyByTransformingPath(p, &ctm);
      Circle circle = {0};
      circle.cx = cp.x;
      circle.cy = cp.y;
      circle.r = radius;
      int hadElements = canvas_read_circle(d, &circle);
      canvas_add_path(c, p, 1);
      CGPathRelease(p);
      CGPathRelease(d);
      if (hadElements) {
        canvas_record_circle(c, &circle);
      } else {
        canvas_path_other(c);
      }
      c->curX = sp.x;
      c->curY = sp.y;
      c->havePoint = 1;
      c->path_fresh = 0;
      c->path_moved = 0;
      return;
    }
  }
  canvas_path_other(c);
  CGMutablePathRef p = CGPathCreateMutable();
  CGPathAddArc(p, NULL, cx, cy, r, start, end, ccw ? true : false);
  canvas_add_path(c, p, 1);
  CGPathRelease(p);
  CGPoint ep = canvas_point(c, cx + r * cos(end), cy + r * sin(end));
  c->curX = ep.x;
  c->curY = ep.y;
  c->havePoint = 1;
  c->path_fresh = 0;
  c->path_moved = 0;
}

void host_canvas_arc_to(int32_t id, double x1, double y1, double x2, double y2, double r) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  canvas_path_other(c);
  // The arc connects to the path's current point, which only the host can see. Carry it back to
  // user space, build the arc there, and bake the transform in as every other segment does.
  if (CGPathIsEmpty(c->path)) {
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, x1, y1);
    canvas_add_path(c, p, 0);
    CGPathRelease(p);
    CGPoint p1 = canvas_point(c, x1, y1);
    c->curX = p1.x;
    c->curY = p1.y;
    c->havePoint = 1;
    return;
  }
  CGAffineTransform m = CGContextGetCTM(c->ctx);
  CGPoint cur = CGPointApplyAffineTransform(CGPathGetCurrentPoint(c->path), CGAffineTransformInvert(m));
  CGMutablePathRef p = CGPathCreateMutable();
  CGPathMoveToPoint(p, NULL, cur.x, cur.y);
  CGPathAddArcToPoint(p, NULL, x1, y1, x2, y2, r);
  canvas_add_path(c, p, 1);
  CGPathRelease(p);
  c->curX = CGPathGetCurrentPoint(c->path).x;
  c->curY = CGPathGetCurrentPoint(c->path).y;
  c->havePoint = 1;
  canvas_hint_general(c);
  c->path_fresh = 0;
  c->path_moved = 0;
}

void host_canvas_rect(int32_t id, double x, double y, double w, double h) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  if (c->path_fresh && c->hint == HINT_NONE) {
    double rx = x, ry = y, rw = w, rh = h;
    if (rw < 0) { rx += rw; rw = -rw; }
    if (rh < 0) { ry += rh; rh = -rh; }
    if (rw > 0 && rh > 0) {
      c->hint = HINT_RECT;
      c->hint_x = rx; c->hint_y = ry; c->hint_w = rw; c->hint_h = rh;
      canvas_ctm(c, c->hint_m);
    } else {
      canvas_hint_general(c);
    }
  } else {
    canvas_hint_general(c);
  }
  CGMutablePathRef p = CGPathCreateMutable();
  CGPathAddRect(p, NULL, CGRectMake(x, y, w, h));
  canvas_add_path(c, p, 0);
  CGPathRelease(p);
  canvas_path_other(c);
  CGPoint p1 = canvas_point(c, x, y);
  c->curX = p1.x;
  c->curY = p1.y;
  c->havePoint = 1;
  c->path_fresh = 0;
  c->path_moved = 0;
}

// --- Fill statistics (NATIVE_CANVAS_STATS=1) ------------------------------------------

typedef struct {
  double x0, y0, x1, y1;
  int i;
} CanvasStatBox;

static int canvas_stats_enabled(void) {
  static int on = -1;
  if (on < 0) on = getenv("NATIVE_CANVAS_STATS") != NULL;
  return on;
}

static int canvas_stat_box_cmp(const void *a, const void *b) {
  const CanvasStatBox *p = a, *q = b;
  double d = p->x0 - q->x0;
  return d < 0 ? -1 : d > 0 ? 1 : 0;
}

static int canvas_stat_int_cmp(const void *a, const void *b) {
  int p = *(const int *)a, q = *(const int *)b;
  return p < q ? -1 : p > q ? 1 : 0;
}

// One line per fill that carries circles: how many, their radii and spread, how many boxes and
// discs overlap, and how long CoreGraphics took to rasterise the path.
static void canvas_stats_fill(Canvas *c, int evenodd, int groups, double ms) {
  if (!canvas_stats_enabled()) return;
  CGRect bb = CGPathGetBoundingBox(c->path);
  double bx = bb.origin.x, by = c->h - (bb.origin.y + bb.size.height);
  int n = c->circleCount;
  double rmin = 0, rmax = 0;
  int distinct = 0;
  int bbox_pairs = 0, disc_pairs = 0;
  double area = 0;
  CanvasStatBox *boxes = NULL;
  int *radii = NULL;
  if (n > 0) {
    boxes = malloc((size_t)n * sizeof(CanvasStatBox));
    radii = malloc((size_t)n * sizeof(int));
  }
  if (boxes && radii) {
    for (int i = 0; i < n; i++) {
      double cx = c->circles[i].cx, cy = c->circles[i].cy;
      double r = c->circles[i].r;
      double y = c->h - cy;
      if (i == 0 || r < rmin) rmin = r;
      if (i == 0 || r > rmax) rmax = r;
      radii[i] = (int)lround(r * 64);
      boxes[i].x0 = cx - r;
      boxes[i].x1 = cx + r;
      boxes[i].y0 = y - r;
      boxes[i].y1 = y + r;
      boxes[i].i = i;
      double xa = fmax(0, boxes[i].x0), xb = fmin(c->w, boxes[i].x1);
      double ya = fmax(0, boxes[i].y0), yb = fmin(c->h, boxes[i].y1);
      if (xb > xa && yb > ya) area += (xb - xa) * (yb - ya);
    }
    qsort(radii, (size_t)n, sizeof(int), canvas_stat_int_cmp);
    for (int i = 0; i < n; i++) if (i == 0 || radii[i] != radii[i - 1]) distinct++;
    qsort(boxes, (size_t)n, sizeof(CanvasStatBox), canvas_stat_box_cmp);
    for (int i = 0; i < n; i++) {
      for (int j = i + 1; j < n && boxes[j].x0 < boxes[i].x1; j++) {
        if (boxes[j].y0 < boxes[i].y1 && boxes[j].y1 > boxes[i].y0) {
          bbox_pairs++;
          int a = boxes[i].i, b = boxes[j].i;
          double dx = c->circles[a].cx - c->circles[b].cx;
          double dy = c->circles[a].cy - c->circles[b].cy;
          double rr = c->circles[a].r + c->circles[b].r;
          if (dx * dx + dy * dy < rr * rr) disc_pairs++;
        }
      }
    }
  }
  fprintf(stderr,
          "native: canvas fill kind=%d rule=%d circles=%d groups=%d r=%.2f..%.2f radii64=%d "
          "bbox=%.1f,%.1f %.1fx%.1f pixarea=%.0f bboxpairs=%d discpairs=%d fill=%.3fms\n",
          c->pathKind, evenodd ? 1 : 0, n, groups, rmin, rmax, distinct,
          bx, by, bb.size.width, bb.size.height, area, bbox_pairs, disc_pairs, ms);
  free(boxes);
  free(radii);
}

static int canvas_group_find(int *parent, int i) {
  while (parent[i] != i) {
    parent[i] = parent[parent[i]];
    i = parent[i];
  }
  return i;
}

static void canvas_group_join(int *parent, int a, int b) {
  a = canvas_group_find(parent, a);
  b = canvas_group_find(parent, b);
  if (a != b) parent[a] = b;
}

// Fills the circles recorded for the current path: a circle whose box, widened by a pixel,
// touches no other circle is filled on its own, and circles whose boxes do touch are filled
// together in one path, so winding and coverage stay those of the path the page built. Splitting
// the fill this way gives CoreGraphics a short edge list per call instead of one huge path.
// Two circles in different groups cover no common pixel, so the drawing is the same as one fill
// of the whole path. Returns the number of fills made, or -1 when the bookkeeping could not be
// allocated.
static int canvas_fill_circles(Canvas *c, int evenodd) {
  int n = c->circleCount;
  int *parent = malloc((size_t)n * sizeof(int));
  int *count = calloc((size_t)n, sizeof(int));
  int *start = malloc(((size_t)n + 1) * sizeof(int));
  int *cursor = malloc((size_t)n * sizeof(int));
  int *items = malloc((size_t)n * sizeof(int));
  CanvasStatBox *boxes = malloc((size_t)n * sizeof(CanvasStatBox));
  int ok = parent && count && start && cursor && items && boxes;
  int groups = 0;
  if (ok) {
    for (int i = 0; i < n; i++) {
      double cx = c->circles[i].cx, cy = c->circles[i].cy;
      double r = c->circles[i].r;
      parent[i] = i;
      // One antialiased pixel of reach beyond the circle: a circle in another group must not
      // cover any pixel this one covers.
      boxes[i].x0 = cx - r - 1;
      boxes[i].x1 = cx + r + 1;
      boxes[i].y0 = cy - r - 1;
      boxes[i].y1 = cy + r + 1;
      boxes[i].i = i;
    }
    qsort(boxes, (size_t)n, sizeof(CanvasStatBox), canvas_stat_box_cmp);
    for (int a = 0; a < n; a++) {
      for (int b = a + 1; b < n && boxes[b].x0 <= boxes[a].x1; b++) {
        if (boxes[b].y0 <= boxes[a].y1 && boxes[b].y1 >= boxes[a].y0)
          canvas_group_join(parent, boxes[a].i, boxes[b].i);
      }
    }
    for (int i = 0; i < n; i++) count[canvas_group_find(parent, i)]++;
    int total = 0;
    for (int i = 0; i < n; i++) {
      start[i] = total;
      cursor[i] = total;
      total += count[i];
      if (count[i] > 0) groups++;
    }
    start[n] = total;
    for (int i = 0; i < n; i++) items[cursor[canvas_group_find(parent, i)]++] = i;
    CGContextRef ctx = c->ctx;
    for (int i = 0; i < n; i++) {
      int members = count[i];
      if (members == 0) continue;
      CGMutablePathRef p = CGPathCreateMutable();
      for (int k = start[i]; k < start[i] + members; k++) {
        const Circle *circle = &c->circles[items[k]];
        CGPathMoveToPoint(p, NULL, circle->move.x, circle->move.y);
        for (int e = 0; e < 4; e++) {
          CGPathAddCurveToPoint(p, NULL, circle->curve[e][0].x, circle->curve[e][0].y,
                                circle->curve[e][1].x, circle->curve[e][1].y,
                                circle->curve[e][2].x, circle->curve[e][2].y);
        }
      }
      CGContextAddPath(ctx, p);
      if (evenodd) CGContextEOFillPath(ctx);
      else CGContextFillPath(ctx);
      CGPathRelease(p);
    }
  }
  free(parent);
  free(count);
  free(start);
  free(cursor);
  free(items);
  free(boxes);
  return ok ? groups : -1;
}

// The fewest circles worth splitting a fill for; below this the single path is as cheap.
#define CANVAS_FILL_SPLIT_MIN 16

// NATIVE_CANVAS_SPLIT=0 draws the single path fill, for comparing the two rasterisations.
static int canvas_split_enabled(void) {
  static int on = -1;
  if (on < 0) {
    const char *v = getenv("NATIVE_CANVAS_SPLIT");
    on = v == NULL || strcmp(v, "0") != 0;
  }
  return on;
}

// Fills a device-space path with the current fill style.
static void canvas_fill_device(Canvas *c, CGPathRef device, int evenodd, int from_path) {
  CGContextRef ctx = c->ctx;
  CGAffineTransform m = CGContextGetCTM(ctx);
  int stats = from_path && canvas_stats_enabled();
  struct timespec t0, t1;
  if (stats) clock_gettime(CLOCK_MONOTONIC, &t0);
  CGContextSaveGState(ctx);
  context_set_ctm(ctx, CGAffineTransformIdentity);
  int groups = -1;
  if (from_path && c->fillKind == 0 && c->pathKind == 1 && c->circleCount >= CANVAS_FILL_SPLIT_MIN &&
      canvas_split_enabled()) {
    set_fill(ctx, c->fillColor);
    groups = canvas_fill_circles(c, evenodd);
  }
  if (groups < 0) {
    CGContextAddPath(ctx, device);
    if (c->fillKind == 1) {
      gradient_paint(ctx, &c->fillGrad, m);
    } else {
      set_fill(ctx, c->fillColor);
      if (evenodd) CGContextEOFillPath(ctx);
      else CGContextFillPath(ctx);
    }
  }
  CGContextRestoreGState(ctx);
  if (stats) {
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double ms = (double)(t1.tv_sec - t0.tv_sec) * 1000.0 +
                (double)(t1.tv_nsec - t0.tv_nsec) / 1000000.0;
    canvas_stats_fill(c, evenodd, groups, ms);
  }
}

// Sets the pen: width, ends, corners and the dash pattern. `scale` is the transform the stroke
// is drawn under, since the pen and its dashes are sized in user space.
static void canvas_set_line(Canvas *c, CGContextRef ctx, double width, double scale) {
  CGContextSetLineWidth(ctx, width);
  CGContextSetLineCap(ctx, c->cap == 1 ? kCGLineCapRound : c->cap == 2 ? kCGLineCapSquare : kCGLineCapButt);
  CGContextSetLineJoin(ctx, c->join == 1 ? kCGLineJoinRound : c->join == 2 ? kCGLineJoinBevel : kCGLineJoinMiter);
  if (c->dashCount > 0) {
    double dashes[DASH_MAX];
    for (int i = 0; i < c->dashCount; i++) dashes[i] = c->dash[i] * scale;
    CGContextSetLineDash(ctx, c->dashOffset * scale, dashes, (size_t)c->dashCount);
  } else {
    CGContextSetLineDash(ctx, 0, NULL, 0);
  }
}

// Strokes a device-space path. The pen is sized in user space, so it is scaled by the transform
// in effect at stroke time, as on the web.
static void canvas_stroke_device(Canvas *c, CGPathRef device) {
  CGContextRef ctx = c->ctx;
  CGAffineTransform m = CGContextGetCTM(ctx);
  double scale = sqrt(fabs(m.a * m.d - m.b * m.c));
  if (!(scale > 0)) scale = 1;
  CGContextSaveGState(ctx);
  context_set_ctm(ctx, CGAffineTransformIdentity);
  canvas_set_line(c, ctx, canvas_coord(c->lineWidth * scale), scale);
  CGContextAddPath(ctx, device);
  if (c->strokeKind == 1) {
    CGContextReplacePathWithStrokedPath(ctx);
    gradient_paint(ctx, &c->strokeGrad, m);
  } else {
    set_stroke(ctx, c->strokeColor);
    CGContextStrokePath(ctx);
  }
  CGContextRestoreGState(ctx);
}

void host_canvas_fill(int32_t id, int32_t rule) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  CanvasOp op = {0};
  op.kind = OP_FILL;
  op.flag = rule;
  canvas_op(c, &op);
}

void host_canvas_stroke(int32_t id) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  CanvasOp op = {0};
  op.kind = OP_STROKE;
  canvas_op(c, &op);
}

void host_canvas_clip(int32_t id, int32_t rule) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  // The queued fills draw without a clip, so they land before this one begins.
  canvas_gpu_sync(c);
  CGContextRef ctx = c->ctx;
  CGAffineTransform saved = CGContextGetCTM(ctx);
  context_set_ctm(ctx, CGAffineTransformIdentity);
  CGContextAddPath(ctx, c->path);
  if (rule != 0) CGContextEOClip(ctx);
  else CGContextClip(ctx);
  context_set_ctm(ctx, saved);
  c->clip_depth++;
}

// --- Rects ------------------------------------------------------------------

// A rect (in user space) as a device-space path.
static CGPathRef canvas_device_rect(Canvas *c, CGMutablePathRef *owner, double x, double y, double w, double h) {
  CGPathRef user = CGPathCreateWithRect(CGRectMake(x, y, w, h), NULL);
  CGAffineTransform m = CGContextGetCTM(c->ctx);
  *owner = CGPathCreateMutableCopyByTransformingPath(user, &m);
  CGPathRelease(user);
  return *owner;
}

void host_canvas_fill_rect(int32_t id, double x, double y, double w, double h) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  CanvasOp op = {0};
  op.kind = OP_FILL_RECT;
  op.x = x; op.y = y; op.w = w; op.h = h;
  canvas_op(c, &op);
}

void host_canvas_stroke_rect(int32_t id, double x, double y, double w, double h) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  CanvasOp op = {0};
  op.kind = OP_STROKE_RECT;
  op.x = x; op.y = y; op.w = w; op.h = h;
  canvas_op(c, &op);
}

// Clears a rect to transparent black, whatever the fill style and composite mode are.
void host_canvas_clear_rect(int32_t id, double x, double y, double w, double h) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  if (canvas_gpu_on() && c->gl == NULL && c->filterCount == 0 && c->clip_depth == 0 &&
      c->gpu_count == 0) {
    // A clear of the whole canvas with nothing queued starts the next batch from transparent, so
    // the texture does not have to keep last frame's pixels.
    CGAffineTransform m = CGContextGetCTM(c->ctx);
    CGRect r = CGRectStandardize(CGRectApplyAffineTransform(CGRectMake(x, y, w, h), m));
    if (r.origin.x <= 0 && r.origin.y <= 0 && r.origin.x + r.size.width >= c->w &&
        r.origin.y + r.size.height >= c->h) {
      c->gpu_cleared = 1;
      c->gpu_dirty = 1;
      c->gpu_unsynced = 0; // the clear throws away whatever the texture held
      canvas_changed(c);
      return;
    }
  }
  canvas_gpu_sync(c);
  CGContextClearRect(c->ctx, CGRectMake(x, y, w, h));
  canvas_changed(c);
}

// --- Text -------------------------------------------------------------------

static void canvas_text(Canvas *c, const uint8_t *s, size_t n, double x, double y, double maxWidth, int stroke) {
  @autoreleasepool {
    CTLineRef line = line_for_text((const char *)s, n, c->fontSize, c->fontWeight, 0, 0, NO);
    double width = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    double sx = maxWidth > 0 && width > maxWidth ? maxWidth / width : 1;
    CGContextRef ctx = c->ctx;
    CGContextSaveGState(ctx);
    CGContextSetTextMatrix(ctx, CGAffineTransformMakeScale(sx, -1));
    CGContextSetTextPosition(ctx, x, y);
    CGContextSetShouldSmoothFonts(ctx, false);
    if (stroke) {
      CGContextSetTextDrawingMode(ctx, kCGTextStroke);
      CGContextSetLineWidth(ctx, c->lineWidth);
      set_stroke(ctx, c->strokeColor);
      CTLineDraw(line, ctx);
    } else if (c->fillKind == 1) {
      // A gradient fills the glyphs: clip to them, then paint the gradient through the clip.
      CGContextSetTextDrawingMode(ctx, kCGTextClip);
      CTLineDraw(line, ctx);
      gradient_paint(ctx, &c->fillGrad, CGContextGetCTM(ctx));
    } else {
      CGContextSetTextDrawingMode(ctx, kCGTextFill);
      set_fill(ctx, c->fillColor);
      if (font_is_fake_bold(c->fontSize, c->fontWeight)) fake_bold_stroke(ctx, c->fontSize, c->fillColor);
      CGContextSetShouldSmoothFonts(ctx, false);
      CTLineDraw(line, ctx);
    }
    CGContextRestoreGState(ctx);
    CFRelease(line);
  }
}

void host_canvas_fill_text(const uint8_t *s, size_t n, int32_t id, double x, double y, double maxWidth) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  CanvasOp op = {0};
  op.kind = OP_TEXT;
  op.x = x; op.y = y; op.maxWidth = maxWidth;
  op.text = s; op.n = n;
  canvas_op(c, &op);
}

void host_canvas_stroke_text(const uint8_t *s, size_t n, int32_t id, double x, double y, double maxWidth) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  CanvasOp op = {0};
  op.kind = OP_TEXT;
  op.flag = 1;
  op.x = x; op.y = y; op.maxWidth = maxWidth;
  op.text = s; op.n = n;
  canvas_op(c, &op);
}

// --- Filters ----------------------------------------------------------------
// A canvas filter is the chain of CSS filter functions drawing operations go through. An operation
// with a filter paints into a scratch bitmap of the canvas's size, the chain runs over those
// pixels, and the result is composited into the canvas with the alpha, blend mode and clip in
// force. There is no CoreImage here: the functions are the CSS ones, on sRGB values.

typedef struct { double r, g, b, a; } FPixel;

// The scratch bitmap painting goes into first, the canvas's size and format.
static CGContextRef canvas_scratch(Canvas *c) {
  if (c->scratch &&
      (size_t)c->w == CGBitmapContextGetWidth(c->scratch) &&
      (size_t)c->h == CGBitmapContextGetHeight(c->scratch)) {
    return c->scratch;
  }
  if (c->scratch) CGContextRelease(c->scratch);
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  c->scratch = CGBitmapContextCreate(NULL, (size_t)c->w, (size_t)c->h, 8, 0, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(cs);
  return c->scratch;
}

static double filter_clamp(double v) { return v < 0 ? 0 : (v > 1 ? 1 : v); }

// The relative luminance a saturate and grayscale filter turn a colour into.
static double filter_luma(double r, double g, double b) { return 0.2126 * r + 0.7152 * g + 0.0722 * b; }

// A Gaussian blur of the pixels in place: CSS's blur() is a Gaussian whose standard deviation is the
// length. It runs on premultiplied colour, so a transparent pixel's missing colour doesn't bleed in,
// and both passes clamp at the bitmap's edges.
static void filter_blur(FPixel *px, int w, int h, double sigma) {
  if (!(sigma > 0) || w <= 0 || h <= 0) return;
  int r = (int)ceil(sigma * 3);
  if (r < 1) r = 1;
  if (r > 64) r = 64;
  double k[129];
  double sum = 0;
  for (int i = -r; i <= r; i++) {
    double v = exp(-(double)(i * i) / (2 * sigma * sigma));
    k[i + r] = v;
    sum += v;
  }
  for (int i = 0; i <= 2 * r; i++) k[i] /= sum;
  size_t n = (size_t)w * (size_t)h;
  FPixel *a = malloc(n * sizeof(FPixel));
  FPixel *b = malloc(n * sizeof(FPixel));
  if (!a || !b) { free(a); free(b); return; }
  for (size_t i = 0; i < n; i++) {
    a[i].r = px[i].r * px[i].a;
    a[i].g = px[i].g * px[i].a;
    a[i].b = px[i].b * px[i].a;
    a[i].a = px[i].a;
  }
  for (int y = 0; y < h; y++) { // across
    for (int x = 0; x < w; x++) {
      FPixel acc = {0, 0, 0, 0};
      for (int i = -r; i <= r; i++) {
        int sx = x + i;
        if (sx < 0) sx = 0;
        if (sx >= w) sx = w - 1;
        const FPixel *s = &a[(size_t)y * (size_t)w + (size_t)sx];
        double kv = k[i + r];
        acc.r += s->r * kv; acc.g += s->g * kv; acc.b += s->b * kv; acc.a += s->a * kv;
      }
      b[(size_t)y * (size_t)w + (size_t)x] = acc;
    }
  }
  for (int y = 0; y < h; y++) { // down
    for (int x = 0; x < w; x++) {
      FPixel acc = {0, 0, 0, 0};
      for (int i = -r; i <= r; i++) {
        int sy = y + i;
        if (sy < 0) sy = 0;
        if (sy >= h) sy = h - 1;
        const FPixel *s = &b[(size_t)sy * (size_t)w + (size_t)x];
        double kv = k[i + r];
        acc.r += s->r * kv; acc.g += s->g * kv; acc.b += s->b * kv; acc.a += s->a * kv;
      }
      a[(size_t)y * (size_t)w + (size_t)x] = acc;
    }
  }
  for (size_t i = 0; i < n; i++) {
    double al = a[i].a;
    if (al > 0) {
      px[i].r = filter_clamp(a[i].r / al);
      px[i].g = filter_clamp(a[i].g / al);
      px[i].b = filter_clamp(a[i].b / al);
    } else {
      px[i].r = px[i].g = px[i].b = 0;
    }
    px[i].a = filter_clamp(al);
  }
  free(a);
  free(b);
}

// One colour filter over every pixel: the CSS function's definition, applied in sRGB.
static void filter_colour(FPixel *px, size_t n, int kind, double a) {
  double cosv = 0, sinv = 0;
  if (kind == FILTER_HUE_ROTATE) {
    double rad = a * 3.14159265358979323846 / 180.0;
    cosv = cos(rad);
    sinv = sin(rad);
  }
  for (size_t i = 0; i < n; i++) {
    FPixel *p = &px[i];
    double r = p->r, g = p->g, b = p->b, al = p->a;
    switch (kind) {
      case FILTER_BRIGHTNESS:
        r *= a; g *= a; b *= a;
        break;
      case FILTER_CONTRAST:
        r = (r - 0.5) * a + 0.5;
        g = (g - 0.5) * a + 0.5;
        b = (b - 0.5) * a + 0.5;
        break;
      case FILTER_SATURATE: {
        double l = filter_luma(r, g, b);
        r = l + (r - l) * a;
        g = l + (g - l) * a;
        b = l + (b - l) * a;
        break;
      }
      case FILTER_GRAYSCALE: {
        double l = filter_luma(r, g, b);
        double k = 1 - a;
        r = l + (r - l) * k;
        g = l + (g - l) * k;
        b = l + (b - l) * k;
        break;
      }
      case FILTER_SEPIA: {
        double sr = 0.393 * r + 0.769 * g + 0.189 * b;
        double sg = 0.349 * r + 0.686 * g + 0.168 * b;
        double sb = 0.272 * r + 0.534 * g + 0.131 * b;
        r += (sr - r) * a;
        g += (sg - g) * a;
        b += (sb - b) * a;
        break;
      }
      case FILTER_HUE_ROTATE: {
        double nr = (0.213 + cosv * 0.787 - sinv * 0.213) * r + (0.715 - cosv * 0.715 - sinv * 0.715) * g
                  + (0.072 - cosv * 0.072 + sinv * 0.928) * b;
        double ng = (0.213 - cosv * 0.213 + sinv * 0.143) * r + (0.715 + cosv * 0.285 + sinv * 0.140) * g
                  + (0.072 - cosv * 0.072 - sinv * 0.283) * b;
        double nb = (0.213 - cosv * 0.213 - sinv * 0.787) * r + (0.715 - cosv * 0.715 + sinv * 0.715) * g
                  + (0.072 + cosv * 0.928 + sinv * 0.072) * b;
        r = nr; g = ng; b = nb;
        break;
      }
      case FILTER_INVERT:
        r += (1 - 2 * r) * a;
        g += (1 - 2 * g) * a;
        b += (1 - 2 * b) * a;
        break;
      case FILTER_OPACITY:
        al *= a;
        break;
      default:
        break;
    }
    p->r = filter_clamp(r);
    p->g = filter_clamp(g);
    p->b = filter_clamp(b);
    p->a = filter_clamp(al);
  }
}

// Runs the chain over the scratch bitmap and composites it into the canvas, in device space, where
// the main context's alpha, blend mode and clip all apply to the filtered result.
static void canvas_apply_filter(Canvas *c, CGContextRef main, CGContextRef scratch) {
  int w = (int)c->w, h = (int)c->h;
  size_t n = (size_t)w * (size_t)h;
  uint8_t *data = n ? CGBitmapContextGetData(scratch) : NULL;
  if (!data) return;
  size_t rowBytes = CGBitmapContextGetBytesPerRow(scratch);
  FPixel *px = malloc(n * sizeof(FPixel));
  if (!px) return;
  for (int y = 0; y < h; y++) {
    const uint8_t *row = data + (size_t)y * rowBytes;
    for (int x = 0; x < w; x++) {
      const uint8_t *s = row + (size_t)x * 4;
      FPixel *p = &px[(size_t)y * (size_t)w + (size_t)x];
      unsigned al = s[3];
      if (al == 0) {
        p->r = p->g = p->b = p->a = 0;
      } else {
        // Premultiplied to straight, the way getImageData reads a pixel.
        p->r = (double)s[0] / al;
        p->g = (double)s[1] / al;
        p->b = (double)s[2] / al;
        p->a = (double)al / 255.0;
      }
    }
  }
  for (int i = 0; i < c->filterCount; i++) {
    int kind = c->filter[i].kind;
    if (kind == FILTER_BLUR) filter_blur(px, w, h, c->filter[i].a);
    else filter_colour(px, n, kind, c->filter[i].a);
  }
  for (int y = 0; y < h; y++) {
    uint8_t *row = data + (size_t)y * rowBytes;
    for (int x = 0; x < w; x++) {
      const FPixel *p = &px[(size_t)y * (size_t)w + (size_t)x];
      uint8_t *d = row + (size_t)x * 4;
      unsigned al = (unsigned)(p->a * 255 + 0.5);
      if (al > 255) al = 255;
      // Straight back to premultiplied, never above the alpha the pixel can carry.
      for (int ch = 0; ch < 3; ch++) {
        double v = (ch == 0 ? p->r : ch == 1 ? p->g : p->b) * al + 0.5;
        if (v < 0) v = 0;
        if (v > al) v = al;
        d[ch] = (uint8_t)v;
      }
      d[3] = (uint8_t)al;
    }
  }
  CGImageRef img = CGBitmapContextCreateImage(scratch);
  if (img) {
    CGContextSaveGState(main);
    context_set_ctm(main, CGAffineTransformIdentity);
    CGContextDrawImage(main, CGRectMake(0, 0, c->w, c->h), img);
    CGContextRestoreGState(main);
    CGImageRelease(img);
  }
  free(px);
}

// Paints an operation into the scratch bitmap, runs the filter chain over it, and composites the
// result. The scratch carries the canvas's transform, and the clip as its bounding box: the clip
// path belongs to the main context and can't be copied.
static void canvas_filtered(Canvas *c, CanvasOp *op) {
  CGContextRef main = c->ctx;
  CGContextRef scratch = canvas_scratch(c);
  if (!scratch) {
    canvas_do(c, op);
    return;
  }
  CGContextSaveGState(scratch);
  context_set_ctm(scratch, CGAffineTransformIdentity);
  CGContextClearRect(scratch, CGRectMake(0, 0, c->w, c->h));
  CGRect clip = CGContextGetClipBoundingBox(main);
  CGAffineTransform m = CGContextGetCTM(main);
  CGRect device = CGRectApplyAffineTransform(clip, m);
  device = CGRectMake(floor(CGRectGetMinX(device)), floor(CGRectGetMinY(device)),
                      ceil(CGRectGetWidth(device)), ceil(CGRectGetHeight(device)));
  CGContextClipToRect(scratch, device);
  context_set_ctm(scratch, m);
  c->ctx = scratch;
  canvas_do(c, op);
  c->ctx = main;
  CGContextRestoreGState(scratch);
  canvas_apply_filter(c, main, scratch);
}

static void canvas_do(Canvas *c, CanvasOp *op) {
  switch (op->kind) {
    case OP_FILL:
      canvas_fill_device(c, c->path, op->flag != 0, 1);
      break;
    case OP_STROKE:
      canvas_stroke_device(c, c->path);
      break;
    case OP_FILL_RECT:
      if (c->fillKind == 1) {
        CGMutablePathRef p = NULL;
        CGPathRef device = canvas_device_rect(c, &p, op->x, op->y, op->w, op->h);
        canvas_fill_device(c, device, 0, 0);
        CGPathRelease(p);
      } else {
        set_fill(c->ctx, c->fillColor);
        CGContextFillRect(c->ctx, CGRectMake(op->x, op->y, op->w, op->h));
      }
      break;
    case OP_STROKE_RECT: {
      CGMutablePathRef p = NULL;
      CGPathRef device = canvas_device_rect(c, &p, op->x, op->y, op->w, op->h);
      canvas_stroke_device(c, device);
      CGPathRelease(p);
      break;
    }
    case OP_TEXT:
      canvas_text(c, op->text, op->n, op->x, op->y, op->maxWidth, op->flag);
      break;
  }
}

/** Queues a fill whose shape the sdf shaders can draw, and answers 1 when it did. */
static int canvas_gpu_op(Canvas *c, CanvasOp *op) {
  if (!canvas_gpu_ready(c)) return 0;
  if ((c->fillColor & 255u) == 0) return 1; // a fully transparent fill draws nothing
  if (op->kind == OP_FILL_RECT) {
    double x = op->x, y = op->y, w = op->w, h = op->h;
    if (w < 0) { x += w; w = -w; }
    if (h < 0) { y += h; h = -h; }
    if (!(w > 0) || !(h > 0)) return 1;
    double m[6];
    canvas_ctm(c, m);
    canvas_gpu_push(c, CGPU_RECT, m, x, y, w, h);
    return 1;
  }
  if (op->kind != OP_FILL) return 0;
  if (c->hint == HINT_RECT) {
    canvas_gpu_push(c, CGPU_RECT, c->hint_m, c->hint_x, c->hint_y, c->hint_w, c->hint_h);
    return 1;
  }
  // One circle is one shape. A path of many circles is a single fill whose overlaps must not
  // blend twice, which the shaders do not do yet, so it stays on the CPU.
  if (c->hint == HINT_OVALS && c->circle_count == 1) {
    double r = c->circles[0].r;
    canvas_gpu_push(c, CGPU_OVAL, c->circles[0].m, c->circles[0].cx - r, c->circles[0].cy - r,
                    2 * r, 2 * r);
    return 1;
  }
  return 0;
}

static void canvas_op(Canvas *c, CanvasOp *op) {
  if (canvas_gpu_op(c, op)) {
    canvas_changed(c);
    return;
  }
  // Anything the GPU can't draw needs the bitmap, which the queued fills have not reached.
  canvas_gpu_sync(c);
  if (c->filterCount == 0) canvas_do(c, op);
  else canvas_filtered(c, op);
  canvas_changed(c);
}

// Places the part of a canvas bitmap within a source rect, in bitmap pixels, into a rect in the
// current (y down) user space: a slice cut from a rasterized SVG border image.
void host_canvas_draw_part(int32_t id, double x, double y, double w, double h,
                           double sx, double sy, double sw, double sh, double alpha, double smooth) {
  Canvas *c = canvas_at(id);
  if (!c || !c->ctx) return;
  gl_present_canvas(c);
  Cmd *cmd = push_cmd();
  cmd->kind = CMD_CANVAS;
  cmd->image = id;
  cmd->x = x; cmd->y = y; cmd->w = w; cmd->h = h; cmd->size = alpha; cmd->color = 0xffffffff;
  cmd->smooth = smooth > 0.5;
  cmd->sx = sx; cmd->sy = sy; cmd->sw = sw; cmd->sh = sh;
}

// Places a canvas bitmap in the display list, scaled to a rect in the current (y down) user space.
void host_canvas_draw(int32_t id, double x, double y, double w, double h, double alpha, double smooth) {
  Canvas *c = canvas_at(id);
  if (!c || !c->ctx) return;
  gl_present_canvas(c);
  Cmd *cmd = push_cmd();
  cmd->kind = CMD_CANVAS;
  cmd->image = id;
  cmd->x = x; cmd->y = y; cmd->w = w; cmd->h = h; cmd->size = alpha; cmd->color = 0xffffffff;
  cmd->smooth = smooth > 0.5;
}

// --- Pixels ------------------------------------------------------------------

// The bitmap's own pixels, the way getImageData hands them over: RGBA with every channel straight
// rather than premultiplied, rows top down. A pixel the rect asks for outside the bitmap reads as
// transparent black, as a browser's does. The bytes go to the callback once, inside the call.
typedef void (*pixels_cb)(const uint8_t *, size_t);

// A premultiplied channel as the straight one it stands for; rounding can leave it a step above
// its alpha, which still means fully opaque.
static uint8_t straight_channel(uint8_t v, unsigned a) {
  unsigned s = ((unsigned)v * 255 + a / 2) / a;
  return (uint8_t)(s > 255 ? 255 : s);
}

void host_canvas_get_image_data(int32_t id, double sx, double sy, double sw, double sh, pixels_cb cb) {
  int w = (int)sw, h = (int)sh;
  if (w < 0) w = 0;
  if (h < 0) h = 0;
  size_t n = (size_t)w * (size_t)h * 4;
  uint8_t *out = n ? calloc(n, 1) : NULL;
  Canvas *c = canvas_at(id);
  if (c && c->ctx && n) {
    // The bitmap has to hold the fills the GPU drew before they are read.
    canvas_gpu_sync(c);
    uint8_t *data = CGBitmapContextGetData(c->ctx);
    size_t rowBytes = CGBitmapContextGetBytesPerRow(c->ctx);
    long long x0 = (long long)floor(sx), y0 = (long long)floor(sy);
    for (int y = 0; y < h; y++) {
      long long sy2 = y0 + y;
      if (sy2 < 0 || sy2 >= (long long)c->h) continue;
      for (int x = 0; x < w; x++) {
        long long sx2 = x0 + x;
        if (sx2 < 0 || sx2 >= (long long)c->w) continue;
        const uint8_t *p = data + (size_t)sy2 * rowBytes + (size_t)sx2 * 4;
        uint8_t *o = out + ((size_t)y * (size_t)w + (size_t)x) * 4;
        unsigned a = p[3];
        if (a == 0) continue; // transparent black, which calloc already left there
        // Premultiplied to straight: the most the 8-bit source can say.
        o[0] = straight_channel(p[0], a);
        o[1] = straight_channel(p[1], a);
        o[2] = straight_channel(p[2], a);
        o[3] = (uint8_t)a;
      }
    }
  }
  cb(out, n);
  free(out);
}

static int b64_value(uint8_t ch) {
  if (ch >= 'A' && ch <= 'Z') return ch - 'A';
  if (ch >= 'a' && ch <= 'z') return ch - 'a' + 26;
  if (ch >= '0' && ch <= '9') return ch - '0' + 52;
  if (ch == '+') return 62;
  if (ch == '/') return 63;
  return -1;
}

// Straight RGBA bytes, base64 in as many bytes as `n * 3 / 4`: pixels written at an integer offset
// in the bitmap's own space, replacing what is there, whatever the transform, clip and alpha are —
// putImageData writes pixels, and only pixels.
// Draws a decoded image into a canvas bitmap: the source rect (image pixels) into the dest rect.
// Canvas space is y-down (the base CTM flips the context), so the local flip after the translate
// keeps the image upright; globalAlpha and the blend mode are already set on the context.
void host_canvas_draw_image(int32_t id, int32_t imageId, double dx, double dy, double dw, double dh,
                            double sx, double sy, double sw, double sh, double smooth) {
  Canvas *c = canvas_at(id);
  if (!c || !c->ctx) return;
  if (!(dw > 0) || !(dh > 0) || !(sw > 0) || !(sh > 0)) return;
  canvas_gpu_sync(c);
  CGImageRef img = image_at(imageId);
  if (!img) return;
  CGContextSaveGState(c->ctx);
  CGContextClipToRect(c->ctx, CGRectMake(dx, dy, dw, dh));
  CGContextTranslateCTM(c->ctx, dx, dy + dh);
  CGContextScaleCTM(c->ctx, dw / sw, -(dh / sh));
  CGContextTranslateCTM(c->ctx, -sx, -sy);
  CGContextSetInterpolationQuality(c->ctx,
                                   smooth > 0.5 ? kCGInterpolationMedium : kCGInterpolationNone);
  // CoreGraphics always draws the whole image into the rect, so the rect is the image's own
  // pixel size: the CTM maps those pixels so the source rect covers the destination rect, and
  // the clip above keeps the rest out.
  CGContextDrawImage(c->ctx,
                     CGRectMake(0, 0, (double)CGImageGetWidth(img), (double)CGImageGetHeight(img)), img);
  CGContextRestoreGState(c->ctx);
  canvas_changed(c);
}

// Draws a canvas's bitmap into a canvas: the source rect (bitmap pixels) into the dest rect,
// under the destination's transform, with its globalAlpha and blend mode already on the context.
// A canvas drawn into itself reads the bitmap it had before the draw.
void host_canvas_draw_canvas(int32_t id, int32_t sourceId, double dx, double dy, double dw, double dh,
                             double sx, double sy, double sw, double sh, double smooth) {
  Canvas *c = canvas_at(id);
  Canvas *src = canvas_at(sourceId);
  if (!c || !c->ctx || !src || !src->ctx) return;
  if (!(dw > 0) || !(dh > 0) || !(sw > 0) || !(sh > 0)) return;
  canvas_gpu_sync(src);
  canvas_gpu_sync(c);
  CGContextFlush(src->ctx);
  CGImageRef img = src->image;
  int created = 0;
  if (!img) {
    img = CGBitmapContextCreateImage(src->ctx);
    created = 1;
  }
  if (!img) return;
  CGContextSaveGState(c->ctx);
  CGContextClipToRect(c->ctx, CGRectMake(dx, dy, dw, dh));
  CGContextTranslateCTM(c->ctx, dx, dy + dh);
  CGContextScaleCTM(c->ctx, dw / sw, -(dh / sh));
  CGContextTranslateCTM(c->ctx, -sx, -sy);
  CGContextSetInterpolationQuality(c->ctx,
                                   smooth > 0.5 ? kCGInterpolationMedium : kCGInterpolationNone);
  CGContextDrawImage(c->ctx,
                     CGRectMake(0, 0, (double)CGImageGetWidth(img), (double)CGImageGetHeight(img)), img);
  CGContextRestoreGState(c->ctx);
  if (created) CGImageRelease(img);
  canvas_changed(c);
}

void host_canvas_put_image_data(int32_t id, double dx, double dy, double w, double h, const uint8_t *b64b, size_t n) {
  Canvas *c = canvas_at(id);
  if (!c || !c->ctx) return;
  canvas_gpu_sync(c);
  int iw = (int)w, ih = (int)h;
  if (iw <= 0 || ih <= 0) return;
  size_t want = (size_t)iw * (size_t)ih * 4;
  uint8_t *px = malloc(want);
  if (!px) return;
  size_t at = 0;
  int acc = 0, bits = 0;
  for (size_t i = 0; i < n && at < want; i++) {
    int v = b64_value(b64b[i]);
    if (v < 0) continue; // the '=' padding, and anything that isn't base64
    acc = (acc << 6) | v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      px[at++] = (uint8_t)((acc >> bits) & 0xff);
    }
  }
  uint8_t *data = CGBitmapContextGetData(c->ctx);
  size_t rowBytes = CGBitmapContextGetBytesPerRow(c->ctx);
  long long x0 = (long long)floor(dx), y0 = (long long)floor(dy);
  for (int y = 0; y < ih; y++) {
    long long ty = y0 + y;
    if (ty < 0 || ty >= (long long)c->h) continue;
    for (int x = 0; x < iw; x++) {
      long long tx = x0 + x;
      if (tx < 0 || tx >= (long long)c->w) continue;
      size_t i = ((size_t)y * (size_t)iw + (size_t)x) * 4;
      unsigned a = px[i + 3];
      uint8_t *p = data + (size_t)ty * rowBytes + (size_t)tx * 4;
      if (a == 0) {
        p[0] = p[1] = p[2] = p[3] = 0;
      } else {
        // Straight to premultiplied, the way the bitmap stores a pixel.
        p[0] = (uint8_t)((px[i] * a + 127) / 255);
        p[1] = (uint8_t)((px[i + 1] * a + 127) / 255);
        p[2] = (uint8_t)((px[i + 2] * a + 127) / 255);
        p[3] = (uint8_t)a;
      }
    }
  }
  free(px);
  canvas_changed(c);
}


typedef void (*text_cb)(const uint8_t *, size_t);

// The compositor's core and Metal backend are part of this translation unit, so the window path
// and the backend share one build; the backend's shaders are compiled when it is made.
#include "compositor/compositor.c"
#include "compositor/layers.c"
#include "compositor/tiles.c"
#include "compositor/chunks.c"

/** Patches a damaged frame over the last presented picture (defined with the window compositor
 *  below). */
static int composite_damaged_into(CompBackend *b, int target, double scale, int pw, int ph);
#include "compositor/metal.m"

/// The layer the window composites onto, held from the view's creation.
static CAMetalLayer *g_metal_layer = nil;

// ---------------------------------------------------------------------------
// WebGL2
//
// A <canvas> with a "webgl2" context owns a CGL context and a framebuffer object that stands in
// for the browser's default framebuffer, and the canvas bitmap the display list draws (CMD_CANVAS)
// is a readback of it. Commands execute as they are called, as with the 2D canvas, and every call
// names the canvas it belongs to, so several WebGL canvases keep separate GL state.
//
// Programs arrive as GLSL ES 3.00 and are compiled as desktop GLSL 4.10: three.js's programs need
// only the version line changed, and their `precision` declarations are accepted as they are.

#define GL_SURFACES 3

typedef struct GlCanvas {
  CGLContextObj ctx;
  // The stand-in for the default framebuffer: a resolved RGBA8 texture the canvas bitmap is read
  // from, and, when the context asks for antialiasing, a multisampled pair drawn into and blitted
  // into the resolved one when the canvas is painted.
  GLuint fbo, color;
  GLuint msaa_fbo, msaa_color, msaa_depth;
  GLuint depth; // the resolved framebuffer's depth/stencil renderbuffer
  GLuint default_vao; // core profile has no vertex array object 0, so the page's 0 names this one
  double w, h;
  int depth_bits, stencil_bits, samples, alpha;
  // Set when a draw or clear reaches the drawing buffer, so the canvas is copied into the page's
  // display list only when it changed. A present clears it.
  int damage;
  // What a windowed page presents into instead of reading the buffer back: IOSurfaces that GL
  // draws into and the window's compositor samples as Metal textures, taking turns so GL never
  // writes the one a frame on the GPU is still reading. `surf_cur` is the last one presented, -1
  // before the first; `stale` says the canvas bitmap is behind it, for a raster that needs it.
  IOSurfaceRef surf[GL_SURFACES];
  GLuint surf_tex[GL_SURFACES], surf_fbo[GL_SURFACES];
  int surf_mt[GL_SURFACES]; // the compositor's texture over each surface, -1 until it draws one
  int surf_w, surf_h, surf_cur, surf_failed;
  int stale;
} GlCanvas;

static GlCanvas *gl_at(int32_t id) {
  Canvas *c = canvas_at(id);
  return c ? c->gl : NULL;
}

// Makes the canvas's context current. False when the canvas has no WebGL context.
static int gl_ready(GlCanvas *g) {
  if (!g || !g->ctx) return 0;
  if (CGLGetCurrentContext() != g->ctx) CGLSetCurrentContext(g->ctx);
  return 1;
}

// The renderbuffer format for the depth/stencil attachment: 0 when the context asked for neither.
// A framebuffer without a depth attachment passes the depth test, as a browser's does.
static GLenum gl_depth_format(const GlCanvas *g) {
  if (g->depth_bits && g->stencil_bits) return GL_DEPTH24_STENCIL8;
  if (g->depth_bits) return GL_DEPTH_COMPONENT24;
  if (g->stencil_bits) return GL_STENCIL_INDEX8;
  return 0;
}

// `g->fbo` for a context without antialiasing, else the multisampled one; framebuffer object 0
// from the page binds this.
static GLuint gl_draw_fbo(const GlCanvas *g) {
  return g->samples ? g->msaa_fbo : g->fbo;
}

static void gl_alloc(GlCanvas *g, double w, double h) {
  if (w < 1) w = 1;
  if (h < 1) h = 1;
  g->w = floor(w);
  g->h = floor(h);
  GLsizei gw = (GLsizei)g->w, gh = (GLsizei)g->h;

  glBindFramebuffer(GL_FRAMEBUFFER, g->fbo);
  glBindTexture(GL_TEXTURE_2D, g->color);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, gw, gh, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, g->color, 0);

  GLenum dfmt = gl_depth_format(g);
  if (dfmt) {
    glBindRenderbuffer(GL_RENDERBUFFER, g->depth);
    glRenderbufferStorage(GL_RENDERBUFFER, dfmt, gw, gh);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, g->stencil_bits ? GL_DEPTH_STENCIL_ATTACHMENT : GL_DEPTH_ATTACHMENT,
                              GL_RENDERBUFFER, g->depth);
  }

  if (g->samples) {
    glBindFramebuffer(GL_FRAMEBUFFER, g->msaa_fbo);
    glBindRenderbuffer(GL_RENDERBUFFER, g->msaa_color);
    glRenderbufferStorageMultisample(GL_RENDERBUFFER, g->samples, GL_RGBA8, gw, gh);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, g->msaa_color);
    if (dfmt) {
      glBindRenderbuffer(GL_RENDERBUFFER, g->msaa_depth);
      glRenderbufferStorageMultisample(GL_RENDERBUFFER, g->samples, dfmt, gw, gh);
      glFramebufferRenderbuffer(GL_FRAMEBUFFER, g->stencil_bits ? GL_DEPTH_STENCIL_ATTACHMENT : GL_DEPTH_ATTACHMENT,
                                GL_RENDERBUFFER, g->msaa_depth);
    }
  }

  glBindFramebuffer(GL_FRAMEBUFFER, gl_draw_fbo(g));
  glViewport(0, 0, gw, gh);
  // A browser's drawing buffer starts cleared to transparent black.
  glClearColor(0, 0, 0, 0);
  glClearDepth(1);
  glClearStencil(0);
  glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);
  glBindTexture(GL_TEXTURE_2D, 0);
  g->damage = 1;
}

// Creates the canvas's GL context and drawing buffer, or resizes the buffer it has. The first
// call fixes the context attributes the drawing buffer honours.
int32_t host_gl_attach(int32_t id, double w, double h, double depth, double stencil, double antialias) {
  Canvas *c = canvas_at(id);
  if (!c) return 0;
  GlCanvas *g = c->gl;
  if (!g) {
    g = calloc(1, sizeof(GlCanvas));
    if (!g) return 0;
    g->surf_cur = -1;
    for (int k = 0; k < GL_SURFACES; k++) g->surf_mt[k] = -1;
    c->gl = g;
  }
  if (!g->ctx) {
    g->depth_bits = depth != 0;
    g->stencil_bits = stencil != 0;
    g->samples = antialias != 0 ? 4 : 0;
    g->alpha = 1;
    CGLPixelFormatAttribute attrs[] = {
      kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_GL4_Core,
      kCGLPFAColorSize, (CGLPixelFormatAttribute)24,
      kCGLPFAAlphaSize, (CGLPixelFormatAttribute)8,
      kCGLPFADepthSize, (CGLPixelFormatAttribute)24,
      kCGLPFAAllowOfflineRenderers,
      (CGLPixelFormatAttribute)0,
    };
    CGLPixelFormatObj pix = NULL;
    GLint npix = 0;
    if (CGLChoosePixelFormat(attrs, &pix, &npix) || !pix) return 0;
    CGLError err = CGLCreateContext(pix, NULL, &g->ctx);
    CGLDestroyPixelFormat(pix);
    if (err) {
      g->ctx = NULL;
      return 0;
    }
    CGLSetCurrentContext(g->ctx);
    // WebGL always takes a point's size from gl_PointSize; a core GL context only does with this on.
    glEnable(GL_PROGRAM_POINT_SIZE);
    glGenFramebuffers(1, &g->fbo);
    glGenTextures(1, &g->color);
    glGenRenderbuffers(1, &g->depth);
    glGenVertexArrays(1, &g->default_vao);
    glBindVertexArray(g->default_vao);
    if (g->samples) {
      glGenFramebuffers(1, &g->msaa_fbo);
      glGenRenderbuffers(1, &g->msaa_color);
      glGenRenderbuffers(1, &g->msaa_depth);
      GLint max_samples = 0;
      glGetIntegerv(GL_MAX_SAMPLES, &max_samples);
      if (g->samples > max_samples) g->samples = max_samples;
    }
  }
  if (!gl_ready(g)) return 0;
  gl_alloc(g, w, h);
  return 1;
}

// Whether the drawing buffer keeps its alpha (WebGL's `alpha` context attribute).
void host_gl_set_alpha(int32_t id, double alpha) {
  GlCanvas *g = gl_at(id);
  if (g) g->alpha = alpha != 0;
}

// The window's compositor: the backend is made with the window, after the canvases' code.
static CompBackend *g_window_backend;
static int window_compositing(void);

/** Whether a canvas presents into IOSurfaces the compositor draws, rather than being read back
 *  into its bitmap every frame: a composited run, windowed or the live path a headless snapshot
 *  takes (NATIVE_COMPOSITOR_LIVE=1), unless `NATIVE_GL_SURFACE=0`. A headless run that draws no
 *  frame keeps the readback, which its snapshots replay. */
static int gl_surfaces_on(void) {
  static int on = -1;
  if (on < 0) {
    const char *env = getenv("NATIVE_GL_SURFACE");
    on = !(env != NULL && env[0] == '0' && env[1] == 0);
  }
  return on && window_compositing() && (g_view != nil || headless_live());
}

/** Drops a canvas's IOSurfaces and the textures over them, for a new size. */
static void gl_surfaces_drop(GlCanvas *g) {
  for (int k = 0; k < GL_SURFACES; k++) {
    if (g->surf_mt[k] >= 0 && g_window_backend != NULL) {
      mt_tex_wait_idle(g_window_backend, g->surf_mt[k]);
      g_window_backend->vt->tex_destroy(g_window_backend, g->surf_mt[k]);
    }
    g->surf_mt[k] = -1;
    if (g->surf_fbo[k]) glDeleteFramebuffers(1, &g->surf_fbo[k]);
    if (g->surf_tex[k]) glDeleteTextures(1, &g->surf_tex[k]);
    g->surf_fbo[k] = g->surf_tex[k] = 0;
    if (g->surf[k] != NULL) CFRelease(g->surf[k]);
    g->surf[k] = NULL;
  }
  g->surf_w = g->surf_h = 0;
  g->surf_cur = -1;
  g->stale = 0;
}

/** Makes the IOSurfaces a canvas of `w` x `h` presents into, each a GL framebuffer of its own.
 *  Answers 0 when GL can't draw into one, and the canvas reads its buffer back from then on. */
static int gl_surfaces_ensure(GlCanvas *g, int w, int h) {
  if (g->surf_failed) return 0;
  if (g->surf_w == w && g->surf_h == h && g->surf[0] != NULL) return 1;
  gl_surfaces_drop(g);
  GLint prev_fbo = 0, prev_rect = 0;
  glGetIntegerv(GL_FRAMEBUFFER_BINDING, &prev_fbo);
  glGetIntegerv(GL_TEXTURE_BINDING_RECTANGLE, &prev_rect);
  int ok = 1;
  for (int k = 0; k < GL_SURFACES && ok; k++) {
    NSDictionary *props = @{
      (id)kIOSurfaceWidth : @(w),
      (id)kIOSurfaceHeight : @(h),
      (id)kIOSurfaceBytesPerElement : @4,
      (id)kIOSurfacePixelFormat : @((uint32_t)'BGRA'),
    };
    g->surf[k] = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    if (g->surf[k] == NULL) { ok = 0; break; }
    glGenTextures(1, &g->surf_tex[k]);
    glBindTexture(GL_TEXTURE_RECTANGLE, g->surf_tex[k]);
    if (CGLTexImageIOSurface2D(g->ctx, GL_TEXTURE_RECTANGLE, GL_RGBA, w, h, GL_BGRA,
                               GL_UNSIGNED_INT_8_8_8_8_REV, g->surf[k], 0) != kCGLNoError) {
      ok = 0;
      break;
    }
    glGenFramebuffers(1, &g->surf_fbo[k]);
    glBindFramebuffer(GL_FRAMEBUFFER, g->surf_fbo[k]);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_RECTANGLE, g->surf_tex[k], 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) ok = 0;
  }
  glBindTexture(GL_TEXTURE_RECTANGLE, (GLuint)prev_rect);
  glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)prev_fbo);
  if (!ok) {
    gl_surfaces_drop(g);
    g->surf_failed = 1;
    return 0;
  }
  g->surf_w = w;
  g->surf_h = h;
  return 1;
}

/** Guards the copy from the last presented IOSurface into a canvas bitmap: a raster worker may
 *  ask for it while another replays the same canvas. */
static pthread_mutex_t g_gl_sync_lock = PTHREAD_MUTEX_INITIALIZER;

/** Brings a canvas bitmap up to the IOSurface the canvas last presented, for a raster that draws
 *  the canvas through CoreGraphics (a snapshot, a frame the compositor can't express, a canvas
 *  under a rounded clip). The surface's rows already run top down; its colours are straight. No
 *  GL call: any thread may ask, and the present flushed the work that drew the surface. */
static void gl_sync_bitmap(Canvas *c) {
  GlCanvas *g = c->gl;
  if (g == NULL || !g->stale) return;
  pthread_mutex_lock(&g_gl_sync_lock);
  if (g->stale && g->surf_cur >= 0 && g->surf[g->surf_cur] != NULL && c->ctx != NULL) {
    IOSurfaceRef surf = g->surf[g->surf_cur];
    IOSurfaceLock(surf, kIOSurfaceLockReadOnly, NULL);
    const uint8_t *base = IOSurfaceGetBaseAddress(surf);
    size_t sstride = IOSurfaceGetBytesPerRow(surf);
    uint8_t *dst = CGBitmapContextGetData(c->ctx);
    size_t stride = CGBitmapContextGetBytesPerRow(c->ctx);
    int cw = (int)c->w < g->surf_w ? (int)c->w : g->surf_w;
    int ch = (int)c->h < g->surf_h ? (int)c->h : g->surf_h;
    if (dst != NULL && base != NULL) {
      for (int y = 0; y < ch; y++) {
        const uint8_t *src = base + (size_t)y * sstride;
        uint8_t *row = dst + (size_t)y * stride;
        for (int x = 0; x < cw; x++) {
          unsigned a = g->alpha ? src[x * 4 + 3] : 255u;
          row[x * 4 + 0] = (uint8_t)((src[x * 4 + 2] * a + 127) / 255);
          row[x * 4 + 1] = (uint8_t)((src[x * 4 + 1] * a + 127) / 255);
          row[x * 4 + 2] = (uint8_t)((src[x * 4 + 0] * a + 127) / 255);
          row[x * 4 + 3] = (uint8_t)a;
        }
      }
    }
    IOSurfaceUnlock(surf, kIOSurfaceLockReadOnly, NULL);
    if (c->image) {
      CGImageRelease(c->image);
      c->image = NULL;
    }
    g->stale = 0;
  }
  pthread_mutex_unlock(&g_gl_sync_lock);
}

/** Presents the drawing buffer into the next IOSurface, on the GPU: the multisampled buffer is
 *  resolved and the resolved one blitted in upside down, so the surface's rows run top down as
 *  the compositor draws them. Nothing waits for the GPU and nothing is read back; the canvas
 *  bitmap is only filled from the surface if a CoreGraphics raster asks for it. Answers 0 when the
 *  canvas can't present this way. */
static int gl_present_surface(Canvas *c) {
  GlCanvas *g = c->gl;
  int w = (int)g->w, h = (int)g->h;
  if (!gl_surfaces_ensure(g, w, h)) return 0;
  int k = (g->surf_cur + 1) % GL_SURFACES;
  // The surface was drawn GL_SURFACES frames ago; the frame that sampled it is normally long done.
  if (g->surf_mt[k] >= 0 && g_window_backend != NULL) mt_tex_wait_idle(g_window_backend, g->surf_mt[k]);
  GLint prev_read = 0, prev_draw = 0;
  glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &prev_read);
  glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &prev_draw);
  // A blit is cut to the scissor box, which the page may have left on.
  GLboolean scissor = glIsEnabled(GL_SCISSOR_TEST);
  if (scissor) glDisable(GL_SCISSOR_TEST);
  if (g->samples) {
    glBindFramebuffer(GL_READ_FRAMEBUFFER, g->msaa_fbo);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, g->fbo);
    glBlitFramebuffer(0, 0, w, h, 0, 0, w, h, GL_COLOR_BUFFER_BIT, GL_NEAREST);
  }
  glBindFramebuffer(GL_READ_FRAMEBUFFER, g->fbo);
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, g->surf_fbo[k]);
  glBlitFramebuffer(0, 0, w, h, 0, h, w, 0, GL_COLOR_BUFFER_BIT, GL_NEAREST);
  if (scissor) glEnable(GL_SCISSOR_TEST);
  glBindFramebuffer(GL_READ_FRAMEBUFFER, (GLuint)prev_read);
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, (GLuint)prev_draw);
  // Submits the blit, so a Metal frame that samples the surface after this sees it drawn.
  glFlush();
  pthread_mutex_lock(&g_gl_sync_lock);
  g->surf_cur = k;
  g->stale = 1;
  pthread_mutex_unlock(&g_gl_sync_lock);
  g->damage = 0;
  canvas_changed(c);
  return 1;
}

// Copies the drawing buffer into the canvas bitmap for the display list: GL's rows run bottom to
// top and its colours are straight, the bitmap's run top to bottom and are premultiplied.
static void gl_present_canvas(Canvas *c) {
  GlCanvas *g = c->gl;
  if (!gl_ready(g)) return;
  // Nothing has drawn into the drawing buffer since it was last copied, so the canvas bitmap
  // already shows it: a CSS or 2D repaint of the page must not read the whole GL buffer back.
  if (!g->damage) return;
  if (gl_surfaces_on() && gl_present_surface(c)) return;
  if (g->surf_cur >= 0) gl_surfaces_drop(g); // the bitmap is the canvas's picture again
  int w = (int)g->w, h = (int)g->h;
  int cw = (int)c->w, ch = (int)c->h;
  uint8_t *px = malloc((size_t)w * h * 4);
  if (!px) return;
  // The page draws between presents, so the framebuffer it left bound has to come back.
  GLint prev_read = 0, prev_draw = 0, prev_align = 4;
  glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &prev_read);
  glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &prev_draw);
  glGetIntegerv(GL_PACK_ALIGNMENT, &prev_align);
  if (g->samples) {
    glBindFramebuffer(GL_READ_FRAMEBUFFER, g->msaa_fbo);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, g->fbo);
    glBlitFramebuffer(0, 0, w, h, 0, 0, w, h, GL_COLOR_BUFFER_BIT, GL_NEAREST);
  }
  glBindFramebuffer(GL_FRAMEBUFFER, g->fbo);
  glPixelStorei(GL_PACK_ALIGNMENT, 1);
  glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, px);
  glBindFramebuffer(GL_READ_FRAMEBUFFER, (GLuint)prev_read);
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, (GLuint)prev_draw);
  glPixelStorei(GL_PACK_ALIGNMENT, prev_align);
  uint8_t *dst = CGBitmapContextGetData(c->ctx);
  size_t stride = CGBitmapContextGetBytesPerRow(c->ctx);
  if (dst) {
    for (int y = 0; y < ch; y++) {
      const uint8_t *src = px + (size_t)(h - 1 - y) * w * 4;
      uint8_t *row = dst + (size_t)y * stride;
      for (int x = 0; x < cw; x++) {
        unsigned a = g->alpha ? src[x * 4 + 3] : 255u;
        row[x * 4 + 0] = (uint8_t)((src[x * 4 + 0] * a + 127) / 255);
        row[x * 4 + 1] = (uint8_t)((src[x * 4 + 1] * a + 127) / 255);
        row[x * 4 + 2] = (uint8_t)((src[x * 4 + 2] * a + 127) / 255);
        row[x * 4 + 3] = (uint8_t)a;
      }
    }
  }
  free(px);
  g->damage = 0;
  canvas_changed(c);
}

// Objects. Each GL name is only unique within its context, and every call names its canvas.
int32_t host_gl_create_buffer(int32_t id) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  GLuint b = 0;
  glGenBuffers(1, &b);
  return (int32_t)b;
}

int32_t host_gl_create_texture(int32_t id) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  GLuint t = 0;
  glGenTextures(1, &t);
  return (int32_t)t;
}

int32_t host_gl_create_framebuffer(int32_t id) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  GLuint f = 0;
  glGenFramebuffers(1, &f);
  return (int32_t)f;
}

int32_t host_gl_create_renderbuffer(int32_t id) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  GLuint r = 0;
  glGenRenderbuffers(1, &r);
  return (int32_t)r;
}

int32_t host_gl_create_program(int32_t id) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  return (int32_t)glCreateProgram();
}

int32_t host_gl_create_shader(int32_t id, double type) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  return (int32_t)glCreateShader((GLenum)type);
}

int32_t host_gl_create_vertex_array(int32_t id) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  GLuint v = 0;
  glGenVertexArrays(1, &v);
  return (int32_t)v;
}

// kind: 0 buffer, 1 texture, 2 framebuffer, 3 renderbuffer, 4 program, 5 shader, 6 vertex array.
void host_gl_delete_object(int32_t id, double kind, double obj) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  GLuint o = (GLuint)obj;
  switch ((int)kind) {
    case 0: glDeleteBuffers(1, &o); break;
    case 1: glDeleteTextures(1, &o); break;
    case 2: glDeleteFramebuffers(1, &o); break;
    case 3: glDeleteRenderbuffers(1, &o); break;
    case 4: glDeleteProgram(o); break;
    case 5: glDeleteShader(o); break;
    case 6: glDeleteVertexArrays(1, &o); break;
  }
}

// Buffers
void host_gl_bind_buffer(int32_t id, double target, double buffer) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBindBuffer((GLenum)target, (GLuint)buffer);
}

void host_gl_buffer_data(int32_t id, double target, double usage, const uint8_t *data, size_t n) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBufferData((GLenum)target, (GLsizeiptr)n, data, (GLenum)usage);
}

void host_gl_buffer_data_size(int32_t id, double target, double size, double usage) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBufferData((GLenum)target, (GLsizeiptr)size, NULL, (GLenum)usage);
}

void host_gl_buffer_sub_data(int32_t id, double target, double offset, const uint8_t *data, size_t n) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBufferSubData((GLenum)target, (GLintptr)offset, (GLsizeiptr)n, data);
}

// Textures
void host_gl_active_texture(int32_t id, double unit) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glActiveTexture((GLenum)unit);
}

void host_gl_bind_texture(int32_t id, double target, double texture) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBindTexture((GLenum)target, (GLuint)texture);
}

void host_gl_tex_image_2d(int32_t id, double target, double level, double internal, double w, double h,
                          double border, double format, double type, const uint8_t *data, size_t n) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  glTexImage2D((GLenum)target, (GLint)level, (GLint)internal, (GLsizei)w, (GLsizei)h, (GLint)border,
               (GLenum)format, (GLenum)type, n ? data : NULL);
}

void host_gl_tex_image_2d_null(int32_t id, double target, double level, double internal, double w, double h,
                               double border, double format, double type) {
  host_gl_tex_image_2d(id, target, level, internal, w, h, border, format, type, NULL, 0);
}

void host_gl_tex_image_3d(int32_t id, double target, double level, double internal, double w, double h, double depth,
                          double border, double format, double type, const uint8_t *data, size_t n) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  glTexImage3D((GLenum)target, (GLint)level, (GLint)internal, (GLsizei)w, (GLsizei)h, (GLsizei)depth,
               (GLint)border, (GLenum)format, (GLenum)type, n ? data : NULL);
}

void host_gl_tex_sub_image_2d(int32_t id, double target, double level, double x, double y, double w, double h,
                              double format, double type, const uint8_t *data, size_t n) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  glTexSubImage2D((GLenum)target, (GLint)level, (GLint)x, (GLint)y, (GLsizei)w, (GLsizei)h, (GLenum)format,
                  (GLenum)type, n ? data : NULL);
}

void host_gl_tex_storage_2d(int32_t id, double target, double levels, double internal, double w, double h) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glTexStorage2D((GLenum)target, (GLsizei)levels, (GLenum)internal, (GLsizei)w, (GLsizei)h);
}

// An image texture upload. The host has already decoded the file, so it draws the pixels into
// RGBA8 rows and hands those to GL; WebGL's unpack options are the runtime's, so the two that
// change the data (flip and premultiply) are applied here as the runtime passes them in.
static uint8_t *image_rgba(const int32_t image, const int flip, const int premultiply,
                           GLsizei *out_w, GLsizei *out_h) {
  CGImageRef img = image_at(image);
  if (!img) return NULL;
  size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
  if (w == 0 || h == 0) return NULL;
  uint8_t *data = calloc(w * h, 4);
  if (!data) return NULL;
  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx = CGBitmapContextCreate(data, w, h, 8, w * 4, space,
                                           kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(space);
  if (!ctx) {
    free(data);
    return NULL;
  }
  CGContextSetBlendMode(ctx, kCGBlendModeCopy);
  CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h), img);
  CGContextRelease(ctx);
  size_t count = w * h;
  // A bitmap context can only hold premultiplied alpha; UNPACK_PREMULTIPLY_ALPHA_WEBGL=false
  // asks for the file's own straight values, so undo the multiplication.
  if (!premultiply) {
    for (size_t i = 0; i < count; i++) {
      uint8_t *p = data + i * 4;
      unsigned a = p[3];
      if (a != 0 && a != 255) {
        p[0] = (uint8_t)((p[0] * 255u + a / 2) / a);
        p[1] = (uint8_t)((p[1] * 255u + a / 2) / a);
        p[2] = (uint8_t)((p[2] * 255u + a / 2) / a);
      }
    }
  }
  // GL takes the first row as texture row 0, which is the image's bottom row; flipping the
  // rows is what UNPACK_FLIP_Y_WEBGL does.
  if (flip && h > 1) {
    uint8_t *tmp = malloc(w * 4);
    if (tmp) {
      for (size_t y = 0; y < h / 2; y++) {
        uint8_t *top = data + y * w * 4;
        uint8_t *bottom = data + (h - 1 - y) * w * 4;
        memcpy(tmp, top, w * 4);
        memcpy(top, bottom, w * 4);
        memcpy(bottom, tmp, w * 4);
      }
      free(tmp);
    }
  }
  *out_w = (GLsizei)w;
  *out_h = (GLsizei)h;
  return data;
}

void host_gl_tex_image_2d_from_image(int32_t id, double target, double level, double internal,
                                     int32_t image, int32_t flip, int32_t premultiply) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  GLsizei w = 0, h = 0;
  uint8_t *data = image_rgba(image, flip != 0, premultiply != 0, &w, &h);
  if (!data) return;
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  glTexImage2D((GLenum)target, (GLint)level, (GLint)internal, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, data);
  free(data);
}

void host_gl_tex_sub_image_2d_from_image(int32_t id, double target, double level, double x, double y,
                                         int32_t image, int32_t flip, int32_t premultiply) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  GLsizei w = 0, h = 0;
  uint8_t *data = image_rgba(image, flip != 0, premultiply != 0, &w, &h);
  if (!data) return;
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  glTexSubImage2D((GLenum)target, (GLint)level, (GLint)x, (GLint)y, w, h, GL_RGBA, GL_UNSIGNED_BYTE, data);
  free(data);
}

void host_gl_tex_parameter_i(int32_t id, double target, double pname, double param) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glTexParameteri((GLenum)target, (GLenum)pname, (GLint)param);
}

void host_gl_tex_parameter_f(int32_t id, double target, double pname, double param) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glTexParameterf((GLenum)target, (GLenum)pname, (GLfloat)param);
}

void host_gl_generate_mipmap(int32_t id, double target) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glGenerateMipmap((GLenum)target);
}

void host_gl_pixel_storei(int32_t id, double pname, double param) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glPixelStorei((GLenum)pname, (GLint)param);
}

// Shaders and programs
void host_gl_shader_source(int32_t id, double shader, const char *src) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  size_t n = strlen(src);
  const char *s = src;
  char *translated = NULL;
  const char *version = "#version 300 es";
  const char *at = strstr(s, version);
  if (at) {
    const char *desktop = "#version 410 core";
    size_t head = (size_t)(at - s);
    size_t rest = n - head - strlen(version);
    translated = malloc(head + strlen(desktop) + rest + 1);
    if (translated) {
      memcpy(translated, s, head);
      memcpy(translated + head, desktop, strlen(desktop));
      memcpy(translated + head + strlen(desktop), at + strlen(version), rest);
      translated[head + strlen(desktop) + rest] = 0;
      s = translated;
    }
  }
  glShaderSource((GLuint)shader, 1, &s, NULL);
  free(translated);
}

void host_gl_compile_shader(int32_t id, double shader) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glCompileShader((GLuint)shader);
}

double host_gl_get_shader_parameter(int32_t id, double shader, double pname) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  GLint v = 0;
  glGetShaderiv((GLuint)shader, (GLenum)pname, &v);
  return v;
}

void host_gl_get_shader_info_log(int32_t id, double shader, text_cb cb) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  char log[8192];
  GLsizei n = 0;
  glGetShaderInfoLog((GLuint)shader, sizeof log, &n, log);
  cb((const uint8_t *)log, (size_t)n);
}

void host_gl_attach_shader(int32_t id, double program, double shader) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glAttachShader((GLuint)program, (GLuint)shader);
}

void host_gl_detach_shader(int32_t id, double program, double shader) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glDetachShader((GLuint)program, (GLuint)shader);
}

void host_gl_bind_attrib_location(int32_t id, double program, double index, const char *name) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBindAttribLocation((GLuint)program, (GLuint)index, name);
}

void host_gl_link_program(int32_t id, double program) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glLinkProgram((GLuint)program);
}

void host_gl_use_program(int32_t id, double program) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glUseProgram((GLuint)program);
}

double host_gl_get_program_parameter(int32_t id, double program, double pname) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  GLint v = 0;
  glGetProgramiv((GLuint)program, (GLenum)pname, &v);
  return v;
}

void host_gl_get_program_info_log(int32_t id, double program, text_cb cb) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  char log[8192];
  GLsizei n = 0;
  glGetProgramInfoLog((GLuint)program, sizeof log, &n, log);
  cb((const uint8_t *)log, (size_t)n);
}

double host_gl_get_attrib_location(int32_t id, double program, const char *name) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return -1;
  return glGetAttribLocation((GLuint)program, name);
}

double host_gl_get_uniform_location(int32_t id, double program, const char *name) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return -1;
  return glGetUniformLocation((GLuint)program, name);
}

double host_gl_get_uniform_block_index(int32_t id, double program, const char *name) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return -1;
  return glGetUniformBlockIndex((GLuint)program, name);
}

// The active uniform and attribute tables, read one entry at a time: the name through a callback,
// the type and size as numbers.
void host_gl_active_uniform_name(int32_t id, double program, double index, text_cb name) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  char buf[512];
  GLsizei len = 0;
  GLint size = 0;
  GLenum type = 0;
  glGetActiveUniform((GLuint)program, (GLuint)index, sizeof buf, &len, &size, &type, buf);
  name((const uint8_t *)buf, (size_t)len);
}

double host_gl_active_uniform_type(int32_t id, double program, double index) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  char buf[1];
  GLsizei len = 0;
  GLint size = 0;
  GLenum type = 0;
  glGetActiveUniform((GLuint)program, (GLuint)index, 0, &len, &size, &type, buf);
  return type;
}

double host_gl_active_uniform_size(int32_t id, double program, double index) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  char buf[1];
  GLsizei len = 0;
  GLint size = 0;
  GLenum type = 0;
  glGetActiveUniform((GLuint)program, (GLuint)index, 0, &len, &size, &type, buf);
  return size;
}

void host_gl_active_attrib_name(int32_t id, double program, double index, text_cb name) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  char buf[512];
  GLsizei len = 0;
  GLint size = 0;
  GLenum type = 0;
  glGetActiveAttrib((GLuint)program, (GLuint)index, sizeof buf, &len, &size, &type, buf);
  name((const uint8_t *)buf, (size_t)len);
}

double host_gl_active_attrib_type(int32_t id, double program, double index) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  char buf[1];
  GLsizei len = 0;
  GLint size = 0;
  GLenum type = 0;
  glGetActiveAttrib((GLuint)program, (GLuint)index, 0, &len, &size, &type, buf);
  return type;
}

double host_gl_active_attrib_size(int32_t id, double program, double index) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  char buf[1];
  GLsizei len = 0;
  GLint size = 0;
  GLenum type = 0;
  glGetActiveAttrib((GLuint)program, (GLuint)index, 0, &len, &size, &type, buf);
  return size;
}

// Uniforms. One call covers every vector shape: `kind` names it (1..4 float, 5..8 int, 9..12
// unsigned), and the count follows from the byte length.
void host_gl_uniform1f(int32_t id, double location, double x) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glUniform1f((GLint)location, (GLfloat)x);
}

void host_gl_uniform1i(int32_t id, double location, double x) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glUniform1i((GLint)location, (GLint)x);
}

void host_gl_uniform(int32_t id, double location, double kind, const uint8_t *data, size_t n) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  int k = (int)kind;
  int comps = ((k - 1) % 4) + 1;
  int count = (int)(n / (4 * comps));
  const GLfloat *f = (const GLfloat *)data;
  const GLint *i = (const GLint *)data;
  const GLuint *u = (const GLuint *)data;
  switch (k) {
    case 1: glUniform1fv((GLint)location, count, f); break;
    case 2: glUniform2fv((GLint)location, count, f); break;
    case 3: glUniform3fv((GLint)location, count, f); break;
    case 4: glUniform4fv((GLint)location, count, f); break;
    case 5: glUniform1iv((GLint)location, count, i); break;
    case 6: glUniform2iv((GLint)location, count, i); break;
    case 7: glUniform3iv((GLint)location, count, i); break;
    case 8: glUniform4iv((GLint)location, count, i); break;
    case 9: glUniform1uiv((GLint)location, count, u); break;
    case 10: glUniform2uiv((GLint)location, count, u); break;
    case 11: glUniform3uiv((GLint)location, count, u); break;
    case 12: glUniform4uiv((GLint)location, count, u); break;
  }
}

// `dims` is 2, 3 or 4 for the square matrix shape.
void host_gl_uniform_matrix(int32_t id, double location, double dims, double transpose, const uint8_t *data, size_t n) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  int d = (int)dims;
  int count = (int)(n / (4 * d * d));
  const GLfloat *m = (const GLfloat *)data;
  switch (d) {
    case 2: glUniformMatrix2fv((GLint)location, count, (GLboolean)transpose, m); break;
    case 3: glUniformMatrix3fv((GLint)location, count, (GLboolean)transpose, m); break;
    case 4: glUniformMatrix4fv((GLint)location, count, (GLboolean)transpose, m); break;
  }
}

// Vertex attributes
void host_gl_bind_vertex_array(int32_t id, double array) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBindVertexArray((GLuint)array == 0 ? g->default_vao : (GLuint)array);
}

void host_gl_enable_vertex_attrib_array(int32_t id, double index) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glEnableVertexAttribArray((GLuint)index);
}

void host_gl_disable_vertex_attrib_array(int32_t id, double index) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glDisableVertexAttribArray((GLuint)index);
}

void host_gl_vertex_attrib_pointer(int32_t id, double index, double size, double type, double normalized,
                                   double stride, double offset) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glVertexAttribPointer((GLuint)index, (GLint)size, (GLenum)type, (GLboolean)normalized, (GLsizei)stride,
                        (const void *)(GLintptr)offset);
}

void host_gl_vertex_attrib_i_pointer(int32_t id, double index, double size, double type, double stride, double offset) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glVertexAttribIPointer((GLuint)index, (GLint)size, (GLenum)type, (GLsizei)stride, (const void *)(GLintptr)offset);
}

void host_gl_vertex_attrib_divisor(int32_t id, double index, double divisor) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glVertexAttribDivisor((GLuint)index, (GLuint)divisor);
}

// A constant value for an attribute no buffer feeds: `kind` is the float vector length, 1 to 4.
void host_gl_vertex_attrib(int32_t id, double index, double kind, const uint8_t *data, size_t n) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  const GLfloat *v = (const GLfloat *)data;
  switch ((int)kind) {
    case 1: glVertexAttrib1fv((GLuint)index, v); break;
    case 2: glVertexAttrib2fv((GLuint)index, v); break;
    case 3: glVertexAttrib3fv((GLuint)index, v); break;
    case 4: glVertexAttrib4fv((GLuint)index, v); break;
  }
}

// Framebuffers. Binding 0 means the canvas's drawing buffer, as in a browser.
void host_gl_bind_framebuffer(int32_t id, double target, double framebuffer) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBindFramebuffer((GLenum)target, (GLuint)framebuffer == 0 ? gl_draw_fbo(g) : (GLuint)framebuffer);
}

void host_gl_bind_renderbuffer(int32_t id, double target, double renderbuffer) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBindRenderbuffer((GLenum)target, (GLuint)renderbuffer);
}

void host_gl_framebuffer_texture_2d(int32_t id, double target, double attachment, double tex_target,
                                    double texture, double level) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glFramebufferTexture2D((GLenum)target, (GLenum)attachment, (GLenum)tex_target, (GLuint)texture, (GLint)level);
}

void host_gl_framebuffer_renderbuffer(int32_t id, double target, double attachment, double rb_target,
                                      double renderbuffer) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glFramebufferRenderbuffer((GLenum)target, (GLenum)attachment, (GLenum)rb_target, (GLuint)renderbuffer);
}

void host_gl_renderbuffer_storage(int32_t id, double target, double format, double w, double h) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glRenderbufferStorage((GLenum)target, (GLenum)format, (GLsizei)w, (GLsizei)h);
}

double host_gl_check_framebuffer_status(int32_t id, double target) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  return glCheckFramebufferStatus((GLenum)target);
}

// The list arrives as 32-bit ids in a byte view, which is how an array crosses the FFI.
void host_gl_draw_buffers(int32_t id, double count, const uint8_t *buffers, size_t bytes) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  int n = (int)count;
  if (n < 0) n = 0;
  if (n > 32) n = 32;
  if (bytes < (size_t)n * 4) n = (int)(bytes / 4);
  GLenum list[32];
  const uint32_t *ids = (const uint32_t *)buffers;
  for (int i = 0; i < n; i++) {
    // The canvas's default framebuffer is a texture-backed FBO here, so WebGL's BACK is its
    // one colour attachment rather than a real back buffer.
    list[i] = (GLenum)ids[i] == GL_BACK ? GL_COLOR_ATTACHMENT0 : (GLenum)ids[i];
  }
  glDrawBuffers(n, list);
}

// Drawing
void host_gl_draw_arrays(int32_t id, double mode, double first, double count) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glDrawArrays((GLenum)mode, (GLint)first, (GLsizei)count);
  g->damage = 1;
}

void host_gl_draw_elements(int32_t id, double mode, double count, double type, double offset) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glDrawElements((GLenum)mode, (GLsizei)count, (GLenum)type, (const void *)(GLintptr)offset);
  g->damage = 1;
}

void host_gl_draw_arrays_instanced(int32_t id, double mode, double first, double count, double instances) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glDrawArraysInstanced((GLenum)mode, (GLint)first, (GLsizei)count, (GLsizei)instances);
  g->damage = 1;
}

void host_gl_draw_elements_instanced(int32_t id, double mode, double count, double type, double offset, double instances) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glDrawElementsInstanced((GLenum)mode, (GLsizei)count, (GLenum)type, (const void *)(GLintptr)offset, (GLsizei)instances);
  g->damage = 1;
}

// Fixed-function state. Each call sets one piece, as the WebGL method does.
void host_gl_enable(int32_t id, double cap) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glEnable((GLenum)cap);
}

void host_gl_disable(int32_t id, double cap) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glDisable((GLenum)cap);
}

void host_gl_clear(int32_t id, double mask) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glClear((GLbitfield)mask);
  g->damage = 1;
}

void host_gl_clear_color(int32_t id, double r, double g_, double b, double a) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glClearColor((GLfloat)r, (GLfloat)g_, (GLfloat)b, (GLfloat)a);
}

void host_gl_clear_depth(int32_t id, double depth) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glClearDepth(depth);
}

void host_gl_clear_stencil(int32_t id, double s) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glClearStencil((GLint)s);
}

void host_gl_color_mask(int32_t id, double r, double g_, double b, double a) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glColorMask(r != 0, g_ != 0, b != 0, a != 0);
}

void host_gl_depth_mask(int32_t id, double flag) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glDepthMask(flag != 0);
}

void host_gl_stencil_mask(int32_t id, double mask) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glStencilMask((GLuint)mask);
}

void host_gl_cull_face(int32_t id, double mode) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glCullFace((GLenum)mode);
}

void host_gl_front_face(int32_t id, double mode) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glFrontFace((GLenum)mode);
}

void host_gl_depth_func(int32_t id, double func) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glDepthFunc((GLenum)func);
}

void host_gl_depth_range(int32_t id, double near, double far) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glDepthRange(near, far);
}

void host_gl_blend_func(int32_t id, double src, double dst) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBlendFunc((GLenum)src, (GLenum)dst);
}

void host_gl_blend_func_separate(int32_t id, double src_rgb, double dst_rgb, double src_alpha, double dst_alpha) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBlendFuncSeparate((GLenum)src_rgb, (GLenum)dst_rgb, (GLenum)src_alpha, (GLenum)dst_alpha);
}

void host_gl_blend_equation(int32_t id, double mode) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBlendEquation((GLenum)mode);
}

void host_gl_blend_equation_separate(int32_t id, double rgb, double alpha) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBlendEquationSeparate((GLenum)rgb, (GLenum)alpha);
}

void host_gl_blend_color(int32_t id, double r, double g_, double b, double a) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBlendColor((GLfloat)r, (GLfloat)g_, (GLfloat)b, (GLfloat)a);
}

void host_gl_polygon_offset(int32_t id, double factor, double units) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glPolygonOffset((GLfloat)factor, (GLfloat)units);
}

void host_gl_stencil_func(int32_t id, double func, double ref, double mask) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glStencilFunc((GLenum)func, (GLint)ref, (GLuint)mask);
}

void host_gl_stencil_op(int32_t id, double fail, double zfail, double zpass) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glStencilOp((GLenum)fail, (GLenum)zfail, (GLenum)zpass);
}

void host_gl_viewport(int32_t id, double x, double y, double w, double h) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glViewport((GLint)x, (GLint)y, (GLsizei)w, (GLsizei)h);
}

void host_gl_scissor(int32_t id, double x, double y, double w, double h) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glScissor((GLint)x, (GLint)y, (GLsizei)w, (GLsizei)h);
}

void host_gl_line_width(int32_t id, double width) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glLineWidth((GLfloat)width);
}

void host_gl_finish(int32_t id) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glFinish();
}

void host_gl_flush(int32_t id) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glFlush();
}

// Queries
double host_gl_get_parameter_int(int32_t id, double pname) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  GLint v = 0;
  glGetIntegerv((GLenum)pname, &v);
  return v;
}

double host_gl_get_parameter_float(int32_t id, double pname) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  GLfloat v = 0;
  glGetFloatv((GLenum)pname, &v);
  return v;
}

void host_gl_get_parameter_ints(int32_t id, double pname, uint8_t *out, size_t n) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g) || n < 4) return;
  glGetIntegerv((GLenum)pname, (GLint *)out);
}

void host_gl_get_parameter_floats(int32_t id, double pname, uint8_t *out, size_t n) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g) || n < 4) return;
  glGetFloatv((GLenum)pname, (GLfloat *)out);
}

void host_gl_get_parameter_string(int32_t id, double pname, text_cb cb) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  const GLubyte *s = glGetString((GLenum)pname);
  if (s) cb(s, strlen((const char *)s));
}

// A core context has no GL_EXTENSIONS string: the list is counted and fetched by index.
int32_t host_gl_extension_count(int32_t id) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  GLint count = 0;
  glGetIntegerv(GL_NUM_EXTENSIONS, &count);
  return count;
}

void host_gl_extension_string(int32_t id, double index, text_cb cb) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  const GLubyte *s = glGetStringi(GL_EXTENSIONS, (GLuint)index);
  if (s) cb(s, strlen((const char *)s));
}

double host_gl_get_error(int32_t id) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  return glGetError();
}

void host_gl_read_pixels(int32_t id, double x, double y, double w, double h, uint8_t *out, size_t n) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  GLint prev_read = 0, prev_draw = 0, prev_align = 4;
  glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &prev_read);
  glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &prev_draw);
  glGetIntegerv(GL_PACK_ALIGNMENT, &prev_align);
  // Reading the default framebuffer reads what the page has drawn so far, so the multisampled
  // buffer behind it is resolved first.
  if (g->samples && (GLuint)prev_read == g->msaa_fbo) {
    glBindFramebuffer(GL_READ_FRAMEBUFFER, g->msaa_fbo);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, g->fbo);
    glBlitFramebuffer(0, 0, (GLsizei)g->w, (GLsizei)g->h, 0, 0, (GLsizei)g->w, (GLsizei)g->h,
                      GL_COLOR_BUFFER_BIT, GL_NEAREST);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, g->fbo);
  }
  glPixelStorei(GL_PACK_ALIGNMENT, 1);
  glReadPixels((GLint)x, (GLint)y, (GLsizei)w, (GLsizei)h, GL_RGBA, GL_UNSIGNED_BYTE, out);
  glBindFramebuffer(GL_READ_FRAMEBUFFER, (GLuint)prev_read);
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, (GLuint)prev_draw);
  glPixelStorei(GL_PACK_ALIGNMENT, prev_align);
}

static void gl_resize_canvas(int32_t id, double w, double h) {
  Canvas *c = canvas_at(id);
  if (c && c->gl) host_gl_attach(id, w, h, c->gl->depth_bits, c->gl->stencil_bits, c->gl->samples);
}

// Gradients
//
// A gradient is a stop list: `<colour>,<position>` pairs joined by ";", positions 0..1 along the
// gradient line. The colour is packed 0xRRGGBBAA like every other host colour.

// Parses a stop list into four components a stop (straight sRGB and alpha) and each stop's place
// along the gradient. Returns how many stops it read.
static int parse_stops(const char *s, double *comps, double *locs) {
  if (!s) return 0;
  int n = 0;
  const char *p = s;
  while (*p && n < MAX_STOPS) {
    char *end;
    unsigned long long c = strtoull(p, &end, 10);
    if (end == p) break;
    p = end;
    if (*p == ',') p++;
    double loc = strtod(p, &end);
    if (end == p) break;
    p = end;
    comps[n * 4 + 0] = ((c >> 24) & 255) / 255.0;
    comps[n * 4 + 1] = ((c >> 16) & 255) / 255.0;
    comps[n * 4 + 2] = ((c >> 8) & 255) / 255.0;
    comps[n * 4 + 3] = (c & 255) / 255.0;
    locs[n] = loc;
    n++;
    if (*p == ';') p++;
    else break;
  }
  return n;
}

static CGGradientRef gradient_from(const char *s) {
  // The stop lists can be long (a repeating pattern is tiled out to MAX_STOPS), so they come off
  // the heap rather than the stack.
  double *comps = malloc(MAX_STOPS * 4 * sizeof(double));
  double *locs = malloc(MAX_STOPS * sizeof(double));
  if (!comps || !locs) {
    free(comps);
    free(locs);
    return NULL;
  }
  int n = parse_stops(s, comps, locs);
  if (n < 2) {
    free(comps);
    free(locs);
    return NULL;
  }
  CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGGradientRef g = CGGradientCreateWithColorComponents(space, comps, locs, (size_t)n);
  CGColorSpaceRelease(space);
  free(comps);
  free(locs);
  return g;
}

// The colour at `t` along a gradient: the end stop's colour past either end of the line, which is
// what drawing with the before and after locations extends, and a straight blend in between.
static void gradient_colour_at(const double *comps, const double *locs, int n, double t, double out[4]) {
  int i = 0;
  while (i + 1 < n && locs[i + 1] <= t) i++;
  int next = i + 1 < n ? i + 1 : i;
  const double *a = comps + i * 4, *b = comps + next * 4;
  double span = locs[next] - locs[i];
  double k = span > 0 && t > locs[i] ? (t - locs[i]) / span : 0;
  if (k > 1) k = 1;
  if (k < 0) k = 0;
  for (int c = 0; c < 4; c++) out[c] = a[c] + (b[c] - a[c]) * k;
}

// An axis-aligned linear gradient is filled one device pixel at a time instead of being handed to
// CGContextDrawLinearGradient. CoreGraphics dithers a gradient according to the extent it is drawn
// over, so one ramp drawn as two differently sized tiles comes out a channel value apart from
// pixel to pixel; a band of solid colour makes a pixel's colour depend on its place along the ramp
// alone, so a gradient tiled two ways agrees with itself. Returns 0 for a line that runs
// diagonally, which still goes to CoreGraphics.
static int fill_linear_bands(CGContextRef ctx, const char *s, double x0, double y0, double x1, double y1) {
  int vertical = fabs(x1 - x0) < 1e-9, horizontal = fabs(y1 - y0) < 1e-9;
  if (vertical == horizontal) return 0;
  // The clip and a fill are both in user space; this transform says which device pixels they cover.
  // CGContextGetCTM is not it: that one also carries the base transform the context was made with.
  CGAffineTransform u = CGContextGetUserSpaceToDeviceSpaceTransform(ctx);
  // A turned view maps a device row to a slanted line, so only an unturned one may use bands.
  if (u.b != 0 || u.c != 0 || u.a == 0 || u.d == 0) return 0;
  double *comps = malloc(MAX_STOPS * 4 * sizeof(double));
  double *locs = malloc(MAX_STOPS * sizeof(double));
  if (!comps || !locs) {
    free(comps);
    free(locs);
    return 0;
  }
  int n = parse_stops(s, comps, locs);
  if (n < 2) {
    free(comps);
    free(locs);
    return 0;
  }
  CGRect cb = CGContextGetClipBoundingBox(ctx);
  double dx0 = cb.origin.x * u.a + u.tx, dx1 = (cb.origin.x + cb.size.width) * u.a + u.tx;
  double dy0 = cb.origin.y * u.d + u.ty, dy1 = (cb.origin.y + cb.size.height) * u.d + u.ty;
  if (dx1 < dx0) { double t = dx0; dx0 = dx1; dx1 = t; }
  if (dy1 < dy0) { double t = dy0; dy0 = dy1; dy1 = t; }
  double ux0 = (dx0 - u.tx) / u.a, ux1 = (dx1 - u.tx) / u.a;
  double uy0 = (dy0 - u.ty) / u.d, uy1 = (dy1 - u.ty) / u.d;
  double col[4];
  if (vertical) {
    for (double dy = floor(dy0); dy < dy1; dy += 1) {
      double a = (dy - u.ty) / u.d, b = (dy + 1 - u.ty) / u.d;
      double yc = (dy + 0.5 - u.ty) / u.d;
      gradient_colour_at(comps, locs, n, (yc - y0) / (y1 - y0), col);
      CGContextSetRGBFillColor(ctx, col[0], col[1], col[2], col[3]);
      CGContextFillRect(ctx, CGRectMake(ux0, fmin(a, b), ux1 - ux0, fabs(b - a)));
    }
  } else {
    for (double dx = floor(dx0); dx < dx1; dx += 1) {
      double a = (dx - u.tx) / u.a, b = (dx + 1 - u.tx) / u.a;
      double xc = (dx + 0.5 - u.tx) / u.a;
      gradient_colour_at(comps, locs, n, (xc - x0) / (x1 - x0), col);
      CGContextSetRGBFillColor(ctx, col[0], col[1], col[2], col[3]);
      CGContextFillRect(ctx, CGRectMake(fmin(a, b), uy0, fabs(b - a), uy1 - uy0));
    }
  }
  free(comps);
  free(locs);
  return 1;
}

// A diagonal linear gradient can't be filled in bands, and CoreGraphics dithers it by the extent it
// draws over (see fill_linear_bands). It is therefore rasterized one device pixel at a time here,
// and the result cached by the tile's stops and device size: a gradient's colour at a pixel depends
// only on the stops and the pixel's place in the tile, so every tile of that size can share one
// image and a ramp drawn as differently clipped pieces comes out the same either way.
typedef struct {
  char *stops;
  int w, h;
  double rx0, ry0, vx, vy;
  CGImageRef img;
} GradientTile;

// Each entry holds a tile's device pixels, so the cache is small and the tiles it takes are capped
// (a full-window gradient falls back to CoreGraphics rather than pinning tens of megabytes).
#define GRADIENT_TILES 8
static GradientTile gradient_tiles[GRADIENT_TILES];
static int gradient_tiles_next = 0;

/** Frees a tile bitmap once the image made from it is released. */
static void free_buffer(void *info, const void *data, size_t size) {
  (void)info;
  (void)size;
  free((void *)data);
}

static void gradient_tile_store(GradientTile *t, const char *stops, int w, int h,
    double rx0, double ry0, double vx, double vy, CGImageRef img) {
  if (t->img) CGImageRelease(t->img);
  free(t->stops);
  size_t n = strlen(stops) + 1;
  t->stops = malloc(n);
  if (t->stops) memcpy(t->stops, stops, n);
  t->w = w;
  t->h = h;
  t->rx0 = rx0;
  t->ry0 = ry0;
  t->vx = vx;
  t->vy = vy;
  t->img = img;
}

/** The raster of one gradient tile, sized `w` x `h` device pixels. */
static CGImageRef gradient_tile(const char *stops, int w, int h,
    double rx0, double ry0, double vx, double vy) {
  for (int k = 0; k < GRADIENT_TILES; k++) {
    GradientTile *t = &gradient_tiles[k];
    if (t->img && t->w == w && t->h == h && t->rx0 == rx0 && t->ry0 == ry0
        && t->vx == vx && t->vy == vy && t->stops && strcmp(t->stops, stops) == 0) {
      return t->img;
    }
  }
  double *comps = malloc(MAX_STOPS * 4 * sizeof(double));
  double *locs = malloc(MAX_STOPS * sizeof(double));
  uint8_t *buf = malloc((size_t)w * (size_t)h * 4);
  if (!comps || !locs || !buf) {
    free(comps);
    free(locs);
    free(buf);
    return NULL;
  }
  int n = parse_stops(stops, comps, locs);
  double len2 = vx * vx + vy * vy;
  if (n < 2 || !(len2 > 0)) {
    free(comps);
    free(locs);
    free(buf);
    return NULL;
  }
  double col[4];
  for (int j = 0; j < h; j++) {
    for (int i = 0; i < w; i++) {
      double t = (((i + 0.5) - rx0) * vx + ((j + 0.5) - ry0) * vy) / len2;
      gradient_colour_at(comps, locs, n, t, col);
      // Premultiplied, like the CGGradient the stops are given to.
      size_t o = ((size_t)j * (size_t)w + (size_t)i) * 4;
      buf[o + 0] = (uint8_t)lround(col[0] * col[3] * 255);
      buf[o + 1] = (uint8_t)lround(col[1] * col[3] * 255);
      buf[o + 2] = (uint8_t)lround(col[2] * col[3] * 255);
      buf[o + 3] = (uint8_t)lround(col[3] * 255);
    }
  }
  free(comps);
  free(locs);
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGDataProviderRef prov = CGDataProviderCreateWithData(NULL, buf, (size_t)w * (size_t)h * 4, free_buffer);
  CGImageRef img = prov
    ? CGImageCreate(w, h, 8, 32, (size_t)w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast, prov,
        NULL, false, kCGRenderingIntentDefault)
    : NULL;
  // The provider owns the bitmap from here: releasing the image (or the provider, when no image was
  // made) frees it, so only a failed provider creation frees it by hand.
  if (prov) CGDataProviderRelease(prov);
  else free(buf);
  CGColorSpaceRelease(cs);
  if (!img) return NULL;
  GradientTile *t = &gradient_tiles[gradient_tiles_next];
  gradient_tiles_next = (gradient_tiles_next + 1) % GRADIENT_TILES;
  gradient_tile_store(t, stops, w, h, rx0, ry0, vx, vy, img);
  return img;
}

/**
 * Paints a linear gradient from a raster of its tile, so a ramp drawn as differently clipped pieces
 * agrees pixel for pixel. Returns 0 for a turned or scaled-out-of-range tile, which goes to
 * CoreGraphics.
 */
static int fill_linear_tile(CGContextRef ctx, const char *stops, double x, double y, double w, double h,
    double x0, double y0, double x1, double y1, int transformed) {
  // A transform can turn the tile (a diagonal ramp would no longer be diagonal) or snap it to a
  // grid of its own; those tiles go to CoreGraphics.
  CGAffineTransform u = CGContextGetUserSpaceToDeviceSpaceTransform(ctx);
  if (transformed || u.b != 0 || u.c != 0 || !(u.a > 0) || !(u.d > 0)) return 0;
  CGRect r = snapped_rect(x, y, w, h);
  if (!(r.size.width > 0) || !(r.size.height > 0)) return 0;
  int tw = (int)llround(r.size.width * u.a), th = (int)llround(r.size.height * u.d);
  if (tw <= 0 || th <= 0 || (double)tw * (double)th > 2e6) return 0;
  // Quantized to a thousandth of a device pixel: the same gradient at two different spots must
  // produce the same raster, so it can't depend on the rounding of subtracting their positions.
  double rx0 = round((x0 - r.origin.x) * u.a * 1000) / 1000;
  double ry0 = round((y0 - r.origin.y) * u.d * 1000) / 1000;
  double vx = round((x1 - x0) * u.a * 1000) / 1000, vy = round((y1 - y0) * u.d * 1000) / 1000;
  CGImageRef img = gradient_tile(stops, tw, th, rx0, ry0, vx, vy);
  if (!img) return 0;
  CGContextSaveGState(ctx);
  CGContextSetInterpolationQuality(ctx, kCGInterpolationNone);
  // The user space is y down, and CGContextDrawImage draws in a y up space: flip locally so the
  // image's top row lands at the top of the tile, as a drawn image's does.
  CGContextTranslateCTM(ctx, r.origin.x, r.origin.y + r.size.height);
  CGContextScaleCTM(ctx, 1, -1);
  CGContextDrawImage(ctx, CGRectMake(0, 0, r.size.width, r.size.height), img);
  CGContextRestoreGState(ctx);
  return 1;
}

// Whether every stop of a stop list is the same colour, which the list's first field then holds: a
// gradient that never changes colour is that colour everywhere.
static int gradient_flat(const char *s, unsigned long long *colour) {
  if (!s) return 0;
  const char *p = s;
  unsigned long long first = 0;
  int n = 0;
  while (*p) {
    char *end;
    unsigned long long c = strtoull(p, &end, 10);
    if (end == p) return 0;
    p = end;
    if (*p == ',') p++;
    double loc = strtod(p, &end);
    if (end == p) return 0;
    (void)loc;
    p = end;
    if (n == 0) first = c;
    else if (c != first) return 0;
    n++;
    if (*p == ';') p++;
    else if (*p) return 0;
  }
  if (n < 2) return 0;
  *colour = first;
  return 1;
}

static void copy_stops(Cmd *c, const uint8_t *stops, size_t n) {
  c->text = malloc(n + 1);
  memcpy(c->text, stops, n);
  c->text[n] = 0;
  c->len = n;
}

void host_gradient_linear(double x, double y, double w, double h,
    double x0, double y0, double x1, double y1, const uint8_t *stops, size_t n, double alpha) {
  Cmd *c = push_cmd();
  c->kind = CMD_GRADIENT_LINEAR;
  c->x = x; c->y = y; c->w = w; c->h = h;
  c->p0 = x0; c->p1 = y0; c->p2 = x1; c->p3 = y1;
  c->size = alpha;
  copy_stops(c, stops, n);
}

void host_gradient_radial(double x, double y, double w, double h,
    double cx, double cy, double rx, double ry, const uint8_t *stops, size_t n, double alpha) {
  Cmd *c = push_cmd();
  c->kind = CMD_GRADIENT_RADIAL;
  c->x = x; c->y = y; c->w = w; c->h = h;
  c->p0 = cx; c->p1 = cy; c->p2 = rx; c->p3 = ry;
  c->size = alpha;
  copy_stops(c, stops, n);
}

void host_gradient_conic(double x, double y, double w, double h,
    double cx, double cy, double angle, const uint8_t *stops, size_t n, double alpha) {
  Cmd *c = push_cmd();
  c->kind = CMD_GRADIENT_CONIC;
  c->x = x; c->y = y; c->w = w; c->h = h;
  c->p0 = cx; c->p1 = cy; c->p2 = angle;
  c->size = alpha;
  copy_stops(c, stops, n);
}

void host_text(const uint8_t *s, size_t n, double x, double y, double line_height, double size, double weight,
               uint32_t color, double letter, double word, uint32_t emphasis, uint32_t emphasis_color) {
  Cmd *c = push_cmd();
  c->kind = CMD_TEXT;
  c->x = x; c->y = y; c->line_height = line_height; c->size = size; c->weight = weight; c->color = color;
  c->letter = letter; c->word = word;
  c->emphasis = emphasis; c->emphasis_color = emphasis_color;
  c->text = malloc(n + 1);
  memcpy(c->text, s, n);
  c->text[n] = 0;
  c->len = n;
}

// A text run drawn with a shadow of itself: the shadow takes `shadow_color`, offset by (dx, dy)
// and blurred by `blur`; the glyphs themselves are drawn in `color`.
void host_text_shadow(const uint8_t *s, size_t n, double x, double y, double line_height, double size, double weight,
                      uint32_t color, uint32_t shadow_color, double letter, double word,
                      double dx, double dy, double blur, uint32_t emphasis, uint32_t emphasis_color) {
  Cmd *c = push_cmd();
  c->kind = CMD_TEXT_SHADOW;
  c->x = x; c->y = y; c->line_height = line_height; c->size = size; c->weight = weight;
  c->color = color; c->shadow_color = shadow_color;
  c->letter = letter; c->word = word;
  c->dx = dx; c->dy = dy; c->blur = blur;
  c->emphasis = emphasis; c->emphasis_color = emphasis_color;
  c->text = malloc(n + 1);
  memcpy(c->text, s, n);
  c->text[n] = 0;
  c->len = n;
}

static void set_fill(CGContextRef ctx, uint32_t c) {
  CGContextSetRGBFillColor(ctx, ((c >> 24) & 255) / 255.0, ((c >> 16) & 255) / 255.0, ((c >> 8) & 255) / 255.0, (c & 255) / 255.0);
}

static void set_stroke(CGContextRef ctx, uint32_t c) {
  CGContextSetRGBStrokeColor(ctx, ((c >> 24) & 255) / 255.0, ((c >> 16) & 255) / 255.0, ((c >> 8) & 255) / 255.0, (c & 255) / 255.0);
}

// Sets the context's shadow. A shadow's offset and blur are measured in base space rather than
// the display list's user space, so they take the device scale; and base space has y up, so the
// vertical offset is negated.
static void set_shadow(CGContextRef ctx, uint32_t c, double dx, double dy, double blur) {
  static CGColorSpaceRef cs = NULL;
  if (!cs) cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGFloat comps[4] = {
    ((c >> 24) & 255) / 255.0, ((c >> 16) & 255) / 255.0, ((c >> 8) & 255) / 255.0, (c & 255) / 255.0,
  };
  CGColorRef col = CGColorCreate(cs, comps);
  CGAffineTransform m = CGContextGetCTM(ctx);
  double scale = sqrt(fabs(m.a * m.d - m.b * m.c));
  CGContextSetShadowWithColor(ctx, CGSizeMake(dx * scale, -dy * scale), blur * scale, col);
  CGColorRelease(col);
}

// Opaque axis-aligned rectangles are snapped to device pixels, as browsers do: a background
// whose edge falls mid-pixel is drawn to the pixel boundary instead of a soft antialiased edge.
static CGRect snapped_rect(double x, double y, double w, double h) {
  double x0 = round(x), y0 = round(y), x1 = round(x + w), y1 = round(y + h);
  return CGRectMake(x0, y0, x1 - x0, y1 - y0);
}

/** Does every corner of this shape have no radius? */
static int square_radii(const double *r) {
  for (int k = 0; k < 8; k++) if (r[k] != 0) return 0;
  return 1;
}

/**
 * How much of the box's edge a corner covers: twice the smaller share of the width and the height
 * its radii take up. A radius at least half the box in both directions covers the edge once over,
 * which is what makes a `border-radius: 50%` box stay a circle when its shadow spreads.
 */
static double shadow_coverage(double rw, double rh, double w, double h) {
  double a = 2 * rw / w, b = 2 * rh / h;
  // A side with no width leaves 0 / 0 for a square corner, which covers none of it.
  if (isnan(a) || isnan(b)) return 0;
  return a < b ? a : b;
}

/**
 * The corner radius a shadow spreads to, for one axis (CSS Backgrounds 3, the outset-adjusted
 * border radius): the radius plus the spread, except that a radius smaller than the spread is
 * damped by how much of the edge the corner covers, so that a small round corner does not become
 * disproportionately round and a sharp one stays sharp.
 */
static double spread_radius(double r, double spread, double coverage) {
  if (!(r > 0)) return 0;
  if (r > spread || coverage > 1) return r + spread;
  double q = 1 - r / spread;
  return r + spread * (1 - q * q * q * (1 - coverage * coverage * coverage));
}

/**
 * The corner radius of the hole inside an inset shadow's padding box, where the spread works the
 * other way: a positive spread shrinks the corner (flooring at zero) and a negative one grows it,
 * damped like an outer shadow's. A square corner stays square either way.
 */
static double inset_radius(double r, double spread) {
  if (!(r > 0)) return 0;
  double d = -spread;
  if (!(d > 0)) {
    double v = r + d;
    return v > 0 ? v : 0;
  }
  return spread_radius(r, d, 0);
}

// The rectangle to fill in the current user space: an untransformed or straight-scaled box is
// snapped there, where user space and device space agree on what a pixel is. A transform that
// keeps axis-aligned rectangles axis-aligned (a diagonal or anti-diagonal linear part: translated,
// scaled, turned by a quarter or reflected) is snapped in device space instead, which is what a
// browser's pixel snapping of a transformed layer amounts to; any other transform is left alone.
static CGRect snapped_for_ctm(CGContextRef ctx, double x, double y, double w, double h, int transformed) {
  // Only a transform changes what snapping to device pixels means: without one the CTM is just
  // the backing scale, where the established user-space snapping is the one a browser does.
  if (!transformed) return snapped_rect(x, y, w, h);
  CGAffineTransform t = CGContextGetCTM(ctx);
  int diagonal = t.b == 0 && t.c == 0 && t.a != 0 && t.d != 0;
  int anti = t.a == 0 && t.d == 0 && t.b != 0 && t.c != 0;
  if (!diagonal && !anti) return snapped_rect(x, y, w, h);
  double px[2] = {x, x + w}, py[2] = {y, y + h};
  double dx[4], dy[4];
  for (int i = 0; i < 4; i++) {
    dx[i] = t.a * px[i & 1] + t.c * py[i >> 1] + t.tx;
    dy[i] = t.b * px[i & 1] + t.d * py[i >> 1] + t.ty;
  }
  double x0 = fmin(fmin(dx[0], dx[1]), fmin(dx[2], dx[3]));
  double x1 = fmax(fmax(dx[0], dx[1]), fmax(dx[2], dx[3]));
  double y0 = fmin(fmin(dy[0], dy[1]), fmin(dy[2], dy[3]));
  double y1 = fmax(fmax(dy[0], dy[1]), fmax(dy[2], dy[3]));
  x0 = round(x0); y0 = round(y0); x1 = round(x1); y1 = round(y1);
  // Back into user space: the image of the snapped device rect is still axis-aligned.
  double den = t.a * t.d - t.b * t.c;
  double ux[4], uy[4];
  for (int i = 0; i < 4; i++) {
    double X = (i & 1) ? x1 : x0, Y = (i >> 1) ? y1 : y0;
    double rx = X - t.tx, ry = Y - t.ty;
    ux[i] = (t.d * rx - t.c * ry) / den;
    uy[i] = (t.a * ry - t.b * rx) / den;
  }
  double X0 = fmin(fmin(ux[0], ux[1]), fmin(ux[2], ux[3]));
  double X1 = fmax(fmax(ux[0], ux[1]), fmax(ux[2], ux[3]));
  double Y0 = fmin(fmin(uy[0], uy[1]), fmin(uy[2], uy[3]));
  double Y1 = fmax(fmax(uy[0], uy[1]), fmax(uy[2], uy[3]));
  return CGRectMake(X0, Y0, X1 - X0, Y1 - Y0);
}

// One vertex of a polygon snapped to the device grid the way snapped_for_ctm snaps a rect: a
// border side's corners sit on the same pixel grid as the box they belong to.
static void snap_vertex(CGContextRef ctx, double *px, double *py, int transformed) {
  if (!transformed) {
    *px = round(*px);
    *py = round(*py);
    return;
  }
  CGAffineTransform t = CGContextGetCTM(ctx);
  int diagonal = t.b == 0 && t.c == 0 && t.a != 0 && t.d != 0;
  int anti = t.a == 0 && t.d == 0 && t.b != 0 && t.c != 0;
  if (!diagonal && !anti) return;
  double X = round(t.a * *px + t.c * *py + t.tx);
  double Y = round(t.b * *px + t.d * *py + t.ty);
  double rx = X - t.tx, ry = Y - t.ty;
  double den = t.a * t.d - t.b * t.c;
  *px = (t.d * rx - t.c * ry) / den;
  *py = (t.a * ry - t.b * rx) / den;
}

// The next character of a point list that starts a number, stopping at a subpath break.
static const char *to_num(const char *q) {
  while (*q && *q != ';' && (*q < '0' || *q > '9') && *q != '-' && *q != '+' && *q != '.') q++;
  return q;
}

// A path from "x,y x,y x,y" points, one subpath per ';' (a border's sides that share a colour).
// The vertices are snapped like a fill's edges, so a polygon on the pixel grid has hard edges.
static CGPathRef poly_path(CGContextRef ctx, const char *s, int transformed, int snap) {
  CGMutablePathRef p = CGPathCreateMutable();
  const char *q = s;
  int fresh = 1;
  while (*q) {
    q = to_num(q);
    if (!*q) break;
    if (*q == ';') {
      q++;
      if (!fresh) {
        CGPathCloseSubpath(p);
        fresh = 1;
      }
      continue;
    }
    char *end;
    double x = strtod(q, &end);
    if (end == q) break;
    q = to_num(end);
    if (!*q || *q == ';') break; // a point needs both of its coordinates
    double y = strtod(q, &end);
    if (end == q) break;
    q = end;
    if (snap) snap_vertex(ctx, &x, &y, transformed);
    if (fresh) {
      CGPathMoveToPoint(p, NULL, x, y);
      fresh = 0;
    } else {
      CGPathAddLineToPoint(p, NULL, x, y);
    }
  }
  if (!fresh) CGPathCloseSubpath(p);
  return p;
}

// Fill a rectangle that a spread may have shrunk to nothing or less: CoreGraphics would standardise
// a negative width or height, filling the box mirrored across the edge instead of nothing.
static void fill_rect_clamped(CGContextRef ctx, CGRect r) {
  if (r.size.width <= 0 || r.size.height <= 0) return;
  CGContextFillRect(ctx, r);
}

static CGPathRef rounded(double x, double y, double w, double h, double r) {
  if (w < 0) w = 0;
  if (h < 0) h = 0;
  double max = (w < h ? w : h) / 2;
  if (r > max) r = max;
  if (r < 0) r = 0;
  return CGPathCreateWithRoundedRect(CGRectMake(x, y, w, h), r, r, NULL);
}

// A rounded rect with a radius per corner and per axis, as a cubic path. `r` holds the radii in
// Cmd's order.
static CGPathRef round_path(double x, double y, double w, double h, const double *r) {
  if (w < 0) w = 0;
  if (h < 0) h = 0;
  double tlx = r[0], tly = r[1], trx = r[2], trY = r[3], brx = r[4], bry = r[5], blx = r[6], bly = r[7];
  if (tlx < 0) tlx = 0; if (tly < 0) tly = 0;
  if (trx < 0) trx = 0; if (trY < 0) trY = 0;
  if (brx < 0) brx = 0; if (bry < 0) bry = 0;
  if (blx < 0) blx = 0; if (bly < 0) bly = 0;
  if (tlx > w) tlx = w; if (trx > w) trx = w; if (brx > w) brx = w; if (blx > w) blx = w;
  if (tly > h) tly = h; if (trY > h) trY = h; if (bry > h) bry = h; if (bly > h) bly = h;
  // The circle-to-cubic magic constant: a quarter arc's control points sit this far along.
  static const double k = 0.5522847498307936;
  CGMutablePathRef p = CGPathCreateMutable();
  CGPathMoveToPoint(p, NULL, x + tlx, y);
  CGPathAddLineToPoint(p, NULL, x + w - trx, y);
  if (trx > 0 || trY > 0) {
    CGPathAddCurveToPoint(p, NULL, x + w - trx + k * trx, y, x + w, y + trY - k * trY, x + w, y + trY);
  }
  CGPathAddLineToPoint(p, NULL, x + w, y + h - bry);
  if (brx > 0 || bry > 0) {
    CGPathAddCurveToPoint(p, NULL, x + w, y + h - bry + k * bry, x + w - brx + k * brx, y + h, x + w - brx, y + h);
  }
  CGPathAddLineToPoint(p, NULL, x + blx, y + h);
  if (blx > 0 || bly > 0) {
    CGPathAddCurveToPoint(p, NULL, x + blx - k * blx, y + h, x, y + h - bly + k * bly, x, y + h - bly);
  }
  CGPathAddLineToPoint(p, NULL, x, y + tly);
  if (tlx > 0 || tly > 0) {
    CGPathAddCurveToPoint(p, NULL, x, y + tly - k * tly, x + tlx - k * tlx, y, x + tlx, y);
  }
  CGPathCloseSubpath(p);
  return p;
}

// The same path shrunk by `b` on every side, with each radius reduced by `b` along its axis.
static CGPathRef inner_round_path(double x, double y, double w, double h, const double *r, double b) {
  double in[8];
  for (int i = 0; i < 8; i++) {
    double v = r[i] - b;
    in[i] = v > 0 ? v : 0;
  }
  return round_path(x + b, y + b, w - 2 * b, h - 2 * b, in);
}

// Where a replay stands: the states it saved for clips and transforms, and how many of them hold
// a transform (only a fill inside one is snapped in device space).
typedef struct {
  int saved[1024];
  int depth;
  int transforms;
} ReplayState;

static size_t replay_effect(CGContextRef ctx, size_t i);
static size_t replay_mask(CGContextRef ctx, size_t i);
static size_t replay_perspective(CGContextRef ctx, size_t i);
static size_t replay_range(CGContextRef ctx, size_t i, ReplayState *st);
static void draw_layer_image(CGContextRef ctx, int32_t id);

/** Whether a layer paints another layer inside it: such a layer keeps replaying, so the inner
 *  one's own cached raster is not frozen into it. */
static int layer_paints_layer(int32_t id) {
  CmdList *list = &g_layers[id].list;
  for (size_t i = 0; i < list->count; i++) {
    if (list->cmds[i].kind == CMD_LAYER_REF) return 1;
  }
  return 0;
}

/** Rasters one layer's commands in page space at `scale`, cropped to its ink, and caches it. */
static void raster_layer_image(int32_t id, double scale) {
  LayerImage *li = &g_layer_image[id];
  int pw = (int)(g_replay_w * scale), ph = (int)(g_replay_h * scale);
  if (pw <= 0 || ph <= 0) return;
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef bctx = CGBitmapContextCreate(NULL, (size_t)pw, (size_t)ph, 8, 0, cs,
                                            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(cs);
  if (bctx == NULL) return;
  // The flat path's own space: page points, y down, at the device scale.
  CGContextTranslateCTM(bctx, 0, ph);
  CGContextScaleCTM(bctx, scale, -scale);
  CGContextSetTextMatrix(bctx, CGAffineTransformMakeScale(1, -1));
  CmdList *saved = g_list;
  g_list = &g_layers[id].list;
  ReplayState st;
  st.depth = 0;
  st.transforms = 0;
  replay_range(bctx, 0, &st);
  g_list = saved;
  unsigned char *data = CGBitmapContextGetData(bctx);
  size_t stride = CGBitmapContextGetBytesPerRow(bctx);
  int minx = pw, miny = ph, maxx = -1, maxy = -1;
  if (data != NULL) {
    for (int y = 0; y < ph; y++) {
      const unsigned char *row = data + (size_t)y * stride;
      for (int x = 0; x < pw; x++) {
        if (row[x * 4 + 3] == 0) continue;
        if (x < minx) minx = x;
        if (x > maxx) maxx = x;
        if (y < miny) miny = y;
        if (y > maxy) maxy = y;
      }
    }
  }
  if (maxx >= minx && maxy >= miny) {
    CGImageRef full = CGBitmapContextCreateImage(bctx);
    if (full != NULL) {
      li->image = CGImageCreateWithImageInRect(full, CGRectMake(minx, miny, maxx - minx + 1, maxy - miny + 1));
      li->x = minx;
      li->y = miny;
      li->w = maxx - minx + 1;
      li->h = maxy - miny + 1;
      CGImageRelease(full);
    }
  }
  CGContextRelease(bctx);
}

/** Draws a layer from its cached raster where the ref sits, under the page's current CTM. */
static void draw_layer_image(CGContextRef ctx, int32_t id) {
  if (id < 0 || id >= g_layer_count || id >= MAX_LAYERS) return;
  CGAffineTransform ctm = CGContextGetCTM(ctx);
  double scale = fabs(ctm.a) > 0 ? fabs(ctm.a) : 1.0;
  LayerImage *li = &g_layer_image[id];
  if (li->image == NULL || li->scale != scale) {
    if (li->image != NULL) CGImageRelease(li->image);
    li->image = NULL;
    li->scale = scale;
    raster_layer_image(id, scale);
  }
  if (li->image == NULL) return;
  double x = (double)li->x / scale, y = (double)li->y / scale;
  double w = (double)li->w / scale, h = (double)li->h / scale;
  // A y-down context draws an image upside down unless it is flipped about its own rect.
  CGContextSaveGState(ctx);
  CGContextTranslateCTM(ctx, 0, 2 * y + h);
  CGContextScaleCTM(ctx, 1, -1);
  CGContextSetTextMatrix(ctx, CGAffineTransformMakeScale(1, -1));
  CGContextDrawImage(ctx, CGRectMake(x, y, w, h), li->image);
  CGContextRestoreGState(ctx);
}

/**
 * Replays the display list from `i` into `ctx`, until the command that closes the layer it was
 * called for, or the end of the list. Returns the index of the command that ended it.
 */
static size_t replay_range(CGContextRef ctx, size_t i, ReplayState *st) {
  for (; i < g_list->count && i < g_replay_limit; i++) {
    Cmd *c = &g_list->cmds[i];
    if (c->kind == CMD_EFFECT_POP || c->kind == CMD_MASK_SPLIT || c->kind == CMD_MASK_POP ||
      c->kind == CMD_PERSPECTIVE_POP) return i;
    if (c->kind == CMD_EFFECT_PUSH) {
      i = replay_effect(ctx, i);
      continue;
    }
    if (c->kind == CMD_PERSPECTIVE_PUSH) {
      i = replay_perspective(ctx, i);
      continue;
    }
    if (c->kind == CMD_LAYER_REF) {
      if (g_layer_images_on && !layer_paints_layer(c->layer)) {
        draw_layer_image(ctx, c->layer);
        continue;
      }
      CmdList *saved = g_list;
      size_t saved_limit = g_replay_limit;
      if (c->layer >= 0 && c->layer < g_layer_count) {
        g_list = &g_layers[c->layer].list;
        // The limit is an index into the list being replayed, so a layer reached from a chunk
        // paints its own commands to their end rather than to the end of the chunk's range.
        g_replay_limit = (size_t)-1;
        replay_range(ctx, 0, st);
      }
      g_replay_limit = saved_limit;
      g_list = saved;
      continue;
    }
    if (c->kind == CMD_MASK_PUSH) {
      i = replay_mask(ctx, i);
      continue;
    }
    if (c->kind == CMD_FILL) {
      set_fill(ctx, c->color);
      if (c->radius > 0) {
        // A rounded fill snaps like a square one: a border's dot or a scrollbar thumb should sit
        // on the same pixel grid as the box it belongs to, not smear across a half pixel when the
        // box it hangs off ends at a fraction.
        CGRect r = snapped_for_ctm(ctx, c->x, c->y, c->w, c->h, st->transforms > 0);
        CGPathRef p = rounded(r.origin.x, r.origin.y, r.size.width, r.size.height, c->radius);
        CGContextAddPath(ctx, p);
        CGContextFillPath(ctx);
        CGPathRelease(p);
      } else {
        CGContextFillRect(ctx, snapped_for_ctm(ctx, c->x, c->y, c->w, c->h, st->transforms > 0));
      }
    } else if (c->kind == CMD_FILL_ROUND) {
      set_fill(ctx, c->color);
      CGPathRef p = round_path(c->x, c->y, c->w, c->h, c->r);
      CGContextAddPath(ctx, p);
      CGContextFillPath(ctx);
      CGPathRelease(p);
    } else if (c->kind == CMD_RING_ROUND) {
      set_fill(ctx, c->color);
      CGPathRef outer = round_path(c->x, c->y, c->w, c->h, c->r);
      CGPathRef inner = inner_round_path(c->x, c->y, c->w, c->h, c->r, c->line_width);
      CGContextAddPath(ctx, outer);
      CGContextAddPath(ctx, inner);
      CGContextEOFillPath(ctx);
      CGPathRelease(outer);
      CGPathRelease(inner);
    } else if (c->kind == CMD_SHADOW) {
      // The shadow shape is painted far off to the left with its offset moved to match, so only
      // the shadow itself lands back in place: the shape must cast the shadow without painting
      // over it (which would darken the shadow's own antialiased edge). The shape is filled
      // opaque, because a fill's alpha multiplies into its shadow. A transparency layer then
      // lets the border box be punched back out: an outer shadow is clipped inside it.
      double s = c->line_width;
      double grown[8];
      for (int k = 0; k < 8; k += 2) {
        // Each corner grows independently of the others, its spread damped by how much of the
        // edge it covers; a square corner stays square.
        double cov = shadow_coverage(c->r[k], c->r[k + 1], c->w, c->h);
        grown[k] = spread_radius(c->r[k], s, cov);
        grown[k + 1] = spread_radius(c->r[k + 1], s, cov);
      }
      const double cast = 65536;
      // A shadow with no blur is the shape itself, moved by the offset. Drawing that shape directly
      // keeps its edges on the pixels CSS puts them on; CoreGraphics's own shadow of a sharp shape
      // lands half a device pixel off at scale 1.
      const int hard = !(c->blur > 0);
      // A square shape snaps to the device pixels the box's own fill snaps to, so the shadow's
      // edge meets the box's. A rounded one keeps its path, as every rounded fill does.
      const int square = square_radii(grown);
      CGRect shapeRect = snapped_for_ctm(ctx, c->x - s + (hard ? c->dx : -cast),
        c->y - s + (hard ? c->dy : 0), c->w + 2 * s, c->h + 2 * s, st->transforms > 0);
      CGRect punchRect = snapped_for_ctm(ctx, c->x, c->y, c->w, c->h, st->transforms > 0);
      CGPathRef shape = square ? NULL
        : round_path(c->x - s + (hard ? c->dx : -cast), c->y - s + (hard ? c->dy : 0), c->w + 2 * s, c->h + 2 * s, grown);
      CGPathRef punch = square_radii(c->r) ? NULL : round_path(c->x, c->y, c->w, c->h, c->r);
      CGContextSaveGState(ctx);
      CGContextBeginTransparencyLayer(ctx, NULL);
      if (hard) {
        set_fill(ctx, c->color);
      } else {
        set_shadow(ctx, c->color, c->dx + cast, c->dy, c->blur);
        CGContextSetRGBFillColor(ctx, 0, 0, 0, 1);
      }
      if (shape) {
        CGContextAddPath(ctx, shape);
        CGContextFillPath(ctx);
      } else {
        fill_rect_clamped(ctx, shapeRect);
      }
      CGContextSetShadow(ctx, CGSizeZero, 0);
      CGContextSetBlendMode(ctx, kCGBlendModeClear);
      if (punch) {
        CGContextAddPath(ctx, punch);
        CGContextFillPath(ctx);
      } else {
        fill_rect_clamped(ctx, punchRect);
      }
      CGContextSetBlendMode(ctx, kCGBlendModeNormal);
      CGContextEndTransparencyLayer(ctx);
      CGContextRestoreGState(ctx);
      if (shape) CGPathRelease(shape);
      if (punch) CGPathRelease(punch);
    } else if (c->kind == CMD_SHADOW_INSET) {
      // Tint the whole padding box, then wipe out the blurred, offset inner shape: what is left
      // is the shadow. The inner shape casts that blur from far off to the side, so its own
      // crisp edge never darkens or double-covers its shadow.
      double s = c->line_width;
      double in[8];
      for (int k = 0; k < 8; k++) in[k] = inset_radius(c->r[k], s);
      const double cast = 65536;
      // The shadow lives inside the padding box, whose background is snapped to the pixel grid,
      // so its own edges are snapped the same way: otherwise the half-covered pixel along an edge
      // that falls mid-pixel is antialiased over the background and shows it through.
      const int hard = !(c->blur > 0);
      CGRect boxRect = snapped_for_ctm(ctx, c->x, c->y, c->w, c->h, st->transforms > 0);
      CGRect holeRect = snapped_for_ctm(ctx, c->x + s + (hard ? c->dx : -cast),
        c->y + s + (hard ? c->dy : 0), c->w - 2 * s, c->h - 2 * s, st->transforms > 0);
      CGPathRef box = square_radii(c->r) ? NULL
        : round_path(boxRect.origin.x, boxRect.origin.y, boxRect.size.width, boxRect.size.height, c->r);
      CGPathRef hole = square_radii(in)
        ? NULL
        : round_path(holeRect.origin.x, holeRect.origin.y, holeRect.size.width, holeRect.size.height, in);
      CGContextSaveGState(ctx);
      CGContextBeginTransparencyLayer(ctx, NULL);
      set_fill(ctx, c->color);
      if (box) {
        CGContextAddPath(ctx, box);
        CGContextFillPath(ctx);
      } else {
        fill_rect_clamped(ctx, boxRect);
      }
      CGContextSetBlendMode(ctx, kCGBlendModeDestinationOut);
      if (!hard) set_shadow(ctx, 0xffffffff, c->dx + cast, c->dy, c->blur);
      CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
      if (hole) {
        CGContextAddPath(ctx, hole);
        CGContextFillPath(ctx);
      } else {
        fill_rect_clamped(ctx, holeRect);
      }
      CGContextSetShadow(ctx, CGSizeZero, 0);
      CGContextSetBlendMode(ctx, kCGBlendModeNormal);
      CGContextEndTransparencyLayer(ctx);
      CGContextRestoreGState(ctx);
      if (box) CGPathRelease(box);
      if (hole) CGPathRelease(hole);
    } else if (c->kind == CMD_CLIP_ELLIPSE) {
      CGContextSaveGState(ctx);
      if (st->depth < 1024) st->saved[st->depth++] = 0;
      if (c->p2 > 0 && c->p3 > 0) {
        CGRect r = CGRectMake(c->p0 - c->p2, c->p1 - c->p3, c->p2 * 2, c->p3 * 2);
        CGPathRef p = CGPathCreateWithEllipseInRect(r, NULL);
        CGContextAddPath(ctx, p);
        CGContextClip(ctx);
        CGPathRelease(p);
      } else {
        // A circle or ellipse with no radius clips everything away.
        CGContextClipToRect(ctx, CGRectMake(c->p0, c->p1, 0, 0));
      }
    } else if (c->kind == CMD_CLIP_SHAPE) {
      CGContextSaveGState(ctx);
      if (st->depth < 1024) st->saved[st->depth++] = 0;
      CGPathRef p = poly_path(ctx, c->text, 0, 0);
      CGContextAddPath(ctx, p);
      if (c->p0 != 0) CGContextEOClip(ctx);
      else CGContextClip(ctx);
      CGPathRelease(p);
    } else if (c->kind == CMD_CLIP_ROUND) {
      CGContextSaveGState(ctx);
      if (st->depth < 1024) st->saved[st->depth++] = 0;
      CGPathRef p = round_path(c->x, c->y, c->w, c->h, c->r);
      CGContextAddPath(ctx, p);
      CGContextClip(ctx);
      CGPathRelease(p);
    } else if (c->kind == CMD_RING) {
      // A border with rounded corners: the area between the outer rounded rect and the inner one.
      set_fill(ctx, c->color);
      double b = c->line_width;
      CGPathRef outer = rounded(c->x, c->y, c->w, c->h, c->radius);
      CGPathRef inner = rounded(c->x + b, c->y + b, c->w - 2 * b, c->h - 2 * b, c->radius - b);
      CGContextAddPath(ctx, outer);
      CGContextAddPath(ctx, inner);
      CGContextEOFillPath(ctx);
      CGPathRelease(outer);
      CGPathRelease(inner);
    } else if (c->kind == CMD_LINE) {
      double x0 = c->x, span = c->w, y = c->y, t = c->line_width;
      int style = (int)c->radius;
      double x1 = x0 + span;
      if (span > 0 && t > 0) {
        if (style == 1) {
          // Double: two thirds-thick lines, a third apart.
          double part = t / 3;
          set_fill(ctx, c->color);
          fill_rect_clamped(ctx, snapped_for_ctm(ctx, x0, y, span, part, st->transforms > 0));
          fill_rect_clamped(ctx, snapped_for_ctm(ctx, x0, y + 2 * part, span, part, st->transforms > 0));
        } else if (style == 2) {
          // Dotted: squares as wide as the line is thick, one square apart.
          set_fill(ctx, c->color);
          for (double x = x0; x < x1; x += 2 * t) {
            double w = fmin(t, x1 - x);
            fill_rect_clamped(ctx, snapped_for_ctm(ctx, x, y, w, t, st->transforms > 0));
          }
        } else if (style == 3) {
          // Dashed: three thicknesses on, two off.
          set_fill(ctx, c->color);
          for (double x = x0; x < x1; x += 5 * t) {
            double w = fmin(3 * t, x1 - x);
            fill_rect_clamped(ctx, snapped_for_ctm(ctx, x, y, w, t, st->transforms > 0));
          }
        } else if (style == 4) {
          // Wavy: a sine wave, stroked with the line's own thickness.
          double amp = t, period = fmax(8, 4 * t);
          CGContextSaveGState(ctx);
          set_stroke(ctx, c->color);
          CGContextSetLineWidth(ctx, t);
          CGContextSetLineCap(ctx, kCGLineCapRound);
          CGMutablePathRef p = CGPathCreateMutable();
          for (double x = x0;; x += 1) {
            double xx = x > x1 ? x1 : x;
            double yy = y + t / 2 + amp * sin(2 * M_PI * (xx - x0) / period);
            if (xx == x0) CGPathMoveToPoint(p, NULL, xx, yy);
            else CGPathAddLineToPoint(p, NULL, xx, yy);
            if (xx >= x1) break;
          }
          CGContextAddPath(ctx, p);
          CGContextStrokePath(ctx);
          CGPathRelease(p);
          CGContextRestoreGState(ctx);
        } else {
          set_fill(ctx, c->color);
          fill_rect_clamped(ctx, snapped_for_ctm(ctx, x0, y, span, t, st->transforms > 0));
        }
      }
    } else if (c->kind == CMD_POLY) {
      set_fill(ctx, c->color);
      CGPathRef p = poly_path(ctx, c->text, st->transforms > 0, 1);
      CGContextAddPath(ctx, p);
      CGContextFillPath(ctx);
      CGPathRelease(p);
    } else if (c->kind == CMD_CLIP_POLY) {
      CGContextSaveGState(ctx);
      if (st->depth < 1024) st->saved[st->depth++] = 0;
      CGPathRef p = poly_path(ctx, c->text, st->transforms > 0, 1);
      CGContextAddPath(ctx, p);
      CGContextClip(ctx);
      CGPathRelease(p);
    } else if (c->kind == CMD_CLIP) {
      CGContextSaveGState(ctx);
      if (st->depth < 1024) st->saved[st->depth++] = 0;
      // Clips without a radius are snapped along with the fills they contain: a clip edge that
      // falls mid-pixel would otherwise let the antialiased remainder of a rounded fill through.
      // Inside a transform that keeps the box axis-aligned the snapping is to the device grid,
      // like the fills, so a scaled or quarter-turned background reaches its own edges.
      CGRect clip = c->radius > 0
        ? CGRectMake(c->x, c->y, c->w, c->h)
        : snapped_for_ctm(ctx, c->x, c->y, c->w, c->h, st->transforms > 0);
      CGPathRef p = rounded(clip.origin.x, clip.origin.y, clip.size.width, clip.size.height, c->radius);
      CGContextAddPath(ctx, p);
      CGContextClip(ctx);
      CGPathRelease(p);
    } else if (c->kind == CMD_TRANSFORM) {
      CGContextSaveGState(ctx);
      // A scroll container's translation is not a transform for snapping: its content snaps in
      // the page's own space, exactly where it snapped when the offset was painted into the
      // coordinates. Every other transform keeps the device-space snapping it has.
      int scroll = c->pkind == CMD_PK_SCROLL;
      if (st->depth < 1024) st->saved[st->depth++] = scroll ? 0 : 1;
      if (!scroll) st->transforms++;
      CGContextConcatCTM(ctx, CGAffineTransformMake(c->p0, c->p1, c->p2, c->p3, c->r[0], c->r[1]));
    } else if (c->kind == CMD_UNCLIP) {
      if (st->depth > 0 && st->saved[--st->depth]) st->transforms--;
      CGContextRestoreGState(ctx);
    } else if (c->kind == CMD_IMAGE) {
      CGImageRef img = image_at(c->image);
      CGImageRef part = NULL;
      if (img && c->sw > 0 && c->sh > 0) {
        // The cut is taken in image pixels before the scale, so scaling a thin slice up can't
        // pull in the colour of the slices beside it.
        part = CGImageCreateWithImageInRect(img, CGRectMake(c->sx, c->sy, c->sw, c->sh));
        if (part) img = part;
      }
      if (img) {
        CGContextSaveGState(ctx);
        CGContextSetAlpha(ctx, c->size);
        CGContextSetInterpolationQuality(ctx, c->smooth ? kCGInterpolationMedium : kCGInterpolationNone);
        // The rect is snapped like a background: an image at a fractional position is drawn
        // edge-for-edge with the box around it instead of with soft edges over its neighbours.
        CGRect r = snapped_rect(c->x, c->y, c->w, c->h);
        // The user space is y down, and CGContextDrawImage draws in a y up space: flip locally
        // so the image's top row lands at the top of the rect.
        CGContextTranslateCTM(ctx, r.origin.x, r.origin.y + r.size.height);
        CGContextScaleCTM(ctx, 1, -1);
        CGContextDrawImage(ctx, CGRectMake(0, 0, r.size.width, r.size.height), img);
        CGContextRestoreGState(ctx);
      }
      if (part) CGImageRelease(part);
    } else if (c->kind == CMD_VIDEO) {
      int32_t vi = video_index(c->image);
      if (vi >= 0 && g_video_player[vi] != nil) {
        @autoreleasepool {
          CMTime at = g_video_player[vi].currentTime;
          CVPixelBufferRef pb = [g_video_output[vi] copyPixelBufferForItemTime:at itemTimeForDisplay:NULL];
          if (pb != NULL) {
            if (g_video_context == nil) g_video_context = [CIContext contextWithOptions:nil];
            CIImage *ci = [CIImage imageWithCVPixelBuffer:pb];
            CGImageRef img = [g_video_context createCGImage:ci fromRect:ci.extent];
            if (img != NULL) {
              CGContextSaveGState(ctx);
              CGContextSetAlpha(ctx, c->size);
              CGRect r = snapped_rect(c->x, c->y, c->w, c->h);
              CGContextTranslateCTM(ctx, r.origin.x, r.origin.y + r.size.height);
              CGContextScaleCTM(ctx, 1, -1);
              CGContextDrawImage(ctx, CGRectMake(0, 0, r.size.width, r.size.height), img);
              CGContextRestoreGState(ctx);
              CGImageRelease(img);
            }
            CVPixelBufferRelease(pb);
          }
        }
      }
    } else if (c->kind == CMD_CANVAS) {
      Canvas *cv = canvas_at(c->image);
      if (cv && cv->ctx) {
        // A WebGL canvas that presented into an IOSurface fills its bitmap from it first.
        gl_sync_bitmap(cv);
        // Fills the page queued on the GPU come back into the bitmap the snapshot reads.
        canvas_gpu_sync(cv);
        // The bitmap is snapshotted when the page paints, then cached until the canvas changes.
        if (!cv->image) cv->image = CGBitmapContextCreateImage(cv->ctx);
        // A slice of the bitmap is cut in its own pixels before the scale, as an image's is.
        CGImageRef part = NULL;
        if (cv->image && c->sw > 0 && c->sh > 0) {
          part = CGImageCreateWithImageInRect(cv->image, CGRectMake(c->sx, c->sy, c->sw, c->sh));
        }
        CGImageRef img = part ? part : cv->image;
        if (img) {
          CGContextSaveGState(ctx);
          CGContextSetAlpha(ctx, c->size);
          CGContextSetInterpolationQuality(ctx, c->smooth ? kCGInterpolationHigh : kCGInterpolationNone);
          CGRect r = CGRectMake(c->x, c->y, c->w, c->h);
          CGContextTranslateCTM(ctx, r.origin.x, r.origin.y + r.size.height);
          CGContextScaleCTM(ctx, 1, -1);
          CGContextDrawImage(ctx, CGRectMake(0, 0, r.size.width, r.size.height), img);
          CGContextRestoreGState(ctx);
        }
        if (part) CGImageRelease(part);
      }
    } else if (c->kind == CMD_GRADIENT_CONIC) {
      CGGradientRef g = gradient_from(c->text);
      unsigned long long flat = 0;
      // CGContextDrawConicGradient arrived in macOS 14; earlier systems have no way to draw the
      // turn, so the tile is left as it was.
      if (g && gradient_flat(c->text, &flat)) {
        // A conic ramp is dithered, unlike the other gradients, so one flat colour reads a
        // channel off in every pixel (green 0 0 painted rgb(1,128,1)). Flat is a fill.
        CGContextSaveGState(ctx);
        CGContextSetAlpha(ctx, c->size);
        set_fill(ctx, (uint32_t)flat);
        fill_rect_clamped(ctx, snapped_rect(c->x, c->y, c->w, c->h));
        CGContextRestoreGState(ctx);
      } else if (@available(macOS 14.0, *)) {
        if (g) {
          CGContextSaveGState(ctx);
          CGContextSetAlpha(ctx, c->size);
          CGContextClipToRect(ctx, snapped_rect(c->x, c->y, c->w, c->h));
          CGContextDrawConicGradient(ctx, g, CGPointMake(c->p0, c->p1), c->p2);
          CGContextRestoreGState(ctx);
        }
      }
      if (g) CGGradientRelease(g);
    } else if (c->kind == CMD_GRADIENT_LINEAR || c->kind == CMD_GRADIENT_RADIAL) {
      CGGradientRef g = gradient_from(c->text);
      if (g) {
        CGContextSaveGState(ctx);
        CGContextSetAlpha(ctx, c->size);
        // The tile is snapped like a background image, so repeated tiles meet edge to edge. A
        // tile inside a transform that keeps it axis-aligned snaps to the device grid, as the
        // fills do, so a scaled or quarter-turned background has hard edges rather than a band
        // of half-covered pixels at every side.
        CGContextClipToRect(ctx, snapped_for_ctm(ctx, c->x, c->y, c->w, c->h, st->transforms > 0));
        if (c->kind == CMD_GRADIENT_LINEAR) {
          if (!fill_linear_bands(ctx, c->text, c->p0, c->p1, c->p2, c->p3)
              && !fill_linear_tile(ctx, c->text, c->x, c->y, c->w, c->h, c->p0, c->p1, c->p2, c->p3,
                st->transforms > 0)) {
            CGContextDrawLinearGradient(ctx, g, CGPointMake(c->p0, c->p1), CGPointMake(c->p2, c->p3),
                                        kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
          }
        } else {
          // An ellipse is a circle under a non-uniform scale about the centre.
          CGContextTranslateCTM(ctx, c->p0, c->p1);
          CGContextScaleCTM(ctx, 1, c->p3 / c->p2);
          CGContextDrawRadialGradient(ctx, g, CGPointZero, 0, CGPointZero, c->p2,
                                      kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
        }
        CGContextRestoreGState(ctx);
        CGGradientRelease(g);
      }
    } else if (c->kind == CMD_TEXT) {
      @autoreleasepool {
        NSFont *f = font_for(c->size, c->weight);
        double baseline = text_baseline(f, c->y, c->line_height);
        CTLineRef line = line_for_text(c->text, c->len, c->size, c->weight, c->letter, c->word, NO);
        set_fill(ctx, c->color);
        CGContextSetTextDrawingMode(ctx, kCGTextFill);
        if (font_is_fake_bold(c->size, c->weight)) fake_bold_stroke(ctx, c->size, c->color);
        // A text run is snapped to device pixels too, as browsers do: otherwise a run at a
        // fractional position is drawn with soft edges, unlike the boxes around it. Font
        // smoothing (subpixel LCD antialiasing) is off for the same reason: it spreads a glyph
        // edge over the neighboring row and column even when the run sits on whole pixels.
        // The text matrix comes first: setting the position after the matrix runs the position
        // through it, which is what keeps the slant about the run's own baseline.
        if (font_is_fake_italic(c->size, c->weight)) {
          CGContextSetTextMatrix(ctx, fake_italic_matrix());
        }
        CGContextSetTextPosition(ctx, c->x, device_round(baseline));
        CGContextSetShouldSmoothFonts(ctx, false);
        CTLineDraw(line, ctx);
        if (font_is_fake_italic(c->size, c->weight)) CGContextSetTextMatrix(ctx, upright_text_matrix());
        // The marks go on once the glyphs are down, so a mark of an open shape never covers one.
        draw_emphasis(ctx, line, c->x, device_round(baseline), c->size, f, (int)c->emphasis, c->emphasis_color);
        CFRelease(line);
      }
    } else if (c->kind == CMD_TEXT_SHADOW) {
      @autoreleasepool {
        double baseline = text_baseline(font_for(c->size, c->weight), c->y, c->line_height);
        CTLineRef line = line_for_text(c->text, c->len, c->size, c->weight, c->letter, c->word, NO);
        set_fill(ctx, c->color);
        CGContextSetTextDrawingMode(ctx, kCGTextFill);
        CGContextSaveGState(ctx);
        set_shadow(ctx, c->shadow_color, c->dx, c->dy, c->blur);
        if (font_is_fake_bold(c->size, c->weight)) fake_bold_stroke(ctx, c->size, c->color);
        if (font_is_fake_italic(c->size, c->weight)) {
          CGContextSetTextMatrix(ctx, fake_italic_matrix());
        }
        CGContextSetTextPosition(ctx, c->x, device_round(baseline));
        CGContextSetShouldSmoothFonts(ctx, false);
        CTLineDraw(line, ctx);
        if (font_is_fake_italic(c->size, c->weight)) CGContextSetTextMatrix(ctx, upright_text_matrix());
        CGContextRestoreGState(ctx);
        // The mark is drawn in the emphasis colour alone, not as a shadow of itself.
        draw_emphasis(ctx, line, c->x, device_round(baseline), c->size,
                      font_for(c->size, c->weight), (int)c->emphasis, c->emphasis_color);
        CFRelease(line);
      }
    }
  }
  return i;
}

// Replays the display list into a context whose user space is top-left origin, y down.
static void replay(CGContextRef ctx, double width, double height) {
  // The frame is the root list; every layer hangs off a ref inside it.
  g_list = &g_root;
  g_replay_w = width;
  g_replay_h = height;
  // A backdrop-filter reads the pixels behind its box, which only a bitmap can answer: paint the
  // whole frame into one and copy it into `ctx` afterwards. Frames without one paint straight in.
  CGAffineTransform m0 = CGContextGetCTM(ctx);
  double dx = 0, dy = 0, dw = 0, dh = 0;
  CGContextRef target = ctx;
  if (g_needs_backdrop && width > 0 && height > 0) {
    CGPoint c0 = CGPointApplyAffineTransform(CGPointMake(0, 0), m0);
    CGPoint c1 = CGPointApplyAffineTransform(CGPointMake(width, height), m0);
    dx = floor(c0.x < c1.x ? c0.x : c1.x);
    dy = floor(c0.y < c1.y ? c0.y : c1.y);
    dw = ceil((c0.x < c1.x ? c1.x : c0.x)) - dx;
    dh = ceil((c0.y < c1.y ? c1.y : c0.y)) - dy;
    if (dw > 0 && dh > 0 && dw * dh <= 64.0 * 1024 * 1024) {
      CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
      target = CGBitmapContextCreate(NULL, (size_t)dw, (size_t)dh, 8, 0, cs,
                                     kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
      CGColorSpaceRelease(cs);
      if (target) {
        CGContextTranslateCTM(target, -dx, -dy);
        CGContextConcatCTM(target, m0);
      } else {
        target = ctx;
      }
    }
  }
  const int region = g_present_region && g_damage_count > 0;
  if (region) {
    CGMutablePathRef path = CGPathCreateMutable();
    for (int i = 0; i < g_damage_count; i++) {
      const double *r = g_damage_rects[i];
      CGPathAddRect(path, NULL, CGRectMake(r[0], r[1], r[2], r[3]));
    }
    CGContextSaveGState(target);
    CGContextAddPath(target, path);
    CGContextClip(target);
    CGPathRelease(path);
    set_fill(target, g_background);
    for (int i = 0; i < g_damage_count; i++) {
      const double *r = g_damage_rects[i];
      CGContextFillRect(target, CGRectMake(r[0], r[1], r[2], r[3]));
    }
  } else if (!g_skip_background) {
    set_fill(target, g_background);
    CGContextFillRect(target, CGRectMake(0, 0, width, height));
  }
  CGContextSetTextMatrix(target, CGAffineTransformMakeScale(1, -1));
  ReplayState st;
  st.depth = 0;
  st.transforms = 0;
  replay_range(target, 0, &st);
  if (region) CGContextRestoreGState(target);
  if (target != ctx) {
    CGImageRef img = CGBitmapContextCreateImage(target);
    CGContextRelease(target);
    if (img) {
      CGContextSaveGState(ctx);
      CGContextConcatCTM(ctx, CGAffineTransformInvert(CGContextGetCTM(ctx)));
      CGContextDrawImage(ctx, CGRectMake(dx, dy, dw, dh), img);
      CGContextRestoreGState(ctx);
      CGImageRelease(img);
    }
  }
}

// ---------------------------------------------------------------------------
// Effects: filter and blending layers
//
// A box with a filter or a mix-blend-mode paints its subtree into a layer of its own, delimited by
// CMD_EFFECT_PUSH and CMD_EFFECT_POP. The layer is replayed into a bitmap of the page's own device
// pixels, the filter list is applied to it, and the result is composited into the page with the
// blend mode. CoreGraphics has no filter pipeline, so the filters work on the bitmap's pixels: the
// colour matrices are the ones CSS defines for each function, and blur is a Gaussian, done as
// three box blurs.

// Filter function kinds, numbered as shared/props.ts numbers them (FK_*).
enum {
  FK_BLUR = 0, FK_BRIGHTNESS = 1, FK_CONTRAST = 2, FK_DROP_SHADOW = 3, FK_GRAYSCALE = 4,
  FK_HUE_ROTATE = 5, FK_INVERT = 6, FK_OPACITY = 7, FK_SATURATE = 8, FK_SEPIA = 9,
};

typedef struct {
  int kind;
  double a, dx, dy, blur;
  uint32_t color;
} FilterOp;

/** One layer's blend mode, filter chain and backdrop chain, as the runtime writes them into the
 * command. A backdrop chain filters what is painted behind the box, inside its border box. */
typedef struct {
  // The layer's own alpha, which multiplies its contents once when it composites: a box whose
  // opacity is below 1 fades as one group rather than drawing by drawing.
  double alpha;
  int blend;
  int count;
  FilterOp ops[64];
  int bcount;
  FilterOp bops[64];
} EffectSpec;

typedef struct {
  unsigned char *px;
  size_t w, h, stride;
} LayerBitmap;

/** Reads a filter list's count and functions from the spec, leaving `*end` after the last one. A
 *  negative backdrop count says the list is known to be unchanged behind the box: the host reuses
 *  the filtered result it kept instead of filtering again (see apply_backdrop). */
static int read_ops(FilterOp *ops, const char *q, char **end) {
  int count = (int)strtol(q, end, 10);
  q = *end;
  int n = count < 0 ? -count : count;
  if (n > 64) n = 64;
  for (int i = 0; i < n; i++) {
    FilterOp *op = &ops[i];
    op->kind = (int)strtol(q, end, 10);
    q = *end;
    op->a = strtod(q, end);
    q = *end;
    op->dx = strtod(q, end);
    q = *end;
    op->dy = strtod(q, end);
    q = *end;
    op->blur = strtod(q, end);
    q = *end;
    op->color = (uint32_t)strtod(q, end);
    q = *end;
  }
  return count < 0 ? -n : n;
}

static void effect_spec_parse(EffectSpec *s, const char *text) {
  s->alpha = 1;
  s->blend = 0;
  s->count = 0;
  s->bcount = 0;
  const char *q = text;
  char *end;
  s->alpha = strtod(q, &end);
  if (end == q) return;
  q = end;
  s->blend = (int)strtol(q, &end, 10);
  if (end == q) return;
  q = end;
  s->count = read_ops(s->ops, q, &end);
  q = end;
  s->bcount = read_ops(s->bops, q, &end);
}

/**
 * A box blur of `radius` pixels on each side, one direction at a time. Everything outside the
 * bitmap counts as transparent, so a shape's edge fades into nothing as a blurred edge does.
 */
static void box_blur(const unsigned char *src, unsigned char *dst, size_t w, size_t h, size_t stride,
                     int radius, int horizontal) {
  const long n = 2 * (long)radius + 1;
  if (horizontal) {
    for (size_t y = 0; y < h; y++) {
      const unsigned char *in = src + y * stride;
      unsigned char *out = dst + y * stride;
      long sr = 0, sg = 0, sb = 0, sa = 0;
      for (int k = -radius; k <= radius; k++) {
        if (k < 0 || (size_t)k >= w) continue;
        sr += in[k * 4]; sg += in[k * 4 + 1]; sb += in[k * 4 + 2]; sa += in[k * 4 + 3];
      }
      for (size_t x = 0; x < w; x++) {
        out[x * 4] = (unsigned char)((sr + n / 2) / n);
        out[x * 4 + 1] = (unsigned char)((sg + n / 2) / n);
        out[x * 4 + 2] = (unsigned char)((sb + n / 2) / n);
        out[x * 4 + 3] = (unsigned char)((sa + n / 2) / n);
        long drop = (long)x - radius, add = (long)x + radius + 1;
        if (drop >= 0 && (size_t)drop < w) {
          sr -= in[drop * 4]; sg -= in[drop * 4 + 1]; sb -= in[drop * 4 + 2]; sa -= in[drop * 4 + 3];
        }
        if (add >= 0 && (size_t)add < w) {
          sr += in[add * 4]; sg += in[add * 4 + 1]; sb += in[add * 4 + 2]; sa += in[add * 4 + 3];
        }
      }
    }
    return;
  }
  for (size_t x = 0; x < w; x++) {
    long sr = 0, sg = 0, sb = 0, sa = 0;
    for (int k = -radius; k <= radius; k++) {
      if (k < 0 || (size_t)k >= h) continue;
      const unsigned char *p = src + (size_t)k * stride + x * 4;
      sr += p[0]; sg += p[1]; sb += p[2]; sa += p[3];
    }
    for (size_t y = 0; y < h; y++) {
      unsigned char *out = dst + y * stride + x * 4;
      out[0] = (unsigned char)((sr + n / 2) / n);
      out[1] = (unsigned char)((sg + n / 2) / n);
      out[2] = (unsigned char)((sb + n / 2) / n);
      out[3] = (unsigned char)((sa + n / 2) / n);
      long drop = (long)y - radius, add = (long)y + radius + 1;
      if (drop >= 0 && (size_t)drop < h) {
        const unsigned char *p = src + (size_t)drop * stride + x * 4;
        sr -= p[0]; sg -= p[1]; sb -= p[2]; sa -= p[3];
      }
      if (add >= 0 && (size_t)add < h) {
        const unsigned char *p = src + (size_t)add * stride + x * 4;
        sr += p[0]; sg += p[1]; sb += p[2]; sa += p[3];
      }
    }
  }
}

/**
 * A Gaussian blur of standard deviation `sigma`, as three box blurs in each direction: the box
 * widths are chosen so their repeated convolution matches the Gaussian (Kutskir's sizes). Blurring
 * premultiplied pixels is what makes a blurred shape's edge fade rather than darken.
 */
static void gauss_blur(unsigned char *px, size_t w, size_t h, size_t stride, double sigma) {
  if (!(sigma > 0) || w == 0 || h == 0) return;
  double ideal = sqrt((12.0 * sigma * sigma / 3.0) + 1.0);
  int wl = (int)floor(ideal);
  if (wl % 2 == 0) wl--;
  if (wl < 1) wl = 1;
  int wu = wl + 2;
  double mIdeal = (12.0 * sigma * sigma - 3.0 * wl * wl - 12.0 * wl - 9.0) / (-4.0 * wl - 4.0);
  int m = (int)round(mIdeal);
  int sizes[3];
  for (int i = 0; i < 3; i++) sizes[i] = i < m ? wl : wu;
  unsigned char *tmp = malloc(h * stride);
  if (!tmp) return;
  for (int i = 0; i < 3; i++) {
    int radius = (sizes[i] - 1) / 2;
    if (radius < 1) continue;
    box_blur(px, tmp, w, h, stride, radius, 1);
    box_blur(tmp, px, w, h, stride, radius, 0);
  }
  free(tmp);
}

/** A 5x4 colour matrix, rows R, G, B, A, with its last column an offset (both scaled to 0..255). */
static void color_matrix(unsigned char *px, size_t w, size_t h, size_t stride, const double *m) {
  for (size_t y = 0; y < h; y++) {
    unsigned char *row = px + y * stride;
    for (size_t x = 0; x < w; x++) {
      unsigned char *p = row + x * 4;
      double a = p[3];
      // A transparent pixel has no colour to correct, and keeps its alpha.
      if (a <= 0) continue;
      // The matrices are defined on straight (unpremultiplied) colour.
      double r = p[0] * 255.0 / a, g = p[1] * 255.0 / a, b = p[2] * 255.0 / a;
      double nr = m[0] * r + m[1] * g + m[2] * b + m[3] * a + m[4] * 255.0;
      double ng = m[5] * r + m[6] * g + m[7] * b + m[8] * a + m[9] * 255.0;
      double nb = m[10] * r + m[11] * g + m[12] * b + m[13] * a + m[14] * 255.0;
      double na = m[15] * r + m[16] * g + m[17] * b + m[18] * a + m[19] * 255.0;
      if (nr < 0) nr = 0; else if (nr > 255) nr = 255;
      if (ng < 0) ng = 0; else if (ng > 255) ng = 255;
      if (nb < 0) nb = 0; else if (nb > 255) nb = 255;
      if (na < 0) na = 0; else if (na > 255) na = 255;
      p[0] = (unsigned char)round(nr * na / 255.0);
      p[1] = (unsigned char)round(ng * na / 255.0);
      p[2] = (unsigned char)round(nb * na / 255.0);
      p[3] = (unsigned char)round(na);
    }
  }
}

static void matrix_identity(double *m) {
  for (int i = 0; i < 20; i++) m[i] = 0;
  m[0] = 1; m[6] = 1; m[12] = 1; m[18] = 1;
}

/**
 * drop-shadow(): the element's alpha, blurred, tinted with the colour and offset, drawn under the
 * element.
 */
static void drop_shadow(unsigned char *px, size_t w, size_t h, size_t stride, const FilterOp *op,
                        double scale) {
  unsigned char *sh = calloc(h, stride);
  if (!sh) return;
  for (size_t y = 0; y < h; y++) {
    const unsigned char *in = px + y * stride;
    unsigned char *out = sh + y * stride;
    for (size_t x = 0; x < w; x++) out[x * 4 + 3] = in[x * 4 + 3];
  }
  if (op->blur > 0) gauss_blur(sh, w, h, stride, op->blur * scale / 2);
  // The layer's bitmap memory runs down the page (row 0 is the layer's top row), so a CSS offset
  // moves the shadow down and to the right by sampling the shape up and to the left of it.
  long offx = lround(op->dx * scale), offy = lround(op->dy * scale);
  double cr = ((op->color >> 24) & 0xff) * (double)(op->color & 0xff) / 255.0;
  double cg = ((op->color >> 16) & 0xff) * (double)(op->color & 0xff) / 255.0;
  double cb = ((op->color >> 8) & 0xff) * (double)(op->color & 0xff) / 255.0;
  for (size_t y = 0; y < h; y++) {
    unsigned char *row = px + y * stride;
    for (size_t x = 0; x < w; x++) {
      long sx = (long)x - offx, sy = (long)y - offy;
      if (sx < 0 || sy < 0 || (size_t)sx >= w || (size_t)sy >= h) continue;
      double sa = sh[(size_t)sy * stride + (size_t)sx * 4 + 3] / 255.0;
      if (sa <= 0) continue;
      // The element paints over the shadow: the shadow is the source under the destination.
      double da = row[x * 4 + 3] / 255.0;
      double under = 1.0 - da;
      double a = da + sa * under;
      row[x * 4] = (unsigned char)round(row[x * 4] + cr * sa * under);
      row[x * 4 + 1] = (unsigned char)round(row[x * 4 + 1] + cg * sa * under);
      row[x * 4 + 2] = (unsigned char)round(row[x * 4 + 2] + cb * sa * under);
      row[x * 4 + 3] = (unsigned char)round(a * 255.0);
    }
  }
  free(sh);
}

/** The filter chain, in order: each function takes the whole layer as its input. */
static void apply_filters(LayerBitmap *b, const FilterOp *ops, int count, double scale) {
  for (int i = 0; i < count; i++) {
    const FilterOp *op = &ops[i];
    double m[20];
    switch (op->kind) {
      case FK_BLUR:
        gauss_blur(b->px, b->w, b->h, b->stride, op->a * scale);
        break;
      case FK_BRIGHTNESS:
        matrix_identity(m);
        m[0] = m[6] = m[12] = op->a;
        color_matrix(b->px, b->w, b->h, b->stride, m);
        break;
      case FK_CONTRAST:
        matrix_identity(m);
        m[0] = m[6] = m[12] = op->a;
        m[4] = m[9] = m[14] = 0.5 - 0.5 * op->a;
        color_matrix(b->px, b->w, b->h, b->stride, m);
        break;
      case FK_GRAYSCALE: {
        double t = 1 - op->a;
        matrix_identity(m);
        m[0] = 0.2126 + 0.7874 * t; m[1] = 0.7152 - 0.7152 * t; m[2] = 0.0722 - 0.0722 * t;
        m[5] = 0.2126 - 0.2126 * t; m[6] = 0.7152 + 0.2848 * t; m[7] = 0.0722 - 0.0722 * t;
        m[10] = 0.2126 - 0.2126 * t; m[11] = 0.7152 - 0.7152 * t; m[12] = 0.0722 + 0.9278 * t;
        color_matrix(b->px, b->w, b->h, b->stride, m);
        break;
      }
      case FK_HUE_ROTATE: {
        double c = cos(op->a), s = sin(op->a);
        matrix_identity(m);
        m[0] = 0.213 + c * 0.787 - s * 0.213; m[1] = 0.715 - c * 0.715 - s * 0.715;
        m[2] = 0.072 - c * 0.072 + s * 0.928;
        m[5] = 0.213 - c * 0.213 + s * 0.143; m[6] = 0.715 + c * 0.285 + s * 0.140;
        m[7] = 0.072 - c * 0.072 - s * 0.283;
        m[10] = 0.213 - c * 0.213 - s * 0.787; m[11] = 0.715 - c * 0.715 + s * 0.715;
        m[12] = 0.072 + c * 0.928 + s * 0.072;
        color_matrix(b->px, b->w, b->h, b->stride, m);
        break;
      }
      case FK_INVERT:
        matrix_identity(m);
        m[0] = m[6] = m[12] = 1 - 2 * op->a;
        m[4] = m[9] = m[14] = op->a;
        color_matrix(b->px, b->w, b->h, b->stride, m);
        break;
      case FK_OPACITY:
        matrix_identity(m);
        m[18] = op->a;
        color_matrix(b->px, b->w, b->h, b->stride, m);
        break;
      case FK_SATURATE: {
        double s = op->a;
        matrix_identity(m);
        m[0] = 0.213 + 0.787 * s; m[1] = 0.715 - 0.715 * s; m[2] = 0.072 - 0.072 * s;
        m[5] = 0.213 - 0.213 * s; m[6] = 0.715 + 0.285 * s; m[7] = 0.072 - 0.072 * s;
        m[10] = 0.213 - 0.213 * s; m[11] = 0.715 - 0.715 * s; m[12] = 0.072 + 0.928 * s;
        color_matrix(b->px, b->w, b->h, b->stride, m);
        break;
      }
      case FK_SEPIA: {
        double t = 1 - op->a;
        matrix_identity(m);
        m[0] = 0.393 + 0.607 * t; m[1] = 0.769 - 0.769 * t; m[2] = 0.189 - 0.189 * t;
        m[5] = 0.349 - 0.349 * t; m[6] = 0.686 + 0.314 * t; m[7] = 0.168 - 0.168 * t;
        m[10] = 0.272 - 0.272 * t; m[11] = 0.534 - 0.534 * t; m[12] = 0.131 + 0.869 * t;
        color_matrix(b->px, b->w, b->h, b->stride, m);
        break;
      }
      case FK_DROP_SHADOW:
        drop_shadow(b->px, b->w, b->h, b->stride, op, scale);
        break;
      default:
        break;
    }
  }
}

// ---------------------------------------------------------------------------
// A backdrop filter's result, kept as an image of the box it covers: its own layer.
//
// The filter samples the pixels behind the box, which a frame that repaints only part of the page
// doesn't have fresh. A frame whose damage is inside the box — an animation in a blurred header —
// leaves the backdrop alone, so the filtered result the last full paint made still stands; it is
// kept here and drawn back over the regions the frame repaints. A frame that repainted the box
// filters again and replaces it.

#define MAX_BACKDROPS 8

typedef struct {
  int used;
  int32_t serial;
  double scale;
  long x, y, w, h;   // the device-pixel rect, y up as Core Graphics measures it
  long row;          // the top memory row of the rect
  unsigned char *px; // w * h premultiplied pixels, the filtered backdrop
  unsigned long stamp;
} BackdropImage;

static BackdropImage g_backdrops[MAX_BACKDROPS];
static unsigned long g_backdrop_stamp = 0;

static BackdropImage *backdrop_find(int32_t serial, long bx, long by, long bw, long bh, double scale) {
  for (int i = 0; i < MAX_BACKDROPS; i++) {
    BackdropImage *s = &g_backdrops[i];
    if (s->used && s->serial == serial && s->x == bx && s->y == by && s->w == bw && s->h == bh && s->scale == scale) return s;
  }
  return NULL;
}

/** Whether a rounded rect has any corner to cut. */
static int radii_set(const double *r) {
  if (r == NULL) return 0;
  for (int k = 0; k < 8; k++) if (r[k] > 0) return 1;
  return 0;
}

/** The border shape an effect's box paints under, in device pixels: the element's border box
 *  rounded like its background, through the transform that box sits in. NULL for a square box. */
static CGPathRef backdrop_shape(const Cmd *c, const Cmd *clip, CGAffineTransform m) {
  if (clip == NULL || !radii_set(clip->r)) return NULL;
  CGPathRef p = round_path(c->x, c->y, c->w, c->h, clip->r);
  CGPathRef out = CGPathCreateCopyByTransformingPath(p, &m);
  CGPathRelease(p);
  return out;
}

/** Draws filtered backdrop pixels over the box they came from, in device pixels and clipped to
 *  the box's border shape: a backdrop filter is cut by the element's border radius, so none of
 *  it shows in the corners the element itself doesn't cover. */
static void draw_backdrop_box(CGContextRef ctx, const unsigned char *px, long w, long h,
                              size_t stride, long x, long y, CGPathRef shape) {
  if (px == NULL || w <= 0 || h <= 0) return;
  CGColorSpaceRef cs = CGBitmapContextGetColorSpace(ctx);
  if (cs == NULL) return;
  CGBitmapInfo info = CGBitmapContextGetBitmapInfo(ctx);
  CGDataProviderRef prov = CGDataProviderCreateWithData(NULL, px, (size_t)h * stride, NULL);
  if (prov == NULL) return;
  CGImageRef img = CGImageCreate((size_t)w, (size_t)h, 8, 32, stride, cs, info, prov, NULL,
                                 false, kCGRenderingIntentDefault);
  CGDataProviderRelease(prov);
  if (img == NULL) return;
  CGContextSaveGState(ctx);
  // Device pixels, so the image lands exactly where the filter cut it from whatever the page's
  // transform is; the context's clip keeps it inside the regions being repainted.
  CGContextConcatCTM(ctx, CGAffineTransformInvert(CGContextGetCTM(ctx)));
  if (shape != NULL) {
    CGContextSetShouldAntialias(ctx, true);
    CGContextAddPath(ctx, shape);
    CGContextClip(ctx);
  }
  // The pixels are what the filter wrote over the backdrop: replace, don't blend, and don't
  // resample — they land on the pixels they came from.
  CGContextSetBlendMode(ctx, kCGBlendModeCopy);
  CGContextSetInterpolationQuality(ctx, kCGInterpolationNone);
  CGContextSetShouldAntialias(ctx, false);
  CGContextDrawImage(ctx, CGRectMake((double)x, (double)y, (double)w, (double)h), img);
  CGContextRestoreGState(ctx);
  CGImageRelease(img);
}

/** Draws a kept filtered backdrop where it came from, clipped to what the frame repaints. */
static int backdrop_draw(CGContextRef ctx, BackdropImage *s, CGPathRef shape) {
  if (s->px == NULL) return 0;
  draw_backdrop_box(ctx, s->px, s->w, s->h, (size_t)s->w * 4, s->x, s->y, shape);
  return 1;
}

/** The border radius the element an effect push belongs to paints its box with: the rounded clip
 *  its background is painted under, in the effect's own range. NULL when the box has square corners
 *  or the commands carry no rounded clip. */
static const Cmd *effect_round_clip_list(const Cmd *cmds, size_t count, size_t first, size_t last,
                                         const Cmd *eff, int layers);

static const Cmd *effect_round_clip(size_t first, size_t last, const Cmd *eff) {
  return effect_round_clip_list(g_list->cmds, g_list->count, first, last, eff, 1);
}

/** The same scan over a list the effect sits inside (a layer's own commands). */
static const Cmd *effect_round_clip_list(const Cmd *cmds, size_t count, size_t first, size_t last,
                                         const Cmd *eff, int layers) {
  int depth = 0;
  for (size_t k = first; k < last && k < count; k++) {
    const Cmd *q = &cmds[k];
    if (q->kind == CMD_EFFECT_PUSH || q->kind == CMD_MASK_PUSH || q->kind == CMD_PERSPECTIVE_PUSH) {
      depth++;
      continue;
    }
    if (q->kind == CMD_EFFECT_POP || q->kind == CMD_MASK_POP || q->kind == CMD_PERSPECTIVE_POP) {
      if (depth > 0) depth--;
      continue;
    }
    if (q->kind == CMD_LAYER_REF && depth == 0 && layers && q->layer >= 0 && q->layer < g_layer_count) {
      CmdList *inner = &g_layers[q->layer].list;
      const Cmd *hit = effect_round_clip_list(inner->cmds, inner->count, 0, inner->count, eff, 0);
      if (hit != NULL) return hit;
      continue;
    }
    if (depth != 0) continue;
    if (q->kind != CMD_CLIP_ROUND && q->kind != CMD_FILL_ROUND && q->kind != CMD_RING_ROUND) continue;
    if (q->x < eff->x - 8 || q->y < eff->y - 8) continue;
    if (q->x + q->w > eff->x + eff->w + 8 || q->y + q->h > eff->y + eff->h + 8) continue;
    if (q->x > eff->x + 0.01 || q->y > eff->y + 0.01) continue;
    if (q->x + q->w < eff->x + eff->w - 0.01 || q->y + q->h < eff->y + eff->h - 0.01) continue;
    if (radii_set(q->r)) return q;
  }
  return NULL;
}

/** Keeps the filtered backdrop just written, for the frames that repaint only part of the box. */
static void backdrop_store(const Cmd *c, const unsigned char *base, size_t stride, long bx, long by,
                           long mrow, long bw, long bh, double scale) {
  // A huge box is not worth keeping: the frames that repaint part of it are rare next to its cost.
  if ((double)bw * (double)bh > 2.0 * 1024 * 1024) return;
  BackdropImage *s = backdrop_find(c->serial, bx, by, bw, bh, scale);
  if (s == NULL) {
    // Replace the least recently kept entry; a box that moved or resized is a miss until its
    // filter runs again.
    s = &g_backdrops[0];
    for (int i = 0; i < MAX_BACKDROPS; i++) {
      if (!g_backdrops[i].used) { s = &g_backdrops[i]; break; }
      if (g_backdrops[i].stamp < s->stamp) s = &g_backdrops[i];
    }
    unsigned char *px = (unsigned char *)malloc((size_t)bw * (size_t)bh * 4);
    if (px == NULL) return;
    free(s->px);
    s->px = px;
    s->used = 1;
    s->serial = c->serial;
    s->x = bx;
    s->y = by;
    s->w = bw;
    s->h = bh;
    s->scale = scale;
  }
  s->row = mrow;
  s->stamp = ++g_backdrop_stamp;
  for (long y = 0; y < bh; y++) {
    memcpy(s->px + (size_t)y * (size_t)bw * 4, base + (size_t)(mrow + y) * stride + (size_t)bx * 4,
           (size_t)bw * 4);
  }
}

/**
 * A backdrop-filter's work: the pixels already painted in the box's border box are copied out of
 * the destination, filtered, and written back, so the box's own layer then paints over the
 * filtered result. `ctx` must be a bitmap context, which replay() arranges for any frame whose
 * command list carries a backdrop chain; the box's border box is the filter's region.
 *
 * A reused filter — a compositor frame, or a frame the runtime marked as changing nothing behind
 * the box (a negative backdrop count) — draws the result the last real filter left instead, so a
 * frame that repaints part of a blurred panel costs nothing to filter.
 */
static void apply_backdrop(CGContextRef ctx, const Cmd *c, const EffectSpec *spec, double scale,
                           const Cmd *clip) {
  unsigned char *base = CGBitmapContextGetData(ctx);
  if (!base || spec->bcount == 0) return;
  // The filter is part of the element's painting: an element faded to nothing paints nothing, and
  // its backdrop filter must not leave the filtered backdrop behind.
  if (!(spec->alpha > 0)) return;
  int bcount = spec->bcount < 0 ? -spec->bcount : spec->bcount;
  int reuse = spec->bcount < 0 || g_reuse_backdrops;
  if (g_layer_images_on || g_reference_paint) reuse = 0;
  size_t fw = CGBitmapContextGetWidth(ctx), fh = CGBitmapContextGetHeight(ctx);
  size_t fstride = CGBitmapContextGetBytesPerRow(ctx);
  CGAffineTransform m = CGContextGetCTM(ctx);
  double minx = 0, miny = 0, maxx = 0, maxy = 0;
  for (int k = 0; k < 4; k++) {
    double ux = k == 0 || k == 3 ? c->x : c->x + c->w;
    double uy = k < 2 ? c->y : c->y + c->h;
    CGPoint p = CGPointApplyAffineTransform(CGPointMake(ux, uy), m);
    if (k == 0 || p.x < minx) minx = p.x;
    if (k == 0 || p.y < miny) miny = p.y;
    if (k == 0 || p.x > maxx) maxx = p.x;
    if (k == 0 || p.y > maxy) maxy = p.y;
  }
  long bx = (long)floor(minx), by = (long)floor(miny);
  long bw = (long)ceil(maxx) - bx, bh = (long)ceil(maxy) - by;
  if (bw <= 0 || bh <= 0) return;
  // Only what the destination holds can be filtered.
  if (bx < 0) { bw += bx; bx = 0; }
  if (by < 0) { bh += by; by = 0; }
  if (bx + bw > (long)fw) bw = (long)fw - bx;
  if (by + bh > (long)fh) bh = (long)fh - by;
  if (bw <= 0 || bh <= 0) return;
  // The CTM's device space is y-up, but a bitmap's memory starts at the top row of the image, so
  // the device rect's top edge is the memory row fh - (by + bh).
  long mrow = (long)fh - (by + bh);
  if (mrow < 0) mrow = 0;
  // The shape the box paints under, in the same device pixels the box was measured in.
  CGPathRef shape = backdrop_shape(c, clip, m);
  // A frame that left the pixels behind the box alone draws the result the last real filter kept:
  // the repainted regions get exactly the backdrop they would have filtered to.
  if (reuse) {
    BackdropImage *kept = backdrop_find(c->serial, bx, by, bw, bh, scale);
    // The kept pixels are the clipped result: their edge already carries the shape's coverage, so
    // drawing them back through the same clip would apply the antialiasing a second time.
    if (kept != NULL && backdrop_draw(ctx, kept, NULL)) {
      if (shape != NULL) CGPathRelease(shape);
      return;
    }
  }
  // A blur samples past the box, and the backdrop beyond it isn't the box's to filter: the copy
  // is grown by however far the chain spreads and its edge pixels repeated into that margin, so
  // the box's own edge blurs with the colour behind it instead of fading towards transparent.
  long pad = 0;
  for (int i = 0; i < bcount; i++) {
    const FilterOp *op = &spec->bops[i];
    if (op->kind == FK_BLUR) pad += (long)ceil(op->a * scale * 3);
    else if (op->kind == FK_DROP_SHADOW) {
      pad += (long)ceil((fabs(op->dx) + fabs(op->dy) + op->blur * 3) * scale);
    }
  }
  if (pad > 512) pad = 512;
  long pw = bw + 2 * pad, ph2 = bh + 2 * pad;
  if ((double)pw * ph2 > 16.0 * 1024 * 1024) { pad = 0; pw = bw; ph2 = bh; }
  size_t lstride = (size_t)pw * 4;
  unsigned char *buf = malloc((size_t)ph2 * lstride);
  if (!buf) {
    if (shape != NULL) CGPathRelease(shape);
    return;
  }
  for (long y = 0; y < ph2; y++) {
    long sy = y - pad;
    if (sy < 0) sy = 0;
    if (sy >= bh) sy = bh - 1;
    const unsigned char *src = base + (size_t)(mrow + sy) * fstride + (size_t)bx * 4;
    unsigned char *dst = buf + (size_t)y * lstride;
    for (long x = 0; x < pw; x++) {
      long sx = x - pad;
      if (sx < 0) sx = 0;
      if (sx >= bw) sx = bw - 1;
      memcpy(dst + (size_t)x * 4, src + (size_t)sx * 4, 4);
    }
  }
  LayerBitmap b;
  b.px = buf;
  b.w = (size_t)pw;
  b.h = (size_t)ph2;
  b.stride = lstride;
  apply_filters(&b, spec->bops, bcount, scale);
  if (shape != NULL) {
    // The filter's result is the box, cut by the element's border shape: the backdrop in the
    // corners the element itself doesn't paint stays as it was.
    draw_backdrop_box(ctx, buf + (size_t)pad * lstride + (size_t)pad * 4, bw, bh, lstride,
                      bx, by, shape);
    CGPathRelease(shape);
  } else {
    for (long y = 0; y < bh; y++) {
      memcpy(base + (size_t)(mrow + y) * fstride + (size_t)bx * 4,
        buf + (size_t)(y + pad) * lstride + (size_t)pad * 4, (size_t)bw * 4);
    }
  }
  free(buf);
  if (!g_layer_images_on) backdrop_store(c, base, fstride, bx, by, mrow, bw, bh, scale);
}

/** The CoreGraphics blend mode for a mix-blend-mode value. Its order isn't CSS's. */static CGBlendMode blend_mode(int mode) {
  switch (mode) {
    case 1: return kCGBlendModeMultiply;
    case 2: return kCGBlendModeScreen;
    case 3: return kCGBlendModeOverlay;
    case 4: return kCGBlendModeDarken;
    case 5: return kCGBlendModeLighten;
    case 6: return kCGBlendModeColorDodge;
    case 7: return kCGBlendModeColorBurn;
    case 8: return kCGBlendModeHardLight;
    case 9: return kCGBlendModeSoftLight;
    case 10: return kCGBlendModeDifference;
    case 11: return kCGBlendModeExclusion;
    case 12: return kCGBlendModeHue;
    case 13: return kCGBlendModeSaturation;
    case 14: return kCGBlendModeColor;
    case 15: return kCGBlendModeLuminosity;
    case 16: return kCGBlendModePlusLighter;
    default: return kCGBlendModeNormal;
  }
}

/** Skips a layer's commands without drawing them, returning the index of its pop. */
static size_t skip_layer(size_t i) {
  int nested = 0;
  for (size_t k = i; k < g_list->count; k++) {
    if (g_list->cmds[k].kind == CMD_EFFECT_PUSH || g_list->cmds[k].kind == CMD_MASK_PUSH ||
      g_list->cmds[k].kind == CMD_PERSPECTIVE_PUSH) nested++;
    else if (g_list->cmds[k].kind == CMD_EFFECT_POP || g_list->cmds[k].kind == CMD_MASK_POP ||
      g_list->cmds[k].kind == CMD_PERSPECTIVE_POP) {
      nested--;
      if (nested == 0) return k;
    }
  }
  return g_list->count;
}

/**
 * Replays one layer: the commands from `i` (a CMD_EFFECT_PUSH) to its CMD_EFFECT_POP are drawn
 * into a bitmap covering the layer's filter region in device pixels, the filter chain runs on that
 * bitmap, and the result is composited into `ctx` with the layer's blend mode. Returns the index
 * of the pop.
 */
static size_t replay_effect(CGContextRef ctx, size_t i) {
  Cmd *c = &g_list->cmds[i];
  EffectSpec spec;
  effect_spec_parse(&spec, c->text);
  if (c->alpha_override) spec.alpha = c->alpha;
  // An opacity group with nothing else to it needs no bitmap: a transparency layer fades whatever
  // the box paints, however far it reaches past the box, which is what an opacity group is.
  if (spec.alpha < 1 && spec.count == 0 && spec.bcount == 0 && spec.blend == 0) {
    CGContextSaveGState(ctx);
    CGContextSetAlpha(ctx, spec.alpha);
    CGContextBeginTransparencyLayer(ctx, NULL);
    ReplayState plain;
    plain.depth = 0;
    plain.transforms = 0;
    size_t pop = replay_range(ctx, i + 1, &plain);
    CGContextEndTransparencyLayer(ctx);
    CGContextRestoreGState(ctx);
    return pop;
  }
  // The filter region is the border box grown by 10% on every side (CSS Filter Effects), mapped
  // through the page's transform into the device pixels the layer is cut from.
  CGAffineTransform m = CGContextGetCTM(ctx);
  double ex = c->w * 0.1, ey = c->h * 0.1;
  double minx = 0, miny = 0, maxx = 0, maxy = 0;
  for (int k = 0; k < 4; k++) {
    double ux = k == 0 || k == 3 ? c->x - ex : c->x + c->w + ex;
    double uy = k < 2 ? c->y - ey : c->y + c->h + ey;
    CGPoint p = CGPointApplyAffineTransform(CGPointMake(ux, uy), m);
    if (k == 0 || p.x < minx) minx = p.x;
    if (k == 0 || p.y < miny) miny = p.y;
    if (k == 0 || p.x > maxx) maxx = p.x;
    if (k == 0 || p.y > maxy) maxy = p.y;
  }
  double dx = floor(minx), dy = floor(miny);
  double dw = ceil(maxx) - dx, dh = ceil(maxy) - dy;
  // The scale the filter's CSS lengths run at: blur(4px) covers twice the pixels on a 2x display.
  double scale = sqrt(fabs(m.a * m.d - m.b * m.c));
  // An absurd layer would exhaust memory: skip it.
  if (dw * dh > 16.0 * 1024 * 1024) return skip_layer(i);
  if (!(dw > 0 && dh > 0)) {
    // A box with no area has no filter region, so there is nothing to filter (or to blend): what
    // it holds, positioned children that outgrow an empty box among them, paints plainly.
    ReplayState plain;
    plain.depth = 0;
    plain.transforms = 0;
    return replay_range(ctx, i + 1, &plain);
  }
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef bctx = CGBitmapContextCreate(NULL, (size_t)dw, (size_t)dh, 8, 0, cs,
                                            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(cs);
  if (!bctx) return skip_layer(i);
  CGContextClearRect(bctx, CGRectMake(0, 0, dw, dh));
  // The layer's user space is the page's device space moved to the bitmap's own origin, so every
  // command inside draws in the same coordinate space it would have outside.
  CGContextTranslateCTM(bctx, -dx, -dy);
  CGContextConcatCTM(bctx, m);
  CGContextSetTextMatrix(bctx, CGAffineTransformMakeScale(1, -1));
  ReplayState sub;
  sub.depth = 0;
  sub.transforms = 0;
  size_t pop = replay_range(bctx, i + 1, &sub);
  LayerBitmap b;
  b.px = CGBitmapContextGetData(bctx);
  b.w = (size_t)dw;
  b.h = (size_t)dh;
  b.stride = CGBitmapContextGetBytesPerRow(bctx);
  if (b.px && spec.count > 0) apply_filters(&b, spec.ops, spec.count, scale);
  // What is behind the box is filtered in place before the layer paints over it.
  if (spec.bcount != 0) {
    // The box's own rounded clip, when it has one, is the shape the backdrop filter is cut by.
    apply_backdrop(ctx, c, &spec, scale, effect_round_clip(i + 1, pop, c));
  }
  CGImageRef img = CGBitmapContextCreateImage(bctx);
  CGContextRelease(bctx);
  if (img) {
    CGContextSaveGState(ctx);
    // Device pixels, so the bitmap lands exactly where it was cut from whatever the page's
    // transform is.
    CGContextConcatCTM(ctx, CGAffineTransformInvert(CGContextGetCTM(ctx)));
    CGContextSetBlendMode(ctx, blend_mode(spec.blend));
    // The layer composites as one image, with the blend mode it asked for; its own contents never
    // see the page behind it, which is the isolation a stacking context gives them. Its alpha
    // multiplies the whole image once, after the filter chain has run on it.
    CGContextSetAlpha(ctx, spec.alpha);
    CGContextBeginTransparencyLayerWithRect(ctx, CGRectMake(dx, dy, dw, dh), NULL);
    CGContextDrawImage(ctx, CGRectMake(dx, dy, dw, dh), img);
    CGContextEndTransparencyLayer(ctx);
    CGContextRestoreGState(ctx);
    CGImageRelease(img);
  }
  return pop;
}

/**
 * Replays a perspective layer: the commands from a CMD_PERSPECTIVE_PUSH to its pop paint the box
 * in its own space into a bitmap, and the bitmap is warped onto the projected quad with
 * CoreImage's CIPerspectiveTransform, then composited into the page. A planar quad's projective
 * map is exactly a homography, so this is Chrome's projection, edges included.
 */
static size_t replay_perspective(CGContextRef ctx, size_t i) {
  Cmd *c = &g_list->cmds[i];
  CGAffineTransform userToDevice = CGContextGetCTM(ctx);
  // The bitmap covers the box before projection, in the page's device pixels.
  double minx = 0, miny = 0, maxx = 0, maxy = 0;
  for (int k = 0; k < 4; k++) {
    double ux = k == 0 || k == 3 ? c->x : c->x + c->w;
    double uy = k < 2 ? c->y : c->y + c->h;
    CGPoint p = CGPointApplyAffineTransform(CGPointMake(ux, uy), userToDevice);
    if (k == 0 || p.x < minx) minx = p.x;
    if (k == 0 || p.y < miny) miny = p.y;
    if (k == 0 || p.x > maxx) maxx = p.x;
    if (k == 0 || p.y > maxy) maxy = p.y;
  }
  double dx = floor(minx), dy = floor(miny);
  double dw = ceil(maxx) - dx, dh = ceil(maxy) - dy;
  if (!(dw > 0 && dh > 0) || dw * dh > 32.0 * 1024 * 1024) return skip_layer(i);
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef bctx = CGBitmapContextCreate(NULL, (size_t)dw, (size_t)dh, 8, 0, cs,
                                            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(cs);
  if (!bctx) return skip_layer(i);
  CGContextClearRect(bctx, CGRectMake(0, 0, dw, dh));
  CGContextTranslateCTM(bctx, -dx, -dy);
  CGContextConcatCTM(bctx, userToDevice);
  CGContextSetTextMatrix(bctx, CGAffineTransformMakeScale(1, -1));
  ReplayState sub;
  sub.depth = 0;
  sub.transforms = 0;
  size_t pop = replay_range(bctx, i + 1, &sub);
  CGImageRef img = CGBitmapContextCreateImage(bctx);
  CGContextRelease(bctx);
  if (!img) return pop;
  // The quad in device pixels. The bitmap and CoreImage both have their origin at the bottom
  // left, so the page's top-left corner is the bitmap's top-left in this space.
  double qx[4], qy[4];
  for (int k = 0; k < 4; k++) {
    CGPoint p = CGPointApplyAffineTransform(CGPointMake(c->q[k * 2], c->q[k * 2 + 1]), userToDevice);
    qx[k] = p.x;
    qy[k] = p.y;
  }
  CIImage *src = [CIImage imageWithCGImage:img];
  CIFilter *f = [CIFilter filterWithName:@"CIPerspectiveTransform"];
  if (f != nil) {
    [f setValue:src forKey:kCIInputImageKey];
    [f setValue:[CIVector vectorWithX:qx[0] Y:qy[0]] forKey:@"inputTopLeft"];
    [f setValue:[CIVector vectorWithX:qx[1] Y:qy[1]] forKey:@"inputTopRight"];
    [f setValue:[CIVector vectorWithX:qx[2] Y:qy[2]] forKey:@"inputBottomRight"];
    [f setValue:[CIVector vectorWithX:qx[3] Y:qy[3]] forKey:@"inputBottomLeft"];
    CIImage *out = [f outputImage];
    if (out != nil) {
      CGRect ext = out.extent;
      CGContextSaveGState(ctx);
      // Device pixels, so the image lands where the quad says whatever the page's transform is.
      CGContextConcatCTM(ctx, CGAffineTransformInvert(CGContextGetCTM(ctx)));
      CIContext *ci = [CIContext contextWithCGContext:ctx options:nil];
      [ci drawImage:out inRect:ext fromRect:ext];
      CGContextRestoreGState(ctx);
    }
  }
  CGImageRelease(img);
  return pop;
}

/**
 * Replays a mask layer. The commands from a CMD_MASK_PUSH to its CMD_MASK_POP paint the box into
 * one bitmap; the ones before CMD_MASK_SPLIT are its mask image, painted into a second one. Every
 * pixel of the box then keeps as much of its alpha as the mask has there, and the result is
 * composited into `ctx`. What falls outside the mask's box — the border box, mask-clip's initial
 * value — is dropped with it. Returns the index of the pop.
 */
static size_t replay_mask(CGContextRef ctx, size_t i) {
  Cmd *c = &g_list->cmds[i];
  CGAffineTransform m = CGContextGetCTM(ctx);
  double minx = 0, miny = 0, maxx = 0, maxy = 0;
  for (int k = 0; k < 4; k++) {
    double ux = k == 0 || k == 3 ? c->x : c->x + c->w;
    double uy = k < 2 ? c->y : c->y + c->h;
    CGPoint p = CGPointApplyAffineTransform(CGPointMake(ux, uy), m);
    if (k == 0 || p.x < minx) minx = p.x;
    if (k == 0 || p.y < miny) miny = p.y;
    if (k == 0 || p.x > maxx) maxx = p.x;
    if (k == 0 || p.y > maxy) maxy = p.y;
  }
  double dx = floor(minx), dy = floor(miny);
  double dw = ceil(maxx) - dx, dh = ceil(maxy) - dy;
  // An absurd layer would exhaust memory: skip it.
  if (dw * dh > 16.0 * 1024 * 1024) return skip_layer(i);
  // A box with no area shows nothing once masked: its mask is transparent along the whole of it.
  if (!(dw > 0 && dh > 0)) return skip_layer(i);
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef mask = CGBitmapContextCreate(NULL, (size_t)dw, (size_t)dh, 8, 0, cs,
                                            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
  CGContextRef content = CGBitmapContextCreate(NULL, (size_t)dw, (size_t)dh, 8, 0, cs,
                                               kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(cs);
  if (!mask || !content) {
    if (mask) CGContextRelease(mask);
    if (content) CGContextRelease(content);
    return skip_layer(i);
  }
  // Both bitmaps are cut from the page's device space at the box's corner, so everything inside
  // them draws in the coordinate space it would have outside.
  CGContextClearRect(mask, CGRectMake(0, 0, dw, dh));
  CGContextTranslateCTM(mask, -dx, -dy);
  CGContextConcatCTM(mask, m);
  CGContextSetTextMatrix(mask, CGAffineTransformMakeScale(1, -1));
  ReplayState mst;
  mst.depth = 0;
  mst.transforms = 0;
  size_t split = replay_range(mask, i + 1, &mst);

  CGContextClearRect(content, CGRectMake(0, 0, dw, dh));
  CGContextTranslateCTM(content, -dx, -dy);
  CGContextConcatCTM(content, m);
  CGContextSetTextMatrix(content, CGAffineTransformMakeScale(1, -1));
  ReplayState cst;
  cst.depth = 0;
  cst.transforms = 0;
  size_t pop = split < g_list->count ? replay_range(content, split + 1, &cst) : g_list->count;

  unsigned char *cp = CGBitmapContextGetData(content);
  const unsigned char *mp = CGBitmapContextGetData(mask);
  if (cp && mp) {
    size_t stride = CGBitmapContextGetBytesPerRow(content);
    size_t mstride = CGBitmapContextGetBytesPerRow(mask);
    for (size_t y = 0; y < (size_t)dh; y++) {
      unsigned char *row = cp + y * stride;
      const unsigned char *mrow = mp + y * mstride;
      for (size_t x = 0; x < (size_t)dw; x++) {
        unsigned a = mrow[x * 4 + 3];
        if (a == 255) continue;
        unsigned char *p = row + x * 4;
        // The content is premultiplied, so scaling every channel by the mask's coverage is the
        // same as cutting the alpha and leaving the colour alone.
        p[0] = (unsigned char)((p[0] * a + 127) / 255);
        p[1] = (unsigned char)((p[1] * a + 127) / 255);
        p[2] = (unsigned char)((p[2] * a + 127) / 255);
        p[3] = (unsigned char)((p[3] * a + 127) / 255);
      }
    }
  }
  CGImageRef img = CGBitmapContextCreateImage(content);
  CGContextRelease(mask);
  CGContextRelease(content);
  if (img) {
    CGContextSaveGState(ctx);
    CGContextConcatCTM(ctx, CGAffineTransformInvert(CGContextGetCTM(ctx)));
    CGContextSetBlendMode(ctx, kCGBlendModeNormal);
    CGContextBeginTransparencyLayerWithRect(ctx, CGRectMake(dx, dy, dw, dh), NULL);
    CGContextDrawImage(ctx, CGRectMake(dx, dy, dw, dh), img);
    CGContextEndTransparencyLayer(ctx);
    CGContextRestoreGState(ctx);
    CGImageRelease(img);
  }
  return pop;
}

/**
 * Starts a mask layer over the box (x, y, w, h) in the current user space. The commands up to
 * host_mask_split() paint the mask image, the ones from there to host_mask_pop() the content.
 */
void host_mask_push(int32_t serial, int32_t pkind, double x, double y, double w, double h) {
  Cmd *c = push_cmd();
  c->kind = CMD_MASK_PUSH;
  c->serial = serial; c->pkind = pkind;
  c->x = x;
  c->y = y;
  c->w = w;
  c->h = h;
}

/** Marks where a mask layer's image ends and the content it masks begins. */
void host_mask_split(void) { push_cmd()->kind = CMD_MASK_SPLIT; }

void host_mask_pop(void) { push_cmd()->kind = CMD_MASK_POP; }

static Cmd *push_effect(int32_t serial, int32_t pkind, double x, double y, double w, double h,
                        const uint8_t *spec, size_t n) {
  Cmd *c = push_cmd();
  c->kind = CMD_EFFECT_PUSH;
  c->serial = serial; c->pkind = pkind;
  c->x = x;
  c->y = y;
  c->w = w;
  c->h = h;
  c->text = malloc(n + 1);
  memcpy(c->text, spec, n);
  c->text[n] = 0;
  c->len = n;
  EffectSpec parsed;
  effect_spec_parse(&parsed, c->text);
  if (parsed.bcount != 0) g_needs_backdrop = 1;
  return c;
}

void host_effect_push(int32_t serial, int32_t pkind, double x, double y, double w, double h,
                      const uint8_t *spec, size_t n) {
  push_effect(serial, pkind, x, y, w, h, spec, n);
}

/** The same, reporting the command's handle so a later frame can set its alpha in place. */
int32_t host_effect_push_indexed(int32_t serial, int32_t pkind, double x, double y, double w, double h,
                                 const uint8_t *spec, size_t n) {
  return push_effect(serial, pkind, x, y, w, h, spec, n)->handle;
}

/** The command a handle names: its list id and index are packed into the handle. */
static Cmd *find_command(int32_t handle) {
  if (handle < 0) return NULL;
  int32_t list_id = handle / CMD_HANDLE_STRIDE - 1;
  int32_t index = handle % CMD_HANDLE_STRIDE;
  if (list_id < -1 || list_id >= g_layer_count) return NULL;
  CmdList *list = list_id < 0 ? &g_root : &g_layers[list_id].list;
  if (index < 0 || (size_t)index >= list->count) return NULL;
  Cmd *c = &list->cmds[index];
  return c->handle == handle ? c : NULL;
}

/** Moves a recorded transform to a new matrix, and a recorded opacity group to a new alpha. */
int32_t host_update_transform(int32_t handle, double a, double b, double cc, double d, double e, double f) {
  Cmd *c = find_command(handle);
  if (c == NULL || c->kind != CMD_TRANSFORM) return 0;
  c->p0 = a; c->p1 = b; c->p2 = cc; c->p3 = d;
  c->r[0] = e;
  c->r[1] = f;
  return 1;
}

int32_t host_update_opacity(int32_t handle, double alpha) {
  Cmd *c = find_command(handle);
  if (c == NULL || c->kind != CMD_EFFECT_PUSH) return 0;
  c->alpha_override = 1;
  c->alpha = alpha;
  return 1;
}

void host_effect_pop(void) { push_cmd()->kind = CMD_EFFECT_POP; }

/**
 * Starts a perspective layer: the commands up to host_perspective_pop() paint the box (x, y, w,
 * h) in its own user space, and the layer is then warped onto `quad` — the box's four projected
 * corners, TL, TR, BR, BL in page space — and composited into the page.
 */
void host_perspective_push(int32_t serial, int32_t pkind, double x, double y, double w, double h,
                           double x0, double y0, double x1, double y1,
                           double x2, double y2, double x3, double y3) {
  Cmd *c = push_cmd();
  c->kind = CMD_PERSPECTIVE_PUSH;
  c->serial = serial; c->pkind = pkind;
  c->x = x;
  c->y = y;
  c->w = w;
  c->h = h;
  c->q[0] = x0; c->q[1] = y0;
  c->q[2] = x1; c->q[3] = y1;
  c->q[4] = x2; c->q[5] = y2;
  c->q[6] = x3; c->q[7] = y3;
}

void host_perspective_pop(void) { push_cmd()->kind = CMD_PERSPECTIVE_POP; }


// ---------------------------------------------------------------------------
// Window

// ---------------------------------------------------------------------------
// Accessibility. The runtime computes the page's accessibility tree from the DOM — the roles
// HTML-AAM and ARIA give its elements, the names accname computes — and hands it over as JSON
// (runtime/ax-tree.ts). Here it becomes NSAccessibilityElements under an AXWebArea, with roles
// and subroles from Core-AAM's macOS mapping, as a browser's page reads to VoiceOver.
//
// Nothing is built until a client asks: the first query of the view, or a client switching
// AXManualAccessibility or AXEnhancedUserInterface on, marks the tree wanted, and the runtime
// builds it from the next frame on. The view has no children until then.
//
// A client's action — a press, a focus, a value written into a field — is queued and handed to
// the runtime on the next poll (EV_AXACTION), which runs it on the element itself; the element
// takes the new value at once, so a client that reads it back sees what it wrote.

/** The action kinds EV_AXACTION carries, as runtime/host.ts has them. */
enum {
  AX_PRESS = 1, AX_FOCUS = 2, AX_SET_VALUE = 3, AX_INSERT_TEXT = 4, AX_SELECT_RANGE = 5,
  AX_INCREMENT = 6, AX_DECREMENT = 7, AX_SHOW_MENU = 8,
};
/** The actions a node takes, as AxNode.actions carries them (runtime/ax-tree.ts). */
enum {
  AXA_PRESS = 1, AXA_FOCUS = 2, AXA_SET_VALUE = 4, AXA_INSERT_TEXT = 8, AXA_INCREMENT = 16,
  AXA_SHOW_MENU = 32,
};

/** Marks the tree wanted: from the next frame on, the runtime builds it and keeps it current. */
static void ax_activate(void) {
  if (g_ax_active) return;
  g_ax_active = 1;
  // Wake the poll, so the frame that builds the tree doesn't wait for other input.
  NSEvent *wake = [NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint
    modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0];
  [NSApp postEvent:wake atStart:NO];
}

/** Queues a client's action for the runtime, which takes it on the next poll. */
static void ax_queue(int kind, NSInteger uid, NSString *text, double x, double y) {
  if (uid == 0) return;
  if (g_ax_queue == nil) g_ax_queue = [NSMutableArray array];
  [g_ax_queue addObject:@{ @"kind": @(kind), @"uid": @(uid), @"text": text ?: @"", @"x": @(x), @"y": @(y) }];
}

/** An element's frame in the coordinates accessibility uses: AppKit's screen space. */
static NSRect ax_screen_rect(NSRect viewRect) {
  // A headless run has no window: the tree is still built, in view coordinates.
  if (g_view == nil || g_window == nil) return viewRect;
  return NSAccessibilityFrameInView(g_view, viewRect);
}

/** The deepest element of a forest whose frame holds a point in screen coordinates, or nil. The
 *  last child that holds it wins, as the one painted on top. */
static id ax_hit(NSArray *list, NSPoint point) {
  for (NSInteger i = (NSInteger)list.count - 1; i >= 0; i--) {
    NSAccessibilityElement *e = list[(NSUInteger)i];
    id inner = ax_hit(e.accessibilityChildren, point);
    if (inner != nil) return inner;
    if (NSPointInRect(point, e.accessibilityFrame)) return e;
  }
  return nil;
}

/** One node of the page's tree. Its attributes are what the runtime's JSON says; a setter a
 *  client calls queues the action for the runtime instead of storing the value. */
@interface NativeAxElement : NSAccessibilityElement
/** The node's box in view coordinates (CSS px from the view's top-left). */
@property (nonatomic, assign) NSRect viewFrame;
/** The node's index in the runtime's last tree, which a value-changed report names. */
@property (nonatomic, assign) NSInteger nodeId;
/** The node's identity across trees, which an action names. */
@property (nonatomic, assign) NSInteger uid;
/** The role the runtime gave the node: an ARIA role, or staticText for a run of text. */
@property (nonatomic, copy) NSString *roleName;
/** What a client may do to the node, as AXA_* bits. */
@property (nonatomic, assign) NSInteger actionBits;
/** Whether the page's focus is here. */
@property (nonatomic, assign) BOOL axFocused;
/** AXValue: a field's text, a checkbox's state, a range's position, a heading's level. */
@property (nonatomic, strong) id axValue;
/** The text a field (or a static text) holds, for the range-based text attributes. */
@property (nonatomic, copy) NSString *axText;
/** A field's selection, in characters. */
@property (nonatomic, assign) NSRange axSelection;
/** The element's id attribute, which AXDOMIdentifier reports. */
@property (nonatomic, copy) NSString *domId;
/** aria-expanded and the selected state: -1 where the state doesn't apply, else 0 or 1. */
@property (nonatomic, assign) int expandedState;
@property (nonatomic, assign) int selectedState;
@property (nonatomic, assign) BOOL requiredState;
@end

/** Whether the node is a text field, whose text, caret and selection a client reads and edits. */
static BOOL ax_is_field(NativeAxElement *e) {
  NSString *r = e.accessibilityRole;
  return [r isEqualToString:NSAccessibilityTextFieldRole] || [r isEqualToString:NSAccessibilityTextAreaRole] ||
    [r isEqualToString:NSAccessibilityComboBoxRole];
}

@implementation NativeAxElement
- (NSRect)accessibilityFrame { return ax_screen_rect(self.viewFrame); }
- (id)accessibilityValue { return self.axValue; }
- (BOOL)isAccessibilityFocused { return self.axFocused; }
- (NSRange)accessibilitySelectedTextRange { return self.axSelection; }
- (NSInteger)accessibilityNumberOfCharacters { return (NSInteger)self.axText.length; }
- (NSRange)accessibilityVisibleCharacterRange { return NSMakeRange(0, self.axText.length); }
- (BOOL)isAccessibilityExpanded { return self.expandedState == 1; }
- (BOOL)isAccessibilitySelected { return self.selectedState == 1; }
- (BOOL)isAccessibilityRequired { return self.requiredState; }

/** The selectors a node answers depend on what it is: a press only where the page takes one, the
 *  text attributes only on a field or a static text, a writable value only in a field that takes
 *  text. Everything else is NSAccessibilityElement's. */
- (BOOL)isAccessibilitySelectorAllowed:(SEL)selector {
  if (selector == @selector(accessibilityPerformPress)) return (self.actionBits & AXA_PRESS) != 0;
  if (selector == @selector(setAccessibilityFocused:)) return (self.actionBits & AXA_FOCUS) != 0;
  if (selector == @selector(setAccessibilityValue:)) return (self.actionBits & AXA_SET_VALUE) != 0;
  if (selector == @selector(setAccessibilitySelectedText:) ||
      selector == @selector(setAccessibilitySelectedTextRange:)) return (self.actionBits & AXA_INSERT_TEXT) != 0;
  if (selector == @selector(accessibilityPerformIncrement) ||
      selector == @selector(accessibilityPerformDecrement)) return (self.actionBits & AXA_INCREMENT) != 0;
  if (selector == @selector(accessibilityPerformShowMenu)) return (self.actionBits & AXA_SHOW_MENU) != 0;
  // A state the element doesn't have isn't reported as false: it isn't there at all.
  if (selector == @selector(isAccessibilityExpanded)) return self.expandedState >= 0;
  if (selector == @selector(isAccessibilitySelected)) return self.selectedState >= 0;
  if (selector == @selector(isAccessibilityRequired)) return self.requiredState;
  BOOL text = ax_is_field(self) || [self.accessibilityRole isEqualToString:NSAccessibilityStaticTextRole];
  if (selector == @selector(accessibilitySelectedText) || selector == @selector(accessibilitySelectedTextRange) ||
      selector == @selector(accessibilityInsertionPointLineNumber)) return ax_is_field(self);
  if (selector == @selector(accessibilityNumberOfCharacters) || selector == @selector(accessibilityVisibleCharacterRange) ||
      selector == @selector(accessibilityStringForRange:) || selector == @selector(accessibilityLineForIndex:) ||
      selector == @selector(accessibilityRangeForLine:)) return text;
  return [super isAccessibilitySelectorAllowed:selector];
}

- (BOOL)accessibilityPerformPress {
  ax_queue(AX_PRESS, self.uid, nil, 0, 0);
  return YES;
}
- (BOOL)accessibilityPerformIncrement {
  ax_queue(AX_INCREMENT, self.uid, nil, 0, 0);
  return YES;
}
- (BOOL)accessibilityPerformDecrement {
  ax_queue(AX_DECREMENT, self.uid, nil, 0, 0);
  return YES;
}
- (BOOL)accessibilityPerformShowMenu {
  ax_queue(AX_SHOW_MENU, self.uid, nil, 0, 0);
  return YES;
}
- (void)setAccessibilityFocused:(BOOL)focused {
  if (!focused) return;
  ax_queue(AX_FOCUS, self.uid, nil, 0, 0);
  self.axFocused = YES;
}
/** A client writing AXValue: a field takes the text as its whole value, a range the number. */
- (void)setAccessibilityValue:(id)value {
  NSString *text = [value isKindOfClass:[NSString class]] ? value :
    [value respondsToSelector:@selector(stringValue)] ? [value stringValue] : nil;
  if (text == nil) return;
  ax_queue(AX_SET_VALUE, self.uid, text, 0, 0);
  self.axValue = [value isKindOfClass:[NSString class]] ? text : value;
  if (ax_is_field(self)) {
    self.axText = text;
    self.axSelection = NSMakeRange(text.length, 0);
  }
}
/** A client writing AXSelectedText: the text replaces the selection, as typing it would. */
- (void)setAccessibilitySelectedText:(NSString *)text {
  if (![text isKindOfClass:[NSString class]]) return;
  ax_queue(AX_INSERT_TEXT, self.uid, text, 0, 0);
  NSString *was = self.axText ?: @"";
  NSRange sel = self.axSelection;
  if (sel.location > was.length) sel = NSMakeRange(was.length, 0);
  if (NSMaxRange(sel) > was.length) sel.length = was.length - sel.location;
  NSString *now = [was stringByReplacingCharactersInRange:sel withString:text];
  self.axText = now;
  self.axValue = now;
  self.axSelection = NSMakeRange(sel.location + text.length, 0);
}
- (void)setAccessibilitySelectedTextRange:(NSRange)range {
  ax_queue(AX_SELECT_RANGE, self.uid, nil, (double)range.location, (double)range.length);
  self.axSelection = range;
}
/** The characters a range covers, for VoiceOver's text navigation. */
- (NSString *)accessibilityStringForRange:(NSRange)range {
  if (self.axText == nil || range.location >= self.axText.length) return @"";
  NSUInteger len = MIN(range.length, self.axText.length - range.location);
  return [self.axText substringWithRange:NSMakeRange(range.location, len)];
}
/** The line the character at `index` sits on. */
- (NSInteger)accessibilityLineForIndex:(NSInteger)index {
  if (self.axText == nil) return 0;
  NSInteger line = 0;
  NSUInteger at = MIN((NSUInteger)MAX(index, 0), self.axText.length);
  for (NSUInteger i = 0; i < at; i++) if ([self.axText characterAtIndex:i] == '\n') line++;
  return line;
}
- (NSInteger)accessibilityInsertionPointLineNumber {
  return [self accessibilityLineForIndex:(NSInteger)self.axSelection.location];
}
/** The character range of one line. */
- (NSRange)accessibilityRangeForLine:(NSInteger)line {
  if (self.axText == nil) return NSMakeRange(0, 0);
  NSInteger at = 0;
  NSUInteger start = 0;
  while (start < self.axText.length && at < line) {
    if ([self.axText characterAtIndex:start] == '\n') at++;
    start++;
  }
  if (at < line) return NSMakeRange(0, 0);
  NSUInteger end = start;
  while (end < self.axText.length && [self.axText characterAtIndex:end] != '\n') end++;
  return NSMakeRange(start, end - start);
}
/** The selected characters, read from the range the tree carries. */
- (NSString *)accessibilitySelectedText {
  return [self accessibilityStringForRange:self.axSelection];
}
- (id)accessibilityHitTest:(NSPoint)point {
  id inner = ax_hit(self.accessibilityChildren, point);
  return inner != nil ? inner : self;
}

// AXDOMIdentifier, as a browser's page reports an element's id: the protocol has no property for
// it, so it goes through the attribute API AppKit still asks.
- (NSArray *)accessibilityAttributeNames {
  NSArray *names = [super accessibilityAttributeNames];
  return self.domId.length > 0 ? [names arrayByAddingObject:@"AXDOMIdentifier"] : names;
}
- (id)accessibilityAttributeValue:(NSString *)attribute {
  if ([attribute isEqualToString:@"AXDOMIdentifier"]) return self.domId.length > 0 ? self.domId : nil;
  return [super accessibilityAttributeValue:attribute];
}
/** AppKit counts an attribute settable when the class has its setter, whatever the selector
 *  check says, so the writable attributes are decided here, by what the node takes. */
- (BOOL)accessibilityIsAttributeSettable:(NSString *)attribute {
  if ([attribute isEqualToString:NSAccessibilityValueAttribute]) return (self.actionBits & AXA_SET_VALUE) != 0;
  if ([attribute isEqualToString:NSAccessibilityFocusedAttribute]) return (self.actionBits & AXA_FOCUS) != 0;
  if ([attribute isEqualToString:NSAccessibilitySelectedTextAttribute] ||
      [attribute isEqualToString:NSAccessibilitySelectedTextRangeAttribute]) return (self.actionBits & AXA_INSERT_TEXT) != 0;
  return [super accessibilityIsAttributeSettable:attribute];
}
@end

/** The page itself: AXWebArea, the root a client finds the page's elements under. */
@interface NativeAxWebArea : NSAccessibilityElement
@end

@implementation NativeAxWebArea
- (NSRect)accessibilityFrame {
  return g_view == nil ? NSZeroRect : ax_screen_rect(g_view.bounds);
}
- (NSString *)accessibilityTitle { return g_win_title; }
- (NSString *)accessibilityLabel { return g_win_title; }
- (BOOL)isAccessibilityFocused { return g_ax_focused_id == 0; }
- (id)accessibilityHitTest:(NSPoint)point {
  id inner = ax_hit(self.accessibilityChildren, point);
  return inner != nil ? inner : self;
}
- (NSArray *)accessibilityAttributeNames {
  return [[super accessibilityAttributeNames] arrayByAddingObject:@"AXLoaded"];
}
- (id)accessibilityAttributeValue:(NSString *)attribute {
  if ([attribute isEqualToString:@"AXLoaded"]) return @YES;
  return [super accessibilityAttributeValue:attribute];
}
@end

/** The AppKit role (and subrole) an ARIA role maps to, as Core-AAM gives it for macOS. */
static NSString *ax_role(NSString *role, NSDictionary *node, NSString **subrole) {
  *subrole = nil;
  BOOL multiline = [node[@"multiline"] boolValue];
  if ([role isEqualToString:@"staticText"]) return NSAccessibilityStaticTextRole;
  if ([role isEqualToString:@"button"]) {
    // A toggle button (aria-pressed) is a checkbox with the toggle subrole.
    if ([node[@"pressed"] intValue] >= 0) { *subrole = NSAccessibilityToggleSubrole; return NSAccessibilityCheckBoxRole; }
    return NSAccessibilityButtonRole;
  }
  if ([role isEqualToString:@"link"]) return NSAccessibilityLinkRole;
  if ([role isEqualToString:@"checkbox"]) return NSAccessibilityCheckBoxRole;
  if ([role isEqualToString:@"switch"]) { *subrole = NSAccessibilitySwitchSubrole; return NSAccessibilityCheckBoxRole; }
  if ([role isEqualToString:@"radio"]) return NSAccessibilityRadioButtonRole;
  if ([role isEqualToString:@"radiogroup"]) return NSAccessibilityRadioGroupRole;
  if ([role isEqualToString:@"textbox"]) return multiline ? NSAccessibilityTextAreaRole : NSAccessibilityTextFieldRole;
  if ([role isEqualToString:@"searchbox"]) { *subrole = NSAccessibilitySearchFieldSubrole; return NSAccessibilityTextFieldRole; }
  if ([role isEqualToString:@"spinbutton"]) return NSAccessibilityIncrementorRole;
  // HTML-AAM: a select that shows one option is a pop-up button; an ARIA combobox is a combo box.
  if ([role isEqualToString:@"combobox"]) {
    return [node[@"actions"] intValue] & AXA_INSERT_TEXT ? NSAccessibilityComboBoxRole : NSAccessibilityPopUpButtonRole;
  }
  if ([role isEqualToString:@"listbox"]) return NSAccessibilityListRole;
  if ([role isEqualToString:@"option"]) return NSAccessibilityStaticTextRole;
  if ([role isEqualToString:@"list"]) { *subrole = NSAccessibilityContentListSubrole; return NSAccessibilityListRole; }
  if ([role isEqualToString:@"listitem"]) return NSAccessibilityGroupRole;
  if ([role isEqualToString:@"table"] || [role isEqualToString:@"grid"] || [role isEqualToString:@"treegrid"]) return NSAccessibilityTableRole;
  if ([role isEqualToString:@"row"]) return NSAccessibilityRowRole;
  if ([role isEqualToString:@"cell"] || [role isEqualToString:@"gridcell"] ||
      [role isEqualToString:@"columnheader"] || [role isEqualToString:@"rowheader"]) return NSAccessibilityCellRole;
  if ([role isEqualToString:@"img"] || [role isEqualToString:@"image"]) return NSAccessibilityImageRole;
  if ([role isEqualToString:@"slider"]) return NSAccessibilitySliderRole;
  if ([role isEqualToString:@"progressbar"]) return NSAccessibilityProgressIndicatorRole;
  if ([role isEqualToString:@"meter"]) return NSAccessibilityLevelIndicatorRole;
  if ([role isEqualToString:@"scrollbar"]) return NSAccessibilityScrollBarRole;
  if ([role isEqualToString:@"separator"]) return NSAccessibilitySplitterRole;
  if ([role isEqualToString:@"menu"]) return NSAccessibilityMenuRole;
  if ([role isEqualToString:@"menubar"]) return NSAccessibilityMenuBarRole;
  if ([role isEqualToString:@"menuitem"] || [role isEqualToString:@"menuitemcheckbox"] ||
      [role isEqualToString:@"menuitemradio"]) return NSAccessibilityMenuItemRole;
  if ([role isEqualToString:@"tab"]) { *subrole = NSAccessibilityTabButtonSubrole; return NSAccessibilityRadioButtonRole; }
  if ([role isEqualToString:@"tablist"]) return NSAccessibilityTabGroupRole;
  if ([role isEqualToString:@"tabpanel"]) { *subrole = @"AXTabPanel"; return NSAccessibilityGroupRole; }
  if ([role isEqualToString:@"tree"]) return NSAccessibilityOutlineRole;
  if ([role isEqualToString:@"treeitem"]) { *subrole = NSAccessibilityOutlineRowSubrole; return NSAccessibilityRowRole; }
  if ([role isEqualToString:@"toolbar"]) return NSAccessibilityToolbarRole;
  if ([role isEqualToString:@"heading"]) return @"AXHeading";
  struct { const char *role, *subrole; } grouped[] = {
    { "alert", "AXApplicationAlert" }, { "alertdialog", "AXApplicationAlertDialog" },
    { "dialog", "AXApplicationDialog" }, { "log", "AXApplicationLog" },
    { "marquee", "AXApplicationMarquee" }, { "status", "AXApplicationStatus" },
    { "timer", "AXApplicationTimer" }, { "article", "AXDocumentArticle" },
    { "document", "AXDocument" }, { "math", "AXDocumentMath" }, { "note", "AXDocumentNote" },
    { "definition", "AXDefinition" }, { "term", "AXTerm" }, { "tooltip", "AXUserInterfaceTooltip" },
    { "banner", "AXLandmarkBanner" }, { "complementary", "AXLandmarkComplementary" },
    { "contentinfo", "AXLandmarkContentInfo" }, { "form", "AXLandmarkForm" },
    { "main", "AXLandmarkMain" }, { "navigation", "AXLandmarkNavigation" },
    { "region", "AXLandmarkRegion" }, { "search", "AXLandmarkSearch" },
  };
  for (size_t i = 0; i < sizeof grouped / sizeof grouped[0]; i++) {
    if ([role isEqualToString:@(grouped[i].role)]) { *subrole = @(grouped[i].subrole); break; }
  }
  return NSAccessibilityGroupRole;
}

/** Gives a table its rows and each row's cells their row and column indices, which is how a
 *  screen reader moves around a table. */
static void ax_index_tables(NSArray *list) {
  for (NativeAxElement *e in list) {
    if ([e.accessibilityRole isEqualToString:NSAccessibilityTableRole]) {
      NSMutableArray *rows = [NSMutableArray array];
      NSInteger ri = 0;
      for (NativeAxElement *r in e.accessibilityChildren) {
        if (![r.accessibilityRole isEqualToString:NSAccessibilityRowRole]) continue;
        r.accessibilityIndex = ri;
        NSInteger ci = 0;
        for (NativeAxElement *c in r.accessibilityChildren) {
          if (![c.accessibilityRole isEqualToString:NSAccessibilityCellRole]) continue;
          c.accessibilityRowIndexRange = NSMakeRange((NSUInteger)ri, 1);
          c.accessibilityColumnIndexRange = NSMakeRange((NSUInteger)ci, 1);
          ci++;
        }
        [rows addObject:r];
        ri++;
      }
      e.accessibilityRows = rows;
    }
    ax_index_tables(e.accessibilityChildren);
  }
}

static NSString *ax_string(id v) { return [v isKindOfClass:[NSString class]] ? v : @""; }

/**
 * Brings the elements in line with the runtime's latest JSON. An element whose node is still in
 * the tree with the same role is the same object as before, so a client holding it keeps a live
 * reference; one whose node left is told it was destroyed.
 */
static void ax_rebuild(void) {
  NSData *data = [g_ax_json dataUsingEncoding:NSUTF8StringEncoding];
  id parsed = data == nil ? nil : [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  NSArray *nodes = [parsed isKindOfClass:[NSArray class]] ? parsed : @[];
  if (g_ax_web_area == nil) {
    g_ax_web_area = [[NativeAxWebArea alloc] init];
    g_ax_web_area.accessibilityRole = @"AXWebArea";
    g_ax_web_area.accessibilityRoleDescription = @"HTML content";
    g_ax_web_area.accessibilityEnabled = YES;
  }
  // The view keeps out of the tree itself, so the web area's parent is the first element above it.
  g_ax_web_area.accessibilityParent = g_view != nil ? NSAccessibilityUnignoredAncestor(g_view) : nil;
  NSMutableDictionary *was = g_ax_by_uid ?: [NSMutableDictionary dictionary];
  NSMutableDictionary *now = [NSMutableDictionary dictionaryWithCapacity:nodes.count];
  NSUInteger n = nodes.count;
  NSMutableArray *made = [NSMutableArray arrayWithCapacity:n];
  NSMutableArray *kids = [NSMutableArray arrayWithCapacity:n];
  for (NSUInteger i = 0; i < n; i++) {
    [made addObject:[NSNull null]];
    [kids addObject:[NSMutableArray array]];
  }
  NSMutableArray *roots = [NSMutableArray array];
  for (NSUInteger i = 0; i < n; i++) {
    NSDictionary *node = nodes[i];
    if (![node isKindOfClass:[NSDictionary class]]) continue;
    NSString *roleName = [node[@"role"] isKindOfClass:[NSString class]] ? node[@"role"] : @"generic";
    NSString *subrole = nil;
    NSString *role = ax_role(roleName, node, &subrole);
    NSInteger uid = [node[@"uid"] integerValue];
    NativeAxElement *e = uid != 0 ? was[@(uid)] : nil;
    if (e != nil && (![e.accessibilityRole isEqualToString:role] || now[@(uid)] != nil)) e = nil;
    if (e == nil) e = [[NativeAxElement alloc] init];
    if (uid != 0) {
      now[@(uid)] = e;
      [was removeObjectForKey:@(uid)];
    }
    e.uid = uid;
    e.nodeId = (NSInteger)i + 1;
    e.roleName = roleName;
    e.accessibilityRole = role;
    e.accessibilitySubrole = subrole;
    NSString *roleDescription = ax_string(node[@"roleDescription"]);
    e.accessibilityRoleDescription = roleDescription.length > 0 ? roleDescription :
      NSAccessibilityRoleDescription(role, subrole);
    NSString *label = ax_string(node[@"label"]);
    NSString *value = ax_string(node[@"value"]);
    BOOL field = ax_is_field(e);
    // AXTitle is the name a client reads; AXDescription carries it too, as a browser's page does
    // for an element named by aria-label. A static text's words are its value.
    e.accessibilityLabel = label.length > 0 ? label : nil;
    e.accessibilityTitle = label.length > 0 ? label : nil;
    e.accessibilityHelp = ax_string(node[@"description"]).length > 0 ? node[@"description"] : nil;
    e.accessibilityPlaceholderValue = ax_string(node[@"placeholder"]).length > 0 ? node[@"placeholder"] : nil;
    NSString *url = ax_string(node[@"url"]);
    e.accessibilityURL = url.length > 0 ? [NSURL URLWithString:url] : nil;
    e.domId = ax_string(node[@"domId"]);
    int checked = [node[@"checked"] intValue];
    id axValue = nil;
    if ([roleName isEqualToString:@"staticText"] || [roleName isEqualToString:@"option"]) axValue = label;
    else if (field) axValue = value;
    else if ([role isEqualToString:NSAccessibilityCheckBoxRole] || [role isEqualToString:NSAccessibilityRadioButtonRole]) {
      // A checkbox's value is 0, 1, or 2 for mixed; a toggle button's is its pressed state.
      int pressed = [node[@"pressed"] intValue];
      if (pressed >= 0) axValue = @(pressed);
      else if ([node[@"mixed"] boolValue]) axValue = @2;
      else if ([roleName isEqualToString:@"tab"]) axValue = @([node[@"selected"] intValue] == 1 ? 1 : 0);
      else axValue = @(checked == 1 ? 1 : 0);
    } else if ([role isEqualToString:@"AXHeading"]) axValue = @([node[@"level"] intValue]);
    else if ([node[@"valueNow"] isKindOfClass:[NSNumber class]]) axValue = node[@"valueNow"];
    else if (value.length > 0) axValue = value;
    e.axValue = axValue;
    e.accessibilityMinValue = [node[@"valueMin"] isKindOfClass:[NSNumber class]] ? node[@"valueMin"] : nil;
    e.accessibilityMaxValue = [node[@"valueMax"] isKindOfClass:[NSNumber class]] ? node[@"valueMax"] : nil;
    e.axText = field ? value : label;
    NSInteger s0 = [node[@"selStart"] integerValue], s1 = [node[@"selEnd"] integerValue];
    e.axSelection = s0 >= 0 ? NSMakeRange((NSUInteger)s0, (NSUInteger)(s1 > s0 ? s1 - s0 : 0)) : NSMakeRange(0, 0);
    e.accessibilityEnabled = [node[@"disabled"] boolValue] ? NO : YES;
    e.requiredState = [node[@"required"] boolValue];
    e.expandedState = [node[@"expanded"] intValue];
    e.selectedState = [node[@"selected"] intValue];
    e.actionBits = [node[@"actions"] integerValue];
    e.axFocused = [node[@"focused"] boolValue];
    e.viewFrame = NSMakeRect([node[@"x"] doubleValue], [node[@"y"] doubleValue],
      [node[@"w"] doubleValue], [node[@"h"] doubleValue]);
    made[i] = e;
    NSInteger parent = [node[@"parent"] integerValue];
    if (parent > 0 && (NSUInteger)parent <= n && [made[(NSUInteger)parent - 1] isKindOfClass:[NativeAxElement class]]) {
      e.accessibilityParent = made[(NSUInteger)parent - 1];
      [kids[(NSUInteger)parent - 1] addObject:e];
    } else {
      e.accessibilityParent = g_ax_web_area;
      [roots addObject:e];
    }
  }
  for (NSUInteger i = 0; i < n; i++) {
    if (![made[i] isKindOfClass:[NativeAxElement class]]) continue;
    [(NativeAxElement *)made[i] setAccessibilityChildren:kids[i]];
  }
  ax_index_tables(roots);
  g_ax_web_area.accessibilityChildren = roots;
  g_ax_roots = roots;
  g_ax_by_uid = now;
  // The nodes that left the page: a client holding one learns it is gone.
  if (g_view != nil) {
    for (NativeAxElement *gone in was.allValues) {
      NSAccessibilityPostNotification(gone, NSAccessibilityUIElementDestroyedNotification);
    }
  }
}

/** The web area once a tree has arrived, as the view's one child; nothing before that. */
static NSArray *ax_children(void) {
  ax_activate();
  return g_ax_web_area != nil ? @[ g_ax_web_area ] : @[];
}

@interface NativeView : NSView <NSTextInputClient>
@end

// The display's period in milliseconds, and how long until its next refresh, both read from the
// display link; zero until a window with a screen exists.
static double g_refresh_ms = 0;
// The display's next target refresh, on CACurrentMediaTime's clock. A window that doesn't present
// through GL starts its frames on this cadence; a GL window's own swap already waits for it.
static double g_next_target = 0;
// The display link itself, kept for as long as the window: it fires on the main run loop.
static id g_display_link = nil;

double host_refresh_interval(void) { return g_refresh_ms; }
double host_until_refresh(void) {
  double until = g_next_target - CACurrentMediaTime();
  return until > 0 ? until * 1000.0 : 0;
}

/** Whether a canvas in the window presents through GL, whose swap waits for the display itself. */
int32_t host_gl_window(void) {
  for (int i = 0; i < g_canvas_count; i++) {
    Canvas *c = g_canvases[i];
    if (c != NULL && c->gl != NULL) return 1;
  }
  return 0;
}

@implementation NativeView
- (void)refreshTick:(id)link {
  // The link's timestamps are on CACurrentMediaTime's clock. The period it reports is the
  // display's own, so a ProMotion panel gives 8.3 ms and a fixed one 16.7.
  if (@available(macOS 14.0, *)) {
    CADisplayLink *dl = (CADisplayLink *)link;
    double period = dl.targetTimestamp - dl.timestamp;
    if (period > 0 && period < 0.1) g_refresh_ms = period * 1000.0;
    g_next_target = dl.targetTimestamp;
  }
}
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

// ---------------------------------------------------------------------------
// Files dragged in from outside the app
//
// A page decides what it takes with its dragenter and dragover handlers, but those run in the
// runtime, which a drag session can't wait for: the window accepts file URLs as a copy, and the
// runtime then fires dragenter, dragover and drop at the point the drag landed and drops the copy
// if the page doesn't take it. A drag of anything else — text, an image — is refused.

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self != nil) [self registerForDraggedTypes:@[ NSPasteboardTypeFileURL ]];
  return self;
}

/** The files a drag carries, or nil when it carries none. */
static NSArray<NSURL *> *dragged_file_urls(id<NSDraggingInfo> sender) {
  NSArray *urls = [sender.draggingPasteboard readObjectsForClasses:@[ [NSURL class] ]
                                                           options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }];
  if (urls == nil) return nil;
  NSMutableArray<NSURL *> *files = [NSMutableArray array];
  for (id u in urls) if ([u isKindOfClass:[NSURL class]] && ((NSURL *)u).path != nil) [files addObject:u];
  return files.count > 0 ? files : nil;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
  return dragged_file_urls(sender) != nil ? NSDragOperationCopy : NSDragOperationNone;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
  return dragged_file_urls(sender) != nil ? NSDragOperationCopy : NSDragOperationNone;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
  NSArray<NSURL *> *files = dragged_file_urls(sender);
  if (files == nil) return NO;
  NSMutableArray<NSString *> *paths = [NSMutableArray array];
  for (NSURL *u in files) [paths addObject:u.path];
  g_drop_files = paths;
  // The view is flipped, so the point is in CSS pixels from the window's top left.
  NSPoint p = [self convertPoint:sender.draggingLocation fromView:nil];
  g_ex = p.x;
  g_ey = p.y;
  g_drop_pending = 1;
  return YES;
}
// The view is a container, not a stop of its own: the elements the page exposes are its children.
- (BOOL)isAccessibilityElement { return NO; }
- (NSArray *)accessibilityChildren { return ax_children(); }
- (NSArray *)accessibilityChildrenInNavigationOrder { return ax_children(); }
- (id)accessibilityHitTest:(NSPoint)point {
  ax_activate();
  return g_ax_web_area != nil ? [g_ax_web_area accessibilityHitTest:point] : self;
}
- (id)accessibilityFocusedUIElement {
  ax_activate();
  if (g_ax_web_area == nil) return self;
  NSAccessibilityElement *focused = g_ax_focused_id != 0 ? g_ax_by_uid[@(g_ax_focused_id)] : nil;
  return focused != nil ? focused : g_ax_web_area;
}
- (void)drawRect:(NSRect)dirtyRect {
  CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
  double started = frame_times() ? now_ms() : 0;
  int saved = g_layer_images_on;
  g_layer_images_on = 1;
  replay(ctx, self.bounds.size.width, self.bounds.size.height);
  g_layer_images_on = saved;
  if (frame_times()) {
    g_last_replay_ms = now_ms() - started;
    log_window_font_info(ctx);
  }
}
/**
 * A cursor drawn here, for a keyword macOS has no public cursor for: help, progress, wait, move,
 * all-scroll and zoom in and out. The image is 24x24 and the hot spot is its centre, since none
 * of these is a pointer.
 */
static NSCursor *drawn_cursor(int kind) {
  static NSCursor *cache[64];
  if (kind >= 0 && kind < 64 && cache[kind] != nil) return cache[kind];
  NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(24, 24)];
  [img lockFocus];
  [[NSColor whiteColor] set];
  NSRectFill(NSMakeRect(0, 0, 24, 24));
  NSBezierPath *disc = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(4, 4, 16, 16)];
  NSBezierPath *shape = [NSBezierPath bezierPath];
  if (kind == 4) {
    // help: a disc with a question mark
    [[NSColor whiteColor] set];
    [disc setLineWidth:9];
    [disc stroke];
    [[NSColor blackColor] set];
    [disc setLineWidth:5];
    [disc stroke];
    NSString *q = @"?";
    NSDictionary *attrs = @{ NSFontAttributeName: [NSFont boldSystemFontOfSize:13],
                             NSForegroundColorAttributeName: [NSColor blackColor] };
    NSSize sz = [q sizeWithAttributes:attrs];
    [q drawAtPoint:NSMakePoint(12 - sz.width / 2, 12 - sz.height / 2 + 1) withAttributes:attrs];
  } else if (kind == 5 || kind == 6) {
    // progress and wait: a ring, and for wait a hand at a quarter past
    [[NSColor whiteColor] set];
    [disc setLineWidth:9];
    [disc stroke];
    [[NSColor blackColor] set];
    [disc setLineWidth:5];
    [disc stroke];
    if (kind == 6) {
      NSBezierPath *hands = [NSBezierPath bezierPath];
      [hands moveToPoint:NSMakePoint(12, 12)];
      [hands lineToPoint:NSMakePoint(12, 17)];
      [hands moveToPoint:NSMakePoint(12, 12)];
      [hands lineToPoint:NSMakePoint(16, 12)];
      [hands setLineWidth:2];
      [hands setLineCapStyle:NSLineCapStyleRound];
      [hands stroke];
    }
  } else if (kind == 12 || kind == 17) {
    // move and all-scroll: four arrows meeting in the middle
    const NSPoint up[3] = { {12, 3}, {8, 9}, {16, 9} };
    const NSPoint down[3] = { {12, 21}, {8, 15}, {16, 15} };
    const NSPoint left[3] = { {3, 12}, {9, 8}, {9, 16} };
    const NSPoint right[3] = { {21, 12}, {15, 8}, {15, 16} };
    const NSPoint *tri[4] = { up, down, left, right };
    for (int t = 0; t < 4; t++) {
      [shape moveToPoint:tri[t][0]];
      [shape lineToPoint:tri[t][1]];
      [shape lineToPoint:tri[t][2]];
      [shape closePath];
    }
    [shape appendBezierPathWithRect:NSMakeRect(10.5, 5, 3, 14)];
    [shape appendBezierPathWithRect:NSMakeRect(5, 10.5, 14, 3)];
  } else if (kind == 32 || kind == 33) {
    // zoom in and out: a magnifier with a plus or a minus in its lens
    NSBezierPath *lens = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(3, 9, 12, 12)];
    NSBezierPath *handle = [NSBezierPath bezierPath];
    [handle moveToPoint:NSMakePoint(13.5, 9.5)];
    [handle lineToPoint:NSMakePoint(20, 3)];
    [handle setLineWidth:3];
    [[NSColor whiteColor] set];
    [lens setLineWidth:8];
    [lens stroke];
    [handle setLineWidth:7];
    [handle stroke];
    [[NSColor blackColor] set];
    [lens setLineWidth:3];
    [lens stroke];
    [handle setLineWidth:3];
    [handle stroke];
    NSBezierPath *mark = [NSBezierPath bezierPath];
    [mark moveToPoint:NSMakePoint(6, 15)];
    [mark lineToPoint:NSMakePoint(12, 15)];
    if (kind == 32) {
      [mark moveToPoint:NSMakePoint(9, 12)];
      [mark lineToPoint:NSMakePoint(9, 18)];
    }
    [mark setLineWidth:2];
    [mark setLineCapStyle:NSLineCapStyleRound];
    [mark stroke];
  }
  if ([shape elementCount] > 0) {
    [[NSColor whiteColor] set];
    [shape setLineWidth:4];
    [shape stroke];
    [[NSColor blackColor] set];
    [shape fill];
    [shape setLineWidth:1.5];
    [shape stroke];
  }
  [img unlockFocus];
  NSCursor *c = [[NSCursor alloc] initWithImage:img hotSpot:NSMakePoint(12, 12)];
  if (kind >= 0 && kind < 64) cache[kind] = c;
  return c;
}

/**
 * The cursor a CSS cursor keyword asks for (see C_* in shared/props.ts). macOS has no public
 * cursor for some of them — help, progress, wait, move, all-scroll, the corners and zoom — so
 * those it has none for are drawn here (drawn_cursor) and the corners take the closest one it
 * does have.
 */
static NSCursor *cursor_for(int kind) {
  switch (kind) {
    case 1: return [NSCursor pointingHandCursor];
    case 2: return [NSCursor IBeamCursor];
    case 3: return [NSCursor contextualMenuCursor];
    case 7: case 8: return [NSCursor crosshairCursor];
    case 9: return [NSCursor IBeamCursorForVerticalLayout];
    case 10: return [NSCursor dragLinkCursor];
    case 11: return [NSCursor dragCopyCursor];
    case 4: case 5: case 6: case 32: case 33: return drawn_cursor(kind);
    case 12: case 17: return drawn_cursor(kind);
    case 15: return [NSCursor openHandCursor];
    case 16: return [NSCursor closedHandCursor];
    case 13: case 14: return [NSCursor operationNotAllowedCursor];
    case 18: return [NSCursor resizeLeftRightCursor];
    case 19: return [NSCursor resizeUpDownCursor];
    case 20: case 24: case 25: return [NSCursor resizeUpCursor];
    case 22: case 26: case 27: return [NSCursor resizeDownCursor];
    case 21: return [NSCursor resizeRightCursor];
    case 23: return [NSCursor resizeLeftCursor];
    case 28: return [NSCursor resizeLeftRightCursor];
    case 29: return [NSCursor resizeUpDownCursor];
    case 30: return [NSCursor resizeUpDownCursor];
    case 31: return [NSCursor resizeLeftRightCursor];
    default: return [NSCursor arrowCursor];
  }
}

- (void)resetCursorRects {
  [self addCursorRect:self.bounds cursor:g_cursor_image != nil ? g_cursor_image : cursor_for(g_cursor)];
}
- (void)updateTrackingAreas {
  for (NSTrackingArea *a in self.trackingAreas) [self removeTrackingArea:a];
  [self addTrackingArea:[[NSTrackingArea alloc]
                            initWithRect:NSZeroRect
                                 options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                                         NSTrackingActiveAlways | NSTrackingInVisibleRect
                                   owner:self
                                userInfo:nil]];
  [super updateTrackingAreas];
}

// ---------------------------------------------------------------------------
// Text input and input methods
//
// A key that isn't a shortcut goes through AppKit's input client, so a keyboard layout, dead keys
// and an input method's marked text and candidate window all behave as they do in a native text
// view. Each callback hands the runtime a composition event (the marked text, or the text that was
// committed) or a key; the page draws the marked text, since it holds it in the field's value.

/** Queues a composition event with AppKit's phase numbers. */
static void queue_compose(int32_t phase, NSString *text) {
  g_compose_phase = phase;
  g_compose_text = text != nil ? [text copy] : @"";
}

/** Queues a plain key with its text, for a layout that produced text without a composition. The
 *  text is copied: the runtime reads it after this event loop's pool has drained, and AppKit owns
 *  the string it handed the input client. */
static void queue_key_text(NSString *text) {
  g_key = KEY_TEXT;
  g_key_text = text != nil ? [text copy] : @"";
  g_key_pending = 1;
}

- (BOOL)hasMarkedText { return g_marked_text != nil && g_marked_text.length > 0; }

- (NSRange)markedRange {
  return g_marked_text != nil ? NSMakeRange(0, g_marked_text.length) : NSMakeRange(NSNotFound, 0);
}

- (NSRange)selectedRange { return NSMakeRange(g_marked_text != nil ? g_marked_text.length : 0, 0); }

- (void)setMarkedText:(id)string selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange {
  (void)selectedRange;
  (void)replacementRange;
  NSString *text = [string isKindOfClass:[NSAttributedString class]] ? [(NSAttributedString *)string string] : (NSString *)string;
  if (text == nil) text = @"";
  // An input method that has nothing marked any more has abandoned the composition.
  if (text.length == 0) {
    if (g_marked_text != nil) {
      queue_compose(3, g_marked_text);
      g_marked_text = nil;
    }
    return;
  }
  int32_t phase = g_marked_text == nil ? 0 : 1;
  g_marked_text = [text copy];
  queue_compose(phase, text);
}

- (void)unmarkText {
  if (g_marked_text == nil) return;
  queue_compose(3, g_marked_text);
  g_marked_text = nil;
}

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
  (void)replacementRange;
  NSString *text = [string isKindOfClass:[NSAttributedString class]] ? [(NSAttributedString *)string string] : (NSString *)string;
  if (text == nil) text = @"";
  // Text typed while a composition is showing is its commit; text typed without one is the key.
  if (g_marked_text != nil) {
    queue_compose(2, text);
    g_marked_text = nil;
  } else {
    queue_key_text(text);
  }
}

- (void)insertText:(id)string {
  [self insertText:string replacementRange:NSMakeRange(NSNotFound, 0)];
}

- (void)doCommandBySelector:(SEL)selector {
  int32_t code = KEY_OTHER;
  if (selector == @selector(deleteBackward:)) code = KEY_BACKSPACE;
  else if (selector == @selector(deleteForward:)) code = KEY_DELETE;
  else if (selector == @selector(deleteWordBackward:)) code = KEY_BACKSPACE;
  else if (selector == @selector(deleteWordForward:)) code = KEY_DELETE;
  else if (selector == @selector(insertNewline:) || selector == @selector(insertNewlineIgnoringFieldEditor:)) code = KEY_ENTER;
  else if (selector == @selector(insertTab:)) code = KEY_TAB;
  else if (selector == @selector(insertBacktab:)) { g_mods |= MOD_SHIFT; code = KEY_TAB; }
  else if (selector == @selector(cancelOperation:)) code = KEY_ESCAPE;
  else if (selector == @selector(moveLeft:) || selector == @selector(moveBackward:)) code = KEY_LEFT;
  else if (selector == @selector(moveRight:) || selector == @selector(moveForward:)) code = KEY_RIGHT;
  else if (selector == @selector(moveWordLeft:)) { g_mods |= MOD_ALT; code = KEY_LEFT; }
  else if (selector == @selector(moveWordRight:)) { g_mods |= MOD_ALT; code = KEY_RIGHT; }
  else if (selector == @selector(moveUp:)) code = KEY_UP;
  else if (selector == @selector(moveDown:)) code = KEY_DOWN;
  else if (selector == @selector(moveToBeginningOfLine:) || selector == @selector(moveToLeftEndOfLine:)
           || selector == @selector(moveToBeginningOfDocument:) || selector == @selector(scrollToBeginningOfDocument:)) code = KEY_HOME;
  else if (selector == @selector(moveToEndOfLine:) || selector == @selector(moveToRightEndOfLine:)
           || selector == @selector(moveToEndOfDocument:) || selector == @selector(scrollToEndOfDocument:)) code = KEY_END;
  else if (selector == @selector(selectAll:)) code = KEY_SELECT_ALL;
  if (code != KEY_OTHER) {
    g_key = code;
    g_key_text = @"";
    g_key_pending = 1;
  }
}

- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
  (void)range;
  if (actualRange != NULL) *actualRange = NSMakeRange(0, 0);
  return nil;
}

- (NSArray<NSString *> *)validAttributesForMarkedText { return @[]; }

- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
  (void)range;
  if (actualRange != NULL) *actualRange = NSMakeRange(0, 0);
  NSRect screen = NSMakeRect(0, 0, 1, g_caret_h);
  if (self.window != nil) {
    // The view is flipped, so the top of the caret line is the point the runtime gave.
    NSPoint inWindow = [self convertPoint:NSMakePoint(g_caret_x, g_caret_y + g_caret_h) toView:nil];
    screen = [self.window convertRectToScreen:NSMakeRect(inWindow.x, inWindow.y, g_caret_w, g_caret_h)];
  }
  return screen;
}

- (NSUInteger)characterIndexForPoint:(NSPoint)point {
  (void)point;
  return NSNotFound;
}
@end

/**
 * The application, which answers the two attributes a client sets to ask a page for its
 * accessibility tree, as it asks a browser: AXManualAccessibility, which assistive clients set,
 * and AXEnhancedUserInterface, which VoiceOver sets. Either one switches the tree on.
 */
@interface NativeApplication : NSApplication
@end

@implementation NativeApplication
static BOOL ax_switch_attribute(NSString *attribute) {
  return [attribute isEqualToString:@"AXManualAccessibility"] || [attribute isEqualToString:@"AXEnhancedUserInterface"];
}
- (NSArray *)accessibilityAttributeNames {
  return [[super accessibilityAttributeNames] arrayByAddingObjectsFromArray:@[ @"AXManualAccessibility", @"AXEnhancedUserInterface" ]];
}
- (id)accessibilityAttributeValue:(NSString *)attribute {
  // A boolean, as a client reads it (CFBoolean), not a number.
  if (ax_switch_attribute(attribute)) return g_ax_active ? @YES : @NO;
  return [super accessibilityAttributeValue:attribute];
}
- (BOOL)accessibilityIsAttributeSettable:(NSString *)attribute {
  if (ax_switch_attribute(attribute)) return YES;
  return [super accessibilityIsAttributeSettable:attribute];
}
- (void)accessibilitySetValue:(id)value forAttribute:(NSString *)attribute {
  if (ax_switch_attribute(attribute)) {
    // The tree stays on once a client asked for it: a client that switches it off again would
    // otherwise leave another one, still reading, with nothing.
    if ([value respondsToSelector:@selector(boolValue)] && [value boolValue]) ax_activate();
    return;
  }
  [super accessibilitySetValue:value forAttribute:attribute];
}
@end

@interface NativeDelegate : NSObject <NSWindowDelegate>
@end

@implementation NativeDelegate
- (void)windowWillClose:(NSNotification *)n {
  close_children();
  g_quit = 1;
}
/** The red button asks the page first: its beforeunload decides, as a browser's close does. The
 *  runtime closes the window for real (host_window_close(0)) once the page has had its say. */
- (BOOL)windowShouldClose:(NSWindow *)sender {
  if (g_close_approved) return YES;
  g_app_quit = 1;
  return NO;
}
- (void)windowDidResize:(NSNotification *)n { g_resized = 1; }
- (void)windowDidMove:(NSNotification *)n { g_moved = 1; }
- (void)windowDidBecomeKey:(NSNotification *)n { g_key_state = 1; }
- (void)windowDidResignKey:(NSNotification *)n { g_key_state = -1; }
- (void)windowDidMiniaturize:(NSNotification *)n { g_visibility_changed = 1; }
- (void)windowDidDeminiaturize:(NSNotification *)n { g_visibility_changed = 1; }
- (void)windowDidEnterFullScreen:(NSNotification *)n { g_fullscreen_changed = 1; }
- (void)windowDidExitFullScreen:(NSNotification *)n { g_fullscreen_changed = 1; }
@end

static NativeDelegate *g_delegate = nil;

/** The app's own delegate: the Quit item asks it first, so the page's beforeunload can say no. */
@interface NativeAppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation NativeAppDelegate
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
  // The runtime runs the page's beforeunload and pagehide, then quits for real (host_quit).
  g_app_quit = 1;
  return NSTerminateCancel;
}
@end

static NativeAppDelegate *g_app_delegate = nil;

static NSString *str_from(const uint8_t *s, size_t n) {
  NSString *str = [[NSString alloc] initWithBytes:s length:n encoding:NSUTF8StringEncoding];
  return str ? str : @"";
}

// The last left mouse-down in the window: an app-region drag starts from it.
static NSEvent *g_last_down;
// The titlebar area a page can lay out into (Window Controls Overlay's titlebar-area-*), in
// view coordinates with y down, and whether the page draws under the titlebar at all.
static double g_tb_x, g_tb_y, g_tb_w, g_tb_h;
static int g_tb_overlay;

/** The value of `key` in the window options ("titlebar=hidden;min-width=640"), or nil. */
static NSString *window_option(NSString *opts, NSString *key) {
  for (NSString *pair in [opts componentsSeparatedByString:@";"]) {
    NSRange eq = [pair rangeOfString:@"="];
    if (eq.location != NSNotFound && [[pair substringToIndex:eq.location] isEqualToString:key])
      return [pair substringFromIndex:eq.location + 1];
  }
  return nil;
}

static void update_titlebar_area(void) {
  if (!g_window || !g_tb_overlay) {
    g_tb_x = g_tb_y = g_tb_w = g_tb_h = 0;
    return;
  }
  NSButton *zoom = [g_window standardWindowButton:NSWindowZoomButton];
  NSRect z = zoom ? [g_view convertRect:zoom.bounds fromView:zoom] : NSZeroRect;
  double width = g_view.bounds.size.width;
  double bar = g_window.frame.size.height - g_window.contentLayoutRect.size.height;
  g_tb_x = NSMaxX(z) + 12;
  g_tb_y = 0;
  g_tb_w = width - g_tb_x;
  g_tb_h = bar;
}

// The system appearance and the accessibility display options are watched rather than polled:
// the app is told when one changes, and reads the settings then.
static volatile int32_t g_settings_changed = 0;
static id g_settings_observer = nil;

@interface NativeSettingsObserver : NSObject
@end

@implementation NativeSettingsObserver
- (void)accessibilityOptionsChanged:(NSNotification *)note {
  g_settings_changed = 1;
}
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change context:(void *)context {
  g_settings_changed = 1;
}
@end

/** The frame at the size it was given, moved so its titlebar and window controls stay on
 *  `screen`. AppKit's own constraint shrinks a frame past the screen; a browser keeps the page's
 *  size and lets the window hang past the display, with its titlebar where the user can reach it. */
static NSRect frame_kept_on_screen(NSRect frame, NSScreen *screen) {
  NSRect visible = screen.visibleFrame;
  if (NSHeight(frame) > NSHeight(visible)) {
    frame.origin.y = NSMaxY(visible) - NSHeight(frame);
  } else if (frame.origin.y < NSMinY(visible)) {
    frame.origin.y = NSMinY(visible);
  } else if (NSMaxY(frame) > NSMaxY(visible)) {
    frame.origin.y = NSMaxY(visible) - NSHeight(frame);
  }
  // The window controls sit at the frame's top left, so a frame wider than the screen keeps its
  // left edge on it.
  if (NSWidth(frame) > NSWidth(visible)) {
    frame.origin.x = NSMinX(visible);
  } else if (frame.origin.x < NSMinX(visible)) {
    frame.origin.x = NSMinX(visible);
  } else if (NSMaxX(frame) > NSMaxX(visible)) {
    frame.origin.x = NSMaxX(visible) - NSWidth(frame);
  }
  return frame;
}

/** The window a page draws in. It keeps the frame it is given: a page wider or taller than the
 *  display is laid out at its own size, as it is in a browser, instead of being shrunk to fit the
 *  screen the way AppKit shrinks an ordinary window. Only where it sits is constrained, so the
 *  titlebar and the controls stay on the screen. */
@interface NativeWindow : NSWindow
@end
@implementation NativeWindow
- (NSRect)constrainFrameRect:(NSRect)frameRect toScreen:(NSScreen *)screen {
  NSScreen *on = screen != nil ? screen : (self.screen != nil ? self.screen : [NSScreen mainScreen]);
  return on != nil ? frame_kept_on_screen(frameRect, on) : frameRect;
}
@end

void host_open(double width, double height, const uint8_t *title, size_t title_len, const uint8_t *options, size_t options_len) {
  @autoreleasepool {
    signal(SIGPIPE, SIG_IGN);
    [NativeApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

    NSString *name = str_from(title, title_len);
    g_win_title = name;
    // A window the app opened is another process running the same page: it names its own window
    // and keeps out of the Dock, so the app shows one icon.
    const char *id_env = getenv("NATIVE_WINDOW_ID");
    g_win_id = id_env != NULL && id_env[0] != '\0' ? (int32_t)atoi(id_env) : new_window_id();
    const char *opener_env = getenv("NATIVE_WINDOW_OPENER");
    g_opener_id = opener_env != NULL && opener_env[0] != '\0' ? (int32_t)atoi(opener_env) : 0;
    const char *win_name = getenv("NATIVE_WINDOW_NAME");
    g_win_name = win_name != NULL ? [NSString stringWithUTF8String:win_name] : @"";
    if (g_opener_id != 0) {
      [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
      // The opener hands this window a pipe each way on fds 3 and 4 (see spawn_window).
      if (fcntl(3, F_GETFD) != -1) {
        g_parent_read = 3;
        fcntl(3, F_SETFL, fcntl(3, F_GETFL) | O_NONBLOCK);
      }
      if (fcntl(4, F_GETFD) != -1) g_parent_write = 4;
      static int registered = 0;
      if (!registered) {
        registered = 1;
        atexit(close_children);
      }
    }
    if (g_app_delegate == nil) {
      g_app_delegate = [[NativeAppDelegate alloc] init];
      NSApp.delegate = g_app_delegate;
    }
    apply_menu_bar();

    NSString *opts = str_from(options, options_len);
    NSString *tbStyle = window_option(opts, @"titlebar") ?: @"default";
    NSWindowStyleMask mask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable;
    if (![window_option(opts, @"resizable") isEqualToString:@"no"]) mask |= NSWindowStyleMaskResizable;
    // Every style but the default draws the page under the titlebar, with the traffic lights over it.
    g_tb_overlay = ![tbStyle isEqualToString:@"default"];
    if (g_tb_overlay) mask |= NSWindowStyleMaskFullSizeContentView;
    g_window = [[NativeWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, width, height)
                  styleMask:mask
                    backing:NSBackingStoreBuffered
                      defer:NO];
    g_window.releasedWhenClosed = NO;
    g_window.title = name;
    if (g_tb_overlay) {
      g_window.titlebarAppearsTransparent = YES;
      // `transparent` keeps the title text; `hidden` and `hidden-inset` leave the bar to the page.
      if (![tbStyle isEqualToString:@"transparent"]) g_window.titleVisibility = NSWindowTitleHidden;
      if ([tbStyle isEqualToString:@"hidden-inset"]) {
        // An empty unified toolbar makes the bar taller and sets the traffic lights in from the
        // corner, as an app with its own toolbar looks.
        NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"native"];
        g_window.toolbar = toolbar;
        g_window.toolbarStyle = NSWindowToolbarStyleUnified;
      }
    }
    NSString *minW = window_option(opts, @"min-width"), *minH = window_option(opts, @"min-height");
    if (minW || minH) g_window.contentMinSize = NSMakeSize(minW ? minW.doubleValue : 0, minH ? minH.doubleValue : 0);
    g_view = [[NativeView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
    if (window_compositing()) {
      // The view hosts a CAMetalLayer: the compositor draws each frame into its drawable, and
      // AppKit has no backing store of its own to draw a second copy into.
      CAMetalLayer *ml = [CAMetalLayer layer];
      ml.device = MTLCreateSystemDefaultDevice();
      if (ml.device != nil) {
        ml.pixelFormat = MTLPixelFormatBGRA8Unorm;
        ml.framebufferOnly = YES;
        ml.opaque = YES;
        ml.contentsScale = g_window.backingScaleFactor;
        ml.drawableSize = CGSizeMake(width * ml.contentsScale, height * ml.contentsScale);
        g_view.wantsLayer = YES;
        g_view.layer = ml;
        g_metal_layer = ml;
      }
    }
    g_window.contentView = g_view;
    g_window.acceptsMouseMovedEvents = YES;
    g_delegate = [[NativeDelegate alloc] init];
    g_window.delegate = g_delegate;
    NSString *optX = window_option(opts, @"x"), *optY = window_option(opts, @"y");
    if (optX != nil || optY != nil) {
      NSRect frame = g_window.frame;
      NSRect visible = [NSScreen mainScreen].visibleFrame;
      if (optX != nil) frame.origin.x = visible.origin.x + optX.doubleValue;
      if (optY != nil) frame.origin.y = visible.origin.y + visible.size.height - optY.doubleValue - frame.size.height;
      [g_window setFrame:frame display:NO];
    } else {
      // Centre in the screen's visible frame, which is the free area between the menu bar and
      // the Dock: the margins either side are equal, and the gap above the window matches the
      // gap below it. -[NSWindow center] frames against the screen's full height, which leaves
      // a window of this size too high once the menu bar and the Dock are accounted for.
      NSScreen *screen = g_window.screen != nil ? g_window.screen : [NSScreen mainScreen];
      if (screen != nil) {
        NSRect visible = screen.visibleFrame;
        NSRect frame = g_window.frame;
        frame.origin.x = visible.origin.x + floor((visible.size.width - frame.size.width) / 2);
        frame.origin.y = visible.origin.y + floor((visible.size.height - frame.size.height) / 2);
        [g_window setFrame:frame display:NO];
      } else {
        [g_window center];
      }
    }
    // Placement is the frame in the page's size moved onto the screen: `center` puts a window
    // taller than the display halfway above it, which leaves the titlebar and its controls out of
    // reach.
    NSScreen *home = g_window.screen != nil ? g_window.screen : [NSScreen mainScreen];
    if (home != nil) [g_window setFrame:frame_kept_on_screen(g_window.frame, home) display:NO];
    [g_window makeKeyAndOrderFront:nil];
    if (g_view != nil) {
      // Follow the display: the link's period is what the frame loop paces itself with, and a
      // display that refreshes at 120 Hz gets 120 frames a second without any other change.
      NSScreen *screen = g_window.screen != nil ? g_window.screen : [NSScreen mainScreen];
      if (screen != nil && screen.maximumFramesPerSecond > 0) {
        g_refresh_ms = 1000.0 / (double)screen.maximumFramesPerSecond;
        g_next_target = 0;
      }
      if (@available(macOS 14.0, *)) {
        CADisplayLink *link = [g_view displayLinkWithTarget:g_view selector:@selector(refreshTick:)];
        link.preferredFrameRateRange = CAFrameRateRangeMake(30, 120, 120);
        [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        g_display_link = link;
      }
      if (frame_times()) fprintf(stderr, "native: display period %g ms\n", g_refresh_ms);
    }
    update_titlebar_area();
    [NSApp finishLaunching];
    [NSApp activateIgnoringOtherApps:YES];
    if (g_settings_observer == nil) {
      g_settings_observer = [[NativeSettingsObserver alloc] init];
      [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:g_settings_observer
        selector:@selector(accessibilityOptionsChanged:)
        name:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification object:nil];
      if (@available(macOS 10.14, *)) {
        [NSApp addObserver:g_settings_observer forKeyPath:@"effectiveAppearance"
                   options:NSKeyValueObservingOptionNew context:NULL];
        [g_window addObserver:g_settings_observer forKeyPath:@"effectiveAppearance"
                      options:NSKeyValueObservingOptionNew context:NULL];
      }
    }
  }
}

void host_set_title(const uint8_t *title, size_t n) {
  g_win_title = str_from(title, n);
  if (g_window) g_window.title = g_win_title;
}

/** Whether NATIVE_AX_DUMP asks every tree printed, which builds one with no client asking. */
static int ax_dump_on(void) {
  static int on = -1;
  if (on < 0) on = getenv("NATIVE_AX_DUMP") != NULL ? 1 : 0;
  return on;
}

/** Prints the tree the way the accessibility API sees it, for a test that can't hold the
 *  Accessibility permission: NATIVE_AX_DUMP=1 makes each rebuild print its roles and names. */
static void ax_dump(NSArray *children, int depth) {
  for (NSAccessibilityElement *e in children) {
    NSMutableString *pad = [NSMutableString string];
    for (int i = 0; i < depth; i++) [pad appendString:@"  "];
    NSRect r = e.accessibilityFrame;
    id label = e.accessibilityLabel;
    id value = e.accessibilityValue;
    NSString *role = e.accessibilityRole;
    NSString *sub = e.accessibilitySubrole;
    NSString *extra = @"";
    if ([e isKindOfClass:[NativeAxElement class]]) {
      NativeAxElement *n = (NativeAxElement *)e;
      NSMutableString *more = [NSMutableString string];
      if (ax_is_field(n)) {
        [more appendFormat:@" sel=%lu,%lu line=%ld", (unsigned long)n.axSelection.location,
          (unsigned long)n.axSelection.length, (long)n.accessibilityInsertionPointLineNumber];
      }
      if (n.accessibilityPlaceholderValue.length > 0) [more appendFormat:@" placeholder=[%@]", n.accessibilityPlaceholderValue];
      if (n.domId.length > 0) [more appendFormat:@" id=%@", n.domId];
      NSMutableArray *acts = [NSMutableArray array];
      if (n.actionBits & AXA_PRESS) [acts addObject:@"press"];
      if (n.actionBits & AXA_FOCUS) [acts addObject:@"focus"];
      if (n.actionBits & AXA_SET_VALUE) [acts addObject:@"setValue"];
      if (n.actionBits & AXA_INCREMENT) [acts addObject:@"step"];
      if (acts.count > 0) [more appendFormat:@" actions=%@", [acts componentsJoinedByString:@","]];
      if (n.axFocused) [more appendString:@" focused"];
      extra = more;
    }
    fprintf(stdout, "%s%s%s%s %.0f,%.0f %.0fx%.0f label=[%s] value=[%s]%s\n", pad.UTF8String,
      role.UTF8String, sub.length > 0 ? "/" : "", sub.length > 0 ? sub.UTF8String : "",
      r.origin.x, r.origin.y, r.size.width, r.size.height,
      label == nil ? "" : [[label description] UTF8String],
      value == nil ? "" : [[value description] UTF8String],
      extra.UTF8String);
    ax_dump(e.accessibilityChildren, depth + 1);
  }
}

/** The focused element of a forest, or nil. */
static NativeAxElement *ax_find_focused(NSArray *list) {
  for (NativeAxElement *e in list) {
    if (e.axFocused) return e;
    NativeAxElement *inner = ax_find_focused(e.accessibilityChildren);
    if (inner != nil) return inner;
  }
  return nil;
}

/** This host's focus and text-range requests go to the runtime as EV_AXACTION; the older events
 *  carry nothing here. */
int32_t host_ax_focus(void) { return 0; }
int32_t host_ax_selection(void) { return 0; }

/** Whether a client has asked for the tree (or NATIVE_AX_DUMP prints every one). */
int32_t host_ax_active(void) { return g_ax_active || ax_dump_on() ? 1 : 0; }
/** The action EV_AXACTION carries: its kind, its node's uid, and its text. */
int32_t host_ax_action(void) { return g_ax_action_kind; }
int32_t host_ax_action_target(void) { return g_ax_action_uid; }
void host_ax_action_text(text_cb cb) {
  NSString *t = g_ax_action_text ?: @"";
  const char *utf8 = t.UTF8String;
  cb((const uint8_t *)utf8, strlen(utf8));
}

/** The element with a node id in a forest, or nil. */
static NSAccessibilityElement *ax_find_id(NSArray *list, NSInteger nodeId) {
  for (NSAccessibilityElement *e in list) {
    if (((NativeAxElement *)e).nodeId == nodeId) return e;
    NSAccessibilityElement *inner = ax_find_id(e.accessibilityChildren, nodeId);
    if (inner != nil) return inner;
  }
  return nil;
}

/** Speaks a live region's new text through the system's announcement request. */
void host_ax_announce(const uint8_t *text, size_t n, int32_t priority) {
  @autoreleasepool {
    NSString *spoken = str_from(text, n);
    if (spoken.length == 0) return;
    NSAccessibilityPriorityLevel level = priority == 1 ? NSAccessibilityPriorityHigh : NSAccessibilityPriorityMedium;
    NSAccessibilityPostNotificationWithUserInfo(NSApp, NSAccessibilityAnnouncementRequestedNotification,
      @{ NSAccessibilityAnnouncementKey: spoken, NSAccessibilityPriorityKey: @(level) });
    if (ax_dump_on()) {
      fprintf(stdout, "AX ANNOUNCE %d [%s]\n", priority, spoken.UTF8String);
      fflush(stdout);
    }
  }
}

/** Posts the value-changed notification for the element a node id names. */
void host_ax_value_changed(int32_t id) {
  if (g_ax_roots == nil || id <= 0) return;
  NSAccessibilityElement *e = ax_find_id(g_ax_roots, (NSInteger)id);
  if (e == nil) return;
  if (g_view != nil) NSAccessibilityPostNotification(e, NSAccessibilityValueChangedNotification);
  if (ax_dump_on()) {
    fprintf(stdout, "AX VALUE %d\n", id);
    fflush(stdout);
  }
}

/** The page's accessibility tree, as JSON (see runtime/ax-tree.ts). It only comes once a client
 *  asked for it. The elements are brought up to date now, so a change of focus or selection posts
 *  its notification at once, and the client hears that the layout changed. */
void host_ax_tree(const uint8_t *json, size_t n) {
  @autoreleasepool {
    g_ax_json = str_from(json, n);
    NativeAxElement *wasFocused = g_ax_focused_id != 0 ? g_ax_by_uid[@(g_ax_focused_id)] : nil;
    NSRange wasSelection = wasFocused != nil ? wasFocused.axSelection : NSMakeRange(NSNotFound, 0);
    ax_rebuild();
    NSArray *roots = g_ax_roots;
    NativeAxElement *focused = ax_find_focused(roots);
    NSInteger focusedId = focused == nil ? 0 : focused.uid;
    if (g_view != nil) {
      if (focusedId != g_ax_focused_id) {
        NSAccessibilityPostNotificationWithUserInfo(g_view,
          NSAccessibilityFocusedUIElementChangedNotification,
          @{ NSAccessibilityFocusedUIElementAttribute: focused != nil ? focused : g_ax_web_area });
      } else if (focused != nil && ax_is_field(focused) && !NSEqualRanges(focused.axSelection, wasSelection)) {
        NSAccessibilityPostNotification(focused, NSAccessibilitySelectedTextChangedNotification);
      }
      NSAccessibilityPostNotification(g_ax_web_area, NSAccessibilityLayoutChangedNotification);
    }
    g_ax_focused_id = focusedId;
    if (ax_dump_on()) {
      fprintf(stdout, "AX TREE\n");
      ax_dump(@[ g_ax_web_area ], 0);
      fprintf(stdout, "AX END\n");
      fflush(stdout);
    }
  }
}

double host_view_width(void) { return g_view ? g_view.bounds.size.width : 0; }
double host_view_height(void) { return g_view ? g_view.bounds.size.height : 0; }
double host_event_x(void) { return g_ex; }
double host_event_dx(void) { return g_dx; }
double host_event_dy(void) { return g_dy; }
int32_t host_event_phase(void) { return g_wheel_phase; }
int32_t host_event_key(void) { return g_key; }
int32_t host_event_mods(void) { return g_mods; }
int32_t host_event_repeat(void) { return g_key_repeat; }

void host_event_text(text_cb cb) {
  const char *s = g_key_text.UTF8String;
  cb((const uint8_t *)s, strlen(s));
}

/** The phase of the input method's composition that an EV_COMPOSE reports. */
int32_t host_composition_phase(void) { return g_compose_phase; }

void host_composition_text(text_cb cb) {
  const char *s = g_compose_text.UTF8String;
  cb((const uint8_t *)s, strlen(s));
}

/** Where the caret is, in CSS pixels from the view's top left: the candidate window's anchor. */
void host_composition_rect(double x, double y, double w, double h) {
  g_caret_x = x;
  g_caret_y = y;
  g_caret_w = w > 0 ? w : 1;
  g_caret_h = h > 0 ? h : 16;
}

/**
 * The text fragment the app was opened with, from NATIVE_TARGET_TEXT: the value a URL's
 * #:~:text= directive carries, which ::target-text paints. An app opened without one says so by
 * answering nothing.
 */
void host_target_text(text_cb cb) {
  const char *t = getenv("NATIVE_TARGET_TEXT");
  if (t == NULL || t[0] == '\0') return;
  cb((const uint8_t *)t, strlen(t));
}

/**
 * The file a run keeps its pasteboard in, or nil for the system one. A headless run given
 * NATIVE_PASTEBOARD copies and pastes through that file, so tests never touch the user's clipboard.
 */
static NSString *pasteboard_file(void) {
  static NSString *path = nil;
  static int looked = 0;
  if (!looked) {
    looked = 1;
    const char *p = getenv("NATIVE_PASTEBOARD");
    if (p != NULL && p[0] != '\0') path = [NSString stringWithUTF8String:p];
  }
  return path;
}

/** The markup a run's clipboard holds, beside its text: the pasteboard file with ".html" on it. */
static NSString *pasteboard_html_file(void) {
  NSString *file = pasteboard_file();
  return file == nil ? nil : [file stringByAppendingString:@".html"];
}

// The MOD_* flags of an event's modifier keys, for both keys and the pointer.
static int32_t mods_from(NSEventModifierFlags f) {
  return ((f & NSEventModifierFlagCommand) ? MOD_META : 0) | ((f & NSEventModifierFlagShift) ? MOD_SHIFT : 0) |
         ((f & NSEventModifierFlagOption) ? MOD_ALT : 0) | ((f & NSEventModifierFlagControl) ? MOD_CTRL : 0);
}

// Translates a key-down into a KEY_* code (plus text). Returns 0 if the menu handled it. A
// key-up takes the same code, but never reaches the menu: nothing is being chosen by letting go.
static int translate_key(NSEvent *e, int down) {
  g_mods = mods_from(e.modifierFlags);
  g_key_text = @"";
  NSString *chars = e.charactersIgnoringModifiers.lowercaseString;
  if (g_mods & MOD_META) {
    // An item of the page's menus owns its shortcut before the key reaches the page's own
    // handling of Cmd+C, Cmd+V and the like.
    if (down && NSApp.mainMenu != nil && [NSApp.mainMenu performKeyEquivalent:e]) return 0;
    // Paste reads the pasteboard in the runtime, which is what puts the text in and fires the
    // paste event; the host only says the key was pressed.
    if ([chars isEqualToString:@"v"]) { g_key = KEY_PASTE; return 1; }
    if ([chars isEqualToString:@"x"]) { g_key = KEY_CUT; return 1; }
    if ([chars isEqualToString:@"a"]) { g_key = KEY_SELECT_ALL; return 1; }
    if ([chars isEqualToString:@"c"]) { g_key = KEY_COPY; return 1; }
  }
  switch (e.keyCode) {
    case 51: g_key = KEY_BACKSPACE; return 1;
    case 117: g_key = KEY_DELETE; return 1;
    case 36: case 76: g_key = KEY_ENTER; return 1;
    case 123: g_key = KEY_LEFT; return 1;
    case 124: g_key = KEY_RIGHT; return 1;
    case 126: g_key = KEY_UP; return 1;
    case 125: g_key = KEY_DOWN; return 1;
    case 115: g_key = KEY_HOME; return 1;
    case 119: g_key = KEY_END; return 1;
    case 53: g_key = KEY_ESCAPE; return 1;
    case 48: g_key = KEY_TAB; return 1;
  }
  // Printable text, minus control characters and the private-use range AppKit uses for function keys.
  NSMutableString *text = [NSMutableString string];
  NSString *raw = e.characters ?: @"";
  for (NSUInteger i = 0; i < raw.length; i++) {
    unichar ch = [raw characterAtIndex:i];
    if (ch < 0x20 || ch == 0x7f || (ch >= 0xF700 && ch <= 0xF8FF)) continue;
    [text appendFormat:@"%C", ch];
  }
  g_key_text = [text copy];
  g_key = text.length > 0 && !(g_mods & (MOD_META | MOD_CTRL)) ? KEY_TEXT : KEY_OTHER;
  return 1;
}
double host_event_y(void) { return g_ey; }

/** One format off the pasteboard: the run's file, or the system pasteboard. */
static NSString *pasteboard_string(NSString *format) {
  NSString *file = pasteboard_file();
  if (file != nil) {
    NSString *path = [format isEqualToString:@"text/html"] ? pasteboard_html_file() : file;
    NSString *s = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    return s == nil ? @"" : s;
  }
  NSPasteboard *board = [NSPasteboard generalPasteboard];
  BOOL html = [format isEqualToString:@"text/html"];
  NSString *s = [board stringForType:html ? NSPasteboardTypeHTML : NSPasteboardTypeString];
  return s == nil ? @"" : s;
}

/** One format the clipboard holds: "" when it holds none of it. */
void host_clipboard_read(const uint8_t *format, size_t n, text_cb cb) {
  @autoreleasepool {
    NSString *s = pasteboard_string(str_from(format, n));
    const char *u = s.UTF8String;
    cb((const uint8_t *)u, strlen(u));
  }
}

/**
 * Replaces the clipboard's contents: the text as text/plain, and the markup as text/html when it
 * isn't empty. A headless run writes the two files its pasteboard lives in instead.
 */
void host_clipboard_write(const uint8_t *text, size_t text_len, const uint8_t *html, size_t html_len) {
  @autoreleasepool {
    NSString *t = str_from(text, text_len);
    NSString *h = str_from(html, html_len);
    NSString *file = pasteboard_file();
    if (file != nil) {
      [t writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil];
      NSString *htmlFile = pasteboard_html_file();
      if (h.length > 0) [h writeToFile:htmlFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
      else [[NSFileManager defaultManager] removeItemAtPath:htmlFile error:nil];
      return;
    }
    NSPasteboard *board = [NSPasteboard generalPasteboard];
    [board clearContents];
    [board setString:t forType:NSPasteboardTypeString];
    if (h.length > 0) [board setString:h forType:NSPasteboardTypeHTML];
  }
}

// ---------------------------------------------------------------------------
// Files dropped on the window
//
// The view is an NSDraggingDestination for file URLs: a drag from the Finder over the window is
// accepted as a copy, and its files wait for the EV_DROP that tells the runtime where the drop
// landed (host_event_x/y).

int32_t host_drop_file_count(void) { return g_drop_files == nil ? 0 : (int32_t)g_drop_files.count; }

void host_drop_file_name(int32_t index, text_cb cb) {
  @autoreleasepool {
    NSString *name = g_drop_files != nil && index >= 0 && index < (int32_t)g_drop_files.count
      ? [(NSString *)g_drop_files[index] lastPathComponent] : @"";
    const char *u = name.UTF8String;
    cb((const uint8_t *)u, strlen(u));
  }
}

void host_drop_file_path(int32_t index, text_cb cb) {
  @autoreleasepool {
    NSString *path = g_drop_files != nil && index >= 0 && index < (int32_t)g_drop_files.count
      ? g_drop_files[index] : @"";
    const char *u = path.UTF8String;
    cb((const uint8_t *)u, strlen(u));
  }
}

/**
 * The system's selection colour, which follows the user's accent colour, as 0xRRGGBBAA. The
 * window with a selection on it is the key window, so the emphasized colour is the one to match.
 */
uint32_t host_selection_color(void) {
  @autoreleasepool {
    NSColor *c = [NSColor.selectedTextBackgroundColor colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if (c == nil) return 0xb4d5feff;
    unsigned r = (unsigned)lround(c.redComponent * 255.0);
    unsigned g = (unsigned)lround(c.greenComponent * 255.0);
    unsigned b = (unsigned)lround(c.blueComponent * 255.0);
    return (r << 24) | (g << 16) | (b << 8) | 0xff;
  }
}

/** The system's keyboard focus ring colour, which is what Chrome on macOS draws for :focus-visible. */
uint32_t host_focus_ring_color(void) {
  @autoreleasepool {
    NSColor *c = [[NSColor keyboardFocusIndicatorColor] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if (c == nil) return 0x0064e1ffu;
    return ((uint32_t)lround(c.redComponent * 255.0) << 24) | ((uint32_t)lround(c.greenComponent * 255.0) << 16) |
      ((uint32_t)lround(c.blueComponent * 255.0) << 8) | (uint32_t)lround(c.alphaComponent * 255.0);
  }
}

void host_set_cursor(int32_t cursor) {
  g_cursor = cursor;
  g_cursor_image = nil;
  if (g_window) [g_window invalidateCursorRectsForView:g_view];
}

/**
 * Sets the cursor to an image the app loaded, with its hotspot in the image's own pixels, as
 * `cursor: url(image.png) 4 5` says. An image the host doesn't have leaves the keyword cursor.
 */
void host_set_cursor_image(int32_t id, double hx, double hy) {
  CGImageRef img = image_at(id);
  if (img == NULL) return;
  NSSize size = NSMakeSize((CGFloat)CGImageGetWidth(img), (CGFloat)CGImageGetHeight(img));
  NSImage *image = [[NSImage alloc] initWithCGImage:img size:size];
  g_cursor_image = [[NSCursor alloc] initWithImage:image hotSpot:NSMakePoint((CGFloat)hx, (CGFloat)hy)];
  if (g_window) [g_window invalidateCursorRectsForView:g_view];
}

double host_backing_scale(void) {
  if (g_window == nil) return 1.0;
  // A window that isn't on a screen yet reports a scale of 1, and a page's first script can run
  // before the window is shown: the screen it opens on gives the scale its frames draw at, so a
  // canvas sized from devicePixelRatio is sized for the pixels it will have.
  NSScreen *screen = g_window.screen != nil ? g_window.screen : [NSScreen mainScreen];
  return screen != nil ? screen.backingScaleFactor : g_window.backingScaleFactor;
}

double host_display_scale(void) {
  @autoreleasepool {
    // The display's own scale, before there is a window on it: a page's first script runs before
    // run() opens the window, and the screen the window opens on is the one its frames draw for.
    NSScreen *screen = g_window != nil ? g_window.screen : nil;
    if (screen == nil) screen = [NSScreen mainScreen];
    return screen != nil ? screen.backingScaleFactor : 1.0;
  }
}

int32_t host_reduced_motion(void) {
  @autoreleasepool {
    // Tests pin the preference instead of reading the machine's accessibility setting.
    const char *env = getenv("NATIVE_REDUCED_MOTION");
    if (env && *env) return strcmp(env, "0") != 0 ? 1 : 0;
    if (@available(macOS 10.12, *)) {
      return [[NSWorkspace sharedWorkspace] accessibilityDisplayShouldReduceMotion] ? 1 : 0;
    }
    return 0;
  }
}

// The system appearance: 1 when dark mode is on. Tests pin it with NATIVE_COLOR_SCHEME.
int32_t host_color_scheme(void) {
  @autoreleasepool {
    const char *env = getenv("NATIVE_COLOR_SCHEME");
    if (env && *env) return strcmp(env, "dark") == 0 ? 1 : 0;
    if (@available(macOS 10.14, *)) {
      NSAppearance *app = NSApp != nil ? NSApp.effectiveAppearance : [NSAppearance currentDrawingAppearance];
      NSAppearanceName name = [app bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
      if (name != nil) return [name isEqualToString:NSAppearanceNameDarkAqua] ? 1 : 0;
    }
    return 0;
  }
}

// The accessibility display settings media queries ask about, pinned by environment for tests.
int32_t host_increase_contrast(void) {
  const char *env = getenv("NATIVE_INCREASE_CONTRAST");
  if (env && *env) return strcmp(env, "0") != 0 ? 1 : 0;
  if (@available(macOS 10.12, *)) {
    return [[NSWorkspace sharedWorkspace] accessibilityDisplayShouldIncreaseContrast] ? 1 : 0;
  }
  return 0;
}

int32_t host_reduce_transparency(void) {
  const char *env = getenv("NATIVE_REDUCE_TRANSPARENCY");
  if (env && *env) return strcmp(env, "0") != 0 ? 1 : 0;
  if (@available(macOS 10.12, *)) {
    return [[NSWorkspace sharedWorkspace] accessibilityDisplayShouldReduceTransparency] ? 1 : 0;
  }
  return 0;
}

// The media type the page is laid out for. Print output isn't produced yet, so this is how a
// test (or a preview) asks for print media: NATIVE_MEDIA=print.
int32_t host_media_type(void) {
  const char *env = getenv("NATIVE_MEDIA");
  if (env != NULL && strcmp(env, "print") == 0) return 1;
  return 0;
}

// ---------------------------------------------------------------------------
// localStorage
//
// One JSON object per app, held in memory and written back on every change. The file lives under
// Application Support, or wherever NATIVE_STORAGE points, which is what the tests use.

static NSMutableDictionary<NSString *, NSString *> *g_storage = nil;
static NSString *g_storage_path = nil;

typedef void (*str_cb)(const uint8_t *, size_t);

static void storage_save(void) {
  if (!g_storage || !g_storage_path) return;
  NSData *data = [NSJSONSerialization dataWithJSONObject:g_storage options:0 error:NULL];
  if (data) [data writeToFile:g_storage_path atomically:YES];
}

void host_storage_open(const uint8_t *name, size_t n) {
  @autoreleasepool {
    if (g_storage) return;
    g_storage = [NSMutableDictionary dictionary];
    const char *env = getenv("NATIVE_STORAGE");
    NSString *path = nil;
    if (env && *env) {
      path = [NSString stringWithUTF8String:env];
    } else {
      NSString *app = str_from(name, n);
      NSMutableString *safe = [NSMutableString string];
      for (NSUInteger i = 0; i < app.length && safe.length < 64; i++) {
        unichar ch = [app characterAtIndex:i];
        [safe appendFormat:@"%C", (unichar)((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '-' || ch == '_' ? ch : '-')];
      }
      if (safe.length == 0) safe = [NSMutableString stringWithString:@"app"];
      NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
      NSString *base = dirs.count > 0 ? dirs[0] : NSTemporaryDirectory();
      NSString *dir = [[base stringByAppendingPathComponent:@"native"] stringByAppendingPathComponent:safe];
      [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
      path = [dir stringByAppendingPathComponent:@"localStorage.json"];
    }
    g_storage_path = path;
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return;
    NSDictionary *loaded = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![loaded isKindOfClass:[NSDictionary class]]) return;
    for (id key in loaded) {
      id value = loaded[key];
      if ([key isKindOfClass:[NSString class]] && [value isKindOfClass:[NSString class]]) g_storage[key] = value;
    }
  }
}

void host_storage_dir(str_cb cb) {
  @autoreleasepool {
    if (g_storage_path == nil) { cb((const uint8_t *)"", 0); return; }
    NSString *dir = [g_storage_path stringByDeletingLastPathComponent];
    const char *s = dir.UTF8String;
    cb((const uint8_t *)s, strlen(s));
  }
}

int32_t host_storage_has(const uint8_t *key, size_t n) {
  if (!g_storage) return 0;
  return g_storage[str_from(key, n)] != nil ? 1 : 0;
}

void host_storage_get(const uint8_t *key, size_t n, str_cb cb) {
  NSString *v = g_storage ? g_storage[str_from(key, n)] : nil;
  const char *s = v ? v.UTF8String : "";
  cb((const uint8_t *)s, strlen(s));
}

void host_storage_set(const uint8_t *key, size_t kn, const uint8_t *value, size_t vn) {
  if (!g_storage) return;
  g_storage[str_from(key, kn)] = str_from(value, vn);
  storage_save();
}

void host_storage_remove(const uint8_t *key, size_t n) {
  if (!g_storage) return;
  [g_storage removeObjectForKey:str_from(key, n)];
  storage_save();
}

void host_storage_clear(void) {
  if (!g_storage) return;
  [g_storage removeAllObjects];
  storage_save();
}

int32_t host_storage_length(void) { return g_storage ? (int32_t)g_storage.count : 0; }

void host_storage_key(int32_t index, str_cb cb) {
  NSString *key = @"";
  if (g_storage && index >= 0 && (NSUInteger)index < g_storage.count) key = g_storage.allKeys[(NSUInteger)index];
  const char *s = key.UTF8String;
  cb((const uint8_t *)s, strlen(s));
}

// ---------------------------------------------------------------------------
// The app's own files. fetch() resolves a page-relative URL to a path in the directory the page
// was built from (the build puts that path in IMAGE_BASE) and asks the host for its bytes; the
// callback runs once, inside the call, with the whole file. A missing file has size -1 and reads
// as a zero-length callback.

typedef void (*bytes_cb)(const uint8_t *, size_t);

// ---------------------------------------------------------------------------
// SQLite
//
// The store IndexedDB keeps its records in. A database and each prepared statement are an opaque
// id the runtime holds; ids are 1-based and 0 means none. Statements are cached by the runtime,
// so the table is the only limit on how many are open.

#define SQLITE_MAX_DB 8
#define SQLITE_MAX_STMT 512

static sqlite3 *g_sqlite_db[SQLITE_MAX_DB];
static sqlite3_stmt *g_sqlite_stmt[SQLITE_MAX_STMT];

static sqlite3 *sqlite_db_at(int32_t id) {
  return id > 0 && id <= SQLITE_MAX_DB ? g_sqlite_db[id - 1] : NULL;
}

static sqlite3_stmt *sqlite_stmt_at(int32_t id) {
  return id > 0 && id <= SQLITE_MAX_STMT ? g_sqlite_stmt[id - 1] : NULL;
}

static char *sqlite_copy(const uint8_t *s, size_t n) {
  char *p = (char *)malloc(n + 1);
  if (p == NULL) return NULL;
  if (n > 0) memcpy(p, s, n);
  p[n] = '\0';
  return p;
}

int32_t host_sqlite_open(const uint8_t *path, size_t n) {
  char *p = sqlite_copy(path, n);
  if (p == NULL) return 0;
  int32_t id = 0;
  for (int i = 0; i < SQLITE_MAX_DB; i++) {
    if (g_sqlite_db[i] != NULL) continue;
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(p, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
      if (db != NULL) sqlite3_close(db);
      break;
    }
    sqlite3_busy_timeout(db, 2000);
    g_sqlite_db[i] = db;
    id = i + 1;
    break;
  }
  free(p);
  return id;
}

void host_sqlite_close(int32_t id) {
  sqlite3 *db = sqlite_db_at(id);
  if (db == NULL) return;
  sqlite3_close_v2(db);
  g_sqlite_db[id - 1] = NULL;
}

int32_t host_sqlite_exec(int32_t id, const uint8_t *sql, size_t n) {
  sqlite3 *db = sqlite_db_at(id);
  if (db == NULL) return SQLITE_MISUSE;
  char *q = sqlite_copy(sql, n);
  if (q == NULL) return SQLITE_NOMEM;
  int rc = sqlite3_exec(db, q, NULL, NULL, NULL);
  free(q);
  return rc;
}

int32_t host_sqlite_prepare(int32_t id, const uint8_t *sql, size_t n) {
  sqlite3 *db = sqlite_db_at(id);
  if (db == NULL) return 0;
  char *q = sqlite_copy(sql, n);
  if (q == NULL) return 0;
  int32_t found = 0;
  for (int i = 0; i < SQLITE_MAX_STMT; i++) {
    if (g_sqlite_stmt[i] != NULL) continue;
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db, q, -1, &st, NULL) != SQLITE_OK) break;
    g_sqlite_stmt[i] = st;
    found = i + 1;
    break;
  }
  free(q);
  return found;
}

int32_t host_sqlite_finalize(int32_t id) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  if (st == NULL) return SQLITE_MISUSE;
  int rc = sqlite3_finalize(st);
  g_sqlite_stmt[id - 1] = NULL;
  return rc;
}

int32_t host_sqlite_reset(int32_t id) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  return st == NULL ? SQLITE_MISUSE : sqlite3_reset(st);
}

int32_t host_sqlite_clear_bindings(int32_t id) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  return st == NULL ? SQLITE_MISUSE : sqlite3_clear_bindings(st);
}

int32_t host_sqlite_bind_text(int32_t id, int32_t index, const uint8_t *value, size_t n) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  if (st == NULL) return SQLITE_MISUSE;
  return sqlite3_bind_text(st, index, (const char *)value, (int)n, SQLITE_TRANSIENT);
}

int32_t host_sqlite_bind_double(int32_t id, int32_t index, double value) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  return st == NULL ? SQLITE_MISUSE : sqlite3_bind_double(st, index, value);
}

int32_t host_sqlite_bind_int(int32_t id, int32_t index, double value) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  return st == NULL ? SQLITE_MISUSE : sqlite3_bind_int64(st, index, (sqlite3_int64)value);
}

int32_t host_sqlite_bind_null(int32_t id, int32_t index) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  return st == NULL ? SQLITE_MISUSE : sqlite3_bind_null(st, index);
}

int32_t host_sqlite_bind_blob(int32_t id, int32_t index, const uint8_t *value, size_t n) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  if (st == NULL) return SQLITE_MISUSE;
  return sqlite3_bind_blob(st, index, value, (int)n, SQLITE_TRANSIENT);
}

int32_t host_sqlite_step(int32_t id) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  return st == NULL ? SQLITE_MISUSE : sqlite3_step(st);
}

int32_t host_sqlite_column_count(int32_t id) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  return st == NULL ? 0 : sqlite3_column_count(st);
}

int32_t host_sqlite_column_type(int32_t id, int32_t col) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  return st == NULL ? SQLITE_NULL : sqlite3_column_type(st, col);
}

void host_sqlite_column_text(int32_t id, int32_t col, text_cb cb) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  if (st == NULL) { cb((const uint8_t *)"", 0); return; }
  const unsigned char *text = sqlite3_column_text(st, col);
  int n = sqlite3_column_bytes(st, col);
  cb(text == NULL ? (const uint8_t *)"" : text, text == NULL ? 0 : (size_t)n);
}

void host_sqlite_column_blob(int32_t id, int32_t col, bytes_cb cb) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  if (st == NULL) { cb(NULL, 0); return; }
  const void *blob = sqlite3_column_blob(st, col);
  int n = sqlite3_column_bytes(st, col);
  cb(blob == NULL ? NULL : (const uint8_t *)blob, blob == NULL ? 0 : (size_t)n);
}

double host_sqlite_column_double(int32_t id, int32_t col) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  return st == NULL ? 0 : sqlite3_column_double(st, col);
}

double host_sqlite_changes(int32_t id) {
  sqlite3 *db = sqlite_db_at(id);
  return db == NULL ? 0 : (double)sqlite3_changes(db);
}

double host_sqlite_last_id(int32_t id) {
  sqlite3 *db = sqlite_db_at(id);
  return db == NULL ? 0 : (double)sqlite3_last_insert_rowid(db);
}

void host_sqlite_errmsg(int32_t id, text_cb cb) {
  sqlite3 *db = sqlite_db_at(id);
  const char *msg = db == NULL ? "no database" : sqlite3_errmsg(db);
  cb((const uint8_t *)msg, strlen(msg));
}


/** The size of a regular file in bytes, or -1 when it can't be read. */
int32_t host_file_size(const uint8_t *path, size_t n) {
  @autoreleasepool {
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:str_from(path, n) error:NULL];
    if (!attrs || ![attrs[NSFileType] isEqualToString:NSFileTypeRegular]) return -1;
    long long size = [attrs[NSFileSize] longLongValue];
    return size > 0x7fffffffLL ? -1 : (int32_t)size;
  }
}

/** Passes the file's bytes to `cb` once; an empty callback when it can't be read. */
void host_file_read(const uint8_t *path, size_t n, bytes_cb cb) {
  @autoreleasepool {
    NSData *data = [NSData dataWithContentsOfFile:str_from(path, n)];
    if (!data) { cb(NULL, 0); return; }
    cb((const uint8_t *)data.bytes, data.length);
  }
}

// ---------------------------------------------------------------------------
// Menus, windows and the app's lifecycle. A menu arrives as a spec of lines (runtime/menus.ts
// writes it): an item's label, its accesskey and its command separated by tabs, two spaces of
// indent per submenu. Every item of the page's menus comes back as EV_MENU with its line index,
// and the runtime runs what it says; the app menu at the front of the bar is this host's own.
// A window the app opens is another process running the same page, connected to this one by a
// pair of pipes: one carries messages to it, the other what it sends back.

@interface NativeMenuLine : NSObject
@property (nonatomic) int depth;
@property (nonatomic, strong) NSString *label;
@property (nonatomic, strong) NSString *keys;
@property (nonatomic) BOOL disabled;
@end
@implementation NativeMenuLine
@end

@interface NativeMenuTarget : NSObject
- (void)itemChosen:(NSMenuItem *)item;
@end

@implementation NativeMenuTarget
- (void)itemChosen:(NSMenuItem *)item {
  if (g_menu_popup_open) {
    g_menu_choice = (int32_t)item.tag;
    return;
  }
  g_menu_index = (int32_t)item.tag;
  g_menu_pending = 1;
}
@end

static NativeMenuTarget *g_menu_target = nil;
static NSString *g_menu_spec = @"";

/** The lines of a menu spec, in its order: the index of a line is the index EV_MENU reports. */
static NSArray<NativeMenuLine *> *parse_menu_spec(NSString *spec) {
  NSMutableArray<NativeMenuLine *> *lines = [NSMutableArray array];
  if (spec.length == 0) return lines;
  for (NSString *raw in [spec componentsSeparatedByString:@"\n"]) {
    if (raw.length == 0) continue;
    NSUInteger i = 0;
    int depth = 0;
    while (i + 1 < raw.length && [raw characterAtIndex:i] == ' ' && [raw characterAtIndex:i + 1] == ' ') {
      depth++;
      i += 2;
    }
    NSArray<NSString *> *fields = [[raw substringFromIndex:i] componentsSeparatedByString:@"\t"];
    NativeMenuLine *line = [[NativeMenuLine alloc] init];
    line.depth = depth;
    line.label = fields.count > 0 ? fields[0] : @"";
    line.keys = fields.count > 1 ? fields[1] : @"";
    line.disabled = fields.count > 2 && [fields[2] isEqualToString:@"1"];
    [lines addObject:line];
  }
  return lines;
}

/** The key equivalent a named key takes, or nil for a name the menu doesn't know. */
static NSString *named_key(NSString *name) {
  static NSDictionary<NSString *, NSString *> *keys = nil;
  if (keys == nil) {
    keys = @{
      @"enter": @"\r", @"return": @"\r", @"escape": @"\x1b", @"esc": @"\x1b",
      @"tab": @"\t", @"space": @" ", @"backspace": @"\x08", @"delete": @"\x7f",
      @"up": [NSString stringWithFormat:@"%C", (unichar)NSUpArrowFunctionKey],
      @"down": [NSString stringWithFormat:@"%C", (unichar)NSDownArrowFunctionKey],
      @"left": [NSString stringWithFormat:@"%C", (unichar)NSLeftArrowFunctionKey],
      @"right": [NSString stringWithFormat:@"%C", (unichar)NSRightArrowFunctionKey],
      @"home": [NSString stringWithFormat:@"%C", (unichar)NSHomeFunctionKey],
      @"end": [NSString stringWithFormat:@"%C", (unichar)NSEndFunctionKey],
      @"pageup": [NSString stringWithFormat:@"%C", (unichar)NSPageUpFunctionKey],
      @"pagedown": [NSString stringWithFormat:@"%C", (unichar)NSPageDownFunctionKey],
    };
  }
  return keys[name.lowercaseString];
}

/** An accesskey ("N", "Shift+N", "Alt+Shift+K") as a key equivalent and its modifiers: the
 *  platform's primary modifier (Command) always, plus the ones the attribute names. */
static BOOL parse_keys(NSString *text, NSString **outKey, NSUInteger *outMask) {
  if (text.length == 0) return NO;
  NSArray<NSString *> *parts = [text componentsSeparatedByString:@"+"];
  NSUInteger mask = NSEventModifierFlagCommand;
  for (NSUInteger i = 0; i + 1 < parts.count; i++) {
    NSString *part = [parts[i].lowercaseString stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if ([part isEqualToString:@"shift"]) mask |= NSEventModifierFlagShift;
    else if ([part isEqualToString:@"alt"] || [part isEqualToString:@"option"]) mask |= NSEventModifierFlagOption;
    else if ([part isEqualToString:@"ctrl"] || [part isEqualToString:@"control"]) mask |= NSEventModifierFlagControl;
    else if ([part isEqualToString:@"cmd"] || [part isEqualToString:@"command"] || [part isEqualToString:@"meta"]) continue;
    else return NO;
  }
  NSString *last = [parts.lastObject stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  NSString *key = last.length == 1 ? last.lowercaseString : named_key(last);
  if (key == nil) return NO;
  *outKey = key;
  *outMask = mask;
  return YES;
}

static NSMenuItem *menu_item(NativeMenuLine *line, NSUInteger index) {
  NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:line.label action:@selector(itemChosen:) keyEquivalent:@""];
  item.target = g_menu_target;
  item.tag = (NSInteger)index;
  item.enabled = !line.disabled;
  NSString *key = nil;
  NSUInteger mask = 0;
  if (parse_keys(line.keys, &key, &mask)) {
    item.keyEquivalent = key;
    item.keyEquivalentModifierMask = mask;
  }
  return item;
}

/** The items at `depth` from `at`, making each one that has children a submenu. */
static void fill_menu(NSMenu *menu, NSArray<NativeMenuLine *> *lines, NSUInteger *at, int depth) {
  while (*at < lines.count) {
    NativeMenuLine *line = lines[*at];
    if (line.depth < depth) break;
    if (line.depth > depth) {
      (*at)++;
      continue;
    }
    NSUInteger index = *at;
    (*at)++;
    if ([line.label isEqualToString:@"-"]) {
      [menu addItem:[NSMenuItem separatorItem]];
      continue;
    }
    BOOL hasChildren = *at < lines.count && lines[*at].depth > depth;
    if (hasChildren) {
      NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:line.label action:nil keyEquivalent:@""];
      NSMenu *submenu = [[NSMenu alloc] init];
      submenu.autoenablesItems = NO;
      fill_menu(submenu, lines, at, depth + 1);
      item.submenu = submenu;
      [menu addItem:item];
    } else {
      [menu addItem:menu_item(line, index)];
    }
  }
}

static NSMenu *menu_from_lines(NSArray<NativeMenuLine *> *lines, NSUInteger *at, int depth) {
  NSMenu *menu = [[NSMenu alloc] init];
  menu.autoenablesItems = NO;
  fill_menu(menu, lines, at, depth);
  return menu;
}

/**
 * The app's own menu, which macOS puts first: About, Hide, Hide Others and Show All, then the
 * items the page put at the top of its menu (when `lines` is given), and Quit.
 */
static NSMenu *app_menu(NSString *name, NSArray<NativeMenuLine *> *lines, NSUInteger *at) {
  NSMenu *menu = [[NSMenu alloc] init];
  menu.autoenablesItems = NO;
  NSMenuItem *about = [[NSMenuItem alloc] initWithTitle:[@"About " stringByAppendingString:name]
                                                action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
  [menu addItem:about];
  [menu addItem:[NSMenuItem separatorItem]];
  NSMenuItem *hide = [[NSMenuItem alloc] initWithTitle:@"Hide" action:@selector(hide:) keyEquivalent:@"h"];
  hide.target = NSApp;
  [menu addItem:hide];
  NSMenuItem *hideOthers = [[NSMenuItem alloc] initWithTitle:@"Hide Others" action:@selector(hideOtherApplications:) keyEquivalent:@"h"];
  hideOthers.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
  hideOthers.target = NSApp;
  [menu addItem:hideOthers];
  NSMenuItem *showAll = [[NSMenuItem alloc] initWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
  showAll.target = NSApp;
  [menu addItem:showAll];
  if (at != NULL && *at < lines.count && lines[*at].depth > 0) {
    [menu addItem:[NSMenuItem separatorItem]];
    fill_menu(menu, lines, at, 1);
  }
  [menu addItem:[NSMenuItem separatorItem]];
  NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:[@"Quit " stringByAppendingString:name]
                                               action:@selector(terminate:) keyEquivalent:@"q"];
  quit.target = NSApp;
  [menu addItem:quit];
  return menu;
}

/** Builds the bar from the page's spec, with the app menu in front of it. */
static void apply_menu_bar(void) {
  if (NSApp == nil) return;
  if (g_menu_target == nil) g_menu_target = [[NativeMenuTarget alloc] init];
  // The app's name in the menu bar is the bundle's, so "About" and "Quit" name the app the way
  // Finder and the window title do. An executable run outside a bundle has no bundle name, and
  // keeps the process name it always had.
  NSBundle *bundle = [NSBundle mainBundle];
  NSString *name = [bundle objectForInfoDictionaryKey:@"CFBundleDisplayName"];
  if (name.length == 0) name = [bundle objectForInfoDictionaryKey:@"CFBundleName"];
  if (name.length == 0) name = [NSProcessInfo processInfo].processName;
  NSMenu *bar = [[NSMenu alloc] init];
  NSArray<NativeMenuLine *> *lines = parse_menu_spec(g_menu_spec);
  NSUInteger at = 0;
  // The app menu is the bar's first menu. A top-level line with no label is the page's items of
  // it, which go between the automatic Hide group and Quit.
  NSMenuItem *appItem = [[NSMenuItem alloc] initWithTitle:name action:nil keyEquivalent:@""];
  if (at < lines.count && lines[at].depth == 0 && lines[at].label.length == 0) {
    at++;
    appItem.submenu = app_menu(name, lines, &at);
  } else {
    appItem.submenu = app_menu(name, nil, NULL);
  }
  [bar addItem:appItem];
  while (at < lines.count) {
    NativeMenuLine *line = lines[at];
    if (line.depth != 0) {
      at++;
      continue;
    }
    at++;
    NSMenuItem *top = [[NSMenuItem alloc] initWithTitle:line.label action:nil keyEquivalent:@""];
    top.submenu = menu_from_lines(lines, &at, 1);
    [bar addItem:top];
  }
  NSApp.mainMenu = bar;
}

void host_menu_set(const uint8_t *spec, size_t n) {
  @autoreleasepool {
    g_menu_spec = str_from(spec, n);
    [NativeApplication sharedApplication];
    apply_menu_bar();
  }
}

int32_t host_menu_popup(const uint8_t *spec, size_t n, double x, double y) {
  @autoreleasepool {
    if (g_view == nil) return -1;
    g_menu_spec = str_from(spec, n);
    if (g_menu_target == nil) g_menu_target = [[NativeMenuTarget alloc] init];
    NSArray<NativeMenuLine *> *lines = parse_menu_spec(g_menu_spec);
    NSUInteger at = 0;
    NSMenu *menu = menu_from_lines(lines, &at, 0);
    g_menu_choice = -1;
    g_menu_popup_open = 1;
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(x, y) inView:g_view];
    g_menu_popup_open = 0;
    return g_menu_choice;
  }
}

int32_t host_menu_item(void) { return g_menu_index; }

void host_menu_spec(text_cb cb) {
  const char *spec = g_menu_spec.UTF8String;
  cb((const uint8_t *)(spec == NULL ? "" : spec), strlen(spec == NULL ? "" : spec));
}

// ---------------------------------------------------------------------------
// Windows: the app's own, and the processes it opens.

#define MAX_CHILDREN 16

/** A window this one opened, and the pipes that carry messages both ways. */
typedef struct {
  int32_t id;
  pid_t pid;
  int write_fd; // this process to the child
  int read_fd;  // the child to this process
  int open;
  char name[128];
  char *buf;
  size_t buf_len, buf_cap;
} ChildWindow;

static ChildWindow g_children[MAX_CHILDREN];
static int g_child_count = 0;
static int g_next_child_seq = 1;
static int32_t g_closed_child = 0;
/** Messages waiting for the page: the window each came from and its JSON body. */
#define MAX_MESSAGES 16
typedef struct {
  int32_t from;
  char *data;
} HostMessage;
static HostMessage g_messages[MAX_MESSAGES];
static int g_msg_head = 0, g_msg_tail = 0;
static int32_t g_message_from = 0;
static char *g_message_data = NULL;

/** A window's id: this process's, plus a counter for the ones it opens, so ids never collide. */
static int32_t new_window_id(void) {
  return (int32_t)(getpid() * 1000) + g_next_child_seq++;
}

static void queue_message(int32_t from, const char *data) {
  int next = (g_msg_tail + 1) % MAX_MESSAGES;
  if (next == g_msg_head) return; // full: the oldest stays, the newest is dropped
  g_messages[g_msg_tail].from = from;
  g_messages[g_msg_tail].data = strdup(data);
  if (g_messages[g_msg_tail].data == NULL) return;
  g_msg_tail = next;
}

static void write_line(int fd, int32_t to, int32_t from, const char *json) {
  if (fd < 0) return;
  size_t need = strlen(json) + 64;
  char *line = (char *)malloc(need);
  if (line == NULL) return;
  int n = snprintf(line, need, "%d\t%d\t%s\n", to, from, json);
  if (n > 0) {
    size_t off = 0;
    while (off < (size_t)n) {
      ssize_t written = write(fd, line + off, (size_t)n - off);
      if (written <= 0) break;
      off += (size_t)written;
    }
  }
  free(line);
}

static void route_message(int32_t to, int32_t from, const char *json) {
  for (int i = 0; i < g_child_count; i++) {
    if (g_children[i].open && g_children[i].id == to) {
      write_line(g_children[i].write_fd, to, from, json);
      return;
    }
  }
  // A window this one didn't open belongs further along the chain: hand it to the opener.
  write_line(g_parent_write, to, from, json);
}

/** One line of the wire: the window it is for, the window it is from, and the JSON body. */
static void handle_message_line(char *line) {
  char *t1 = strchr(line, '\t');
  if (t1 == NULL) return;
  char *t2 = strchr(t1 + 1, '\t');
  if (t2 == NULL) return;
  int32_t to = (int32_t)atoi(line);
  int32_t from = (int32_t)atoi(t1 + 1);
  char *json = t2 + 1;
  if (to == g_win_id) {
    queue_message(from, json);
    return;
  }
  route_message(to, from, json);
}

/** Reads what a pipe holds, hands over its complete lines, and keeps the rest for next time. */
static void read_pipe(int fd, char **buf, size_t *len, size_t *cap) {
  if (fd < 0) return;
  char chunk[4096];
  for (;;) {
    ssize_t n = read(fd, chunk, sizeof(chunk));
    if (n <= 0) break;
    while (*len + (size_t)n > *cap) {
      size_t next = *cap == 0 ? 8192 : *cap * 2;
      char *grown = (char *)realloc(*buf, next);
      if (grown == NULL) {
        *len = 0;
        *cap = 0;
        return;
      }
      *buf = grown;
      *cap = next;
    }
    memcpy(*buf + *len, chunk, (size_t)n);
    *len += (size_t)n;
  }
  size_t start = 0;
  for (size_t i = 0; i < *len; i++) {
    if ((*buf)[i] == '\n') {
      (*buf)[i] = '\0';
      handle_message_line(*buf + start);
      start = i + 1;
    }
  }
  if (start > 0) {
    memmove(*buf, *buf + start, *len - start);
    *len -= start;
  }
}

static void pump_messages(void) {
  read_pipe(g_parent_read, &g_parent_buf, &g_parent_len, &g_parent_cap);
  for (int i = 0; i < g_child_count; i++) {
    if (g_children[i].open) read_pipe(g_children[i].read_fd, &g_children[i].buf, &g_children[i].buf_len, &g_children[i].buf_cap);
  }
}

/** Takes the next message the page should hear; false when none is waiting. */
static int take_message(void) {
  if (g_msg_head == g_msg_tail) return 0;
  free(g_message_data);
  g_message_data = g_messages[g_msg_head].data;
  g_message_from = g_messages[g_msg_head].from;
  g_msg_head = (g_msg_head + 1) % MAX_MESSAGES;
  return 1;
}

/** Finds a window this one opened that has exited, and reports it. */
static int check_children(void) {
  for (int i = 0; i < g_child_count; i++) {
    if (!g_children[i].open) continue;
    int status = 0;
    pid_t exited = waitpid(g_children[i].pid, &status, WNOHANG);
    if (exited != g_children[i].pid) continue;
    g_children[i].open = 0;
    if (g_children[i].write_fd >= 0) close(g_children[i].write_fd);
    if (g_children[i].read_fd >= 0) close(g_children[i].read_fd);
    g_children[i].write_fd = g_children[i].read_fd = -1;
    g_closed_child = g_children[i].id;
    return 1;
  }
  return 0;
}

/** Ends the windows this one opened, which are its processes to end. */
static void close_children(void) {
  for (int i = 0; i < g_child_count; i++) {
    if (!g_children[i].open) continue;
    kill(g_children[i].pid, SIGTERM);
    g_children[i].open = 0;
  }
}

/** One value of a window-features string ("width=420,height=300"): what `name` is set to. */
static NSString *feature_value(NSString *features, NSString *name) {
  NSCharacterSet *separators = [NSCharacterSet characterSetWithCharactersInString:@", "];
  for (NSString *part in [features componentsSeparatedByCharactersInSet:separators]) {
    NSRange eq = [part rangeOfString:@"="];
    if (eq.location == NSNotFound) continue;
    if ([[part substringToIndex:eq.location].lowercaseString isEqualToString:name]) {
      return [part substringFromIndex:eq.location + 1];
    }
  }
  return nil;
}

/** Opens a window: the same executable, at its own address, talking to this one over pipes. */
static int32_t spawn_window(NSString *route, NSString *name, NSString *features) {
  char exe[PATH_MAX];
  uint32_t size = sizeof(exe);
  if (_NSGetExecutablePath(exe, &size) != 0) return -1;
  char resolved[PATH_MAX];
  if (realpath(exe, resolved) != NULL) {
    strncpy(exe, resolved, sizeof(exe) - 1);
    exe[sizeof(exe) - 1] = '\0';
  }
  int to_child[2], from_child[2];
  if (pipe(to_child) != 0) return -1;
  if (pipe(from_child) != 0) {
    close(to_child[0]);
    close(to_child[1]);
    return -1;
  }
  int32_t child_id = new_window_id();
  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  // The child reads its messages on fd 3 and writes on fd 4. The pipes' own ends may already be
  // those numbers, so nothing is closed until both are in place, and a pair that has them
  // swapped goes through a spare fd.
  if (to_child[0] == 4 && from_child[1] == 3) {
    posix_spawn_file_actions_adddup2(&actions, from_child[1], 8);
    posix_spawn_file_actions_adddup2(&actions, to_child[0], 3);
    posix_spawn_file_actions_adddup2(&actions, 8, 4);
    posix_spawn_file_actions_addclose(&actions, 8);
  } else {
    if (to_child[0] != 3) posix_spawn_file_actions_adddup2(&actions, to_child[0], 3);
    if (from_child[1] != 4) posix_spawn_file_actions_adddup2(&actions, from_child[1], 4);
  }
  if (to_child[0] != 3 && to_child[0] != 4) posix_spawn_file_actions_addclose(&actions, to_child[0]);
  if (to_child[1] != 3 && to_child[1] != 4) posix_spawn_file_actions_addclose(&actions, to_child[1]);
  if (from_child[0] != 3 && from_child[0] != 4) posix_spawn_file_actions_addclose(&actions, from_child[0]);
  if (from_child[1] != 3 && from_child[1] != 4) posix_spawn_file_actions_addclose(&actions, from_child[1]);

  extern char **environ;
  NSMutableArray<NSString *> *env = [NSMutableArray array];
  for (char **e = environ; e != NULL && *e != NULL; e++) {
    NSString *pair = [NSString stringWithUTF8String:*e];
    if (pair == nil) continue;
    // A run's own steps belong to the window that started them; a new window starts clean.
    if ([pair hasPrefix:@"NATIVE_STEPS="] || [pair hasPrefix:@"NATIVE_SNAPSHOT="] ||
        [pair hasPrefix:@"NATIVE_WINDOW_URL="] || [pair hasPrefix:@"NATIVE_WINDOW_NAME="] ||
        [pair hasPrefix:@"NATIVE_WINDOW_ID="] || [pair hasPrefix:@"NATIVE_WINDOW_OPENER="] ||
        [pair hasPrefix:@"NATIVE_WINDOW_OPTIONS="] || [pair hasPrefix:@"NATIVE_WINDOW_WIDTH="] ||
        [pair hasPrefix:@"NATIVE_WINDOW_HEIGHT="]) {
      continue;
    }
    [env addObject:pair];
  }
  NSMutableString *options = [NSMutableString string];
  for (NSString *key in @[@"width", @"height"]) {
    NSString *value = feature_value(features, key);
    if (value == nil) continue;
    if (options.length > 0) [options appendString:@";"];
    [options appendFormat:@"%@=%@", key, value];
    [env addObject:[NSString stringWithFormat:@"NATIVE_WINDOW_%@=%@", key.uppercaseString, value]];
  }
  NSString *left = feature_value(features, @"left");
  NSString *top = feature_value(features, @"top");
  if (left != nil) {
    if (options.length > 0) [options appendString:@";"];
    [options appendFormat:@"x=%@", left];
  }
  if (top != nil) {
    if (options.length > 0) [options appendString:@";"];
    [options appendFormat:@"y=%@", top];
  }
  [env addObject:[NSString stringWithFormat:@"NATIVE_WINDOW_ID=%d", child_id]];
  [env addObject:[NSString stringWithFormat:@"NATIVE_WINDOW_OPENER=%d", g_win_id]];
  [env addObject:[NSString stringWithFormat:@"NATIVE_WINDOW_URL=%@", route]];
  [env addObject:[NSString stringWithFormat:@"NATIVE_WINDOW_NAME=%@", name]];
  [env addObject:[NSString stringWithFormat:@"NATIVE_WINDOW_OPTIONS=%@", options]];

  char *argv[2];
  argv[0] = exe;
  argv[1] = NULL;
  char **envp = (char **)calloc(env.count + 1, sizeof(char *));
  if (envp == NULL) {
    posix_spawn_file_actions_destroy(&actions);
    return -1;
  }
  for (NSUInteger i = 0; i < env.count; i++) envp[i] = strdup([env[i] UTF8String]);
  pid_t pid = 0;
  int rc = posix_spawn(&pid, exe, &actions, NULL, argv, envp);
  for (NSUInteger i = 0; i < env.count; i++) free(envp[i]);
  free(envp);
  posix_spawn_file_actions_destroy(&actions);
  close(to_child[0]);
  close(from_child[1]);
  if (rc != 0) {
    close(to_child[1]);
    close(from_child[0]);
    return -1;
  }
  fcntl(from_child[0], F_SETFL, fcntl(from_child[0], F_GETFL) | O_NONBLOCK);
  int at = g_child_count < MAX_CHILDREN ? g_child_count : MAX_CHILDREN - 1;
  if (g_child_count < MAX_CHILDREN) g_child_count++;
  ChildWindow *w = &g_children[at];
  memset(w, 0, sizeof(*w));
  w->id = child_id;
  w->pid = pid;
  w->write_fd = to_child[1];
  w->read_fd = from_child[0];
  w->open = 1;
  snprintf(w->name, sizeof(w->name), "%s", name.UTF8String == NULL ? "" : name.UTF8String);
  return child_id;
}

int32_t host_window_open(const uint8_t *url, size_t n, const uint8_t *name, size_t name_len,
                         const uint8_t *features, size_t features_len) {
  @autoreleasepool {
    NSString *route = str_from(url, n);
    NSString *wanted = str_from(name, name_len);
    NSString *featureText = str_from(features, features_len);
    if (wanted.length > 0) {
      for (int i = 0; i < g_child_count; i++) {
        if (g_children[i].open && strcmp(g_children[i].name, wanted.UTF8String == NULL ? "" : wanted.UTF8String) == 0) {
          NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:g_children[i].pid];
          [app activateWithOptions:NSApplicationActivateAllWindows];
          return g_children[i].id;
        }
      }
    }
    return spawn_window(route, wanted, featureText);
  }
}

int32_t host_window_id(void) { return g_win_id; }

void host_window_close(int32_t id) {
  if (id <= 0) {
    if (g_window != nil) {
      g_close_approved = 1;
      [g_window close];
    }
    return;
  }
  for (int i = 0; i < g_child_count; i++) {
    if (g_children[i].open && g_children[i].id == id) {
      kill(g_children[i].pid, SIGTERM);
      return;
    }
  }
}

void host_window_focus(int32_t id) {
  if (id <= 0) {
    [NSApp activateIgnoringOtherApps:YES];
    if (g_window != nil) [g_window makeKeyAndOrderFront:nil];
    return;
  }
  for (int i = 0; i < g_child_count; i++) {
    if (g_children[i].open && g_children[i].id == id) {
      NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:g_children[i].pid];
      [app activateWithOptions:NSApplicationActivateAllWindows];
      return;
    }
  }
}

void host_window_blur(void) { [NSApp deactivate]; }

int32_t host_window_closed(void) { return g_closed_child; }

/** A headless run's page size, from the frame the runtime gives the window it doesn't open. */
static double g_headless_w = 0, g_headless_h = 0;

void host_window_set_frame(double x, double y, double w, double h) {
  if (g_window == nil) {
    if (w >= 0) g_headless_w = w;
    if (h >= 0) g_headless_h = h;
    return;
  }
  NSRect frame = g_window.frame;
  if (w >= 0 || h >= 0) {
    NSSize content = g_window.contentLayoutRect.size;
    if (w >= 0) content.width = w;
    if (h >= 0) content.height = h;
    frame = [g_window frameRectForContentRect:NSMakeRect(0, 0, content.width, content.height)];
    frame.origin = g_window.frame.origin;
  }
  NSScreen *screen = g_window.screen != nil ? g_window.screen : [NSScreen mainScreen];
  if (screen != nil) {
    NSRect visible = screen.visibleFrame;
    if (x >= 0) frame.origin.x = visible.origin.x + x;
    if (y >= 0) frame.origin.y = visible.origin.y + visible.size.height - y - frame.size.height;
    // A frame larger than the display keeps the size the page asked for; it is moved so its
    // titlebar and controls stay on the screen.
    if (NSWidth(frame) > NSWidth(visible) || NSHeight(frame) > NSHeight(visible)) {
      frame = frame_kept_on_screen(frame, screen);
    }
  }
  [g_window setFrame:frame display:YES];
}

double host_window_frame(int32_t which) {
  if (g_window == nil) return 0;
  NSRect frame = g_window.frame;
  NSRect visible = g_window.screen != nil ? g_window.screen.visibleFrame : [NSScreen mainScreen].visibleFrame;
  if (which == 0) return frame.origin.x - visible.origin.x;
  if (which == 1) return (visible.origin.y + visible.size.height) - NSMaxY(frame);
  if (which == 2) return frame.size.width;
  return frame.size.height;
}

void host_window_fullscreen(int32_t on) {
  if (g_window == nil) return;
  BOOL now = (g_window.styleMask & NSWindowStyleMaskFullScreen) != 0;
  if ((on != 0) != now) [g_window toggleFullScreen:nil];
}

int32_t host_window_fullscreen_state(void) {
  return g_window != nil && (g_window.styleMask & NSWindowStyleMaskFullScreen) != 0 ? 1 : 0;
}

int32_t host_window_hidden(void) { return g_window != nil && g_window.isMiniaturized ? 1 : 0; }
void host_window_set_hidden(int32_t hidden) {
  if (g_window == nil) return;
  if (hidden != 0 && !g_window.isMiniaturized) [g_window miniaturize:nil];
  else if (hidden == 0 && g_window.isMiniaturized) [g_window deminiaturize:nil];
}
void host_window_minimize(void) {
  if (g_window != nil) [g_window performMiniaturize:nil];
}
void host_window_zoom(void) {
  if (g_window != nil) [g_window zoom:nil];
}

void host_title(text_cb cb) {
  const char *title = g_win_title.UTF8String;
  cb((const uint8_t *)(title == NULL ? "" : title), strlen(title == NULL ? "" : title));
}

void host_post_message(int32_t target, const uint8_t *data, size_t n) {
  @autoreleasepool {
    NSString *json = str_from(data, n);
    if (target == g_win_id) {
      queue_message(g_win_id, json.UTF8String);
      return;
    }
    for (int i = 0; i < g_child_count; i++) {
      if (g_children[i].open && g_children[i].id == target) {
        write_line(g_children[i].write_fd, target, g_win_id, json.UTF8String);
        return;
      }
    }
    write_line(g_parent_write, target, g_win_id, json.UTF8String);
  }
}

int32_t host_message_source(void) { return g_message_from; }

void host_message_data(text_cb cb) {
  const char *data = g_message_data == NULL ? "" : g_message_data;
  cb((const uint8_t *)data, strlen(data));
}

void host_app_action(const uint8_t *action, size_t n) {
  @autoreleasepool {
    NSString *name = str_from(action, n);
    if ([name isEqualToString:@"hide"]) [NSApp hide:nil];
    else if ([name isEqualToString:@"hide-others"]) [NSApp hideOtherApplications:nil];
    else if ([name isEqualToString:@"show-all"]) [NSApp unhideAllApplications:nil];
  }
}

void host_quit(void) {
  close_children();
  g_quit = 1;
}

/**
 * The directory a bundled app's own files were copied into: its .app's Resources when the
 * executable is in one, and otherwise a `<name>.app/Contents/Resources` beside it (what a build
 * leaves next to the path it was asked for), falling back to the executable's own directory.
 */
void host_bundle_dir(text_cb cb) {
  @autoreleasepool {
    NSString *dir = nil;
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    if ([bundlePath hasSuffix:@".app"]) {
      dir = [[NSBundle mainBundle] resourcePath];
    } else {
      NSString *exe = [[NSBundle mainBundle] executablePath];
      NSString *parent = [exe stringByDeletingLastPathComponent];
      NSString *sibling = [parent stringByAppendingPathComponent:
        [[[exe lastPathComponent] stringByAppendingString:@".app"]
          stringByAppendingPathComponent:@"Contents/Resources"]];
      BOOL isDir = NO;
      if ([[NSFileManager defaultManager] fileExistsAtPath:sibling isDirectory:&isDir] && isDir) dir = sibling;
      else dir = parent;
    }
    if (dir == nil) return;
    const char *s = [dir fileSystemRepresentation];
    if (s == NULL) return;
    cb((const uint8_t *)s, strlen(s));
  }
}

int32_t host_poll(double timeout) {
  @autoreleasepool {
    if (g_quit) return EV_QUIT;
    // An image decoded on the pool: the page repaints the pictures that were waiting for it.
    if (take_image_event()) return EV_IMAGE;
    if (g_app_quit) {
      g_app_quit = 0;
      return EV_APPQUIT;
    }
    pump_messages();
    if (take_message()) return EV_MESSAGE;
    if (check_children()) return EV_WINDOWCLOSED;
    if (g_menu_pending) {
      g_menu_pending = 0;
      return EV_MENU;
    }
    if (g_key_state != 0) {
      int32_t ev = g_key_state > 0 ? EV_FOCUS : EV_BLUR;
      g_key_state = 0;
      return ev;
    }
    if (g_visibility_changed) {
      g_visibility_changed = 0;
      return EV_VISIBILITY;
    }
    if (g_moved) {
      g_moved = 0;
      return EV_WINDOWMOVE;
    }
    if (g_fullscreen_changed) {
      g_fullscreen_changed = 0;
      return EV_FULLSCREEN;
    }
    if (g_resized) {
      g_resized = 0;
      return EV_RESIZE;
    }
    if (g_settings_changed) {
      g_settings_changed = 0;
      return EV_SETTINGS;
    }
    // A client's accessibility action goes to the runtime, which runs it on the element: one per
    // poll, in the order they came.
    if (g_ax_queue.count > 0) {
      NSDictionary *action = g_ax_queue.firstObject;
      [g_ax_queue removeObjectAtIndex:0];
      g_ax_action_kind = [action[@"kind"] intValue];
      g_ax_action_uid = [action[@"uid"] intValue];
      g_ax_action_text = action[@"text"];
      g_ex = [action[@"x"] doubleValue];
      g_ey = [action[@"y"] doubleValue];
      return EV_AXACTION;
    }
    // A drag from another app landed on the window: the runtime fires the drop events and reads
    // the files through host_drop_file_count().
    if (g_drop_pending) {
      g_drop_pending = 0;
      return EV_DROP;
    }
    NSEvent *e = [NSApp nextEventMatchingMask:NSEventMaskAny
                                    untilDate:[NSDate dateWithTimeIntervalSinceNow:timeout]
                                       inMode:NSDefaultRunLoopMode
                                      dequeue:YES];
    if (!e) return EV_NONE;
    int32_t kind = EV_OTHER;
    if (e.window == g_window) {
      switch (e.type) {
        case NSEventTypeLeftMouseDown:
          kind = EV_DOWN;
          g_last_down = e;
          // The system's own click counting: two is a double-click at the speed the user set.
          g_clicks = (int32_t)e.clickCount;
          break;
        case NSEventTypeLeftMouseUp: kind = EV_UP; break;
        // The second button is a context menu's press: the page hears contextmenu and decides.
        case NSEventTypeRightMouseDown: kind = EV_CONTEXT; break;
        case NSEventTypeMouseMoved:
        case NSEventTypeLeftMouseDragged: kind = EV_MOVE; break;
        case NSEventTypeMouseExited: kind = EV_LEAVE; break;
        case NSEventTypeKeyUp: kind = EV_KEYUP; break;
        case NSEventTypeScrollWheel: {
          // Finger phase first, then the momentum the system runs after the fingers lift: the page
          // hears where in a gesture each wheel it gets belongs.
          #define WHEEL_PHASE_OF(ev) \
            ((ev).phase != NSEventPhaseNone \
               ? ((ev).phase & NSEventPhaseBegan ? 1 \
                  : (ev).phase & NSEventPhaseEnded ? 3 \
                  : (ev).phase & NSEventPhaseCancelled ? 4 : 2) \
               : ((ev).momentumPhase != NSEventPhaseNone \
                    ? ((ev).momentumPhase & NSEventPhaseBegan ? 5 \
                       : (ev).momentumPhase & NSEventPhaseEnded ? 7 \
                       : (ev).momentumPhase & NSEventPhaseCancelled ? 8 : 6) \
                    : 0))
          kind = EV_WHEEL;
          // Trackpads report precise pixel deltas; wheels report lines.
          double dx = e.hasPreciseScrollingDeltas ? e.scrollingDeltaX : e.scrollingDeltaX * 16;
          double dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 16;
          int32_t phase = WHEEL_PHASE_OF(e);
          // Trackpads send a stream of these while the fingers move, and the page pays a hit test
          // and a scroll listener for each. The deltas of the events already waiting go with this
          // one, so a frame's worth of motion is a single wheel for the page, as in a browser.
          for (int k = 0; k < 128; k++) {
            NSEvent *next = [NSApp nextEventMatchingMask:NSEventMaskScrollWheel
                                               untilDate:[NSDate distantPast]
                                                  inMode:NSDefaultRunLoopMode
                                                 dequeue:YES];
            if (next == nil) break;
            if (next.window != g_window) continue;
            dx += next.hasPreciseScrollingDeltas ? next.scrollingDeltaX : next.scrollingDeltaX * 16;
            dy += next.hasPreciseScrollingDeltas ? next.scrollingDeltaY : next.scrollingDeltaY * 16;
            int32_t p = WHEEL_PHASE_OF(next);
            if (p == 1 || p == 5) phase = p;      // the gesture started in this batch
            else if (p != 0) phase = p;           // where the gesture is now
          }
          g_dx = dx;
          g_dy = dy;
          g_wheel_phase = phase;
          break;
        }
        default: break;
      }
      if (kind != EV_OTHER) {
        NSPoint p = [g_view convertPoint:e.locationInWindow fromView:nil];
        g_ex = p.x;
        g_ey = p.y;
        // The pointer's modifiers travel with its event, so a press can be a Cmd- or Shift-press.
        g_mods = mods_from(e.modifierFlags);
      }
      if (e.type == NSEventTypeKeyDown) {
        // Key events are consumed here rather than sent through the responder chain (which
        // would beep for an unhandled key). A shortcut goes to the menu bar or the runtime's own
        // handling as before; every other key goes through the input client, which turns a
        // layout, a dead key or an input method's composition into the event the runtime wants.
        g_key = KEY_OTHER;
        g_key_text = @"";
        g_key_pending = 0;
        g_compose_phase = -1;
        g_compose_text = @"";
        // The system's auto-repeat is what it is: the same key going down again while held.
        g_key_repeat = e.isARepeat ? 1 : 0;
        g_mods = mods_from(e.modifierFlags);
        if ((g_mods & (MOD_META | MOD_CTRL)) != 0) {
          return translate_key(e, 1) ? EV_KEY : EV_OTHER;
        }
        [g_view interpretKeyEvents:@[ e ]];
        if (g_compose_phase >= 0) return EV_COMPOSE;
        if (g_key_pending) return EV_KEY;
        return translate_key(e, 1) ? EV_KEY : EV_OTHER;
      }
      if (e.type == NSEventTypeKeyUp) {
        // A key-up reports the key it releases, with the modifiers it had. Nothing types on a
        // release, and no menu item is chosen by one.
        g_key = KEY_OTHER;
        g_key_text = @"";
        g_key_repeat = 0;
        g_mods = mods_from(e.modifierFlags);
        translate_key(e, 0);
        return EV_KEYUP;
      }
    }
    [NSApp sendEvent:e];
    if (g_quit) return EV_QUIT;
    return kind;
  }
}

static int verify_enabled(void);
static void verify_capture_full(double width, double height);

/** How many clicks the last mouse-down was: 2 for a double-click, 3 for a triple-click. */
int32_t host_event_clicks(void) { return g_clicks; }

/** One edge of the titlebar area (0 x, 1 y, 2 width, 3 height); all 0 with a default titlebar. */
double host_titlebar_area(int32_t which) {
  update_titlebar_area();
  return which == 0 ? g_tb_x : which == 1 ? g_tb_y : which == 2 ? g_tb_w : g_tb_h;
}

/** Moves the window with the pointer from the last mouse-down until the button is released, as
 *  a titlebar does; a double-click zooms the window instead. Returns when the drag ends. */
void host_window_drag(void) {
  if (!g_window || !g_last_down) return;
  if (g_last_down.clickCount == 2) {
    [g_window performZoom:nil];
    return;
  }
  [g_window performWindowDragWithEvent:g_last_down];
}

/** Draws the frame on the window's compositor; defined with the window's compositing below. */
static int window_composite(void);

/** Composites a headless frame as the window would; defined with the window's compositing. */
static void headless_live_composite(void);

void host_present(double width, double height) {
  if (!g_view) {
    headless_live_composite();
    return;
  }
  double started = frame_times() ? now_ms() : 0;
  int composited = 0;
  @autoreleasepool {
    composited = window_composite();
    if (!composited) {
      // A pool of its own: AppKit's display path autoreleases the graphics stack it builds for the
      // frame (a graphics context, its display list and the glyphs recorded in it), and the app's
      // main loop never returns to AppKit's own pool, so without this every frame's stack stays.
      [g_view setNeedsDisplay:YES];
      [g_view displayIfNeeded];
    }
  }
  if (frame_times()) {
    double total = now_ms() - started;
    if (composited) fprintf(stderr, "native: composite %g ms\n", total);
    else fprintf(stderr, "native: present %g ms replay %g ms\n", total - g_last_replay_ms, g_last_replay_ms);
  }
  if (verify_enabled()) verify_capture_full(width, height);
}

/** Whether the window path hands frames to the compositor; a damage-limited frame asks the host
 *  first whether it can patch the picture the last frame presented. */
int32_t host_compositor_on(void) { return window_compositing(); }

/** Whether every backdrop-filtered box the retained list holds has a kept image: only then can a
 *  region present draw them back instead of filtering over the pixels the window keeps. */
static int backdrop_cache_ready(void) {
  for (int l = -1; l < g_layer_count; l++) {
    CmdList *list = l < 0 ? &g_root : &g_layers[l].list;
    for (size_t i = 0; i < list->count; i++) {
      Cmd *c = &list->cmds[i];
      if (c->kind != CMD_EFFECT_PUSH || c->text == NULL) continue;
      EffectSpec spec;
      effect_spec_parse(&spec, c->text);
      if (spec.bcount == 0) continue;
      int hit = 0;
      for (int k = 0; k < MAX_BACKDROPS; k++) {
        if (g_backdrops[k].used && g_backdrops[k].serial == c->serial) { hit = 1; break; }
      }
      if (!hit) return 0;
    }
  }
  return 1;
}

/** Presents a compositor frame over the retained backing: the display list is whole, but only
 *  the rectangles the frame moved are marked for display. */
void host_present_region(const uint8_t *rects, size_t n, double width, double height) {
  if (!g_view) {
    // A headless run composites its frame the way the window would, whole list and all.
    headless_live_composite();
    return;
  }
  if (g_needs_backdrop && !backdrop_cache_ready()) {
    // A backdrop filter reads pixels outside the moved rectangles, and nothing was kept for one
    // of them: replay the whole frame.
    host_present(width, height);
    return;
  }
  if (window_compositing()) {
    // A transform-only frame is the compositor's own work: the tiles stay and are drawn again
    // under the new matrices, and the frame becomes the picture a damaged frame patches next.
    // A picture the compositor couldn't chunk is not patchable: the window shows that picture,
    // not the view's backing, so the frame is presented whole instead of over a backing that
    // never held it.
    host_present(width, height);
    return;
  }
  // The frame is drawn by the view instead, so the picture no longer matches what it shows.
  g_pic_cur = -1;
  parse_damage_rects(rects, n);
  g_present_region = 1;
  // Only compositor properties moved, so nothing behind a backdrop filter changed: its kept
  // result is still what the box shows.
  g_reuse_backdrops = 1;
  @autoreleasepool {
    for (int i = 0; i < g_damage_count; i++) {
      const double *r = g_damage_rects[i];
      [g_view setNeedsDisplayInRect:NSMakeRect(r[0], r[1], r[2], r[3])];
    }
    [g_view displayIfNeeded];
  }
  g_reuse_backdrops = 0;
  g_present_region = 0;
}

/** Presents only the damaged rectangles: the view keeps the rest of its backing. */
void host_present_damage(const uint8_t *rects, size_t n, double width, double height) {
  if (!g_view) return;
  parse_damage_rects(rects, n);
  // A compositing window patches its chunk list instead of drawing the view's backing.
  if (g_damage_frame && window_compositing() && window_composite()) {
    g_damage_frame = 0;
    return;
  }
  @autoreleasepool {
    for (int i = 0; i < g_damage_count; i++) {
      const double *r = g_damage_rects[i];
      [g_view setNeedsDisplayInRect:NSMakeRect(r[0], r[1], r[2], r[3])];
    }
    [g_view displayIfNeeded];
  }
}

// Rasters the flat list as premultiplied RGBA in device pixels; defined with the compositor,
// which uses it for the frames its walk can't express.
static int raster_flat_rgba(double scale, int pw, int ph, unsigned char **out);

static unsigned char *g_mac_verify_px = NULL;
static int g_mac_verify_w = 0, g_mac_verify_h = 0;
/** The pixels the last presented frame left, the base a damaged frame is replayed over. */
static unsigned char *g_mac_prev_px = NULL;
static int g_mac_prev_w = 0, g_mac_prev_h = 0;

static int verify_enabled(void) { return getenv("NATIVE_VERIFY_DAMAGE") != NULL; }

/** Keeps a full frame's pixels as the base the next damaged frame is replayed over. */
static void verify_capture_full(double width, double height) {
  int pw = (int)ceil(width), ph = (int)ceil(height);
  if (pw <= 0 || ph <= 0) return;
  unsigned char *rgba = NULL;
  if (!raster_flat_rgba(1.0, pw, ph, &rgba)) return;
  free(g_mac_prev_px);
  g_mac_prev_px = rgba;
  g_mac_prev_w = pw;
  g_mac_prev_h = ph;
}

void host_damage_reference(double width, double height) {
  free(g_mac_verify_px);
  g_mac_verify_px = NULL;
  g_mac_verify_w = g_mac_verify_h = 0;
  int pw = (int)ceil(width), ph = (int)ceil(height);
  if (pw <= 0 || ph <= 0) return;
  unsigned char *rgba = NULL;
  if (!raster_flat_rgba(1.0, pw, ph, &rgba)) return;
  g_mac_verify_px = rgba;
  g_mac_verify_w = pw;
  g_mac_verify_h = ph;
}

int32_t host_verify_damage(const uint8_t *rects, size_t n, double width, double height) {
  parse_damage_rects(rects, n);
  if (g_mac_verify_px == NULL) {
    fprintf(stderr, "native: damage verify no reference\n");
    return -1;
  }
  int pw = (int)ceil(width), ph = (int)ceil(height);
  if (pw <= 0 || ph <= 0 || pw > 16384 || ph > 16384) return -1;
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreate(NULL, (size_t)pw, (size_t)ph, 8, 0, cs,
                                           (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(cs);
  if (ctx == NULL) return -1;
  unsigned char *data = CGBitmapContextGetData(ctx);
  size_t stride = CGBitmapContextGetBytesPerRow(ctx);
  // The base is the frame the damaged list was applied to; a pixel it forgot stays as the old
  // frame left it and differs from the new reference.
  const unsigned char *base = g_mac_prev_px;
  int base_w = g_mac_prev_w, base_h = g_mac_prev_h;
  if (base == NULL || base_w != pw || base_h != ph) {
    base = g_mac_verify_px;
    base_w = g_mac_verify_w;
    base_h = g_mac_verify_h;
  }
  if (data != NULL && base != NULL) {
    for (int y = 0; y < ph && y < base_h; y++) {
      memcpy(data + (size_t)y * stride, base + (size_t)y * (size_t)base_w * 4u,
             (size_t)(pw < base_w ? pw : base_w) * 4u);
    }
  }
  CGContextTranslateCTM(ctx, 0, ph);
  CGContextScaleCTM(ctx, 1, -1);
  int saved = g_layer_images_on;
  int saved_region = g_present_region;
  g_layer_images_on = 0;
  g_present_region = 1;
  replay(ctx, width, height);
  g_present_region = saved_region;
  g_layer_images_on = saved;
  CGContextFlush(ctx);
  long bad = 0;
  for (int i = 0; i < g_damage_count; i++) {
    int x0 = (int)floor(g_damage_rects[i][0]), y0 = (int)floor(g_damage_rects[i][1]);
    int x1 = (int)ceil(g_damage_rects[i][0] + g_damage_rects[i][2]);
    int y1 = (int)ceil(g_damage_rects[i][1] + g_damage_rects[i][3]);
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > pw) x1 = pw;
    if (y1 > ph) y1 = ph;
    for (int y = y0; y < y1 && y < g_mac_verify_h; y++) {
      for (int x = x0; x < x1 && x < g_mac_verify_w; x++) {
        const unsigned char *a = data + (size_t)y * stride + (size_t)x * 4;
        const unsigned char *b = g_mac_verify_px + ((size_t)y * (size_t)g_mac_verify_w + (size_t)x) * 4;
        if (a[0] != b[0] || a[1] != b[1] || a[2] != b[2] || a[3] != b[3]) bad++;
      }
    }
  }
  // A pixel outside every rectangle is the old frame's: one that differs from the reference is
  // stale paint the damage missed (a highlight a change didn't repaint), which the count inside the
  // rectangles can't see.
  long frame = 0;
  for (int y = 0; y < ph && y < g_mac_verify_h; y++) {
    for (int x = 0; x < pw && x < g_mac_verify_w; x++) {
      const unsigned char *a = data + (size_t)y * stride + (size_t)x * 4;
      const unsigned char *b = g_mac_verify_px + ((size_t)y * (size_t)g_mac_verify_w + (size_t)x) * 4;
      if (a[0] != b[0] || a[1] != b[1] || a[2] != b[2] || a[3] != b[3]) frame++;
    }
  }
  fprintf(stderr, "native: damage verify mismatched=%ld rects=%d frame=%ld\n", bad, g_damage_count, frame);
  // The damaged frame is now what the window shows: keep it for the next verification.
  free(g_mac_prev_px);
  g_mac_prev_px = (unsigned char *)malloc((size_t)pw * 4u * (size_t)ph);
  if (g_mac_prev_px != NULL && data != NULL) {
    for (int y = 0; y < ph; y++) memcpy(g_mac_prev_px + (size_t)y * (size_t)pw * 4u, data + (size_t)y * stride, (size_t)pw * 4u);
    g_mac_prev_w = pw;
    g_mac_prev_h = ph;
  }
  CGContextRelease(ctx);
  free(g_mac_verify_px);
  g_mac_verify_px = NULL;
  return (int32_t)bad;
}

// Renders the current display list offscreen and writes a PNG. Returns 1 on success. With
// `cached`, every layer draws from the raster the window path keeps for it, so the picture is the
// window's own; without, every command is replayed, which is the reference both are held to.
// ---------------------------------------------------------------------------
// Metal composited snapshots
//
// The window's picture, built the way the compositor will: the paint is split into chunks (the
// shared walker), each chunk is rastered with its state, uploaded as a texture, and the chunks
// are composited in paint order through the Metal backend. A frame the walker can't express falls
// back to the CoreGraphics replay.

/** The box a polygon's points cover, as "x,y x,y" pairs with subpaths split by ';'. Answers 0 when
 *  it has no points, so the command is one that paints nothing. */
static int poly_box(const char *s, double *x, double *y, double *w, double *h) {
  double minx = 0, miny = 0, maxx = 0, maxy = 0;
  int any = 0;
  const char *q = s;
  while (q != NULL && *q != 0) {
    char *end = NULL;
    double px = strtod(q, &end);
    if (end == q) { q++; continue; }
    q = end;
    while (*q == ' ' || *q == ',') q++;
    double py = strtod(q, &end);
    if (end == q) break;
    q = end;
    if (!any) {
      minx = maxx = px;
      miny = maxy = py;
      any = 1;
    } else {
      if (px < minx) minx = px;
      if (px > maxx) maxx = px;
      if (py < miny) miny = py;
      if (py > maxy) maxy = py;
    }
  }
  if (!any) return 0;
  *x = minx; *y = miny; *w = maxx - minx; *h = maxy - miny;
  return 1;
}

/** Whether the compositor draws a canvas command from the canvas's own texture: a whole canvas
 *  (not a slice of one, as a border image cuts), 2D or a WebGL canvas that presents into IOSurfaces.
 *  `NATIVE_CANVAS_TEXTURE=0` rasters every canvas into its chunk instead. */
static int canvas_draws_external(const Cmd *c) {
  static int on = -1;
  if (on < 0) {
    const char *env = getenv("NATIVE_CANVAS_TEXTURE");
    on = !(env != NULL && env[0] == '0' && env[1] == 0);
  }
  if (!on || c->kind != CMD_CANVAS || c->sw > 0 || c->sh > 0) return 0;
  Canvas *cv = canvas_at(c->image);
  if (cv == NULL || cv->ctx == NULL || cv->w < 1 || cv->h < 1) return 0;
  if (cv->gl != NULL) return cv->gl->surf_cur >= 0 && cv->gl->surf[cv->gl->surf_cur] != NULL;
  return 1;
}

static int metal_cmd_count(void *ctx, int list_id) {
  (void)ctx;
  if (list_id < 0) return (int)g_root.count;
  if (list_id >= g_layer_count) return -1;
  return (int)g_layers[list_id].list.count;
}

static int metal_cmd_view(void *ctx, int list_id, int index, CompCmdView *out) {
  (void)ctx;
  CmdList *l = list_id < 0 ? &g_root : &g_layers[list_id].list;
  if (index < 0 || (size_t)index >= l->count) return 0;
  Cmd *c = &l->cmds[index];
  memset(out, 0, sizeof(*out));
  out->serial = c->serial;
  switch (c->kind) {
    case CMD_TRANSFORM:
      out->kind = COMP_CMD_TRANSFORM;
      out->matrix.m[0] = (float)c->p0;
      out->matrix.m[1] = (float)c->p1;
      out->matrix.m[4] = (float)c->p2;
      out->matrix.m[5] = (float)c->p3;
      out->matrix.m[10] = 1.0f;
      out->matrix.m[12] = (float)c->r[0];
      out->matrix.m[13] = (float)c->r[1];
      out->matrix.m[15] = 1.0f;
      return 1;
    case CMD_CLIP:
      out->kind = COMP_CMD_CLIP;
      out->x = c->x; out->y = c->y; out->w = c->w; out->h = c->h;
      return 1;
    case CMD_CLIP_ROUND: {
      out->kind = COMP_CMD_CLIP_ROUND;
      out->x = c->x; out->y = c->y; out->w = c->w; out->h = c->h;
      double r = 0;
      for (int k = 0; k < 8; k++) if (c->r[k] > r) r = c->r[k];
      out->radius = r;
      return 1;
    }
    case CMD_CLIP_POLY:
    case CMD_CLIP_ELLIPSE:
    case CMD_CLIP_SHAPE:
      out->kind = COMP_CMD_CLIP_SHAPED;
      return 1;
    case CMD_EFFECT_PUSH: {
      EffectSpec spec;
      effect_spec_parse(&spec, c->text);
      out->kind = COMP_CMD_EFFECT;
      out->alpha = (float)spec.alpha;
      out->simple = spec.count == 0 && spec.bcount == 0 && spec.blend == 0;
      // A backdrop filter shows the pixels behind it, so a mask that holds one stays whole.
      out->backdrop = spec.bcount != 0;
      return 1;
    }
    case CMD_UNCLIP:
    case CMD_EFFECT_POP:
      out->kind = COMP_CMD_POP;
      return 1;
    case CMD_LAYER_REF:
      out->kind = COMP_CMD_LAYER_REF;
      out->layer = c->layer;
      return 1;
    // The one kind carries how it opens, splits and closes: the walk needs to know which mask
    // command closes the state the push opened.
    case CMD_MASK_PUSH:
      out->kind = COMP_CMD_MASK;
      out->op = 0;
      // The box the mask covers in the page, which a host that splits the mask measures its
      // surfaces by (the flat replay takes the same box, through the state it sits in).
      out->x = c->x;
      out->y = c->y;
      out->w = c->w;
      out->h = c->h;
      return 1;
    case CMD_MASK_SPLIT:
      out->kind = COMP_CMD_MASK;
      out->op = 1;
      return 1;
    case CMD_MASK_POP:
      out->kind = COMP_CMD_MASK;
      out->op = 2;
      return 1;
    case CMD_PERSPECTIVE_PUSH:
      out->kind = COMP_CMD_PERSPECTIVE;
      out->op = 0;
      return 1;
    case CMD_PERSPECTIVE_POP:
      out->kind = COMP_CMD_PERSPECTIVE;
      out->op = 2;
      return 1;
    default: {
      out->kind = COMP_CMD_DRAW;
      out->external = canvas_draws_external(c);
      // The box the command paints into, padded for the antialiased edge and, for a shadow, the
      // ground it covers, so a layer rastered from its box never cuts its own drawing off.
      double pad = 2;
      if (c->kind == CMD_SHADOW || c->kind == CMD_SHADOW_INSET || c->kind == CMD_TEXT_SHADOW) {
        // Both offsets, the spread, and the blur's tail, which CoreGraphics draws past the radius.
        pad += fabs(c->dx) + fabs(c->dy) + 2 * fabs(c->blur) + fabs(c->line_width);
      }
      // A text-emphasis mark sits off the run's advance, outside the box the run reports.
      if (c->emphasis != 0) pad += 12;
      double x = c->x, y = c->y, w = c->w, h = c->h;
      if (c->kind == CMD_TEXT || c->kind == CMD_TEXT_SHADOW) {
        // A run records where its line starts, not the advance the host measured when it shaped
        // the text, so its box is worked out from the size: an em and the spacing for each
        // character, a line box and the font's own height. The estimate only has to be generous —
        // extra pixels cost a little raster, while a box short of the run would cut the glyphs out
        // of the chunk's raster. With no box at all the run would look like a command that paints
        // nothing and be left out of the frame.
        w = (double)c->len * (c->size + fabs(c->letter) + fabs(c->word));
        h = (c->line_height > c->size * 1.4 ? c->line_height : c->size * 1.4) + c->size * 0.5;
        // A slanted run leans a little past the point its line starts at, and a line box can be
        // shorter than the fonts inside it.
        pad += c->size * 0.25;
        out->empty = c->len == 0;
      } else if (c->kind == CMD_POLY) {
        // A polygon's box is its points': filled borders and diagonal sides are recorded that way.
        out->empty = !poly_box(c->text, &x, &y, &w, &h);
        if (out->empty) return 1;
      } else {
        out->empty = c->w <= 0 && c->h <= 0;
      }
      out->x = x - pad;
      out->y = y - pad;
      out->w = w + 2 * pad;
      out->h = h + 2 * pad;
      out->boxed = 1;
      return 1;
    }
  }
}

static const CompCmdSource METAL_CHUNK_SOURCE = { metal_cmd_count, metal_cmd_view };

/** Rasters a chunk's commands under `m`, with its clip state baked when `clips` is set, into the
 *  device-space `region` and cropped to its ink there, as premultiplied RGBA. */
static int raster_chunk_rgba(const CompWalkChunk *c, const CompMatrix *m, int clips, CompRect region,
                             unsigned char **out, int *ox, int *oy, int *ow, int *oh) {
  int pw = region.w, ph = region.h;
  if (pw <= 0 || ph <= 0) return 0;
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef bctx = CGBitmapContextCreate(NULL, (size_t)pw, (size_t)ph, 8, 0, cs,
                                            (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(cs);
  if (bctx == NULL) return 0;
  CGContextTranslateCTM(bctx, 0, ph);
  CGContextScaleCTM(bctx, 1, -1);
  // The bitmap's own pixels are the region, so device coordinates are moved to its corner.
  CGContextTranslateCTM(bctx, -(double)region.x, -(double)region.y);
  // The chunk's clips are in device pixels, so they go on in the flipped space before the page's
  // own matrix: a clip that moves with a transform is already part of that chunk's state.
  for (int k = 0; clips && k < c->clip_count; k++) {
    const CompWalkClip *cl = &c->clips[k];
    CGRect rect = CGRectMake(cl->x, cl->y, cl->w, cl->h);
    CGPathRef path = cl->r > 0
        ? CGPathCreateWithRoundedRect(rect, cl->r, cl->r, NULL)
        : CGPathCreateWithRect(rect, NULL);
    if (path != NULL) {
      CGContextAddPath(bctx, path);
      CGContextClip(bctx);
      CGPathRelease(path);
    }
  }
  CGAffineTransform tm = CGAffineTransformMake(m->m[0], m->m[1], m->m[4], m->m[5],
                                               m->m[12], m->m[13]);
  CGContextConcatCTM(bctx, tm);
  CGContextSetTextMatrix(bctx, CGAffineTransformMakeScale(1, -1));
  CmdList *ll = c->list_id < 0 ? &g_root : &g_layers[c->list_id].list;
  CmdList *saved = g_list;
  g_list = ll;
  size_t saved_limit = g_replay_limit;
  g_replay_limit = (size_t)(c->first + c->count);
  ReplayState st;
  st.depth = 0;
  st.transforms = c->transforms;
  replay_range(bctx, (size_t)c->first, &st);
  g_replay_limit = saved_limit;
  g_list = saved;
  const unsigned char *data = CGBitmapContextGetData(bctx);
  size_t stride = CGBitmapContextGetBytesPerRow(bctx);
  int minx = pw, miny = ph, maxx = -1, maxy = -1;
  if (data != NULL) {
    for (int y = 0; y < ph; y++) {
      const unsigned char *row = data + (size_t)y * stride;
      for (int x = 0; x < pw; x++) {
        if (row[x * 4 + 3] == 0) continue;
        if (x < minx) minx = x;
        if (x > maxx) maxx = x;
        if (y < miny) miny = y;
        if (y > maxy) maxy = y;
      }
    }
  }
  if (maxx < minx || maxy < miny) {
    CGContextRelease(bctx);
    return 0;
  }
  int w = maxx - minx + 1, h = maxy - miny + 1;
  unsigned char *rgba = (unsigned char *)malloc((size_t)w * 4u * (size_t)h);
  if (rgba == NULL) {
    CGContextRelease(bctx);
    return 0;
  }
  for (int y = 0; y < h; y++) {
    const unsigned char *src = data + (size_t)(miny + y) * stride + (size_t)minx * 4u;
    unsigned char *dst = rgba + (size_t)y * (size_t)w * 4u;
    memcpy(dst, src, (size_t)w * 4u);
  }
  CGContextRelease(bctx);
  *out = rgba;
  *ox = region.x + minx;
  *oy = region.y + miny;
  *ow = w;
  *oh = h;
  return 1;
}

/** Writes a straight-RGBA buffer as a PNG, or returns 0. */
static int write_rgba_png(const uint8_t *path, size_t path_len, int pw, int ph, unsigned char *rgba) {
  CGDataProviderRef prov = CGDataProviderCreateWithData(NULL, rgba, (size_t)pw * 4u * (size_t)ph, NULL);
  if (prov == NULL) return 0;
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGImageRef img = CGImageCreate((size_t)pw, (size_t)ph, 8, 32, (size_t)pw * 4u, cs,
                                 (CGBitmapInfo)kCGImageAlphaLast, prov, NULL, false,
                                 kCGRenderingIntentDefault);
  CGColorSpaceRelease(cs);
  CGDataProviderRelease(prov);
  if (img == NULL) return 0;
  NSString *pathStr = str_from(path, path_len);
  NSURL *url = [NSURL fileURLWithPath:pathStr];
  CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
  if (dst == NULL) {
    CGImageRelease(img);
    return 0;
  }
  CGImageDestinationAddImage(dst, img, NULL);
  bool ok = CGImageDestinationFinalize(dst);
  CFRelease(dst);
  CGImageRelease(img);
  return ok ? 1 : 0;
}

/** The window's compositor backend, made on first use; NULL when the machine draws no Metal. */
static CompBackend *window_backend(void);
/** Composites the frame into `target` (-1 for the window's drawable); defined below. */
static int composite_frame_into(CompBackend *b, int target, double scale, int pw, int ph);

/** 1 written, 0 failed, -1 when the frame belongs to the CoreGraphics path. */
static int32_t snapshot_metal(const uint8_t *path, size_t path_len, double width, double height,
                              double scale) {
  // The picture is the window's own: the same chunks, tiles and matrices the window draws.
  CompBackend *b = window_backend();
  if (b == NULL) return -1;
  int pw = (int)(width * scale), ph = (int)(height * scale);
  if (pw <= 0 || ph <= 0) return -1;
  int tex = b->vt->tex_create(b, pw, ph);
  if (tex < 0) return -1;
  int done = composite_frame_into(b, tex, scale, pw, ph);
  unsigned char *out = NULL;
  int ok = 0;
  if (done) {
    out = (unsigned char *)malloc((size_t)pw * 4u * (size_t)ph);
    if (out != NULL && b->vt->readback(b, -1, (CompRect){0, 0, pw, ph}, out, pw * 4)) {
      ok = write_rgba_png(path, path_len, pw, ph, out);
    }
  }
  free(out);
  b->vt->tex_destroy(b, tex);
  return done ? ok : -1;
}

// ---------------------------------------------------------------------------
// The window's compositor
//
// The window draws its frame on a CAMetalLayer. Each chunk of the paint is rastered once into
// tiles that stay as textures; a frame that only moves a layer's transform or opacity draws those
// tiles again with the new matrix, so CoreGraphics does no work until the page paints again. A
// frame the walk can't express is rastered whole, which is what the replay drew anyway.

/** How many tile textures the cache may hold; past it a chunk is drawn for its frame only. */
#define WIN_TILE_BUDGET 2048

typedef struct {
  int tex;
  CompRect rect; // where the tile sits in the chunk's raster space, in device pixels
} WinTile;

typedef struct {
  // What the tiles are a picture of: a hash of the chunk's commands and of the state its raster
  // bakes in (see chunk_key). 0 for a chunk whose pixels its commands don't pin down, such as a
  // canvas, which only a frame of the same paint may keep.
  uint64_t key;
  int list_id, first, count;
  int own; // rastered in the layer's own space, so the compositor can move it with a matrix
  int transient; // drawn this frame only: the budget was full, so the tiles are dropped after
  int tex_count;
  WinTile *tiles;
  CompMatrix raster_m; // the matrix a chunk whose state is baked in was rastered with
  int pending; // this frame queued its raster and has not taken the pixels yet
  unsigned long serial; // the paint the tiles were made in; 0 when the entry has no picture
  int ext; // drawn from its canvas's own texture: no tiles, nothing rastered
} WinChunk;

static CompBackend *g_window_backend = NULL; // declared with the canvases above
static int g_window_comp = -1; // -1 not asked yet, 0 the replay draws the window, 1 the compositor
static int g_win_stats = -1;
static int g_flat_tex = -1;    // the whole-frame raster a walk the compositor can't express draws
static double g_flat_replay_ms = 0; // how long the replay behind that raster took
static int g_flat_w = 0, g_flat_h = 0;
static double g_win_scale = 0; // the device scale the cached tiles were rastered at
static WinChunk g_win_chunks[COMP_MAX_LAYERS];
static int g_win_count = 0;
static int g_win_tiles = 0;

/** Whether a damaged frame can patch the last picture: the picture has to be there to patch, and
 *  the runtime has to have named what it changed, so the frame is a damage frame and not a full
 *  paint it chose to present as one. */
int32_t host_damage_can_merge(const uint8_t *serials, size_t n, const uint8_t *rects, size_t m) {
  (void)serials; // the boxes are named; the picture is patched over their rectangles
  (void)rects;
  if (!window_compositing() || g_pic_cur < 0 || n == 0 || m == 0) return 0;
  // The picture holds the last frame at the size it was drawn: a window that changed size has
  // none of this frame's size to patch, and a damaged list painted as a whole frame would show
  // the rest of the page empty. The frame paints the page whole instead.
  double scale = g_view != nil && g_view.window != nil ? (double)g_view.window.backingScaleFactor
                                                       : host_backing_scale();
  int pw = (int)lround(host_view_width() * scale);
  int ph = (int)lround(host_view_height() * scale);
  if (pw <= 0 || ph <= 0 || g_pic_w != pw || g_pic_h != ph) return 0;
  return 1;
}

/** Whether a headless run composites every frame it presents the way the window does, into a
 *  texture a composited snapshot reads back: `NATIVE_COMPOSITOR_LIVE=1`, for tests that hold the
 *  window's own frames to the flat replay. */
static int headless_live(void) {
  const char *env = getenv("NATIVE_COMPOSITOR_LIVE");
  return env != NULL && env[0] == '1' && env[1] == 0;
}
static int g_live_tex = -1, g_live_w = 0, g_live_h = 0; // the last frame a headless run presented

/** Whether NATIVE_COMPOSITOR leaves the window to the compositor; `NATIVE_COMPOSITOR=0` doesn't. */
static int window_compositing(void) {
  const char *env = getenv("NATIVE_COMPOSITOR");
  return !(env != NULL && env[0] == '0' && env[1] == 0);
}

static void mask_surfaces_drop(void);

/** Drops the tiles a chunk holds, returning them to the budget. */
static void win_drop_tiles(WinChunk *e) {
  if (g_window_backend != NULL) {
    for (int i = 0; i < e->tex_count; i++) {
      if (e->tiles[i].tex >= 0) g_window_backend->vt->tex_destroy(g_window_backend, e->tiles[i].tex);
    }
  }
  // A transient chunk's tiles were never counted, since its frame draws them and drops them.
  if (!e->transient) g_win_tiles -= e->tex_count;
  if (g_win_tiles < 0) g_win_tiles = 0;
  free(e->tiles);
  e->tiles = NULL;
  e->tex_count = 0;
  e->serial = 0;
  e->key = 0;
  e->own = 0;
  e->transient = 0;
}

/** Drops the pictures a damaged frame would patch, for a new scale or a new frame the cache can't
 *  describe. */
static void win_pic_drop(CompBackend *b) {
  for (int i = 0; i < 2; i++) {
    if (g_pic_tex[i] >= 0 && b != NULL) b->vt->tex_destroy(b, g_pic_tex[i]);
    g_pic_tex[i] = -1;
  }
  if (g_patch_tex >= 0 && b != NULL) b->vt->tex_destroy(b, g_patch_tex);
  g_patch_tex = -1;
  g_patch_w = g_patch_h = 0;
  g_pic_cur = -1;
  g_pic_w = g_pic_h = 0;
}

/** Drops every tile, for a new scale or a new frame the cache can't describe. */
static void win_drop_all(void) {
  for (int i = 0; i < g_win_count; i++) win_drop_tiles(&g_win_chunks[i]);
  mask_surfaces_drop();
  g_win_count = 0;
  g_win_tiles = 0;
  g_win_scale = 0;
  win_pic_drop(g_window_backend);
}

/** Makes sure there are two picture textures of the frame's size; answers 0 when there aren't. */
static int win_pic_ensure(CompBackend *b, int pw, int ph) {
  if (g_pic_w == pw && g_pic_h == ph && g_pic_tex[0] >= 0 && g_pic_tex[1] >= 0) return 1;
  win_pic_drop(b);
  g_pic_tex[0] = b->vt->tex_create(b, pw, ph);
  g_pic_tex[1] = b->vt->tex_create(b, pw, ph);
  if (g_pic_tex[0] < 0 || g_pic_tex[1] < 0) {
    win_pic_drop(b);
    return 0;
  }
  g_pic_w = pw;
  g_pic_h = ph;
  return 1;
}

/** Draws a frame's picture into `target` as it is: its pixels are premultiplied and already hold
 *  the page's background, so the copy is the picture itself. `tex` is the backend texture the
 *  picture was drawn into, as `g_pic_tex[pic]` holds it: a picture's slot is not its texture id. */
static void win_pic_show(CompBackend *b, int target, int tex, int pw, int ph) {
  b->vt->pass_begin(b, target, pw, ph, 0);
  CompMatrix M = comp_matrix_identity();
  b->vt->draw_quad(b, tex, (CompRect){0, 0, pw, ph}, &M, 1.0f, NULL, 0.0f);
  b->vt->present(b);
}

/** Cuts a chunk's raster into tiles, uploads them, and records where each sits. */
static int win_upload_tiles(WinChunk *e, const unsigned char *rgba, CompRect ink) {
  int count = comp_tile_count(ink);
  if (count <= 0) return 0;
  e->tiles = (WinTile *)calloc((size_t)count, sizeof(WinTile));
  if (e->tiles == NULL) return 0;
  for (int t = 0; t < count; t++) {
    CompRect tile;
    if (!comp_tile_at(ink, t, &tile)) break;
    int x0 = tile.x > ink.x ? tile.x : ink.x;
    int y0 = tile.y > ink.y ? tile.y : ink.y;
    int x1 = tile.x + tile.w < ink.x + ink.w ? tile.x + tile.w : ink.x + ink.w;
    int y1 = tile.y + tile.h < ink.y + ink.h ? tile.y + tile.h : ink.y + ink.h;
    if (x1 <= x0 || y1 <= y0) continue;
    int w = x1 - x0, h = y1 - y0;
    unsigned char *sub = (unsigned char *)malloc((size_t)w * 4u * (size_t)h);
    if (sub == NULL) continue;
    for (int row = 0; row < h; row++) {
      memcpy(sub + (size_t)row * (size_t)w * 4u,
             rgba + ((size_t)(y0 - ink.y + row) * (size_t)ink.w + (size_t)(x0 - ink.x)) * 4u,
             (size_t)w * 4u);
    }
    int tex = g_window_backend->vt->tex_create(g_window_backend, w, h);
    if (tex >= 0) {
      g_window_backend->vt->tex_upload(g_window_backend, tex, (CompRect){0, 0, w, h}, sub, w * 4);
      e->tiles[e->tex_count].tex = tex;
      e->tiles[e->tex_count].rect = (CompRect){x0, y0, w, h};
      e->tex_count++;
      if (!e->transient) g_win_tiles++;
    }
    free(sub);
  }
  return e->tex_count;
}

/**
 * The clips of a chunk rastered in its layer's own space. A plain clip (an integer device rect)
 * is a scissor when the tiles are drawn, `scissor`, the rect every plain clip agrees on, or a zero
 * rect when there is none. Any other clip — rounded, or off the pixel grid — is baked into the
 * raster: `baked` is the chunk with those clips mapped back through the matrix the compositor
 * draws its tiles with, so a clip that moves with the layer's transform is the same clip every
 * frame and the tiles are kept. Answers 0 when a clip can't be mapped back (the layer is rotated
 * or skewed, or scaled unevenly under a rounded clip), and the chunk is rastered at its device
 * matrix instead. `has_scissor` says whether there was a plain clip at all.
 */
static int own_space_clips(const CompWalkChunk *c, double scale, CompWalkChunk *baked,
                           CompRect *scissor, int *has_scissor) {
  *baked = *c;
  baked->clip_count = 0;
  memset(scissor, 0, sizeof(*scissor));
  *has_scissor = 0;
  // The tiles' own pixels to the device: the chunk's matrix after the device scale is taken off.
  double sx = c->m.m[0] / scale, sy = c->m.m[5] / scale;
  double tx = c->m.m[12], ty = c->m.m[13];
  int axis = fabs(c->m.m[1]) < 1e-6 && fabs(c->m.m[4]) < 1e-6 && sx > 1e-6 && sy > 1e-6;
  for (int k = 0; k < c->clip_count; k++) {
    const CompWalkClip *cl = &c->clips[k];
    int plain = cl->r <= 0 && cl->x == (double)(int)cl->x && cl->y == (double)(int)cl->y &&
                cl->w == (double)(int)cl->w && cl->h == (double)(int)cl->h;
    if (plain) {
      CompRect r = {(int)cl->x, (int)cl->y, (int)cl->w, (int)cl->h};
      if (!*has_scissor) {
        *scissor = r;
        *has_scissor = 1;
        continue;
      }
      int x0 = r.x > scissor->x ? r.x : scissor->x;
      int y0 = r.y > scissor->y ? r.y : scissor->y;
      int x1 = r.x + r.w < scissor->x + scissor->w ? r.x + r.w : scissor->x + scissor->w;
      int y1 = r.y + r.h < scissor->y + scissor->h ? r.y + r.h : scissor->y + scissor->h;
      *scissor = (CompRect){x0, y0, x1 - x0 > 0 ? x1 - x0 : 0, y1 - y0 > 0 ? y1 - y0 : 0};
      continue;
    }
    if (!axis) return 0;
    if (cl->r > 0 && fabs(sx - sy) > 1e-4 * (sx > sy ? sx : sy)) return 0;
    // Device pixels back to the raster's: x_device = sx * x_raster + tx.
    CompWalkClip *o = &baked->clips[baked->clip_count++];
    o->x = (cl->x - tx) / sx;
    o->y = (cl->y - ty) / sy;
    o->w = cl->w / sx;
    o->h = cl->h / sy;
    o->r = cl->r / sx;
  }
  return 1;
}

/** Whether a chunk's commands paint a layer of their own: such a chunk can't be kept, since the
 *  inner layer moves on its own. */
static int chunk_has_layer_ref(const CompWalkChunk *c) {
  if (c->list_id < 0 || c->list_id >= g_layer_count) return 0;
  CmdList *l = &g_layers[c->list_id].list;
  for (int i = 0; i < c->count; i++) {
    size_t at = (size_t)(c->first + i);
    if (at >= l->count) break;
    if (l->cmds[at].kind == CMD_LAYER_REF) return 1;
  }
  return 0;
}

/** Rasters the whole frame flat, as the replay draws it, as premultiplied RGBA in device pixels. */
static int raster_flat_rgba(double scale, int pw, int ph, unsigned char **out) {
  double replay_started = now_ms();
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef bctx = CGBitmapContextCreate(NULL, (size_t)pw, (size_t)ph, 8, 0, cs,
                                            (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(cs);
  if (bctx == NULL) return 0;
  CGContextTranslateCTM(bctx, 0, ph);
  CGContextScaleCTM(bctx, scale, -scale);
  // The replay draws the commands themselves: the per-layer image cache exists to save the work
  // of a layer drawn again on a later frame, and this raster is thrown away after one.
  int saved = g_layer_images_on;
  g_layer_images_on = 0;
  g_reference_paint = 1;
  replay(bctx, (double)pw / scale, (double)ph / scale);
  g_reference_paint = 0;
  g_layer_images_on = saved;
  g_flat_replay_ms = now_ms() - replay_started;
  const unsigned char *data = CGBitmapContextGetData(bctx);
  size_t stride = CGBitmapContextGetBytesPerRow(bctx);
  unsigned char *rgba = (unsigned char *)malloc((size_t)pw * 4u * (size_t)ph);
  if (rgba == NULL || data == NULL) {
    free(rgba);
    CGContextRelease(bctx);
    return 0;
  }
  for (int y = 0; y < ph; y++) memcpy(rgba + (size_t)y * (size_t)pw * 4u, data + (size_t)y * stride,
                                      (size_t)pw * 4u);
  CGContextRelease(bctx);
  *out = rgba;
  return 1;
}

/** Rasters the display list into `region` of the frame — a device-space rect, clamped to the
 *  frame — as the replay draws it there, as premultiplied RGBA in device pixels. `width` and
 *  `height` are the frame's CSS size. */
static int raster_region_rgba(double scale, CompRect region, double width, double height,
                              unsigned char **out) {
  int pw = region.w, ph = region.h;
  if (pw <= 0 || ph <= 0 || scale <= 0) return 0;
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef bctx = CGBitmapContextCreate(NULL, (size_t)pw, (size_t)ph, 8, 0, cs,
                                            (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(cs);
  if (bctx == NULL) return 0;
  CGContextTranslateCTM(bctx, 0, ph);
  CGContextScaleCTM(bctx, scale, -scale);
  // The page's own coordinates come from `replay`, so the shift to the region is in CSS pixels.
  CGContextTranslateCTM(bctx, -(double)region.x / scale, -(double)region.y / scale);
  // The layer images are this paint's: a paint that starts clears them, so a layer ref in the
  // damaged list rasters once and is reused within the frame, as the window's own replay does.
  int saved = g_layer_images_on;
  g_layer_images_on = 1;
  replay(bctx, width, height);
  g_layer_images_on = saved;
  const unsigned char *data = CGBitmapContextGetData(bctx);
  size_t stride = CGBitmapContextGetBytesPerRow(bctx);
  unsigned char *rgba = (unsigned char *)malloc((size_t)pw * 4u * (size_t)ph);
  if (rgba == NULL || data == NULL) {
    free(rgba);
    CGContextRelease(bctx);
    return 0;
  }
  for (int y = 0; y < ph; y++) memcpy(rgba + (size_t)y * (size_t)pw * 4u, data + (size_t)y * stride,
                                      (size_t)pw * 4u);
  CGContextRelease(bctx);
  *out = rgba;
  return 1;
}

/** The window's compositor backend, made on first use; NULL when the machine draws no Metal. */
static CompBackend *window_backend(void) {
  if (g_window_backend == NULL && g_metal_layer != nil) {
    g_window_backend = comp_metal_backend_for_layer((__bridge void *)g_metal_layer);
  } else if (g_window_backend == NULL && g_view == nil && headless_live()) {
    // A headless run that composites as the window does draws into a texture of its own.
    g_window_backend = comp_metal_backend();
  }
  return g_window_backend;
}

/** Reads NATIVE_COMPOSITOR_STATS once. */
static void window_stats_init(void) {
  if (g_win_stats >= 0) return;
  const char *s = getenv("NATIVE_COMPOSITOR_STATS");
  g_win_stats = s != NULL && s[0] != 0 && strcmp(s, "0") != 0;
}

/** Draws this frame on the window's Metal layer. Answers 1 when the layer took the frame. */
static int window_composite(void) {
  if (g_window_comp < 0) g_window_comp = window_compositing() ? 1 : 0;
  window_stats_init();
  if (g_window_comp == 0) return 0;
  // A backdrop filter reads the frame's pixels under it, which only the replay does.
  if (g_metal_layer == nil || g_view == nil || g_needs_backdrop) return 0;
  if (window_backend() == NULL) {
    g_window_comp = 0;
    return 0;
  }
  NSRect bounds = g_view.bounds;
  double scale = g_view.window != nil ? (double)g_view.window.backingScaleFactor : 1.0;
  int pw = (int)lround(bounds.size.width * scale), ph = (int)lround(bounds.size.height * scale);
  if (pw <= 0 || ph <= 0) return 0;
  g_metal_layer.contentsScale = scale;
  g_metal_layer.opaque = (g_background & 255u) == 255u;
  if ((int)g_metal_layer.drawableSize.width != pw || (int)g_metal_layer.drawableSize.height != ph) {
    g_metal_layer.drawableSize = CGSizeMake(pw, ph);
  }
  return composite_frame_into(g_window_backend, -1, scale, pw, ph);
}

/** The device-space region a chunk's raster covers: its commands' box through `m`, cut to the
 *  frame, so a layer pays for a surface the size of what it draws rather than the window's. */
static CompRect chunk_region(const CompWalkChunk *c, const CompMatrix *m, int pw, int ph) {
  if (c->full || c->bw <= 0 || c->bh <= 0) return (CompRect){0, 0, pw, ph};
  double bx = c->bx, by = c->by, ex = c->bx + c->bw, ey = c->by + c->bh;
  const double px[4] = {bx, ex, ex, bx}, py[4] = {by, by, ey, ey};
  double minx = 0, miny = 0, maxx = 0, maxy = 0;
  for (int i = 0; i < 4; i++) {
    double x = m->m[0] * px[i] + m->m[4] * py[i] + m->m[12];
    double y = m->m[1] * px[i] + m->m[5] * py[i] + m->m[13];
    if (i == 0) {
      minx = maxx = x;
      miny = maxy = y;
    } else {
      if (x < minx) minx = x;
      if (x > maxx) maxx = x;
      if (y < miny) miny = y;
      if (y > maxy) maxy = y;
    }
  }
  int x0 = (int)floor(minx) - 1, y0 = (int)floor(miny) - 1;
  int x1 = (int)ceil(maxx) + 1, y1 = (int)ceil(maxy) + 1;
  if (x0 < 0) x0 = 0;
  if (y0 < 0) y0 = 0;
  if (x1 > pw) x1 = pw;
  if (y1 > ph) y1 = ph;
  if (x1 <= x0 || y1 <= y0) return (CompRect){0, 0, 0, 0};
  return (CompRect){x0, y0, x1 - x0, y1 - y0};
}

// ---------------------------------------------------------------------------
// The raster pool
//
// A chunk's raster is CoreGraphics work on a bitmap of its own, with no state shared with the
// next one, so a few threads turn a frame's chunks into pixels while the main thread waits. Each
// worker replays with its own list and limit (see the thread-locals above); the display list is
// only read.

typedef struct {
  CompWalkChunk chunk; // a copy: the walk itself is freed when the frame ends
  CompMatrix m;
  int clips;
  CompRect region;
  unsigned char *rgba;
  int x, y, w, h;
  int entry;           // the WinChunk the pixels belong to
  uint64_t key;        // what they are a picture of
} RasterJob;

#define RASTER_MAX_WORKERS 6

static RasterJob g_jobs[COMP_MAX_LAYERS];
static int g_job_count = 0;
static int g_job_next = 0;
static int g_job_done = 0;
static int g_job_active = 0;
static int g_pool_state = 0; // 0 not started, 1 started
static int g_pool_threads = 0;
static pthread_t g_pool_threads_handle[RASTER_MAX_WORKERS];
static pthread_mutex_t g_job_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_job_wake = PTHREAD_COND_INITIALIZER;
static pthread_cond_t g_job_all_done = PTHREAD_COND_INITIALIZER;

/** Rasters one job's chunk into the job's buffer. */
static void raster_job(RasterJob *job) {
  job->rgba = NULL;
  job->x = job->y = job->w = job->h = 0;
  raster_chunk_rgba(&job->chunk, &job->m, job->clips, job->region, &job->rgba, &job->x,
                    &job->y, &job->w, &job->h);
}

static void *raster_worker(void *unused) {
  (void)unused;
  for (;;) {
    pthread_mutex_lock(&g_job_lock);
    while (g_job_active == 0) pthread_cond_wait(&g_job_wake, &g_job_lock);
    while (g_job_next < g_job_count) {
      int j = g_job_next++;
      pthread_mutex_unlock(&g_job_lock);
      raster_job(&g_jobs[j]);
      pthread_mutex_lock(&g_job_lock);
      g_job_done++;
      if (g_job_done == g_job_count) pthread_cond_signal(&g_job_all_done);
    }
    pthread_mutex_unlock(&g_job_lock);
  }
  return NULL;
}

/** Starts the pool on first use; `NATIVE_RASTER_WORKERS=0` keeps every raster on the main thread. */
static void start_raster_pool(void) {
  if (g_pool_state != 0) return;
  g_pool_state = 1;
  const char *env = getenv("NATIVE_RASTER_WORKERS");
  if (env != NULL && strcmp(env, "0") == 0) return;
  long cores = sysconf(_SC_NPROCESSORS_ONLN);
  int n = cores > 1 ? (int)cores : 0;
  if (n > RASTER_MAX_WORKERS) n = RASTER_MAX_WORKERS;
  int started = 0;
  for (int i = 0; i < n; i++) {
    if (pthread_create(&g_pool_threads_handle[i], NULL, raster_worker, NULL) != 0) break;
    started++;
  }
  g_pool_threads = started;
}

/** Rasters a frame's batch of jobs, on the pool when it has threads and inline otherwise, and
 *  returns once every job is done: a frame never goes out with a chunk whose pixels are still
 *  being made. */
/** Gives the batch to the pool; with no pool threads the jobs run here, since there is nowhere
 *  else for them to run. */
static void start_raster_jobs(void) {
  start_raster_pool();
  if (g_job_count == 0) return;
  if (g_pool_threads == 0) {
    for (int j = 0; j < g_job_count; j++) raster_job(&g_jobs[j]);
    g_job_done = g_job_count;
    return;
  }
  pthread_mutex_lock(&g_job_lock);
  g_job_next = 0;
  g_job_done = 0;
  g_job_active = 1;
  pthread_cond_broadcast(&g_job_wake);
  pthread_mutex_unlock(&g_job_lock);
}

/** Waits for the batch to be done, so its pixels can be installed. */
static void wait_raster_jobs(void) {
  if (g_job_count == 0 || g_pool_threads == 0) return;
  pthread_mutex_lock(&g_job_lock);
  while (g_job_done < g_job_count) pthread_cond_wait(&g_job_all_done, &g_job_lock);
  // The workers go back to waiting for the next batch instead of polling for this one's end.
  g_job_active = 0;
  pthread_mutex_unlock(&g_job_lock);
}

/** Uploads the batch's pixels into their chunks' tiles. */
static void install_raster_jobs(void) {
  for (int j = 0; j < g_job_count; j++) {
    RasterJob *r = &g_jobs[j];
    WinChunk *e = &g_win_chunks[r->entry];
    if (r->rgba != NULL) {
      CompRect ink = (CompRect){r->x, r->y, r->w, r->h};
      e->transient = g_win_tiles + comp_tile_count(ink) > WIN_TILE_BUDGET;
      win_upload_tiles(e, r->rgba, ink);
    }
    // A chunk with no ink has a picture too: nothing, which the next frame can keep.
    e->serial = g_paint_serial;
    e->key = r->key;
    e->pending = 0;
    free(r->rgba);
    r->rgba = NULL;
  }
  g_job_count = 0;
}

// What a chunk's tiles are a picture of. A chunk's place in the walk and the command index it
// starts at say nothing about its pixels: a row that changes its text in a page repainting every
// frame moves every chunk after it to other indexes. So the cache keys a chunk by its content —
// every field of its commands that the raster reads, its text, and the state the raster bakes in —
// and a chunk anywhere in a new paint keeps the tiles of the chunk in the last frame it equals.

static inline uint64_t key_mix(uint64_t h, uint64_t v) {
  h ^= v * 0x9e3779b97f4a7c15ull;
  h = (h << 31) | (h >> 33);
  return h * 0xbf58476d1ce4e5b9ull;
}

static inline uint64_t key_double(uint64_t h, double d) {
  uint64_t v;
  memcpy(&v, &d, sizeof(v));
  return key_mix(h, v);
}

/** A number that changes when an image's pixels land: 1 pending, 2 decoded, 3 failed. */
static uint64_t image_generation(int32_t id) {
  if (id < 0 || id >= g_image_count) return 0;
  pthread_mutex_lock(&g_image_lock);
  int state = g_image_slots[id].state;
  pthread_mutex_unlock(&g_image_lock);
  return (uint64_t)(state + 2);
}

static uint64_t key_cmd(uint64_t h, const Cmd *c) {
  // `handle` is the command's index within the frame, so it changes with every command before
  // it; `layer` is a layer's index within the paint, read only by a layer ref, which has no key.
  h = key_mix(h, (uint64_t)(uint32_t)c->kind | ((uint64_t)(uint32_t)c->pkind << 32));
  h = key_mix(h, (uint64_t)(uint32_t)c->serial | ((uint64_t)(uint32_t)c->image << 32));
  // An image's pixels land after the command that draws it: the key moves when they do, so a
  // chunk rastered while the image was pending isn't kept as the picture of an empty image.
  if (c->kind == CMD_IMAGE) h = key_mix(h, image_generation(c->image));
  const double d[] = {c->x, c->y, c->w, c->h, c->radius, c->line_width, c->line_height, c->size,
                      c->weight, c->sx, c->sy, c->sw, c->sh, c->p0, c->p1, c->p2, c->p3, c->dx,
                      c->dy, c->blur, c->letter, c->word, c->alpha};
  for (size_t i = 0; i < sizeof(d) / sizeof(d[0]); i++) h = key_double(h, d[i]);
  for (int i = 0; i < 8; i++) h = key_double(h, c->r[i]);
  for (int i = 0; i < 8; i++) h = key_double(h, c->q[i]);
  h = key_mix(h, (uint64_t)c->color | ((uint64_t)c->shadow_color << 32));
  h = key_mix(h, (uint64_t)c->emphasis | ((uint64_t)c->emphasis_color << 32));
  h = key_mix(h, (uint64_t)(uint32_t)c->smooth | ((uint64_t)(uint32_t)c->alpha_override << 32));
  h = key_mix(h, (uint64_t)c->len);
  if (c->text != NULL) {
    size_t i = 0;
    for (; i + 8 <= c->len; i += 8) {
      uint64_t v;
      memcpy(&v, c->text + i, 8);
      h = key_mix(h, v);
    }
    uint64_t tail = 0;
    memcpy(&tail, c->text + i, c->len - i);
    h = key_mix(h, tail);
  }
  return h;
}

/** Folds the pixels a run of commands rasters into `h`, following a layer ref into the list it
 *  paints: a chunk under a mask or a projection holds such a ref where the walk can't split, and
 *  what it draws is the layer's commands. Answers 0 when the run can't be keyed: a canvas draws
 *  pixels its script changes without a new command, and so does a video, which draws the frame it
 *  is on; a chain of layers deeper than the walk follows has more than the key should hold. */
static int key_range(uint64_t *out, CmdList *l, size_t first, size_t count, int depth) {
  uint64_t h = *out;
  for (size_t i = 0; i < count; i++) {
    const Cmd *cmd = &l->cmds[first + i];
    if (cmd->kind == CMD_CANVAS || cmd->kind == CMD_VIDEO) return 0;
    if (cmd->kind == CMD_LAYER_REF) {
      if (depth >= 6 || cmd->layer < 0 || cmd->layer >= g_layer_count) return 0;
      CmdList *inner = &g_layers[cmd->layer].list;
      h = key_mix(h, 0x6c62272e07bb0142ull);
      if (!key_range(&h, inner, 0, inner->count, depth + 1)) return 0;
      continue;
    }
    h = key_cmd(h, cmd);
  }
  *out = h;
  return 1;
}

/** The key of a chunk rastered under `raster_m` (with its clips baked in when it isn't `own`)
 *  into a frame of `pw` x `ph`; 0 when its commands don't pin its pixels down: a canvas draws
 *  pixels its script changes without a new command. */
static uint64_t chunk_key(const CompWalkChunk *c, int own, const CompMatrix *raster_m, int pw,
                          int ph) {
  if (c->count <= 0) return 0;
  if (c->list_id >= g_layer_count) return 0;
  CmdList *l = c->list_id < 0 ? &g_root : &g_layers[c->list_id].list;
  if ((size_t)(c->first + c->count) > l->count) return 0;
  uint64_t h = 0x243f6a8885a308d3ull;
  h = key_mix(h, (uint64_t)g_raster_epoch);
  h = key_mix(h, (uint64_t)(c->list_id < 0) | ((uint64_t)(uint32_t)own << 1) |
                     ((uint64_t)(uint32_t)c->full << 2) | ((uint64_t)(uint32_t)c->transforms << 8) |
                     ((uint64_t)(uint32_t)c->mask_role << 24) |
                     ((uint64_t)(uint32_t)c->mask_id << 32));
  h = key_mix(h, (uint64_t)(uint32_t)pw | ((uint64_t)(uint32_t)ph << 32));
  for (int i = 0; i < 16; i++) h = key_double(h, raster_m->m[i]);
  h = key_double(h, c->bx);
  h = key_double(h, c->by);
  h = key_double(h, c->bw);
  h = key_double(h, c->bh);
  {
    // A chunk in its own space carries only the clips baked into its raster (own_space_clips).
    h = key_mix(h, (uint64_t)c->clip_count);
    for (int k = 0; k < c->clip_count; k++) {
      h = key_double(h, c->clips[k].x);
      h = key_double(h, c->clips[k].y);
      h = key_double(h, c->clips[k].w);
      h = key_double(h, c->clips[k].h);
      h = key_double(h, c->clips[k].r);
    }
  }
  if (!key_range(&h, l, (size_t)c->first, (size_t)c->count, 0)) return 0;
  return h == 0 ? 1 : h;
}

// --- GPU canvas: drawing a batch --------------------------------------------------------------

/** Draws a batch on the CPU, for a canvas with no texture to draw into: a flat snapshot, or a
 *  build with no Metal device. The same shapes, filled with CoreGraphics. */
static void canvas_gpu_replay_cpu(Canvas *c) {
  uint32_t color = c->fillColor;
  double alpha = c->alpha;
  for (int i = 0; i < c->gpu_count; i++) {
    const CanvasGpuCmd *q = &c->gpu[i];
    CGAffineTransform m = CGAffineTransformMake(q->m[0], q->m[1], q->m[2], q->m[3], q->m[4], q->m[5]);
    CGMutablePathRef p = CGPathCreateMutable();
    if (q->kind == CGPU_RECT) CGPathAddRect(p, NULL, CGRectMake(q->x, q->y, q->w, q->h));
    else CGPathAddEllipseInRect(p, NULL, CGRectMake(q->x, q->y, q->w, q->h));
    CGMutablePathRef device = CGPathCreateMutableCopyByTransformingPath(p, &m);
    c->fillColor = q->color;
    c->alpha = q->alpha;
    CGContextSetAlpha(c->ctx, q->alpha);
    canvas_fill_device(c, device, 0);
    CGPathRelease(device);
    CGPathRelease(p);
  }
  c->fillColor = color;
  c->alpha = alpha;
  CGContextSetAlpha(c->ctx, alpha);
  c->gpu_count = 0;
  c->gpu_cleared = 0;
  c->gpu_dirty = 0;
  c->gpu_unsynced = 0;
}

/** Draws the queued fills into a canvas texture. The target is the texture the last frame is not
 *  using; the previous texture's pixels are copied in unless the batch started with a clear. The
 *  bitmap is left as it was, so the canvas reads as stale until canvas_gpu_sync copies back. */
static void canvas_gpu_flush(Canvas *c) {
  if (!c->gpu_dirty) return;
  // Nothing queued and no clear: the texture already holds what the batch drew.
  if (c->gpu_count == 0 && !c->gpu_cleared) return;
  CompBackend *b = c->backend;
  if (b == NULL || c->tex[0] < 0 || c->tex[1] < 0) {
    canvas_gpu_replay_cpu(c);
    return;
  }
  int k = c->tex_cur < 0 ? 0 : 1 - c->tex_cur;
  // The batch draws over the canvas as it stood: the texture the last frame sampled, when it
  // holds draws the bitmap has not taken back; otherwise the bitmap, which a CPU operation has
  // changed since the last batch.
  int clear = c->gpu_cleared || c->tex_cur < 0;
  int src = (!clear && c->gpu_unsynced) ? c->tex_cur : -1;
  mt_tex_wait_idle(b, c->tex[k]);
  if (!clear && src < 0 && c->ctx != NULL) {
    const unsigned char *data = CGBitmapContextGetData(c->ctx);
    if (data != NULL) mt_tex_upload_rgba(b, c->tex[k], data, CGBitmapContextGetBytesPerRow(c->ctx));
    else clear = 1;
  }
  MtSdfShape *shapes = malloc((size_t)c->gpu_count * sizeof(MtSdfShape));
  if (shapes == NULL) {
    canvas_gpu_replay_cpu(c);
    return;
  }
  for (int i = 0; i < c->gpu_count; i++) {
    const CanvasGpuCmd *q = &c->gpu[i];
    MtSdfShape *s = &shapes[i];
    memset(s, 0, sizeof(*s));
    // The recorded matrix takes a local point to CoreGraphics' y-up device space; the texture's
    // first row is the top of the canvas, so y is flipped here.
    s->m[0] = (float)q->m[0];
    s->m[1] = (float)-q->m[1];
    s->m[2] = (float)q->m[2];
    s->m[3] = (float)-q->m[3];
    s->origin[0] = (float)q->m[4];
    s->origin[1] = (float)(c->h - q->m[5]);
    s->origin[2] = (float)q->kind;
    s->box[0] = (float)q->x;
    s->box[1] = (float)q->y;
    s->box[2] = (float)q->w;
    s->box[3] = (float)q->h;
    if (q->kind == CGPU_OVAL) {
      s->radii[0] = (float)(q->w * 0.5);
      s->radii[1] = (float)(q->h * 0.5);
    }
    double a = (double)(q->color & 255u) / 255.0 * q->alpha;
    s->color[0] = (float)((double)((q->color >> 24) & 255u) / 255.0 * a);
    s->color[1] = (float)((double)((q->color >> 16) & 255u) / 255.0 * a);
    s->color[2] = (float)((double)((q->color >> 8) & 255u) / 255.0 * a);
    s->color[3] = (float)a;
  }
  if (getenv("NATIVE_CANVAS_STATS") != NULL) {
    fprintf(stderr, "native: canvas gpu shapes=%d clear=%d\n", c->gpu_count, c->gpu_cleared);
  }
  int ok = mt_canvas_batch(b, c->tex[k], src, clear, shapes, c->gpu_count, (int)c->w, (int)c->h);
  free(shapes);
  if (!ok) {
    canvas_gpu_replay_cpu(c);
    return;
  }
  c->tex_cur = k;
  c->tex_gen = c->gen;
  c->gpu_count = 0;
  c->gpu_cleared = 0;
  c->gpu_unsynced = 1;
}

/** Brings the bitmap up to date with the fills drawn on the GPU, so an operation that needs the
 *  bitmap (text, an image, a filter, a read, a flat snapshot) sees them. */
static void canvas_gpu_sync(Canvas *c) {
  if (!c->gpu_dirty) return;
  canvas_gpu_flush(c);
  if (!c->gpu_dirty) return;
  CompBackend *b = c->backend;
  if (b != NULL && c->tex_cur >= 0 && c->tex_gen == c->gen) {
    if (mt_tex_readback(b, c->tex[c->tex_cur], CGBitmapContextGetData(c->ctx),
                        CGBitmapContextGetBytesPerRow(c->ctx))) {
      c->gpu_dirty = 0;
      c->gpu_unsynced = 0;
    }
  }
}

/** The texture an external chunk's canvas is drawn from, made current: a WebGL canvas's last
 *  IOSurface, or a 2D canvas's bitmap copied into a texture when it changed. Answers -1 when the
 *  canvas has none, and the chunk is rastered like any other. */
static int canvas_texture(CompBackend *b, const Cmd *cmd, CompRect *src, int *flags) {
  Canvas *cv = canvas_at(cmd->image);
  if (cv == NULL || cv->ctx == NULL) return -1;
  int linear = cmd->smooth ? MT_SAMPLE_LINEAR : 0;
  if (cv->gl != NULL) {
    GlCanvas *g = cv->gl;
    int k = g->surf_cur;
    if (k < 0 || g->surf[k] == NULL) return -1;
    if (g->surf_mt[k] < 0) g->surf_mt[k] = mt_tex_wrap_iosurface(b, g->surf[k]);
    if (g->surf_mt[k] < 0) return -1;
    *src = (CompRect){0, 0, g->surf_w, g->surf_h};
    // The buffer holds straight colour, as the bitmap readback took it; without `alpha` the page's
    // alpha is not the canvas's.
    *flags = MT_SAMPLE_PREMULTIPLY | (g->alpha ? 0 : MT_SAMPLE_OPAQUE) | linear;
    return g->surf_mt[k];
  }
  int w = (int)cv->w, h = (int)cv->h;
  if (cv->tex_w != w || cv->tex_h != h) {
    for (int k = 0; k < 2; k++) {
      if (cv->tex_w > 0 && cv->tex[k] >= 0) {
        mt_tex_wait_idle(b, cv->tex[k]);
        b->vt->tex_destroy(b, cv->tex[k]);
      }
      cv->tex[k] = mt_tex_create_rgba(b, w, h);
    }
    cv->tex_w = w;
    cv->tex_h = h;
    cv->tex_cur = -1;
    if (cv->tex[0] < 0 || cv->tex[1] < 0) {
      for (int k = 0; k < 2; k++) {
        if (cv->tex[k] >= 0) b->vt->tex_destroy(b, cv->tex[k]);
        cv->tex[k] = -1;
      }
      cv->tex_w = cv->tex_h = 0;
      return -1;
    }
  }
  // The textures are this backend's, so a later flush or readback uses it too.
  cv->backend = b;
  // Draws the fills the page queued straight into the texture, so the bitmap never has to hold
  // them and no upload follows.
  if (cv->gpu_dirty) canvas_gpu_flush(cv);
  if (cv->tex_cur < 0 || cv->tex_gen != cv->gen) {
    const unsigned char *data = CGBitmapContextGetData(cv->ctx);
    if (data == NULL) return -1;
    int k = cv->tex_cur < 0 ? 0 : 1 - cv->tex_cur;
    mt_tex_wait_idle(b, cv->tex[k]);
    mt_tex_upload_rgba(b, cv->tex[k], data, CGBitmapContextGetBytesPerRow(cv->ctx));
    cv->tex_cur = k;
    cv->tex_gen = cv->gen;
  }
  *src = (CompRect){0, 0, w, h};
  *flags = linear;
  return cv->tex[cv->tex_cur];
}

/** Draws an external chunk's canvas from its texture where its command places it, through the
 *  chunk's matrix, opacity and clip. */
static void draw_external_chunk(CompBackend *b, const CompWalkChunk *c, int tex, CompRect src,
                                int flags, const CompRect *clip) {
  CmdList *l = c->list_id < 0 ? &g_root : &g_layers[c->list_id].list;
  const Cmd *cmd = &l->cmds[c->first];
  CompMatrix place = comp_matrix_mul(
      comp_matrix_translate((float)cmd->x, (float)cmd->y),
      comp_matrix_scale((float)(cmd->w / (double)src.w), (float)(cmd->h / (double)src.h)));
  CompMatrix M = comp_matrix_mul(c->m, place);
  mt_draw_quad_sampled(b, tex, src, &M, (float)(c->alpha * cmd->size), clip, flags | MT_SAMPLE_TRACKED);
}

/** Whether each layer of this frame is rastered in its own space (see composite_frame_into). */
static unsigned char g_layer_own[MAX_LAYERS];

/** The last frame's entries, while a frame matches its chunks to them. */
static WinChunk g_win_prev[COMP_MAX_LAYERS];
static unsigned char g_win_prev_used[COMP_MAX_LAYERS];
static uint64_t g_win_keys[COMP_MAX_LAYERS];
#define WIN_KEY_SLOTS 8192 // a power of two above COMP_MAX_LAYERS
static int g_win_key_slot[WIN_KEY_SLOTS];

// ---------------------------------------------------------------------------
// Masks the walk split
//
// A mask the walk split (comp_walk_mask_split) arrives as chunks of two roles: the ones that paint
// its image and the ones that paint the content it masks, every chunk carrying the mask's id and
// its device box. The window draws the image onto a surface of the box once and keeps it, draws
// the content's chunks onto another surface of it every frame (their tiles are kept while nothing
// they show changes), and draws the content through the image's alpha as one quad.

#define MAX_MASK_GROUPS 8

typedef struct {
  int id;           // the mask's identity in the walk
  int w, h;         // the box the surfaces are sized for
  int alpha_tex;    // the mask image, or -1
  int content_tex;  // the content drawn on the box, or -1
  int composed_tex; // the content through the image's alpha, rounded to eight bits, or -1
  uint64_t alpha_key; // what the image texture is a picture of
  int used;         // the frame that last used the surfaces
} MaskSurface;

typedef struct {
  int id;
  CompRect box;       // device pixels; the surfaces are the part of it the frame shows
  int first, count;   // the group's chunks, its image's first
  int alpha_chunks;
  MaskSurface *surface;
} MaskGroup;

static MaskSurface g_mask_surfaces[MAX_MASK_GROUPS];
static int g_mask_surfaces_ready = 0;
static int g_mask_frame = 0;
static MaskGroup g_mask_groups[MAX_MASK_GROUPS];
static int g_mask_group_count = 0;

/** Whether the mask path prints what it made of each group: NATIVE_MASK_SPLIT_DEBUG=1. */
static int mask_split_debug_on(void) {
  static int on = -1;
  if (on < 0) {
    const char *env = getenv("NATIVE_MASK_SPLIT_DEBUG");
    on = env != NULL && env[0] == '1' && env[1] == 0;
  }
  return on;
}


static void mask_surfaces_init(void) {
  if (g_mask_surfaces_ready) return;
  for (int i = 0; i < MAX_MASK_GROUPS; i++) {
    g_mask_surfaces[i].alpha_tex = -1;
    g_mask_surfaces[i].content_tex = -1;
    g_mask_surfaces[i].composed_tex = -1;
  }
  g_mask_surfaces_ready = 1;
}

/** Drops every surface's textures: the tiles were rastered for another scale, or the window is
 *  going away. */
static void mask_surfaces_drop(void) {
  if (!g_mask_surfaces_ready) return;
  for (int i = 0; i < MAX_MASK_GROUPS; i++) {
    MaskSurface *s = &g_mask_surfaces[i];
    if (s->alpha_tex >= 0 && g_window_backend != NULL) {
      g_window_backend->vt->tex_destroy(g_window_backend, s->alpha_tex);
    }
    if (s->content_tex >= 0 && g_window_backend != NULL) {
      g_window_backend->vt->tex_destroy(g_window_backend, s->content_tex);
    }
    if (s->composed_tex >= 0 && g_window_backend != NULL) {
      g_window_backend->vt->tex_destroy(g_window_backend, s->composed_tex);
    }
    s->alpha_tex = -1;
    s->content_tex = -1;
    s->composed_tex = -1;
    s->alpha_key = 0;
    s->w = s->h = 0;
    s->id = -1;
  }
}

/** The surfaces a mask's group draws on, sized for the box; a new pair when the size changed. */
static MaskSurface *mask_surface_for(CompBackend *b, int id, int w, int h) {
  mask_surfaces_init();
  int slot = -1, spare = -1;
  for (int i = 0; i < MAX_MASK_GROUPS; i++) {
    MaskSurface *s = &g_mask_surfaces[i];
    if (s->id == id && s->alpha_tex >= 0) {
      slot = i;
      break;
    }
    if (spare < 0 && (s->alpha_tex < 0 || s->used < g_mask_frame)) spare = i;
  }
  if (slot < 0) slot = spare >= 0 ? spare : 0;
  MaskSurface *s = &g_mask_surfaces[slot];
  if (s->w != w || s->h != h || s->alpha_tex < 0 || s->content_tex < 0 || s->composed_tex < 0) {
    if (s->alpha_tex >= 0) b->vt->tex_destroy(b, s->alpha_tex);
    if (s->content_tex >= 0) b->vt->tex_destroy(b, s->content_tex);
    if (s->composed_tex >= 0) b->vt->tex_destroy(b, s->composed_tex);
    s->alpha_tex = b->vt->tex_create(b, w, h);
    s->content_tex = b->vt->tex_create(b, w, h);
    s->composed_tex = b->vt->tex_create(b, w, h);
    s->alpha_key = 0;
    s->w = w;
    s->h = h;
  }
  s->id = id;
  s->used = g_mask_frame;
  return s;
}

/** Collects the groups a walk's chunks make: each run of chunks of one mask id. */
static void mask_groups_collect(const CompWalk *walk) {
  g_mask_group_count = 0;
  int n = walk->count;
  for (int i = 0; i < n && g_mask_group_count < MAX_MASK_GROUPS; ) {
    const CompWalkChunk *c = &walk->chunks[i];
    if (c->mask_role == COMP_MASK_NONE) {
      i++;
      continue;
    }
    MaskGroup *g = &g_mask_groups[g_mask_group_count++];
    memset(g, 0, sizeof(*g));
    g->id = c->mask_id;
    g->box = c->mask_box;
    g->first = i;
    while (i < n && walk->chunks[i].mask_role != COMP_MASK_NONE &&
           walk->chunks[i].mask_id == g->id) {
      if (walk->chunks[i].mask_role == COMP_MASK_ALPHA) g->alpha_chunks++;
      g->count++;
      i++;
    }
  }
}

/** Draws the group's chunks of `role` onto surface `tex`, moved by the box's corner so the box's
 *  pixels start at its top left. The image paints at full alpha: any alpha around the mask fades
 *  the content into the frame, not the coverage that cuts it. */
static int mask_surface_draw(CompBackend *b, const MaskGroup *g, const CompWalk *walk, double scale,
                             int role, int tex) {
  (void)tex;
  CompMatrix shift = comp_matrix_translate((float)-g->box.x, (float)-g->box.y);
  CompMatrix inv = comp_matrix_scale((float)(1.0 / scale), (float)(1.0 / scale));
  int drawn = 0;
  for (int i = g->first; i < g->first + g->count; i++) {
    const CompWalkChunk *c = &walk->chunks[i];
    const WinChunk *e = &g_win_chunks[i];
    if (c->mask_role != role || e->ext || e->pending || e->tex_count <= 0) continue;
    CompWalkChunk baked;
    CompRect clip;
    int has_scissor = 0;
    (void)own_space_clips(c, scale, &baked, &clip, &has_scissor);
    if (e->own && has_scissor && (clip.w <= 0 || clip.h <= 0)) continue;
    CompRect moved = {clip.x - g->box.x, clip.y - g->box.y, clip.w, clip.h};
    const CompRect *draw_clip = e->own && has_scissor ? &moved : NULL;
    float alpha = role == COMP_MASK_ALPHA ? 1.0f : c->alpha;
    if (mask_split_debug_on()) {
      fprintf(stderr, "native: mask surface role=%d chunk=%d own=%d tiles=%d m=%.1f,%.1f clip=%d,%d %dx%d tile0=%d,%d %dx%d tex0=%d\n",
              role, i, e->own, e->tex_count, c->m.m[12], c->m.m[13], clip.x, clip.y, clip.w, clip.h,
              e->tex_count > 0 ? e->tiles[0].rect.x : -1, e->tex_count > 0 ? e->tiles[0].rect.y : -1,
              e->tex_count > 0 ? e->tiles[0].rect.w : -1, e->tex_count > 0 ? e->tiles[0].rect.h : -1,
              e->tex_count > 0 ? e->tiles[0].tex : -1);
    }
    int resampled = e->own &&
                    (fabs(c->m.m[0] / scale - 1.0) > 1e-4 || fabs(c->m.m[5] / scale - 1.0) > 1e-4 ||
                     fabs(c->m.m[1]) > 1e-6 || fabs(c->m.m[4]) > 1e-6);
    for (int t = 0; t < e->tex_count; t++) {
      CompRect r = e->tiles[t].rect;
      CompMatrix M;
      if (e->own) {
        M = comp_matrix_mul(comp_matrix_mul(c->m, inv),
                            comp_matrix_translate((float)r.x, (float)r.y));
      } else {
        M = comp_matrix_translate((float)r.x, (float)r.y);
      }
      M = comp_matrix_mul(shift, M);
      (void)resampled;
      mt_surface_draw(b, e->tiles[t].tex, (CompRect){0, 0, r.w, r.h}, &M, alpha, draw_clip);
      drawn++;
    }
  }
  if (mask_split_debug_on()) {
    fprintf(stderr, "native: mask surface role=%d drawn=%d\n", role, drawn);
  }
  return drawn;
}

/** What a group's image surface is a picture of: the keys of its image chunks, or 0 when one of
 *  them has none, which asks for it to be drawn again. */
static uint64_t mask_alpha_key(const MaskGroup *g, const CompWalk *walk) {
  uint64_t h = 0x94d049bb133111ebull;
  for (int i = g->first; i < g->first + g->count; i++) {
    if (walk->chunks[i].mask_role != COMP_MASK_ALPHA) continue;
    if (i >= g_win_count || g_win_chunks[i].pending || g_win_keys[i] == 0) return 0;
    h = key_mix(h, g_win_keys[i]);
    // A chunk's key is its commands and the space it is rastered in; where the layer sits in the
    // frame is applied at draw, so a retained descendant that only moves keeps its key. The image
    // surface is drawn in device pixels, so the chunk's device matrix and the group's box are part
    // of what it is a picture of.
    for (int k = 0; k < 16; k++) h = key_double(h, walk->chunks[i].m.m[k]);
    h = key_double(h, g->box.x);
    h = key_double(h, g->box.y);
    h = key_double(h, g->box.w);
    h = key_double(h, g->box.h);
    // The chunk key leaves a plain clip out (it is the scissor the tiles are drawn under), so the
    // clips go into the surface's key here: a clip that moves redraws the image.
    for (int k = 0; k < walk->chunks[i].clip_count; k++) {
      const CompWalkClip *cl = &walk->chunks[i].clips[k];
      h = key_double(h, cl->x);
      h = key_double(h, cl->y);
      h = key_double(h, cl->w);
      h = key_double(h, cl->h);
      h = key_double(h, cl->r);
    }
  }
  return h;
}

/** Prepares every group's surfaces: the image only when what it shows changed, the content every
 *  frame. Answers how many groups draw. */
static int mask_groups_render(CompBackend *b, const CompWalk *walk, double scale, int pw, int ph) {
  g_mask_frame++;
  int live = 0;
  for (int k = 0; k < g_mask_group_count; k++) {
    MaskGroup *g = &g_mask_groups[k];
    g->surface = NULL;
    // With no image nothing shows through the mask, whatever the content paints.
    if (g->alpha_chunks <= 0) continue;
    int x0 = g->box.x < 0 ? 0 : g->box.x;
    int y0 = g->box.y < 0 ? 0 : g->box.y;
    int x1 = g->box.x + g->box.w > pw ? pw : g->box.x + g->box.w;
    int y1 = g->box.y + g->box.h > ph ? ph : g->box.y + g->box.h;
    if (x1 <= x0 || y1 <= y0) continue;
    g->box = (CompRect){x0, y0, x1 - x0, y1 - y0};
    MaskSurface *s = mask_surface_for(b, g->id, g->box.w, g->box.h);
    if (mask_split_debug_on()) {
      fprintf(stderr, "native: mask group id=%d chunks=%d alpha=%d box=%d,%d %dx%d tex=%d,%d\n",
              g->id, g->count, g->alpha_chunks, g->box.x, g->box.y, g->box.w, g->box.h,
              s != NULL ? s->alpha_tex : -2, s != NULL ? s->content_tex : -2);
    }
    if (s == NULL || s->alpha_tex < 0 || s->content_tex < 0) continue;
    g->surface = s;
    uint64_t key = mask_alpha_key(g, walk);
    if (key == 0 || key != s->alpha_key) {
      mt_surface_begin(b, s->alpha_tex, g->box.w, g->box.h);
      mask_surface_draw(b, g, walk, scale, COMP_MASK_ALPHA, s->alpha_tex);
      mt_surface_end(b);
      s->alpha_key = key;
    }
    mt_surface_begin(b, s->content_tex, g->box.w, g->box.h);
    mask_surface_draw(b, g, walk, scale, COMP_MASK_CONTENT, s->content_tex);
    mt_surface_end(b);
    // The product lands in a surface of its own first: rounded to eight bits there, as the flat
    // replay's image is, so the frame's blend sees the same values it always did.
    mt_surface_begin(b, s->composed_tex, g->box.w, g->box.h);
    mt_surface_draw_masked(b, s->content_tex, s->alpha_tex,
                           (CompRect){0, 0, g->box.w, g->box.h}, NULL, 1.0f);
    mt_surface_end(b);
    live++;
  }
  return live;
}

/** Whether this frame's masks are split: the backend has the mask composite pass, and
 *  NATIVE_MASK_SPLIT=0 doesn't hold it back for a comparison against the whole-mask path. */
static int mask_split_wanted(CompBackend *b) {
  const char *env = getenv("NATIVE_MASK_SPLIT");
  if (env != NULL && env[0] == '0' && env[1] == 0) return 0;
  return mt_mask_composite_available(b);
}

/** Composites the frame into `target` (-1 for the window's drawable), reusing the tiles the last
 *  frame left, and presents it. Every chunk is drawn from a picture of its own current commands:
 *  one the last frame had, or one rastered now. Answers 1 when the target was drawn. */
static int composite_frame_into(CompBackend *b, int target, double scale, int pw, int ph) {
  // A damaged frame paints the damaged region over the picture the last frame presented, instead
  // of drawing the page again; with no picture to patch, it is painted whole below.
  if (g_damage_frame) {
    g_damage_frame = 0;
    if (g_pic_cur >= 0 && g_pic_w == pw && g_pic_h == ph) {
      return composite_damaged_into(b, target, scale, pw, ph);
    }
    // A damaged list is only part of the page: drawing it as a whole frame would show the rest
    // empty. With no picture of this size to patch, leave the window showing what it has.
    return 0;
  }
  if (g_win_scale != scale) {
    win_drop_all(); // the tiles were rastered for another scale
    g_win_scale = scale;
  }
  // The frame is drawn into a picture of its own first, which the window shows and a damaged
  // frame patches next time.
  int pic = win_pic_ensure(b, pw, ph) ? (g_pic_cur == 0 ? 1 : 0) : -1;
  int into = pic >= 0 ? g_pic_tex[pic] : target;
  CompWalk *walk = (CompWalk *)malloc(sizeof(CompWalk));
  // A mask is split into its image and its content only when this backend can composite them.
  comp_walk_set_mask_split(mask_split_wanted(b));
  comp_walk_set_mask_max(MAX_MASK_GROUPS);
  int chunked = walk != NULL && comp_walk_nested(&METAL_CHUNK_SOURCE, NULL, scale, walk);
  if (chunked) mask_groups_collect(walk);
  else g_mask_group_count = 0;
  if (chunked && mask_split_debug_on()) {
    fprintf(stderr, "native: composite walk chunks=%d groups=%d\n", walk->count,
            g_mask_group_count);
    for (int i = 0; i < walk->count; i++) {
      if (walk->chunks[i].mask_role != COMP_MASK_NONE) {
        fprintf(stderr, "native: chunk %d role=%d id=%d box=%d,%d %dx%d\n", i,
                walk->chunks[i].mask_role, walk->chunks[i].mask_id, walk->chunks[i].mask_box.x,
                walk->chunks[i].mask_box.y, walk->chunks[i].mask_box.w,
                walk->chunks[i].mask_box.h);
      }
    }
  }
  g_pic_chunked = chunked && pic >= 0;
  unsigned char *flat = NULL;
  double flat_ms = 0;
  if (!chunked) {
    double flat_started = now_ms();
    int made_flat = raster_flat_rgba(scale, pw, ph, &flat);
    flat_ms = now_ms() - flat_started;
    if (!made_flat) {
      free(walk);
      return 0;
    }
  }
  int kept = 0, full_chunks = 0, rastered = 0, external = 0;
  double raster_ms = 0;
  int mask_groups = 0;
  if (chunked) {
    int n = walk->count;
    CompMatrix device = comp_matrix_scale((float)scale, (float)scale);
    // The last frame's entries, looked up by key.
    int prev_count = g_win_count;
    memcpy(g_win_prev, g_win_chunks, (size_t)prev_count * sizeof(WinChunk));
    memset(g_win_prev_used, 0, (size_t)prev_count);
    for (int k = 0; k < WIN_KEY_SLOTS; k++) g_win_key_slot[k] = -1;
    for (int j = 0; j < prev_count; j++) {
      const WinChunk *p = &g_win_prev[j];
      if (p->key == 0 || p->serial == 0) continue;
      unsigned slot = (unsigned)(p->key & (WIN_KEY_SLOTS - 1));
      while (g_win_key_slot[slot] >= 0) slot = (slot + 1) & (WIN_KEY_SLOTS - 1);
      g_win_key_slot[slot] = j;
    }
    // A layer is rastered in its own space only when every chunk of it can be: a layer the walk
    // split into several runs (around the layers inside it) whose runs mixed rasters baked at the
    // device matrix with ones the compositor moves would put their edges half a pixel apart under a
    // scale, showing a seam where one run's antialiased edge meets the next.
    for (int l = 0; l < g_layer_count && l < MAX_LAYERS; l++) g_layer_own[l] = 1;
    for (int i = 0; i < n; i++) {
      const CompWalkChunk *c = &walk->chunks[i];
      if (c->list_id < 0 || c->list_id >= MAX_LAYERS || c->count <= 0) continue;
      CompWalkChunk baked;
      CompRect scissor;
      int has_scissor = 0;
      if (!own_space_clips(c, scale, &baked, &scissor, &has_scissor) || chunk_has_layer_ref(c)) {
        g_layer_own[c->list_id] = 0;
      }
    }
    g_job_count = 0;
    for (int i = 0; i < n; i++) {
      const CompWalkChunk *c = &walk->chunks[i];
      WinChunk *e = &g_win_chunks[i];
      CompWalkChunk baked;
      CompRect scissor;
      int has_scissor = 0;
      int clips = own_space_clips(c, scale, &baked, &scissor, &has_scissor);
      if (c->external && c->count == 1 && (c->clip_count == 0 || (clips && baked.clip_count == 0))) {
        // A canvas drawn from its own texture under plain clips: nothing to raster or keep.
        CmdList *el = c->list_id < 0 ? &g_root : &g_layers[c->list_id].list;
        CompRect src;
        int flags = 0;
        if ((size_t)c->first < el->count && canvas_texture(b, &el->cmds[c->first], &src, &flags) >= 0) {
          memset(e, 0, sizeof(*e));
          e->list_id = c->list_id;
          e->first = c->first;
          e->count = c->count;
          e->serial = g_paint_serial;
          e->ext = 1;
          g_win_keys[i] = 1; // not a keyless chunk: it is never rastered
          external++;
          continue;
        }
      }
      int own = c->list_id >= 0 && c->list_id < MAX_LAYERS && g_layer_own[c->list_id] &&
                clips && c->count > 0 && !chunk_has_layer_ref(c);
      CompMatrix raster_m = own ? device : c->m;
      // A chunk in its own space is rastered with the clips own_space_clips baked; any other with
      // its clips as they are, in device pixels.
      const CompWalkChunk *rc = own ? &baked : c;
      uint64_t key = chunk_key(rc, own, &raster_m, pw, ph);
      g_win_keys[i] = key;
      if (c->full) full_chunks++;
      int from = -1;
      if (key != 0) {
        // The same picture anywhere in the last frame: the entry at this index first, since a
        // frame that changed nothing before a chunk leaves it where it was.
        if (i < prev_count && !g_win_prev_used[i] && g_win_prev[i].key == key &&
            g_win_prev[i].serial != 0) {
          from = i;
        } else {
          unsigned slot = (unsigned)(key & (WIN_KEY_SLOTS - 1));
          while (g_win_key_slot[slot] >= 0) {
            int j = g_win_key_slot[slot];
            if (!g_win_prev_used[j] && g_win_prev[j].key == key) {
              from = j;
              break;
            }
            slot = (slot + 1) & (WIN_KEY_SLOTS - 1);
          }
        }
      } else if (i < prev_count && !g_win_prev_used[i]) {
        // A chunk with no key is kept only within the paint that rastered it, by place: a frame
        // that moved nothing but a transform or an opacity left its commands alone.
        const WinChunk *p = &g_win_prev[i];
        if (p->key == 0 && !p->ext && p->serial == g_paint_serial && p->own == own &&
            p->list_id == c->list_id && p->first == c->first && p->count == c->count &&
            (own || memcmp(&p->raster_m, &c->m, sizeof(CompMatrix)) == 0)) {
          from = i;
        }
      }
      if (from >= 0) {
        *e = g_win_prev[from];
        g_win_prev_used[from] = 1;
        e->list_id = c->list_id;
        e->first = c->first;
        e->count = c->count;
        kept++;
        continue;
      }
      memset(e, 0, sizeof(*e));
      e->list_id = c->list_id;
      e->first = c->first;
      e->count = c->count;
      e->own = own;
      e->raster_m = raster_m;
      if (c->count <= 0) {
        e->serial = g_paint_serial; // nothing to draw, nothing to raster
        continue;
      }
      RasterJob *job = &g_jobs[g_job_count++];
      job->chunk = *rc;
      job->m = raster_m;
      job->clips = 1;
      job->region = chunk_region(c, &job->m, pw, ph);
      job->rgba = NULL;
      job->entry = i;
      job->key = key;
      e->pending = 1;
    }
    // The last frame's pictures that no chunk of this one is: their textures go.
    for (int j = 0; j < prev_count; j++) {
      if (!g_win_prev_used[j]) win_drop_tiles(&g_win_prev[j]);
    }
    g_win_count = n;
    rastered = g_job_count;
    double raster_started = now_ms();
    // The pixels are made while the frame is drawn: a chunk that changed needs its raster before
    // it can be drawn in its place, but the chunks that were kept draw straight away and the pool
    // works behind them. A frame whose chunks were all kept never waits at all.
    start_raster_jobs();
    int waiting = g_job_count > 0;
    raster_ms = 0;
    int next_mask = 0;
    if (g_mask_group_count > 0) {
      // A split mask's surfaces are made before the frame's pass opens: a pass can't change target
      // midway. The content's rasters are taken here, so the draws below never wait for them.
      wait_raster_jobs();
      install_raster_jobs();
      waiting = 0;
      mask_groups = mask_groups_render(b, walk, scale, pw, ph);
      raster_ms = now_ms() - raster_started;
    }
    b->vt->pass_begin(b, into, pw, ph, g_background);
    for (int i = 0; i < n; i++) {
      const CompWalkChunk *c = &walk->chunks[i];
      WinChunk *e = &g_win_chunks[i];
      if (next_mask < g_mask_group_count && i == g_mask_groups[next_mask].first) {
        // A split mask is one quad: its content surface through its image's alpha.
        MaskGroup *g = &g_mask_groups[next_mask++];
        i = g->first + g->count - 1;
        if (g->surface != NULL) {
          CompMatrix M = comp_matrix_translate((float)g->box.x, (float)g->box.y);
          b->vt->draw_quad(b, g->surface->composed_tex, (CompRect){0, 0, g->box.w, g->box.h}, &M,
                           1.0f, NULL, 0.0f);
        }
        continue;
      }
      if (waiting && e->pending) {
        wait_raster_jobs();
        install_raster_jobs();
        waiting = 0;
        raster_ms = now_ms() - raster_started;
      }
      CompWalkChunk baked;
      CompRect clip;
      int has_scissor = 0;
      (void)own_space_clips(c, scale, &baked, &clip, &has_scissor);
      // Plain clips that leave nothing: the chunk draws nothing (a zero rect would clip nothing).
      if ((e->own || e->ext) && has_scissor && (clip.w <= 0 || clip.h <= 0)) continue;
      if (e->ext) {
        CmdList *el = c->list_id < 0 ? &g_root : &g_layers[c->list_id].list;
        CompRect src;
        int flags = 0;
        int tex = canvas_texture(b, &el->cmds[c->first], &src, &flags);
        if (tex >= 0) draw_external_chunk(b, c, tex, src, flags, has_scissor ? &clip : NULL);
        continue;
      }
      float alpha = c->alpha;
      CompMatrix inv = comp_matrix_scale((float)(1.0 / scale), (float)(1.0 / scale));
      const CompRect *draw_clip = e->own && has_scissor ? &clip : NULL;
      // A layer drawn scaled or turned from its own-space raster is filtered, as a browser filters
      // a composited layer; one that only moves keeps every texel as it is.
      int resampled = e->own && (fabs(c->m.m[0] / scale - 1.0) > 1e-4 || fabs(c->m.m[5] / scale - 1.0) > 1e-4 ||
                                 fabs(c->m.m[1]) > 1e-6 || fabs(c->m.m[4]) > 1e-6);
      for (int t = 0; t < e->tex_count; t++) {
        CompRect r = e->tiles[t].rect;
        CompMatrix M;
        if (e->own) {
          // The raster is the layer at the device scale, without its element's transform: the
          // matrix puts it back, so a transform-only frame draws the same tiles again.
          M = comp_matrix_mul(comp_matrix_mul(c->m, inv),
                              comp_matrix_translate((float)r.x, (float)r.y));
        } else {
          M = comp_matrix_translate((float)r.x, (float)r.y);
        }
        if (resampled) {
          mt_draw_quad_sampled(b, e->tiles[t].tex, (CompRect){0, 0, r.w, r.h}, &M, alpha, draw_clip,
                               MT_SAMPLE_LINEAR);
        } else {
          b->vt->draw_quad(b, e->tiles[t].tex, (CompRect){0, 0, r.w, r.h}, &M, alpha, draw_clip, 0.0f);
        }
      }
    }
    if (waiting) {
      // No chunk of this frame needed the pixels while it was drawn: the batch is taken here so
      // the next frame finds them, its wait having been paid behind the draws above.
      wait_raster_jobs();
      install_raster_jobs();
      raster_ms = now_ms() - raster_started;
      waiting = 0;
    }
  } else {
    b->vt->pass_begin(b, into, pw, ph, g_background);
    if (g_flat_tex < 0 || g_flat_w != pw || g_flat_h != ph) {
      if (g_flat_tex >= 0) b->vt->tex_destroy(b, g_flat_tex);
      g_flat_tex = b->vt->tex_create(b, pw, ph);
      g_flat_w = pw;
      g_flat_h = ph;
    }
    if (g_flat_tex >= 0) {
      b->vt->tex_upload(b, g_flat_tex, (CompRect){0, 0, pw, ph}, flat, pw * 4);
      CompMatrix M = comp_matrix_identity();
      b->vt->draw_quad(b, g_flat_tex, (CompRect){0, 0, pw, ph}, &M, 1.0f, NULL, 0.0f);
    }
  }
  free(flat);
  b->vt->present(b);
  if (pic >= 0) {
    win_pic_show(b, target, g_pic_tex[pic], pw, ph);
    g_pic_cur = pic;
  }
  // A chunk that outgrew the budget was drawn from textures of its own: release them now, after
  // the frame that reads them is on the GPU's queue.
  for (int i = 0; chunked && i < g_win_count; i++) {
    if (g_win_chunks[i].transient) win_drop_tiles(&g_win_chunks[i]);
  }
  if (g_win_stats) {
    int group = chunked ? 0 : comp_walk_group_count();
    for (int k = 0; k < group && k < 6; k++) {
      const CompWalkChunk *g = comp_walk_group_chunk(k);
      if (g == NULL) break;
      fprintf(stderr, "native: composite group %d list=%d first=%d count=%d clips=%d box=%.0fx%.0f\n",
              k, g->list_id, g->first, g->count, g->clip_count, g->bw, g->bh);
    }
    int keyless = 0;
    for (int i = 0; chunked && i < walk->count; i++) if (g_win_keys[i] == 0) keyless++;
    fprintf(stderr, "native: composite chunks=%d tiles=%d kept=%d rastered=%d keyless=%d "
                    "external=%d rasterms=%g flat=%d fail=%d@%d info=%d full=%d flatms=%g replayms=%g "
                    "workers=%d\n",
            chunked ? (walk != NULL ? walk->count : 0) : 0, g_win_tiles, kept, rastered, keyless,
            external,
            raster_ms, chunked ? 0 : 1, chunked ? 0 : comp_walk_failure(),
            chunked ? -1 : comp_walk_failure_at(), chunked ? -1 : comp_walk_failure_kind(),
            full_chunks, flat_ms, chunked ? 0.0 : g_flat_replay_ms, g_pool_threads);
    if (mask_groups > 0) {
      fprintf(stderr, "native: composite masks=%d groups=%d\n", mask_groups, g_mask_group_count);
    }
  }
  free(walk);
  return 1;
}

/**
 * Composites a damaged frame over the picture the last presented frame left. A damaged display
 * list paints the damaged rectangles afresh — the page's background over each, then every box
 * that meets them, cut to the rectangles — so the frame is the last picture with that region
 * replayed onto it. Only the damaged region is rastered and uploaded; the rest of the window is
 * the picture it already showed, so a frame that changes one box costs one small raster.
 */
static int composite_damaged_into(CompBackend *b, int target, double scale, int pw, int ph) {
  // The damaged rectangles are CSS pixels; the region they cover is device pixels, padded so a
  // box's antialiased edge lands inside it.
  CompRect region = {0, 0, 0, 0};
  if (g_damage_count > 0) {
    double x0 = g_damage_rects[0][0], y0 = g_damage_rects[0][1];
    double x1 = x0 + g_damage_rects[0][2], y1 = y0 + g_damage_rects[0][3];
    for (int i = 1; i < g_damage_count; i++) {
      const double *r = g_damage_rects[i];
      if (r[0] < x0) x0 = r[0];
      if (r[1] < y0) y0 = r[1];
      if (r[0] + r[2] > x1) x1 = r[0] + r[2];
      if (r[1] + r[3] > y1) y1 = r[1] + r[3];
    }
    int ax = (int)floor(x0 * scale) - 1, ay = (int)floor(y0 * scale) - 1;
    int bx = (int)ceil(x1 * scale) + 1, by = (int)ceil(y1 * scale) + 1;
    if (ax < 0) ax = 0;
    if (ay < 0) ay = 0;
    if (bx > pw) bx = pw;
    if (by > ph) by = ph;
    if (bx > ax && by > ay) region = (CompRect){ax, ay, bx - ax, by - ay};
  }
  if ((long)region.w * (long)region.h * 4 > (long)pw * (long)ph * 3) {
    // Most of the frame changed: drawing the page again reuses the tiles the last frame kept,
    // which is cheaper than rastering and copying a region that size.
    return composite_frame_into(b, target, scale, pw, ph);
  }
  double raster_started = now_ms();
  unsigned char *rgba = NULL;
  if (region.w > 0 && region.h > 0) {
    raster_region_rgba(scale, region, (double)pw / scale, (double)ph / scale, &rgba);
  }
  double raster_ms = now_ms() - raster_started;
  int cur = g_pic_cur;
  int next = cur == 0 ? 1 : 0;
  b->vt->pass_begin(b, g_pic_tex[next], pw, ph, 0);
  CompMatrix identity = comp_matrix_identity();
  b->vt->draw_quad(b, g_pic_tex[cur], (CompRect){0, 0, pw, ph}, &identity, 1.0f, NULL, 0.0f);
  if (rgba != NULL) {
    if (g_patch_tex < 0 || g_patch_w != region.w || g_patch_h != region.h) {
      if (g_patch_tex >= 0) b->vt->tex_destroy(b, g_patch_tex);
      g_patch_tex = b->vt->tex_create(b, region.w, region.h);
      g_patch_w = region.w;
      g_patch_h = region.h;
    }
    if (g_patch_tex >= 0) {
      b->vt->tex_upload(b, g_patch_tex, (CompRect){0, 0, region.w, region.h}, rgba, region.w * 4);
      CompMatrix M = comp_matrix_translate((float)region.x, (float)region.y);
      b->vt->draw_quad(b, g_patch_tex, (CompRect){0, 0, region.w, region.h}, &M, 1.0f, NULL, 0.0f);
    }
    free(rgba);
  }
  b->vt->present(b);
  win_pic_show(b, target, g_pic_tex[next], pw, ph);
  g_pic_cur = next;
  if (g_win_stats) {
    fprintf(stderr, "native: composite damage region=%d,%d %dx%d rasterms=%g rects=%d\n",
            region.x, region.y, region.w, region.h, raster_ms, g_damage_count);
  }
  return 1;
}

/** Composites a headless run's frame as the window would, into a texture of the page's size at
 *  the snapshot scale, for NATIVE_COMPOSITOR_LIVE runs. */
static void headless_live_composite(void) {
  if (!headless_live() || !window_compositing() || g_needs_backdrop) return;
  window_stats_init();
  CompBackend *b = window_backend();
  if (b == NULL) return;
  const double scale = 2; // the scale a headless snapshot draws at
  int pw = (int)lround(g_headless_w * scale), ph = (int)lround(g_headless_h * scale);
  if (pw <= 0 || ph <= 0) return;
  if (g_live_tex < 0 || g_live_w != pw || g_live_h != ph) {
    if (g_live_tex >= 0) b->vt->tex_destroy(b, g_live_tex);
    g_live_tex = b->vt->tex_create(b, pw, ph);
    g_live_w = pw;
    g_live_h = ph;
  }
  if (g_live_tex < 0) return;
  double started = frame_times() ? now_ms() : 0;
  composite_frame_into(b, g_live_tex, scale, pw, ph);
  if (frame_times()) fprintf(stderr, "native: composite %g ms\n", now_ms() - started);
}

/** Writes the last frame a headless live run presented. 1 written, 0 failed, -1 none. */
static int32_t snapshot_live(const uint8_t *path, size_t path_len) {
  if (!headless_live() || g_live_tex < 0 || g_window_backend == NULL) return -1;
  unsigned char *out = (unsigned char *)malloc((size_t)g_live_w * 4u * (size_t)g_live_h);
  if (out == NULL) return 0;
  int ok = 0;
  if (g_window_backend->vt->readback(g_window_backend, g_live_tex,
                                     (CompRect){0, 0, g_live_w, g_live_h}, out, g_live_w * 4)) {
    ok = write_rgba_png(path, path_len, g_live_w, g_live_h, out);
  }
  free(out);
  return ok;
}

static int32_t snapshot_to(const uint8_t *path, size_t path_len, double width, double height,
                           double scale, int cached) {
  @autoreleasepool {
    size_t pw = (size_t)(width * scale), ph = (size_t)(height * scale);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, pw, ph, 8, 0, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) return 0;
    CGContextTranslateCTM(ctx, 0, ph);
    CGContextScaleCTM(ctx, scale, -scale);
    int saved_cached = g_layer_images_on;
    g_layer_images_on = cached;
    if (cached && headless_live()) {
      // The frame the run presented last, as the window would have shown it.
      int32_t live = snapshot_live(path, path_len);
      if (live >= 0) {
        CGContextRelease(ctx);
        g_layer_images_on = saved_cached;
        return live;
      }
    }
    if (cached) {
      int32_t metal = snapshot_metal(path, path_len, width, height, scale);
      if (metal >= 0) {
        CGContextRelease(ctx);
        return metal;
      }
      // No Metal device, or a frame the walk can't express: the cached rasters below.
    }
    replay(ctx, width, height);
    g_layer_images_on = saved_cached;
    NSString *pathStr = str_from(path, path_len);
    if ([pathStr hasSuffix:@".rgba"]) {
      // Raw RGBA (premultiplied), row-major, for pixel comparisons without decoding.
      NSData *data = [NSData dataWithBytesNoCopy:CGBitmapContextGetData(ctx)
                                          length:CGBitmapContextGetBytesPerRow(ctx) * ph
                                    freeWhenDone:NO];
      BOOL ok = [data writeToFile:pathStr atomically:NO];
      CGContextRelease(ctx);
      return ok ? 1 : 0;
    }
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    NSURL *url = [NSURL fileURLWithPath:str_from(path, path_len)];
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
    if (!dst) {
      CGImageRelease(img);
      return 0;
    }
    CGImageDestinationAddImage(dst, img, NULL);
    bool ok = CGImageDestinationFinalize(dst);
    CFRelease(dst);
    CGImageRelease(img);
    return ok ? 1 : 0;
  }
}

int32_t host_snapshot(const uint8_t *path, size_t path_len, double width, double height, double scale) {
  return snapshot_to(path, path_len, width, height, scale, 0);
}

int32_t host_snapshot_composited(const uint8_t *path, size_t path_len, double width, double height, double scale) {
  return snapshot_to(path, path_len, width, height, scale, 1);
}
