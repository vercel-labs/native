// Module-resolution hook for the devhost: maps the "@native-sdk/core"
// specifier onto this package's own SDK module (sdk/core.ts, the file the
// package's exports map names), and "@native-sdk/core/<lib>" onto the SDK
// library module beside it (sdk/<lib>.ts), so a core under `node` imports
// exactly the modules the transpiler types it against. The hook
// short-circuits BEFORE default resolution on purpose: app trees carry a
// node_modules/@native-sdk/core copy as editor surface (same content,
// materialized by the CLI pre-publish, npm-installed after), but node's
// type stripping refuses .ts files under node_modules, so the devhost
// always imports the SDK checkout's module directly. Relative imports
// inside the core's src/ are real files node resolves itself.

export async function resolve(specifier, context, nextResolve) {
  if (specifier === "@native-sdk/core") {
    return { shortCircuit: true, url: new URL("../sdk/core.ts", import.meta.url).href };
  }
  if (specifier.startsWith("@native-sdk/core/")) {
    const lib = specifier.slice("@native-sdk/core/".length);
    return { shortCircuit: true, url: new URL(`../sdk/${lib}.ts`, import.meta.url).href };
  }
  return nextResolve(specifier, context);
}
