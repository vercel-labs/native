// Following a link: the DOM sees the click, and the window knows what navigating means for an app
// (a fragment or a query on the page, or another window with the link's target). The DOM can't
// import the window module, which imports the DOM, so the window installs this at startup.

/** What a click on a link with an href does: navigate, or open the window its target names. */
export let followLinkHook: (href: string, target: string | null) => void = () => {};

export function setFollowLinkHook(fn: (href: string, target: string | null) => void): void {
  followLinkHook = fn;
}
