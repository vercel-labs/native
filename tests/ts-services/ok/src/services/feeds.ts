import * as fs from "node:fs";
import escapeStringRegexp from "escape-string-regexp";
import type { ServiceCancellation } from "@native-sdk/core";
import { sharedFailure, type ParseChunk, type ParseRequest, type ParseResult } from "../shared.ts";

export function parse(request: ParseRequest): ParseResult {
  const facts = new Map<string, number>();
  facts.set("now", Date.now());
  facts.set("cwd", fs.existsSync(".") ? 1 : 0);
  const decoded = new TextDecoder().decode(request.source);
  const escaped = escapeStringRegexp(decoded);
  const matches = request.caseSensitive ? /feed/.test(decoded) : /feed/i.test(decoded);
  const text = JSON.stringify({
    matches,
    escaped,
    facts: facts.size,
  });
  return { bytes: new TextEncoder().encode(text), matches, facts: facts.size };
}

export function fail(): ParseResult {
  return sharedFailure();
}

export function exitClean(): ParseResult {
  process.exit(0);
  return { bytes: new Uint8Array(0), matches: false, facts: 0 };
}

/** @deadlineMs 75 */
export function hang(cancel: ServiceCancellation): ParseResult {
  fs.writeFileSync("hang.started", "ready");
  while (true) cancel.throwIfCancelled();
}

/** @streamBuffer 4 */
export function stream(request: ParseRequest, emit: (chunk: ParseChunk) => void): ParseResult {
  for (let index = 0; index < 3; index++) emit({ bytes: request.source, index });
  return parse(request);
}

/** @streamBuffer 4 */
export function streamHang(request: ParseRequest, emit: (chunk: ParseChunk) => void, cancel: ServiceCancellation): ParseResult {
  emit({ bytes: request.source, index: 0 });
  fs.writeFileSync("stream-hang.started", "ready");
  while (true) cancel.throwIfCancelled();
}
