// Load the SDK's transpiler-tier TypeScript modules under ANY install layout.
//
// Node's own type stripping refuses node_modules-resident `.ts` by design
// (ERR_UNSUPPORTED_NODE_MODULES_TYPE_STRIPPING), and outside node_modules it
// only became the default in Node 22.18. Every script that imports the
// frontend must therefore strip with the transpiler's own exact-pinned
// TypeScript compiler, resolved by node's ancestor `node_modules` walk from
// the importing module's location: a repo checkout's packages/core install,
// or the npm-installed CLI's own dependency. This is the same load hook
// build/ts_run.mjs registers for the app-build tier; keeping it in one module
// means the external-compile staging script and the runner cannot drift.
import module, { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const defaultToolchainTeaching = (origin) =>
  `the transpiler's TypeScript toolchain (@typescript/old) does not resolve from ${origin} - on a repo checkout, run \`npm ci --include=dev\` in packages/core.`;

/// Register a synchronous load hook that transpiles every `.ts` module
/// with the SDK's pinned TypeScript. Call before importing any `.ts` module.
/// Returns normally on success and throws a teaching Error when this Node
/// build cannot host the hook.
export function registerTsModules(origin = import.meta.url, options = {}) {
  const originPath = origin instanceof URL ? fileURLToPath(origin) : origin;
  if (typeof module.registerHooks !== "function") {
    const error = new Error(options.missingHooksMessage ??
      `TypeScript modules need Node.js 24+ with module.registerHooks; you're running ${process.version} - upgrade or reinstall node and re-run.`);
    error.code = "ERR_NATIVE_SDK_TS_HOOKS";
    throw error;
  }
  const requireFrom = createRequire(originPath);
  let ts = null;
  module.registerHooks({
    load(url, context, nextLoad) {
      if (!url.startsWith("file:") || !url.endsWith(".ts")) return nextLoad(url, context);
      const filePath = fileURLToPath(url);
      if (ts === null) {
        try {
          ts = requireFrom("@typescript/old");
        } catch {
          throw new Error(options.missingToolchainMessage ?? defaultToolchainTeaching(originPath));
        }
      }
      const { outputText } = ts.transpileModule(readFileSync(filePath, "utf8"), {
        fileName: filePath,
        compilerOptions: {
          target: ts.ScriptTarget.ESNext,
          module: ts.ModuleKind.ESNext,
          verbatimModuleSyntax: true,
        },
      });
      return { format: "module", source: outputText, shortCircuit: true };
    },
  });
}
