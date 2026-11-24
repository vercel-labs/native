// Running a menu item's command: the DOM sees the click that runs it, and the menus module knows
// what each command does. The DOM can't import the menus module, which imports the DOM, so the
// menus module installs this at startup.

/** What a menuitem's command does when its element is clicked. */
export let runCommandHook: (command: string) => void = () => {};

export function setRunCommandHook(fn: (command: string) => void): void {
  runCommandHook = fn;
}
