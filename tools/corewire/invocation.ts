// Portable invocation rules; raw argument bytes and OS facts cross explicitly.
import type { EmissionInput } from "./core_emission.ts";
import type { Diagnostic } from "./core_contract.ts";
import { emitMirror } from "./emit_mirror.ts";
import { emitFacade } from "./emit_facade.ts";
import { emitProfile } from "./profile_emission.ts";
import { rewriteEffective } from "./lossless_projection.ts";
import { coreUsage, serviceUsage } from "./invocation_usage.ts";

export interface OutputPlan { kind: string; flag: string; path_index: number }
export interface InvocationPlan {
  mode: string; input: number | null; outputs: OutputPlan[];
  check_only: boolean; optimization: number | null; slots: number[];
  error: number[]; exit_code: number;
}
export function textBytes(text: string): number[] {
  const out: number[] = [];
  for (const b of new TextEncoder().encode(text)) out.push(b);
  return out;
}
function same(a: number[], b: number[]): boolean {
  return a.length === b.length && a.every((c, i) => c === b[i]);
}
function equals(a: number[], text: string): boolean { return same(a, textBytes(text)); }
function foldSame(a: number[], b: number[]): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    const x = a[i] >= 65 && a[i] <= 90 ? a[i] + 32 : a[i];
    const y = b[i] >= 65 && b[i] <= 90 ? b[i] + 32 : b[i];
    if (x !== y) return false;
  }
  return true;
}
export function diagnostic(prefix: string, subject: number[], suffix: string): number[] {
  const out = textBytes(prefix);
  for (const b of subject) out.push(b);
  for (const b of textBytes(suffix)) out.push(b);
  return out;
}
function refuse(plan: InvocationPlan, error: number[]): InvocationPlan {
  plan.error = error; plan.exit_code = 2; return plan;
}
const coreFlags = ["--out", "--facade", "--profile", "--effective-sidecar"];
const coreKinds = ["mirror", "facade", "profile", "effective"];
const serviceFlags = ["--service-host-main", "--service-registry", "--service-client", "--service-inproc-main", "--service-inproc-profile"];
const serviceKinds = ["host", "registry", "client", "inproc_main", "inproc_profile"];
function output(plan: InvocationPlan, flag: string, kind: string, index: number): void {
  const found = plan.outputs.find(o => o.kind === kind);
  if (found !== undefined) found.path_index = index;
  else plan.outputs.push({ flag, kind, path_index: index });
}
function ordered(plan: InvocationPlan, kinds: string[]): void {
  const outputs: OutputPlan[] = [];
  for (const kind of kinds) for (const entry of plan.outputs) if (entry.kind === kind) outputs.push(entry);
  plan.outputs = outputs;
}
export function planInvocation(args: number[][]): InvocationPlan {
  const plan: InvocationPlan = { mode: "core", input: null, outputs: [], check_only: false,
    optimization: null, slots: [], error: [], exit_code: 0 };
  let service = false;
  // Service selection preserves the native prefix scan: arguments before its
  // first flag are ignored; unknown arguments after that flag refuse.
  for (let i = 1; i < args.length; i++) {
    const arg = args[i]; let recognized = false;
    if (i + 1 < args.length && equals(arg, "--services-sidecar")) {
      service = true; plan.input = ++i; recognized = true;
    } else if (i + 1 < args.length) {
      for (let j = 0; j < serviceFlags.length; j++) if (equals(arg, serviceFlags[j])) {
        service = true; output(plan, serviceFlags[j], serviceKinds[j], ++i); recognized = true; break;
      }
      if (!recognized && service && equals(arg, "--optimization")) {
        plan.optimization = ++i; recognized = true;
      }
    }
    if (!recognized && service) return refuse(plan, diagnostic('corewire: unknown service projection argument "', arg, '"\n'));
  }
  if (service) {
    plan.mode = "service"; ordered(plan, serviceKinds);
    if (plan.optimization !== null && !equals(args[plan.optimization], "dev") && !equals(args[plan.optimization], "release"))
      return refuse(plan, textBytes("corewire: --optimization must be dev or release\n"));
    if (plan.input === null) return refuse(plan, textBytes(serviceUsage));
    if (plan.outputs.length === 0) return refuse(plan, textBytes("corewire: the service projection needs at least one output\n"));
    const host = plan.outputs.find(o => o.kind === "host"), registry = plan.outputs.find(o => o.kind === "registry");
    if (host !== undefined && registry !== undefined && foldSame(args[host.path_index], args[registry.path_index]))
      return refuse(plan, textBytes("corewire: the service host and registry outputs name one file\n"));
    return plan;
  }
  plan.input = null; plan.outputs = []; plan.optimization = null;
  for (let i = 1; i < args.length; i++) {
    const arg = args[i]; let recognized = false;
    if (equals(arg, "--sidecar") && i + 1 < args.length) { plan.input = ++i; recognized = true; }
    else if (equals(arg, "--f64-slot") && i + 1 < args.length) { plan.slots.push(++i); recognized = true; }
    else if (equals(arg, "--optimization") && i + 1 < args.length) { plan.optimization = ++i; recognized = true; }
    else if (equals(arg, "--check")) { plan.check_only = true; recognized = true; }
    else if (i + 1 < args.length) for (let j = 0; j < coreFlags.length; j++) if (equals(arg, coreFlags[j])) {
      output(plan, coreFlags[j], coreKinds[j], ++i); recognized = true; break;
    }
    if (!recognized) return refuse(plan, diagnostic('corewire: unknown argument "', arg, '"\n\n' + coreUsage));
  }
  ordered(plan, coreKinds);
  if (plan.input === null || ((plan.outputs.length > 0) === plan.check_only)) return refuse(plan, textBytes(coreUsage));
  return plan;
}
export function aliasPolicy(input: number[], paths: number[][], identities: boolean[][]): number[] {
  for (let i = 0; i < paths.length; i++) {
    const path = paths[i];
    if (foldSame(path, input)) return diagnostic("corewire: output ", path, " names the sidecar itself — generating would destroy the input contract\n");
    if (identities[i][0]) return diagnostic("corewire: output ", path, " resolves to the sidecar's own file — generating would destroy the input contract\n");
    for (let j = i + 1; j < paths.length; j++) if (foldSame(path, paths[j]) || identities[i][j + 1])
      return diagnostic("corewire: two outputs name one file (", path, ") — the later projection would overwrite the earlier\n");
  }
  return [];
}
export interface CoreInvocationInput extends EmissionInput {
  slots: number[][]; check_only: boolean; outputs: string[];
  optimization: string | null; entry: string; entry_utf8: boolean;
  entry_unrelated: boolean; facade_path: number[]; profile_directory: number[];
  entry_bytes: number[]; source: string; canonical_source: string;
}
export interface CoreInvocationResult {
  mirror: string; facade: string; profile: string; effective: string;
  diagnostics: Diagnostic[]; error: number[]; exit_code: number;
}
export function emitCoreInvocation(input: CoreInvocationInput): CoreInvocationResult {
  const result: CoreInvocationResult = { mirror: "", facade: "", profile: "", effective: "", diagnostics: [], error: [], exit_code: 0 };
  const s = input.sidecar;
  for (const raw of input.slots) {
    const attested = s.integer_slots.some(slot => same(textBytes(slot.slot), raw));
    if (!attested) {
      result.error = diagnostic("corewire: --f64-slot ", raw, " names no attested integer slot of this contract — a misspelling would silently demote nothing; check the contract's integer_slots\n");
      result.exit_code = 2; return result;
    }
    let demoted = false;
    for (const record of s.types.structs) for (const field of record.fields) {
      if (!same(textBytes(record.name + "." + field.name), raw) || record.name.includes(".") || field.name.includes(".")) continue;
      const type = field.type.kind === "optional" ? field.type.inner! : field.type;
      if (type.kind !== "i64") continue;
      type.kind = "f64"; demoted = true;
    }
    if (!demoted) {
      result.error = diagnostic("corewire: --f64-slot ", raw, " does not name a record field slot (Container.field) — only record-field slots demote today; a message-arm or helper slot demotion needs its own emitter support\n");
      result.exit_code = 2; return result;
    }
  }
  s.integer_slots = s.integer_slots.filter(slot => !input.slots.some(raw => same(textBytes(slot.slot), raw)));
  const mirror = emitMirror(input); result.diagnostics = mirror.diagnostics;
  if (mirror.diagnostics.length !== 0) { result.exit_code = 1; return result; }
  result.mirror = mirror.output;
  const needsProfile = input.check_only || input.outputs.includes("profile");
  if (input.check_only || input.outputs.includes("facade") || needsProfile) {
    const facade = emitFacade(input); result.diagnostics = facade.diagnostics;
    if (facade.diagnostics.length !== 0) { result.exit_code = 1; return result; }
    result.facade = facade.output;
  }
  if (needsProfile) {
    if (input.entry_unrelated) {
      result.error = diagnostic("corewire: --facade ", input.facade_path, " has no path relative to the --profile directory ");
      for (const b of input.profile_directory) result.error.push(b);
      for (const b of textBytes(" — the profile's entry must reach the facade from beside the profile; emit them under one root\n")) result.error.push(b);
      result.exit_code = 2; return result;
    }
    if (!input.entry_utf8) {
      result.error = diagnostic('corewire: the profile\'s entry spelling "', input.entry_bytes, '" is not valid UTF-8 — the profile is a JSON document and JSON text carries UTF-8 only; rename the facade file\n');
      result.exit_code = 2; return result;
    }
    if (input.optimization !== null && input.optimization !== "dev" && input.optimization !== "release") {
      result.error = textBytes("corewire: --optimization must be dev or release\n"); result.exit_code = 2; return result;
    }
    const profile = emitProfile(s, input.entry, input.optimization ?? ""); result.diagnostics = profile.diagnostics;
    if (profile.diagnostics.length !== 0) { result.exit_code = 1; return result; }
    result.profile = profile.output;
  }
  if (input.outputs.includes("effective")) result.effective = input.slots.length === 0 ? input.source : rewriteEffective(input.canonical_source, input.slots);
  return result;
}
