// Whether a text run's data can change what a selector matches: an `:empty` condition, a `:has()`
// argument, a counter, or a filtered sibling count all read the text below an element. style.ts
// works this out from the page's tables and sets the flag; the DOM asks before deciding that a
// text edit only needs a relay-out. A module of its own so neither side imports the other.

export const textRunDependence = { affectSelectors: false };
