/** Node test driver for the compiled app host built by `native test`.
 * Import from tests/*.test.ts, never from the deterministic app core.
 */
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import type { ScrollState } from "../sdk/events.ts";

export type JsonValue = null | boolean | number | string | readonly JsonValue[] | { readonly [key: string]: JsonValue };
export interface NativeWidget {
  /** Decimal strings preserve all 64 bits of native identities. */
  readonly id: string;
  readonly view: string;
  readonly window: number;
  readonly role: string;
  readonly name: string;
  readonly text: string;
  /** Applied numeric accessibility value; null for controls without one. */
  readonly value: number | null;
  /** Applied two-axis runtime scroll state; null for other widget kinds. */
  readonly scroll: ScrollState | null;
  readonly enabled: boolean;
  readonly focused: boolean;
  readonly selected: boolean;
  readonly bounds: { readonly x: number; readonly y: number; readonly width: number; readonly height: number };
  readonly actions: Readonly<Record<string, boolean>>;
}
export interface NativeWindow {
  readonly id: number;
  readonly label: string;
  readonly title: string;
  readonly bounds: { readonly x: number; readonly y: number; readonly width: number; readonly height: number };
  readonly focused: boolean;
  readonly hidden: boolean;
}
export interface NativeStatusItem {
  readonly id: number;
  readonly visible: boolean;
  /** Complete native shell bytes; arbitrary bytes remain lossless. */
  readonly iconPath: readonly number[];
  readonly tooltip: readonly number[];
  readonly activationCommand: readonly number[];
  readonly alternateActivationCommand: readonly number[];
  readonly openCommand: readonly number[];
  /** Native presentation and rich menu records, including all optional data.
   * Byte fields are number arrays and native field names are preserved. */
  readonly presentation: Readonly<Record<string, JsonValue>>;
  readonly items: readonly Readonly<Record<string, JsonValue>>[];
}
export interface NativeSnapshot {
  readonly viewBackend: "zig" | "typescript";
  /** Committed native model projection. Bytes are number arrays; tagged unions
   * use the generated mirror's {arm: payload} representation. */
  readonly model: Readonly<Record<string, JsonValue>>;
  readonly fingerprint: string;
  readonly windows: readonly NativeWindow[];
  readonly webViews: readonly {
    readonly window: number; readonly label: string; readonly url: string;
    readonly bounds: NativeWindow["bounds"]; readonly layer: number;
    readonly transparent: boolean; readonly bridgeEnabled: boolean; readonly zoom: number;
  }[];
  readonly contextMenu: NativeContextMenu | null;
  readonly statusItems: readonly NativeStatusItem[];
  readonly widgets: readonly NativeWidget[];
  readonly effects: {
    readonly recorded: number;
    readonly requests: readonly { readonly key: string; readonly name: string; readonly bytes: readonly number[] }[];
    readonly spawns: readonly {
      readonly key: string;
      readonly argv: readonly (readonly number[])[];
      readonly stdin: readonly number[];
      readonly output: "lines" | "collect";
      readonly maxLineBytes: number;
    }[];
    readonly fetches: readonly {
      readonly key: string;
      readonly generation: string;
      readonly method: string;
      readonly url: readonly number[];
      readonly headers: readonly { readonly name: readonly number[]; readonly value: readonly number[] }[];
      readonly body: readonly number[];
      readonly response: "buffered" | "stream";
      readonly timeoutMs: number;
      readonly maxLineBytes: number;
    }[];
    readonly timers: readonly { readonly key: string; readonly intervalMs: number; readonly mode: "one_shot" | "repeating" }[];
    readonly files: readonly { readonly key: string; readonly generation: string; readonly op: "read" | "write" | "append" | "stat" | "delete"; readonly path: string; readonly bytes: readonly number[] }[];
    /** Pending image requests retain exact native identities and owned source bytes. */
    readonly images: readonly { readonly id: string; readonly path: readonly number[]; readonly url: readonly number[]; readonly cachePath: readonly number[]; readonly expectedBytes: string }[];
    readonly clipboards: readonly { readonly key: string; readonly generation: string; readonly op: "read" | "write"; readonly text: readonly number[] }[];
    /** Parked fake database operations, including complete live-query facts.
     * Decimal strings preserve native keys and generation counters exactly. */
    readonly databases: readonly {
      readonly key: string;
      readonly generation: string;
      readonly kind: "query" | "exec" | "live";
      readonly sql: string;
      readonly params: readonly JsonValue[];
      readonly tables: readonly string[];
    }[];
  };
}
export interface NativeContextMenu {
  readonly window: number;
  readonly view: string;
  readonly token: string;
  readonly target: string;
  readonly point: NativePoint;
  readonly items: readonly { readonly id: number; readonly label: readonly number[]; readonly enabled: boolean; readonly separator: boolean }[];
}
export interface NativeReplay {
  readonly events: number;
  readonly effects: number;
  readonly checkpoints: number;
  readonly snapshot: NativeSnapshot;
}
export interface NativeAppOptions {
  /** Existing fixture directory delivered through the framework app-data env
   * channel, with native app-scoped file authorization and journaled replay. */
  readonly appDataDirectory?: string;
  readonly width?: number;
  readonly height?: number;
  readonly wallMs?: number;
  readonly timeoutMs?: number;
  /** Usually supplied by `native test`; useful for external test runners. */
  readonly executable?: string;
}
export interface NativePoint { readonly x: number; readonly y: number }
export interface NativePointerOptions {
  /** Decimal u64 token, including a host's touch-source stamp. */
  readonly pointerId?: string;
  readonly button?: 0 | 1;
  readonly shift?: boolean;
}
interface Reply {
  protocol: number;
  snapshot?: NativeSnapshot;
  replay?: Omit<NativeReplay, "snapshot">;
  closed?: boolean;
}

/** Select exactly one rendered accessibility widget; ambiguity fails the test. */
export function findWidget(snapshot: NativeSnapshot, query: { role: string; name: string; view?: string }): NativeWidget {
  const matches = snapshot.widgets.filter(widget => widget.role === query.role && widget.name === query.name &&
    (query.view === undefined || widget.view === query.view));
  if (matches.length !== 1) throw new Error(`Expected one widget ${JSON.stringify(query)}, found ${matches.length}`);
  return matches[0]!;
}

function token(value: string): string {
  if (!value || /\s|\0/.test(value)) throw new Error("Expected a nonempty automation token");
  return value;
}
function identity(value: string): string {
  if (!value || /[^0-9]/.test(value) || BigInt(value) > 0xffffffffffffffffn) throw new Error("Invalid native identity");
  return value;
}

/** One child process per instance: scriptc's global core state is never shared. */
export class NativeApp implements AsyncDisposable {
  #child: ChildProcessWithoutNullStreams;
  #timeout: number;
  #tail = "";
  #output = Buffer.alloc(0);
  #failed?: Error;
  #closing = false;
  #closed?: Promise<void>;
  #exit: Promise<void>;
  #queue: Promise<unknown> = Promise.resolve();
  #pending: { resolve: (reply: Reply) => void; reject: (error: Error) => void; timer: ReturnType<typeof setTimeout> } | undefined;

  private constructor(executable: string, timeout: number) {
    this.#timeout = timeout;
    this.#child = spawn(executable, [], { stdio: "pipe" });
    this.#exit = new Promise(resolve => this.#child.once("close", (code, signal) => {
      if (!this.#closing || this.#pending || code !== 0 || signal !== null) this.#fail(new Error(`Native test host exited (${signal ?? code})${this.#tail ? `\n${this.#tail}` : ""}`));
      resolve();
    }));
    this.#child.on("error", error => this.#fail(error));
    this.#child.stdin.on("error", error => this.#fail(error));
    this.#child.stderr.on("data", (chunk: Buffer) => { this.#tail = (this.#tail + chunk.toString()).slice(-32768); });
    this.#child.stdout.on("data", (chunk: Buffer) => {
      this.#output = Buffer.concat([this.#output, chunk]);
      if (this.#output.length > 8 * 1024 * 1024) return this.#fail(new Error("Native test response exceeds 8 MiB"));
      const end = this.#output.indexOf(10);
      if (end < 0) return;
      try {
        const reply = JSON.parse(this.#output.subarray(0, end).toString()) as Reply;
        this.#output = this.#output.subarray(end + 1);
        if (reply.protocol !== 1) throw new Error("Native test protocol mismatch; rebuild the test host");
        const pending = this.#pending;
        if (!pending || this.#output.length !== 0) throw new Error("Unexpected native test response");
        this.#pending = undefined;
        clearTimeout(pending.timer);
        pending.resolve(reply);
      } catch (error) { this.#fail(error instanceof Error ? error : new Error(String(error))); }
    });
  }

  static async start(options: NativeAppOptions = {}): Promise<NativeApp> {
    const executable = options.executable ?? process.env.NATIVE_SDK_TEST_HOST;
    if (!executable) throw new Error("Run this test with `native test`, or supply the compiled test host executable");
    const timeout = options.timeoutMs ?? 10000;
    if (!Number.isSafeInteger(timeout) || timeout <= 0 || timeout > 2147483647) throw new Error("Invalid native test timeout");
    const app = new NativeApp(executable, timeout);
    try {
      await app.#snapshot({ op: "start", width: options.width ?? 640, height: options.height ?? 480, wall_ms: options.wallMs ?? 0, app_data_directory: options.appDataDirectory ?? "" });
      return app;
    } catch (error) {
      await app.close();
      throw error;
    }
  }

  #fail(error: Error): void {
    this.#failed ??= error;
    if (this.#pending) {
      clearTimeout(this.#pending.timer);
      this.#pending.reject(this.#failed);
      this.#pending = undefined;
    }
    this.#child.kill("SIGKILL");
  }

  #request(request: object): Promise<Reply> {
    const line = JSON.stringify(request) + "\n";
    const operation = "op" in request ? String(request.op) : "unknown";
    if (Buffer.byteLength(line) > 64 * 1024) return Promise.reject(new Error("Native test request exceeds 64 KiB"));
    const result = this.#queue.then(() => {
      if (this.#failed) throw this.#failed;
      return new Promise<Reply>((resolve, reject) => {
        const timer = setTimeout(() => this.#fail(new Error(`Native test ${operation} request timed out after ${this.#timeout}ms${this.#tail ? `\n${this.#tail}` : ""}`)), this.#timeout);
        this.#pending = { resolve, reject, timer };
        this.#child.stdin.write(line);
      });
    });
    this.#queue = result.catch(() => {});
    return result;
  }

  async #snapshot(request: object): Promise<NativeSnapshot> {
    if (this.#closing) throw new Error("Native test app is closed");
    const reply = await this.#request(request);
    if (!reply.snapshot || !Array.isArray(reply.snapshot.widgets) || typeof reply.snapshot.fingerprint !== "string") {
      const error = new Error("Invalid native test snapshot");
      this.#fail(error);
      throw error;
    }
    return reply.snapshot;
  }

  snapshot(): Promise<NativeSnapshot> { return this.#snapshot({ op: "snapshot" }); }
  /** Present the primary canvas and every live secondary canvas. */
  frame(): Promise<NativeSnapshot> { return this.#snapshot({ op: "frame" }); }
  click(widget: NativeWidget): Promise<NativeSnapshot> {
    return this.#snapshot({ op: "automation", command: `widget-click ${token(widget.view)} ${identity(widget.id)}` });
  }
  /** Pointer down, native hold timer, then the suppressed release. */
  hold(widget: NativeWidget): Promise<NativeSnapshot> {
    return this.#snapshot({ op: "automation", command: `widget-hold ${token(widget.view)} ${identity(widget.id)}` });
  }
  contextPress(widget: NativeWidget): Promise<NativeSnapshot> {
    return this.#snapshot({ op: "automation", command: `widget-context-press ${token(widget.view)} ${identity(widget.id)}` });
  }
  /** Resolve the exact presented native menu, including stale-token behavior.
   * Item 0 dismisses it; other ids come from snapshot.contextMenu.items. */
  contextMenuAction(menu: NativeContextMenu, item: number): Promise<NativeSnapshot> {
    if (!Number.isSafeInteger(item) || item < 0 || item > 0xffffffff) throw new Error("Expected a native context-menu item id");
    return this.#snapshot({ op: "context_menu", window: menu.window, view: token(menu.view), token: identity(menu.token), item });
  }
  /** Deliver the reserved timer while a manually driven gesture is armed. */
  fireHoldTimer(): Promise<NativeSnapshot> { return this.#snapshot({ op: "hold_timer" }); }
  /** Physical pointer input through native hit testing and pointer capture. */
  pointer(widget: NativeWidget, phase: "move" | "down" | "drag" | "up" | "cancel", point: NativePoint, delta: NativePoint = { x: 0, y: 0 }, options: NativePointerOptions = {}): Promise<NativeSnapshot> {
    for (const number of [point.x, point.y, delta.x, delta.y]) if (!Number.isFinite(number)) throw new Error("Expected finite pointer coordinates");
    const pointerId = identity(options.pointerId ?? "0"), button = options.button ?? 0;
    if (button !== 0 && button !== 1) throw new Error("Expected primary or secondary pointer button");
    return this.#snapshot({ op: "input", view: token(widget.view), window: widget.window,
      input: `pointer_${phase}`, x: point.x, y: point.y, delta_x: delta.x, delta_y: delta.y,
      shift: options.shift ?? false, pointer_id: pointerId, button });
  }
  /** A floating pointer move earns hover proof; drag is contact motion. */
  hover(widget: NativeWidget, point: NativePoint, options: NativePointerOptions = {}): Promise<NativeSnapshot> {
    return this.pointer(widget, "move", point, { x: 0, y: 0 }, options);
  }
  /** Leave the gesture active so tests can inspect the projected insertion slot. */
  async beginDrag(widget: NativeWidget, destination: NativePoint): Promise<NativeSnapshot> {
    const origin = { x: widget.bounds.x + widget.bounds.width / 2, y: widget.bounds.y + widget.bounds.height / 2 };
    await this.pointer(widget, "down", origin);
    return this.pointer(widget, "drag", destination, { x: destination.x - origin.x, y: destination.y - origin.y });
  }
  async drag(widget: NativeWidget, destination: NativePoint): Promise<NativeSnapshot> {
    await this.beginDrag(widget, destination);
    return this.pointer(widget, "up", destination);
  }
  wheel(widget: NativeWidget, deltaY: number, deltaX = 0, options: NativePointerOptions = {}): Promise<NativeSnapshot> {
    if (!Number.isFinite(deltaX) || !Number.isFinite(deltaY)) throw new Error("Expected finite wheel deltas");
    const pointerId = identity(options.pointerId ?? "0"), button = options.button ?? 0;
    if (button !== 0 && button !== 1) throw new Error("Expected primary or secondary pointer button");
    return this.#snapshot({ op: "input", view: token(widget.view), window: widget.window, input: "scroll",
      x: widget.bounds.x + widget.bounds.width / 2, y: widget.bounds.y + widget.bounds.height / 2,
      delta_x: deltaX, delta_y: deltaY, pointer_id: pointerId, button, shift: options.shift ?? false });
  }
  key(view: string, key: string): Promise<NativeSnapshot> {
    return this.#snapshot({ op: "automation", command: `widget-key ${token(view)} ${token(key)}` });
  }
  /** Replace through native select-all and text input, preserving whitespace. */
  setText(widget: NativeWidget, text: string): Promise<NativeSnapshot> {
    return this.#textAction(widget, "set_text", text);
  }
  /** UTF-8 byte offsets; native editing snaps offsets to valid boundaries. */
  selectText(widget: NativeWidget, anchor: number, focus: number): Promise<NativeSnapshot> {
    for (const offset of [anchor, focus]) if (!Number.isSafeInteger(offset) || offset < 0) throw new Error("Expected a nonnegative exact byte offset");
    return this.#textAction(widget, "set_selection", `${anchor} ${focus}`);
  }
  composeText(widget: NativeWidget, text: string): Promise<NativeSnapshot> {
    return this.#textAction(widget, "set_composition", text);
  }
  commitComposition(widget: NativeWidget): Promise<NativeSnapshot> {
    return this.#textAction(widget, "commit_composition", "");
  }
  cancelComposition(widget: NativeWidget): Promise<NativeSnapshot> {
    return this.#textAction(widget, "cancel_composition", "");
  }
  #textAction(widget: NativeWidget, action: string, text: string): Promise<NativeSnapshot> {
    return this.#snapshot({ op: "text_action", view: token(widget.view), widget: identity(widget.id), text_action: action, text });
  }
  dropFiles(view: string, paths: readonly string[], window = 1): Promise<NativeSnapshot> {
    return this.#snapshot({ op: "drop", view, paths, window });
  }
  action(widget: NativeWidget, action: "focus" | "press" | "toggle" | "increment" | "decrement" | "dismiss"): Promise<NativeSnapshot> {
    return this.#snapshot({ op: "automation", command: `widget-action ${token(widget.view)} ${identity(widget.id)} ${token(action)}` });
  }
  menu(command: string, window = 1): Promise<NativeSnapshot> { return this.#snapshot({ op: "menu", command, window }); }
  /** OS tray row selection; identifiers are scoped to one status item. */
  statusItemAction(statusItem: number, item: number): Promise<NativeSnapshot> {
    for (const id of [statusItem, item]) if (!Number.isSafeInteger(id) || id <= 0 || id > 4294967295) throw new Error("Invalid status item or row identity");
    return this.#snapshot({ op: "tray", status_item: statusItem, item });
  }
  /** Native user-close notification; routes the window's close command. */
  closeWindow(window: NativeWindow): Promise<NativeSnapshot> {
    if (!Number.isSafeInteger(window.id) || window.id <= 0) throw new Error("Invalid window identity");
    return this.#snapshot({ op: "window_close", window: window.id });
  }
  respond(key: string, bytes: Uint8Array, ok = true): Promise<NativeSnapshot> {
    return this.#snapshot({ op: "host_result", key: identity(key), bytes: Array.from(bytes), ok });
  }
  /** Feed terminal OS results through the native journal/replay boundary. */
  fileResult(key: string, op: "read" | "write" | "append" | "stat" | "delete", bytes: Uint8Array = new Uint8Array(0),
    options: { outcome?: "ok" | "not_found" | "io_failed" | "truncated" | "rejected" | "cancelled" | "disk_full"; total?: number; mtimeMs?: number; exists?: boolean } = {}): Promise<NativeSnapshot> {
    return this.#snapshot({ op: "file_result", key: identity(key), file_op: op, bytes: [...bytes], file_outcome: options.outcome ?? "ok", file_total: options.total ?? 0, file_mtime_ms: options.mtimeMs ?? 0, file_exists: options.exists ?? false });
  }
  /** Feed a complete image terminal; dimensions and status pass through the journal. */
  imageResult(id: string, options: { outcome?: "loaded" | "rejected" | "not_found" | "io_failed" | "connect_failed" | "tls_failed" | "protocol_failed" | "timed_out" | "http_status" | "cancelled" | "too_large" | "unsupported" | "decode_failed" | "registry_full" | "alloc_failed"; width?: number; height?: number; status?: number } = {}): Promise<NativeSnapshot> {
    return this.#snapshot({ op: "image_result", key: identity(id), image_outcome: options.outcome ?? "loaded", image_width: options.width ?? 0, image_height: options.height ?? 0, image_status: options.status ?? 0 });
  }
  /** Decode and register actual image bytes through the native capability. */
  imageBytes(id: string, bytes: Uint8Array): Promise<NativeSnapshot> {
    return this.#snapshot({ op: "image_bytes", key: identity(id), bytes: [...bytes] });
  }
  fetchResult(key: string, status: number, body: Uint8Array,
    options: { outcome?: "ok" | "rejected" | "connect_failed" | "tls_failed" | "protocol_failed" | "timed_out" | "cancelled"; truncated?: boolean } = {}): Promise<NativeSnapshot> {
    return this.#snapshot({ op: "fetch_result", key: identity(key), fetch_status: status, bytes: [...body], fetch_outcome: options.outcome ?? "ok", fetch_truncated: options.truncated ?? false });
  }
  clipboardResult(key: string, text: Uint8Array, outcome: "ok" | "failed" | "rejected" | "cancelled" = "ok"): Promise<NativeSnapshot> {
    return this.#snapshot({ op: "clipboard_result", key: identity(key), bytes: [...text], clipboard_outcome: outcome });
  }
  /** Journal a native stream line, including explicit data-loss facts. */
  streamLine(key: string, bytes: Uint8Array, metadata: { truncated?: boolean; droppedBefore?: number } = {}): Promise<NativeSnapshot> {
    const dropped = metadata.droppedBefore ?? 0;
    if (!Number.isInteger(dropped) || dropped < 0 || dropped > 0xffffffff) throw new Error("Invalid dropped-line count");
    return this.#snapshot({ op: "stream_line", key: identity(key), stream_bytes: [...bytes], truncated: metadata.truncated ?? false, dropped_before: dropped });
  }
  spawnExit(key: string, code = 0, reason: "exited" | "signaled" | "cancelled" | "rejected" | "spawn_failed" = "exited", output = new Uint8Array(0)): Promise<NativeSnapshot> {
    if (!Number.isInteger(code) || code < -2147483648 || code > 2147483647) throw new Error("Invalid spawn exit code");
    return this.#snapshot({ op: "spawn_exit", key: identity(key), exit_code: code, exit_reason: reason, stream_bytes: [...output] });
  }
  /** Feed bounded chunks into a collect-mode process before its terminal. */
  spawnOutput(key: string, bytes: Uint8Array): Promise<NativeSnapshot> {
    return this.#snapshot({ op: "spawn_output", key: identity(key), stream_bytes: [...bytes] });
  }
  fetchResponse(key: string, status = 200, outcome: "ok" | "rejected" | "connect_failed" | "tls_failed" | "protocol_failed" | "timed_out" | "cancelled" = "ok", metadata: { truncated?: boolean; droppedBefore?: number } = {}): Promise<NativeSnapshot> {
    const dropped = metadata.droppedBefore ?? 0;
    if (!Number.isInteger(status) || status < 0 || status > 65535 || !Number.isInteger(dropped) || dropped < 0 || dropped > 0xffffffff)
      throw new Error("Invalid fetch response metadata");
    return this.#snapshot({ op: "fetch_response", key: identity(key), http_status: status, fetch_outcome: outcome, truncated: metadata.truncated ?? false, dropped_before: dropped });
  }
  fireTimer(key: string): Promise<NativeSnapshot> { return this.#snapshot({ op: "timer", key: identity(key) }); }

  /** Deliver a canonical row page or terminal through the journaled database
   * boundary. Malformed pages and mismatched operation kinds fail in native. */
  databaseResult(key: string, kind: "page" | "done" | "exec", bytes: Uint8Array = new Uint8Array(0),
    outcome: "ok" | "constraint" | "busy" | "io_failed" | "corrupt" | "misuse" | "rejected" | "cancelled" = "ok"): Promise<NativeSnapshot> {
    return this.#snapshot({ op: "db_result", key: identity(key), db_kind: kind, db_outcome: outcome, db_bytes: [...bytes] });
  }

  /** Finish recording and replay into a freshly initialized native runtime.
   * Verifies every checkpoint, the final fingerprint, and the final model. Terminal: only
   * snapshot() and close() are available afterward. */
  async verifyReplay(): Promise<NativeReplay> {
    if (this.#closing) throw new Error("Native test app is closed");
    const reply = await this.#request({ op: "replay" });
    if (!reply.replay || !reply.snapshot) throw new Error("Invalid native replay report");
    return { ...reply.replay, snapshot: reply.snapshot };
  }

  close(): Promise<void> {
    if (this.#closed) return this.#closed;
    const failedBeforeClose = this.#failed;
    this.#closing = true;
    this.#closed = (async () => {
      try {
        if (!this.#failed) {
          const reply = await this.#request({ op: "close" });
          if (reply.closed !== true) this.#fail(new Error("Invalid native test shutdown response"));
        }
      } finally {
        this.#child.stdin.end();
        const timer = setTimeout(() => this.#child.kill("SIGKILL"), 1000);
        try { await this.#exit; } finally { clearTimeout(timer); }
        if (!failedBeforeClose && this.#failed) throw this.#failed;
      }
    })();
    return this.#closed;
  }
  async [Symbol.asyncDispose](): Promise<void> { await this.close(); }
}
