import type { TextInputEvent } from "@native-sdk/core/text";
import type { FileOperation, FileEvent, FileOutcome } from "./types.ts";
import { entryIndex } from "./whole.ts";
import { Cmd, asciiBytes, utf8Bytes, windowDescriptor } from "@native-sdk/core";
import type { ChromeInsets, ChromeButtons, KeyEvent, WindowDescriptor, FrameEvent } from "@native-sdk/core/events";
import { counterEqual, initialFileKey, counterZero, incrementCounter, counterBytes } from "./counters.ts";
import { initialBrowser, status, transition, stay, hasDirty, hasWrites, openIndices, fullPath, scanDirectory, installDirectory, finishRename, concat } from "./editor.ts";
import { bytesEqual, renamedExplorerPath } from "./explorer.ts";
import { folderRequest, directoryRequest, renameRequest, windowRequest, capabilityReply } from "./capabilities.ts";
import { project, type EditorPage } from "./view.ts";
import type { BrowserSession, EditorPlan, BrowserMsg, ExactCounter } from "./types.ts";

export interface Model {
  readonly sessions: readonly BrowserSession[];
  readonly active_session: number;
  readonly pending_focus_session: number | null;
  readonly pending_close_main: boolean;
  readonly next_capability: ExactCounter;
  readonly focus_token: Uint8Array;
  readonly close_token: Uint8Array;
}
export type WindowContextMsg = { readonly kind: "window_changed"; readonly label: Uint8Array } | { readonly kind: "window_context_unavailable" };
export type Msg =
  { readonly kind: "open_folder" }
  | { readonly kind: "select_entry"; readonly index: number }
  | { readonly kind: "preview_entry"; readonly index: number }
  | { readonly kind: "pin_entry"; readonly index: number }
  | { readonly kind: "pin_tree_entry" }
  | { readonly kind: "begin_rename"; readonly index: number }
  | { readonly kind: "edit_rename"; readonly edit: TextInputEvent }
  | { readonly kind: "commit_rename" }
  | { readonly kind: "activate_tab"; readonly index: number }
  | { readonly kind: "hover_tab"; readonly index: number }
  | { readonly kind: "unhover_tab"; readonly index: number }
  | { readonly kind: "close_tab"; readonly index: number }
  | { readonly kind: "close_other_tabs"; readonly index: number }
  | { readonly kind: "close_active_tab" }
  | { readonly kind: "previous_tab" } | { readonly kind: "next_tab" }
  | { readonly kind: "toggle_entry"; readonly index: number }
  | { readonly kind: "edit_code"; readonly edit: TextInputEvent }
  | { readonly kind: "save_file" }
  | { readonly kind: "sidebar_resized"; readonly fraction: number }
  | { readonly kind: "file_done"; readonly key: Uint8Array; readonly operation: FileOperation; readonly event: FileEvent; readonly outcome: FileOutcome; readonly bytes: Uint8Array; readonly totalBytes: Uint8Array; readonly mtimeMs: Uint8Array; readonly exists: boolean; readonly droppedBefore: number }
  | { readonly kind: "new_window" }
  | { readonly kind: "close_window"; readonly session: number }
  | { readonly kind: "window_changed"; readonly label: Uint8Array }
  | { readonly kind: "window_context_unavailable" }
  | { readonly kind: "folder_done"; readonly bytes: Uint8Array }
  | { readonly kind: "directory_done"; readonly bytes: Uint8Array }
  | { readonly kind: "rename_done"; readonly bytes: Uint8Array }
  | { readonly kind: "folder_failed_0"; readonly error: Uint8Array }
  | { readonly kind: "folder_failed_1"; readonly error: Uint8Array }
  | { readonly kind: "folder_failed_2"; readonly error: Uint8Array }
  | { readonly kind: "folder_failed_3"; readonly error: Uint8Array }
  | { readonly kind: "folder_failed_4"; readonly error: Uint8Array }
  | { readonly kind: "directory_failed_0"; readonly error: Uint8Array }
  | { readonly kind: "directory_failed_1"; readonly error: Uint8Array }
  | { readonly kind: "directory_failed_2"; readonly error: Uint8Array }
  | { readonly kind: "directory_failed_3"; readonly error: Uint8Array }
  | { readonly kind: "directory_failed_4"; readonly error: Uint8Array }
  | { readonly kind: "rename_failed_0"; readonly error: Uint8Array }
  | { readonly kind: "rename_failed_1"; readonly error: Uint8Array }
  | { readonly kind: "rename_failed_2"; readonly error: Uint8Array }
  | { readonly kind: "rename_failed_3"; readonly error: Uint8Array }
  | { readonly kind: "rename_failed_4"; readonly error: Uint8Array }
  | { readonly kind: "focus_done"; readonly bytes: Uint8Array }
  | { readonly kind: "close_done"; readonly bytes: Uint8Array }
  | { readonly kind: "window_retry" }
  | { readonly kind: "window_failed"; readonly error: Uint8Array }
  | { readonly kind: "chrome_changed"; readonly insets: ChromeInsets; readonly buttons: ChromeButtons; readonly tabsProjected: boolean };
export const chromeMsg = "chrome_changed";
export const viewUnbound = ["sessions", "active_session", "pending_focus_session", "pending_close_main", "next_capability", "focus_token", "close_token", "window_changed", "window_context_unavailable", "file_done", "folder_done", "directory_done", "rename_done", "folder_failed_0", "folder_failed_1", "folder_failed_2", "folder_failed_3", "folder_failed_4", "directory_failed_0", "directory_failed_1", "directory_failed_2", "directory_failed_3", "directory_failed_4", "rename_failed_0", "rename_failed_1", "rename_failed_2", "rename_failed_3", "rename_failed_4", "focus_done", "close_done", "window_retry", "window_failed", "chrome_changed", "new_window", "close_window"] as const;
export function frameMsg(model: Model, frame: FrameEvent): Msg | null {
  return model.pending_focus_session !== null || model.pending_close_main ? { kind: "window_retry" } : null;
}
function sessionLabel(index: number): Uint8Array {
  if (index === 1) return asciiBytes("code-editor-2");
  if (index === 2) return asciiBytes("code-editor-3");
  if (index === 3) return asciiBytes("code-editor-4");
  if (index === 4) return asciiBytes("code-editor-5");
  return asciiBytes("main");
}

function blankSession(index: number, open: boolean): BrowserSession {
  const browser = initialBrowser(open ? index : 0);
  return { open, pending_root: asciiBytes(""), folder_token: asciiBytes(""), directory_token: asciiBytes(""), rename_token: asciiBytes(""), browser, handled_picker_serial: browser.picker_serial, handled_rename_serial: browser.rename_serial, handled_expand_serial: browser.expand_serial };
}
export function initialModel(): Model {
  const sessions: BrowserSession[] = []; for (let i = 0; i < 5; i += 1) sessions.push(blankSession(i, i === 0));
  return { sessions, active_session: 0, pending_focus_session: null, pending_close_main: false, next_capability: initialFileKey(0), focus_token: asciiBytes(""), close_token: asciiBytes("") };
}
function ownerIndex(model: Model): number {
  return model.active_session >= 0 && model.active_session < 5 && model.sessions[model.active_session]!.open ? model.active_session : 0;
}
function withSession(model: Model, index: number, session: BrowserSession): Model {
  return { ...model, sessions: model.sessions.map((old, at) => at === index ? session : old) };
}
function counterMaximum(a: ExactCounter, b: ExactCounter): ExactCounter {
  return a.counter_upper > b.counter_upper || a.counter_upper === b.counter_upper && a.counter_lower >= b.counter_lower ? a : b;
}
function closeSession(model: Model, index: number): Model {
  if (index <= 0 || index >= 5) return model;
  const session = model.sessions[index]!;
  if (hasWrites(session.browser)) return withSession(model, index, { ...session, browser: status(session.browser, asciiBytes("Wait for file saves before closing this window.")) });
  if (hasDirty(session.browser)) return withSession(model, index, { ...session, browser: status(session.browser, asciiBytes("Save all files before closing this window.")) });
  const blank = blankSession(0, false);
  return { ...withSession(model, index, { ...blank, browser: { ...blank.browser, next_file_key: session.browser.next_file_key } }),
    active_session: model.active_session === index ? 0 : model.active_session,
    pending_focus_session: model.pending_focus_session === index ? null : model.pending_focus_session,
    focus_token: model.pending_focus_session === index ? asciiBytes("") : model.focus_token };
}
interface CapabilityPlan { readonly owner: number; readonly operation: "folder" | "directory" | "rename"; readonly payload: Uint8Array; }
interface AppPlan { readonly model: Model; readonly files: readonly EditorPlan[]; readonly requests: readonly CapabilityPlan[]; }
function takeCapability(model: Model): { readonly model: Model; readonly token: Uint8Array } {
  return { model: { ...model, next_capability: incrementCounter(model.next_capability) }, token: counterBytes(model.next_capability) };
}
function appStay(model: Model): AppPlan { return { model, files: [], requests: [] }; }
/** Consume host plans once, in the reference's rename/scan/dialog order. */
function executePlans(model: Model, files: readonly EditorPlan[]): AppPlan {
  let next = model;
  const requests: CapabilityPlan[] = [];
  let renamed = false, expanded = false, picked = false;
  for (let index = 0; index < 5; index += 1) {
    let session = next.sessions[index]!; if (!session.open) continue;
    let browser = session.browser;
    if (!renamed && browser.pending_rename_entry !== null && !counterEqual(browser.rename_serial, session.handled_rename_serial)) {
      renamed = true; session = { ...session, handled_rename_serial: browser.rename_serial };
      next = { ...next, active_session: index >>> 0 };
      const at = browser.pending_rename_entry, entry = browser.entries[at]!;
      const relative = renamedExplorerPath(entry, browser.rename_buffer.text);
      const collision = browser.entries.some((candidate, candidateIndex) => candidateIndex !== at && bytesEqual(candidate.relative_path, relative));
      const oldPath = fullPath(browser, entry.relative_path), newPath = fullPath(browser, relative);
      if (collision) browser = finishRename(browser, asciiBytes("PathAlreadyExists"));
      else if (oldPath === null || newPath === null) browser = status({ ...browser, pending_rename_entry: null }, asciiBytes("That file path is too long to rename."));
      else {
        const issued = takeCapability(next); next = issued.model;
        session = { ...session, rename_token: issued.token };
        requests.push({ owner: index, operation: "rename", payload: renameRequest(index, issued.token, oldPath, newPath) });
      }
    }
    session = { ...session, browser }; next = withSession(next, index, session);
  }
  for (let index = 0; index < 5; index += 1) {
    let session = next.sessions[index]!; if (!session.open) continue;
    const browser = session.browser;
    if (!expanded && browser.pending_expand_entry !== null && !counterEqual(browser.expand_serial, session.handled_expand_serial)) {
      expanded = true; session = { ...session, handled_expand_serial: browser.expand_serial };
      const parent = browser.entries[browser.pending_expand_entry]!, path = fullPath(browser, parent.relative_path);
      if (path === null) session = { ...session, browser: status({ ...browser, pending_expand_entry: null }, asciiBytes("Could not open that folder: PathTooLong")) };
      else {
        const issued = takeCapability(next); next = issued.model;
        session = { ...session, directory_token: issued.token };
        requests.push({ owner: index, operation: "directory", payload: directoryRequest(index, issued.token, path, 128 - browser.entries.length, Math.max(0, Math.min(255, 511 - parent.relative_path.length))) });
      }
      next = { ...next, active_session: index >>> 0 };
    }
    next = withSession(next, index, session);
  }
  for (let index = 0; index < 5; index += 1) {
    let session = next.sessions[index]!; if (!session.open) continue;
    if (!picked && !counterEqual(session.browser.picker_serial, session.handled_picker_serial)) {
      picked = true; session = { ...session, handled_picker_serial: session.browser.picker_serial };
      const issued = takeCapability(next); next = issued.model;
      session = { ...session, folder_token: issued.token };
      requests.push({ owner: index, operation: "folder", payload: folderRequest(index, issued.token, session.browser.root) });
      next = { ...next, active_session: index >>> 0 };
    }
    next = withSession(next, index, session);
  }
  return { model: next, files, requests };
}
function appTransition(model: Model, msg: Msg): AppPlan {
  const index = ownerIndex(model), session = model.sessions[index]!;
  switch (msg.kind) {
    case "window_changed": {
      const labels = [asciiBytes("main"), asciiBytes("code-editor-2"), asciiBytes("code-editor-3"), asciiBytes("code-editor-4"), asciiBytes("code-editor-5")];
      for (let at = 0; at < labels.length; at += 1) if (bytesEqual(msg.label, labels[at]!)) return appStay({ ...model, active_session: at >>> 0 });
      return appStay(model);
    }
    case "window_context_unavailable": case "window_retry": case "window_failed": return appStay(model);
    case "focus_done": case "close_done": {
      const reply = capabilityReply(msg.bytes, "window");
      if (!reply.valid || reply.error.length > 0) return appStay(model);
      if (msg.kind === "close_done") return appStay(reply.owner === 0 && bytesEqual(reply.token, model.close_token) ? { ...model, pending_close_main: false, close_token: asciiBytes("") } : model);
      return appStay(reply.owner === model.pending_focus_session && bytesEqual(reply.token, model.focus_token) ? { ...model, pending_focus_session: null, focus_token: asciiBytes("") } : model);
    }
    case "new_window": {
      for (let at = 1; at < 5; at += 1) {
        const previous = model.sessions[at]!; if (previous.open) continue;
        const next = blankSession(at, true);
        const issued = takeCapability(model);
        return appStay({ ...withSession(issued.model, at, { ...next, browser: { ...next.browser, next_file_key: counterMaximum(previous.browser.next_file_key, initialFileKey(at)) } }), active_session: at >>> 0, pending_focus_session: at >>> 0, focus_token: issued.token });
      }
      return appStay(withSession(model, index, { ...session, browser: status(session.browser, asciiBytes("Window limit reached (5).")) }));
    }
    case "close_window": return appStay(closeSession(model, msg.session));
    case "close_active_tab": {
      if (openIndices(session.browser).length > 0) break;
      if (index !== 0) return appStay(closeSession(model, index));
      const issued = takeCapability(model);
      return appStay({ ...issued.model, pending_close_main: true, close_token: issued.token });
    }
    case "chrome_changed": {
      const main = model.sessions[0]!, leading = Math.fround(msg.insets.left);
      const height = Math.max(52, msg.insets.top);
      return appStay(withSession(model, 0, { ...main, browser: { ...main.browser, chrome_leading: leading, titlebar_height: Math.fround(height) } }));
    }
    case "file_done": {
      let next = model; const plans: EditorPlan[] = [];
      for (let at = 0; at < 5; at += 1) {
        const owner = next.sessions[at]!; if (!owner.open) continue;
        const plan = transition(owner.browser, msg); next = withSession(next, at, { ...owner, browser: plan.browser }); plans.push(plan);
      }
      return { model: next, files: plans, requests: [] };
    }
    case "folder_failed_0": case "folder_failed_1": case "folder_failed_2": case "folder_failed_3": case "folder_failed_4": {
      const failedOwner = msg.kind === "folder_failed_0" ? 0 : msg.kind === "folder_failed_1" ? 1 : msg.kind === "folder_failed_2" ? 2 : msg.kind === "folder_failed_3" ? 3 : 4;
      const failed = model.sessions[failedOwner]!;
      if (!failed.open || failed.folder_token.length === 0) return appStay(model);
      return appStay(withSession(model, failedOwner, { ...failed, folder_token: asciiBytes(""), browser: status(failed.browser, asciiBytes("The folder dialog could not be opened.")) }));
    }
    case "directory_failed_0": case "directory_failed_1": case "directory_failed_2": case "directory_failed_3": case "directory_failed_4": {
      const failedOwner = msg.kind === "directory_failed_0" ? 0 : msg.kind === "directory_failed_1" ? 1 : msg.kind === "directory_failed_2" ? 2 : msg.kind === "directory_failed_3" ? 3 : 4;
      const failed = model.sessions[failedOwner]!;
      if (!failed.open || failed.directory_token.length === 0) return appStay(model);
      return appStay(withSession(model, failedOwner, { ...failed, directory_token: asciiBytes(""), pending_root: asciiBytes(""), browser: status({ ...failed.browser, pending_expand_entry: null }, concat([asciiBytes("Could not open that folder: "), msg.error])) }));
    }
    case "rename_failed_0": case "rename_failed_1": case "rename_failed_2": case "rename_failed_3": case "rename_failed_4": {
      const failedOwner = msg.kind === "rename_failed_0" ? 0 : msg.kind === "rename_failed_1" ? 1 : msg.kind === "rename_failed_2" ? 2 : msg.kind === "rename_failed_3" ? 3 : 4;
      const failed = model.sessions[failedOwner]!;
      if (!failed.open || failed.rename_token.length === 0) return appStay(model);
      return appStay(withSession(model, failedOwner, { ...failed, rename_token: asciiBytes(""), browser: finishRename(failed.browser, msg.error) }));
    }
    case "folder_done": case "directory_done": case "rename_done": {
      const operation = msg.kind === "folder_done" ? "folder" : msg.kind === "directory_done" ? "directory" : "rename";
      const reply = capabilityReply(msg.bytes, operation); if (!reply.valid) return appStay(model);
      let owner = model.sessions[reply.owner]!; if (!owner.open) return appStay(model);
      const expected = operation === "folder" ? owner.folder_token : operation === "directory" ? owner.directory_token : owner.rename_token;
      if (expected.length === 0 || !bytesEqual(reply.token, expected)) return appStay(model);
      owner = operation === "folder" ? { ...owner, folder_token: asciiBytes("") } : operation === "directory" ? { ...owner, directory_token: asciiBytes("") } : { ...owner, rename_token: asciiBytes("") };
      let browser = owner.browser;
      if (operation === "rename") return appStay(withSession(model, reply.owner, { ...owner, browser: finishRename(browser, reply.error) }));
      if (operation === "folder") {
        if (reply.error.length > 0) return appStay(withSession(model, reply.owner, { ...owner, browser: status(browser, asciiBytes("The folder dialog could not be opened.")) }));
        if (reply.path.length === 0) return appStay(withSession(model, reply.owner, { ...owner, browser: status(browser, asciiBytes("Folder selection cancelled.")) }));
        const invalid = reply.path.length > 512 ? asciiBytes("PathTooLong") : hasWrites(browser) ? asciiBytes("FileActivityPending") : hasDirty(browser) ? asciiBytes("UnsavedChanges") : asciiBytes("");
        if (invalid.length > 0) return appStay(withSession(model, reply.owner, { ...owner, browser: status(browser, concat([asciiBytes("Could not open that folder: "), invalid])) }));
        const issued = takeCapability(model);
        return { ...appStay(withSession(issued.model, reply.owner, { ...owner, pending_root: reply.path, directory_token: issued.token })), requests: [{ owner: reply.owner, operation: "directory", payload: directoryRequest(reply.owner, issued.token, reply.path, 128, 255) }] };
      }
      const rootScan = owner.pending_root.length > 0;
      if (reply.error.length > 0) browser = status(browser, concat([asciiBytes("Could not open that folder: "), reply.error]));
      else if (rootScan) browser = scanDirectory(browser, owner.pending_root, reply.items, reply.truncated, reply.had_errors);
      else if (browser.pending_expand_entry !== null) browser = installDirectory(browser, browser.pending_expand_entry, reply.items, reply.truncated, reply.had_errors);
      if (!rootScan) browser = { ...browser, pending_expand_entry: null };
      return appStay(withSession(model, reply.owner, { ...owner, pending_root: asciiBytes(""), browser }));
    }
    default: break;
  }
  // Host-only cases returned above; the remaining union is the browser input surface.
  const plan = transition(session.browser, msg);
  return { model: withSession(model, index, { ...session, browser: plan.browser }), files: [plan], requests: [] };
}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  const transitioned = appTransition(model, msg);
  const derived = msg.kind === "window_changed" || msg.kind === "window_context_unavailable" ? appStay(transitioned.model) : executePlans(transitioned.model, transitioned.files);
  const plan: AppPlan = { ...derived, requests: [...transitioned.requests, ...derived.requests] };
  // Native failures retain intent until a later event; a reply never retries
  // itself while the effect queue drains.
  const retry = msg.kind !== "window_changed" && msg.kind !== "window_context_unavailable" && msg.kind !== "focus_done" && msg.kind !== "close_done" && msg.kind !== "window_failed";
  return [plan.model, Cmd.batch([
    model.sessions[1]!.open && !plan.model.sessions[1]!.open ? Cmd.batch([Cmd.cancel("editor.folder.1"), Cmd.cancel("editor.directory.1"), Cmd.cancel("editor.rename.1")]) : Cmd.none,
    model.sessions[2]!.open && !plan.model.sessions[2]!.open ? Cmd.batch([Cmd.cancel("editor.folder.2"), Cmd.cancel("editor.directory.2"), Cmd.cancel("editor.rename.2")]) : Cmd.none,
    model.sessions[3]!.open && !plan.model.sessions[3]!.open ? Cmd.batch([Cmd.cancel("editor.folder.3"), Cmd.cancel("editor.directory.3"), Cmd.cancel("editor.rename.3")]) : Cmd.none,
    model.sessions[4]!.open && !plan.model.sessions[4]!.open ? Cmd.batch([Cmd.cancel("editor.folder.4"), Cmd.cancel("editor.directory.4"), Cmd.cancel("editor.rename.4")]) : Cmd.none,
    Cmd.batch(plan.files.map(file => Cmd.batch([
      Cmd.batch(file.cancel_keys.map(key => Cmd.cancelKey(key))),
      file.read_path.length > 0 ? Cmd.readFileResultKey(file.read_key, file.read_path, { replace: false, result: "file_done" }) : Cmd.none,
      file.write_path.length > 0 ? Cmd.writeFileResultKey(file.write_key, file.write_path, file.write_bytes, { replace: false, result: "file_done" }) : Cmd.none,
    ]))),
    Cmd.batch(plan.requests.filter(request => request.operation !== "folder").map(request =>
      request.owner === 0 && request.operation === "directory" ? Cmd.request("native-sdk.fs.listDirectory", request.payload, { key: "editor.directory.0", ok: "directory_done", err: "directory_failed_0" }) :
      request.owner === 0 ? Cmd.request("native-sdk.fs.renameExclusive", request.payload, { key: "editor.rename.0", ok: "rename_done", err: "rename_failed_0" }) :
      request.owner === 1 && request.operation === "directory" ? Cmd.request("native-sdk.fs.listDirectory", request.payload, { key: "editor.directory.1", ok: "directory_done", err: "directory_failed_1" }) :
      request.owner === 1 ? Cmd.request("native-sdk.fs.renameExclusive", request.payload, { key: "editor.rename.1", ok: "rename_done", err: "rename_failed_1" }) :
      request.owner === 2 && request.operation === "directory" ? Cmd.request("native-sdk.fs.listDirectory", request.payload, { key: "editor.directory.2", ok: "directory_done", err: "directory_failed_2" }) :
      request.owner === 2 ? Cmd.request("native-sdk.fs.renameExclusive", request.payload, { key: "editor.rename.2", ok: "rename_done", err: "rename_failed_2" }) :
      request.owner === 3 && request.operation === "directory" ? Cmd.request("native-sdk.fs.listDirectory", request.payload, { key: "editor.directory.3", ok: "directory_done", err: "directory_failed_3" }) :
      request.owner === 3 ? Cmd.request("native-sdk.fs.renameExclusive", request.payload, { key: "editor.rename.3", ok: "rename_done", err: "rename_failed_3" }) :
      request.owner === 4 && request.operation === "directory" ? Cmd.request("native-sdk.fs.listDirectory", request.payload, { key: "editor.directory.4", ok: "directory_done", err: "directory_failed_4" }) :
      request.owner === 4 ? Cmd.request("native-sdk.fs.renameExclusive", request.payload, { key: "editor.rename.4", ok: "rename_done", err: "rename_failed_4" }) :
      Cmd.none)),
    retry && plan.model.pending_close_main ? Cmd.request("native-sdk.window.closeResult", windowRequest(0, plan.model.close_token, asciiBytes("main")), { key: "editor.close", ok: "close_done", err: "window_failed" }) : Cmd.none,
    retry && plan.model.pending_focus_session !== null ? Cmd.request("native-sdk.window.focusResult", windowRequest(plan.model.pending_focus_session, plan.model.focus_token, sessionLabel(plan.model.pending_focus_session)), { key: "editor.focus", ok: "focus_done", err: "window_failed" }) : Cmd.none,
    Cmd.batch(plan.requests.filter(request => request.operation === "folder").map(request =>
      request.owner === 0 ? Cmd.request("native-sdk.dialog.openDirectory", request.payload, { key: "editor.folder.0", ok: "folder_done", err: "folder_failed_0" }) :
      request.owner === 1 ? Cmd.request("native-sdk.dialog.openDirectory", request.payload, { key: "editor.folder.1", ok: "folder_done", err: "folder_failed_1" }) :
      request.owner === 2 ? Cmd.request("native-sdk.dialog.openDirectory", request.payload, { key: "editor.folder.2", ok: "folder_done", err: "folder_failed_2" }) :
      request.owner === 3 ? Cmd.request("native-sdk.dialog.openDirectory", request.payload, { key: "editor.folder.3", ok: "folder_done", err: "folder_failed_3" }) :
      request.owner === 4 ? Cmd.request("native-sdk.dialog.openDirectory", request.payload, { key: "editor.folder.4", ok: "folder_done", err: "folder_failed_4" }) :
      Cmd.none)),

  ])];
}
export function commandMsg(name: string): Msg | null {
  if (name === "save-file") return { kind: "save_file" };
  if (name === "close-tab") return { kind: "close_active_tab" };
  if (name === "open-folder") return { kind: "open_folder" };
  if (name === "new-window") return { kind: "new_window" };
  if (name === "previous-tab") return { kind: "previous_tab" };
  if (name === "next-tab") return { kind: "next_tab" };
  if (name === "close-editor-2") return { kind: "close_window", session: 1 };
  if (name === "close-editor-3") return { kind: "close_window", session: 2 };
  if (name === "close-editor-4") return { kind: "close_window", session: 3 };
  if (name === "close-editor-5") return { kind: "close_window", session: 4 };
  return null;
}
export function keyMsg(key: KeyEvent): Msg | null {
  return key.super && !key.alt && !key.shift && key.key === "arrowdown" ? { kind: "pin_tree_entry" } : null;
}
export function windows(model: Model): readonly WindowDescriptor[] {
  return [
    ...(model.sessions[1]!.open ? [windowDescriptor({ label: asciiBytes("code-editor-2"), canvasLabel: asciiBytes("code-editor-canvas-2"), title: asciiBytes("Native SDK Code Editor"), width: 1120, height: 720, minWidth: 760, minHeight: 480, titlebar: "hidden_inset_tall", onCloseCommand: asciiBytes("close-editor-2") })] : []),
    ...(model.sessions[2]!.open ? [windowDescriptor({ label: asciiBytes("code-editor-3"), canvasLabel: asciiBytes("code-editor-canvas-3"), title: asciiBytes("Native SDK Code Editor"), width: 1120, height: 720, minWidth: 760, minHeight: 480, titlebar: "hidden_inset_tall", onCloseCommand: asciiBytes("close-editor-3") })] : []),
    ...(model.sessions[3]!.open ? [windowDescriptor({ label: asciiBytes("code-editor-4"), canvasLabel: asciiBytes("code-editor-canvas-4"), title: asciiBytes("Native SDK Code Editor"), width: 1120, height: 720, minWidth: 760, minHeight: 480, titlebar: "hidden_inset_tall", onCloseCommand: asciiBytes("close-editor-4") })] : []),
    ...(model.sessions[4]!.open ? [windowDescriptor({ label: asciiBytes("code-editor-5"), canvasLabel: asciiBytes("code-editor-canvas-5"), title: asciiBytes("Native SDK Code Editor"), width: 1120, height: 720, minWidth: 760, minHeight: 480, titlebar: "hidden_inset_tall", onCloseCommand: asciiBytes("close-editor-5") })] : []),
  ];
}
export function page0(model: Model): EditorPage { return project(model.sessions[0]!.browser, 0); }
export function page1(model: Model): EditorPage { return project(model.sessions[1]!.browser, 1); }
export function page2(model: Model): EditorPage { return project(model.sessions[2]!.browser, 2); }
export function page3(model: Model): EditorPage { return project(model.sessions[3]!.browser, 3); }
export function page4(model: Model): EditorPage { return project(model.sessions[4]!.browser, 4); }

/** Map source-window identity before reducing its input; null leaves the current owner. */
export function windowContext(model: Model, label: Uint8Array): WindowContextMsg | null {
  const labels = [asciiBytes("main"), asciiBytes("code-editor-2"), asciiBytes("code-editor-3"), asciiBytes("code-editor-4"), asciiBytes("code-editor-5")];
  for (let at = 0; at < labels.length; at += 1) if (bytesEqual(label, labels[at]!) && model.active_session !== at) return { kind: "window_changed", label };
  return null;
}
