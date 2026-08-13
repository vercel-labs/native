#!/usr/bin/env node
// Flatten a static archive whose members include nested archives into one
// plain object archive.
//
// Zig's ELF static-library emission stores `.a` link inputs as archive
// MEMBERS instead of merging their objects (Mach-O emission merges), so an
// Android embed library carrying compiled TypeScript core/service archives
// would hand the NDK linker nested blobs it skips with a warning. This
// driver extracts every member with the supplied zig's llvm-ar (GNU
// long-name members included — the reason system `ar` on macOS is not an
// option), recurses into nested archives, and re-archives the objects with
// a fresh symbol index.
//
//   node merge_static_archives.mjs --zig <zig-exe> --format <gnu|darwin>
//     --out <file.a> --in <file.a> [--in <file.a> ...]

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const args = { in: [] };
for (let i = 2; i < process.argv.length; i += 2) {
  const key = process.argv[i];
  const value = process.argv[i + 1];
  if (!key?.startsWith("--") || value === undefined) {
    console.error("usage: merge_static_archives.mjs --zig <zig-exe> --format <gnu|darwin> --out <file.a> --in <file.a> [--in ...]");
    process.exit(2);
  }
  if (key === "--in") args.in.push(path.resolve(value));
  else args[key.slice(2)] = value;
}
for (const required of ["zig", "format", "out"]) {
  if (!args[required]) {
    console.error(`merge_static_archives.mjs: missing --${required}`);
    process.exit(2);
  }
}
if (args.in.length === 0) {
  console.error("merge_static_archives.mjs: supply at least one --in archive");
  process.exit(2);
}
args.out = path.resolve(args.out);

function ar(arArgs) {
  const result = spawnSync(args.zig, ["ar", ...arArgs], { encoding: "utf8" });
  if (result.status !== 0) {
    console.error(`merge_static_archives.mjs: zig ar ${arArgs[0]} failed:\n${result.stderr ?? ""}`);
    process.exit(result.status ?? 1);
  }
}

const work = fs.mkdtempSync(path.join(os.tmpdir(), "native-merge-archives-"));
try {
  const objects = [];
  let extraction = 0;
  const extract = (archive) => {
    const dir = path.join(work, String(extraction));
    extraction += 1;
    fs.mkdirSync(dir);
    ar(["x", `--output=${dir}`, archive]);
    for (const name of fs.readdirSync(dir)) {
      const member = path.join(dir, name);
      if (name.endsWith(".a")) extract(member);
      else objects.push(member);
    }
  };
  for (const input of args.in) extract(input);
  if (objects.length === 0) {
    console.error("merge_static_archives.mjs: the input archives contain no objects");
    process.exit(1);
  }
  fs.mkdirSync(path.dirname(args.out), { recursive: true });
  fs.rmSync(args.out, { force: true });
  ar(["rcs", `--format=${args.format}`, args.out, ...objects]);
} finally {
  fs.rmSync(work, { recursive: true, force: true });
}
