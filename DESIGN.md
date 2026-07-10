# Native SDK Design Guide

This guide is the design contract for Native SDK itself: built-in components,
examples, templates, docs screenshots, and agent-generated native UI should all
pull in this direction. It complements the Native UI language reference and the
theming docs; it does not replace either.

## Default Stance

- Build the real product surface first. An app opens on the workspace, editor,
  dashboard, browser, board, player, or tool the user came for.
- Prefer native, familiar controls over decorative imitations. Buttons, lists,
  fields, tabs, menus, sliders, charts, and dialogs should use the framework's
  widgets unless a new primitive is genuinely needed.
- Make operational software quiet and scannable. Dense information, stable
  alignment, restrained color, and predictable navigation beat big marketing
  composition inside an app.
- Let brand live in tokens. Component behavior and structure should stay stable
  while color, radius, type, motion, and control metrics move through
  `DesignTokens`.

## Product Shape

- Start with a useful first viewport. Avoid splash screens, landing pages, and
  ornamental hero sections for apps, dashboards, internal tools, and games.
- Give screens a clear job: navigation or collection on one side, the primary
  work area in the center, detail/actions where they are needed, and status at
  the edge.
- Choose the display primitive that matches the data:
  - `list` / `list-item` for selectable records and feeds.
  - `table` or `data_grid` for comparison across columns.
  - `chart` for quantitative trends, with labels and semantics.
  - `tree` for nested disclosure, not hand-indented lists.
  - `timeline` / `stepper` for progress through time or stages.
- Always design the non-happy states: empty, loading, disabled, invalid,
  selected, focused, error, and offline or unavailable surfaces.

## Component Discipline

- Do not make fake controls out of styled containers. If it can be a `button`,
  `checkbox`, `radio`, `switch`, `slider`, `select`, `text-field`, or
  `list-item`, use that widget.
- Icon actions need a real vector icon plus an accessible label. Prefer the
  built-in icon registry or registered app icons to glyph text.
- Keep one control size register per row. Mixing `sm`, default, and `lg` in the
  same toolbar should be a deliberate exception, not drift.
- `heading` and `display` are typography rungs for text, not control sizes.
  Hero-sized text belongs only where it improves scanning or hierarchy.
- Do not nest cards inside cards. Use cards for repeated standalone items or
  modal content; use panels, full-width bands, rows, columns, and split panes
  for page structure.
- Composite selectable rows should stay rows. Use `list-item` with children for
  title/snippet/badge layouts; reserve bordered cards for items that are truly
  card-like.
- Charts should visualize live data, not screenshots. Label series, report
  semantics, and make hover details optional interaction chrome.

## Layout

- Prefer explicit constraints over lucky content fit: widths for fixed columns,
  heights for fixed controls, min-widths for split panes, and grow only where
  space can actually flex.
- Text must not overlap or escape its container. Use `wrap`, `overflow`, stable
  widths, and layout tests when labels can vary.
- Rows and columns do not wrap children. If content needs wrapping, wrap text
  leaves or change the structure.
- Stacking containers (`stack`, `panel`, `card`, modal surfaces) layer children;
  put a `row` or `column` inside when you want flow and `gap`.
- Keep spacing regular. Use the token scale and small local variation instead
  of ad hoc offsets.
- Avoid decoration that does not carry information or affordance. Background
  blobs, ornamental gradients, and visual noise make native-rendered apps feel
  less native.

## Tokens And Theming

- Use semantic color tokens in views (`background`, `surface`, `text`,
  `text_muted`, `accent`, `success`, `warning`, `destructive`, `info`) rather
  than raw colors.
- Raw colors belong in token packs, token overrides, generated assets, or
  custom low-level drawing where a token has already been chosen by the caller.
- Every theme decision should be checked in light, dark, and high contrast.
  Reduced motion must preserve the same state transitions without relying on
  animation to communicate meaning.
- Theme first, eject second, build third: use tokens for visual changes, eject
  library composites when you need to own their structure, and create new
  components only when neither path fits.

## Accessibility And Input

- Every interactive or informative non-text surface needs a stable accessible
  name. Icon-only controls must have `label`.
- Roles should describe the interaction users get: `listitem`, `treeitem`,
  `button`, `chart`, `group`, and so on. Do not add roles for styling.
- Keyboard behavior must match the component's native contract. Selection rows,
  tabs, radio groups, sliders, split dividers, dialogs, and menus should all be
  reachable and operable without a pointer.
- Focus rings are product UI, not debug chrome. They must be visible, clipped
  correctly, and consistent with the token pack.
- Status, errors, and progress need text equivalents. A color-only signal is not
  enough.

## Verification

Before finishing framework UI work, run the checks that match the change:

- `native check` for markup and manifest validation in an app workspace.
- `native test` or the relevant `zig build test-example-<name>` for examples.
- Layout sweeps for fixed-format surfaces and accessibility sweeps for all
  focusable UI.
- Reference screenshots or component previews when a visual decision changed.
- `scripts/gate.sh fast` from the framework repo before merging.

## Review Checklist

- Does the first screen perform the app's real job?
- Did the implementation use built-in widgets before custom drawing?
- Are lists, tables, charts, trees, and timelines chosen for the right data?
- Are spacing, type, color, and radii token-driven?
- Do all states exist and stay stable under resize and longer text?
- Can keyboard and assistive-tech users identify and operate every control?
- Are visual changes covered by tests, previews, or screenshots?
