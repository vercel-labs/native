import assert from "node:assert/strict";
import test from "node:test";
import { native_effect_policy } from "../src/runtime_policy.ts";
function request(mode: number, variant = 0, flags: readonly number[] = []): Uint8Array {
  const b = new Uint8Array(264); b.set([29, 1, mode, variant]);
  for (const i of flags) b[8 + i] = 1;
  return b;
}
function program(mode: number, variant: number, flags: readonly number[], values: readonly string[]): string {
  const input = request(mode, variant, flags), before = input.slice(), out = native_effect_policy(input);
  assert.deepEqual(input, before); assert.ok(out.length <= 16384);
  let text = "", at = 0;
  while (at < out.length) {
    const op = out[at++]!;
    if (op === 2) { text += `<children:${out[at++]!}>`; continue; }
    const count = out[at++]! | out[at++]! << 8;
    if (op === 0) { text += Buffer.from(out.subarray(at, at + count)).toString("latin1"); at += count; }
    else { assert.equal(op, 1); const format = out[at++]!; assert.ok(format <= 5); text += values[count] ?? `<slot:${count}>`; }
  }
  return text;
}
test("snapshot root owns complete traversal for all three output variants", () => {
  const fields = ["ffffffffffffffff", "18446744073709551615", "9007199254740993", "42", "43", "44", "45"];
  assert.equal(program(0,0,[7,8,10,11,12],fields), "ready=true protocol=0xffffffffffffffff frame=18446744073709551615 commands=9007199254740993 runtime_uptime_ns=42 dispatch_errors=43 dropped_trace_records=44 publisher_pid=45 markup_watch=armed\nframe_profile<children:0>\n<children:1><children:2><children:3><children:4><children:5><children:6><children:7><children:8><children:9><children:10>");
  assert.equal(program(0,1,[],[]), "a11y root=@w1 nodes=<slot:9>\n<children:1><children:2><children:3>");
  assert.equal(program(0,2,[8,10,11,12],[]), "<children:1>");
});
test("snapshot chunks preserve every byte and exact escape distinctions", () => {
  const all = Uint8Array.from({length:256},(_,i)=>i);
  for (const mode of [20,21]) for (let start=0;start<256;start+=17) {
    const input = new Uint8Array(8+Math.min(17,256-start));input.set([29,1,mode]);input.set(all.subarray(start,start+17),8);
    const expected = Array.from(input.subarray(8), byte => mode === 21 ? byte.toString(16).padStart(2,"0") : byte === 34 ? '\\"' : byte === 92 ? '\\\\' : byte === 10 ? '\\n' : byte === 13 ? '\\r' : byte === 9 ? '\\t' : byte < 32 || byte === 127 ? `\\u00${byte.toString(16).padStart(2,"0")}` : String.fromCharCode(byte)).join("");
    assert.equal(Buffer.from(native_effect_policy(input)).toString("latin1"), expected);
  }
});
test("snapshot widget state ordering presence and accessibility omit only placeholder", () => {
  const flags=Array.from({length:60},(_,i)=>i).filter(i=>i!==38), values=Array.from({length:60},(_,i)=>`v${i}`);
  const full=program(4,0,flags,values), a11y=program(4,1,flags,values);
  assert.ok(full.includes(' parent=#v11 value=v12 text="v13" placeholder="v14" grid=[row_index=v15,column_index=v16,row_count=v17,column_count=v18]'));
  assert.ok(full.includes(' state=[focused,disabled,hovered,pressed,selected,expanded,required,read_only,invalid] actions=[focus,press,toggle,increment,decrement,set_text,set_selection,select,drag,drop_files,dismiss] selection=v54..v55 composition=v57..v58 context_menu=[<children:11>]\n'));
  assert.ok(!a11y.includes("placeholder=")); assert.ok(a11y.includes(' text="v13" grid='));
  assert.ok(!program(4,0,[],values).includes("state="));
});
test("snapshot rich tray precedence and honest transport state are portable", () => {
  assert.equal(program(10,0,[0,2,4,8],[]),"  tray-item separator\n");
  assert.equal(program(10,0,[2,4,8],[]),"  tray-item #<slot:1> role=segmented options=<slot:3>\n<children:14>");
  assert.ok(program(10,0,[4,8],[]).includes(" role=metric primary="));
  assert.ok(program(10,0,[8],[]).includes(" role=chart caption="));
  for (const variant of [0,1,2]) assert.ok(program(13,variant,[1,2],[]).includes("state=buffering"));
  assert.ok(!program(13,0,[],[]).includes("spectrum_bands="));
  assert.ok(program(13,0,[6],[]).includes("spectrum_bands="));
});
test("snapshot malformed versions extents and flags refuse before output", () => {
  for (const length of [0,1,7,263,265]) assert.throws(()=>native_effect_policy(new Uint8Array(length).fill(29)));
  for (const at of [1,2,3,4,8,263]) { const b=request(0);b[at]=255;assert.throws(()=>native_effect_policy(b)); }
  const b=new Uint8Array(265);b.set([29,1,20]);assert.throws(()=>native_effect_policy(b));
});
