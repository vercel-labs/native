import * as fs from "node:fs";
import { sharedFailure } from "../shared.ts";

export function parse(payload: Uint8Array): Uint8Array {
  const facts = new Map<string, number>();
  facts.set("now", Date.now());
  facts.set("cwd", fs.existsSync(".") ? 1 : 0);
  const text = JSON.stringify({
    matches: /feed/i.test(new TextDecoder().decode(payload)),
    facts: facts.size,
  });
  return new TextEncoder().encode(text);
}

export function fail(): Uint8Array {
  return sharedFailure();
}

export function hang(): Uint8Array {
  fs.writeFileSync("hang.started", "ready");
  while (true) {}
}
