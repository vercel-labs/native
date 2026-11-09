// Write the view updates the markup reload battery applies, with the real
// watcher format, for one fixed session:
//
//   view_reload_updates.ts --contract <core.contract.json> --markup <dir> --out <dir>
//
// edited / broken / compiled are what a watcher writes for those edits;
// foreign is a program compiled for a different build, and stale is the
// edited program addressed to another session.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { appViewSources } from "../../packages/core/src/view_sources.ts";
import { compileViewProgram } from "../../packages/core/src/view_frontend.ts";
import { encodeViewProgram } from "../../packages/core/src/view_program.ts";
import { compileViewReload, encodeViewDiagnostic, encodeViewUpdate, viewUpdateKind } from "../../packages/core/src/view_reload.ts";

const args = new Map<string, string>();
for (let i = 2; i < process.argv.length; i += 2) args.set(process.argv[i]!, process.argv[i + 1]!);
const contract = JSON.parse(fs.readFileSync(args.get("--contract")!, "utf8"));
const markup = args.get("--markup")!, out = args.get("--out")!;
const session = 0x5eedn;
const shape = { windows: [], virtual: false };
fs.mkdirSync(out, { recursive: true });

function compile(file: string) {
  const src = fs.mkdtempSync(path.join(os.tmpdir(), "view-reload-fixture-"));
  fs.copyFileSync(path.join(markup, file), path.join(src, "app.native"));
  const result = compileViewReload(appViewSources(src), src, contract, shape);
  fs.rmSync(src, { recursive: true });
  return result;
}
function program(file: string): Uint8Array {
  const result = compile(file);
  if (result.kind !== "program") throw new Error(`${file}: ${result.diagnostic.message}`);
  return result.program;
}
const broken = compile("broken.native");
if (broken.kind !== "diagnostic") throw new Error("broken.native compiled");
const write = (name: string, bytes: Uint8Array) => fs.writeFileSync(path.join(out, name), bytes);
write("edited.update", encodeViewUpdate(session, viewUpdateKind.program, program("edited.native")));
write("broken.update", encodeViewUpdate(session, viewUpdateKind.diagnostic, encodeViewDiagnostic(broken.diagnostic)));
write("compiled.update", encodeViewUpdate(session, viewUpdateKind.compiled, new Uint8Array(0)));
// The edited markup, compiled for some other build of the app.
const { program: foreign } = compileViewProgram(fs.readFileSync(path.join(markup, "edited.native"), "utf8"), contract, {}, []);
write("foreign.update", encodeViewUpdate(session, viewUpdateKind.program, encodeViewProgram(foreign, "another build")));
write("stale.update", encodeViewUpdate(session + 1n, viewUpdateKind.program, program("edited.native")));
