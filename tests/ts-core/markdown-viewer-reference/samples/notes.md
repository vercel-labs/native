# Reading notes — *A Philosophy of Software Design*

Ousterhout's core claim: **complexity is incremental**, and the fight against it is won or lost in code review, not architecture review.

## Chapter 4 — Modules should be deep

- A module is an abstraction: interface (cost) over implementation (benefit)
- *Deep* modules: small interface, lots of functionality behind it
  - `write()` in Unix — one call hides buffering, scheduling, devices
  - Counter-example: a class per field with getters and setters
- Shallow modules make the codebase *feel* organized while adding surface area

> "The best modules are those whose interfaces are much simpler than their implementations."

## Chapter 6 — General-purpose modules are deeper

- Somewhat counterintuitive: making it general-purpose usually makes it **smaller**
- The litmus test: ~~would this API change if the UI changed?~~ → *does the API mention the caller's domain?*
- Applied to our editor: `insert(text)` and `delete(range)` beat `backspace()`, `deleteSelection()`, `pasteFromClipboard()`

## Questions to bring on Thursday

1. Where do we draw the line between deep and *bloated*?
2. Is our effects channel a deep module? One call, five outcome enums…
3. Chapter 9's "better together vs. better apart" — apply it to the sync RFC

## Follow-ups

- Reread chapter 5 on information leakage — [summary here](https://example.com/notes/leakage)
- Compare with Parnas, [On the Criteria](https://example.com/parnas-1972)
- Draft a "depth review" checklist for the next review cycle
