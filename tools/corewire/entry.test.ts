import assert from "node:assert/strict";
import { test } from "node:test";
import { entryBegin, entryStep, entryPolicy, formatDiagnostics, readFailure } from "./entry_coordination.ts";
import type { EntryAction, EntryObservation } from "./entry_coordination.ts";
import { planInvocation, textBytes } from "./invocation.ts";
import path from "node:path";
import { invoke } from "./invocation_fixture.ts";
import type { InvocationCase } from "./invocation_cases.ts";
import { baseContract as coreContract } from "./core_cases.ts";
import { baseContract as serviceContract } from "./service_cases.ts";
const b = textBytes;
const core = planInvocation(["corewire", "--sidecar", "input", "--facade", "facade", "--profile", "profile"].map(b));
const service = planInvocation(["corewire", "--services-sidecar", "input", "--service-client", "client"].map(b));
const observation = (): EntryObservation => ({ plan: core, ok: true, message: [], exit_code: 0, paths: 3, diagnostics: [] });
function trace(plan = core, observe: (a: EntryAction) => Partial<EntryObservation> = () => ({})) {
  let state = entryBegin(), observed = observation(); const actions: EntryAction[] = [];
  for (let i=0; i<100; i++) {
    const result = entryStep(state, observed);state = result.state;actions.push(result.action);
    if (result.action.kind === "done") return { state, actions };
    observed = { ...observation(), plan, ...observe(result.action) };
  }
  throw new Error("entry coordinator failed to finish");
}
test("complete core invocation preserves alias observations before read and warnings before output", () => {
  const {state, actions} = trace(core,a => a.kind === "project" ? { diagnostics:b("warning\n") } : {});
  assert.equal(state.exit_code,0);
  assert.deepEqual(actions.map(a=>a.kind),["plan","canonical_input","alias_paths","canonical_output","canonical_output","canonical_output","identity_input","identity_pair","identity_pair","identity_input","identity_pair","identity_input","aliases","read_core","decode_core","relative_entry","project","diagnostic","flush","outputs","done"]);
  assert.deepEqual(actions.filter(a=>a.kind==="identity_pair").map(a=>[a.cursor,a.prior]),[[0,1],[0,2],[1,2]]);
  assert.deepEqual(actions.find(a=>a.kind==="diagnostic")?.message,b("warning\n"));
});
test("service mode bypasses core aliases and entry computation, flushing on complete success",()=>{
  assert.deepEqual(trace(service).actions.map(a=>a.kind),["plan","read_service","decode_service","outputs","flush","done"]);
  assert.deepEqual(trace(service,a=>a.kind==="outputs"?{exit_code:1}:{}).actions.map(a=>a.kind),["plan","read_service","decode_service","outputs","done"]);
});
test("argument refusal precedes every path capability",()=>{
  const bad=planInvocation(["corewire","--bad"].map(b)); const t=trace(bad);
  assert.equal(t.state.exit_code,2);assert.deepEqual(t.actions.map(a=>a.kind),["plan","diagnostic","flush","done"]);
  assert.deepEqual(t.actions[1].message,bad.error);
});
for(const failure of ["aliases","read_core","decode_core","project"]) test(`${failure} refusal prevents later capabilities and preserves exit and diagnostic selection`,()=>{
  const t=trace(core,a=>a.kind===failure?{ok:false,message:failure==="decode_core"?[]:b("explicit"),diagnostics:b("fields"),exit_code:2}:{});
  const names=t.actions.map(a=>a.kind);assert.equal(names.includes("outputs"),false);
  assert.equal(t.state.exit_code,failure==="aliases"||failure==="project"?2:1);
  assert.deepEqual(t.actions.at(-3)?.message,b(failure==="decode_core"?"fields":"explicit"));
  assert.deepEqual(names.slice(-3),["diagnostic","flush","done"]);
});
test("projection field diagnostics are used only in the absence of explicit error",()=>{
  const t=trace(core,a=>a.kind==="project"?{message:[],exit_code:1,diagnostics:b("fields")}:{});
  assert.deepEqual(t.actions.at(-3)?.message,b("fields"));
});
test("facade-only and no-facade invocation retain independent entry selection",()=>{
  const facade=planInvocation(["corewire","--sidecar","input","--facade","facade"].map(b));assert.ok(trace(facade).actions.some(a=>a.kind==="basename_entry"));
  const check=planInvocation(["corewire","--sidecar","input","--check"].map(b));assert.ok(!trace(check).actions.some(a=>a.kind.endsWith("_entry")));
});
test("diagnostic formatting preserves ordered raw bytes, empty fields and exact punctuation",()=>{
  assert.deepEqual(formatDiagnostics([255,0],[{path:[],message:[128,10],severity:"error"},{path:[65,0],message:[255],severity:"warning"}]),[255,0,...b(": error: "),128,10,10,255,0,...b(": warning: "),65,0,58,32,255,10]);
  assert.deepEqual(readFailure([255,0],[128]),[...b("corewire: cannot read "),255,0,58,32,128,10]);
});
test("entry ABI retains raw malformed bytes and normalizes only relative Windows separators",()=>{
  const run=(v:object)=>JSON.parse(entryPolicy(JSON.stringify({operation:"entry",payload:JSON.stringify({bytes:[97,92,98],relative:true,windows:true,absolute:false,valid_utf8:true,facade:[255],directory:[128],...v})})));
  assert.deepEqual(run({}),{text:"a/b",bytes:[97,47,98],utf8:true,unrelated:false,facade_path:[255],profile_directory:[128]});
  assert.equal(run({relative:false}).text,"a\\b");
  assert.deepEqual(run({bytes:[255,0],valid_utf8:false}).bytes,[255,0]);assert.equal(run({bytes:[],valid_utf8:true}).unrelated,true);
  assert.equal(run({bytes:b("\uFEFFé😀.ts")}).text,"\uFEFFé😀.ts");
});
for (const kind of ["read_service", "decode_service"]) test(`${kind} refusal terminates before every service output`, () => {
  const t = trace(service, a => a.kind === kind ? { ok: false, message: b("read"), diagnostics: b("decode") } : {});
  assert.equal(t.state.exit_code, 1);
  assert.equal(t.actions.some(a => a.kind === "outputs"), false);
  assert.deepEqual(t.actions.at(-3)?.message, b(kind === "read_service" ? "read" : "decode"));
});

if (process.argv[2] && process.argv[3]) {
  const candidate = path.resolve(process.argv[2]), reference = path.resolve(process.argv[3]);
  const core = JSON.stringify(coreContract(), (key, value) => (key === "origin" || key === "member") && value === null ? undefined : value);
  const services = JSON.stringify(serviceContract());
  const cases: InvocationCase[] = [];
  const add = (name: string, args: string[], fields: Partial<InvocationCase> = {}) => cases.push({ name, args, core, services, directories: ["nested"], ...fields });
  for (const name of ["\uFEFFfacade.ts", "é😀.ts", "quote\".ts", "line\n.ts"]) {
    for (const profile of [false, true]) add("raw entry " + JSON.stringify(name) + (profile ? " with profile" : " basename"),
      ["--sidecar", "input.json", "--facade", name, ...(profile ? ["--profile", "profile"] : [])]);
  }
  for (const input of ["{", "null", "{}", core.replace('"wire_version":10', '"wire_version":0')])
    add("core decode " + input.slice(0, 30), ["--sidecar", "input.json", "--out", "mirror"], { core: input });
  const warnings = core.slice(0, -1) + ',"future_entry_field":true}';
  add("warnings before successful check", ["--sidecar", "input.json", "--check"], { core: warnings });
  add("explicit projection refusal supersedes additive warnings", ["--sidecar", "input.json", "--check", "--optimization", "invalid"], { core: warnings });
  add("core read failure", ["--sidecar", "missing", "--check"]);
  add("service read failure", ["--services-sidecar", "missing", "--service-client", "client"]);
  for (const input of ["{", "null", "{}", services.replace('"format":3', '"format":0'), services.replace('"deterministic":false', '"deterministic":true')])
    add("service decode " + input.slice(0, 30), ["--services-sidecar", "services.json", "--service-client", "client"], { services: input });
  for (const item of cases) test("complete entry native reference: " + item.name, () => {
    assert.deepEqual(invoke(candidate, item), invoke(reference, item));
  });
}
