// CLI conformance over independent native-reference outcomes, including all
// generated files and refusal ordering. The two schemas stay explicit.
import { baseContract as coreContract, coreCases } from "./core_cases.ts";
import { baseContract as serviceContract } from "./service_cases.ts";
export interface InvocationCase { name: string; args: string[]; core: string; services: string; directories: string[] }
export function invocationCases(): InvocationCase[] {
  const core = JSON.stringify(coreContract(), (key, value) => (key === "origin" || key === "member") && value === null ? undefined : value);
  const services = JSON.stringify(serviceContract());
  const cases: InvocationCase[] = [];
  function add(name: string, args: string[], source = core): void {
    cases.push({ name, args, core: source, services, directories: ["nested"] });
  }
  const input = ["--sidecar", "input.json"], service = ["--services-sidecar", "services.json"];
  const coreFlags = ["--out", "--facade", "--profile", "--effective-sidecar"];
  const outputs = ["mirror", "facade", "profile", "effective"];
  const serviceFlags = ["--service-host-main", "--service-registry", "--service-client", "--service-inproc-main", "--service-inproc-profile"];
  const serviceOutputs = ["host", "registry", "client", "inproc", "service-profile"];
  add("no-arguments", []);
  add("no-core-input", ["--out", "mirror"]);
  add("no-core-output", input);
  add("check-and-output", [...input, "--check", "--out", "mirror"]);
  add("repeated-check", [...input, "--check", "--check"]);
  for (const flag of ["--sidecar", "--optimization", "--f64-slot", ...coreFlags]) add("core-missing-value-" + flag, [...input, "--check", flag]);
  add("unknown-core", [...input, "--check", "--wat"]);
  add("empty-core-argument", [...input, "--check", ""]);
  add("flag-consumed-as-input", ["--sidecar", "--check", "--out", "mirror"]);
  add("last-core-input", ["--sidecar", "missing", ...input, "--check"]);
  add("core-optimization-ignored-mirror", [...input, "--optimization", "invalid", "--out", "mirror"]);
  add("core-optimization-ignored-effective", [...input, "--optimization", "invalid", "--effective-sidecar", "effective"]);
  add("core-optimization-refused-check", [...input, "--optimization", "invalid", "--check"]);
  add("last-core-optimization", [...input, "--optimization", "invalid", "--optimization", "release", "--profile", "profile"]);
  for (let i = 0; i < coreFlags.length; i++) add("last-core-output-" + i, [...input, coreFlags[i], "old", coreFlags[i], outputs[i]]);
  add("reverse-core-outputs", [...input, ...coreFlags.flatMap((_, i) => [coreFlags[3 - i], outputs[3 - i]]), "--f64-slot", "Model.count"]);
  add("profile-relative-entry", [...input, "--profile", "nested/profile", "--facade", "facade", "--optimization", "dev"]);
  add("core-alias-before-decode", [...input, "--out", "./input.json"], "{");
  add("core-output-pair-alias", [...input, "--profile", "same", "--out", "same"]);
  add("core-staging-prefix-alias", [...input, "--out", "mirror", "--facade", "mirror.corewire-tmp"]);
  add("decode-before-slot", [...input, "--check", "--f64-slot", "Missing.count"], "{");
  add("slot-before-optimization", [...input, "--check", "--f64-slot", "Missing.count", "--optimization", "invalid"]);
  add("mirror-before-optimization", [...input, "--check", "--optimization", "invalid"], core.replace('"wire_version":10', '"wire_version":0'));
  add("facade-before-optimization", [...input, "--check", "--optimization", "invalid"], coreCases().find(c => c.name === "unbound-helper-shadow")!.input);
  add("check-demotion", [...input, "--check", "--f64-slot", "Model.count"]);
  add("check-duplicate-demotion", [...input, "--check", "--f64-slot", "Model.count", "--f64-slot", "Model.count"]);
  add("service-prefix-ignored", ["--unknown", "--sidecar", "ignored", "--optimization", "invalid", ...service, "--service-client", "client"]);
  add("service-prefix-output-flag-value", ["--out", "--service-client", "client", ...service]);
  add("unknown-service-after-input", [...service, "--unknown"]);
  add("core-flag-after-service", [...service, "--check"]);
  add("service-no-input", ["--service-client", "client"]);
  add("service-no-output", service);
  add("service-optimization-before-missing-input", ["--service-client", "client", "--optimization", "invalid"]);
  add("last-service-input", ["--services-sidecar", "missing", ...service, "--service-client", "client"]);
  add("last-service-optimization", [...service, "--optimization", "invalid", "--optimization", "dev", "--service-inproc-profile", "service-profile"]);
  for (const flag of ["--services-sidecar", "--optimization", ...serviceFlags]) add("service-missing-value-" + flag, [...service, flag]);
  for (let i = 0; i < serviceFlags.length; i++) add("last-service-output-" + i, [...service, serviceFlags[i], "old", serviceFlags[i], serviceOutputs[i]]);
  add("reverse-service-outputs", [...service, ...serviceFlags.flatMap((_, i) => [serviceFlags[4 - i], serviceOutputs[4 - i]]), "--optimization", "release"]);
  add("service-host-registry-case-alias", [...service, "--service-host-main", "SAME", "--service-registry", "same"]);
  add("service-sequential-client-over-registry", [...service, "--service-client", "same", "--service-registry", "same"]);
  add("service-sequential-profile-over-inproc", [...service, "--service-inproc-profile", "same", "--service-inproc-main", "same"]);
  return cases;
}
