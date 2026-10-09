import { asciiBytes } from "@native-sdk/core";
import { concat } from "./editor.ts";
import type { DirectoryItem } from "./explorer.ts";
export interface CapabilityReply {
  readonly valid: boolean; readonly owner: number; readonly token: Uint8Array; readonly error: Uint8Array;
  readonly path: Uint8Array; readonly items: readonly DirectoryItem[];
  readonly truncated: boolean; readonly had_errors: boolean;
}
function u16(value: number): Uint8Array { const bytes = new Uint8Array(2); bytes[0] = value & 255; bytes[1] = (value >>> 8) & 255; return bytes; }
function framed(bytes: Uint8Array): Uint8Array { return concat([u16(bytes.length), bytes]); }
export function folderRequest(owner: number, token: Uint8Array, path: Uint8Array): Uint8Array {
  const prefix = new Uint8Array(2); prefix[0] = 2; prefix[1] = owner;
  const header = concat([prefix, framed(token)]);
  return concat([header, framed(asciiBytes("Open Folder")), framed(path)]);
}
export function directoryRequest(owner: number, token: Uint8Array, path: Uint8Array, remaining: number, nameLimit: number): Uint8Array {
  const prefix = new Uint8Array(2); prefix[0] = 2; prefix[1] = owner;
  const header = concat([prefix, framed(token)]);
  return concat([header, u16(remaining), u16(nameLimit), framed(path)]);
}
export function renameRequest(owner: number, token: Uint8Array, oldPath: Uint8Array, newPath: Uint8Array): Uint8Array {
  const prefix = new Uint8Array(2); prefix[0] = 2; prefix[1] = owner;
  const header = concat([prefix, framed(token)]);
  return concat([header, framed(oldPath), framed(newPath)]);
}
export function windowRequest(owner: number, token: Uint8Array, label: Uint8Array): Uint8Array {
  const prefix = new Uint8Array(2); prefix[0] = 2; prefix[1] = owner;
  const header = concat([prefix, framed(token)]);
  return concat([header, framed(label)]);
}
function read16(bytes: Uint8Array, at: number): number { return bytes[at]! + bytes[at + 1]! * 256; }
export function capabilityReply(bytes: Uint8Array, operation: "folder" | "directory" | "rename" | "window"): CapabilityReply {
  const invalid: CapabilityReply = { valid: false, owner: 0, token: asciiBytes(""), error: asciiBytes("invalid_result"), path: asciiBytes(""), items: [], truncated: false, had_errors: false };
  if (bytes.length < 6 || bytes[0] !== 2 || bytes[1]! >= 5) return invalid;
  const tokenLength = read16(bytes, 2);
  if (tokenLength < 1 || tokenLength > 32 || 6 + tokenLength > bytes.length) return invalid;
  const owner = bytes[1]!, token = bytes.slice(4, 4 + tokenLength);
  const errorLength = read16(bytes, 4 + tokenLength); let at = 6 + tokenLength;
  if (at + errorLength > bytes.length) return invalid;
  const error = bytes.slice(at, at + errorLength); at += errorLength;
  if (operation === "rename" || operation === "window" || errorLength > 0) return at === bytes.length ? { ...invalid, valid: true, owner, token, error } : invalid;
  if (operation === "folder") {
    if (at + 2 > bytes.length) return invalid;
    const length = read16(bytes, at); at += 2;
    return at + length === bytes.length ? { ...invalid, valid: true, owner, token, error, path: bytes.slice(at) } : invalid;
  }
  if (at + 3 > bytes.length) return invalid;
  const flags = bytes[at]!, count = read16(bytes, at + 1); at += 3;
  if (flags > 3 || count > 128) return invalid;
  const items: DirectoryItem[] = [];
  for (let i = 0; i < count; i += 1) {
    if (at + 3 > bytes.length || bytes[at]! > 1) return invalid;
    const directory = bytes[at] === 1, length = read16(bytes, at + 1); at += 3;
    if (at + length > bytes.length) return invalid;
    items.push({ directory, name: bytes.slice(at, at + length) }); at += length;
  }
  return at === bytes.length ? { ...invalid, valid: true, owner, token, error, items, truncated: (flags & 1) !== 0, had_errors: (flags & 2) !== 0 } : invalid;
}
