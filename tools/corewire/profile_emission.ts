// Portable compiler-profile emission with exact native-reference formatting.
export interface ProfileInput {
  deterministic: boolean;
  async_free: boolean;
  wire_version: number;
  abi_version: number;
  model: string;
  msg: { name: string };
  has_subscriptions: boolean;
  abi: { prefix: string; exports: string[]; snapshot_format: number };
  integer_slots: { slot: string; class: string }[];
}

export interface Diagnostic { path: string; message: string }
export interface ProfileResult { output: string; diagnostics: Diagnostic[] }
interface Signature { suffix: string; name: string; params: string[] }
interface Fence { selector: string; value: string; teaching: string }

// Match corewire's JSON spelling, including control bytes that JSON.stringify
// normally shortens to \b and \f. Non-ASCII text stays literal UTF-8.
function quote(text: string): string {
  let out = '"';
  let start = 0;
  for (let i = 0; i < text.length; i++) {
    const code = text.charCodeAt(i);
    let escaped = "";
    if (code === 34) escaped = '\\"';
    else if (code === 92) escaped = "\\\\";
    else if (code === 10) escaped = "\\n";
    else if (code === 13) escaped = "\\r";
    else if (code === 9) escaped = "\\t";
    else if (code < 32) escaped = "\\u00" + "0123456789abcdef".charAt(code >> 4) + "0123456789abcdef".charAt(code & 15);
    else continue;
    // Copy whole Unicode spans, never isolated UTF-16 surrogate halves.
    out += text.slice(start, i) + escaped;
    start = i + 1;
  }
  return out + text.slice(start) + '"';
}

export function emitProfile(sidecar: ProfileInput, entry: string, optimization: string): ProfileResult {
  const diagnostics: Diagnostic[] = [];
  if (!sidecar.deterministic) diagnostics.push({
    path: "deterministic",
    message: "the contract attests deterministic: false, but this profile enforces the determinism fences and a core that compiles under them attests true by construction — build the core under this profile and regenerate from the contract it co-emits",
  });
  if (!sidecar.async_free) diagnostics.push({
    path: "async_free",
    message: "the contract attests async_free: false, but this profile's compilation mode is structurally async-free — a core reaching async surface refuses under it, so this contract cannot have come from the profile it asks for; remove the async surface and regenerate the contract",
  });
  if (diagnostics.length > 0) return { output: "", diagnostics };

  const prefix = sidecar.abi.prefix;
  let out = '{\n  "profile_format": 1,\n  "name": "native-sdk-core",\n  "entry": ' + quote(entry) + ',\n  "emission": "llvm",';
  // The original projection places the optional optimization on this line.
  if (optimization !== "") out += '  "optimization": ' + quote(optimization) + ',\n';
  out += '  "abi": {\n    "prefix": ' + quote(prefix)
    + ',\n    "init_symbol": ' + quote(prefix + "init")
    + ',\n    "sink_register_symbol": ' + quote(prefix + "set_panic_sink")
    + ',\n    "collect_symbol": ' + quote(prefix + "collect")
    + ',\n    "result_reset_symbol": ' + quote(prefix + "frame_reset")
    + '\n  },\n  "exports": [\n';
  let first = true;
  for (const suffix of sidecar.abi.exports) {
    for (const signature of signatures) {
      if (signature.suffix !== suffix) continue;
      if (!first) out += ',\n';
      first = false;
      out += '    { "export": ' + quote(signature.name) + ', "symbol": ' + quote(prefix + suffix) + ', "params": [';
      for (let i = 0; i < signature.params.length; i++) {
        if (i !== 0) out += ', ';
        out += quote(signature.params[i]);
      }
      out += '], "returns": "bytes" }';
      break;
    }
  }
  out += '\n  ],\n  "sidecar": {\n    "path": "core.contract.json",\n    "wire_version": ' + sidecar.wire_version
    + ',\n    "abi_version": ' + sidecar.abi_version
    + ',\n    "snapshot_format": ' + sidecar.abi.snapshot_format
    + ',\n    "build_id_symbol": ' + quote(prefix + "build_id")
    + ',\n    "abi_version_symbol": ' + quote(prefix + "abi_version")
    + ',\n    "model": ' + quote(sidecar.model)
    + ',\n    "msg": ' + quote(sidecar.msg.name)
    + ',\n    "init_export": "init",\n    "update_export": "coreUpdate",\n';
  if (sidecar.has_subscriptions) out += '    "subscriptions_export": "coreSubscriptions",\n';
  if (sidecar.integer_slots.length === 0) out += '    "integer_slots": []\n  },\n';
  else {
    out += '    "integer_slots": [\n';
    for (let i = 0; i < sidecar.integer_slots.length; i++) {
      const slot = sidecar.integer_slots[i];
      out += '      { "slot": ' + quote(slot.slot) + ', "class": ' + quote(slot.class) + ' }';
      if (i + 1 !== sidecar.integer_slots.length) out += ',';
      out += '\n';
    }
    out += '    ]\n  },\n';
  }
  out += '  "determinism": {\n    "teachings": {\n';
  for (let i = 0; i < teachings.length; i++) {
    out += '      ' + quote(teachings[i].code) + ': ' + quote(teachings[i].text);
    if (i + 1 !== teachings.length) out += ',';
    out += '\n';
  }
  out += '    },\n    "remediations": {\n';
  for (let i = 0; i < remediations.length; i++) {
    out += '      ' + quote(remediations[i].code) + ': ' + quote(remediations[i].text);
    if (i + 1 !== remediations.length) out += ',';
    out += '\n';
  }
  out += '    },\n    "fences": [\n';
  for (let i = 0; i < fences.length; i++) {
    const fence = fences[i];
    out += '      { ' + quote(fence.selector) + ': ' + quote(fence.value) + ', "teaching": ' + quote(fence.teaching) + ' }';
    if (i + 1 !== fences.length) out += ',';
    out += '\n';
  }
  out += '    ]\n  }\n}\n';
  return { output: out, diagnostics };
}

const signatures: Signature[] = [
  { suffix: "boot_cmd", name: "boot_cmd", params: [] },
  { suffix: "dispatch_void", name: "dispatch_void", params: ["u8"] },
  { suffix: "dispatch_bytes", name: "dispatch_bytes", params: ["u8", "bytes"] },
  { suffix: "dispatch_number", name: "dispatch_number", params: ["u8", "f64"] },
  { suffix: "dispatch_number_bytes", name: "dispatch_number_bytes", params: ["u8", "f64", "bytes"] },
  { suffix: "dispatch_bool", name: "dispatch_bool", params: ["u8", "u8"] },
  { suffix: "dispatch_enum", name: "dispatch_enum", params: ["u8", "u32"] },
  { suffix: "dispatch_record", name: "dispatch_record", params: ["u8", "bytes"] },
  { suffix: "dispatch_text_input", name: "dispatch_text_input", params: ["u8", "bytes"] },
  { suffix: "dispatch_scroll_state", name: "dispatch_scroll_state", params: ["u8", "f64", "f64", "f64", "f64", "f64", "f64", "f64", "f64"] },
  { suffix: "subscriptions", name: "abi_subscriptions", params: [] },
  { suffix: "model_snapshot", name: "model_snapshot", params: [] },
  { suffix: "persist_snapshot", name: "persist_snapshot", params: [] },
  { suffix: "restore_model", name: "restore_model", params: ["bytes"] },
  { suffix: "migrate_model", name: "migrate_model", params: ["bytes", "f64"] },
  { suffix: "helper_call", name: "helper_call", params: ["u32", "bytes"] },
  { suffix: "command_msg", name: "abi_command_msg", params: ["bytes"] },
  { suffix: "frame_msg", name: "abi_frame_msg", params: ["f64", "f64", "f64", "f64"] },
  { suffix: "frame_msg_ns", name: "abi_frame_msg_ns", params: ["f64", "f64", "f64", "f64", "bytes", "bytes"] },
  { suffix: "key_msg", name: "abi_key_msg", params: ["bytes", "u8", "u8", "u8", "u8"] },
  { suffix: "pinch_msg", name: "abi_pinch_msg", params: ["f64", "bytes", "u32", "f64", "f64", "f64"] },
  { suffix: "drop_msg", name: "abi_drop_msg", params: ["bytes"] },
  { suffix: "native_view", name: "native_view", params: [] },
  { suffix: "native_media_view", name: "native_media_view", params: ["bytes"] },
  { suffix: "native_media_window_view", name: "native_media_window_view", params: ["bytes", "bytes"] },
  { suffix: "native_window_view", name: "native_window_view", params: ["bytes"] },
  { suffix: "native_radio_policy", name: "native_radio_policy", params: ["bytes"] },
  { suffix: "native_tabs_policy", name: "native_tabs_policy", params: ["bytes"] },
  { suffix: "native_tree_policy", name: "native_tree_policy", params: ["bytes"] },
  { suffix: "native_list_policy", name: "native_list_policy", params: ["bytes"] },
  { suffix: "native_menu_policy", name: "native_menu_policy", params: ["bytes"] },
  { suffix: "native_toggle_policy", name: "native_toggle_policy", params: ["bytes"] },
  { suffix: "native_accordion_policy", name: "native_accordion_policy", params: ["bytes"] },
  { suffix: "native_slider_policy", name: "native_slider_policy", params: ["bytes"] },
  { suffix: "native_split_policy", name: "native_split_policy", params: ["bytes"] },
  { suffix: "native_scroll_policy", name: "native_scroll_policy", params: ["bytes"] },
  { suffix: "native_resizable_policy", name: "native_resizable_policy", params: ["bytes"] },
  { suffix: "native_text_policy", name: "native_text_policy", params: ["bytes"] },
  { suffix: "native_timer_policy", name: "native_timer_policy", params: ["bytes"] },
  { suffix: "native_db_policy", name: "native_db_policy", params: ["bytes"] },
  { suffix: "native_effect_policy", name: "native_effect_policy", params: ["bytes"] },
  { suffix: "native_stream_policy", name: "native_stream_policy", params: ["bytes"] },
  { suffix: "native_window_policy", name: "native_window_policy", params: ["bytes"] },
  { suffix: "native_theme_policy", name: "native_theme_policy", params: ["bytes"] },
  { suffix: "native_status_policy", name: "native_status_policy", params: ["bytes"] },
  { suffix: "native_virtual_requests", name: "native_virtual_requests", params: ["bytes", "bytes"] },
  { suffix: "native_virtual_view", name: "native_virtual_view", params: ["bytes", "bytes", "bytes"] },
];

const randomness_teaching = "randomness is an effect: the core requests it through a command and the value arrives as a Msg, so a recorded session replays it exactly.";
const network_teaching = "network is an effect: declare requests as commands (Cmd.fetch, Cmd.request) and responses arrive as Msgs.";
const clock_teaching = "the wall clock is an effect: read it through the host's journaled clock — Cmd.now, Cmd.delay, and Sub.timer deliver fire times as Msgs, so a recorded session replays them exactly.";

// RELEASE-PINNED DATA: these selectors must resolve to runtime-deniable
// entries in the pinned scriptc surface manifest. Folded constants remain
// available. Module-only http/https/dgram/dns and folded worker/cluster
// members cannot be fenced by this release.
const fences: Fence[] = [
  { selector: "id", value: "stdlib.math.random", teaching: randomness_teaching },
  { selector: "id", value: "node-builtin.crypto.randomBytes", teaching: randomness_teaching },
  { selector: "id", value: "node-builtin.crypto.randomUUID", teaching: randomness_teaching },
  { selector: "prefix", value: "stdlib.date.", teaching: clock_teaching },
  { selector: "prefix", value: "node-builtin.perf_hooks.", teaching: clock_teaching },
  { selector: "prefix", value: "node-builtin.fs.", teaching: "files are effects: declare reads and writes as commands (Cmd.readFile, Cmd.writeFile) and results arrive as Msgs." },
  { selector: "prefix", value: "node-builtin.net.", teaching: network_teaching },
  { selector: "prefix", value: "node-builtin.http2.", teaching: network_teaching },
  { selector: "prefix", value: "node-builtin.tls.", teaching: network_teaching },
  { selector: "prefix", value: "node-builtin.child_process.", teaching: "processes are effects: run them through Cmd.spawn and their output arrives as Msgs." },
  { selector: "prefix", value: "node-builtin.timers.", teaching: "timers are effects: schedule Cmd.delay or Sub.timer and fire times arrive as Msgs through the host's journaled clock." },
  { selector: "prefix", value: "node-builtin.os.", teaching: "machine and session facts are host inputs: they reach a core as journaled Msgs, never as ambient reads." },
  { selector: "prefix", value: "node-builtin.process.", teaching: "process and environment facts are host inputs: environment values arrive as journaled Msgs through the env channel, and every other session fact reaches a core only as a host-delivered Msg." },
];

const teachings: { code: string; text: string }[] = [
  { code: "async", text: "async, promises, and timer callbacks are unavailable in an app core: the host executes effects — declare a command (Cmd.fetch, Cmd.delay) or a subscription (Sub.timer) and results arrive as Msgs." },
];

const remediations: { code: string; text: string }[] = [
  { code: "SC4013", text: "rebuild the app: an exception escaping a core entry is contract skew between the compiled core and its host bindings, and one build regenerates both from one contract." },
  { code: "SC4017", text: "restart the app process: a trapped core is poisoned and never resumes in place, and the recorded session replays deterministically." },
];
