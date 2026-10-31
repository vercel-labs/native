// Boundary cases shared by compiled CLI conformance and reference capture.
import type { CoreContract, TypeRef, RecordType } from "./core_contract.ts";
export interface Contract extends CoreContract {
  format: number; compiler_version: string; entry: string;
  source_hash: string; build_id: string; model_fingerprint: string;
  has_subscriptions: boolean; has_migrate: boolean; deterministic: boolean; async_free: boolean;
  abi: CoreContract["abi"] & { prefix: string };
}
export interface CoreCase { name: string; input: string; slots?: string[]; mirrorOnly?: boolean }
export function baseContract(): Contract {
  return {
    format: 1, wire_version: 10, abi_version: 2, compiler_version: "0.0.1", entry: "src/core.ts",
    source_hash: "00000000c0ffee00", build_id: "00000000b01dface", model_fingerprint: "00000000a11ce001",
    types: { structs: [{ name: "Model", origin: "src/core.ts", exported: true, fields: [{ name: "count", type: { kind: "i64" } }, { name: "label", type: { kind: "bytes" } }] }], enums: [], unions: [] },
    model: "Model", model_helpers: [], model_unbound: [],
    msg: { name: "Msg", arms: [{ name: "bump", member: null, payload: { kind: "void" } }, { name: "label_set", member: "body", payload: { kind: "bytes" } }], unbound: [] },
    init_returns_cmd: false, update_returns_cmd: true, has_subscriptions: false, has_migrate: false,
    channels: { command_msg: false, frame_msg: false, key_msg: false, pinch_msg: false, drop_msg: false, appearance_msg: null, chrome_msg: null, env_msgs: [] },
    abi: { prefix: "nsc_core_", exports: ["abi_version", "build_id", "set_panic_sink", "init", "collect", "frame_reset", "boot_cmd", "dispatch_void", "dispatch_bytes", "dispatch_number", "dispatch_number_bytes", "dispatch_bool", "dispatch_enum", "dispatch_record", "dispatch_text_input", "dispatch_scroll_state", "subscriptions", "model_snapshot", "persist_snapshot", "restore_model", "migrate_model", "helper_call"], snapshot_format: 1 },
    integer_slots: [{ slot: "Model.count", class: "i64" }], deterministic: true, async_free: true,
  };
}
function record(c: Contract, name: string, kind = "node", origin: string | null = "src/core.ts"): RecordType {
  const r: RecordType = { name, origin, exported: true, fields: [{ name: "flag", type: { kind: "bool" } }, { name: "value", type: { kind: "f64" } }] };
  c.types.structs.push(r); c.types.structs[0].fields.push({ name: "nested", type: { kind, name } }); return r;
}
function enumeration(c: Contract): void {
  c.types.enums.push({ name: "Choice", origin: "src/core.ts", exported: true, members: ["first", "second"] });
  c.types.structs[0].fields.push({ name: "choice", type: { kind: "enum", name: "Choice" } });
}
function union(c: Contract): void {
  c.types.unions.push({ name: "Choice", origin: "src/core.ts", exported: true, arms: [{ name: "empty", member: null, payload: { kind: "void" } }, { name: "number", member: "value", payload: { kind: "f64" } }] });
  c.types.structs[0].fields.push({ name: "choice", type: { kind: "union", name: "Choice" } });
}
function armRecord(c: Contract, name = "Msg_insert", origin: string | null = null): RecordType {
  const r: RecordType = { name, origin, exported: true, fields: [{ name: "flag", type: { kind: "bool" } }, { name: "value", type: { kind: "f64" } }] };
  c.types.structs.push(r); c.msg.arms.push({ name: "insert", member: origin === null ? null : "entry", payload: { kind: "record", name } }); return r;
}
function helper(c: Contract, name = "total", returns: TypeRef = { kind: "f64" }, params: TypeRef[] = []): void {
  c.model_helpers.push({ name, returns, params, arena: false });
}
function encode(c: Contract): string {
  // Absent authored facts decode to null; explicit JSON null is structural
  // invalidity for these optional string fields in format 1.
  return JSON.stringify(c, (key, value) => (key === "origin" || key === "member") && value === null ? undefined : value);
}
export function coreCases(): CoreCase[] {
  const out: CoreCase[] = [];
  function add(name: string, mutate: (c: Contract) => void = () => {}, slots?: string[], mirrorOnly = false): void {
    const c = baseContract(); mutate(c); out.push({ name, input: encode(c), slots, mirrorOnly });
  }
  add("minimal");
  for (const field of ["wire_version", "abi_version", "snapshot_format"]) for (const value of ["-9223372036854775808", "9223372036854775807", "9007199254740993", "-9007199254740993", "0"]) {
    const input = encode(baseContract()).replace(new RegExp(`"${field}":\\d+`), `"${field}":${value}`);
    out.push({ name: `${field}-${value}`, input });
  }
  add("version-and-name-order", c => { c.wire_version = 0; c.abi_version = 0; c.abi.snapshot_format = 0; c.msg.arms.push(c.msg.arms[0]); });
  add("duplicate-table", c => { c.types.enums.push({ name: "Model", origin: null, exported: true, members: ["a", "b"] }); });
  add("duplicate-field", c => { c.types.structs[0].fields.push(c.types.structs[0].fields[0]); });
  add("duplicate-enum", c => { enumeration(c); c.types.enums[0].members.push("first"); });
  add("duplicate-union-arm", c => { union(c); c.types.unions[0].arms.push(c.types.unions[0].arms[0]); });
  add("duplicate-helper", c => { helper(c); helper(c); });
  add("duplicate-env", c => { c.channels.env_msgs = [{ env: "HOME", msg: "label_set" }, { env: "HOME", msg: "label_set" }]; });
  for (const kind of ["node", "value", "enum", "union"]) {
    add(`dangling-${kind}`, c => { c.types.structs[0].fields[1].type = { kind, name: "Missing" }; });
    add(`wrong-kind-${kind}`, c => { c.types.structs[0].fields[1].type = { kind, name: kind === "node" || kind === "value" ? "Choice" : "Model" }; if (kind === "node" || kind === "value") enumeration(c); });
  }
  add("missing-model", c => { c.model = "Missing"; });
  add("enum-model", c => { enumeration(c); c.model = "Choice"; });
  add("unreachable-record", c => { record(c, "Extra"); c.types.structs[0].fields.pop(); });
  add("reach-diagnostic-order", c => { const r = record(c, "Nested"); r.fields = [{ name: "bad", type: { kind: "union", name: "Unknown" } }]; c.types.structs[0].fields.push({ name: "bad", type: { kind: "enum", name: "NoEnum" } }); });
  add("self-cycle", c => { c.types.structs[0].fields.push({ name: "self", type: { kind: "optional", inner: { kind: "node", name: "Model" } } }); });
  add("indirect-cycle", c => { const r = record(c, "Nested"); r.fields.push({ name: "root", type: { kind: "node", name: "Model" } }); });
  add("shared-dag", c => { record(c, "Nested"); c.types.structs[0].fields.push({ name: "other", type: { kind: "node", name: "Nested" } }); });
  for (const size of [254, 255, 256, 257]) add(`named-depth-${size}`, c => {
    c.types.structs[0].fields = []; c.integer_slots = [];
    for (let i = 1; i < size; i++) c.types.structs.push({ name: `N${i}`, origin: "src/core.ts", exported: true, fields: [] });
    for (let i = 0; i < size; i++) c.types.structs[i].fields.push({ name: "next", type: i + 1 < size ? { kind: "node", name: c.types.structs[i + 1].name } : { kind: "bool" } });
  });
  add("combined-wrapper-depth", c => {
    c.types.structs[0].fields = []; c.integer_slots = [];
    for (let i = 1; i < 82; i++) c.types.structs.push({ name: `Depth${i}`, origin: "src/core.ts", exported: true, fields: [] });
    let ref: TypeRef = { kind: "bool" }; for (let i = 0; i < 180; i++) ref = { kind: "optional", inner: ref };
    for (let i = 0; i < 82; i++) c.types.structs[i].fields.push({ name: "next", type: i === 81 ? ref : { kind: "node", name: c.types.structs[i + 1].name } });
  });
  for (const size of [0, 256, 257]) {
    add(`message-bound-${size}`, c => { c.msg.arms = Array.from({ length: size }, (_, i) => ({ name: `arm${i}`, member: null, payload: { kind: "void" } })); });
    add(`enum-bound-${size}`, c => { enumeration(c); c.types.enums[0].members = Array.from({ length: size }, (_, i) => `member${i}`); });
    add(`union-bound-${size}`, c => { union(c); c.types.unions[0].arms = Array.from({ length: size }, (_, i) => ({ name: `arm${i}`, member: null, payload: { kind: "void" } })); });
  }
  add("number-bytes-equal", c => { c.msg.arms[0].payload = { kind: "number_bytes", number_field: "same", bytes_field: "same", number_class: "f64" }; });
  for (const kind of ["void", "node", "value"]) add(`scalar-${kind}`, c => { c.msg.arms[0].member = "value"; c.msg.arms[0].payload = { kind: "scalar", type: { kind, name: "Model" } }; });
  for (const wrap of ["plain", "optional", "slice"]) add(`void-field-${wrap}`, c => { c.types.structs[0].fields[1].type = wrap === "plain" ? { kind: "void" } : { kind: wrap, inner: { kind: "void" }, elem: { kind: "void" } }; });
  add("void-helper-return", c => { helper(c, "total", { kind: "void" }); });
  add("unbound-missing", c => { c.model_unbound = ["absent"]; c.msg.unbound = ["absent"]; });
  add("unbound-helper", c => { helper(c); c.model_unbound = ["total"]; });
  add("unbound-field-shadow", c => { c.types.structs[0].fields[1].name = "label_set"; c.msg.unbound = ["label_set"]; });
  add("unbound-helper-shadow", c => { helper(c, "label_set"); c.msg.unbound = ["label_set"]; });
  for (const channel of ["appearance_msg", "chrome_msg"] as const) for (const name of ["absent", "bump", "label_set"]) add(`${channel}-${name}`, c => { c.channels[channel] = name; });
  add("appearance-shape-and-chrome-order", c => { c.channels.appearance_msg = "bump"; c.msg.arms[0].payload = { kind: "scalar", type: { kind: "bool" } }; c.msg.arms[0].member = "value"; c.channels.chrome_msg = "label_set"; });
  for (const name of ["absent", "bump", "label_set"]) add(`env-${name}`, c => { c.channels.env_msgs = [{ env: "APP_VALUE", msg: name }]; });
  for (const channel of ["command_msg", "frame_msg", "key_msg", "pinch_msg", "drop_msg"] as const) {
    add(`channel-missing-${channel}`, c => { c.channels[channel] = true; });
    add(`channel-unwired-${channel}`, c => { c.abi.exports.push(channel); });
    add(`channel-wired-${channel}`, c => { c.channels[channel] = true; c.abi.exports.push(channel); });
  }
  add("abi-missing", c => { c.abi.exports.splice(3, 1); });
  add("abi-unknown", c => { c.abi.exports.push("unknown"); });
  add("abi-duplicate", c => { c.abi.exports.push("helper_call"); });
  add("abi-order", c => { c.abi.exports.push("native_window_view", "native_view"); });
  add("abi-native-views", c => { c.abi.exports.push("native_view", "native_window_view"); });
  for (const slot of ["Missing.field", "Model.label", "Model.count.extra", "Msg.bump", "Msg.label_set", "helpers.missing.return", "Model", ".count", "Model."]) add(`slot-${slot}`, c => { c.integer_slots.push({ slot, class: "i64" }); });
  add("slot-missing", c => { c.integer_slots = []; });
  add("slot-duplicate", c => { c.integer_slots.push(c.integer_slots[0]); });
  add("slot-unsigned", c => { c.integer_slots[0].class = "u64"; });
  add("slot-dotted", c => { c.types.structs[0].fields[0].name = "with.dot"; c.integer_slots[0].slot = "Model.with.dot"; });
  add("slot-ambiguous", c => { c.msg.name = "Model"; c.msg.arms[0].name = "count"; c.msg.arms[0].payload = { kind: "number", class: "i64" }; c.msg.arms[0].member = "value"; });
  for (const kind of ["bool", "f64", "bytes", "enum", "union", "node", "slice", "optional"]) add(`slot-target-${kind}`, c => {
    if (kind === "enum") enumeration(c); if (kind === "union") union(c); if (kind === "node") record(c, "Nested");
    c.types.structs[0].fields.push({ name: "target", type: { kind, name: kind === "node" ? "Nested" : "Choice", elem: { kind: "i64" }, inner: { kind: "i64" } } });
    c.integer_slots.push({ slot: "Model.target", class: "i64" });
  });
  for (const kind of ["number", "number_bytes", "scalar"]) add(`integer-message-${kind}`, c => {
    c.msg.arms[0].member = "value"; c.msg.arms[0].payload = { kind, class: "i64", number_class: "i64", number_field: "id", bytes_field: "body", type: { kind: "optional", inner: { kind: "i64" } } };
    c.integer_slots.push({ slot: kind === "number_bytes" ? "Msg.bump.id" : "Msg.bump", class: "u64" });
  });
  for (const index of ["0", "+0", "00", "0_", "_0", "0__0", "+_0", "1", "999999999999999999999", "-0", "-00", "-1"]) add(`helper-param-index-${index}`, c => {
    helper(c, "total", { kind: "i64" }, [{ kind: "i64" }]); c.integer_slots.push({ slot: "helpers.total.return", class: "i64" }, { slot: "helpers.total.params[0]", class: "i64" });
    if (index !== "0") c.integer_slots.push({ slot: `helpers.total.params[${index}]`, class: "i64" });
  });
  for (const name of ["std", "rt", "view_unbound", "msg_tags", "p0", "FrameEvent", "nativeView", "nativeTextPolicy", "UpdateResult", "Model", "Msg"]) add(`mirror-name-${name}`, c => { record(c, name); if (name === "p0") helper(c, "total", { kind: "f64" }, [{ kind: "f64" }]); });
  add("mirror-view-reserved", c => { record(c, "nativeView"); c.abi.exports.push("native_view"); });
  add("mirror-policy-reserved", c => { record(c, "nativeTextPolicy"); c.abi.exports.push("native_text_policy"); });
  add("mirror-helper-field", c => { helper(c, "label"); });
  add("mirror-helper-type", c => { record(c, "Nested"); helper(c, "Nested"); });
  for (const origin of [null, "src/core.ts"]) for (const fields of [0, 1, 2]) add(`record-plan-${origin === null ? "generated" : "authored"}-${fields}`, c => { armRecord(c, "Msg_insert", origin).fields.length = fields; });
  add("record-shared-pattern", c => { armRecord(c); c.msg.arms.push({ name: "other", member: "value", payload: { kind: "record", name: "Msg_insert" } }); });
  add("record-node-arm", c => { armRecord(c, "Nested", "src/core.ts"); c.types.structs[0].fields.push({ name: "nested", type: { kind: "node", name: "Nested" } }); });
  add("record-model-arm", c => { c.msg.arms.push({ name: "root", member: "value", payload: { kind: "record", name: "Model" } }); });
  add("record-scalar-node-storage", c => { armRecord(c, "Nested", "src/core.ts"); c.msg.arms.push({ name: "maybe", member: "value", payload: { kind: "scalar", type: { kind: "optional", inner: { kind: "node", name: "Nested" } } } }); });
  for (const spelling of ["ts", "canvas", "old", "mixed"]) for (const signed of [false, true]) add(`scroll-${spelling}-${signed}`, c => {
    const r = armRecord(c);
    const ts = ["offsetX", "offsetY", "velocityX", "velocityY", "viewportExtentX", "viewportExtentY", "contentExtentX", "contentExtentY"];
    const canvas = ["offset_x", "offset_y", "velocity_x", "velocity_y", "viewport_extent_x", "viewport_extent_y", "content_extent_x", "content_extent_y"];
    const fields = spelling === "ts" ? ts : spelling === "canvas" ? canvas : spelling === "old" ? ["offset", "velocity", "viewportExtent", "contentExtent"] : ts.map((name, i) => i === 0 ? canvas[0] : name);
    r.fields = fields.map(name => ({ name, type: { kind: "i64" } }));
    for (let i = 0; i < fields.length; i++) c.integer_slots.push({ slot: `${r.name}.${fields[i]}`, class: i < 4 && signed ? "u64" : "i64" });
  });
  for (const name of ["", "_", "1Type", "with-dash", "$Type", "struct", "return", "f64", "u7", "Uint8Array", "Buffer", "init", "nsc_core_test", "nscfValue", "é"]) add(`facade-name-${name}`, c => { record(c, name); });
  for (const name of ["Math", "String", "Error", "dispatch_void", "abi_frame_msg", "$helper", "nscfHelp", "with-dash"]) add(`facade-helper-${name}`, c => { helper(c, name); });
  add("facade-missing-origin", c => { c.types.structs[0].origin = null; });
  add("facade-missing-member", c => { c.msg.arms[1].member = null; });
  add("facade-kind-member", c => { c.msg.arms[1].member = "kind"; });
  add("facade-kind-flattened", c => { armRecord(c).fields[0].name = "kind"; });
  add("facade-generic", c => { record(c, "Box__f64", "node", null); });
  add("facade-private-record", c => { record(c, "Private").exported = false; });
  add("facade-other-origin", c => { record(c, "Other", "node", "src/shared.ts"); });
  add("facade-value-scalars", c => { record(c, "Nested", "value"); });
  add("facade-value-heap", c => { record(c, "Nested", "value").fields[0].type = { kind: "bytes" }; });
  add("facade-value-sequence", c => { record(c, "Nested", "value"); c.types.structs[0].fields[2].type = { kind: "slice", elem: { kind: "value", name: "Nested" } }; });
  add("facade-mixed-storage", c => { record(c, "Nested", "node"); c.types.structs[0].fields.push({ name: "inline", type: { kind: "value", name: "Nested" } }); });
  add("facade-nested-optional", c => { c.types.structs[0].fields[1].type = { kind: "optional", inner: { kind: "optional", inner: { kind: "bytes" } } }; });
  add("facade-optional-slice", c => { c.types.structs[0].fields[1].type = { kind: "optional", inner: { kind: "slice", elem: { kind: "optional", inner: { kind: "bytes" } } } }; });
  for (const authored of [false, true]) for (const invalid of [false, true]) add(`appearance-${authored}-${invalid}`, c => {
    const r = armRecord(c, "Msg_insert", authored ? "src/core.ts" : null);
    c.types.enums.push({ name: "ColorScheme", origin: "src/events.ts", exported: true, members: ["light", "dark"] });
    r.fields = [{ name: "colorScheme", type: { kind: "enum", name: "ColorScheme" } }, { name: "reduceMotion", type: { kind: invalid ? "bytes" : "bool" } }, { name: "highContrast", type: { kind: "bool" } }];
    c.channels.appearance_msg = "insert";
  });
  for (const authored of [false, true]) for (const node of [false, true]) for (const signed of [false, true]) add(`chrome-${authored}-${node}-${signed}`, c => {
    const r = armRecord(c, "Msg_insert", authored ? "src/core.ts" : null);
    r.fields = [{ name: "insets", type: { kind: node ? "node" : "value", name: "Insets" } }, { name: "buttons", type: { kind: "value", name: "Buttons" } }, { name: "tabsProjected", type: { kind: "bool" } }];
    for (const [name, fields] of [["Insets", ["top", "right", "bottom", "left"]], ["Buttons", ["x", "y", "width", "height"]]] as const) {
      c.types.structs.push({ name, origin: "src/events.ts", exported: true, fields: fields.map(field => ({ name: field, type: { kind: "i64" } })) });
      for (const field of fields) c.integer_slots.push({ slot: `${name}.${field}`, class: signed && name === "Buttons" && (field === "x" || field === "y") ? "u64" : "i64" });
    }
    c.channels.chrome_msg = "insert";
  });
  add("flattened-union-record", c => {
    union(c); c.types.structs.push({ name: "Choice_record", origin: null, exported: true, fields: [{ name: "value", type: { kind: "f64" } }, { name: "flag", type: { kind: "bool" } }] });
    c.types.unions[0].arms.push({ name: "record", member: null, payload: { kind: "value", name: "Choice_record" } });
  });
  add("nested-synthesized-record", c => { const r = record(c, "Model_nested", "value", null); r.fields[0].type = { kind: "i64" }; c.integer_slots.push({ slot: "Model_nested.flag", class: "i64" }); });
  add("integer-helper-return", c => { helper(c, "total", { kind: "optional", inner: { kind: "i64" } }); c.integer_slots.push({ slot: "helpers.total.return", class: "u64" }); });
  add("additive-fields-and-demotion", c => { Object.assign(c, { future_contract: { active: true } }); Object.assign(c.types.structs[0], { future_table: [1, 2] }); Object.assign(c.types.structs[0].fields[0], { future_field: "kept" }); }, ["Model.count"]);
  add("f64-demotion", () => {}, ["Model.count"]);
  add("f64-missing", () => {}, ["Model.absent"]);
  add("f64-message", c => { c.msg.arms[0].payload = { kind: "number", class: "i64" }; c.msg.arms[0].member = "value"; c.integer_slots.push({ slot: "Msg.bump", class: "i64" }); }, ["Msg.bump"]);
  add("legacy-mirror", c => { c.types.structs[0].origin = null; c.msg.arms[1].member = null; }, undefined, true);
  for (const identity of ["0000000000000000", "0020000000000001", "ffffffffffffffff"]) add(`emission-identity-${identity}`, c => {
    c.build_id = identity; c.model_fingerprint = identity;
  });
  for (const [index, entry] of ["", "/", "src///core.ts///", "core.ts", "src\\core.ts", "///src//π.ts//"].entries()) add(`emission-entry-${index}`, c => { c.entry = entry; });
  add("emission-comment-utf8", c => { c.entry = "src/雪🙂\n\r\t\u0000\u007f\u2028\u2029.ts"; c.compiler_version = "0.2.2\n\u2028\u2029"; });
  for (const [index, name] of ["error", "_", "with.dot", "é\"\\\t\r\n", "雪🙂", "$$", "\u0000\u007f"].entries()) {
    add(`emission-property-${index}`, c => { c.types.structs[0].fields[1].name = name; });
    add(`emission-mirror-property-${index}`, c => { c.types.structs[0].fields[1].name = name; }, undefined, true);
  }
  add("emission-environment-utf8", c => { c.channels.env_msgs = [{ env: "APP_雪🙂\"\\\t\u0001", msg: "label_set" }]; });
  for (const [index, origin] of ["src/shared.ts", "src/é\"\\\t\r\n\u2028\u2029.ts"].entries()) add(`emission-origin-${index}`, c => {
    record(c, "Other", "node", origin); enumeration(c); c.types.enums[0].origin = origin;
  });
  for (const unsigned of [false, true]) add(`emission-text-input-${unsigned}`, c => {
    c.types.enums.push({ name: "CaretDirection", origin: "src/events.ts", exported: true, members: ["previous", "next", "previous_word", "next_word", "start", "end"] });
    c.types.structs.push(
      { name: "CaretMove", origin: "src/events.ts", exported: true, fields: [{ name: "direction", type: { kind: "enum", name: "CaretDirection" } }, { name: "extend", type: { kind: "bool" } }] },
      { name: "Selection", origin: "src/events.ts", exported: true, fields: [{ name: "anchor", type: { kind: "i64" } }, { name: "focus", type: { kind: "i64" } }] },
      { name: "Composition", origin: "src/events.ts", exported: true, fields: [{ name: "text", type: { kind: "bytes" } }, { name: "cursor", type: { kind: "optional", inner: { kind: "i64" } } }] },
    );
    for (const slot of ["Selection.anchor", "Selection.focus", "Composition.cursor"]) c.integer_slots.push({ slot, class: unsigned && slot !== "Composition.cursor" ? "u64" : "i64" });
    const tags = ["insert_text", "delete_backward", "delete_forward", "delete_word_backward", "delete_word_forward", "delete_to_start", "delete_to_line_start", "clear", "move_caret", "set_selection", "set_composition", "commit_composition", "cancel_composition"];
    c.types.unions.push({ name: "TextInput", origin: "src/events.ts", exported: true, arms: tags.map(name => ({ name, member: name === "insert_text" || name === "set_composition" ? "text" : name === "move_caret" ? "move" : name === "set_selection" ? "selection" : null, payload: name === "insert_text" ? { kind: "bytes" } : name === "move_caret" ? { kind: "value", name: "CaretMove" } : name === "set_selection" ? { kind: "value", name: "Selection" } : name === "set_composition" ? { kind: "value", name: "Composition" } : { kind: "void" } })) });
    c.msg.arms.push({ name: "edit", member: "event", payload: { kind: "union", name: "TextInput" } });
  });
  for (const scalar of ["-0", "9007199254740993", "18446744073709551615", "-9223372036854775808", "1e-300", "5e-324", "1.7976931348623157e308"]) {
    const c = baseContract();
    const input = encode(c).slice(0, -1) + ',"future":{"wide":' + scalar + ',"nested":[{},[],{"a\\b\\\"c":"café 🧪", "kind":"i64", "slot":"Model.count"}],"bool":true,"empty":null}}';
    out.push({ name: "effective-opaque-" + scalar, input, slots: ["Model.count"] });
  }
  add("effective-optional-u64", c => {
    c.types.structs[0].fields[0].type = { kind: "optional", inner: { kind: "i64" } };
    c.integer_slots[0].class = "u64";
  }, ["Model.count"]);
  add("effective-two-slots", c => {
    c.types.structs[0].fields.push({ name: "other", type: { kind: "optional", inner: { kind: "i64" } } });
    c.integer_slots.push({ slot: "Model.other", class: "u64" });
  }, ["Model.other", "Model.count"]);
  add("effective-repeated-slot", () => {}, ["Model.count", "Model.count"]);
  add("effective-missing-before-repeated", () => {}, ["Missing.count", "Model.count", "Model.count"]);
  const untouched = encode(baseContract());
  out.push({ name: "effective-original-whitespace", input: " \n" + untouched + " \t\n" });
  return out;
}
