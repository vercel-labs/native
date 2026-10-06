// The compiler profile projection of corewire's validated, effective contract.
// Compiled by scriptc and linked into corewire; Node runs the same source in tests.
// Fixed key order and whitespace preserve the existing profile bytes.

import { generateServices as serviceGenerate, validateServices as serviceValidate } from "./emit_service.ts";
import { evaluateCorePolicy } from "./core_policy.ts";
import { emitMirror } from "./emit_mirror.ts";
import { emitFacade } from "./emit_facade.ts";
import type { EmissionInput } from "./core_emission.ts";
import { emitProfile } from "./profile_emission.ts";
import { planInvocation, aliasPolicy, emitCoreInvocation } from "./invocation.ts";
import type { CoreInvocationInput } from "./invocation.ts";
import { projectEffective } from "./lossless_projection.ts";
import type { ProfileInput } from "./profile_emission.ts";
import { coreIntake, serviceIntake } from "./contract_intake.ts";
export { emitProfile } from "./profile_emission.ts";
export function generateMirror(input: string): string { return JSON.stringify(emitMirror(JSON.parse(input) as EmissionInput)); }
export function generateFacade(input: string): string { return JSON.stringify(emitFacade(JSON.parse(input) as EmissionInput)); }
export function corePolicy(input: string, phase: string): string { return evaluateCorePolicy(input, phase); }
export function generateServices(input: string, projection: string, optimization: string): string {
  return serviceGenerate(input, projection, optimization);
}
export function validateServices(input: string): string { return serviceValidate(input); }

// The private C ABI carries only validated projection facts, then returns a
// profile or field diagnostics. Contract validation remains in corewire.
export function generate(input: string, entry: string, optimization: string): string {
  const sidecar = JSON.parse(input) as ProfileInput;
  return JSON.stringify(emitProfile(sidecar, entry, optimization));
}

export function invocationPlan(input: string): string {
  return JSON.stringify(planInvocation(JSON.parse(input) as number[][]));
}
export function invocationAliases(input: string): string {
  const facts = JSON.parse(input) as { input: number[]; paths: number[][]; identities: boolean[][] };
  return JSON.stringify(aliasPolicy(facts.input, facts.paths, facts.identities));
}
export function coreInvocation(input: string): string { return JSON.stringify(emitCoreInvocation(JSON.parse(input) as CoreInvocationInput)); }
export function effectiveSidecar(input: string): string { return projectEffective(input); }
export function contractIntake(input: string, mode: string): string {
  if (mode === "core") return JSON.stringify(coreIntake(input));
  if (mode === "service") return JSON.stringify(serviceIntake(input));
  throw new Error("unknown contract intake mode");
}
