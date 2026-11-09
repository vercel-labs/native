// Portable filesystem coordination for the build-host corewire tool. Native
// capabilities supply OS path operations, exact metadata, entropy and I/O.
import { diagnostic, textBytes } from "./invocation.ts";

export interface PathState { base: number[]; exists: boolean }
export interface FileIdentity {
  canonical: number[] | null;
  basename: number[];
  parent: number[] | null;
  metadata: string[] | null;
}
export interface FileOutput {
  kind: string; flag: string; path: number[]; parent: number[] | null;
  staged: number[];
}
export interface OutputState {
  mode: string; outputs: FileOutput[]; phase: string; index: number; prior: number;
  temporary: number[]; write_failed: boolean; cleanup_at: number; cleanup_end: number;
  after_diagnostic: string; error: number[]; exit_code: number;
}
export interface Observation { ok: boolean; error: number[]; bytes: number[]; identity: boolean }
export interface OutputAction { kind: string; index: number; prior: number; path: number[]; projection: string; message: number[] }
export interface OutputStep { state: OutputState; action: OutputAction }
function same(a: number[], b: number[]): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}
function join(a: number[], b: number[]): number[] {
  const out = a.slice();
  for (const byte of b) out.push(byte);
  return out;
}
export function pathBegin(root: number[] | null, absolute: boolean, cwd: number[] | null): { state: PathState; resolve: boolean } {
  return { state: { base: root ?? cwd ?? textBytes("."), exists: true }, resolve: root !== null && !absolute };
}
export function pathComponent(state: PathState, component: number[]): { action: string; probe: boolean } {
  if (same(component, textBytes("."))) return { action: "keep", probe: false };
  if (same(component, textBytes(".."))) return { action: "parent", probe: !state.exists };
  return { action: "join", probe: state.exists };
}
export function pathObserved(state: PathState, action: string, candidate: number[], canonical: number[] | null): PathState {
  if (action === "keep") return state;
  if (canonical !== null) return { base: canonical, exists: true };
  return { base: candidate, exists: action === "parent" && state.exists };
}
export function identityPlan(a: FileIdentity, b: FileIdentity): { same: boolean; stat: boolean } {
  if (a.canonical === null || b.canonical === null) return { same: false, stat: false };
  if (same(a.canonical, b.canonical)) return { same: true, stat: false };
  return { same: false, stat: same(a.basename, b.basename) && a.parent !== null && b.parent !== null };
}
export function metadataIdentity(a: string[] | null, b: string[] | null): boolean {
  if (a === null || b === null || a.length !== 6 || b.length !== 6) return false;
  for (let i = 0; i < 6; i++) if (a[i] !== b[i]) return false;
  return true;
}
export function aliasPaths(outputs: FileOutput[]): number[][] {
  const paths = outputs.map(output => output.path);
  for (const output of outputs) paths.push(join(output.path, textBytes(".corewire-tmp")));
  return paths;
}
export function outputBegin(mode: string, outputs: FileOutput[]): OutputState {
  return { mode, outputs, phase: mode === "service" ? "service_generate" : "stage_alias", index: 0, prior: 0,
    temporary: [], write_failed: false, cleanup_at: 0, cleanup_end: 0, after_diagnostic: "done", error: [], exit_code: 0 };
}
function errorMessage(prefix: string, path: number[], error: number[], suffix: string): number[] {
  return join(join(diagnostic(prefix, path, ": "), error), textBytes(suffix));
}
function aliasMessage(output: FileOutput, earlier: FileOutput, commit: boolean): number[] {
  return diagnostic("corewire: " + output.flag + " ", output.path, commit
    ? " resolves to the file " + earlier.flag + " just wrote — the later projection would overwrite the earlier\n"
    : " resolves to the " + earlier.flag + " file — the later projection would overwrite the earlier\n");
}
function fail(state: OutputState, message: number[], code: number, first: number, end: number, diagnosticFirst: boolean): void {
  state.error = message; state.exit_code = code; state.cleanup_at = first; state.cleanup_end = end;
  state.after_diagnostic = diagnosticFirst ? "cleanup" : "done";
  state.phase = diagnosticFirst ? "diagnostic" : "cleanup";
}
function action(state: OutputState, kind: string, path: number[] = [], projection = "", message: number[] = []): OutputStep {
  return { state, action: { kind, index: state.index, prior: state.prior, path, projection, message } };
}
export function stagingPath(path: number[], nonce: number[]): number[] {
  if (nonce.length !== 8) throw new Error("invalid corewire entropy extent");
  const out = join(path, textBytes(".corewire-tmp."));
  for (const byte of nonce) {
    const high = byte >>> 4, low = byte & 15;
    out.push(high < 10 ? 48 + high : 87 + high, low < 10 ? 48 + low : 87 + low);
  }
  return out;
}
export function outputStep(state: OutputState, observed: Observation): OutputStep {
  // Only transitions without a capability loop here. Every external action is
  // returned to the native executor, including ignored cleanup failures.
  while (true) {
    const output = state.outputs[state.index];
    switch (state.phase) {
      case "stage_alias":
      case "commit_alias": {
        const commit = state.phase === "commit_alias";
        if (state.index === state.outputs.length) {
          if (commit) { state.phase = "done"; continue; }
          state.index = 0; state.prior = 0; state.phase = "commit_alias"; continue;
        }
        if (state.prior < state.index) {
          state.phase = commit ? "commit_alias_result" : "stage_alias_result";
          return action(state, "identity", output.path);
        }
        if (commit) { state.phase = "rename_result"; return action(state, "rename", output.path); }
        state.phase = "entropy";
        if (output.parent !== null) return action(state, "mkdir", output.parent);
        continue;
      }
      case "stage_alias_result":
      case "commit_alias_result": {
        const commit = state.phase === "commit_alias_result";
        if (observed.identity) {
          fail(state, aliasMessage(output, state.outputs[state.prior], commit), 2,
            commit ? state.index : 0, commit ? state.outputs.length : state.index, false);
        } else { state.prior++; state.phase = commit ? "commit_alias" : "stage_alias"; }
        continue;
      }
      case "entropy": state.phase = "entropy_result"; return action(state, "entropy");
      case "entropy_result":
        state.temporary = stagingPath(output.path, observed.bytes); state.write_failed = false;
        state.phase = "create_result"; return action(state, "create", state.temporary);
      case "create_result":
        if (!observed.ok) {
          fail(state, errorMessage("corewire: cannot stage ", state.temporary, observed.error, "\n"), 1, 0, state.index, true);
          continue;
        }
        state.phase = "write_result"; return action(state, "write");
      case "write_result":
        state.write_failed = !observed.ok;
        if (state.write_failed) { state.phase = "close_result"; return action(state, "close"); }
        state.phase = "flush_result"; return action(state, "flush");
      case "flush_result":
        state.write_failed = !observed.ok; state.phase = "close_result"; return action(state, "close");
      case "close_result":
        if (state.write_failed) { state.phase = "write_failure"; return action(state, "delete", state.temporary); }
        output.staged = state.temporary; state.index++; state.prior = 0; state.phase = "stage_alias"; continue;
      case "write_failure":
        fail(state, diagnostic("corewire: cannot write ", state.temporary, "\n"), 1, 0, state.index, true); continue;
      case "rename_result":
        if (!observed.ok) {
          fail(state, errorMessage("corewire: cannot write ", output.path, observed.error, state.index > 0
            ? " — earlier projections were already replaced, so the outputs on disk may be from different generations; re-run to restore the set\n" : "\n"),
            1, state.index, state.outputs.length, false);
        } else { state.index++; state.prior = 0; state.phase = "commit_alias"; }
        continue;
      case "service_generate":
        if (state.index === state.outputs.length) { state.phase = "done"; continue; }
        state.phase = "service_write";
        return action(state, "generate", [], output.kind === "inproc_main" ? "inproc" : output.kind === "inproc_profile" ? "profile" : output.kind);
      case "service_write": state.phase = "service_write_result"; return action(state, "service_write", output.path);
      case "service_write_result":
        if (!observed.ok) fail(state, errorMessage("corewire: cannot write ", output.path, observed.error, "\n"), 1, 0, 0, true);
        else { state.index++; state.phase = "service_generate"; }
        continue;
      case "cleanup":
        if (state.cleanup_at < state.cleanup_end) {
          const path = state.outputs[state.cleanup_at++].staged;
          return action(state, "delete", path);
        }
        state.phase = state.after_diagnostic === "cleanup" ? "done" : "diagnostic"; continue;
      case "diagnostic":
        state.phase = state.after_diagnostic;
        return action(state, "diagnostic", [], "", state.error);
      case "done": return action(state, "done");
      default: throw new Error("invalid corewire output phase");
    }
  }
}

// This ABI transports raw paths as bytes and metadata as exact decimal text.
// JSON strings never convert paths or native integers through a JS number.
export function filesystemPolicy(input: string): string {
  const value = JSON.parse(input) as { operation: string; payload: string };
  switch (value.operation) {
    case "path_begin": {
      const v = JSON.parse(value.payload) as { root: number[] | null; absolute: boolean; cwd: number[] | null };
      return JSON.stringify(pathBegin(v.root, v.absolute, v.cwd));
    }
    case "path_component": {
      const v = JSON.parse(value.payload) as { state: PathState; component: number[] };
      return JSON.stringify(pathComponent(v.state, v.component));
    }
    case "path_observed": {
      const v = JSON.parse(value.payload) as { state: PathState; action: string; candidate: number[]; canonical: number[] | null };
      return JSON.stringify(pathObserved(v.state, v.action, v.candidate, v.canonical));
    }
    case "identity_plan": {
      const v = JSON.parse(value.payload) as { left: FileIdentity; right: FileIdentity };
      return JSON.stringify(identityPlan(v.left, v.right));
    }
    case "metadata_identity": {
      const v = JSON.parse(value.payload) as { left: FileIdentity; right: FileIdentity };
      return JSON.stringify(metadataIdentity(v.left.metadata, v.right.metadata));
    }
    case "alias_paths": {
      const v = JSON.parse(value.payload) as { outputs: FileOutput[] };
      return JSON.stringify(aliasPaths(v.outputs));
    }
    case "output_begin": {
      const v = JSON.parse(value.payload) as { mode: string; outputs: FileOutput[] };
      return JSON.stringify(outputBegin(v.mode, v.outputs));
    }
    case "output_step": {
      const v = JSON.parse(value.payload) as { output_state: OutputState; observation: Observation };
      return JSON.stringify(outputStep(v.output_state, v.observation));
    }
    default: throw new Error("unknown corewire filesystem operation");
  }
}
