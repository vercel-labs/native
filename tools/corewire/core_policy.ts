import { validateCore } from "./core_contract.ts";
import type { CoreInput, Diagnostic } from "./core_contract.ts";
import { projectionPlan, validateMirror, validateFacade } from "./core_projection.ts";

export function evaluateCorePolicy(input: string, phase: string): string {
  const facts = JSON.parse(input) as CoreInput;
  const plan = projectionPlan(facts.sidecar);
  let diagnostics: Diagnostic[] = [];
  if (phase === "core") diagnostics = validateCore(facts);
  else if (phase === "mirror") diagnostics = validateMirror(facts.sidecar);
  else if (phase === "facade") diagnostics = validateFacade(facts.sidecar, plan);
  else if (phase !== "plan") throw new Error("unknown core policy phase");
  return JSON.stringify({ diagnostics, inlined: plan.inlined, flattened: plan.flattened, node_stored: plan.node_stored });
}
