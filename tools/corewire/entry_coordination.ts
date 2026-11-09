// Complete build-host invocation coordination. Native executes only returned
// capabilities and owns raw input, decoded records and compiled result bytes.
import { diagnostic } from "./invocation.ts";
import type { InvocationPlan } from "./invocation.ts";

export interface EntryState {
  phase: string; mode: string; cursor: number; prior: number; paths: number;
  exit_code: number; facade: number | null; profile: number | null;
}
export interface EntryObservation {
  plan: InvocationPlan | null; ok: boolean; message: number[]; exit_code: number;
  paths: number; diagnostics: number[];
}
export interface EntryAction { kind: string; cursor: number; prior: number; message: number[] }
export interface EntryStep { state: EntryState; action: EntryAction }
export function entryBegin(): EntryState {
  return { phase: "plan", mode: "core", cursor: 0, prior: 0, paths: 0, exit_code: 0, facade: null, profile: null };
}
function action(state: EntryState, kind: string, message: number[] = []): EntryStep {
  return { state, action: { kind, cursor: state.cursor, prior: state.prior, message } };
}
export function entryStep(state: EntryState, observed: EntryObservation): EntryStep {
  while (true) {
    switch (state.phase) {
      case "plan": state.phase = "planned"; return action(state, "plan");
      case "planned": {
        const plan = observed.plan;
        if (plan === null) throw new Error("missing corewire invocation plan");
        state.mode = plan.mode; state.exit_code = plan.exit_code;
        if (plan.exit_code !== 0) { state.phase = "terminal_flush"; return action(state, "diagnostic", plan.error); }
        for (const output of plan.outputs) {
          if (output.kind === "facade") state.facade = output.path_index;
          if (output.kind === "profile") state.profile = output.path_index;
        }
        state.phase = plan.mode === "service" ? "read" : "canonical_input"; continue;
      }
      case "canonical_input": state.phase = "alias_paths"; return action(state, "canonical_input");
      case "alias_paths": state.phase = "canonical_outputs"; return action(state, "alias_paths");
      case "canonical_outputs":
        state.paths = observed.paths; state.cursor = 0; state.phase = "canonical_next"; continue;
      case "canonical_next":
        if (state.cursor === state.paths) { state.cursor = 0; state.phase = "identity_next"; continue; }
        state.phase = "canonical_advance"; return action(state, "canonical_output");
      case "canonical_advance": state.cursor++; state.phase = "canonical_next"; continue;
      case "identity_next":
        if (state.cursor === state.paths) { state.phase = "aliases"; continue; }
        state.prior = state.cursor + 1; state.phase = "identity_pair"; return action(state, "identity_input");
      case "identity_pair":
        if (state.prior === state.paths) { state.cursor++; state.phase = "identity_next"; continue; }
        state.phase = "identity_advance"; return action(state, "identity_pair");
      case "identity_advance": state.prior++; state.phase = "identity_pair"; continue;
      case "aliases": state.phase = "alias_result"; return action(state, "aliases");
      case "alias_result":
        if (observed.message.length !== 0) { state.exit_code = 2; state.phase = "terminal_flush"; return action(state, "diagnostic", observed.message); }
        state.phase = "read"; continue;
      case "read": state.phase = "read_result"; return action(state, state.mode === "service" ? "read_service" : "read_core");
      case "read_result":
        if (!observed.ok) { state.exit_code = 1; state.phase = "terminal_flush"; return action(state, "diagnostic", observed.message); }
        state.phase = "decoded"; return action(state, state.mode === "service" ? "decode_service" : "decode_core");
      case "decoded":
        if (!observed.ok) { state.exit_code = 1; state.phase = "terminal_flush"; return action(state, "diagnostic", observed.diagnostics); }
        if (state.mode === "service") { state.phase = "output"; continue; }
        state.phase = "project";
        if (state.facade !== null) return action(state, state.profile !== null ? "relative_entry" : "basename_entry");
        continue;
      case "project": state.phase = "projected"; return action(state, "project");
      case "projected":
        state.exit_code = observed.exit_code;
        state.phase = observed.exit_code !== 0 ? "terminal_flush" : "output_flush";
        return action(state, "diagnostic", observed.exit_code !== 0 && observed.message.length !== 0 ? observed.message : observed.diagnostics);
      case "output_flush": state.phase = "output"; return action(state, "flush");
      case "output": state.phase = "output_result"; return action(state, "outputs");
      case "output_result":
        state.exit_code = observed.exit_code;
        state.phase = state.mode === "service" && observed.exit_code === 0 ? "terminal_flush" : "done"; continue;
      case "terminal_flush": state.phase = "done"; return action(state, "flush");
      case "done": return action(state, "done");
      default: throw new Error("invalid corewire invocation phase");
    }
  }
}
export interface EntryDiagnostic { path: number[]; message: number[]; severity: string }
export function formatDiagnostics(label: number[], entries: EntryDiagnostic[]): number[] {
  const out: number[] = [];
  for (const item of entries) {
    const line = diagnostic("", label, item.severity === "error" ? ": error: " : ": warning: ");
    if (item.path.length !== 0) { for (const b of item.path) line.push(b); line.push(58, 32); }
    for (const b of item.message) line.push(b);
    line.push(10);
    for (const b of line) out.push(b);
  }
  return out;
}
export function readFailure(path: number[], error: number[]): number[] {
  const out = diagnostic("corewire: cannot read ", path, ": ");
  for (const b of error) out.push(b);
  out.push(10); return out;
}
export function entryPolicy(input: string): string {
  const value = JSON.parse(input) as { operation: string; payload: string };
  switch (value.operation) {
    case "begin": return JSON.stringify(entryBegin());
    case "step": {
      const v = JSON.parse(value.payload) as { state: EntryState; observation: EntryObservation };
      return JSON.stringify(entryStep(v.state, v.observation));
    }
    case "diagnostics": {
      const v = JSON.parse(value.payload) as { label: number[]; entries: EntryDiagnostic[] };
      return JSON.stringify(formatDiagnostics(v.label, v.entries));
    }
    case "entry": {
      const v = JSON.parse(value.payload) as { bytes: number[]; relative: boolean; windows: boolean; absolute: boolean; valid_utf8: boolean; facade: number[]; directory: number[] };
      const bytes = v.bytes.map(b => v.relative && v.windows && b === 92 ? 47 : b);
      return JSON.stringify({ text: v.valid_utf8 ? new TextDecoder("utf-8", { ignoreBOM: true }).decode(new Uint8Array(bytes)) : "", bytes, utf8: v.valid_utf8,
        unrelated: v.relative && (bytes.length === 0 || v.absolute), facade_path: v.facade, profile_directory: v.directory });
    }
    case "read_failure": {
      const v = JSON.parse(value.payload) as { path: number[]; error: number[] };
      return JSON.stringify(readFailure(v.path, v.error));
    }
    case "service_failure": {
      const v = JSON.parse(value.payload) as { error: number[] };
      return JSON.stringify(diagnostic("corewire: services contract is not valid schema-2 JSON: ", v.error, "\n"));
    }
    default: throw new Error("unknown corewire entry operation");
  }
}
