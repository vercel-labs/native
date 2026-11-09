import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { InvocationCase } from "./invocation_cases.ts";
export interface InvocationOutcome { status: number | null; diagnostics: string; files: Record<string, string> }
export function invoke(corewire: string, item: InvocationCase): InvocationOutcome {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "native-corewire-invocation-"));
  try {
    fs.writeFileSync(path.join(dir, "input.json"), item.core);
    fs.writeFileSync(path.join(dir, "services.json"), item.services);
    for (const file of ["mirror", "facade", "profile", "effective", "old", "host", "registry", "client", "inproc", "service-profile", "same"]) fs.writeFileSync(path.join(dir, file), "retain");
    for (const subdir of item.directories) fs.mkdirSync(path.join(dir, subdir));
    const result = spawnSync(corewire, item.args, { cwd: dir, encoding: "utf8", maxBuffer: 32 * 1024 * 1024 });
    assert.ifError(result.error); assert.equal(result.signal, null, result.stderr); assert.equal(result.stdout, "");
    const files: Record<string, string> = {};
    function collect(subdir: string): void {
      for (const entry of fs.readdirSync(path.join(dir, subdir), { withFileTypes: true })) {
        const name = subdir ? subdir + "/" + entry.name : entry.name;
        if (entry.isDirectory()) collect(name);
        else files[name] = createHash("sha256").update(fs.readFileSync(path.join(dir, name))).digest("hex");
      }
    }
    collect("");
    // realpath can normalize the temporary root; diagnostic semantics use
    // a portable root spelling without discarding the filename or refusal.
    let diagnostics = result.stderr.replaceAll(fs.realpathSync(dir), ".").replaceAll(dir, ".");
    if (path.sep === "\\") diagnostics = diagnostics.replaceAll("\\", "/");
    return { status: result.status, diagnostics, files };
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}
