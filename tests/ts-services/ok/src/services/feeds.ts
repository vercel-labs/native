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

/** @deadlineMs 250 */
export function queuedBlocker(cancel: ServiceCancellation): ParseResult {
  fs.writeFileSync("queued-blocker.started", "ready");
  while (true) cancel.throwIfCancelled();
}

/** @deadlineMs 100 */
export function queuedProbe(): ParseResult {
  fs.writeFileSync("queued-probe.started", "unexpected");
  return parse({ source: new Uint8Array([102, 101, 101, 100]), caseSensitive: false });
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

/** @deadlineMs 10000 */
export function slow(request: ParseRequest): ParseResult {
  const start = Date.now();
  while (Date.now() - start < 300) {}
  return parse(request);
}

// Appends `s<tag>;` then `e<tag>;` around a short busy wait to the log file
// named by the request (`<absolute path>|<tag>`), so a harness can prove
// same-key FIFO with no interleaving.
export function order(request: ParseRequest): ParseResult {
  const text = new TextDecoder().decode(request.source);
  const separator = text.indexOf("|");
  const logPath = text.slice(0, separator);
  const tag = text.slice(separator + 1);
  const fd = fs.openSync(logPath, "a");
  fs.writeSync(fd, `s${tag};`);
  const start = Date.now();
  while (Date.now() - start < 20) {}
  fs.writeSync(fd, `e${tag};`);
  fs.closeSync(fd);
  return parse(request);
}

// Keeps running briefly after observing cancellation, so the pool suite can
// prove a replacement with the same key does not overlap the old dispatch.
/** @deadlineMs 10000 */
export function cancelOrder(request: ParseRequest, cancel: ServiceCancellation): ParseResult {
  const text = new TextDecoder().decode(request.source);
  const separator = text.indexOf("|");
  const logPath = text.slice(0, separator);
  const tag = text.slice(separator + 1);
  const fd = fs.openSync(logPath, "a");
  fs.writeSync(fd, `s${tag};`);
  while (!cancel.cancelled()) {}
  const start = Date.now();
  while (Date.now() - start < 50) {}
  fs.writeSync(fd, `e${tag};`);
  fs.closeSync(fd);
  cancel.throwIfCancelled();
  return parse(request);
}

// A detected runtime trap (typed-array read out of bounds) that no catch
// can absorb: the in-process suite proves it poisons exactly one instance.
export function trap(): ParseResult {
  const tiny = new Uint8Array(1);
  let index = 1;
  if (tiny[0] === 0) index = 9;
  const value = tiny[index];
  return { bytes: new Uint8Array([value]), matches: false, facts: value };
}

// Like `hang`, but the started marker lands at the absolute path the
// request names — in-process services run with the app process's working
// directory, so relative marker paths belong to the child-carrier tests.
/** @deadlineMs 75 */
export function hangAt(request: ParseRequest, cancel: ServiceCancellation): ParseResult {
  fs.writeFileSync(new TextDecoder().decode(request.source), "ready");
  while (true) cancel.throwIfCancelled();
}

// Ignores its cooperative token for one second, far past the grace: the
// in-process suite proves the instance is abandoned and the pool refills.
/** @deadlineMs 100 */
export function stubborn(request: ParseRequest): ParseResult {
  const start = Date.now();
  while (Date.now() - start < 1000) {}
  return parse(request);
}

// The ordered form makes the abandoned dispatch's physical lifetime visible:
// a same-key replacement must not append until this ignored-token operation
// has really stopped.
/** @deadlineMs 100 */
export function stubbornOrder(request: ParseRequest): ParseResult {
  const text = new TextDecoder().decode(request.source);
  const separator = text.indexOf("|");
  const logPath = text.slice(0, separator);
  const tag = text.slice(separator + 1);
  const fd = fs.openSync(logPath, "a");
  fs.writeSync(fd, `s${tag};`);
  const start = Date.now();
  while (Date.now() - start < 1000) {}
  fs.writeSync(fd, `e${tag};`);
  fs.closeSync(fd);
  return parse(request);
}

// Cooperative park with a long deadline: cancellation tests release it
// through the token, and the marker lands at the absolute path the
// request names.
/** @deadlineMs 10000 */
export function parkAt(request: ParseRequest, cancel: ServiceCancellation): ParseResult {
  fs.writeFileSync(new TextDecoder().decode(request.source), "ready");
  while (true) cancel.throwIfCancelled();
}

// Emits one chunk, then parks on its token: a harness observes the chunk
// while the operation is provably still running, then cancels.
/** @streamBuffer 4 */
export function streamPark(request: ParseRequest, emit: (chunk: ParseChunk) => void, cancel: ServiceCancellation): ParseResult {
  emit({ bytes: request.source, index: 0 });
  while (true) cancel.throwIfCancelled();
}
