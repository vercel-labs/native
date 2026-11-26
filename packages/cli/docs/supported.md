# Supported HTML, CSS and DOM

Native SDK supports a growing subset of the web platform. Anything outside it is reported by `native` at build time, with a hint where one helps, or is a type error from scriptc (for example, `el.animate()` doesn't exist). `native check <dir>` lists everything an app uses that isn't supported.

- **HTML:** block, inline and inline-block elements, mixed text and inline content (`<b>`, `<em>`, `<a>`,
  `<code>`, `<mark>`, `<s>`, `<u>`, `<br>`, …), `<input>` (text and password fields; `checkbox`, `radio` and
  `range` drawn as widgets: a ticked box, a chosen radio dot and a slider whose thumb a click, a drag or the arrow keys
  move, `appearance: none` handing the box to the author, and `hidden` taking no space; `color` drawn as a 50 by 27
  swatch of the colour it holds, its value any CSS colour kept as lowercase `#rrggbb` (`#000000` when the text names
  none), and `appearance: none` or a background or border the page sets taking the swatch away; `date`, `month`, `week`,
  `time` and `datetime-local` drawn as editable segments in en-US order, with digits filling the selected segment, the
  arrow keys stepping it and moving between segments, `min`/`max`/`step` deciding validity and `stepUp()`/`stepDown()`
  moving the value by whole steps, and a calendar or clock button opening a picker drawn above the page; `button`, `submit`
  and `reset` drawn as a button labelled by the value attribute, and a submit or reset with none showing `Submit` or
  `Reset`), `<img src>` (decoded with ImageIO,
  so PNG, JPEG, GIF and the other formats it reads, with the EXIF orientation applied unless `image-orientation: none` says otherwise;
  the decode runs on a host thread, so the page paints before a large picture is ready and repaints with it when it is;
  the file is resolved at build time, next to the page or against the site root for a URL starting with `/`,
  and copied into the app's bundle at the place the page names it), `<link rel=stylesheet>` (a sheet is read from a local file at build time;
  a remote or `data:` URL is a warning and the sheet is skipped, as a browser does when it can't fetch one,
  so any font family it defines falls back like any unavailable font), `<style>`, `<script>` (external `src` and inline classic scripts,
  run in document order; each script is its own module, so they don't share globals), `<canvas>` (sized by its width and height attributes,
  300 by 150 by default, or by CSS), `<svg>` (inline SVG; see below), `style=""`, `<meta name="native-window" content="width=…, height=…">`
- **Selectors:** compounds of `tag`, `#id`, `.class`, attribute selectors (`[attr]`, `[attr=v]`, `[attr~=v]`,
  `[attr|=v]`, `[attr^=v]`, `[attr$=v]`, `[attr*=v]`, with the optional `i` flag), `:hover`, `:active`,
  `:focus`, `:focus-visible`, `:focus-within`, `:popover-open`, the form states `:checked`, `:indeterminate`,
  `:default`, `:disabled`, `:enabled`, `:required`, `:optional`, `:read-only`, `:read-write`, `:placeholder-shown`,
  `:valid`, `:invalid`, `:in-range`, `:out-of-range`, the structural `:first-child`, `:last-child`, `:only-child`, `:empty`, `:nth-child(An+B)`/`:nth-last-child()` and their `*-of-type` forms,
  `:not()`, `:is()`, `:where()`, `:has()`, `:root` and `*`, joined by descendant (` `), child (`>`), adjacent-sibling (`+`) and general-sibling (`~`) combinators,
  plus comma lists. `:not()` takes one or more compounds (`:not(.a, .b)`), `:is()`/`:where()` take compounds too and are expanded at build time,
  `:has()` takes relative selectors with any of the four combinators (`.card:has(> img)`, `:has(+ p)`, `:has(.a .b)`) and is matched at runtime, and may sit inside `:not()` (`:not(:has(> svg))`),
  so a class a script adds inside one starts it matching,
  and specificity follows the spec (`:is()`/`:not()`/`:has()` use their most specific argument, `:where()` counts zero). Combinators whose ancestor parts are only tags and ids are resolved against the static tree at build time,
  unless a script restructures the tree. The rest are matched right to left at runtime, and attribute changes restyle. A rule's subject may end in `::before`,
  `::after`, `::marker` (or the legacy `:before`/`:after`) or `::placeholder`, which styles the element's generated box
  (`::placeholder` styles the text a text field draws while it is empty);
  pseudo-elements count for one extra unit of specificity and aren't allowed anywhere else in a selector. `::file-selector-button` is valid and styles nothing (there is no file input to draw one). `:host` in a document's sheet is valid too, and matches nothing: only a shadow tree's own sheet has a host to style.
  `::first-line` and `::first-letter` paint the block's own first formatted line and its first glyph in
  their own `color` and `background-color` (the line's background fills the line box). A `::first-line`
  that changes the line's metrics — font, letter-spacing, word-spacing, line-height — lays the first
  line out again in them: it holds the characters that fit in the new font and takes that font's line
  height, while the rest of the block keeps its own. A nested inline's own run inside the first line
  still isn't restyled. A
  `::first-letter` whose rule floats it makes a drop cap: the letter gets a floated box of its own at the
  letter's font size and colour, and the rest of the text wraps beside it and under it. The letter stays in
  the element's `textContent`, selection points and painting count it, and a drag from the paragraph's
  first text copies it too.
- **State:** `:hover` and `:active` follow the pointer, and `:focus` follows focus. `:focus-visible` matches the focus a UA shows a ring for:
  Tab (or any keyboard-initiated `focus()`) gives it, a text field always has it while focused, and a pointer press doesn't.
  The form states come from the control's attributes, value and validity, and are re-derived whenever a rule or a DOM query asks
  about them, so `input:checked + label`, `fieldset:disabled input` and a `querySelector(":invalid")` see the control as it is now.
  `:indeterminate` covers a checkbox a script put in that state, `:default` the checked attribute and a form's first submit button,
  and `:in-range`/`:out-of-range` an `input[type=number]`, `[type=range]` or date or time field against its `min`/`max` (a range field with no value
  sits at the midpoint). Any element that isn't `:read-write` is `:read-only`; only an `input` of a text-like type (which includes `number` and the date types)
  and a `textarea` are writable, and a contenteditable element is not. A disabled control's text takes the UA's grey (`GrayText`)
  unless a rule sets its colour, as Chrome's sheet does, and its box keeps the background its own rules gave it.
- **Generated content:** `::before` and `::after` rules with `content` taking string literals (`content: "*"`),
  several items in a row (`content: "(" attr(data-kind) ")"`) and `attr(name)`, which is read from the originating element,
  so changing the attribute changes the text. `none` and `normal` generate no box. The generated box is a box of its own: it can be `inline`,
  `inline-block` or `block`, sized and painted like any other box, and `getComputedStyle(el, "::before")` (or `":before"`,
  `"::after"`, `":after"`) returns its computed style. It stays out of the page's markup: not in `textContent`,
  `childElementCount`, `firstElementChild`, the sibling accessors, `querySelector(All)`, `closest` or `matches`,
  and a click on it targets the originating element. `content` outside a `::before`/`::after`/`::marker` rule doesn't generate anything and is reported at build time.
- **Lists:** the UA sheet makes `<ul>` and `<ol>` blocks with a 1em vertical margin and 40px of left padding and `<li>` a `list-item` (nested `<ul>`s switch their markers to `circle` and then `square`). Every list item has a marker box: `list-style-type` (`disc`,
  `circle`, `square`, `decimal`, `decimal-leading-zero`, `lower-alpha`/`lower-latin`, `upper-alpha`/`upper-latin`,
  `lower-roman`, `upper-roman`, `none`) and `list-style-position` (`outside`, the default, right-aligns the marker against the content edge;
  `inside` makes it the item's first inline content) are inherited and also set by the `list-style` shorthand
  (which takes an `@counter-style` name wherever the longhand does),
  and a `::marker` rule can restyle the marker or replace its text with `content` (an inside marker keeps the space a
  browser's default `::marker` content puts after the number). Items number from the implicit `list-item` counter: an `<ol>`'s `start`
  attribute sets where its first item lands (1 by default), a `<li>`'s `value` attribute sets that item's number, and a `reversed` list counts down to 1.
  Counters themselves work as in CSS Lists: `counter-reset` starts a counter in the element's own scope, `counter-increment` adds to the innermost one,
  `counter-set` replaces it, and `counter()`/`counters(name, separator)` in a generated box's `content` read them (an `ol`, `ul` or `menu` implicitly
  resets `list-item`, and each list item increments it). `counter-reset: reversed(name)` starts a counter that counts down: with no value it
  takes the start its scope adds up to (the increments on its element, its descendants and its following siblings, CSS Lists 3 §4.4.2), and it
  stays in scope for those following siblings, where `counter()` reads it; list items in a reversed `list-item` counter count down by one. An `@counter-style` rule defines a style of its own — the `cyclic`, `fixed`, `numeric`,
  `alphabetic`, `symbolic`, `additive` and `extends` systems, with `symbols`, `additive-symbols`, `range`, `pad`, `fallback`, `prefix`, `suffix` and
  `negative` — and `list-style-type` and `counter()` take its name; the predefined styles beyond the ten keywords (`lower-greek`, `armenian`,
  `georgian`, `hiragana`, `katakana`, `cjk-decimal`, `cjk-earthly-branch`, `cjk-heavenly-stem`, `disclosure-open` and `disclosure-closed` among them)
  are built in by name. The marker is a box of its own but not part of the markup: it stays out of `textContent`,
  `childElementCount` and the element queries, and `getComputedStyle(el, "::marker")` returns its computed style. A marker box is made for any element that computes as `display: list-item`,
  including one a script creates or restyles.
- **Inline formatting:** line boxes with baseline alignment, word wrapping across elements, whitespace collapsing across runs,
  across inline box edges and at line edges, hanging preserved spaces at the end of a line (an ideographic space among them),
  `white-space` (`normal`, `nowrap`, `pre`, `pre-wrap`, `pre-line`, `break-spaces`), inline backgrounds,
  borders and horizontal padding (one box per line, with a box broken by a block keeping its left border on its first piece and its right border on its last),
  atomic inline-blocks such as buttons and inputs on the baseline, block-level boxes inside an inline box (the inline is broken around them and the block joins the surrounding block flow,
  margins included, like CSS's anonymous block boxes), and clicks that target the innermost inline element under the pointer. A collapsible space is dropped at the start or end of a line whatever inline box edges sit around it,
  so it neither takes room nor starts a line; a line box holding only an inline box's edges keeps its height when that box has a margin,
  padding or border, and a piece an inline box is split into that holds nothing draws none of its edges
- **Document modes:** the doctype selects the mode as HTML's algorithm does — no doctype, a non-`html`
  doctype, or an old/transitional one without a system identifier is quirks mode; the XHTML 1.0 and
  HTML 4.01 transitional/frameset doctypes are limited-quirks; everything else is standards. In quirks
  mode a percentage `height`, `min-height` or `max-height` with no containing block height resolves against
  the nearest ancestor whose height is a length, and against the viewport when there is none, so
  `height: 100%` inside auto-height boxes fills the window. Other quirks (the body's viewport fill, the
  line-height and table quirks) aren't implemented yet.
- **CSS:** `display` (block/flex/inline/inline-block/inline-flex/grid/inline-grid/list-item/none, `flow-root` (a block box with a block formatting context of its own), `contents` — the box isn't generated and the children take its place in the parent's flow — the two-keyword forms such as `inline flex` and `block grid`, the vendor aliases `-webkit-flex`/`-webkit-inline-flex`, plus the table values below; a button's box follows the HTML button layout rules whatever its display value says — an inline-level value makes it an inline-block, any other value a block box that is a flow root and shrinks to fit its content, except a flex or grid container, which still lays its content out as that value asks, and a `list-item` button draws no marker),
  flex (direction with `row-reverse` and `column-reverse`, `flex-wrap`/`flex-flow` with multiple lines and `align-content`,
  justify, align-items/self, `order`, gap, grow/shrink/basis, `flex`, auto margins that take the free space before justify-content),
  box model (`margin` incl. `auto`, `padding`, `border`, `box-sizing`, width/height/min/max), and the logical forms
  `margin-inline`/`margin-block`, `padding-inline`/`padding-block` and `inset-inline`/`inset-block` (each with one value
  for both sides or a start and an end one) plus their `-start`/`-end` longhands, and `border-inline`/`border-block` with
  their `-start`/`-end` and `-width`/`-style`/`-color` forms, all mapped to left/right and top/bottom as a horizontal,
  left-to-right page has them, with vertical margins collapsing between siblings,
  escaping the top and bottom of a parent that has no border or padding there, collapsing through empty blocks,
  and combining negatives as the largest positive plus the most negative, replaced elements (an `<img>` is sized from its intrinsic size,
  `width`/`height` attributes act as presentational hints that author CSS overrides, an `auto` dimension follows the intrinsic ratio,
  and min/max widths and heights clamp with the ratio carried over; an inline image sits on the baseline with its bottom margin edge,
  and a missing or undecodable image has no intrinsic size and draws nothing), borders per side (`border`,
  `border-top/right/bottom/left`, and the `-width`, `-color` and `-style` longhands, with each side its own width and color;
  `currentColor` is the text color; borders are drawn snapped to whole pixels, and a fractional width is floored to the device pixels it covers as browsers do,
  so a 1.9px border is 1px wide; `border-style` draws `solid`, `dashed` (dashes three widths long, one width apart),
  `dotted` (dots one width across, one width apart), `double` (two lines a third of the width), `groove`,
  `ridge`, `inset` and `outset` (shaded toward white and black from the border color), with each side keeping its own style and cut to the quadrilateral between the border box and the padding box,
  so neighbouring sides split a corner along the miter and a zero-size box draws triangles (each side runs the full length of its edge into both corners, so a double line,
  a side's first dash and a dot at the corner reach as far as the miter lets them); a rounded corner is the ring between the outer and inner rounded rect,
  and a border whose four sides agree in width, color and style is drawn as whole rings or whole runs of dashes, so its corners have no seam,
  with a dashed or dotted border's corner arcs drawn whole on a rounded box, a double border drawn as two rings and the 3D styles shading the ring's outer and inner halves),
  `border-image` (the shorthand and its `-source`, `-slice`, `-width`, `-outset` and `-repeat` longhands: a raster file, an SVG
  or a gradient source cut into nine slices, drawn into four corner boxes and four side bands that stretch or tile
  (`repeat` centres the tiles on the band and clips the ends, `round` rescales them to a whole number, `space`
  spreads them with equal gaps), with the middle painted only by `fill` and tiled by the same keywords;
  the bands are as wide as the borders (the initial width is `1`) unless `-width` changes them,
  in border widths, lengths or percentages, or `auto`
  makes each band the natural size of its slice, and `-outset` pushes the picture out past the border box;
  a border image replaces the border styles and is not cut by a rounded corner),
  `visibility` (`visible`, `hidden`, `collapse`, inherited: a hidden box keeps its room in the layout but paints nothing
  of itself and takes no pointer event, while a descendant that says `visible` shows again inside it; `collapse`
  behaves as `hidden` everywhere for now), `object-fit` (`fill`, `contain`, `cover`, `none`, `scale-down`) and `object-position` (the `<position>` keywords,
  percentages and lengths, including the four-value `right 10px bottom 20%` form), which fit the image into the content box and are clipped to it,
  `image-rendering: pixelated`/`crisp-edges` (the host scales the image with nearest-neighbour sampling instead of interpolating it),
  and `image-orientation` (inherited, `from-image` by default; `none` leaves an image's EXIF rotation unapplied),
  `overflow` (`hidden`/`auto`/`scroll`/`clip`, as the shorthand's one- or two-keyword form and as the `overflow-x`
  and `overflow-y` longhands, so one axis can scroll while the other clips or shows; only an axis left `visible`
  beside one that scrolls computes to `auto`, as CSS Overflow 3 says, and `clip` beside a scrolling axis stays `clip`,
  a box that scrolls one axis and clips the other having no scrollable value on the clipped one; `img`, `canvas` and `svg` default to `clip`,
  so an image is painted inside its content box unless CSS gives it `overflow: visible`),
  `overflow-clip-margin` (the clip a `clip` axis cuts content at is its padding box, grown by this margin on that axis
  and measured from the `content-box`, `padding-box` or `border-box` the value names; the clip edge's rounded corners grow
  with the margin, and hit testing follows it; a negative margin shrinks the clip), `position` (`relative`,
  `sticky`, `absolute` and `fixed`, with `top`/`right`/`bottom`/`left`; a sticky box stays in the flow and shifts inside the scrollport of its nearest scroll container,
  or the viewport's for the page, to keep its own insets until its containing block's content box stops it, and paint, hit testing and `getBoundingClientRect()` report it where it has shifted to;
  an out-of-flow box is taken out of the flow and blockified,
  its containing block is the padding box of the nearest positioned ancestor, or of a transformed ancestor — the viewport for `fixed` and when there is none, and for the root element itself, whose own `absolute` or `fixed` insets then size and place the whole page — a positioned inline ancestor gives the box its fragments generate,
  so a split inline's box is the union of its fragments — an `auto` offset falls back to where the box would have gone in the flow,
  and an `auto` width shrinks to fit in the room from there to the containing block's end), `z-index` (positioned boxes paint above in-flow content, negative ones below it,
  sorted by z-index within their stacking context, and clicks are routed in the same order — and a box that is a stacking
  context without being positioned, one with `opacity` below 1 or a transform, paints in the z-index: 0 layer above the
  in-flow content of its context, as CSS 2.1 Appendix E orders it, floats included (a plain inline box keeps its place among
  the runs of its line); `position: relative` also gives elements an offset parent),
  units px/%/em/rem/vw/vh/lh (the element's used line height) and the absolute in/cm/mm/q/pt/pc (96px to the inch), `inset` shorthand (`inset: 10px 20px` sets the four offsets),
  lengths inside `calc()`, `max()`, `min()` and `clamp()` (an expression whose units agree is folded at build time,
  so `calc(10px * 1.5)` and `calc(2px + 3px)` are plain lengths; one that mixes units, such as `calc(50% - 10px)` or `calc(1em + 4px)`,
  is kept as an expression and worked out when the value is used, against the same percentage base the property would use, the element's own font size for an em, the root's for a rem and the element's used line height for an lh (a value the layout reads straight from the computed style,
  such as a border width, is worked out as the style is computed), and a `calc()` may nest the other functions,
  as in `calc(min(50%, 100px) + 5px)`; a `calc()` may follow a `var()`, e.g. `border-radius: calc(var(--r) * 1.5)`;
  each argument of `max()`/`min()`/`clamp()` keeps its own unit, so `max(24px, 4vw)` grows with the window,
  and the result is `auto` when the base is indefinite; `calc(infinity * 1px)`, which Tailwind's `rounded-full` writes,
  means the largest length that fits, so a corner takes the largest radius its box allows; a length inside a media query is a plain number and unit,
  not an expression), `env(safe-area-inset-top/right/bottom/left)`, which is zero on macOS, `@media` with the `width` and `height` features (the colon form with `min-`/`max-` prefixes, and the range
  form `(600px <= width < 800px)` with `<`, `<=`, `>`, `>=` and `=`), `aspect-ratio`, `orientation`, `resolution`
  (dppx/dpi/dpcm), `hover`/`any-hover` (hover), `pointer`/`any-pointer` (fine), `prefers-color-scheme` (the macOS
  appearance, following a change while the app runs), `prefers-contrast`, `prefers-reduced-transparency`,
  `prefers-reduced-motion`, `forced-colors` (none), `color-gamut` (srgb), `scripting`, `update`, `display-mode` and the
  boolean form of any of them, joined by `and` and `or` with parentheses, comma lists, `not`, `only` and the `screen`/`all`
  (and never `print`) types, re-evaluated when the window is resized or a system setting changes (a length there is px, the
  absolute units, em or rem — both the initial 16px font size, as a media query has no element — ch (the initial font's "0"),
  the viewport units, or a `calc()`, `min()`, `max()` or `clamp()` of them), `@container` with a size query — `(width)`, `(height)`, `(inline-size)`, `(block-size)`,
  `(aspect-ratio)` and `(orientation: landscape/portrait)`, with `min-`/`max-` prefixes, the colon form, the `<`, `<=`, `>`, `>=` and `=` operators
  and the range form `400px < width < 800px`, and `and`, `or` and `not` combining them, and a top-level comma list standing for `or` — tested against the nearest ancestor
  whose `container-type` measures the axis the query reads (`size` for both axes, `inline-size` only for the inline one), and a query that names
  a container finds only one with that `container-name`; a query with no such ancestor doesn't apply, even under `not`. `container-type`,
  `container-name` (a space-separated list) and the `container` shorthand (`<name> [ / <type> ]`) set that up; a container applies
  style containment and size containment (inline-size containment for `inline-size`, so its content sizes neither its intrinsic width nor,
  for `size`, its auto height), and answers `style(--x: value)` queries with its computed custom property. The `cqw`/`cqh`/`cqi`/`cqb`/`cqmin`/`cqmax`
  units measure the nearest container (its content box; the viewport when there is none, or for the block axis of an inline-size container),
  on their own or inside a `calc()`/`min()`/`max()` of them, in a transform (`translate`, `transform-origin`), a `box-shadow`
  or `text-shadow` length, an `object-position`, a grid track, `overflow-clip-margin`, a background layer's size and position, and a colour
  stop or position of a gradient,
  and a query whose answer changes layout is re-evaluated after layout until the size it read is the size layout made;
  `@container` rules nested in a runtime `<style>` re-evaluate as a sheet is refreshed, as `@media` ones do,
  and `clip: rect(top, right, bottom, left)` on an absolutely positioned box (a side may be `auto`),
  `background-color`; `background-image` with local image files (`url()` is resolved at build time next to the page,
  or against the site root for a URL starting with `/`, and the host decodes it with ImageIO — PNG, JPEG,
  GIF and the other formats it reads; the file is copied into the app's bundle),
  or with `linear-gradient()`, `radial-gradient()` and `conic-gradient()` (a direction as an angle in deg/grad/rad/turn, or a `calc()` of angles, or as `to <corner>`,
  whose angle follows the box's shape; colour stops with percentages, lengths and em, a stop with two positions for a hard band,
  and the CSS stop fixup for missing, out-of-range or out-of-order ones; radial sizes as a circle or ellipse with explicit radii or `closest`/`farthest` `side`/`corner`;
  a conic turn with `from <angle>` and `at <position>`, whose stops are percentages or angles of the turn;
  a colour hint — a bare position between two stops — in any of the three, bending the mix so the two stops are half mixed where it sits;
  `background-color` (`color(srgb …)`, `color(display-p3 …)`, `color(a98-rgb …)`, `color(prophoto-rgb …)`,
  `color(rec2020 …)`, `color(xyz …)`, `color(xyz-d50 …)`, `color(xyz-d65 …)`, `color(srgb-linear …)` and `color(display-p3-linear …)`,
  each converted to sRGB the way a browser draws it on an sRGB surface — the channels clamped, the space's
  gamma undone, through XYZ to linear sRGB, then clipped); `background-image` with local image files `repeating-linear-gradient()`,
  `repeating-radial-gradient()` and `repeating-conic-gradient()` tile their stops along the line or round the turn,
  and a period too short for the stop budget fades to its average colour; stops mix in premultiplied alpha as CSS does,
  and the host draws the stops with CoreGraphics in sRGB), a comma-separated list of layers painted bottom-most first with `background-repeat` (`repeat`,
  `no-repeat`, `repeat-x`, `repeat-y`, and `space`/`round`, which spread the left-over room between the tiles
  or stretch them so a whole number of them fills the positioning area), `background-position`
  (keywords, percentages, lengths, and the four-value `right 10px bottom 20%` form),
  `background-size` (`auto`, lengths, percentages, `cover`, `contain`), `background-origin` and `background-clip` (`border-box`,
  `padding-box`, `content-box`, with the inner curve of a rounded corner following the outer one), `background-attachment` (`scroll`,
  `fixed` to position and size the layer against the viewport and hold it there while the page scrolls,
  though it is still only visible inside the element's own box, or `local` to position it against the element's contents, so the layer
  rides along as the element scrolls), the `background` shorthand for colours and images (`background: #0f0 url(x.png) no-repeat right 10px / 20px 30px padding-box`;
  the shorthand resets every background longhand, as it does in a browser), with a background on `<html>`,
  or on `<body>` when the root has neither a colour nor an image, painting the whole canvas but
  sized and positioned against the root's box,
  a mask on a box keeping that much of its paint as the mask image's alpha has — `mask-image` (`none`,
  a gradient or a local image file), with `mask-repeat`, `mask-position`, `mask-size`, `mask-origin` and `mask-clip`
  placing and clipping it the way their background counterparts do (a mask sits in the middle of its border box
  and repeats by default), and the `mask` shorthand resetting every mask longhand,
  `clip-path` (a basic shape — `inset()` with its corner radii, `circle()`, `ellipse()`, `polygon()`
  and `path()` — measured against the border, padding or content box, or `url(#id)` naming a
  `<clipPath>` in the page whose shapes are drawn in its own user space or in the reference box's
  unit square, with its `clip-rule`), `border-radius` (a radius for each corner,
  with the `border-top-left-radius` and other longhands taking one value or two for an elliptical curve,
  and the shorthand taking 1–4 values with an optional `/` between the horizontal and vertical radii; a percentage is taken against the box's width across and its height down,
  and adjacent corners that would overlap are scaled down together, as browsers do), `box-shadow` (one or more comma-separated shadows painted in the written order,
  the first on top; each takes `inset`, up to four lengths — the x and y offsets, then the blur and the spread,
  which may be negative — and a color that defaults to `currentColor`, in any order the grammar allows;
  an outer shadow follows the box's rounded corners and grows them with a positive spread while square corners stay square,
  and is clipped inside the border box; an inset shadow is painted inside the padding box, with the inner shape moved by the offsets;
  the blur is Gaussian, so a very large blur (past about 20px on a 2× display) is a little softer-edged than a browser's),
  `text-shadow` (a comma-separated list of shadows of the glyphs, each two or three lengths — the offsets and the blur — and a color that defaults to `currentColor`,
  painted behind the text in the written order with the first on top; a hard shadow is the run drawn again in the shadow color,
  while a blurred one is cast by the glyphs themselves, which the text covers again, so a translucent text color or opacity composites the glyphs twice),
  `outline` (`outline-style`, `outline-width`, `outline-color`, `outline-offset` and the shorthand;
  `outline-style` takes every border style, each drawn as the matching border side is, and `auto` paints as a solid ring;
  the ring is painted outside the border box and takes no room in layout), `color`,
  `font-size` (including the relative `smaller` and `larger` keywords,
  and the `medium` default, which is 16px but 13px in the generic `monospace` family, as browsers size it;
  a size that still rests on `medium` scales to the new family's medium when the family changes, and a size of 0 lays the text out at no width and draws nothing),
  `font-weight` (the 100–900 numbers with `normal` and `bold`, and `bolder` and `lighter` relative to the
  inherited weight as CSS Fonts 4 resolves them), `font-style`, `font-family` (the generic families `sans-serif`, `serif` and `monospace`
  with their `system-ui`, `ui-*` and `-apple-system` spellings, any installed family named by the page — `Arial`, `Menlo`,
  `Georgia` and the rest, taken with the faces the system has for them, so bold and italic are real ones — and fonts loaded with `@font-face` from a local file or a `data:` URL:
  a family may have several faces, each with its own `font-weight` value or range and its `font-style`, and `src` lists
  may name the same face in several places, the first source that can be used being the one taken — a `local()` name the system
  has, or a file that loads (`.ttf`, `.otf`, `.woff` and `.woff2` all read) — and a `local()` name the system lacks falls through;
  a face's `unicode-range` limits it to those characters, the rest of the family list then taking the others in order (the
  system font when the list has none), and each family keeps its own `font-palette`; a face's `font-feature-settings`
  applies to the text it draws, with the element's own settings overriding a tag they share, its `font-stretch`
  picks the face a normal-width text uses, and `ascent-override`, `descent-override` and `line-gap-override`
  replace its line metrics with that share of the font size), `font-kerning` (`auto`, `normal` and `none`,
  which turns the font's kern feature off), `font-language-override` (`normal`, or a quoted four-character language
  tag kept for the computed value), `font-optical-sizing` (`auto` or `none`, kept for the computed value) and
  `font-size-adjust` (`none`, or the x-height ratio, which scales the face so its x-height is that share of
  the font size), `font-stretch` (a keyword from `ultra-condensed` to `ultra-expanded`, or a percentage: the
  family's faces are matched by their own `font-stretch` descriptors), `font-synthesis-weight`, `-style` and
  `-small-caps` (`auto` or `none`, which the `font-synthesis` shorthand sets together) and `font-variant-emoji`
  (`normal`, `text`, `emoji` or `unicode`, kept for the computed value), `text-underline-position`
  (`auto`, `under`, `left`, `right` or `from-font`, kept for the computed value), `text-decoration-skip-ink`
  (`auto`, `none` or `all`, kept for the computed value) and `white-space-collapse` (`collapse`, `preserve`,
  `preserve-breaks`, `preserve-spaces` or `break-spaces`, kept for the computed value), `text-box-trim`
  (`none`, `trim-start`, `trim-end` or `trim-both`), `text-box-edge` (one or two of `text`, `cap`, `ex`,
  `alphabetic`, `ideographic` and `leading`, or `auto`), both kept for the computed value until the trim is
  laid out, `initial-letter` (`normal`, or a size and optional sink, kept for the computed value), and the
  SVG text baselines `alignment-baseline`, `baseline-shift` (`baseline`, `sub`, `super` or a length) and
  `dominant-baseline` (kept for the computed value),
  `font-feature-settings` (`normal`, or any number of quoted four-character OpenType tags, each with `on`, `off` or a
  whole number: the settings are put on the run's font, so both the drawing and the measuring of the text follow them,
  and a tag the font doesn't have changes nothing),
  `font-variant` and its longhands (`caps`, `ligatures`, `numeric`, `east-asian`, `position` and `alternates`: each keyword
  picks OpenType features for the font, so the text measures and draws with them, and a keyword the font lacks changes nothing;
  `font-feature-settings` is applied after the variants, so an explicit tag there overrides one a variant asked for), an
  `@font-feature-values` rule's named alternatives (`styleset(name)`, `stylistic(name)`, `character-variant(name)`,
  `swash(name)`, `ornaments(name)` and `annotation(name)` in `font-variant-alternates` resolve to the OpenType feature the
  rule names for that alias — `ss04`, `cv04`, `swsh`, `ornm`, `nalt` or `salt` — which the text then measures and draws with;
  the alias is taken page-wide rather than per family, and an alias no rule names makes the declaration invalid),
  `font-variation-settings` (`normal`, or any number of quoted four-character axis tags, each with a number: the axes are
  set on the run's font, so a variable font's text measures and draws as the axes say,
  and an axis the font doesn't have changes nothing;
  the axes ride with the feature settings, so one run can take both), `font-synthesis` (`weight`, `style`, `small-caps`,
  `none`, or several of them: a family with no face for a weight or an italic has the text emboldened by a wider stroke or
  slanted by a shear, either way leaving the advance it measures with unchanged as a browser's synthetic face does,
  and a kind turned off leaves that text on the face the family does have),
  `font-palette` (`normal`, `light`, `dark`, or a `--name` an `@font-palette-values` rule defines, for a colour
  font's COLR glyphs: `light` and `dark` take the first palette the font's CPAL table marks for that background and
  fall back to palette 0 when it marks none or has no CPAL table, and a named rule's `base-palette` and
  `override-colors` pick a palette index and replace entries of it; the palette is set on the run's font, so drawing
  and measuring agree, and a rule applies only to the font its `font-family` names, with the last matching rule
  winning),
  the `font` shorthand (`font: italic bold 14px/1.4 sans-serif`, its weight taking `bolder` and `lighter` too
  and its line height a unitless `calc()`), `line-height` (a number, or a `calc()` of numbers as Tailwind writes
  `calc(1.75 / 1.25)`, a length — a percentage or an em of the element's own font size — or `normal`,
  which uses the font's own ascent, descent and line gap, each rounded to a whole device pixel as browsers round them,
  so a normal line box is whole pixels at every backing scale), `vertical-align` on inline boxes and atomic inlines (`baseline`,
  `sub`, `super`, `text-top`, `text-bottom`, `middle`, `top`, `bottom`, and a length or percentage of the element's line height;
  `sub` and `super` use the traditional small offsets from the baseline, and the UA sheet styles `<sub>` and `<sup>` with them and a smaller font size),
  `text-align` (`start` and `end` line up with the side the direction says the text starts on, and
  `left`, `center` and `right` stay as written; `justify` spreads a line's spare room across its word spaces,
  or between its characters with `text-justify: inter-character`, leaving the last line of the block — and each
  line a forced break ends — to `text-align-last`, which starts it by default), `direction` (`ltr` or `rtl`, inherited, and set by the `dir`
  attribute: it moves `start` and `end`, and an rtl line takes its `text-indent` off the right edge;
  bidi reordering isn't done, so a run of another script stays in the order the document gives it),
  `writing-mode` (`horizontal-tb`, and `vertical-rl`/`vertical-lr`: the lines run down the page and stack across it, right
  to left or left to right, each line turned a quarter clockwise. The box's content is laid out in that frame, so an element
  child's width is the frame's block size and its height the frame's inline size, its margins, borders and padding swap and
  turn with it, and it is drawn on the page at the rect the frame maps it to with each border on its own side. A child with
  an auto width shrinks to its column and one with an auto height fills the frame's inline size, as a block's auto width
  fills and its auto height grows in a horizontal page. A box with no height of its own is as tall as the longest line its
  content makes — a `max-height` caps that — and a box whose writing mode runs across its containing block's establishes its
  own formatting context, so its margins stay inside it, and wraps at the space that block leaves across its block axis, or
  at the nearest scroll container's when that leaves none — the page's at worst, and never below its longest word. A box
  whose own writing mode
  runs across the frame's keeps its own axes: horizontal text inside a vertical box runs across the page, and the other way
  round. `sideways-rl`/`sideways-lr` lay out the same way; an inline box's own background and border still turn with its
  line rather than staying a page rect. A page takes the body's writing mode when the root element's own is the initial
  one, as overflow propagates, and the body keeps the one it was given. Upright text (`text-orientation`) isn't done yet),
  `text-transform` (`uppercase`, `lowercase` and `capitalize`; the drawn and measured text changes while the DOM's stays as written),
  `letter-spacing` and `word-spacing` (a length or `normal`; the extra room is measured into the line,
  so wrapping accounts for it, and drawn between the glyphs), `text-indent` (a length or a percentage of the content width,
  inherited, shifting and narrowing the first line; the `hanging` and `each-line` keywords aren't supported),
  `tab-size` (how many characters a preserved tab advances to, 8 by default; the column count starts over at each line break),
  `text-overflow: ellipsis` (a line that runs past the content edge ends in an ellipsis instead of being cut off at an arbitrary glyph;
  it needs `overflow` other than `visible`, and it applies to a line of the element's text,
  whether that text is the element's own or a text node inside it, such as one `innerHTML` inserted),
  `line-clamp` and `-webkit-line-clamp` (a positive whole number of lines, `none`, or `line-clamp: auto`
  to keep as many lines as the box's max-height holds: the block is then that many lines tall,
  the last of them cut to the content width and ended with an ellipsis, for its own text and for its inline children alike;
  `block-ellipsis: no-ellipsis` leaves that last line whole instead, and `line-clamp: 3 no-ellipsis` sets both;
  `display: -webkit-box` and `-webkit-box-orient` are accepted so the old spelling of a clamp works. Text below the cut
  isn't pulled up onto the last line, and a block-ellipsis string, `line-clamp: auto` without a max-height, and the
  `discard` continuation aren't supported),
  `overflow-wrap` and `word-break` (`break-word`, `anywhere` and `break-all` break a line inside a word that doesn't fit it;
  `break-all` also fills the line before breaking, and `break-all` and `anywhere` shrink a run's min-content width to its widest character — `break-word` doesn't,
  as CSS says; breaks between CJK characters aren't added at all, so `keep-all` changes nothing here),
  `hyphens` (`manual` at first: a word breaks at each soft hyphen it holds, and the hyphen is drawn where the break is
  taken and nowhere else; `none` drops the soft hyphens and breaks nowhere; `auto` keeps its computed value but breaks
  where `manual` does, since no hyphenation dictionary ships with this build), and `text-wrap` with `text-wrap-mode`
  and `text-wrap-style` (`nowrap` keeps the text on one line, as `white-space: nowrap` does, and `balance` hands the
  words of a block of six lines or fewer out evenly over the lines it wraps to; `pretty` moves the word before a lone
  last word down, so the text doesn't end on it; `auto` and `stable` break as `wrap` does. `white-space` sets the mode
  too, so `pre` and `nowrap` show in the computed `text-wrap`, and a white-space whose wrapping the mode takes away
  keeps its own collapsing and space handing),
  `text-decoration` with `text-decoration-line` (`none`, `underline`, `overline` and `line-through`, in any combination;
  a decoration belongs to the element that declares it and is drawn over the text of its in-flow descendants, in the
  colour, style and thickness that element gave it, with nested decorations all drawn, and it stops at an inline
  block, a float or an out-of-flow box, which take their own layout), `text-decoration-style` (`solid`, `double`,
  `dotted`, `dashed` and `wavy`, which draws a sine wave), `text-decoration-color` (a colour or `currentColor`,
  the initial value), `text-decoration-thickness` (a length, a percentage of the font size, `auto` or `from-font`)
  and `text-underline-offset` (a length or a percentage of the font size that may be negative, or `auto`,
  which keeps the underline just below the baseline), `text-emphasis` with `text-emphasis-style` (`none`, or a mark that is
  `filled` or `open` — `filled` at first — of the shapes `dot`, `circle`, `double-circle`, `triangle` and `sesame`,
  the dot at first; a string mark isn't drawn yet), `text-emphasis-color` (a colour or `currentColor`,
  the text's own colour at first) and `text-emphasis-position` (`over` or `under`, `over` at first, and `right` or
  `left`, which only vertical text would use and only the computed value keeps): a mark is drawn for every character,
  centred on its advance and a little beyond the font's ascent or descent, and it adds nothing to the text's advance,
  `cursor` (every keyword: the arrow, pointer, I-beam, contextual menu, crosshair, vertical I-beam, alias and copy,
  the open and closed hands, not-allowed, the four edge resizes and the corner and axis resizes, each mapped to the
  closest NSCursor macOS has publicly; the ones it has no cursor for — help, progress, wait, move, all-scroll and
  zoom in and out — are drawn at 24x24 with their hot spot in the middle, a disc with a question mark, a ring, a
  ring with hands, four arrows, and a magnifier with a plus or a minus —
  and a `url()` image before the keyword becomes the cursor, with its hotspot in the image's own pixels
  (`cursor: url(point.png) 4 5, pointer`; an image the build doesn't have leaves the keyword), while
  the keyword after it is the fallback the computed value keeps), `opacity`, `appearance` (also `-webkit-appearance`: a widget keyword and `auto` both get the UA's own
  painting, and `none` leaves the control's box entirely to the author), `accent-color` (inherited; the colour a
  checked box, a chosen radio and a range's lit parts take, `auto` at first, which is the UA's own blue),
  `color-scheme` (inherited; `dark` paints the UA's dark colours — white text, the #121212 canvas, dark fields,
  buttons, dialogs and popovers, Chrome's dark defaults — while `light`, `normal` and a list whose `light` comes
  first under a light system keep the light ones; `light dark` follows the system's `prefers-color-scheme`), `touch-action` (read back as the gestures it allows, `auto` at first; the app has a pointer and no touchscreen, so it changes nothing),
  `pointer-events` (inherited; `none` makes a box see-through to the pointer, which reaches what is painted behind
  it — its hover, presses, clicks and carets — while a descendant can ask for them again with `auto`; the SVG
  keywords all hit as `auto`, since a picture is drawn whole) and `user-select` (also `-webkit-user-select`,
  inherited: its computed value is kept and serialised, but the one selection here is a text field's own and a
  browser lets a press take that text whatever the field says, so it changes nothing yet),
  `transform` (`matrix()`, `translate()`/`translateX()`/`translateY()`,
  `scale()`/`scaleX()`/`scaleY()`, `rotate()`, `skew()`/`skewX()`/`skewY()`, and `matrix3d()`/`translate3d()`/`scale3d()`/`rotateZ()`/`rotate3d()` about the z axis and the other 3D functions (`matrix3d()`,
  `translate3d()`/`translateZ()`, `scale3d()`/`scaleZ()`, `rotateX()`/`rotateY()`/`rotateZ()`, `rotate3d()`),
  comma separated and applied right-to-left as CSS does, an angle taking a `calc()` of angles (`rotate(calc(var(--angle) * -2))`),
  with the whole list multiplied out in 4x4 so a rotation that turns the box onto the page composes with a depth translation the way it does in a browser,
  and the result projected onto the page; a matrix that can't be inverted paints nothing, `transform-origin`'s z is honoured,
  and a constant `w` divide is folded into the projection (`matrix3d(..., 0,0,0,2)` paints at half size);
  the box paints and hit tests through the matrix, and a transformed box is a stacking context of its own,
  the containing block for its absolutely and fixed positioned descendants, and a transformed fill is snapped to device pixels as a browser snaps a transformed layer) and `transform-origin` (keywords,
  lengths and percentages, against the border box, defaulting to its centre), the individual `translate`,
  `rotate` and `scale` properties composing outside `transform` as `scale`, `rotate`, `translate`,
  `transform-style` (`flat`, the initial value, or `preserve-3d`; a 3D rendering context isn't built
  yet, so a preserve-3d page is painted flattened into its parent's plane), `will-change` (`transform`, `opacity` and `filter` make the box a stacking context with a layer of its own, as the spec says; the other names are a hint that changes nothing),
  `filter` (`blur()`, `brightness()`, `contrast()`, `grayscale()`, `hue-rotate()`, `invert()`, `opacity()`, `saturate()` and `sepia()`,
  each taking its number or percentage, and `drop-shadow()` with two or three lengths and a color that defaults to `currentColor`;
  `none`, or a list whose functions apply in the written order, the later ones to the output of the earlier ones.
  The element and its descendants paint into a layer covering the border box grown by 10% on every side, so a blur or drop-shadow bleeds
  that far and no further, as in a browser, and the layer is a stacking context of its own; the blur is Gaussian, matching a browser's),
  `mix-blend-mode` (`normal`, `multiply`, `screen`, `overlay`, `darken`, `lighten`, `color-dodge`, `color-burn`, `hard-light`,
  `soft-light`, `difference`, `exclusion`, `hue`, `saturation`, `color`, `luminosity` and `plus-lighter`; the element's own layer blends
  with what is already painted behind it, and the element becomes a stacking context) and `isolation` (`auto`, or `isolate` to make a
  stacking context that keeps its descendants' blending to the layers inside it); `backdrop-filter` takes the same filter list and
  filters what is already painted behind the element within its border box, leaving the element's own
  content to paint over the result (a filtered box is also a containing block for its out-of-flow
  descendants),
  custom properties (`--accent: #333`, case-sensitive, inherited, set by a rule, a style attribute or `style.setProperty()`,
  with `var(--accent)` and `var(--x, fallback)` substituted into any value when its style is computed,
  so they work inside shorthands; the substituted value stays a token sequence of its own, so `var(--b)red`
  with `--b: orange` reads as two identifiers rather than the one colour `orangered`; a cycle, or a var() with neither a value nor a fallback, leaves the property guaranteed-invalid,
  and a substituted value that doesn't parse leaves its property — every longhand of a shorthand — at the inherited or initial value,
  as invalid-at-computed-value-time does in a browser, and in a debug or headless run it is reported once per property and substituted value on stderr,
  with the parser's reason; `getPropertyValue("--accent")`, `setProperty` and `removeProperty` read and write them,
  and changing one restyles the elements that read it; `CSS.registerProperty()` makes one non-inheriting or gives it
  an initial value, while `CSS.supports()` answers from the same value parser and `CSS.escape()` serializes an
  identifier; a `@property` rule registers one with a `syntax`, an `inherits` flag and an `initial-value`, each rule
  checked at build time and an invalid one dropped whole with a note: `syntax` is `*` or a `|` list of component types —
  `<length>`, `<percentage>`, `<length-percentage>`, `<number>`, `<integer>`, `<angle>`, `<time>`, `<resolution>`,
  `<color>`, `<string>`, `<custom-ident>`, `<url>` and the rest of the grammar — and keywords, with `+`, `#` and `{m,n}`
  multipliers, and `initial-value` must belong to it; a registered property doesn't inherit unless `inherits: true`,
  starts at its initial value where nothing sets it, keeps that initial value where a declaration doesn't belong to the
  syntax, and `inherit`, `initial`, `unset`, `revert` and `revert-layer` resolve against the registration; a rule may sit
  in a `@media` or `@supports` block at build time, and the last rule for a name wins), the CSS-wide `inherit`, `initial`,
  `unset`, `revert` and
  `revert-layer` on every property this build supports, shorthands included: `inherit` takes the parent's computed value,
  `initial` the property's own initial one, and `unset`/`revert`/`revert-layer` inherit on an inherited property and take
  the initial value otherwise, with `!important` allowed as with any value, `@starting-style` (the declarations of the rules inside style an element's first rendered state, so a
  transition set on the element runs from them to the regular style; they apply for that one pass only,
  and an element no such rule matches costs nothing extra), `@namespace` (a default namespace and named prefixes, matched by `ns|tag`, `*|tag` and `|tag`; an element under
  an inline `<svg>` is in the SVG namespace, as a browser's DOM has it), `@scope` (`@scope (.card) { … }`, or with a
  `to (.limit)` end: a rule inside matches only elements within the nearest ancestor matching the scope root, and not
  those at or below an element matching the limit; an unnamed root means the whole document), cascade layers (`@layer name { … }` blocks, `@layer a, b;` order
  statements, dotted and anonymous layers, and nested layers whose own rules come after their sublayers; a later layer beats
  an earlier one for normal declarations and the order reverses for important ones, and rules outside any layer are in the
  implicit final layer, so they beat every layer normally and lose to every layer when important), `@supports` with `(prop: value)`,
  `not`, `and`, `or` and parentheses, decided at build time against what this build compiles (so `@supports (not (-webkit-appearance: -apple-pay-button))`
  holds and `@supports (color: color-mix(in lab, red, red))` does too, while a guard for a property or value this build rejects doesn't;
  a failing guard's rules are dropped with a note), the conditional at-rules a rule may hold (`@supports`, `@media`, `@container` and `@starting-style`), whose declarations apply in place
  to the rule's selector when their condition holds, and CSS Nesting's nested style rules (`&:hover { … }`, a child written as
  a descendant selector, `&` anywhere in the selector, and nesting inside a nested at-rule; the nesting selector takes the
  specificity of what it stands for, as the spec says), `transition` (`transition-property`, `-duration`,
  `-timing-function` and `-delay`, each a comma-separated list, with `all` and `none`, named properties,
  the named curves, `cubic-bezier()` and `steps()` with each jump keyword, and delays; lengths, colors,
  numbers and opacity interpolate, and a property that changes partway through starts again from where it had got to;
  a `transform` list interpolates function by function when both ends name the same functions, `none` as the
  identity of the other list, and otherwise through the matrices the two lists resolve to, decomposed into
  translation, rotation, scale and skew as CSS Transforms 2 has it),
  `@keyframes` (percentages, `from` and `to`, the last block at an offset winning) with `animation-name`,
  `-duration`, `-timing-function`, `-delay`, `-iteration-count` (`infinite` too), `-direction`, `-fill-mode` and `-play-state`,
  the `transition` and `animation` shorthands, and the `transitionrun`, `transitionstart`, `transitionend`
  and `transitioncancel` events, plus the `animationstart`, `animationiteration`, `animationend` and
  `animationcancel` ones (`propertyName`, `animationName` and `elapsedTime`; a transition a new value
  replaces, or one `display: none` takes away, is canceled), all driven by the frame clock
  (`requestAnimationFrame`'s timestamp, which headless runs set with `frame <ms>` so tests are deterministic),
  `getAnimations()` on an element (with `{ subtree: true }`) and on `document`, reporting each running
  transition and animation with `transitionProperty`, `animationName`, `playState`, `currentTime`,
  `startTime`, `cancel()`, `finish()`, `pause()`, `play()` and a `finished` promise,
  and `!important` on any declaration (an important declaration beats normal ones whatever their specificity or order;
  among important declarations the origin order reverses, so an important inline style outranks an important rule,
  which outranks a normal inline style)
- **Colors:** named colors, `#rgb`/`#rgba`/`#rrggbb`/`#rrggbbaa`, `rgb()`/`rgba()`, `hsl()`/`hsla()` and `hwb()` in both the
  comma and space syntax with an optional `/ alpha` (a number or a percentage), and `oklab()`, `oklch()`, `lab()` and
  `lch()`, each with `L`, the Cartesian components or the polar chroma and hue (degrees, or `deg`/`grad`/`rad`/`turn`),
  and the `/ alpha` form; percentages mean their component's 0–100% range. `lab()` and `lch()` are the D50 CIE spaces
  and convert through chromatic adaptation to sRGB. `light-dark(<color>, <color>)`, which picks by the element's used colour scheme (`color-scheme`), and `color-mix(in <space>, <color> [<percentage>], <color> [<percentage>])`
  interpolates premultiplied by alpha in `srgb`, `srgb-linear`, `oklab`, `oklch`, `lab` or `lch`, with a hue following
  the shorter arc, a missing percentage the complement of the other (both missing means an even mix), and percentages
  that don't add up to 100% normalised. A component may be a `calc()` of numbers or percentages, which folds at build
  time: `hsl(calc(var(--hue) + 40), 80%, 50%)` reads as `hsl(40, 80%, 50%)` once its `var()` is substituted, in a
  gradient as much as in a plain color. A relative color — `rgb(from <color> r g b)`, `lab(from <color> l a b)`,
  `color(from <color> display-p3 r g b)`, and the same in the other color functions and spaces — takes the origin
  color's own channels, in that order or another, with an optional `/ alpha`. `currentColor` as the origin stays
  unresolved in the computed value, so an inherited relative color follows the inheriting element's own color.
  `contrast-color(<color>)` is black or white, whichever contrasts more with the color it is given.
  `color(srgb-linear …)` and `color(display-p3-linear …)` take channels that are already linear-light. Any property
  that takes a color takes all of these, at build time and when a script sets one.
- **DOM:** nodes are real: `Node` is the base class, `Element`/`HTMLElement` (with `HTMLInputElement` and `HTMLCanvasElement`) inherit from it,
  and `Text`, `Comment`, `DocumentFragment` and `Document` are nodes of their own, so `instanceof` and `nodeType` (`1`,
  `3`, `8`, `9`, `11`) answer as on the web. Text in the markup is a text node (a `#text` child with `data`),
  editing `data` or `textContent` restyles and repaints, and generated boxes stay out of the tree. Every node has `nodeName`,
  `nodeValue`, `parentNode`, `parentElement`, `childNodes`, `firstChild`/`lastChild`/`nextSibling`/`previousSibling`,
  `ownerDocument` and `textContent`, and `compareDocumentPosition` answers where another node sits — preceding,
  following, containing, contained by — or that the two are in different trees, as the DOM's bitmask has it;
  elements add `children`, `firstElementChild`/`lastElementChild`/`nextElementSibling`/`previousElementSibling`,
  `childElementCount`, `namespaceURI` and `localName`. `document` has `documentElement`, `body`, `title`,
  `activeElement`, `createElement`, `createElementNS`, `createTextNode`, `createComment`, `createDocumentFragment`,
  `createTreeWalker` (over a subtree, taking the node types `NodeFilter`'s `SHOW_*` flags name — all of them at
  first — and what a filter accepts, rejects, or skips: a function, or an object whose `acceptNode()` is;
  `TreeWalker` walks forward and back, and steps to a child, sibling or parent, from `currentNode`, which is where
  the walk left it. An element that still holds its content as its own text gives it the `#text` child a browser
  would have had before the walk reads its children), and `createNodeIterator` (the same nodes in document order,
  one at a time from a cursor that sits beside a reference node, so it keeps its place when a caller removes
  the node it was just given),
  `getElementById`, `querySelector`/`querySelectorAll` and the live `getElementsByTagName`,
  `getElementsByClassName` and `getElementsByName` lists (an `HTMLCollection` re-reads the tree as
  nodes, classes, ids and names come and go; it is an array subclass, so positional reads, `length`
  and iteration are the array's, and `Array.isArray` is true of it, which a browser's is not);
  `elementFromPoint` and `elementsFromPoint` answer where the pointer would land at a viewport
  point — the topmost element, or every element under it, topmost first — laying the page out first
  as a browser forces layout, and skipping a box the pointer can't reach (`pointer-events: none`,
  inert, `display: none`), an ancestor with no box under the point, and any point outside the
  viewport, even where a box overflows past its edge; on elements: `textContent`, `className`, `classList`
  (`add` and `remove` take any number of tokens, and `toggle`, `replace`, `contains` and `supports` keep the
  DOM's token rules, an empty token being a `SyntaxError` and one with whitespace an `InvalidCharacterError`),
  `id`, `hidden`, `get/set/remove/has/toggleAttribute`, `style`, `appendChild`, `append`, `prepend`, `insertBefore`,
  `replaceChild`, `removeChild`, `remove`, `replaceChildren`, `replaceWith`, `contains`, `closest`, `matches`,
  `focus`, `blur`, `click`. `style` is a `CSSStyleDeclaration`: `getPropertyValue`, `setProperty` and
  `removeProperty` take any name, and every property this build parses also has its camelCase accessor, on the
  declaration a style attribute gives and on the computed one `getComputedStyle` returns (`el.style.maxWidth`,
  `cs.pointerEvents`, `style.webkitUserSelect` for the prefixed spelling), so asking for a property this build
  doesn't parse is a type error at build time. Only `clear` has no accessor, since the name is the declaration's
  own `clear()`, which drops every declaration.
  A document fragment inserts its children when appended, as a browser does.
  `querySelector`/`querySelectorAll`/`matches`/`closest` take the same selectors as the style sheets do — combinators,
  selector lists (`a, b`), `:is()`/`:where()`/`:not()` (including a selector list inside `:not()`), attribute selectors
  with every operator and the `i` flag, the structural pseudo-classes and `:scope` — so the DOM and the cascade select
  the same elements; a pseudo-class or pseudo-element the runtime has no use for is valid and matches nothing, and an
  invalid selector throws a `SyntaxError` as a browser does. `getBoundingClientRect` and `getClientRects` answer in
  viewport coordinates: a box that has one reports its border box, an inline box reports a rect per run of its
  fragments — one per line it is broken across and one around each nested inline box, as tall as its font box plus its
  vertical padding and border, with its margins left out — and its bounding rect is the union of them, so an inline
  span has the height of its text rather than of its line. In a box that lays its content out down the page the rects
  are turned back onto the page with the line, so a column's rect is a page rect as tall as the text it holds
- **Popovers and inert:** an element with the `popover` attribute draws only while it is open (the UA sheet's
  `[popover]:not(:popover-open) { display: none }`), `popover` reads `"auto"`, `"manual"` or null, and `showPopover()`,
  `hidePopover()` and `togglePopover()` fire `beforetoggle` (cancelable) and `toggle` with their `oldState` and `newState`,
  throwing `NotSupportedError` or `InvalidStateError` where the DOM does. A button or input with `popovertarget` toggles
  the element it names (`popoverTargetElement`, with `popoverTargetAction` for `show` and `hide`), a press outside an open
  auto popover or Escape closes it, and showing an auto popover closes the auto popovers already open. An open popover
  lives in the top layer (see below) and draws above the page. `inert` takes the element's subtree
  out of the tab order and out of the pointer's reach.
- **Containment:** `contain` takes `none`, `strict`, `content` or any of `size`, `layout`, `style`
  and `paint` (a combination ORs them), plus the level-2 axis sizes `inline-size` and `block-size`, which contain
  one axis only. `size` makes the box ignore its contents for its own inline and block
  sizes — the same rule a size container follows — `layout` makes it a formatting-context root and a containing
  block for its out-of-flow descendants, `paint` clips its contents to its padding box, and `style` changes nothing
  here because `native` has no counters for it to scope.
- **Scroll markers:** `scroll-marker-group: before | after` on a scroll container generates its
  `::scroll-marker-group` box as a sibling just before or after the container, and each of the container's
  element children generates a `::scroll-marker` inside that group, styled by the child's own rule and drawing
  `content` (a bullet when the rule gives none) — a row of markers that tracks the children as they are added or
  removed. `:target-current` names the child whose top the scrollport starts at (and so its marker), following the
  container as it scrolls, and clicking a marker scrolls its child to the start of the scrollport. The scroll
  buttons (`::scroll-button()`) aren't there yet.
- **The top layer:** `showModal()` puts a dialog in the top layer: it paints above everything else, in the order the
  top-layer elements were shown (later ones on top), at its own place in the viewport rather than where it sits in the
  tree, and a `::backdrop` box fills the viewport under it with that pseudo-element's background (`rgba(0, 0, 0, 0.1)`
  from the UA sheet; only the background is painted, so a blur or an image there isn't). `close()`, a closed `open`
  attribute or `hidePopover()` takes the element back out, and it paints where it sits again. Light dismiss, Escape and
  the dialog's `close` event behave as above. A popover in the top layer takes Chrome's place for it — the UA sheet
  gives it `position: fixed`, `inset: 0`, a `fit-content` size in both axes and `margin: auto`, so it sits as big as
  its content wants, centred in the viewport, and an author's `left`/`top` combine with the auto margins Chrome's
  style leaves the other insets at.
- **Selection:** a drag over text with the pointer selects it (from where the press landed to the
  pointer), a double-click selects the word under the pointer and a triple-click the whole element,
  counted by the host's own click count (`MouseEvent.detail` says which), and
  `document.createRange()` and a `Selection` over one range — `setStart`/`setEnd`,
  `selectNodeContents`, `collapse`, `toString`, `commonAncestorContainer`, `collapsed`, and a range's
  `getClientRects`/`getBoundingClientRect` (one rect per line it spans, as wide as the characters that line holds);
  the selection's
  `addRange`/`removeAllRanges`/`collapse`/`extend`/`selectAllChildren`, its `anchorNode`/`focusNode`/
  `rangeCount`/`type`/`isCollapsed` readers, and `toString()`/`containsNode()` answer from the text the range
  covers, across element boundaries. The selected text paints the system's selection colour behind it (the host's
  `selectedTextBackgroundColor`, which follows the user's accent colour), Cmd+C fires a cancelable `copy` event and,
  unless it is handled, puts the selected text on the pasteboard (see Clipboard for the events' payload), and a `::selection` rule's `background-color` and
  `color` paint the selected stretch, inheriting down the tree as a highlight does. Text-field selection is the
  field's own.
- **Value ranges:** `createValueRange(start, end)` on an `<input>` of type text, search, url, tel or password, or a
  `<textarea>`, makes an `OpaqueRange` (also an `AbstractRange`, as `Range` and `StaticRange` are) whose
  `startOffset`/`endOffset` are live offsets into the control's value rather than nodes: replacing the value or
  calling `setRangeText()` moves them as replace data moves a live DOM range's (writing the same text changes
  nothing), `disconnect()` or taking the control out of its document (an input changed to a type with no value
  text included) collapses it, and `getClientRects`/`getBoundingClientRect` give the boxes the covered text draws
  in, one per line (a collapsed range reports a caret box). Offsets past the value are an `IndexSizeError`, and an
  element with no value text is a `NotSupportedError`. A `Range` is live the same way through `replaceData()`
  (and `appendData`/`insertData`/`deleteData`, which it is built on).
- **Custom highlights:** the Custom Highlight API's data model — `new Highlight(...ranges)` with `add`, `delete`,
  `has`, `clear`, `size`, an integer `priority` and `type`, iterating over its ranges as a set does (a text node
  stands for a range over all of its text) — and `CSS.highlights`, the registry keyed by name with
  `get`/`has`/`set`/`delete`/`clear`/`size` and iteration over [name, highlight] pairs; a name that isn't a CSS
  custom-ident throws, as the API says. A `::highlight(name)` rule paints the ranges registered under that
  name: its `background-color` behind them and its `color` on their glyphs, highest `priority` on top, the style
  inherited down the tree as Chrome's is, and the selection's own highlight painting over them.
- **Text fragments:** an app opened with a text fragment (`NATIVE_TARGET_TEXT`, see docs/cli.md — the value a URL's
  `#:~:text=` directive carries, `[prefix-,]start[,end][,-suffix]` with percent escapes decoded) paints the first
  match, ASCII case-insensitively, where it falls: the page's `::target-text` rule gives the highlight's
  `background-color` and `color`, and without a rule it is the browser's pale yellow (`rgba(255, 255, 0, 0.4)`).
  A prefix or suffix the text doesn't have, or a start that isn't there, matches nothing, and the selection paints
  over the target's highlight.
- **Inputs:** `value`, `placeholder`, `type`, `select()`, `setSelectionRange`, and the usual macOS editing keys (⌥ moves by word, ⌘ by line, ⇧ extends the selection, ⌘A selects all, ⌘C copies the field's selection, ⌘V pastes), plus click and drag to select, Tab focus cycling, a blinking caret, Enter submitting the form the field is in, and Enter or Space on a focused button clicking it

- **Audio:** an `<audio>` element plays through the Web Audio engine: `src` (a page-relative file — a bundled one included — or a `data:` URL) is fetched and decoded by `load()` with the engine's decoders (WAV, MP3, Ogg Vorbis, and on macOS what AudioToolbox reads, AAC and M4A among them), and `play()` starts the buffer on the context the elements share. `paused`, `ended`, `duration`, `currentTime`, `volume`, `muted`, `playbackRate`, `loop`, `autoplay` and `readyState`/`networkState` read and write as a browser's do, and the element sends `loadstart`, `durationchange`, `loadedmetadata`, `loadeddata`, `canplay`, `canplaythrough`, `play`, `playing`, `pause`, `seeking`, `seeked`, `timeupdate`, `ended`, `volumechange` and `error`. `createMediaElementSource(element)` moves the element's sound into the calling context's graph at the same playhead (a `MediaElementAudioSourceNode`, one per element), so an app can process it before the destination. A `<video>` element is the next bullet.
- **Video:** a `<video>` element is a replaced box, as big as its clip (300 by 150 before the metadata arrives, `width`/`height` attributes and CSS overriding that), and on macOS AVFoundation opens the file: the frame at the player's current time is drawn into the box as the page paints, while the element's state machine, events, `currentTime`, `volume`, `muted`, `playbackRate`, `loop` and `autoplay` behave as the audio element's do. The picture comes from `AVPlayerItemVideoOutput`; the sound is the player's own, so `createMediaElementSource` throws `NotSupportedError` for a video for now. On Linux the host decodes through our own LGPL FFmpeg build (`packages/cli/host/ffmpeg/build.sh`), loaded from an explicit `NATIVE_FFMPEG_LIB` directory, then a `lib/` directory beside the executable, then the system loader: it reads the royalty-free set (MP4, WebM, Ogg, WAV, FLAC and MP3 containers; VP8, VP9, AV1, Opus, Vorbis, FLAC, MP3 and PCM), and H.264 or AAC only when the system `libavcodec` that was found has their decoders. A build with no FFmpeg answers `""` from `canPlayType` and reports `MEDIA_ERR_SRC_NOT_SUPPORTED` when a video loads. A Linux video plays silently for now: it has no audio output.

- **Composition:** an input method composes into the focused text field (an `input` of a text-like type or a
  `textarea`): the marked text is underlined where it sits, `compositionstart`, `compositionupdate` and
  `compositionend` fire with the text, and an `input` event follows each change — `insertCompositionText` while
  composing, `insertFromComposition` on commit and `deleteCompositionText` on cancel — with the field's `value`
  already holding the marked text, and the field's events `isComposing` while it runs. A selection the composition began
  over is replaced, and leaving the field commits what it was showing. On macOS keys go through
  `NSTextInputClient`, so dead keys and every installed input method work and the candidate window is placed at the
  caret; a headless run drives the same path with the `compose`, `commit` and `cancelcompose` steps.
- **Selects:** a closed `<select>` draws its chosen option's label and opens the UA's own picker on a click the user makes, Enter, Space, Alt+↓ or an arrow key — a panel over the page with the options under their `optgroup` labels, the chosen one highlighted, and a list taller than the window scrolled to it. The arrows and Home/End move the highlight and type-ahead reaches an option by the letters it starts with, both moving the field to the option as Chrome's menulist does and sending `input` then `change`; a disabled option is passed over and painted grey; a click picks the row under the pointer; a wheel scrolls the rows; and Escape, Tab, Enter or Space closes the panel. A list box (`multiple`, or a `size` over one) keeps its rows in the page, chosen by a click or the arrows and extended with Shift.
- **Scrolling:** trackpad and wheel scrolling of `overflow: auto` containers, and of the page itself, on both axes — a wheel's horizontal delta
  (`scrollWheel`'s `deltaX`) rolls a container or the page sideways, a vertical one scrolls it down, and each axis follows its own overflow:
  a wheel rolls only an axis that is `auto` or `scroll` (never `hidden` or `clip`), and the rest of the delta chains to the next scrollport up,
  as in a browser. The root element scrolls the viewport when its content overflows (with `overflow` propagating from the root,
  or the body when the root's is `visible`, so `hidden` on either stops it), a wheel that nothing inside took rolls the page,
  `window.scrollX`/`scrollY`, `scrollTo()` and `scrollBy()` move it, the `scroll` event fires on the document and then the window,
  `position: fixed` boxes stay put while it rolls, a macOS-style overlay scrollbar for the viewport and for containers (down the right edge,
  and along the bottom edge for horizontal scrolling, and only on the axes that can scroll), `document.scrollingElement`,
  and `scrollTop`, `scrollLeft`, `scrollHeight`, `scrollWidth`, `clientHeight`, `clientWidth`, `scrollIntoView()`,
  and the element's own `scroll()`, `scrollTo()` and `scrollBy()` (numbers or an options object),
  which lay the page out first, as a browser forces layout for a scroll, so a scroll made before the
  first frame or right after a change clamps against the box's real scroll extent.
  Script scrolls a `hidden` box as well as an `auto` one, but an axis that is `clip` or `visible` has nothing to scroll and keeps its offset at 0.
  `scroll-behavior: smooth` (inherited) makes a script's scroll travel instead of jump: `scrollTo()`, `scrollBy()`, `scroll()` and a
  `scrollTop`/`scrollLeft` assignment ease to the target over animation frames and fire `scroll` events as they move, while
  `behavior: "instant"` in the options jumps at once and `behavior: "auto"`, or no options, follows the box's computed value.
  The root's value reaches the viewport; a body's does not. A wheel stops a journey where it has got to.
  `scrollIntoView({block, inline, behavior})` lines the box up with `start`, `center`, `end` or `nearest` on each axis
  (the defaults are `start` and `nearest`), scrolling every container on the way to the viewport.
  A container with a `scroll-snap-type` lands on a snap position instead of wherever a scroll asked it to go:
  the type names the axes it snaps (`x`, `y`, `block`, `inline`, `both` or `pair`, which snaps only the areas that
  line up on both axes) and how tightly (`mandatory`, or `proximity`, which reaches only a third of the snapport).
  A snap area is a box with a `scroll-snap-align` on either axis, standing where it would be unscrolled, grown by
  its `scroll-margin` and lined up with the container's scrollport shrunk by its `scroll-padding` — `start`, `center`
  or `end`. The nearest position within reach wins, and a container that snaps both axes keeps the two areas that
  are visible together. A script scroll, a `scrollIntoView()` and a layout land on a snap position, and a container
  whose area moves in a later layout scrolls along with it.
  A container clips everything it holds, relative and sticky descendants and all — only a box whose containing block is outside it,
  such as a fixed one or an absolutely positioned one anchored above it, escapes — and its scrollbar is drawn over that content rather than under it.
  A box's scrollable overflow is its content: a child box wider than it, a `nowrap` line or other inline content running past its content edge,
  and any absolutely positioned box, whose margin box reaches into every ancestor whose content box it passes. A descendant that scrolls or clips itself
  (`overflow` other than `visible` on either axis) ends there: its own overflow is its own, and it doesn't grow an ancestor's `scrollWidth`.
  That reach is measured past the content box, so a box's own padding is never scrollable overflow: `scrollWidth` is `clientWidth`
  plus how far the content goes past the content edge, and `scrollLeft` stops short there too.
- **IntersectionObserver:** `observe`, `unobserve`, `disconnect` and `takeRecords`, with `root` (the viewport when null),
  `rootMargin` (one to four px or % values) and `threshold` (a number or a list). After each frame's layout an entry
  arrives for a target that first became observed or whose ratio crossed a threshold, carrying `isIntersecting`,
  `intersectionRatio`, `boundingClientRect`, `intersectionRect` and `rootBounds`. A target is not reported as
  intersecting while its box is `display: none` or out of the document. The intersection is clipped by the root's box
  and margin only, not by the scroll containers in between.
- **Geometry:** `offsetParent`, `offsetLeft`, `offsetTop` and `ResizeObserver`. Offsets measure
  from the padding edge of the nearest positioned ancestor (a table or table cell counts), and a box with none measures
  from the initial containing block. A `ResizeObserver` callback runs in the next frame with the content box as
  `contentRect` and the border box as `borderBoxSize`, once for each observed element and again when a frame's size
  for it differs.
- **Flexbox sizing:** grow and shrink follow the CSS algorithm: the flex base size comes from `flex-basis`,
  else the item's width, else its max-content size, and ignores the item's own min/max size; the hypothetical main size clamps it by min/max;
  an item with a zero flex factor is frozen at that size; an item that runs into its minimum or maximum size is frozen there and the rest is redistributed;
  and flex factors summing to less than one distribute only that share of the free space. Row items get the automatic minimum size (`min-width: auto`) from their min-content width — a replaced item transfers it through its aspect ratio from its used cross size,
  including a stretched one — and column items from their min-content height (so, as in Chrome, list rows need `flex-shrink: 0` to keep their height inside a scroller). Items in a wrapping container are sized to their fit-content width,
  each line shares the container's cross size through `align-content` (a single wrapped line stretches too),
  an item on `first baseline` or `last baseline` moves along the cross axis until its own baseline meets the line's — the first-baseline items share the largest distance from the cross-start edge to one of theirs and the last-baseline items the largest from one of theirs to the cross-end edge, an item with no baseline of its own standing in with its border box's edge —
  and contiguous text runs become anonymous flex items. An `inline-flex` container is an atomic inline box aligned on the baseline of its first flex line. An absolutely positioned child of a flex container takes its static position from `justify-content` and `align-items` (with `stretch` counting as the start),
  and a flex item with a `z-index` creates a stacking context even while it stays static. An item paints as one unit, the way an inline block
  does, in the order the items stand — so a later item's background covers the text of an earlier one.
- **Multi-column:** `columns` (a width, a count, or both), `column-count`, `column-width` and `column-gap` (whose `normal`
  is one em here) lay a block's content out into columns: the count and width follow CSS Multicol's pseudo-algorithm, and
  an auto width gives as many columns as fit. `column-fill: balance` (the initial value) balances the content across as
  few columns as it can fit, `auto` fills the columns in order when the box has a height of its own, and a box with no
  height keeps one column's worth of content. A child with `column-span: all` takes the full content width between runs
  of columns. `column-rule`, `column-rule-width`, `column-rule-style` and `column-rule-color` draw a rule in each gutter
  (a style other than `none` is drawn solid). The columns take block-level children: a child taller than its column
  splits across columns at the boundaries between its own block-level children, and each piece paints the child's
  background over its own stretch of it — the piece holding the box's top edge draws its top border and top corners, the
  one holding its bottom edge draws the bottom border and bottom corners, and a cut edge has no border, as
  `box-decoration-break: slice` draws. A box with nothing inside it, or one that holds text or inline content, stays in
  one piece and overflows the column. A `break-before` or `break-after` on a child of any of the
  forced kinds (`page`, `column`, `region`, `left`, `right`, `recto`, `verso`, and the `always` alias) starts a new
  column, so it splits the content wherever it falls, and `avoid` or `avoid-column` moves the boxes it holds together to
  the next column when the break would land between them. The margins that adjoin a break are truncated; the top margin
  of the box that opens a column after a forced break is kept. Line-level splitting between columns isn't there yet.
- **Grid lanes:** `display: grid-lanes` and `inline-grid-lanes` (masonry): one axis keeps normal tracks
  (`grid-template-columns` or `grid-template-rows`, with `repeat()` and `grid-auto-*`), and the other packs items into
  the least-filled lane. Each item in order takes the shortest lane it can span — the grid-placement properties place it
  in the lanes it names or spans, and a span takes the highest of the lanes it covers — then that lane's running position
  advances by the item's size and the gap. `grid-lanes-direction` takes `row` or `column` (the default follows the
  template: lanes run down columns unless only the rows name tracks) with `fill-reverse` and `track-reverse`:
  `fill-reverse` stacks each lane from the container's end edge (upward in a column lane, leftward in a row lane, with
  that side's margin leading) and hangs the content there, and `track-reverse` numbers the lanes from the end, so auto
  placement starts in the last one and a tie breaks toward it. `grid-lanes-pack: dense` backfills from the start. A row
  lane is as tall as the items that land in it. `fit-tolerance` (a length, `normal` = 1em, or `infinite`) is how
  close to the shortest a lane must be to count as tied. Not yet: subgrid lanes, and the stacking-axis alignment and
  fragmentation rules.
- **Grid:** `display: grid` and `inline-grid`, with `grid-template-columns`/`grid-template-rows` taking lengths, percentages,
  `auto`, `min-content`, `max-content`, `fit-content()`, `minmax()` and `fr`, and `repeat()` with a positive count,
  `repeat(auto-fill, …)` and `repeat(auto-fit, …)` (as many copies as fit a definite content box, `max-width`, or — through a preferred
  aspect ratio — `max-height`, while a definite `min-width`, or a `min-height` the ratio turns into one, asks for the fewest copies
  that reach it; an `auto-fit` copy no item lands in collapses with its gutters);
  `grid-auto-columns`/`grid-auto-rows` size the implicit tracks an item's placement adds, and `grid-auto-flow` runs
  `row`, `column` or either `dense`; `grid-column`/`grid-row` and `grid-area` (with their `-start`/`-end` longhands) take line
  numbers, negative lines counted back from the end of the explicit grid, `span N` and `auto`;
  a track list's `[name]` groups name the line they sit on (before the next track, or after the last one), and a placement
  may name a line instead of numbering it, either side taking an occurrence count — `a 2`, `b -1` — while `span a 1` reaches
  forward to the next line of that name; a line past the explicit grid carries every name, so a name with no line of its own
  starts on the first implicit line and `span <name>` covers one implicit track. `grid-template-areas` takes its row strings, `grid-area: <name>` fills the named area, and each
  area names its edges `<name>-start` and `<name>-end` for the other placements to reach;
  `gap`/`row-gap`/`column-gap`
  (and the older `grid-gap` spellings) separate the tracks, a percentage resolving against the content box (`normal` is what a gap starts as, and its percentage
  leaves an intrinsic size out); the `grid` and `grid-template` shorthands take `<rows> / <columns>`, and `grid` also the
  `auto-flow` forms that pair one template side with an auto-flowing other side; `place-items`, `place-content` and
  `place-self` set the two axes at once; `justify-items`/`justify-self` and `align-items`/`align-self` (shared with flex) place an
  item in its area, `stretch` included, and auto margins take the free space first. The alignment keywords are CSS Box
  Alignment's: `start`, `flex-start`, `self-start` and `left` sit on the start edge, `center`, and `end`, `flex-end`,
  `self-end` and `right` on the end edge (a page laid out left to right reads the physical edges that way), and a `safe` or
  `unsafe` overflow position may front any of them: `safe` puts an item, or a track set, that overflows its area or its
  container on the start edge, while `unsafe` — and a position with no overflow keyword — lets it overflow both edges.
  Each keyword keeps the word it was written with in the computed value (`start` and `flex-start` included). `normal` stretches an item too, except
  for one that brings a size of its own — a replaced box or one with a preferred aspect ratio — where it starts the item.
  `baseline`, `first baseline` and `last baseline` share a baseline across the items of a row: the row is as tall as the
  furthest item above that baseline plus the deepest one below it, and each item moves down until its own first (or last)
  baseline sits on the group's. A box with no baseline of its own — one that holds no line box, or one written across
  the container's block axis, whose own baselines run along that axis rather than across it — synthesizes one from its
  bottom edge, except that a percentage height, which has no size to resolve against while the row is being measured,
  leaves such a box out of the group. An item spanning tracks joins the group of the row it starts in (the row it ends in, for `last baseline`), an
  auto block margin takes it out of the group. On the inline axis a container whose axis runs down the page shares one
  baseline among the items written across that axis: the group takes the first (or last, as `justify-self` names it)
  baseline of each of them, so it reaches as far before that baseline as the furthest of them and every item moves along
  the axis until its own baseline sits on the group's, which puts a `last baseline` group against the end of the axis.
  A box written the container's own way has no baseline across that axis, so the baseline values fall back to the start
  edge there (`last baseline` the end edge), and an inline auto margin takes an item out of the group. `align-content` and `justify-content` take them too, packing the track set on the start
  edge, or the end edge for `last baseline`, as one container forms a single group. A grid container that is itself aligned on a
  baseline offers the first baseline of the first item in its first row that lines up on one, in grid order — that item's own first
  baseline whichever side of it the item lines up on, or its border box's when no item there lines up on one — and its last row's
  for `last baseline`, so a grid inside a flex or grid line puts that item's baseline on the line. The track sizing algorithm is CSS Grid's: base sizes
  come from fixed lengths or from the items' min-content contributions, growth limits from fixed lengths or max-content
  contributions, free space grows the tracks to their limits, `fr` tracks share what is left after the definite ones (each
  keeping its automatic minimum, and the factors counted as at least one, so `0.4fr` rows leave room over), and every track
  whose maximum is `auto` stretches into the rest of a definite width or
  height — so an `auto-fit` collapse leaves its room to the copies that stay. A percentage track, or a `fit-content()`
  given one, sizes as `auto` while the container's own size is indefinite, and resolves against the size the tracks then
  give the container: in a shrinkwrapped float or an auto-height grid a `20%` row takes a fifth of the height the rows ask
  for, and the auto rows stretch into what it leaves over. A flexible track in a container with no size of its own is worth
  the room its items ask for, and CSS Grid resolves it in two passes: the row takes its factor's share of the item's own
  size, which makes the container that tall, and the rows then share out that height — two `0.4fr` rows around a 100px item
  are 40px each, then 32px. An item spanning more than one column, one of them flexible, has an automatic minimum size of
  zero, so a wide descendant overflows it instead of widening those columns. A run of tracks whose maximums are all fixed
  caps the automatic minimum size of an item that takes its size from its content, so `minmax(auto, 0)` rows and columns
  take no room and their items overflow them, while an item that states its own size keeps it — with its padding
  and borders around it — and a `min-content` or `max-content` minimum keeps the content's size. A baseline-aligned item's minimum contribution carries a shim — the
  distance from its own baseline to the one its group shares — which the fixed maximums in that run clamp along with
  the rest of the contribution, but never below the item's own border, padding and shim, so `minmax(auto, 0)` beside a
  shimmed item keeps the room down to its baseline. An item that scrolls in an axis takes no automatic minimum size in that axis,
  so an `auto` track it alone occupies collapses to nothing and its content overflows. A column's contributions are resolved a second time once the rows have their sizes, so a percentage
  height or an aspect ratio that the row settles can change how wide a track has to be. `justify-content` and `align-content` place the track set in a container with room to spare —
  `start`/`end`/`center`, the three `space-*` packings and `stretch`, which is what `normal` means for a grid. An
  out-of-flow child takes its static position in the content box, aligned by `justify-items`/`align-items` — and one whose
  containing block the grid container is takes the area its placement names as its containing block, so its percentages and
  offsets resolve against the area, and its static position is that area's start corner, aligned by its own
  `justify-self`/`align-self`; an `auto` side of the placement sits on the corresponding padding edge of the grid container,
  so a box with no placement at all fills the padding box, and a line the grid doesn't have counts as `auto`. This holds for
  any out-of-flow descendant the grid is the containing block of, not only a direct child; a baseline keyword there
  falls back to the start edge, or the end edge for `last baseline` — and grid items
  paint in `order`-modified document order. An `inline-grid` shrinks to fit its tracks. Auto-placement follows the placement algorithm:
  items placed on both axes take their cells first, then the cursor walks the flow axis, wrapping at the end of a line and
  taking the first free span, with `dense` packing each item from the start of the grid. `grid-template-columns` or
  `grid-template-rows` may be `subgrid`: the item then adopts the tracks it spans in its parent for that axis — their
  sizes and the parent's gutter, with the subgrid's own `gap` where it sets one — and its items' line numbers count from
  the subgrid's first line. A subgrid's items contribute their content to the parent's auto track sizing through the
  subgrid (as a spanning item's contribution), and a subgrid's own margin, padding and border are not yet applied as the
  extra layer of margin the spec puts on its edge items. Line names written after `subgrid` are read and accepted but
  don't name lines yet. Not yet: an out-of-flow child placed by auto-placement taking the container's padding box as its
  containing block (it takes the content box).

- **Intrinsic sizing:** min-content and max-content widths treat a percentage width as `auto`, as CSS Sizing does,
  except a table's own percentage width, which resolves against the space available to it. So a percentage-width child inside a flex item doesn't inflate the item's automatic minimum size. `width`,
  `height`, `min-width`, `max-width`, `min-height` and `max-height` take the `min-content`, `max-content` and `fit-content` keywords: a width keyword measures the content's own width (`fit-content` is max-content squeezed into the space available but never below min-content),
  and a height keyword lays the box out at the inline size it names and takes the height it reaches (`fit-content` on the block axis fits the height available to the box,
  and is max-content when it has none). The keywords count the box the way `box-sizing` says: a border-box box's keyword includes its padding and border. A child's percentage margin is cyclic while this box's width is what is being measured,
  so it resolves against zero in a min-content or max-content width, and an absolutely positioned box measuring its own shrink-to-fit width resolves its content's percentage heights against the height its offsets pin. A child's cyclic percentage `min-width` resolves against zero in a min-content or max-content contribution,
  and its cyclic percentage `max-width` counts as `none` there, as CSS Sizing says; where the containing block's width is already known the percentage resolves against it. A `fit-content` width in a contribution is the max-content width when contributing a max-content size and the min-content width when contributing a min-content one,
  since the space to fit into isn't known yet. Floats contribute their outer widths to a box's max-content width (with no line to break they all sit on one line) and the widest of them to its min-content width.
- **Aspect ratio:** `aspect-ratio` takes `auto`, a `<ratio>` such as `16 / 9` or `1.5`, or `auto <ratio>`. A bare ratio relates the box `box-sizing` sizes,
  while `auto <ratio>` relates the content box, as a replaced element's own image ratio does. With one axis specified the other follows the ratio,
  a definite height gives an auto width through it, and `auto <ratio>` makes the ratio's height a floor the content can grow past rather than a fixed size. A definite height transfers through the ratio into the box's intrinsic width,
  min-height and max-height transfer into the inline axis, and a specified height is clamped by min/max-height before it transfers. <img>, `<canvas>` and an inline `<svg>` have their image's ratio as their preferred ratio (an svg's is its `viewBox`): `auto <ratio>` keeps the image's and falls back to the given one,
  a bare ratio overrides it, and `box-sizing: border-box` on an image's own ratio still counts the content box. Absolutely positioned boxes follow the same rules against their offsets — the ratio decides the height when the width is pinned,
  and the width when only the height is. A `width` or `height` naming `min-content`, `max-content` or `fit-content` gives way to the ratio on its axis,
  and in the block axis those keywords behave as `auto`. A `min-height` or `max-height` naming an intrinsic keyword on a replaced box names the block size it takes at its inline size,
  given the box's own ratio, so that height transfers into the inline axis as a used height does, and an intrinsic-keyword width on a replaced box resolves a definite height first so the ratio can name the width. A minimum transferred from `min-height` is capped by a definite `max-width`,
  which the box can't exceed. A box whose height a preferred ratio makes definite closes its bottom edge to margin collapsing,
  so its last child's bottom margin stays inside it, as a browser does. A flex item's main size, and its automatic minimum size,
  come from the cross size it is given or stretches to, through its ratio.
- **Tables:** `display: table`, `inline-table`, `table-row-group`, `table-header-group`, `table-footer-group`,
  `table-row`, `table-cell`, `table-column`, `table-column-group` and `table-caption`, with automatic and fixed table layout,
  column widths from cells and `<col>`/`<colgroup>` (colspan and rowspan included), percentage widths,
  `border-spacing` in the separate borders model (a percentage is not a length, so the declaration is ignored,
  as a browser does), captions above or below the table (`caption-side`), `background-color` on a table's rows,
  row groups, columns and column groups (the table paints them beneath its cells, each part only in the areas its cells cover,
  so the border spacing between parts stays clear), `vertical-align` (baseline, top, middle, bottom) inside cells (baseline-aligned cells line up their first lines,
  and content in an anonymous cell counts too, so text directly inside a row gives the row a baseline;
  an inline-table sits on its line by its first row's baseline, or by its bottom edge when it has none),
  and the `<table>`, `<caption>`, `<colgroup>`, `<col>`, `<thead>`, `<tbody>`, `<tfoot>`, `<tr>`, `<td>` and `<th>` defaults in the UA sheet. A `<table>` is `border-box` and an auto-width table shrinks to its preferred width,
  and its `height` is a minimum, so it is never shorter than the rows it holds; a cell's `height` is a minimum too, so content taller than it stretches the row,
  though not when the content only overflowed because a child's percentage resolved against the cell itself (an intrinsic pass resolves it against nothing). The `cellspacing`, `cellpadding`,
  `border`, `width` and `height` attributes act as presentational hints that author CSS overrides (`width` on `<col>` sizes the column), and stray content inside a table row gets an anonymous cell. Table-related boxes outside a table (a lone `display: table-cell` in a `div`,
  say) are wrapped in anonymous table boxes (CSS 2.1 §17.2.1/17.2.2): a run of table-internal siblings becomes an anonymous table that shrinks to fit,
  missing rows, cells and row groups are supplied around stray content, and a block inside an anonymous cell splits it into the surrounding flow. A table box's own text is wrapped in an anonymous cell too,
  and white space between table parts generates nothing whatever `white-space` says; an anonymous cell's inline content breaks into lines like a block's,
  and the cell is as tall as all of them. A floated table part computes to `block` (CSS 2.1 §9.7), so a floated row group or row becomes a block whose cells the anonymous-table fixup wraps,
  and a float in an anonymous cell's content is laid out in the cell, which is a formatting context of its own. A replaced element can't be a table part,
  so an `<img>` with a table-internal `display` is inlined and an anonymous cell wraps it as it would inline content. `empty-cells: hide` draws no background or border for a cell with no content,
  a collapsed row, column, row group or column group (`visibility: collapse`) keeps no room at all — its cells, content and border spacing go with it, even when a row inside a collapsed group asks to stay visible — while `visibility: hidden` keeps the room, and under `border-collapse: collapse` the border spacing is removed, conflicting borders on a shared edge are resolved for each cell edge segment on its own (`hidden` wins outright,
  then the wider border, then the stronger style, then the source order), the winning border is split half to each side,
  and the table paints each stretch of a grid line at the width of its own segment, a cell's content inset by the halves of its own edges,
  a `box-sizing: border-box` width (or `min`/`max-width`) on a cell covering those halves so its border box is the size it names,
  and a row's specified `height` is its border box, counted from the centre of one grid line to the centre of the next, and a cell's `height` sets its row's in the same way.
  A table with a height taller than its rows gives the extra to the rows that name no height, in proportion to the height each needs (or equally when they need none),
  and shares it out in proportion to their heights when every row has one. A fixed-layout table's `width` decides how its space is shared,
  but its declared columns and the border spacing are a floor under it, and with no auto columns the extra goes to the columns that declared a length,
  in proportion to it, while a percentage column keeps its share. A percentage `padding` on a cell counts as zero while the table works out how wide its columns have to be. A row,
  row group or cell with `position: relative` moves by its offsets, its cells and content with it; a percentage offset in the block axis resolves against the height its containing block was given,
  since a table part grows past that height to hold its content. A positioned part that takes a share of the collapsed grid keeps painting with the table's cells,
  so the grid it shares stays above its background.
- **Floats and clearing:** `float` (`left`, `right`), `clear` (`left`, `right`, `both`), and clearance. A float is blockified — an inline-level one keeps its place in the inline content around it,
  going at the top of the line it appears on so that line is shortened by it, and never higher than the line the content before it ended on,
  and shrinks to fit its containing block's width; it has no effect on a flex item. Each float is pushed down until it fits beside the floats before it,
  then held to the content edge on its side, sliding below a float in its way; a block-level one that follows content goes below the line boxes that content made unless its own content still fits beside the last of them. Line boxes are shortened beside floats: a line box with no room for its first unbreakable run,
  or one the floats push into, moves below them, and a block formatting context root — `overflow` other than `visible` on either axis,
  a flex item, an inline-block, a table cell or a float — avoids the floats outside it, narrowing into the space they leave or dropping below them,
  and its `auto` height includes its own floats. `shape-outside` gives a float an outline for the lines and boxes beside it to clear:
  the same basic shapes `clip-path` takes (`inset()`, `circle()`, `ellipse()`, `polygon()`), against `margin-box` (the default for a float),
  `border-box`, `padding-box` or `content-box`, and `shape-margin` grows the outline outward (a `path()` or `url()` shape is
  more than the line fitting reads, so the float keeps its box). A float's box paints below the inline content beside it, as
  CSS 2.1 Appendix E orders them; its own contents still paint above the inline content around it.
- **Canvas 2D:** `canvas.getContext("2d")` with `width`/`height` (setting either resets the bitmap and the drawing state),
  and on the context: the state stack (`save`/`restore`), transforms (`translate`, `rotate`, `scale`, `transform`,
  `setTransform`, `resetTransform`), paths (`beginPath`, `closePath`, `moveTo`, `lineTo`, `quadraticCurveTo`,
  `bezierCurveTo`, `arc`, `arcTo`, `ellipse`, `rect`, `roundRect` with one radius, a point or a list of one to four
  spread over the corners and shrunk to fit), `fill`/`stroke`/`clip` with the optional `"evenodd"` rule,
  `fillRect`/`strokeRect`/`clearRect`, `fillStyle`/`strokeStyle` as any CSS color (**Colors:** above), or a `CanvasGradient` from `createLinearGradient`/`createRadialGradient` with `addColorStop`,
  `globalAlpha`, `globalCompositeOperation` (`source-over`, `lighter`, `copy`, `destination-out` and the usual other Porter-Duff and blend modes),
  `filter` (the CSS filter functions `blur`, `brightness`, `contrast`, `saturate`, `grayscale`, `sepia`, `hue-rotate`,
  `invert` and `opacity`, alone or in a chain, applied to each drawing operation as the page draws it; `drop-shadow()`
  and `url()` references are not supported),
  `lineWidth`, `lineCap`, `lineJoin`, `fillText`/`strokeText` with `font`, `textAlign` and `textBaseline`,
  and `measureText` (the advance, the ink box `actualBoundingBox*`, the font box `fontBoundingBox*` and the
  hanging/alphabetic/ideographic baselines). `createImageData`, `getImageData` and `putImageData` move the bitmap's
  pixels in and out as straight RGBA (`putImageData` writes where it is told and ignores the transform, the clip and
  `globalAlpha`, as a browser's does; the bitmap is premultiplied inside, so a translucent colour reads back within a
  step). The bitmap is backed by a CoreGraphics bitmap context in the host and drawn into the page as an image,
  so a canvas scales and clips like any replaced element, and a snapshot is pixel-exact.
- **WebGL 2:** `canvas.getContext("webgl2", attributes)` returns a typed `WebGL2RenderingContext` backed by a desktop OpenGL core context of its own (CGL on macOS, EGL surfaceless on Linux);
  calls execute as they are made, and each paint resolves the drawing buffer into the canvas bitmap the page draws,
  so a WebGL canvas scales, clips and composites like a 2D one. The context attributes are honoured: `alpha` (a false one paints the bitmap opaque),
  `depth`, `stencil` and `antialias` (4x MSAA, resolved on paint) decide the attachments, and `premultipliedAlpha`,
  `preserveDrawingBuffer`, `powerPreference`, `failIfMajorPerformanceCaveat` and `desynchronized` are accepted and reported back by `getContextAttributes`. Shaders are written in GLSL ES 3.00 (`#version 300 es`) and compiled as desktop GLSL 4.10,
  with only the version line rewritten, so `precision` declarations are accepted as they are. On the context: buffers,
  textures (`texImage2D`, `texImage3D`, `texSubImage2D`, `texStorage2D`, parameters, `generateMipmap`,
  pixel-store state; an upload's source may be an `<img>`, an `ImageData`, or a canvas — 2D or WebGL — each
  read as straight RGBA8 rows, and `UNPACK_FLIP_Y_WEBGL` and `UNPACK_PREMULTIPLY_ALPHA_WEBGL` apply to those
  sources as the API specifies, while typed-array uploads ignore them),
  shaders and programs (`shaderSource`, compile and link, the info logs, active uniform and attribute reflection,
  `bindAttribLocation`), uniform locations and every `uniform1/2/3/4{f,i,iv,fv,uiv}` and `uniformMatrix{2,3,4}fv`,
  vertex arrays and vertex attributes (including `vertexAttribIPointer` and the divisor), framebuffers and renderbuffers (`checkFramebufferStatus`),
  draws (`drawArrays`, `drawElements`, and the instanced pair), the state setters (`enable`/`disable`,
  `clear`, colour/depth/stencil masks, cull and front face, depth func and range, blend func/equation,
  `polygonOffset`, viewport, scissor, `lineWidth`, `hint`), `readPixels`, `getParameter` with WebGL's answers (version and shading-language strings,
  the uniform-vector limits as component counts, `MAX_ELEMENT_INDEX`, the current bindings and state),
  `getShaderPrecisionFormat`, `getError`, `finish`/`flush` and object deletion. Framebuffer 0 is the canvas's own drawing buffer,
  and vertex array 0 is a default one, as in WebGL. The extensions offered are `EXT_color_buffer_float`,
  `EXT_color_buffer_half_float`, `OES_texture_float_linear`, `EXT_texture_filter_anisotropic` (when the driver has it)
  and `WEBGL_debug_renderer_info`; every other name answers null, as a browser without it does.
  The context is never lost and `readPixels` always reads RGBA8;
  sampler objects, uniform buffers, transform feedback, queries, sync objects and compressed textures aren't implemented yet.
- **Web Audio:** `AudioContext` and `OfflineAudioContext` render a node graph natively, in 128-frame quanta, on the
  audio device's thread (`AudioUnit` on macOS, ALSA on Linux, and a silent clock when there is no device) or into the
  offline context's buffer. The graph has `GainNode`, `OscillatorNode` (sine, square, sawtooth, triangle),
  `AudioBufferSourceNode` (`start`/`stop` with `when`, `offset` and `duration`, `loop`/`loopStart`/`loopEnd`,
  `playbackRate`/`detune`, `onended`), `BiquadFilterNode` (all eight types, `getFrequencyResponse`),
  `StereoPannerNode`, `ConstantSourceNode`, `AnalyserNode` (time and frequency data as bytes or floats, with the
  smoothing and window the specification describes), `DelayNode`, `DynamicsCompressorNode`, `ConvolverNode` and `PannerNode` with the
  context's `AudioListener` (position, forward and up vectors, distance models, cone gain and panning from the angle
  between them; `HRTF` asks for the equal-power mix). `AudioParam` runs the automation timeline in the engine:
  `setValueAtTime`, `linearRampToValueAtTime`, `exponentialRampToValueAtTime`, `setTargetAtTime`,
  `cancelScheduledValues` and `cancelAndHoldAtTime`. `decodeAudioData` reads WAV, MP3 and Ogg Vorbis, and on macOS
  also what AudioToolbox reads, including AAC and M4A, resampling to the context's rate; `createBuffer` makes empty
  buffers a script fills. `resume`, `suspend` and `close` move the context's state, and `currentTime` counts the
  frames actually rendered, so a suspended context's clock stops. `AudioWorklet`
  is not implemented yet.
- **Inline SVG:** an `<svg>` in the document is a replaced box whose picture is drawn from its own subtree
  through the host's CoreGraphics paths, rasterized at the device scale, so it stays sharp and is sampled in a snapshot like any other paint. It draws `<rect>` (with `rx`/`ry`),
  `<circle>`, `<ellipse>`, `<line>`, `<polyline>`, `<polygon>` and `<path>` (the whole path grammar: absolute and relative commands,
  `H`/`V`, the cubic and quadratic curves with their smooth continuations, and arcs), nested in `<g>` groups,
  each carrying a `transform` (`translate`, `scale`, `rotate`, `skewX`, `skewY`, `matrix`; a `transform` list applies left to right).
  The root's `viewBox` scales user units into the view port, with `preserveAspectRatio` (`meet` by default, `slice` and `none`,
  and the `xMin`/`xMid`/`xMax`×`yMin`/`yMid`/`yMax` alignments). A nested `<svg>` opens a viewport of its own — its `x`, `y`,
  `width` and `height`, with its `viewBox` fitted inside — and its children's percentages and `view-box` measure that viewport.
  `fill`, `stroke`, `fill-opacity`, `stroke-opacity`,
  `stroke-width`, `stroke-linecap`, `stroke-linejoin`, `stroke-dasharray`, `stroke-dashoffset`, `fill-rule` and `opacity` are ordinary inherited CSS properties,
  so a rule, a `style=""` attribute and a presentation attribute all reach them through one cascade, in that order of precedence,
  and `currentColor` follows the element's `color`. A presentation attribute is read again whenever a script changes it, so
  `arc.setAttribute("stroke-dasharray", "280 302")` and `arc.removeAttribute("fill")` restyle the shape like a browser's do, and a changed
  geometry attribute (`cx`, `r`, `d`, `points`, `x`/`y`, `width`/`height`) redraws it. An `<svg>` a script
  builds with `document.createElementNS("http://www.w3.org/2000/svg", "svg")` paints the same way: its box and
  picture come from the subtree it has at paint time, so a child appended later, a changed `viewBox` and a
  changed presentation attribute all show on the next paint. A `fill` or `stroke` of `url(#id)` names a paint server: a `<linearGradient>` or
  `<radialGradient>` or a `<pattern>` in the same `<svg>`, read from its own attributes and (for a gradient) its `<stop>` children
  (`offset`, `stop-color`, `stop-opacity`, also in `style=""`), with `gradientUnits` (`objectBoundingBox` by default, `userSpaceOnUse`),
  `gradientTransform`, and the attributes or stops an `href` inherits. A pattern tiles its own content across the shape, clipped to each
  tile: `patternUnits`, `patternContentUnits`, `x`/`y`/`width`/`height`, `patternTransform`, `viewBox` and `preserveAspectRatio` are read,
  and its content may itself use gradients. A transform attribute is SVG's own grammar — bare numbers, so a CSS unit or percentage makes it
  invalid and leaves the element untransformed — and the CSS `transform`, `translate`, `rotate` and `scale` properties draw an SVG element
  too, the property replacing the attribute, turned about the `transform-origin` attribute or property (0 0 by default). `transform-box` picks the reference box the transform's percentages and its origin measure: `view-box` (the initial value, the viewport the element's user space is measured in) or `fill-box`/`stroke-box` (its object bounds, or those grown by its stroke; `content-box` and `border-box` are the fill and stroke boxes for an SVG element). Geometry attributes take lengths in user units or percentages of the view port,
  and the element's own size comes from its `width` and `height` attributes (300 by 150 without them, a length or a percentage of the window)
  and its ratio from the `viewBox`, CSS sizing and `aspect-ratio` included. `<defs>`, `title`, `desc` and `metadata` are not drawn where they
  are written, and neither is the subtree of an `svg` with `display: none`. A `<use>` (its `href` or `xlink:href`) draws a copy of what it
  names, at its `x` and `y`: a shape, a group, or an `<svg>` or `<symbol>`, which it sizes with its own `width` and `height` and fits through
  the symbol's `viewBox` and `preserveAspectRatio`. What the `<use>` declares (its `fill`, `stroke`, `color`, …) is inherited by the copy, so
  one definition can be drawn in a dozen colours, while what the referenced element declares itself still wins; a reference chain stops
  where it would loop. A `clip-path` of `url(#id)` names a `<clipPath>` in the same `<svg>`: the element is drawn only where the clip path's
  own shapes (and groups) cover it, with `clipPathUnits` (`userSpaceOnUse` by default, `objectBoundingBox` for the element's own bounds) and
  the path's `clip-rule` (`nonzero` or `evenodd`) honoured, the clip resolved in the element's own user space so it moves with its
  `transform`, and nested clips intersecting. A basic shape on an SVG element (`inset()`, `circle()`, `ellipse()`, `polygon()` or
  `path()`, with `evenodd`) resolves against the box it names: `fill-box`, `padding-box`, `content-box` and `margin-box` are the
  object's own bounds, `border-box` and `stroke-box` those grown by half its stroke, and `view-box` the viewport. A `<text>` is drawn with the host's line layout along its baseline: `x` and `y` place the
  baseline's start, `dx`/`dy` shift it, whitespace collapses as a browser collapses it, and `<tspan>` and `<a>` inside take their own
  `x`/`y`/`dx`/`dy`, `font-family`, `font-size`, `font-weight`, `font-style`, `fill`, `stroke` and the rest of the paint properties,
  so one text can mix sizes and colours. `text-anchor` (`start`, `middle`, `end`) moves a run of text to its anchor point. The glyphs
  follow the element's `transform` and are clipped by its `clip-path` like a shape.
- **SVG images:** a local `.svg` file named by an `<img src>` or a CSS `url()` (in a stylesheet or a `style=""` attribute) is compiled at build
  time into a draw program — the same geometry and paint the inline `<svg>` painter draws, so the shapes, groups, transforms, the path grammar,
  `viewBox` with `preserveAspectRatio`, `fill`/`stroke`/their opacities/`stroke-width`/`stroke-linecap`/`stroke-linejoin`/`stroke-dasharray`/`stroke-dashoffset`/`fill-rule`/`opacity`
  the gradients those paints name (`url(#id)`), `<use>`/`<symbol>` references, `clip-path`/`<clipPath>` clipping and `<text>` with its
  `<tspan>`s and `text-anchor`, all work in a file too.
  It draws that program into a bitmap of its own at the size it is drawn at and at the device scale, so an image stays
  sharp at any used size; `object-fit`/`object-position`, `background-size`/`background-repeat`/`background-position`, `border-radius` clipping
  and `image-rendering` behave as they do for a raster image. The intrinsic size is the file's `width` and `height` attributes when both are
  absolute lengths, and the one of them plus the other from the `viewBox`'s ratio when there is one; a percentage (or missing) attribute
  gives no dimension of its own, since it resolves against the box the image is drawn in. A file with only a `viewBox` has a ratio and no
  size of its own: an auto width fills the space the image is given (its containing block's width, or the cross size of a flex item) and
  the ratio gives it a height, so a logo drawn that way scales to the box it sits in, and a background-image with an auto size fits that
  ratio into its positioning area. A picture without a `viewBox` scales with the box it is drawn into: its attributes describe its own
  viewport, so a `width="8px"` rectangle in an 8 by 32 file is 192 wide in a 192 by 768 box. A background image far larger than its box
  (the cover fit of a picture whose ratio is extreme) is drawn only where it shows, at the box's resolution, and a `viewBox` with a zero
  width or height draws nothing, as SVG says. An image is its own document: `currentColor` and
  inherited properties take the file's root values (the initial colour, black), not the page's.
- **JSX:** an app's `.tsx` and `.jsx` sources build like its `.ts` ones, whether the page's `<script src>` names one or another of the app's files imports it. The app's `tsconfig.json` picks the JSX mode: the automatic runtime (`react-jsx`, its `jsxImportSource` naming the package) or the classic one (`react`, with `jsxFactory` and `jsxFragmentFactory`).
  The runtime's package is compiled with the app from the app's own `node_modules`, so the imports the transform writes into each file and the app's own imports reach one copy of it, and a dev build uses the package's `jsx-dev-runtime` when it ships one.
- **Events:** `click`, `mousedown`, `mouseup`, `mousemove`, `mouseover`, `mouseout`, `mouseenter`, `mouseleave`,
  `pointerdown`, `pointerup`, `pointermove`, `pointerover`, `pointerout`, `pointerenter`, `pointerleave`,
  `keydown`, `keyup`, `input`, `change`, `focus`, `blur`, `scroll`;
  they bubble to `document`, and support `stopPropagation`/`stopImmediatePropagation`/`preventDefault` (which only cancels a `cancelable` event). A listener is a function,
  or an object with `handleEvent`, added with `capture`, `once` and `passive` honoured; it sees the event's `target`,
  `currentTarget`, `eventPhase` and `composedPath()`, and `isTrusted` is true for an event the host's input produced. Each event has the class a browser gives it,
  with that class's own members: `MouseEvent` (`clientX`/`clientY`, `button`, `buttons`, …), `KeyboardEvent` (`key`/`code`, `repeat` and the modifier flags),
  `FocusEvent` (`relatedTarget`), `InputEvent`, `CustomEvent` (`detail`), `UIEvent`, `PointerEvent`, `WheelEvent`,
  `SubmitEvent`, `ToggleEvent`, `AnimationEvent` and `TransitionEvent`. Keyboard events carry `key` and `code` (`" "`/`"Space"`,
  `"a"`/`"KeyA"`, `"ArrowLeft"`, …), and after bubbling through the document they reach `window` listeners too. A press
  sends `keydown`, a held key's repeats send more `keydown`s with `repeat` true, and the release sends `keyup` with the
  same `key` and `code`. `addEventListener` on the window, the document and an element types its listener from the event
  name through the element, document and window event maps, as the DOM lib does, so `(event: KeyboardEvent)` is a
  `keydown` listener.
  A mouse event measures `offsetX`/`offsetY` from its target's box, and a pointer event's `getCoalescedEvents()` is itself,
  as the host never holds a move back. A pointer that crosses an element edge sends `pointerout` for the element it left and
  `pointerover` for the one it entered, `pointerleave`/`pointerenter` for the elements it leaves and enters, and then the
  mouse events' `mouseout`/`mouseover` and `mouseleave`/`mouseenter` pair, each with `relatedTarget` naming the other side;
  `over` and `out` bubble, `enter` and `leave` go to each element alone, as the web has it.
  `setPointerCapture()` makes an element the target of a pressed pointer's moves
  wherever it goes — what a drag that leaves its element needs — until the button lifts or `releasePointerCapture()` gives it up;
  the element hears `gotpointercapture` and `lostpointercapture`, and `hasPointerCapture()` says where the capture is.
  The touch events (`TouchEvent` with its `Touch` list) are declared as a desktop browser declares them for a
  machine with no touch screen, so a listener for them is never called; composition events are real (see
  Composition below), HTML5 drag and drop and the clipboard are real, and the bullets below say what they fire.
  Inline handler attributes (`onclick="…"`, `oninput="…"`, `<body onload="…">`) are compiled into listeners as the page builds, with `this` and `event` as HTML gives them,
  a handler that returns `false` cancelling the event; the element's `on…` property reports the compiled handler, and setting it to `null` detaches it
- **Blob:** `new Blob(parts, { type })` copies strings (as UTF-8), buffers and other blobs into an immutable run of bytes whose type is lowercased, and `size`, `type`, `arrayBuffer()`, `bytes()`, `text()`, `slice(start, end, type)` and `stream()` read it. A `Response.blob()`, a `Request` body, a `ClipboardItem` and a value an IndexedDB store keeps are all this Blob.
- **Clipboard:** `navigator.clipboard` with `readText`/`writeText` and `read`/`write` over `ClipboardItem`s of
  `text/plain` and `text/html` (a value may be text or a `Blob`), with no permission request and no user gesture: a
  native app is the user's own program. Cmd+C, Cmd+X and Cmd+V fire `copy`, `cut` and `paste` with a `DataTransfer` in
  `clipboardData` — the selection, or a focused field's own selected text — and a handler may read it, replace it, or
  take the event with `preventDefault()`. A cut clears the field's selection, and a paste puts the clipboard's text and
  markup in the payload and then inserts its text at a field's caret unless the handler took the event (an input takes
  it on one line, a textarea keeps its newlines). `document.execCommand("copy" | "cut" | "paste" | "selectAll" | "insertText")`
  runs those commands, and `queryCommandSupported()` answers for them. In a contenteditable host
  it also runs `bold`, `italic`, `underline`, `formatBlock`, `createLink`, `removeFormat`, `undo`
  and `redo`; `queryCommandState()` reports whether the caret is bold, italic, underlined, in a
  link or in a list, and `queryCommandEnabled()` answers for a command. `undo` and `redo` walk
  snapshots of the host's markup taken before each editing command and keystroke, not a browser's
  own undo stack. The clipboard is the system's: the macOS host
  reads and writes NSPasteboard, and the headless Linux host keeps it in files, `NATIVE_PASTEBOARD` naming the text one.
- **IndexedDB:** `indexedDB.open(name, version)`, `deleteDatabase(name)` and `databases()`, with `upgradeneeded` (and `blocked`) when a version is newer, `versionchange` on the open connections, and error/success requests. A database holds object stores with an inline or out-of-line key path and an optional key generator; `add`, `put`, `get`, `getKey`, `getAll`, `getAllKeys`, `count`, `delete` and `clear` run in a transaction (`readonly`, `readwrite`, or the upgrade's `versionchange`), which reports `complete`, `abort` or `error` and rolls its writes back when it aborts. `IDBKeyRange` bounds the multi-record reads, and keys of every kind — numbers, dates, strings, buffers and arrays — compare in the standard's order. Values are structured-cloned, dates, buffers and Blobs included. Each database is a SQLite file in the app's own data directory, beside its localStorage file. Indexes (`createIndex`, `index`, `deleteIndex`, `indexNames`) read a store's records by a second key in index-key order, and a cursor (`openCursor`, `openKeyCursor`) over a store or an index walks them in `next`, `nextunique`, `prev` or `prevunique` order through `continue()`, `continue(key)`, `advance()` and, on a value cursor, `update()` and `delete()`.
- **Drag and drop:** a press that moves on an element that drags — `draggable="true"`, or a link or an image with no
  `draggable` attribute, as HTML's auto value has it — starts one: the source hears `dragstart`, each move sends `drag`
  to the source and `dragenter` then `dragover` to the element under the pointer (with a `dragleave` for the one it
  left), a release over an element whose `dragover` was cancelled fires `drop`, and the source hears `dragend` whatever
  happened. A cancelled `dragstart` starts nothing, and a drag that ends sends no click. The `DataTransfer` it carries
  has `types` (`Files` first when it has files), `items`, `files`, `effectAllowed` and `dropEffect` (the effect the
  modifiers pick until a handler sets one), and a dragstart handler can `setData`; a link or an image drags with its
  `text/uri-list` and `text/plain` by default. Files dragged in from outside the app are the host's — the window takes
  file URLs — and the drop carries them as `File`s that read themselves with `text()` and `arrayBuffer()`.
- **Window:** `requestAnimationFrame`/`cancelAnimationFrame`, run on the app's frame loop with the frame's timestamp;
  `window.innerWidth`, `innerHeight` and `devicePixelRatio`; `matchMedia` over the same media features and syntax as `@media`,
  with `matches`, `addEventListener("change")`, the legacy `addListener`, and a `change` event when the window is resized or a
  system setting (the appearance, contrast, transparency, reduce motion) changes under the running app; window `addEventListener`/`removeEventListener` for `resize`,
  `load` (fired once the page's first layout is done, as a `<body onload>` attribute waits for) and the key events;
  `localStorage` (`length`, `getItem`, `setItem`, `removeItem`, `clear`, `key`), one file per app under `~/Library/Application Support/native/<title>/localStorage.json`,
  created the first time it is used (`NATIVE_STORAGE` points tests at another file, and `NATIVE_REDUCED_MOTION` pins the reduced-motion preference),
  and `sessionStorage` with the same members, which lasts only as long as the app runs;
  the constructors a page reaches through `window` — `ResizeObserver`, `IntersectionObserver`, `MutationObserver` — and
  `window.CSS` / `window.customElements` are the same objects the bare names are.
  `navigator` reports a macOS identity (a Macintosh user agent naming this runtime, platform, language `en-US`,
  no touch points, `cookieEnabled` false as there are no cookies, `onLine`) and `window.navigator` is the same object.
  `navigator.serviceWorker` is the app's update check when its web app manifest names `update_url`: `getRegistration()`,
  `ready`, `registration.update()` and the browser's `updatefound`/`installing`/`waiting` shape (see [updates.md](updates.md)).
  The window's titlebar can be hidden, inset or transparent (`<meta name="native-window" content="titlebar=…">`,
  with `min-width`, `min-height` and `resizable=no`); `env(titlebar-area-x/-y/-width/-height)` and `env(safe-area-inset-top)`
  give the area beside the traffic lights, and `app-region: drag`/`no-drag` (also `-webkit-app-region`) marks what drags the window;
  `env()` of any other name takes its fallback.
- **Workers:** `new Worker(url, { type: "module" })`, where the URL is a source-relative
  `new URL("./worker.ts", import.meta.url)` or a page-relative path to a compiled module, starts a
  native thread with its own module state and event loop. The page and the worker exchange
  structured clones with `postMessage`; the page receives them as a `MessageEvent` on
  `worker.onmessage` or `addEventListener("message")`, the worker as `self.onmessage` or
  `addEventListener("message")` with `self`/`postMessage` bound by the build. `terminate()`,
  `onerror` and `removeEventListener` work, and the worker's `self.close()` ends it. Transfer lists
  are accepted; scriptc cannot move an `ArrayBuffer` between threads yet, so the bytes are copied
  and the sender's buffer stays attached.
- **Windows:** a link's `target` and `window.open(url, name, features)` open another window — another
  run of the app's page at its own route (`#/settings`, `?doc=2`) — and a name that is already open
  is focused and reused, while `_blank` always opens a fresh one. The features a browser takes are
  `width`, `height`, `left` and `top`. `window.open()` returns a `WindowProxy` — `closed`, `name`,
  `close()`, `focus()`, `blur()`, `postMessage()` — and `window.opener` and a message's `source` are
  the same kind of handle; a handle reaches the windows the page opened and the window that opened
  it, and nothing of another window's document. `postMessage` carries JSON data to the window, whose
  `message` listener gets a `MessageEvent` with `data`, `source` and the app's opaque `"null"`
  origin. A window has `name`, `close()`, `closed`, `focus()`, `blur()`, `resizeTo()`, `moveTo()`,
  `screenX`/`screenY`, `outerWidth`/`outerHeight`, and the Fullscreen API's
  `requestFullscreen()`/`exitFullscreen()` with `document.fullscreenElement` and
  `fullscreenchange`. Its lifecycle events are `focus`, `blur`, `resize`, `move`, `beforeunload`
  (cancelable, which keeps it open), `pagehide`, and the document's `visibilitychange` with
  `document.hidden`/`visibilityState` following the window being minimized; the app ends when its
  last window closes.
- **Menus:** a `<menu type="application">` is the window's menu bar and a `<menu type="context">` a
  context menu the `contextmenu` attribute on an element shows, both built natively by the app and
  neither drawn by the page (the UA sheet gives them `display: none`). Their items are
  `<menuitem>`s with HTML's own attributes — `label` (or their text), `accesskey` (the shortcut,
  with the platform's primary modifier plus the `Shift`/`Alt`/`Ctrl` the attribute spells out), and
  `disabled` — with `onclick` running when one is chosen and `command` naming an invoker command:
  `--cut`, `--copy`, `--paste`, `--delete`, `--select-all`, `--undo`, `--redo`, `--close`,
  `--minimize`, `--zoom`, `--toggle-fullscreen`, `--hide`, `--hide-others`, `--show-all` and
  `--quit`. Choosing an item fires a bubbling `CommandEvent` at it with `command` and `source`,
  then the platform runs the command it knows; the editing commands act on the focused field, the
  window commands on the window and the app's on the app. A nested `<menu label="…">` is a submenu
  and an `<hr>` a separator, and an item with only a command reads the command's standard label.
  macOS puts the app's own menu (About, Hide, Hide Others, Show All, Quit) in front of the bar.
- **`fetch()`:** a page-relative URL, a `/` URL (the site root: the public directory when the app has one, else the page's directory, as it is for markup) or a `file:`
  URL names a file in the app's bundle (the page's directory in a dev build), which the host reads; a `data:` URL decodes in place; and an
  `http:` or `https:` URL goes to the network. The promise resolves with a `Response` carrying the status, status text,
  headers, URL, `redirected` and `type`, with `text()`, `json()`, `bytes()`, `arrayBuffer()`, `blob()` and `formData()` reading its body
  once and `clone()` copying it beforehand. `body` is a `ReadableStream`: a network response streams the bytes as the server
  sends them, and a file is handed over in 64 KiB chunks, so a loader that reads it reports progress. `Request`,
  `Response` and `Headers` take the bodies and options a browser's do — a string, `ArrayBuffer` or typed array, `Blob`,
  `FormData`, `URLSearchParams` or `ReadableStream`; `method`, `headers`, `body`, `signal`, `redirect` and the rest;
  `Headers` lowercases names, combines repeated ones and keeps `getSetCookie()` — and `new Response(...)`,
  `Response.json()`, `Response.redirect()` and `Response.error()` build responses here. A redirect follows by default
  (`redirect: "follow"`), `"manual"` gives an opaque-redirect response and `"error"` rejects, as Chrome does. A request's
  `AbortSignal` aborts the transfer and rejects with an `AbortError`. `ProgressEvent` reports the progress a loader counts.
  A request's `integrity` is enforced as Subresource Integrity specifies: the body is read and checked
  against its `sha256`/`sha384`/`sha512` digests, a mismatch rejects with `TypeError: Failed to fetch`,
  a request that redirects rejects too (the digest names the URL it was made for), and a `no-cors`
  request with an integrity list throws at construction. After a successful check the body is still
  readable by the page.
  The network client is the native runtime's, with TLS through the platform's certificate store.
  The app is a desktop program with no origin, so CORS isn't enforced (no `Origin` header is sent) and cookies are not
  stored or sent: `credentials` is accepted and ignored, and a `Set-Cookie` header is readable on the response. A URL that
  names nothing readable, and a network failure, reject with a `TypeError` (`Failed to fetch`). `mode: "no-cors"` and
  `mode: "same-origin"` are accepted but not enforced, and an `Authorization` header is sent as given.
- **`XMLHttpRequest`:** asynchronous requests over the same transport and URLs as `fetch()`, with `open`, `send`,
  `setRequestHeader`, `abort`, `timeout`, `responseType` (`""`, `"text"`, `"json"`, `"arraybuffer"` and `"blob"`),
  `responseText`, `response`, `responseURL`, `getResponseHeader`, `getAllResponseHeaders`, `overrideMimeType` and the
  `readystatechange`, `loadstart`, `progress`, `load`, `error`, `abort`, `timeout` and `loadend` events. A synchronous
  request (`open(..., false)`) throws `InvalidAccessError`, since there is no worker to block, and progress arrives as one
  update with the response's size rather than piece by piece.
- **`EventSource`:** server-sent events over `fetch()`, with `onopen`, `onmessage`, named events, `lastEventId`, the
  server's `retry` interval, automatic reconnection and `close()`. A message is a `MessageEvent` carrying `data`,
  `origin` and `lastEventId`. A network failure, and a stream that ends, reconnect after the retry interval; a
  response whose status isn't 200 (204 included) or whose content type isn't `text/event-stream` fails the source,
  which reports `error` and stays CLOSED without reconnecting.
- **`WebSocket`:** the client side of RFC 6455 over the same transport as `fetch()`: a `ws:` URL is a request over
  `http:`, a `wss:` one over `https:` with the platform's TLS and certificate store. The handshake checks the server's
  `Sec-WebSocket-Accept` and takes a subprotocol the page named. Text and binary messages arrive whole, however the
  sender split them into fragments, with `binaryType` choosing a `Blob` or an `ArrayBuffer` for a binary one, and
  `send()` takes a string, `Blob`, `ArrayBuffer` or typed array, its bytes counting in `bufferedAmount` until they are
  written. The client answers a ping with a pong. `close(code, reason)` checks the code (1000, or 3000 to 4999) and
  the 123-byte limit on the reason, and the close event carries the code, the reason and `wasClean`; a handshake that
  doesn't switch protocols, a masked server frame, invalid UTF-8 or another protocol error fires `error` and then a
  `close` with 1006. The `onopen`/`onmessage`/`onerror`/`onclose` properties and `addEventListener` work as in a
  browser. Extensions such as `permessage-deflate` are not negotiated.
- **Accessibility:** the page is published to the platform's assistive technology as a tree of the
  elements a screen reader stops at, with each node's role, accessible name, value, frame and states.
  The role is the one HTML-AAM gives the element — from its tag or its `role` attribute — and the name
  is the one accname 1.2 computes: `aria-labelledby`, `aria-label`, a native label, then the content for
  the roles a browser names from it, then `title`, and a text field's `placeholder` last. Headings,
  buttons, links, text fields, checkboxes and radios, ranges, selects, lists, tables, dialogs, images and
  landmarks are the roles it starts with, and an element the page listens for clicks on is a node a
  client can press, as a browser exposes it; `aria-hidden`, `hidden` and `display: none` keep a subtree
  out. A checkbox reports its checkedness (and `indeterminate` as mixed), not its `checked` attribute.
  macOS exposes the tree through NSAccessibility under an `AXWebArea`, with the roles and subroles
  Core-AAM gives macOS, `AXDOMIdentifier`, `AXURL`, `AXPlaceholderValue`, `AXHelp` (the description)
  and the expanded, selected and required states, frames in screen coordinates, hit testing and the
  focused element. VoiceOver reads it, and a client such as agent-desktop finds, reads and acts on it as
  it does a browser's page: `AXPress` runs the element's click, `AXFocused` focuses it, `AXValue` on a
  text field replaces its value (`input`, then `change`), `AXSelectedText` inserts at the selection as
  typing does (`beforeinput` and `input`), `AXIncrement` and `AXDecrement` step a range or number, and
  `AXShowMenu` sends `contextmenu`. Each action runs on the element itself, so a control scrolled out of
  view or under another box is reached all the same. The tree costs nothing until a client asks for
  it: on macOS the first query of the window's content, or a client setting `AXManualAccessibility` or
  `AXEnhancedUserInterface` on the application, switches it on, and from the next frame it is built and
  kept current. Windows publishes the same tree through UI Automation under a Document node, with
  Core-AAM's control types and the Invoke, Toggle, Value, RangeValue, ExpandCollapse, SelectionItem,
  ScrollItem and Text patterns on the nodes that take them. A node's AutomationId is its element's
  `id`, its ARIA role and properties are reported as a browser reports them, a heading carries its
  level, a landmark which landmark it is, and a link's address is its value. Each pattern runs its
  action on the element itself, as the macOS attributes do: Invoke presses, Toggle and SelectionItem
  click, Value and RangeValue write the value, ExpandCollapse opens or closes a select's picker,
  SetFocus focuses, ScrollIntoView scrolls the element into view, and the Text pattern gives a field's
  text, caret and selection. A Windows tree also costs nothing until a client asks: the first request
  for the window's UIA root, whether a walk, a hit test or a focus query, switches it on, and a
  client's first walk waits briefly for the tree that frame builds rather than finding an empty
  window. Linux publishes the same tree on the AT-SPI accessibility bus, where screen readers and
  tools such as Accerciser walk it: a Document (role `document web`) under the application, with
  Core-AAM's ATK roles and states and the `id`, `xml-roles`, `placeholder-text`, `level` and
  `roledescription` attributes a client reads. A node's object path is its element's uid, so a
  reference a client holds outlives a changed tree. The Action interface carries click, increment,
  decrement and showMenu, EditableText writes a field (SetTextContents, InsertText, DeleteText),
  Component focuses an element and scrolls it into view, Value sets a range's position, Text moves
  the caret and sets the selection, Selection chooses among a container's children, and a link is a
  Hyperlink with its address; each call runs the action on the element itself, as on the other
  platforms. A Linux tree costs nothing until a client asks too: the application joins the bus with
  no page under it, the first walk of it starts the build, and the page arrives as children-changed.
  A focus change, a field's value or a checkbox's state, a select opening or closing, and a changed
  live region (`aria-live`, `role="status"` or `role="alert"`) are notified. `NATIVE_AX_DUMP=1` builds and prints
  the tree a run publishes, as the platform's accessibility API sees it.
- **Bundling:** a built app carries its own files. The images a page or its sheets name (an `<img src>`, a `srcset`
  candidate, a CSS `url()` in a background, border image, mask or cursor, an inline `style=""` URL, a `data:` image),
  the files `@font-face` names, the sheets it links and imports, the files its scripts name with a literal
  `fetch("…")` or import as a non-code file, and the `.svg` images it draws are copied into the app's bundle: the
  `.app`'s Resources on macOS, a `<executable>.resources` directory beside the executable elsewhere. Each keeps the
  place it had in the app, so a page-relative URL still names it; two files with the same name in different
  directories stay apart, a query or fragment in a URL is not part of the file's name, and a `data:` image gets a
  file of its own. A `public` directory beside the page is the site root, as it is in the web's build tools: every
  file in it is copied to the bundle's root as it is, so a URL a script builds at run time (`cover.src =
  "/covers/" + name`) names one. A dev build keeps the source paths and copies nothing; its `/` URLs resolve
  against `public/`. `srcset` selection isn't implemented yet,
  so every candidate is collected and the build draws the source it already chose; `image-set()` isn't read yet.
- **Page lifecycle and timers:** `document.readyState` goes `"loading"` → `"interactive"` for `DOMContentLoaded` → `"complete"`
  for `load`; `DOMContentLoaded` fires at the document, and `load` at the window once the page's scripts have run and its first
  layout is done. `setTimeout`/`clearTimeout` and `setInterval`/`clearInterval` return numeric ids and run on the app's frame
  loop, and `self` names the window. Each page of an app starts with an empty event loop and window, as a browser's page does.
  A promise rejection nothing handled is reported as a console error and an `unhandledrejection` event at the
  window, with the page left running, as a browser does.

## Not yet supported

cutting text outside a field (a page that isn't editable keeps its text, as a browser's does, and the
clipboard fills anyway), dragging a selection of text itself (a press on selected text starts a new
selection), dragging an element out of the app to the desktop, a drag image, an X11 or
Wayland selection on the Linux host (it has no window of its own, so its clipboard is a file), more
than one `ClipboardItem` in a `write()` (a pasteboard holds one), and a copied selection's
`text/html` (a copy puts the text it was given on the pasteboard; a handler adds markup),

In the app shell: the editing history behind `--undo` and `--redo` (their event fires, but the
runtime keeps none to walk); rebuilding the menu bar when the markup changes after the page loads;
a window reaching beyond the ones it opened and its opener (there is no shared heap, and
`postMessage` carries JSON rather than a structured clone of every kind of object); another
window's document.
drawn `<progress>` and `<meter>` widgets and the picker a colour field opens (a click on one does nothing), generated content beyond string literals and `attr()` (the counters and quote keywords in `content`,
`quotes`, `open-quote` and `close-quote`, and `::first-letter`/`::first-line`), IME and multi-line text input,
and any other image a declaration names that isn't a local raster or SVG file (a `data:` URL
or a remote URL), drawing an image's `alt` text when it can't be loaded,
`toDataURL`, `createPattern`, and canvas shadows, `drop-shadow()` filters and
`isPointInPath`, a `<style>` element inside an SVG file (its presentation attributes and `style=""` attributes apply;
a stylesheet in the file doesn't),
and in an `<svg>`, inline or an image: patterns, masking, filters, markers, `textPath` and glyph positioning (`textLength`,
`letter-spacing`), and the reference elements besides `<use>` and `<clipPath>`,
a gradient's `spreadMethod` other than the default `pad` and a focal circle outside its end circle, an element's or a group's
`opacity` composited as one layer (it multiplies into each drawing below it instead, so a translucent box's background
and its children fade one by one rather than as a group), `list-style-image`, a counter style's `speak-as` descriptor and the
`additive-symbols`/`symbols` forms of the scripts beyond the predefined sets above, background clipping to text (`background-clip: text`), remote `@font-face` fonts (a family that isn't available falls back to the system font;
`@font-face` files are copied into the app's bundle), `local()` in an `@font-face` `src`,
and its children fade one by one rather than as a group), `list-style-image`, `counter-reset`/`counter-increment` and the `reversed` attribute of `<ol>`,
background clipping to text (`background-clip: text`), remote `@font-face` fonts (a family that isn't available falls back to the system font;
`@font-face` files are copied into the app's bundle),
`palette-mix()` for `font-palette`, and the light/dark choice `font-palette: normal` would make under a
non-normal `color-scheme` (`normal` always uses the font's palette 0),
per-glyph fallback down a `font-family` list for a character the first family's face merely lacks (a `unicode-range` splits the
list by its ranges, but a missing glyph otherwise falls to CoreText's own cascade inside the first font, so a later family's
design isn't chosen for it),
`text-box-trim` and `text-box-edge` (the trim is the leading above the first line's over edge and below the last line's under edge,
and the box shrinks by both; the case of a block whose content is its own text is measured out and checked, while inline boxes and
trims that accumulate through nested blocks are not),
`text-decoration-thickness: from-font` measuring the font's own thickness (it uses the same thickness as `auto`),
the `blink`, `spelling-error` and `grammar-error` values of `text-decoration-line`, `text-decoration-skip-ink`
and `text-underline-position`,
combinators inside `:is()`, `:where()` or `:not()` (their arguments are compounds), an `:is()`/`:where()` argument whose own
ancestor chain has to interleave with the one the selector was already building, `:not()` nested inside another `:not()`,
namespaced selectors (`ns|tag`, `[ns|attr]`; an `@namespace` rule is read, but its prefixes don't match),
the `of S` argument of `:nth-child()`,
the form states beyond what a control's own attributes and value say (`:indeterminate` covers a checkbox, not an unchecked radio group or a `<progress>`;
`:in-range`/`:out-of-range` compare a `number` or `range` field's value with its `min`/`max`, and no other type has a range here;
`:invalid` reports a missing `required` value, a failed number range and a custom message, so `pattern`, `step` and a type mismatch don't make a field invalid),
`@page` (its `size`, `margin` and page-orientation descriptors are parsed but print output has no pagination yet; the media type is `screen` unless the app runs with NATIVE_MEDIA=print, which makes `@media print` and `matchMedia("print")` match and `screen` not), laying a page out for print, `break-inside` (every CSS Fragmentation keyword, with the `all` alias), `orphans`, `widows` and `print-color-adjust`, which parse and inherit as the spec says but take no effect of their own (a `break-before` or `break-after` on a column child picks where the columns break, and boxes split across columns at their own children's boundaries, but `break-inside` doesn't hold a box together there, as the multi-column entry above says), rubber-band overscroll, transitions, `perspective` (a `w` that varies across the element's plane can't be drawn,
so the divide is dropped), `transform-box`, `backface-visibility`, `transform-style: preserve-3d`, what a transformed descendant adds to a scroll container's scrollable overflow area,
a windowed host on Linux, a cookie jar and CORS enforcement in `fetch()` (an app is a privileged client with no origin, and its cookies are not stored), synchronous `XMLHttpRequest`, and WebSocket extensions. Caret movement counts UTF-16 code units, so it can land inside an emoji. Only ASCII spaces and tabs collapse: an ideographic space (U+3000) is preserved,
gives a break opportunity and hangs at the end of a line (with `break-spaces` it wraps to the next line instead),
while other Unicode spaces are drawn as ordinary characters.
A handler attribute a script adds at runtime (through `setAttribute()` or `innerHTML`) is inert,
since only the build compiles handler code, and a handler's code reaches the DOM and the window's
globals but not the names a page script declares at its top level (a script is a module), and
`customElements.define()`, `get()`, `whenDefined()` and `upgrade()` define a class per tag: an
element of a defined tag is an instance of its class, whether the markup was compiled,
parsed or made with `createElement`, and the elements of that tag already in the tree are upgraded
when the name is defined, each reporting its existing attributes to `attributeChangedCallback`
before `connectedCallback`. Elements inserted later become instances of their class as they are
inserted, and `connectedCallback`/`disconnectedCallback` run as the element enters and leaves the
document. A class's `observedAttributes` can't be read through its class value yet (scriptc issue
#20), so `attributeChangedCallback` is called for every attribute change instead of only the listed
ones, and a change made through `el.style` isn't reported;
an upgrade replaces the element with a new one of its class,
so a reference a script kept to the element before the upgrade is stale,
and `upgrade()` leaves a detached root itself to be upgraded when it is inserted while upgrading its
children; `extends:` customized built-ins aren't supported;
a bad name or a second definition throws an `Error` whose message names the failure (`SyntaxError`,
`NotSupportedError`) rather than a `DOMException`.
Every tag also makes an element of its own class (`HTMLButtonElement`, `HTMLLabelElement`,
…) and those classes carry the members a script reads: a control's `form`, `name`, `value`,
`disabled`, `required`, `labels`, `setCustomValidity()` and `validity`/`validationMessage` (the
constraints checked are `required`, a script's custom error and a date or time field's `min`/`max`/`step`;
`pattern`, `minlength` and other types' `min`/`max`/`step` aren't checked yet, and the message is English),
a checkbox's `checked` and `indeterminate`, a range or number field's `valueAsNumber`
(sanitized into the field's `min`/`max`, and to a whole number of its `step`s, which is also where a
range with no value sits: the middle of its range), and a date or time field's `value`, `valueAsDate`
(not for `datetime-local`), `valueAsNumber` and `stepUp()`/`stepDown()`, with `value` kept in its state's
canonical syntax (`2024-05-03`, `2019-W50`, `13:45`, and so on) and no value at all when it isn't valid,
a label's `control` and `htmlFor` (a click on the label forwards to the control it names,
which takes its own default action), a select's `options`, `selectedIndex` and `value`,
a textarea's `value`, `defaultValue` and selection range,
an image's `naturalWidth`/`naturalHeight` (0 until the load lands,
since the host decodes it and reports back a turn later) and `complete` (no source,
or the load has finished or failed), an image's `decode()` (a promise that resolves once its pixels
are ready to paint, and rejects with an `EncodingError` when they can't be made) and `decoding`
(kept as the attribute says; the host decodes off the thread that paints either way),
a form's `elements`, `checkValidity()` and `reset()`,
and an option's `value`, `text` and `selected`; a form submits as HTML says: a click on a submit
button starts its form's submission, and so does Enter in a single-line text field — through the
form's default button when it has one, else by the form itself when that field is its only one —
which checks the controls first unless the form is `novalidate`,
then fires a cancelable `submit` `SubmitEvent` whose `submitter` is the button that started it (null
for `submit()`, and for a form submitting itself); a reset button resets the form;
`requestSubmit()` takes the same path and refuses a control that isn't a submit button of the form,
while `submit()` fires the event without checking, and a submit nobody cancels does nothing more,
since there is nowhere to navigate to; `new FormData(form)` collects what that submit would send,
in document order — every named control of the form that isn't disabled and isn't a button, a
checked box or radio (whose value is `on` when its value attribute is absent), a file field's
files, a select's chosen options, a field's text — and an empty `FormData` takes `append`, `set`
(which replaces the first entry under the name and drops the rest), `delete`, `get`, `getAll`,
`has`, `keys`, `values`, `forEach` and `entries`, each list an array here where a browser gives an
iterator, a file input never opens a picker (so `files` is empty unless
a script sets it), a `<video>` on a build with no video backend (Linux without FFmpeg), an `<iframe>` has no content document;
an element's `attachShadow()` makes a shadow tree that layout, paint, hit testing and the DOM
queries reach through its flattened children, each `<slot>` filled by the light children assigned
to it (or its own fallback), with `slot`, `assignedSlot`, `assignedNodes()`, `assignedElements()`
and a `slotchange` when the assignment changes, and the root's `host` and `mode`;
a shadow tree's own `<style>` styles that tree and nothing else, `:host`/`:host(sel)` styles its
host and `::slotted(sel)` the nodes a slot took; an event from inside the tree is retargeted for
listeners outside it (they see the host as the target) and `composedPath()` hides the nodes a
listener can't see through, while a non-composed event stays inside the tree;
declarative shadow DOM (`<template shadowrootmode>`), `::part()`, `::theme()` and
`adoptedStyleSheets` on a shadow root are not supported;
`document.getSelection()` answers an empty, collapsed `Selection` that doesn't follow the caret in an input and can't be changed;
and `window.visualViewport` reports the layout viewport and never fires its events.
Conformance against web-platform-tests is tracked in [wpt.md](wpt.md).