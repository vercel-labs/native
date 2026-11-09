import assert from "node:assert/strict";
import test from "node:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { checkAppViews, entryChannelExports, unusedState } from "../src/view_check.ts";
import { SubsetChecker } from "../src/checker.ts";
import { compileViewBundle, type ViewContract, type ViewUsage } from "../src/view_frontend.ts";

const contract: ViewContract & { model_unbound: string[]; msg: ViewContract["msg"] & { unbound: string[] } } = {
  model: "Model",
  types: {
    structs: [
      { name: "Model", fields: [
        { name: "count", type: { kind: "i64" } },
        { name: "title", type: { kind: "bytes" } },
        { name: "items", type: { kind: "slice", elem: { kind: "node", name: "Item" } } },
        { name: "selection", type: { kind: "value", name: "Selection" } },
        { name: "nextId", type: { kind: "i64" } },
        { name: "hidden", type: { kind: "bool" } },
      ] },
      { name: "Item", fields: [{ name: "id", type: { kind: "i64" } }, { name: "label", type: { kind: "bytes" } }] },
      { name: "Selection", fields: [{ name: "index", type: { kind: "i64" } }] },
    ],
  },
  model_helpers: [
    { name: "total", params: [], returns: { kind: "i64" } },
    { name: "unusedHelper", params: [], returns: { kind: "bytes" } },
    { name: "rowExtent", params: [{ kind: "i64" }], returns: { kind: "f64" } },
  ],
  model_unbound: ["nextId"],
  msg: {
    arms: ["add", "remove", "tick", "loaded"].map(name => ({ name, payload: { kind: "void" } })),
    unbound: ["tick"],
  },
};

function usageOf(markup: string, sources = new Map<string, string>()): ViewUsage {
  const usage: ViewUsage = { model: new Set(), msg: new Set() };
  compileViewBundle(markup, contract, { sources }, [], usage);
  return usage;
}

test("view compilation records model names and dispatched Msg kinds", () => {
  const usage = usageOf('<column><text>{title} {total}</text><button on-press="add">Add</button>' +
    '<for each="items" as="item" key="id"><text>{item.label}</text></for></column>');
  assert.deepEqual([...usage.model].sort(), ["items", "title", "total"]);
  assert.deepEqual([...usage.msg], ["add"]);
});

test("a loop variable that shadows a model field does not count as a model read", () => {
  const usage = usageOf('<column><for each="items" as="count" key="id"><text>{count.label}</text></for></column>');
  assert.deepEqual([...usage.model], ["items"]);
});

test("imported templates contribute their bindings", () => {
  const sources = new Map([["parts.native", '<template name="badge"><text>{selection.index}</text></template>']]);
  const usage = usageOf('<import src="parts.native"/><column><use template="badge"/></column>', sources);
  assert.ok(usage.model.has("selection"));
});

test("unused state lists every unbound field, helper and Msg kind except the opt-outs", () => {
  const usage: ViewUsage = { model: new Set(["count", "title"]), msg: new Set(["add"]) };
  assert.deepEqual(unusedState(contract, usage), [
    'model list "items" (Item[]) is never iterated in markup - use it with for each, or list it in viewUnbound if only update or effect logic reads it',
    'model field "selection" (Selection) has no markup binding into any of its fields - bind one, or list it in viewUnbound if only update or effect logic reads it',
    'model field "hidden" (boolean) is never bound in markup - bind it, or list it in viewUnbound if only update or effect logic reads it',
    'model helper "total" (returns number) is never bound in markup - bind it, remove it, or list it in viewUnbound if only update or effect logic calls it',
    'model helper "unusedHelper" (returns string) is never bound in markup - bind it, remove it, or list it in viewUnbound if only update or effect logic calls it',
    'Msg kind "remove" is never dispatched from markup - wire it to an on-* event, or list it in viewUnbound if only update, subscriptions or effects send it',
    'Msg kind "loaded" is never dispatched from markup - wire it to an on-* event, or list it in viewUnbound if only update, subscriptions or effects send it',
  ]);
});

function appDir(files: Record<string, string>): string {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-view-check-"));
  for (const [name, source] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(root, name)), { recursive: true });
    fs.writeFileSync(path.join(root, name), source);
  }
  return root;
}

test("app checks locate compile failures under the source directory", () => {
  const root = appDir({ "app.native": "<column>\n  <text>{titel}</text>\n</column>\n" });
  try {
    const result = checkAppViews(contract, root);
    assert.equal(result.error, "src/app.native:2:3: error: compiled TypeScript view: unknown binding titel");
    assert.deepEqual(result.warnings, []);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("app checks include secondary windows and skip service sources", () => {
  const root = appDir({
    "app.native": '<column><text>{title} {count} {total} {unusedHelper} {hidden} {selection.index}</text><button on-press="add">Add</button></column>',
    "windows/inspector.native": '<column><for each="items" as="item"><button on-press="remove">{item.label}</button></for></column>',
    "services/ignored.native": "<not markup",
  });
  try {
    const result = checkAppViews(contract, root);
    assert.equal(result.error, null);
    assert.deepEqual(result.warnings, [
      'Msg kind "loaded" is never dispatched from markup - wire it to an on-* event, or list it in viewUnbound if only update, subscriptions or effects send it',
    ]);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("an app without a root view fails the check", () => {
  const root = appDir({ "windows/inspector.native": "<column/>" });
  try {
    assert.match(checkAppViews(contract, root).error ?? "", /needs a root view at src\/app\.native/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("host-channel helpers are never reported as unused markup state", () => {
  const withChannels = { ...contract, model_helpers: [...contract.model_helpers, { name: "tokenOverrides", params: [], returns: { kind: "value", name: "ThemeDesignTokenOverrides" } }] };
  const usage: ViewUsage = { model: new Set(["count", "title", "items", "selection", "hidden", "total", "unusedHelper"]), msg: new Set(["add", "remove", "loaded"]) };
  assert.deepEqual(unusedState(withChannels, usage), []);
});

test("the host-channel names match the frontend's entry-only exports", () => {
  const checkerSet = (SubsetChecker as unknown as { entryOnlyExports: ReadonlySet<string> }).entryOnlyExports;
  assert.deepEqual([...entryChannelExports].sort(), [...checkerSet].sort());
});

test("errors in a secondary window view name the file under src/windows", () => {
  const root = appDir({
    "app.native": "<column/>",
    "windows/inspector.native": "<column>\n  <text>{titel}</text>\n</column>\n",
  });
  try {
    assert.equal(checkAppViews(contract, root).error, "src/windows/inspector.native:2:3: error: compiled TypeScript view: unknown binding titel");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("errors in a file a window view imports name the imported file under src/windows", () => {
  const root = appDir({
    "app.native": "<column/>",
    "windows/inspector.native": '<import src="parts/badge.native"/>\n<column><use template="badge"/></column>\n',
    "windows/parts/badge.native": '<template name="badge">\n  <text>{missing}</text>\n</template>\n',
  });
  try {
    assert.equal(checkAppViews(contract, root).error, "src/windows/parts/badge.native:2:3: error: compiled TypeScript view: unknown binding missing");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("errors in a file the root view imports name the imported file under src", () => {
  const root = appDir({
    "app.native": '<import src="components/badge.native"/>\n<column><use template="badge"/></column>\n',
    "components/badge.native": '<template name="badge">\n  <text>{missing}</text>\n</template>\n',
  });
  try {
    assert.equal(checkAppViews(contract, root).error, "src/components/badge.native:2:3: error: compiled TypeScript view: unknown binding missing");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("bundle errors without a location keep the plain error form", () => {
  const root = appDir({ "app.native": "<column/>", [`windows/${"w".repeat(65)}.native`]: "<column/>" });
  try {
    assert.equal(checkAppViews(contract, root).error, "error: compiled TypeScript view: invalid or duplicate window label");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
