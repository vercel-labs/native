// The SVG painter's notice that a subtree left the document, so it can give back the bitmaps it
// kept for an <svg> that is gone. It lives in a module of its own, with no imports, because
// dom.ts's dependencies can remove a node while they are still being initialized: a variable in
// dom.ts itself would be in its temporal dead zone then, and a holder object that is the first
// thing dom.ts imports never is.

/** Called with each subtree that leaves the document while connected; null until the painter
 *  registers (see runtime/svg.ts). */
export const svgDetach: { fn: ((removed: unknown) => void) | null } = { fn: null };
