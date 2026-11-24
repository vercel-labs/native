// Runs a command with its own temp directory, then deletes that directory:
//   node tests/scratch.ts npm run -s test:suite
// The tests make their build directories with mkdtemp under os.tmpdir(), which follows TMPDIR,
// so everything one `npm test` writes lands here and goes away with it, whether the run passes,
// fails or is interrupted. Nothing outside this run's own directory is touched.

import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const [command, ...args] = process.argv.slice(2);
if (command === undefined) {
  console.error("usage: node tests/scratch.ts <command> [args...]");
  process.exit(2);
}

const dir = mkdtempSync(join(tmpdir(), "native-run-"));
const cleanup = (): void => rmSync(dir, { recursive: true, force: true });

const child = spawn(command, args, { stdio: "inherit", env: { ...process.env, TMPDIR: dir } });
for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"] as const) {
  process.on(signal, () => child.kill(signal));
}
child.on("error", (err) => {
  console.error(`native: could not run ${command}: ${err.message}`);
  cleanup();
  process.exit(1);
});
child.on("exit", (code, signal) => {
  cleanup();
  process.exit(code ?? (signal !== null ? 1 : 0));
});
