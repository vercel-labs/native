// The clipboard: what a copy puts on the pasteboard and a paste reads back. The host owns the
// pasteboard itself (NSPasteboard on macOS, a file per format on the headless Linux host), so a
// copy made here is visible to the rest of the system, and the other way round.

import { Blob, DataTransfer } from "./dom.ts";
import { hostClipboardRead, hostClipboardWrite } from "./host.ts";

/** What one format of a ClipboardItem holds: text, or a Blob with its bytes. */
export type ClipboardItemValue = string | Blob;

/** One format on the clipboard, read off the pasteboard; "" when it holds none of it. */
export function clipboardFormat(format: string): string {
  let out = "";
  hostClipboardRead(format, (value) => {
    out = value;
  });
  return out;
}

/**
 * The clipboard's contents as a DataTransfer, which is the payload a paste event carries: the
 * formats it holds, text/plain first. An empty clipboard gives a payload with no types.
 */
export function clipboardData(): DataTransfer {
  const dt = new DataTransfer();
  const text = clipboardFormat("text/plain");
  const html = clipboardFormat("text/html");
  if (text !== "") dt.setData("text/plain", text);
  if (html !== "") dt.setData("text/html", html);
  return dt;
}

/**
 * Puts a payload on the clipboard. `fallback` is the text a copy with no text/plain of its own
 * puts there — the selected text, as a browser's copy does.
 */
export function writeClipboardData(dt: DataTransfer, fallback: string = ""): void {
  const text = dt.getData("text/plain");
  hostClipboardWrite(text === "" ? fallback : text, dt.getData("text/html"));
}

/** The text of a clipboard value, whether it was written as text or as a Blob. */
async function valueText(value: ClipboardItemValue): Promise<string> {
  if (typeof value === "string") return value;
  if (value === null || typeof value !== "object") return "";
  return await (value as Blob).text();
}

/**
 * One thing on the clipboard: the formats it holds, keyed by MIME type. The async clipboard API's
 * `write()` takes these; `read()` answers one that holds what the pasteboard has. A value may be
 * text where a browser would demand a Blob, since the pasteboard here holds numbers and strings.
 */
export class ClipboardItem {
  get [Symbol.toStringTag](): string { return "ClipboardItem"; }
  /** The formats it holds, lowercased, in the order they were given. */
  readonly types: string[];
  /** "unspecified" or "inline", as it was asked for. */
  readonly presentationStyle: string;
  private readonly values: ClipboardItemValue[] = [];

  constructor(items: Record<string, ClipboardItemValue>, options: { presentationStyle?: string } = {}) {
    this.types = [];
    this.values = [];
    for (const type of Object.keys(items)) {
      this.types.push(type.toLowerCase());
      this.values.push(items[type]);
    }
    this.presentationStyle = options.presentationStyle === "inline" ? "inline" : "unspecified";
  }

  /** One of the item's formats, as a Blob of its bytes; a type it doesn't hold is a TypeError. */
  async getType(type: string): Promise<Blob> {
    const i = this.types.indexOf(type.toLowerCase());
    if (i < 0) {
      throw new TypeError("Failed to execute 'getType' on 'ClipboardItem': The type '" + type + "' was not found");
    }
    const text = await valueText(this.values[i]);
    return new Blob([text], { type: this.types[i] });
  }

  /** The text of one of its formats, or "" for a type it doesn't hold: what a write puts down. */
  async textOf(type: string): Promise<string> {
    const i = this.types.indexOf(type.toLowerCase());
    return i < 0 ? "" : valueText(this.values[i]);
  }
}

/**
 * `navigator.clipboard`. A native app is the user's own program and the system pasteboard is
 * theirs to use, so nothing here asks for permission or needs a user gesture, unlike a page's.
 */
export class Clipboard {
  get [Symbol.toStringTag](): string { return "Clipboard"; }
  /** The clipboard's text, or "" when it holds none. */
  async readText(): Promise<string> {
    return clipboardFormat("text/plain");
  }

  /** Replaces the clipboard with one string of text. */
  async writeText(text: string): Promise<void> {
    hostClipboardWrite(String(text === null || text === undefined ? "" : text), "");
  }

  /** The clipboard's contents as one item: the formats it holds. Nothing on it gives no items. */
  async read(): Promise<ClipboardItem[]> {
    const payload = clipboardData();
    if (payload.types.length === 0) return [];
    const items: Record<string, Blob> = {};
    for (const type of payload.types) items[type] = new Blob([payload.getData(type)], { type });
    return [new ClipboardItem(items)];
  }

  /** Replaces the clipboard with the first item's text and markup, which is what it can hold. */
  async write(items: ClipboardItem[]): Promise<void> {
    if (items.length === 0) {
      hostClipboardWrite("", "");
      return;
    }
    const item = items[0];
    const text = await item.textOf("text/plain");
    const html = await item.textOf("text/html");
    hostClipboardWrite(text, html);
  }
}
