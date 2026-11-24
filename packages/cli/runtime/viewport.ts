// The viewport size, in its own module so that both layout and the window globals can see it
// without importing each other. The event loop updates it; layout reads it.

export const viewport = { w: 800, h: 600 };
