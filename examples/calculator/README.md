# Native SDK calculator example

A real four-function calculator built to showcase precision Native SDK layout: the classic keypad grid with exact 66x54 keys, a live expression + result display with the last calculation remembered above it, full keyboard input, and a chromeless window that is nothing but keys and digits. The window is fixed at 320x490 — every frame in it is deliberate, and the test suite asserts the keypad's frames to the point.

## Design brief

The calculator is a precision instrument in the house register: pure neutrals, hairline borders, and exactly one accent — action blue — that appears only when something is live. Nothing at rest is colored.

- **Surfaces.** Paper white and true graphite. Light: white keys lifted off a near-white window by hairlines. Dark: graphite keys on near-black. Key faces separate by one gray step, never by shadows.
- **The strong column.** The operator column and equals are the inverted monochrome keys — near-black faces with white glyphs in light mode, near-white faces with dark glyphs in dark mode. The board reads black-and-white until an operator goes pending, when that key fills with the accent.
- **One accent.** Action blue marks live state only: the pending operator, the press flash on any key, the focus ring on the expression line. It is the sole color in the app.
- **The readout.** The result is tight monospace digits (the bundled mono face), right-aligned, the loudest thing in the window; the memory line above it is the same mono two sizes down. Digits align column-over-column as you type.
- **No mark, no chrome.** Hidden-inset titlebar; the top band is an empty window drag region. No logo, no wordmark, no placeholder text, no app-name label, no theme control — the identity comes from the craft: the readout, the key rhythm, the tight mono numerals. The app follows the system appearance live.

## Arithmetic model (documented, tested)

**Immediate execution**, the model every desk calculator uses: `2 + 3 × 4 =` is `(2 + 3) × 4 = 20` — each operator applies the one before it, there is no precedence. On top of that:

- Chained operators evaluate live (`2 + 3 ×` shows `5` the moment × lands); pressing a second operator with no operand just switches it.
- `=` repeats: `2 + 3 = = =` walks 5, 8, 11. `5 + =` uses the display as the missing operand (10).
- `%` divides the current operand by 100 (no additive-percent special case — that is the whole rule).
- `±` negates the entry while typing, or the standing value otherwise.
- Backspace edits the number being typed, down to `0` and never past it; results are not editable.
- Division by zero (and any non-finite result, including `0 ÷ 0`) shows **Error** with the failing calculation in the expression line; operators go inert until AC — or any digit, which starts fresh.

All arithmetic is f64 with honest display formatting (`formatValue`): integers print exactly up to 12 digits, fractions round to at most 10 decimals for display only (the model keeps full precision — `0.1 + 0.2` shows `0.3`, continues as the exact sum), and anything beyond the 12-digit window prints in scientific notation. Typed entries cap at 12 significant digits, like the desk calculators the model imitates.

## Keyboard (the seam, documented)

The expression line is a real `text_field` and it is the app's keyboard path: click it (or Tab to it) and digits, `+ - * x / . , % =`, backspace, and enter all flow through the widget keyboard path as `TextInputEvent`s that `update` parses into calculator keys — the field's text is model-derived, so unknown characters can never appear. `c` clears. **Escape is a chrome shortcut** (`native_sdk.Shortcut`, mapped through `on_command`) so AC works with no widget focused at all; unmodified character keys deliberately cannot be chrome shortcuts, which is why the text-entry seam carries them.

## Authoring split (markup-first)

- `src/keypad.zml` — the entire keypad, key by key: function keys `secondary`, the operator column and equals `primary` (the inverted monochrome column), digits default surfaces, the pending operator highlighted via a model-sourced `selected=`. Markup message payloads are bindings, so each key dispatches its own void `Msg` arm — which also reads exactly like the keypad it is.
- `src/view.zig` — the Zig-only sections: the drag band (hidden-inset titlebar, `window_drag`, deliberately empty) and the display block, because the big result line needs a scaled, right-aligned monospace paragraph (markup text tops out at the `lg` body size). Also documented there: text fields are start-aligned by the engine (caret math), so the expression line stays left-aligned.
- `src/model.zig` — the whole engine and the **plain-form TEA update**: no effects, no timers, no I/O. This is the smallest real Native SDK app shape.
- `src/theme.zig` — the neutral palettes for both modes, the inverted-monochrome operator column, and the one blue accent through `controls.button_primary.active_background`; high-contrast falls back to the framework palettes, and keypad glyphs render at 18px via `typography.button_size`.

## Run

```sh
native dev
```

Click the expression line and type `12+7⏎`, or press the keys. Escape clears from anywhere. The app follows the system appearance live — flip the OS to dark and the board follows.

Run the deterministic suite (exhaustive arithmetic through `msgForPointer` on every key, keyboard through real `gpu_surface_input` events, the Escape shortcut through the platform event path, formatting, theming, markup engine parity, snapshot assertions, and the exact-frame keypad layout check):

```sh
native test -Dplatform=null
```

Verify live through the automation harness:

```sh
native build -Dautomation=true
./zig-out/bin/calculator &
native automate assert 'gpu_nonblank=true' 'role=button name="Equals"' 'role=textbox name="Expression"'
# Keyboard rides the focused expression field: focus it (widget-click its
# id from the snapshot), then type 9 × 9 ⏎ and watch the result land.
native automate widget-key calc-canvas 9 9 && native automate widget-key calc-canvas x x && native automate widget-key calc-canvas 9 9 && native automate widget-key calc-canvas enter
native automate assert 'role=text name="81"'
```
