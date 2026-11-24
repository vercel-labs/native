// The user-agent stylesheet, compiled into every app at the lowest priority.
// Close to browser defaults so ordinary HTML looks familiar, minus the parts native lacks.
// The root has no background of its own, as in a browser: the canvas is white by default, and
// a background on <body> propagates to it (see canvasColor in paint.ts).
export const UA_CSS = `
/* CSS's initial display is inline, and a browser keeps it for an element its sheet doesn't
   know — a custom element before definition, or a made-up tag in a test. Every element the
   sheet gives a display to below overrides this by specificity. */
* { display: inline; }
html { display: block; color: #000; font-weight: 400; line-height: normal; }
body { display: block; margin: 8px; }
/* The dir attribute names the direction its element's text runs in, and it inherits from there.
   dir="auto" isn't taken: it needs the first strong character of the text to decide. */
[dir="rtl"] { direction: rtl; }
[dir="ltr"] { direction: ltr; }
head, style, script, link, meta, title, template, noscript, base, basefont, bgsound, area,
datalist, noembed, noframes, param, rp, frame { display: none; }
/* The hidden attribute hides an element whose sheet doesn't say otherwise, as HTML's rendering
   section has it; a table's internal parts keep the display that lays them out, and collapse
   their row or column instead. */
/* The rules that keep a display on a hidden element come before the general rule below, because
   the runtime takes the first matching conditional rule for a declaration. */
colgroup[hidden=""] { display: table-column-group; visibility: collapse; }
col[hidden=""] { display: table-column; visibility: collapse; }
thead[hidden=""] { display: table-header-group; visibility: collapse; }
tbody[hidden=""] { display: table-row-group; visibility: collapse; }
tfoot[hidden=""] { display: table-footer-group; visibility: collapse; }
tr[hidden=""] { display: table-row; visibility: collapse; }
table[hidden=""], caption[hidden=""], td[hidden=""], th[hidden=""] { display: none; }
/* A hidden embed still lays out as a zero-sized inline box, as the sheet's hidden-elements
   section says. */
embed[hidden=""] { display: inline; width: 0px; height: 0px; }
[hidden=""] { display: none; }
/* A slot's content goes where the slot is; a math element has no CSS layout of its own. */
slot { display: contents; }
math { display: inline; }
/* A popover draws only while it is open, from the top layer (see runtime/paint.ts), in Chrome's
   place for it: fixed to the viewport, as big as its content wants, and centred in the viewport
   by its auto margins. An author display overrides this rule, as in a browser. */
[popover]:not(:popover-open) { display: none; }
[popover] { position: fixed; inset: 0; width: fit-content; height: fit-content; margin: auto;
  overflow: auto; border: solid; padding: 0.25em; background-color: #ffffff; color: #000000; }
/* A dialog draws only while it is open; showModal() puts it on top with a ::backdrop under it. */
dialog:not([open]) { display: none; }
/* An open, non-modal dialog takes part in the flow as a block. */
dialog { display: block; }
dialog { position: fixed; inset: 0; margin: auto; width: fit-content; height: fit-content;
  border: solid; padding: 1em; background-color: #ffffff; color: #000000; }
dialog::backdrop { display: none; background-color: rgba(0, 0, 0, 0.1); }
/* Keyboard focus shows the system's focus ring, as Chrome's own UA sheet asks for with an auto
   outline; an author's outline wins over this like any other UA declaration. */
:focus-visible { outline-style: auto; outline-width: 1px; }
div, main, section, article, header, footer, nav, aside, ul, ol, form, p, h1, h2, h3, h4, h5, h6,
address, blockquote, center, dd, details, dir, dl, dt, fieldset, figcaption, figure, hgroup, hr,
legend, listing, menu, plaintext, pre, search, summary, xmp { display: block; }
/* The preformatted elements keep their white space as written. */
pre, listing, plaintext, xmp { white-space: pre; }
li { display: list-item; }
table { display: table; box-sizing: border-box; border-collapse: separate; border-spacing: 2px; border-color: #808080; }
caption { display: table-caption; text-align: center; }
colgroup { display: table-column-group; }
col { display: table-column; }
thead { display: table-header-group; }
tbody { display: table-row-group; }
tfoot { display: table-footer-group; }
tr { display: table-row; }
td, th { display: table-cell; padding: 1px; }
th { font-weight: 700; text-align: center; }
span, a, strong, b, em, i, code, small, label, br, s, del, u, mark, sub, sup, kbd, abbr, time, img, embed, object, canvas, svg,
bdi, bdo, wbr, var, samp, cite, dfn, q, data, ins, ruby, rt, output, font, big, tt, strike, acronym, nobr, map, audio, video { display: inline; }
/* A replaced element paints its image in its content box and clips it there, as browsers do with
   overflow: clip in their UA sheet; an author overflow: visible still lets a large image
   (object-fit: none, or a shifted object-position) spill out. An inline <svg> always clips its
   content to its viewport, as SVG says. */
img, embed, object, canvas, svg { overflow: clip; }
/* A template holds markup for a script; it never draws or takes room. */
template { display: none; }
/* A menu that serves as the window's menu bar or as a context menu is not part of the page: the
   app shows it as a native menu, so it draws nothing and takes no room. */
menu[type="application"], menu[type="context"] { display: none; }
u { text-decoration: underline; }
mark { background: #ffff00; }
em, i { font-style: italic; }
sub, sup { font-size: smaller; }
sub { vertical-align: sub; }
sup { vertical-align: super; }
code, kbd { font-size: 0.9em; }
button, input { display: inline-block; box-sizing: border-box; }
/* The block margins of these are logical, as a browser's are: they follow the block axis, so in a
   vertical writing mode they space the page across it rather than down it. */
h1 { font-size: 2em; font-weight: 700; margin-block-start: 0.67em; margin-block-end: 0.67em; }
h2 { font-size: 1.5em; font-weight: 700; margin-block-start: 0.83em; margin-block-end: 0.83em; }
h3 { font-size: 1.17em; font-weight: 700; margin-block-start: 1em; margin-block-end: 1em; }
h4 { font-weight: 700; margin-block-start: 1.33em; margin-block-end: 1.33em; }
h5 { font-size: 0.83em; font-weight: 700; margin-block-start: 1.67em; margin-block-end: 1.67em; }
h6 { font-size: 0.67em; font-weight: 700; margin-block-start: 2.33em; margin-block-end: 2.33em; }
p { margin-block-start: 1em; margin-block-end: 1em; }
blockquote { margin-block-start: 1em; margin-block-end: 1em; margin-inline-start: 40px; margin-inline-end: 40px; }
figure { margin-block-start: 1em; margin-block-end: 1em; margin-inline-start: 40px; margin-inline-end: 40px; }
dl { margin-block-start: 1em; margin-block-end: 1em; }
dd { margin-inline-start: 40px; }
ul, menu, dir, ol { margin-block-start: 1em; margin-block-end: 1em; padding-inline-start: 40px; }
:is(dir, dl, menu, ol, ul) :is(dir, dl, menu, ol, ul) { margin-block-start: 0; margin-block-end: 0; }
ul, menu, dir { list-style-type: disc; }
ol { list-style-type: decimal; }
:is(dir, menu, ol, ul) :is(dir, menu, ul) { list-style-type: circle; }
:is(dir, menu, ol, ul) :is(dir, menu, ol, ul) :is(dir, menu, ul) { list-style-type: square; }
strong, b { font-weight: 700; }
small { font-size: 0.83em; }
a { color: #0000ee; cursor: pointer; text-decoration: underline; }
s, del { text-decoration: line-through; }
button {
  display: inline-block; padding: 1px 6px; border: 1px solid #767676; border-radius: 3px;
  background: #efefef; font-family: Arial; font-size: 13.33px; text-align: center; cursor: default;
}
button:hover { background: #e5e5e5; }
button:active { background: #f5f5f5; }
/* A disabled control's text takes the system's grey, as Chrome's sheet gives it. An author rule
   still wins, as an author rule wins over every UA declaration, and the box keeps its own
   background. */
button:disabled, input:disabled, select:disabled, textarea:disabled, optgroup:disabled, option:disabled {
  color: GrayText;
}
input {
  display: inline-block; padding: 1px 2px; border: 1px solid #767676; border-radius: 2px;
  background: #fff; font-family: Arial; font-size: 13.33px; cursor: text; text-align: left;
}
/* A button, submit or reset input is the box a <button> draws, with its label centred in it: the
   label is the value attribute, or the type's own word when there is no value. */
input[type=button], input[type=submit], input[type=reset] {
  padding: 1px 6px; border: 1px solid #767676; border-radius: 3px; background: #efefef;
  color: #000; text-align: center; cursor: default; white-space: pre;
}
/* A color field is a small box around a swatch of the colour it holds. Chrome's is 50 by 27 — the
   border's included, as the input rule above has it — and the sizes follow the box's own axes, so a
   vertical writing mode turns the box upright. */
input[type=color] {
  inline-size: 50px; block-size: 27px; padding: 1px;
  border: 1px solid #767676; border-radius: 2px; background: #efefef; cursor: default;
}
/* A progress bar and a meter are inline-blocks with an intrinsic size, as in Chrome. */
progress, meter { display: inline-block; width: 10em; height: 1em; }
/* A checked box, a chosen radio and a range are widgets the UA paints itself, so their box is the
   widget's own: the text field's padding, border and background would only get in the way. */
input[type=checkbox], input[type=radio] {
  width: 13px; height: 13px; padding: 0; border: 0; background: transparent; cursor: default;
}
input[type=checkbox] { margin: 3px 4px; }
input[type=radio] { margin: 3px 5px; }
input[type=range] {
  width: 129px; height: 16px; margin: 2px; padding: 0; border: 0; background: transparent;
  cursor: default;
}
input[type=hidden] { display: none !important; }

/* A select shows its chosen option's label in a field of its own, sized to its widest option; the
   options themselves are only drawn in the menulist it opens, so the tree's boxes are out of the way. */
select {
  display: inline-block; box-sizing: border-box; padding: 1px 3px; border: 1px solid #767676;
  background: #fff; font-family: Arial; font-size: 13.33px; color: #000; overflow: clip;
}
select:is([multiple], [size]) { overflow: auto; padding: 0; }
/* A list box shows its options as rows; a closed field draws only the chosen label. */
option, optgroup { display: none; }
select:is([multiple], [size]) option { display: block; }

/* A textarea is a text field whose cols and rows attributes size its box and whose text wraps
   inside it. */
textarea {
  /* No box-sizing: a textarea computes to content-box, as Chrome's sheet leaves it (only button,
     select and some input types are border-box there). */
  display: inline-block; padding: 2px; border: 1px solid #767676;
  background: #fff; font-size: 13.33px; font-family: monospace; color: #000; overflow: auto;
  white-space: pre-wrap; resize: both;
}
/* A page whose used color-scheme is dark gets the UA's dark colours: white text, the dark canvas
   (painted by canvasColor), and the fields, buttons and panels dark. These follow the light
   rules above, at higher specificity, so they win without an !important. The colours are the
   ones Chrome 156 computes for the same page when its color-scheme is dark: its ButtonFace is
   #6b6b6b with a white border, Field #3b3b3b with a #858585 border, Canvas #121212, LinkText
   #9e9eff, and a mark keeps its yellow. */
:root:-native-dark { color: #ffffff; }
:root:-native-dark a { color: #9e9eff; }
:root:-native-dark button { background: #6b6b6b; border-color: #ffffff; color: #ffffff; }
:root:-native-dark input:not([type=checkbox]):not([type=radio]):not([type=range]),
:root:-native-dark select, :root:-native-dark textarea {
  background: #3b3b3b; border-color: #858585; color: #ffffff;
}
:root:-native-dark dialog, :root:-native-dark [popover] {
  background-color: #121212; border-color: #ffffff; color: #ffffff;
}
`;
