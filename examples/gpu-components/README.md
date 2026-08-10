# Native SDK gpu-components example

An isolated gallery of the built-in Native UI components, authored entirely in **TypeScript + Native markup**. There is no app-owned Zig: `src/core.ts` owns controlled state, `src/app.native` owns the component tree and specimens, and `app.zon` describes the desktop shell.

The left pane has a live Default/Geist theme-pack selector and a real disclosure `tree` whose rows use the built-in roving keyboard focus and scroll-into-view behavior. The right pane renders only the selected component. The selector changes the pack in the TypeScript model while the runtime keeps following system appearance. Accordion disclosure, dropdown/select/combobox menus, modal surfaces, fields, sliders, tabs, lists, and the focused Tree specimen are all interactive examples of the public markup API.

Run the app with the repository CLI:

```sh
native dev
```

Compile the TypeScript core, validate the markup contract, and run the generated headless app suite:

```sh
native test -Dplatform=null
```
