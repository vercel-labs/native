import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
import { test } from "node:test";
const root = new URL("../", import.meta.url);
const source = ["runtime_policy.ts", "builtin_coordination.ts"].map(name => readFileSync(new URL(`src/${name}`, root), "utf8")).join("\n");
const { native_window_policy: dispatch } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source)).toString("base64")}`);
function text(mode: number, value: Uint8Array | string, context = 0): Uint8Array {
  const bytes = typeof value === "string" ? Buffer.from(value) : value;
  const result = new Uint8Array(16 + bytes.length);
  result.set([89, 1, mode, context]); new DataView(result.buffer).setBigUint64(8, BigInt(bytes.length), true); result.set(bytes, 16); return result;
}
function route(value: Uint8Array | string, context = 0) { return dispatch(text(0, value, context)) as Uint8Array; }
function strings(result: Uint8Array) {
  const v = new DataView(result.buffer), a = v.getUint16(12, true), b = v.getUint16(14, true);
  assert.equal(result.length, 16 + a + b);
  return [Buffer.from(result.subarray(16, 16 + a)).toString(), Buffer.from(result.subarray(16 + a)).toString()];
}
test("builtin routing recognizes every family and exact supported verb", () => {
  const groups = [
    ["command", ["invoke", "list"]], ["window", ["list", "create", "focus", "close"]],
    ["view", ["create", "list", "update", "setFrame", "setVisible", "focus", "focusNext", "focusPrevious", "close"]],
    ["webview", ["create", "list", "setFrame", "navigate", "setZoom", "setLayer", "close"]],
    ["platform", ["supports"]], ["dialog", ["openFile", "saveFile", "showMessage"]],
    ["os", ["openUrl", "showNotification", "revealPath", "addRecentDocument", "clearRecentDocuments"]],
    ["clipboard", ["readText", "writeText", "read", "write"]], ["credentials", ["set", "get", "delete"]],
  ] as const;
  const verbs = new Set<number>();
  for (let i = 0; i < groups.length; i++) for (const verb of groups[i][1]) {
    const value = route(`native-sdk.${groups[i][0]}.${verb}`); assert.equal(value[8], i + 1); assert.ok(value[9] > 0); verbs.add(value[9]);
  }
  assert.equal(verbs.size, 38);
});
test("builtin family admission retains exact byte prefixes and legacy permissions", () => {
  for (const [value, family, permission] of [["native-sdk.command.",1,1], ["native-sdk.window.",2,2], ["native-sdk.view.",3,3], ["native-sdk.webview.",4,2], ["native-sdk.platform.",5,2], ["native-sdk.dialog.",6,0], ["native-sdk.os.",7,0], ["native-sdk.clipboard.",8,0], ["native-sdk.credentials.",9,0]] as const) {
    const plan = route(value); assert.equal(plan[8], family); assert.equal(plan[9], 0); assert.equal(plan[10], permission);
    assert.equal(route(value + "unknown")[8], family);
    assert.equal(route(value.slice(0,-1))[8], 0);
  }
  for (const value of ["", "Native-sdk.view.list", "native-sdk.viewing.list", " native-sdk.view.list"]) assert.equal(route(value)[8], 0);
  assert.equal(route(new Uint8Array([255,0,118,105,101,119]))[8], 0);
});
test("builtin routing rejects verb suffix aliases while preserving denial and wrong-family text", () => {
  const value = route("native-sdk.view.focus\0"); assert.equal(value[8], 3); assert.equal(value[9], 0);
  assert.deepEqual(strings(value), ["View API is not permitted", "Unknown view command"]);
  assert.deepEqual(strings(route("native-sdk.window.list", 1)), ["Command API is not permitted", "Unknown command command"]);
  assert.equal(route("native-sdk.view.setText")[9], 0);
});
test("builtin error projection preserves error-code asymmetries and complete teaching messages", () => {
  for (const [name, code, message] of [["WindowNotFound",0,"Window was not found"], ["NavigationDenied",0,"URL is not allowed by navigation policy"], ["NoSpaceLeft",5,"Native response buffer is too small"], ["BuiltinWindowListFailed",5,"Failed to list windows"], ["CreateFailed",5,"Native view creation failed"], ["CredentialNotFound",5,"Credential was not found"], ["UnknownError",5,"Native command failed"]] as const) {
    const value = dispatch(text(1, name)); assert.equal(value[8], code);
    assert.equal(Buffer.from(value.subarray(16)).toString(), message);
    assert.equal(new DataView(value.buffer).getUint32(12,true), value.length-16);
  }
  const value = dispatch(text(1,"WebViewLayerNotBuilt")); assert.equal(value[8],0); assert.match(Buffer.from(value.subarray(16)).toString(), /add "webview" to \.capabilities/);
});
test("notification actions preserve admission truth table and exact refusal text", () => {
  for (let action=0; action<2; action++) for (let granted=0; granted<2; granted++) {
    const value = dispatch(new Uint8Array([89,1,2,action,granted,0,0,0]));
    assert.equal(value[8], action && !granted ? 1 : 0);
    assert.equal(Buffer.from(value.subarray(16)).toString(), action && !granted ? "Notification actions require command invoke permission" : "");
  }
});
test("builtin routing compares full long names and raw non-UTF8 bytes without truncation", () => {
  const bytes = Buffer.concat([Buffer.from("native-sdk.credentials."), Buffer.alloc(16385,255)]);
  const value = route(bytes); assert.equal(value[8],9); assert.equal(value[9],0);
  const failure=dispatch(text(1,bytes)); assert.equal(failure[8],5); assert.equal(Buffer.from(failure.subarray(16)).toString(),"Native command failed");
});
test("builtin coordination refuses malformed framing before returning selectors", () => {
  for (const index of [0,1,2,3,4,5,6,7,8,12]) {
    const bad=text(0,"native-sdk.view.list"); bad[index]=255; assert.throws(()=>dispatch(bad));
  }
  assert.throws(()=>dispatch(new Uint8Array([89,1,2,2,0,0,0,0])));
  assert.throws(()=>dispatch(text(1,"WindowNotFound",1)));
});
