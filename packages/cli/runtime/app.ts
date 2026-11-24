// App shell: builds the DOM from compiled tables, then runs the event and render loop. Implementation lives in ./app/.

export { mount, attachHandler, paintPage, renderFrame, resetPage } from "./app/mount.ts";
export type { AppTables } from "./app/mount.ts";
export { run } from "./app/headless.ts";
export { settlePage, settleTests } from "./app/reftest.ts";
