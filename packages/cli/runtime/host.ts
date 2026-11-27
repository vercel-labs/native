// Native host functions (host/macos.m), bound through scriptc's FFI manifest (host/ffi.json).

export declare function hostOpen(width: number, height: number, title: string, options: string): void;
export declare function hostTitlebarArea(which: number): number;
export declare function hostWindowDrag(): void;
export declare function hostSetTitle(title: string): void;

/**
 * The application menu bar, built from a menu spec (see runtime/menus.ts): one line per item, its
 * label, accelerator and command separated by tabs, a submenu's items indented two spaces deeper.
 * "" leaves the window with the host's own default menu.
 */
export declare function hostMenuSet(spec: string): void;
/**
 * Shows a menu as a context menu at (x, y) in the window, and returns the line index of the item
 * chosen, or -1 when the menu was dismissed. The host runs the commands that belong to it (quit,
 * hide, close, …) itself; the runtime runs the rest of what the chosen item does.
 */
export declare function hostMenuPopup(spec: string, x: number, y: number): number;
/** The line index of the application menu item an EV_MENU reports. */
export declare function hostMenuItem(): number;
/** Hands the menu spec the host built or showed last back, for a headless run's `menu` step. */
export declare function hostMenuSpec(receive: (spec: string) => void): void;

/**
 * Opens the window `url` names, as `window.open()` and a link with a target do: `url` is a
 * fragment or query on the app's address, `name` the browsing context's name ("" for a fresh
 * one), and `features` the window-features string (`width=420,height=300,left=100,top=100`).
 * A name a window this one opened already has focuses that window and returns its id again.
 * Returns the window's id, or -1 when no window could be opened.
 */
export declare function hostWindowOpen(url: string, name: string, features: string): number;
/** This window's id, the same number a WindowProxy for it reports. */
export declare function hostWindowId(): number;
/** Asks the window `id` to close; 0 is this window. */
export declare function hostWindowClose(id: number): void;
/** Brings the window `id` to the front; 0 is this window. */
export declare function hostWindowFocus(id: number): void;
/** Asks the system to move focus off this window, as the page's blur() does. */
export declare function hostWindowBlur(): void;
/** The id of a window this one opened that closed, with EV_WINDOWCLOSED. */
export declare function hostWindowClosed(): number;
/** Moves and resizes this window, in screen coordinates; a value of -1 leaves that one alone. */
export declare function hostWindowSetFrame(x: number, y: number, w: number, h: number): void;
/** One number of this window's frame: 0 x, 1 y, 2 width, 3 height, in screen coordinates. */
export declare function hostWindowFrame(which: number): number;
/** Puts this window in or out of fullscreen, as the green button does. */
export declare function hostWindowFullscreen(on: number): void;
/** 1 while this window is fullscreen. */
export declare function hostWindowFullscreenState(): number;
/** 1 while this window is minimized or hidden by the system. */
export declare function hostWindowHidden(): number;
/** Minimizes or restores this window, as a headless run's `hide` and `show` steps ask. */
export declare function hostWindowSetHidden(hidden: number): void;
export declare function hostWindowMinimize(): void;
export declare function hostWindowZoom(): void;
/** This window's title as the host has it, through `receive` (for a headless run's steps). */
export declare function hostTitle(receive: (title: string) => void): void;
/**
 * Sends `data` (a JSON message body) to the window `target`: a window this one opened, or the one
 * that opened it. The receiver hears EV_MESSAGE with this window's id as the source.
 */
export declare function hostPostMessage(target: number, data: string): void;
/** The window id a message came from, with EV_MESSAGE. */
export declare function hostMessageSource(): number;
/** A message's body, through `receive`, with EV_MESSAGE. */
export declare function hostMessageData(receive: (data: string) => void): void;
/** Hides the app, hides the other apps, or shows them all: the app menu's own actions. */
export declare function hostAppAction(action: string): void;
/** Quits the app now: the event loop stops and the process ends after this frame. */
export declare function hostQuit(): void;
/**
 * The accessibility tree, as a JSON array of nodes (see runtime/a11y.ts). The host builds its
 * NSAccessibilityElements from it when VoiceOver asks, so a query never re-enters the runtime.
 */
export declare function hostAxTree(json: string): void;
/** The node id of the accessibility focus request that came with EV_AXFOCUS. */
export declare function hostAxFocus(): number;
/** The node id whose text range came with EV_AXSELRANGE. */
export declare function hostAxSelection(): number;
/** Asks VoiceOver to speak a live region's new text; priority 1 is an alert's. */
export declare function hostAxAnnounce(text: string, priority: number): void;
/** Tells the host a control's value moved, so it posts the value-changed notification. */
export declare function hostAxValueChanged(id: number): void;
/**
 * Whether an accessibility client has asked for the tree: 0 until the first query or the client's
 * request to switch it on, so a page nobody inspects never builds one.
 */
export declare function hostAxActive(): number;
/** The kind of the accessibility action that came with EV_AXACTION (an AX_* constant). */
export declare function hostAxAction(): number;
/** The stable id (AxNode.uid) of the node the action names. */
export declare function hostAxActionTarget(): number;
/** The text a set-value or insert-text action carries, handed over inside the call. */
export declare function hostAxActionText(receive: (text: string) => void): void;
export declare function hostPoll(timeoutSeconds: number): number;
/** Where in a wheel gesture the event is: 0 none, 1 began, 2 changed, 3 ended, 4 cancelled, then
 *  5–8 for the momentum that follows the fingers lifting. */
export declare function hostEventPhase(): number;
/** The display's refresh period in milliseconds, from its display link; 0 without a display. */
export declare function hostRefreshInterval(): number;
/** How long until the display's next refresh in milliseconds; 0 when the host has no clock. */
export declare function hostUntilRefresh(): number;
/** Whether a canvas in the window presents through GL, whose swap waits for the display. */
export declare function hostGlWindow(): number;
export declare function hostEventX(): number;
export declare function hostEventY(): number;
export declare function hostViewWidth(): number;
export declare function hostViewHeight(): number;
export declare function hostSetCursor(cursor: number): void;
export declare function hostSetCursorImage(image: number, x: number, y: number): void;

export declare function hostBegin(background: number): void;
export declare function hostFillRect(x: number, y: number, w: number, h: number, radius: number, color: number): void;
export declare function hostFillRing(x: number, y: number, w: number, h: number, radius: number, lineWidth: number, color: number): void;
/**
 * A filled polygon, or several as one path: `points` is `x,y x,y x,y` vertices with the path's
 * subpaths separated by `;`. Used for the mitered quadrilaterals of a border's sides.
 */
export declare function hostFillPoly(points: string, color: number): void;
// A text-decoration line: `style` is a TDS_* value, and `y` is the line's top.
export declare function hostFillLine(x0: number, x1: number, y: number, thickness: number, color: number, style: number): void;
/**
 * Every push command names the property-tree node it opens: `serial` is the element it belongs
 * to (Node.serial), and `kind` is its PK_* value. The host nests the nodes into its property
 * trees; the replay ignores both.
 */
export declare function hostClipPushPoly(serial: number, kind: number, points: string): void;
/** A clip-path ellipse; everything until the matching pop is clipped to it. */
export declare function hostClipPushEllipse(serial: number, kind: number, cx: number, cy: number, rx: number, ry: number): void;
/**
 * A clip-path shape made of closed subpaths: `points` is `x,y x,y` vertices with subpaths
 * separated by `;`, filled with the even-odd rule when `evenOdd` is set.
 */
export declare function hostClipPushShape(serial: number, kind: number, points: string, evenOdd: number): void;
// `emphasis` is a text-emphasis mark: its style in the low byte and 1 in the next for a mark under
// the text, 0 for no mark; `emphasisColor` is the colour the marks are drawn in.
/**
 * The offsets a line may break at in `text`, from the system's UAX #14 line breaker for the
 * element's language and `line-break` value: an id to read them back with, or 0 when the run
 * needs none of them (only letters, digits and spaces).
 */
export declare function hostRegisterLineBreaks(text: string, lang: string, lineBreak: number): number;
export declare function hostLineBreakCount(id: number): number;
export declare function hostLineBreakAt(id: number, i: number): number;
export declare function hostAtomicBreakForbidden(cp: number): number;

export declare function hostText(text: string, x: number, y: number, lineHeight: number, size: number, weight: number, color: number, letter: number, word: number, emphasis: number, emphasisColor: number): void;
export declare function hostTextShadow(text: string, x: number, y: number, lineHeight: number, size: number, weight: number, color: number, shadowColor: number, letter: number, word: number, dx: number, dy: number, blur: number, emphasis: number, emphasisColor: number): void;
export declare function hostPresent(width: number, height: number): void;
/**
 * Starts a damaged frame's display list: like hostBegin, but the replay must not fill the whole
 * frame with the background — the commands carry their own fills, clipped to `rects` ("x,y,w,h"
 * each, joined by ";"), so only the damaged regions of the retained backing are painted.
 */
export declare function hostDamageBegin(background: number, rects: string): void;
/** Whether a damaged frame can patch the compositor's chunk list: every serial names a chunk the
 *  last full frame drew. Hosts without a chunked compositor answer 0, and the frame paints fully. */
export declare function hostDamageCanMerge(serials: string, rects: string): number;
/** Presents the damaged rectangles over the retained backing. */
export declare function hostPresentDamage(rects: string, width: number, height: number): void;
/** Presents a frame that is already recorded in full, repainting only `rects`: the compositor's
 *  moving layers, whose commands the frame edited in place. */
export declare function hostPresentRegion(rects: string, width: number, height: number): void;
/** 1 while the window draws through the compositor, which needs the whole display list. */
export declare function hostCompositorOn(): number;
/** Rasters the display list the painter just recorded as the reference a damaged frame is held
 *  to (NATIVE_VERIFY_DAMAGE). */
export declare function hostDamageReference(width: number, height: number): void;
/** Replays the damaged list over the reference and compares the damaged rectangles; reports any
 *  differing pixels on stderr and returns how many there were. */
export declare function hostVerifyDamage(rects: string, width: number, height: number): number;
/**
 * Opens a layer: from here to the matching hostLayerPop the commands are the element's own
 * content, kept as a sublist the compositor can raster once and composite on its own. `kind` is
 * the layer's PK_* kind; a flat replay draws the sublist where it stands, so nothing changes.
 */
export declare function hostLayerPush(serial: number, kind: number): void;
export declare function hostLayerPop(): void;
/** How many layers the frame's display list holds. */
export declare function hostLayerCount(): number;
/**
 * Starts a filter or blending layer: everything painted until the matching hostEffectPop is drawn
 * into a bitmap of its own, the filter chain the spec names applied to it, and the result
 * composited into the page with the layer's blend mode. `x, y, w, h` is the box's border box in
 * CSS px; the layer itself is the filter region, 10% larger on every side. The spec is the blend
 * mode number, then each filter chain — the `filter` one and the `backdrop-filter` one — as its
 * number of functions and six numbers per function: kind, its value, drop-shadow's offsets and
 * blur, and its colour. A backdrop chain filters what is painted behind the box, within its
 * border box, before the box's own content goes over it.
 */
export declare function hostEffectPush(serial: number, kind: number, x: number, y: number, w: number, h: number, spec: string): void;
/**
 * The same, returning the command's index in the display list so the frame loop can fade the
 * group later without painting the page again (see runtime/compositor.ts).
 */
export declare function hostEffectPushIndexed(serial: number, kind: number, x: number, y: number, w: number, h: number, spec: string): number;
/** Moves the transform command at `index` to a new matrix. Returns 1 when the command is the one
 *  the caller recorded, 0 when a full paint has replaced the list since. */
export declare function hostUpdateTransform(index: number, a: number, b: number, c: number, d: number, e: number, f: number): number;
/** Sets the alpha of the opacity command at `index`, as hostUpdateTransform does. */
export declare function hostUpdateOpacity(index: number, alpha: number): number;
export declare function hostEffectPop(): void;
/**
 * Starts a mask layer over the box (x, y, w, h), the border box in the current user space. What
 * is painted from here to hostMaskSplit is the mask image; what is painted from there to
 * hostMaskPop is the content, which keeps as much of its alpha as the mask has at each pixel.
 * Nothing outside the box survives: mask-clip starts at `border-box`.
 */
export declare function hostMaskPush(serial: number, kind: number, x: number, y: number, w: number, h: number): void;
export declare function hostMaskSplit(): void;
export declare function hostMaskPop(): void;
export declare function hostSnapshot(path: string, width: number, height: number, scale: number): number;
/**
 * Writes the frame the way the compositor builds it: every layer rastered on its own and
 * composited, instead of the flat replay. Linux CI diffs it against the flat snapshot. A host
 * with no compositor yet answers 0.
 */
export declare function hostSnapshotComposited(path: string, width: number, height: number, scale: number): number;

/** Opens a video file in the host's player and returns its handle, or -1 when it can't. */
export declare function hostVideoOpen(path: string): number;
export declare function hostVideoClose(id: number): void;
export declare function hostVideoPlay(id: number): void;
export declare function hostVideoPause(id: number): void;
export declare function hostVideoSeek(id: number, time: number): void;
/** The player's current time and the clip's duration, in seconds (NaN until it is known). */
export declare function hostVideoTime(id: number): number;
export declare function hostVideoDuration(id: number): number;
/** The video's own size in pixels, 0 until it is known. */
export declare function hostVideoWidth(id: number): number;
export declare function hostVideoHeight(id: number): number;
/** 1 when the clip is ready to play, -1 when it failed, 0 while it loads. */
export declare function hostVideoReady(id: number): number;
export declare function hostVideoSetVolume(id: number, volume: number): void;
export declare function hostVideoSetMuted(id: number, muted: number): void;
export declare function hostVideoSetRate(id: number, rate: number): void;
/** What canPlayType answers for a media type on this host: 2 probably, 1 maybe, 0 no. */
export declare function hostVideoCanPlay(type: string): number;
/** Draws the frame at the player's current time into the rect, as the page paints. */
export declare function hostVideoDraw(id: number, x: number, y: number, w: number, h: number, alpha: number): void;

// The app's own files, for fetch(): the size of a regular file in bytes (-1 when it can't be
// read) and its bytes, handed over once inside the call. A missing file reads as zero bytes.
export declare function hostFileSize(path: string): number;
export declare function hostFileRead(path: string, receive: (bytes: Uint8Array) => void): void;
/** The directory an app keeps its own data in: the parent of its localStorage file. */
export declare function hostStorageDir(receive: (dir: string) => void): void;
/** Opens a SQLite database file and returns its id (0 when it can't be opened). */
export declare function hostSqliteOpen(path: string): number;
export declare function hostSqliteClose(id: number): void;
/** Runs one or more statements; the SQLite result code (0 is SQLITE_OK). */
export declare function hostSqliteExec(id: number, sql: string): number;
/** Prepares one statement and returns its id (0 on failure). */
export declare function hostSqlitePrepare(id: number, sql: string): number;
export declare function hostSqliteFinalize(id: number): number;
export declare function hostSqliteReset(id: number): number;
export declare function hostSqliteClearBindings(id: number): number;
/** Binds a value to the 1-based parameter `index`, keeping a copy of it. */
export declare function hostSqliteBindText(id: number, index: number, value: string): number;
export declare function hostSqliteBindDouble(id: number, index: number, value: number): number;
export declare function hostSqliteBindInt(id: number, index: number, value: number): number;
export declare function hostSqliteBindNull(id: number, index: number): number;
export declare function hostSqliteBindBlob(id: number, index: number, value: Uint8Array): number;
/** SQLITE_ROW (100), SQLITE_DONE (101) or an error code. */
export declare function hostSqliteStep(id: number): number;
export declare function hostSqliteColumnCount(id: number): number;
export declare function hostSqliteColumnType(id: number, col: number): number;
export declare function hostSqliteColumnText(id: number, col: number, receive: (value: string) => void): void;
export declare function hostSqliteColumnBlob(id: number, col: number, receive: (value: Uint8Array) => void): void;
export declare function hostSqliteColumnDouble(id: number, col: number): number;
/** The rows changed by the last statement, and the last inserted rowid (f64 for range). */
export declare function hostSqliteChanges(id: number): number;
export declare function hostSqliteLastId(id: number): number;
export declare function hostSqliteErrmsg(id: number, receive: (message: string) => void): void;
/**
 * The directory a bundled app's own files were copied into: the .app's Resources on macOS, the
 * resources directory beside the executable elsewhere. A build that isn't bundled never asks.
 */
export declare function hostBundleDir(receive: (dir: string) => void): void;

export declare function hostEventDX(): number;
export declare function hostEventDY(): number;
export declare function hostEventClicks(): number;
export declare function hostEventKey(): number;
export declare function hostEventMods(): number;
/** 1 when the key event is an auto-repeat: the key went down again while it was held. */
export declare function hostEventRepeat(): number;
export declare function hostEventText(receive: (text: string) => void): void;
/** The phase an EV_COMPOSE carries: 0 composition started, 1 the marked text changed, 2 the text
 *  was committed, 3 the composition was cancelled. */
export declare function hostCompositionPhase(): number;
/** The marked or committed text an EV_COMPOSE carries. */
export declare function hostCompositionText(receive: (text: string) => void): void;
/** Tells the host where the caret a composition is happening at sits, in CSS pixels from the
 *  viewport's top left, so an input method can put its candidate window under the text. */
export declare function hostCompositionRect(x: number, y: number, w: number, h: number): void;
/**
 * One format the clipboard holds: "text/plain" or "text/html", handed over once inside the call.
 * A format it doesn't hold answers "", so a caller reads text/html first and falls back.
 */
export declare function hostClipboardRead(format: string, receive: (value: string) => void): void;
/**
 * Replaces the clipboard's contents: `text` as text/plain, and `html` as text/html when it isn't
 * empty. An empty `text` with no `html` clears it.
 */
export declare function hostClipboardWrite(text: string, html: string): void;
/** How many files an OS drag that reached the window carries, for the EV_DROP event. */
export declare function hostDropFileCount(): number;
/** The name, and the path, of one of the dropped files. */
export declare function hostDropFileName(index: number, receive: (name: string) => void): void;
export declare function hostDropFilePath(index: number, receive: (path: string) => void): void;
export declare function hostSelectionColor(): number;
/** The colour the system draws a keyboard focus ring in, packed RRGGBBAA. */
export declare function hostFocusRingColor(): number;
/** Reads the text fragment the app was opened with (NATIVE_TARGET_TEXT), through `receive`. */
export declare function hostTargetText(receive: (text: string) => void): void;
export declare function hostClipPush(serial: number, kind: number, x: number, y: number, w: number, h: number, radius: number): void;

// Rounded rects with a radius per corner and per axis (top-left to bottom-left, horizontal
// then vertical), for CSS's per-corner border-radius.
export declare function hostFillRoundRect(x: number, y: number, w: number, h: number,
  tlX: number, tlY: number, trX: number, trY: number, brX: number, brY: number, blX: number, blY: number, color: number): void;
export declare function hostFillRoundRing(x: number, y: number, w: number, h: number,
  tlX: number, tlY: number, trX: number, trY: number, brX: number, brY: number, blX: number, blY: number, lineWidth: number, color: number): void;
export declare function hostClipPushRound(serial: number, kind: number, x: number, y: number, w: number, h: number,
  tlX: number, tlY: number, trX: number, trY: number, brX: number, brY: number, blX: number, blY: number): void;
export declare function hostShadowOuter(x: number, y: number, w: number, h: number,
  tlX: number, tlY: number, trX: number, trY: number, brX: number, brY: number, blX: number, blY: number,
  dx: number, dy: number, blur: number, spread: number, color: number): void;
export declare function hostShadowInset(x: number, y: number, w: number, h: number,
  tlX: number, tlY: number, trX: number, trY: number, brX: number, brY: number, blX: number, blY: number,
  dx: number, dy: number, blur: number, spread: number, color: number): void;
export declare function hostClipPop(): void;

// A CSS transform: multiplies the user space of the commands that follow by this matrix, until
// the matching hostStatePop. It saves the drawing state like a clip, so the pops nest.
export declare function hostTransformPush(serial: number, kind: number, a: number, b: number, c: number, d: number, e: number, f: number): void;
/** The same, returning the command's index so the frame loop can move its matrix in place. */
export declare function hostTransformPushIndexed(serial: number, kind: number, a: number, b: number, c: number, d: number, e: number, f: number): number;
export declare function hostStatePop(): void;

// A projected box: the commands that follow paint the box (x, y, w, h) in its own space until the
// matching hostPerspectivePop, and the layer is warped onto the quad — its four projected corners
// TL, TR, BR, BL in page space.
export declare function hostPerspectivePush(serial: number, kind: number, x: number, y: number, w: number, h: number,
  x0: number, y0: number, x1: number, y1: number, x2: number, y2: number, x3: number, y3: number): void;
export declare function hostPerspectivePop(): void;

export declare function hostFontAscent(size: number, weight: number): number;
export declare function hostFontDescent(size: number, weight: number): number;
/** The font's recommended line gap, part of `line-height: normal`. */
export declare function hostFontLineGap(size: number, weight: number): number;
/**
 * Ascent, descent and line gap in whole device pixels: a line box is laid out in device pixels,
 * with each of the three rounded to the nearest one.
 */
export declare function hostFontAscentDevice(size: number, weight: number): number;
export declare function hostFontDescentDevice(size: number, weight: number): number;
export declare function hostFontLineGapDevice(size: number, weight: number): number;
/** The font's x-height, for `vertical-align: middle`. */
export declare function hostFontXHeight(size: number, weight: number): number;
export declare function hostMeasureText(text: string, size: number, weight: number, letter: number, word: number): number;
/** Milliseconds the host spent shaping text since the last call, for the frame line's `shape=`. */
export declare function hostTextShapeTime(): number;
/**
 * A run's width and ink bounds, then the font's ascent and descent, handed over once inside the
 * call as seven little-endian doubles: width, ink left, ink right, ink ascent, ink descent, font
 * ascent, font descent. The ink is where the glyphs cover pixels, as a browser's measureText
 * reports it.
 */
export declare function hostTextMetrics(text: string, size: number, weight: number, letter: number, word: number,
  receive: (bytes: Uint8Array) => void): void;

/**
 * A rect of the canvas bitmap's own pixels, as getImageData hands them over: RGBA with every
 * channel straight rather than premultiplied, rows top down. Pixels outside the bitmap read as
 * transparent black. The bytes come to the callback once, inside the call.
 */
export declare function hostCanvasGetImageData(id: number, sx: number, sy: number, sw: number, sh: number,
  receive: (bytes: Uint8Array) => void): void;
/**
 * Writes straight RGBA pixels into the bitmap at an integer offset, replacing what is there. The
 * pixels are base64: FFI strings are the only bytes that can be handed to the host, and a pixel
 * buffer isn't text.
 */
export declare function hostCanvasPutImageData(id: number, dx: number, dy: number, w: number, h: number, pixels: string): void;

/** Registers a font file and binds it to a family name. Call before drawing text in it. */
/** One @font-face file: its family id minus FF_CUSTOM, its weight range and 1 when italic. */
export declare function hostRegisterFont(path: string, family: number, lo: number, hi: number, italic: number, ranges: string, features: string, stretch: number): void;
export declare function hostResetFonts(): void;
/** One @font-face face the system already has, named by a `local()` source: 1 when it resolved. */
export declare function hostRegisterFontLocal(name: string, family: number, lo: number, hi: number, italic: number, ranges: string, features: string, stretch: number): number;
/** An installed family a font-family list names, with the faces the system has for it: 1 when it resolved. */
export declare function hostRegisterFontNamed(name: string, family: number): number;
/** Registers one OpenType feature list (`tag=value` pairs joined by semicolons); its id is the font key's run. */
export declare function hostRegisterFeatures(spec: string): number;

/** Decodes an image file, returning a cached id (or -1 if it can't be decoded). The pixels are
 *  made on a thread of the host's, so the id is ready before they are: hostImageReady says when. */
export declare function hostImageLoad(path: string, oriented: number): number;
export declare function hostImageWidth(id: number): number;
export declare function hostImageHeight(id: number): number;
/** 1 once the image's decode is over, whether it made pixels or failed; 0 while it runs. */
export declare function hostImageReady(id: number): number;
/** 1 when the image's decode failed: the page hears an error instead of a load. */
export declare function hostImageFailed(id: number): number;
/** Waits for every image decode in flight: a headless run paints only the settled page. */
export declare function hostImagesSettled(): void;
export declare function hostImageDraw(id: number, x: number, y: number, w: number, h: number, alpha: number, smooth: number): void;
// Draws only the part of an image within a source rect, in image pixels: the cut a border image's
// slices are made of. Cropping before the scale keeps a slice from sampling its neighbours.
export declare function hostImageDrawPart(id: number, x: number, y: number, w: number, h: number,
  sx: number, sy: number, sw: number, sh: number, alpha: number, smooth: number): void;

// Canvas 2D: a bitmap per canvas, with the drawing state the runtime can't keep in CoreGraphics
// (styles, fonts) held by the host and re-applied after a restore.
export declare function hostCanvasCreate(w: number, h: number): number;
export declare function hostCanvasResize(id: number, w: number, h: number): void;
export declare function hostCanvasSave(id: number): void;
export declare function hostCanvasRestore(id: number): void;
export declare function hostCanvasSetTransform(id: number, a: number, b: number, c: number, d: number, e: number, f: number): void;
export declare function hostCanvasSetAlpha(id: number, alpha: number): void;
export declare function hostCanvasSetComposite(id: number, mode: number): void;
export declare function hostCanvasSetLineWidth(id: number, width: number): void;
export declare function hostCanvasSetLineCap(id: number, cap: number): void;
export declare function hostCanvasSetLineJoin(id: number, join: number): void;
/** The dash pattern as "<offset> <d0> <d1> …" in user units; "" strokes solid. */
export declare function hostCanvasSetLineDash(id: number, dashes: string): void;
export declare function hostCanvasSetFillColor(id: number, color: number): void;
export declare function hostCanvasSetStrokeColor(id: number, color: number): void;
export declare function hostCanvasSetFillGradient(id: number, def: string): void;
export declare function hostCanvasSetStrokeGradient(id: number, def: string): void;
export declare function hostCanvasSetFont(id: number, size: number, weight: number): void;
/**
 * The filter chain drawing operations go through, as "kind a" per CSS filter function with ';'
 * between them; "" filters nothing. The kinds are the FILTER_* list in the host, in the order the
 * CSS functions are listed there: blur, brightness, contrast, saturate, grayscale, sepia,
 * hue-rotate, invert, opacity.
 */
export declare function hostCanvasSetFilter(id: number, def: string): void;
export declare function hostCanvasBeginPath(id: number): void;
export declare function hostCanvasMoveTo(id: number, x: number, y: number): void;
export declare function hostCanvasLineTo(id: number, x: number, y: number): void;
export declare function hostCanvasQuadraticTo(id: number, cx: number, cy: number, x: number, y: number): void;
export declare function hostCanvasBezierTo(id: number, c1x: number, c1y: number, c2x: number, c2y: number, x: number, y: number): void;
export declare function hostCanvasClosePath(id: number): void;
export declare function hostCanvasArc(id: number, cx: number, cy: number, r: number, start: number, end: number, ccw: number): void;
export declare function hostCanvasArcTo(id: number, x1: number, y1: number, x2: number, y2: number, r: number): void;
export declare function hostCanvasRect(id: number, x: number, y: number, w: number, h: number): void;
export declare function hostCanvasFill(id: number, rule: number): void;
export declare function hostCanvasStroke(id: number): void;
export declare function hostCanvasClip(id: number, rule: number): void;
export declare function hostCanvasFillRect(id: number, x: number, y: number, w: number, h: number): void;
export declare function hostCanvasStrokeRect(id: number, x: number, y: number, w: number, h: number): void;
export declare function hostCanvasClearRect(id: number, x: number, y: number, w: number, h: number): void;
export declare function hostCanvasFillText(text: string, id: number, x: number, y: number, maxWidth: number): void;
export declare function hostCanvasStrokeText(text: string, id: number, x: number, y: number, maxWidth: number): void;
export declare function hostCanvasDraw(id: number, x: number, y: number, w: number, h: number, alpha: number, smooth: number): void;
/** Draws the decoded image `imageId` into the canvas: the source rect (bitmap pixels) into the
 *  destination rect, honouring the canvas's globalAlpha and composite mode. */
export declare function hostCanvasDrawImage(id: number, imageId: number, dx: number, dy: number,
  dw: number, dh: number, sx: number, sy: number, sw: number, sh: number, smooth: number): void;
/** Draws the source canvas's bitmap into the canvas: the source rect (bitmap pixels) into the
 *  destination rect, under the canvas's transform, globalAlpha and composite mode. */
export declare function hostCanvasDrawCanvas(id: number, sourceId: number, dx: number, dy: number,
  dw: number, dh: number, sx: number, sy: number, sw: number, sh: number, smooth: number): void;

// Draws the part of a canvas bitmap in a source rect, in bitmap pixels, into the rect.
export declare function hostCanvasDrawPart(id: number, x: number, y: number, w: number, h: number,
  sx: number, sy: number, sw: number, sh: number, alpha: number, smooth: number): void;

/** The window's backing scale factor (2 on a retina display), 1 headless. */
export declare function hostBackingScale(): number;
/** The display's own scale factor (2 on a retina display), with or without a window on it: the
 *  screen a first window opens on. */
export declare function hostDisplayScale(): number;
/** 1 when the system asks apps to reduce motion. */
export declare function hostReducedMotion(): number;
/** The system's appearance: 1 for dark, 0 for light. */
export declare function hostColorScheme(): number;
/** The accessibility setting that asks for more contrast: 1 when it is on. */
export declare function hostIncreaseContrast(): number;
/** The accessibility setting that asks for less transparency: 1 when it is on. */
export declare function hostReduceTransparency(): number;
/** The media type the page is laid out for: 1 for print, 0 for screen. */
export declare function hostMediaType(): number;

/** Opens the app's localStorage file (or NATIVE_STORAGE, for tests) and loads it. */
export declare function hostStorageOpen(name: string): void;
export declare function hostStorageHas(key: string): number;
export declare function hostStorageGet(key: string, receive: (value: string) => void): void;
export declare function hostStorageSet(key: string, value: string): void;
export declare function hostStorageRemove(key: string): void;
export declare function hostStorageClear(): void;
export declare function hostStorageLength(): number;
export declare function hostStorageKey(index: number, receive: (key: string) => void): void;
/**
 * A linear gradient filling the tile (x, y, w, h), running from (x0, y0) to (x1, y1). `stops` is
 * `<colour>,<position>` pairs joined by ";", positions 0..1 along the line; `alpha` comes from
 * the painted element's opacity.
 */
export declare function hostLinearGradient(x: number, y: number, w: number, h: number,
  x0: number, y0: number, x1: number, y1: number, stops: string, alpha: number): void;

/** A radial gradient filling the tile (x, y, w, h): an ellipse centred at (cx, cy). */
export declare function hostRadialGradient(x: number, y: number, w: number, h: number,
  cx: number, cy: number, rx: number, ry: number, stops: string, alpha: number): void;

/**
 * A conic gradient filling the tile (x, y, w, h): a turn about (cx, cy) starting at `angle`
 * radians, measured from the positive x axis towards the positive y axis, its stops spread over
 * the full turn.
 */
export declare function hostConicGradient(x: number, y: number, w: number, h: number,
  cx: number, cy: number, angle: number, stops: string, alpha: number): void;

// WebGL2. Every call names the canvas it belongs to, because each WebGL canvas has its own GL
// context; object names are the GL context's own. See host/macos.m for what each call does.
export declare function hostGlAttach(canvas: number, w: number, h: number, depth: number, stencil: number, antialias: number): number;
/** Whether the drawing buffer keeps its alpha (`alpha` in the context attributes). */
export declare function hostGlSetAlpha(canvas: number, alpha: number): void;

export declare function hostGlCreateBuffer(canvas: number): number;
export declare function hostGlCreateTexture(canvas: number): number;
export declare function hostGlCreateFramebuffer(canvas: number): number;
export declare function hostGlCreateRenderbuffer(canvas: number): number;
export declare function hostGlCreateProgram(canvas: number): number;
export declare function hostGlCreateShader(canvas: number, type: number): number;
export declare function hostGlCreateVertexArray(canvas: number): number;
/** `kind`: 0 buffer, 1 texture, 2 framebuffer, 3 renderbuffer, 4 program, 5 shader, 6 vertex array. */
export declare function hostGlDeleteObject(canvas: number, kind: number, object: number): void;

export declare function hostGlBindBuffer(canvas: number, target: number, buffer: number): void;
export declare function hostGlBufferData(canvas: number, target: number, usage: number, data: Uint8Array): void;
export declare function hostGlBufferDataSize(canvas: number, target: number, size: number, usage: number): void;
export declare function hostGlBufferSubData(canvas: number, target: number, offset: number, data: Uint8Array): void;

export declare function hostGlActiveTexture(canvas: number, unit: number): void;
export declare function hostGlBindTexture(canvas: number, target: number, texture: number): void;
export declare function hostGlTexImage2D(canvas: number, target: number, level: number, internalFormat: number,
  width: number, height: number, border: number, format: number, type: number, data: Uint8Array): void;
export declare function hostGlTexImage2DNull(canvas: number, target: number, level: number, internalFormat: number,
  width: number, height: number, border: number, format: number, type: number): void;
export declare function hostGlTexImage3D(canvas: number, target: number, level: number, internalFormat: number,
  width: number, height: number, depth: number, border: number, format: number, type: number, data: Uint8Array): void;
export declare function hostGlTexSubImage2D(canvas: number, target: number, level: number, x: number, y: number,
  width: number, height: number, format: number, type: number, data: Uint8Array): void;
export declare function hostGlTexStorage2D(canvas: number, target: number, levels: number,
  internalFormat: number, width: number, height: number): void;
/** Uploads a decoded image as RGBA8, flipping rows or premultiplying as unpack options ask. */
export declare function hostGlTexImage2DFromImage(canvas: number, target: number, level: number,
  internalFormat: number, image: number, flipY: number, premultiply: number): void;
export declare function hostGlTexSubImage2DFromImage(canvas: number, target: number, level: number,
  x: number, y: number, image: number, flipY: number, premultiply: number): void;
export declare function hostGlTexParameteri(canvas: number, target: number, pname: number, param: number): void;
export declare function hostGlTexParameterf(canvas: number, target: number, pname: number, param: number): void;
export declare function hostGlGenerateMipmap(canvas: number, target: number): void;
export declare function hostGlPixelStorei(canvas: number, pname: number, param: number): void;

export declare function hostGlShaderSource(canvas: number, shader: number, source: string): void;
export declare function hostGlCompileShader(canvas: number, shader: number): void;
export declare function hostGlGetShaderParameter(canvas: number, shader: number, pname: number): number;
export declare function hostGlGetShaderInfoLog(canvas: number, shader: number, receive: (log: string) => void): void;
export declare function hostGlAttachShader(canvas: number, program: number, shader: number): void;
export declare function hostGlDetachShader(canvas: number, program: number, shader: number): void;
export declare function hostGlBindAttribLocation(canvas: number, program: number, index: number, name: string): void;
export declare function hostGlLinkProgram(canvas: number, program: number): void;
export declare function hostGlUseProgram(canvas: number, program: number): void;
export declare function hostGlGetProgramParameter(canvas: number, program: number, pname: number): number;
export declare function hostGlGetProgramInfoLog(canvas: number, program: number, receive: (log: string) => void): void;
export declare function hostGlGetAttribLocation(canvas: number, program: number, name: string): number;
export declare function hostGlGetUniformLocation(canvas: number, program: number, name: string): number;
export declare function hostGlGetUniformBlockIndex(canvas: number, program: number, name: string): number;
export declare function hostGlActiveUniformName(canvas: number, program: number, index: number, receive: (name: string) => void): void;
export declare function hostGlActiveUniformType(canvas: number, program: number, index: number): number;
export declare function hostGlActiveUniformSize(canvas: number, program: number, index: number): number;
export declare function hostGlActiveAttribName(canvas: number, program: number, index: number, receive: (name: string) => void): void;
export declare function hostGlActiveAttribType(canvas: number, program: number, index: number): number;
export declare function hostGlActiveAttribSize(canvas: number, program: number, index: number): number;

export declare function hostGlUniform1f(canvas: number, location: number, x: number): void;
export declare function hostGlUniform1i(canvas: number, location: number, x: number): void;
/** `kind`: 1..4 float vector, 5..8 int vector, 9..12 unsigned vector; the count comes from `data`. */
export declare function hostGlUniform(canvas: number, location: number, kind: number, data: Uint8Array): void;
export declare function hostGlUniformMatrix(canvas: number, location: number, dims: number, transpose: number, data: Uint8Array): void;

export declare function hostGlBindVertexArray(canvas: number, array: number): void;
export declare function hostGlEnableVertexAttribArray(canvas: number, index: number): void;
export declare function hostGlDisableVertexAttribArray(canvas: number, index: number): void;
export declare function hostGlVertexAttribPointer(canvas: number, index: number, size: number, type: number,
  normalized: number, stride: number, offset: number): void;
export declare function hostGlVertexAttribIPointer(canvas: number, index: number, size: number, type: number,
  stride: number, offset: number): void;
export declare function hostGlVertexAttribDivisor(canvas: number, index: number, divisor: number): void;
export declare function hostGlVertexAttrib(canvas: number, index: number, kind: number, data: Uint8Array): void;

export declare function hostGlBindFramebuffer(canvas: number, target: number, framebuffer: number): void;
export declare function hostGlBindRenderbuffer(canvas: number, target: number, renderbuffer: number): void;
export declare function hostGlFramebufferTexture2D(canvas: number, target: number, attachment: number,
  texTarget: number, texture: number, level: number): void;
export declare function hostGlFramebufferRenderbuffer(canvas: number, target: number, attachment: number,
  rbTarget: number, renderbuffer: number): void;
export declare function hostGlRenderbufferStorage(canvas: number, target: number, format: number, width: number, height: number): void;
export declare function hostGlCheckFramebufferStatus(canvas: number, target: number): number;
/** drawBuffers, with the list as 32-bit ids (0 for NONE) in a byte view. */
export declare function hostGlDrawBuffers(canvas: number, count: number, buffers: Uint8Array): void;

export declare function hostGlDrawArrays(canvas: number, mode: number, first: number, count: number): void;
export declare function hostGlDrawElements(canvas: number, mode: number, count: number, type: number, offset: number): void;
export declare function hostGlDrawArraysInstanced(canvas: number, mode: number, first: number, count: number, instances: number): void;
export declare function hostGlDrawElementsInstanced(canvas: number, mode: number, count: number, type: number,
  offset: number, instances: number): void;

export declare function hostGlEnable(canvas: number, cap: number): void;
export declare function hostGlDisable(canvas: number, cap: number): void;
export declare function hostGlClear(canvas: number, mask: number): void;
export declare function hostGlClearColor(canvas: number, r: number, g: number, b: number, a: number): void;
export declare function hostGlClearDepth(canvas: number, depth: number): void;
export declare function hostGlClearStencil(canvas: number, s: number): void;
export declare function hostGlColorMask(canvas: number, r: number, g: number, b: number, a: number): void;
export declare function hostGlDepthMask(canvas: number, flag: number): void;
export declare function hostGlStencilMask(canvas: number, mask: number): void;
export declare function hostGlCullFace(canvas: number, mode: number): void;
export declare function hostGlFrontFace(canvas: number, mode: number): void;
export declare function hostGlDepthFunc(canvas: number, func: number): void;
export declare function hostGlDepthRange(canvas: number, near: number, far: number): void;
export declare function hostGlBlendFunc(canvas: number, src: number, dst: number): void;
export declare function hostGlBlendFuncSeparate(canvas: number, srcRGB: number, dstRGB: number, srcAlpha: number, dstAlpha: number): void;
export declare function hostGlBlendEquation(canvas: number, mode: number): void;
export declare function hostGlBlendEquationSeparate(canvas: number, rgb: number, alpha: number): void;
export declare function hostGlBlendColor(canvas: number, r: number, g: number, b: number, a: number): void;
export declare function hostGlPolygonOffset(canvas: number, factor: number, units: number): void;
export declare function hostGlStencilFunc(canvas: number, func: number, ref: number, mask: number): void;
export declare function hostGlStencilOp(canvas: number, fail: number, zfail: number, zpass: number): void;
export declare function hostGlViewport(canvas: number, x: number, y: number, w: number, h: number): void;
export declare function hostGlScissor(canvas: number, x: number, y: number, w: number, h: number): void;
export declare function hostGlLineWidth(canvas: number, width: number): void;
export declare function hostGlFinish(canvas: number): void;
export declare function hostGlFlush(canvas: number): void;

export declare function hostGlGetParameterInt(canvas: number, pname: number): number;
export declare function hostGlGetParameterFloat(canvas: number, pname: number): number;
export declare function hostGlGetParameterInts(canvas: number, pname: number, out: Uint8Array): void;
export declare function hostGlGetParameterFloats(canvas: number, pname: number, out: Uint8Array): void;
export declare function hostGlGetParameterString(canvas: number, pname: number, receive: (value: string) => void): void;
export declare function hostGlExtensionCount(canvas: number): number;
export declare function hostGlExtensionString(canvas: number, index: number, receive: (value: string) => void): void;
export declare function hostGlGetError(canvas: number): number;
export declare function hostGlReadPixels(canvas: number, x: number, y: number, w: number, h: number, out: Uint8Array): void;

export const EV_NONE = 0;
export const EV_QUIT = 1;
export const EV_DOWN = 2;
export const EV_UP = 3;
export const EV_MOVE = 4;
export const EV_RESIZE = 5;
export const EV_LEAVE = 6;
export const EV_OTHER = 7;
export const EV_KEY = 8;
export const EV_WHEEL = 9;
/** The system appearance or an accessibility display option changed. */
export const EV_SETTINGS = 10;
/** VoiceOver asked for an element to take focus; hostAxFocus() names the node. */
export const EV_AXFOCUS = 11;
/** VoiceOver set a text range on a field: hostAxSelection() names the node, and the event's x
 *  and y carry the range's location and length. */
export const EV_AXSELRANGE = 12;
/** A drag from outside the app was dropped on the window: the event's x and y are where, and
 *  hostDropFileCount() says how many files it carries. */
export const EV_DROP = 13;
/** An application menu item was chosen: hostMenuItem() is its line index in the menu spec. */
export const EV_MENU = 14;
/** The second mouse button went down at the event's x and y: a context menu's press. */
export const EV_CONTEXT = 15;
/** The window moved: its new frame is in hostWindowFrame(). */
export const EV_WINDOWMOVE = 16;
/** The window entered or left fullscreen: hostWindowFullscreenState() says which. */
export const EV_FULLSCREEN = 17;
/** The window became the key window: the page gets focus. */
export const EV_FOCUS = 18;
/** The window stopped being the key window: the page gets blur. */
export const EV_BLUR = 19;
/** The window was minimized or came back: the page gets visibilitychange. */
export const EV_VISIBILITY = 20;
/** A message arrived from another window of the app: a MessageEvent at the window. */
export const EV_MESSAGE = 21;
/** A window this one opened closed: hostWindowClosed() is its id. */
export const EV_WINDOWCLOSED = 22;
/** The app was asked to quit (Cmd+Q, or the system): the page gets beforeunload and pagehide. */
export const EV_APPQUIT = 23;

/** An input method's composition changed: see hostCompositionPhase(). */
export const EV_COMPOSE = 24;
/** An accessibility client acted on a node: hostAxAction() says how, hostAxActionTarget() on
 *  which, and the event's x and y carry a text range's location and length. */
export const EV_AXACTION = 26;

/** The actions an accessibility client can take on a node, as EV_AXACTION carries them. */
export const AX_PRESS = 1;
export const AX_FOCUS = 2;
export const AX_SET_VALUE = 3;
export const AX_INSERT_TEXT = 4;
export const AX_SELECT_RANGE = 5;
export const AX_INCREMENT = 6;
export const AX_DECREMENT = 7;
export const AX_SHOW_MENU = 8;
export const AX_SCROLL_INTO_VIEW = 9;

/** A key was released: hostEventKey() and hostEventMods() name it, and the page gets keyup. */
export const EV_KEYUP = 25;

/** An image's decode landed on a host thread: the pictures waiting for it can now be painted. */
export const EV_IMAGE = 27;

export const KEY_TEXT = 0;
export const KEY_BACKSPACE = 1;
export const KEY_ENTER = 2;
export const KEY_LEFT = 3;
export const KEY_RIGHT = 4;
export const KEY_UP = 5;
export const KEY_DOWN = 6;
export const KEY_HOME = 7;
export const KEY_END = 8;
export const KEY_ESCAPE = 9;
export const KEY_TAB = 10;
export const KEY_DELETE = 11;
export const KEY_SELECT_ALL = 12;
export const KEY_OTHER = 13;
export const KEY_COPY = 14;
export const KEY_CUT = 15;
export const KEY_PASTE = 16;

export const MOD_META = 1;
export const MOD_SHIFT = 2;
export const MOD_ALT = 4;
export const MOD_CTRL = 8;

// ---------------------------------------------------------------------------
// Web Audio (host/audio.c)

export declare function hostAudioContextCreate(rate: number, offline: number): number;
export declare function hostAudioContextRate(id: number): number;
export declare function hostAudioContextDeviceRate(id: number): number;
export declare function hostAudioContextRendered(id: number): number;
export declare function hostAudioContextResume(id: number): void;
export declare function hostAudioContextSuspend(id: number): void;
export declare function hostAudioContextCollect(id: number): void;
export declare function hostAudioContextClose(id: number): void;
export declare function hostAudioNodeCreate(id: number, type: number, extra: number): number;
export declare function hostAudioNodeRelease(id: number, node: number): void;
export declare function hostAudioConnect(id: number, src: number, dst: number, output: number, input: number): void;
export declare function hostAudioDisconnect(id: number, src: number, dst: number, output: number, input: number): void;
export declare function hostAudioParamSet(id: number, node: number, param: number, value: number): void;
export declare function hostAudioParamValue(id: number, node: number, param: number): number;
export declare function hostAudioParamEvent(id: number, node: number, param: number, kind: number,
  time: number, value: number, extra: number): void;
export declare function hostAudioParamCancel(id: number, node: number, param: number, time: number, hold: number): void;
export declare function hostAudioSourceBuffer(id: number, node: number, buffer: number): void;
export declare function hostAudioSourceStart(id: number, node: number, when: number, offset: number,
  duration: number, hasDuration: number): void;
export declare function hostAudioSourceStop(id: number, node: number, when: number): void;
export declare function hostAudioSourceLoop(id: number, node: number, loop: number, start: number, end: number): void;
export declare function hostAudioOscillatorType(id: number, node: number, type: number): void;
export declare function hostAudioBiquadType(id: number, node: number, type: number): void;
export declare function hostAudioPannerConfig(id: number, node: number, panningModel: number,
  distanceModel: number, refDistance: number, maxDistance: number, rolloff: number,
  coneInner: number, coneOuter: number, coneOuterGain: number): void;
export declare function hostAudioCompressorReduction(id: number, node: number): number;
export declare function hostAudioConvolverBuffer(id: number, node: number, buffer: number, normalize: number): void;
export declare function hostAudioBufferCreate(id: number, channels: number, frames: number, rate: number): number;
export declare function hostAudioBufferWrite(id: number, buffer: number, channel: number, bytes: Uint8Array): void;
export declare function hostAudioBufferRead(id: number, buffer: number, channel: number,
  receive: (bytes: Uint8Array) => void): void;
export declare function hostAudioBufferChannels(id: number, buffer: number): number;
export declare function hostAudioBufferFrames(id: number, buffer: number): number;
export declare function hostAudioBufferRate(id: number, buffer: number): number;
export declare function hostAudioBufferRelease(id: number, buffer: number): void;
export declare function hostAudioDecode(id: number, bytes: Uint8Array): number;
export declare function hostAudioOfflineRender(id: number, frames: number,
  receive: (bytes: Uint8Array) => void): void;
export declare function hostAudioEvents(id: number, receive: (bytes: Uint8Array) => void): void;
export declare function hostAudioAnalyserData(id: number, node: number, count: number,
  receive: (bytes: Uint8Array) => void): void;
