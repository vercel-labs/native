// Resolve a compiler command into the argv prefix used by the core and
// service drivers. On Windows npm exposes package bins as .cmd shims, which
// Node's spawnSync cannot execute directly. For the installed scriptc bin,
// unwrap the shim through the package's own `bin` declaration and execute the
// declared JavaScript entry with Node. This preserves published-bin changes
// (for example dist/main.js -> dist/bootstrap.js) without a shell boundary.

import fs from "node:fs";
import path from "node:path";

function npmBinJavaScript(command) {
  const binName = path.basename(command).replace(/\.(?:cmd|bat)$/i, "");
  const nodeModules = path.dirname(path.dirname(command));
  const packageJson = path.join(nodeModules, binName, "package.json");
  let manifest;
  try {
    manifest = JSON.parse(fs.readFileSync(packageJson, "utf8"));
  } catch {
    return null;
  }
  const declared = typeof manifest.bin === "string" ? manifest.bin : manifest.bin?.[binName];
  if (typeof declared !== "string" || declared.length === 0 || path.isAbsolute(declared)) return null;
  const packageRoot = path.dirname(packageJson);
  const target = path.resolve(packageRoot, declared);
  const relative = path.relative(packageRoot, target);
  if (relative === "" || relative === ".." || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) return null;
  try {
    if (!fs.statSync(target).isFile()) return null;
  } catch {
    return null;
  }
  return target;
}

export function compilerArgv(command, options = {}) {
  const platform = options.platform ?? process.platform;
  const node = options.node ?? process.execPath;
  const env = options.env ?? process.env;
  const argv = fs.existsSync(command) ? [command] : command.split(/\s+/);
  if (platform !== "win32" || argv.length !== 1 || !/\.(?:cmd|bat)$/i.test(argv[0])) return argv;

  const npmTarget = npmBinJavaScript(argv[0]);
  if (npmTarget !== null) return [node, npmTarget];

  // Development overrides may name an arbitrary batch file rather than an
  // npm bin. cmd.exe is the Windows executable format's required launcher.
  return [env.ComSpec ?? env.COMSPEC ?? "cmd.exe", "/d", "/s", "/c", argv[0]];
}
