import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["runtime_policy.ts", "bridge_descriptors.ts"].map(n => readFileSync(new URL(`../src/${n}`, import.meta.url), "utf8")).join("\n");
const { nscvBridgeDescriptors: derive, native_window_policy: dispatch } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvBridgeDescriptors };").toString("base64")}`);
function packet(mode: number, tail = 0): Uint8Array { const b = new Uint8Array(96 + tail); b.set([87, 1, mode]); return b; }
function word(b: Uint8Array, at: number, value: number): void { new DataView(b.buffer).setUint32(at, value, true); }
function wide(b: Uint8Array, at: number, value: bigint): void { new DataView(b.buffer).setBigUint64(at, value, true); }
function number(b: Uint8Array, at: number, value: number): void { new DataView(b.buffer).setFloat64(at, value, true); }
function result(b: Uint8Array): DataView { const r = derive(b); assert.deepEqual(r, dispatch(b)); return new DataView(r.buffer); }
function choice(family: number, value: string | Uint8Array, length?: bigint): number {
  const bytes = typeof value === "string" ? new TextEncoder().encode(value) : value, count = Math.min(bytes.length, 64);
  const b = packet(0, count); b[3] = family; wide(b, 8, length ?? BigInt(bytes.length)); b.set(bytes.subarray(0,count),96);
  return result(b).getUint32(16,true);
}
test("bridge choices preserve canonical and compatibility names without normalization", () => {
  const groups = [["webview","toolbar","titlebar_accessory","sidebar","statusbar","split","stack","button","icon_button","list_item","checkbox","toggle","segmented_control","text_field","search_field","label","spacer","gpu_surface","progress_indicator"], ["standard","hidden_inset","hidden_inset_tall","chromeless"], ["none","metal","direct2d","software"], ["none","bgra8_unorm"], ["none","timer"], ["none","opaque","premultiplied"], ["none","srgb","display_p3"], ["main_webview","child_webviews","native_views","native_control_commands","menus","tray","shortcuts","dialogs","clipboard_text","clipboard_rich_data","open_url","reveal_path","notifications","recent_documents","credentials","file_drops","app_activation_events","gpu_surfaces","gpu_surface_scroll_drivers","context_menus","view_surface_adoption","audio_playback","audio_streaming","audio_spectrum","microphone_capture","system_audio_capture","window_hide_on_close","video_playback","global_shortcuts"]];
  groups.forEach((names, family) => names.forEach((name,index) => assert.equal(choice(family,name), index+1)));
  for (const [family,alias,expected] of [[0,"titlebarAccessory",3],[0,"gpuSurface",18],[0,"progressIndicator",19],[1,"hiddenInsetTall",3],[7,"gpuSurfaceScrollDrivers",19],[7,"videoPlayback",28],[7,"globalShortcuts",29]] as const) assert.equal(choice(family,alias),expected);
  for (let family=0; family<8; family++) for (const name of [""," NONE","none ","UNKNOWN","gpuSurface\0",new Uint8Array([255]),"x".repeat(65)]) assert.equal(choice(family,name),0);
  assert.equal(choice(0,new Uint8Array(64),1n<<32n),0);
});
test("GPU options preserve all defaults, nullable facts and complete ordered refusal", () => {
  const b=packet(1); for(let i=0;i<5;i++) word(b,16+i*4,4294967295);
  assert.deepEqual(Array.from({length:6},(_,i)=>result(b).getUint32(16+i*4,true)),[1,1,1,1,1,1]);
  b[4]=1; assert.equal(result(b).getUint32(36,true),0); b[4]=2; assert.equal(result(b).getUint32(36,true),1);
  for(let i=0;i<5;i++){word(b,16+i*4,0);assert.equal(result(b).getUint32(8,true),8);word(b,16+i*4,1);assert.equal(result(b).getUint32(16+i*4,true),0);}
});
test("window ownership compares every u64 bit beyond JavaScript safe integers", () => {
  for(const web of [0,1]) for(const owner of [0n,1n,9007199254740992n,9007199254740993n,(1n<<64n)-1n]) {
    const b=packet(2);b[3]=web;wide(b,16,owner); assert.equal(result(b).getBigUint64(16,true),owner);
    b[4]=1;assert.equal(result(b).getUint32(8,true),web?1:3);b[5]=1;wide(b,24,owner);assert.equal(result(b).getUint32(8,true),0);
    wide(b,24,owner^1n);assert.equal(result(b).getUint32(8,true),web?2:4);
  }
});
test("view and WebView frames retain different zero-size and optional-field rules", () => {
  for(const web of [0,1]) {
    const b=packet(3);b[3]=web;assert.equal(result(b).getUint32(8,true),web?6:0);
    b[4]=1;assert.equal(result(b).getUint32(8,true),web?6:5);b[5]=1;b[6]=1;b[7]=1;
    assert.equal(result(b).getUint32(8,true),web?6:0);
    number(b,32,1);number(b,40,1);number(b,16,-1);number(b,24,-1);
    assert.equal(result(b).getUint32(8,true),0);b[8]=1;assert.equal(result(b).getUint32(8,true),web?6:5);
    number(b,16,0);b[9]=1;assert.equal(result(b).getUint32(8,true),web?6:5);
    number(b,24,0);for(const width of [0,-1,1,Infinity,NaN]){number(b,32,width);assert.equal(result(b).getUint32(8,true),width<0||web&&width===0?web?6:5:0);}
  }
});
test("layer decisions retain defaults and exact signed i32 admission", () => {
  for(const web of [0,1]) {
    const b=packet(4);b[3]=web;assert.equal(result(b).getUint32(12,true),web);b[4]=1;
    assert.equal(result(b).getUint32(8,true),web?6:5);b[5]=1;
    for(const layer of [-2147483649,-2147483648,-0,0,2147483647,2147483648,.5,NaN,Infinity,-Infinity]) {
      number(b,16,layer);const valid=Number.isFinite(layer)&&Math.trunc(layer)===layer&&layer>=-2147483648&&layer<=2147483647;
      assert.equal(result(b).getUint32(8,true),valid?0:web?6:5);if(valid)assert.equal(result(b).getFloat64(16,true),layer);
    }
  }
});
function origin(url: string, capacity: bigint, chunk: number): [number,bigint,number] {
  const bytes=new TextEncoder().encode(url);let offset=0,state=0;
  while(true){const count=Math.min(chunk,bytes.length-offset),b=packet(5,count);b[3]=Number(offset+count===bytes.length);word(b,8,count);wide(b,16,BigInt(bytes.length));wide(b,24,BigInt(offset));wide(b,32,capacity);word(b,40,state);b.set(bytes.subarray(0,6),48);b.set(bytes.subarray(offset,offset+count),96);
    const r=result(b),status=r.getUint32(8,true);if(status!==2)return [status,r.getBigUint64(16,true),r.getUint32(12,true)];state=r.getUint32(24,true);offset+=count;
  }
}
test("URL origins stream scheme and host delimiters across every chunk boundary", () => {
  for(const chunk of [1,2,3,5,6,7,255,256]) {
    assert.deepEqual(origin("about:anything",0n,chunk),[0,0n,1]);
    for(const suffix of ["","/path","?query","#fragment"])assert.deepEqual(origin("odd://host"+suffix,10n,chunk),[0,10n,0]);
    for(const url of ["","://",":///host","https:///","https://?x","no-scheme"] )assert.equal(origin(url,1000n,chunk)[0],6);
    assert.equal(origin("odd://host",9n,chunk)[0],6);
    const url="x".repeat(254)+"://"+"h".repeat(260)+"/tail";assert.deepEqual(origin(url,517n,chunk),[0,517n,0]);
  }
  const b=packet(5,1);word(b,8,1);wide(b,16,(1n<<32n)+1n);wide(b,24,(1n<<32n)-1n);wide(b,32,1n<<40n);word(b,40,4);b[96]=47;const r=result(b);assert.equal(r.getUint32(8,true),0);assert.equal(r.getBigUint64(16,true),(1n<<32n)-1n);
});
test("descriptor transport rejects truncation and retains nonzero byte offsets", () => {
  const b=packet(2);wide(b,16,9007199254740993n);for(let n=0;n<96;n++)assert.throws(()=>derive(b.subarray(0,n)));
  const backing=new Uint8Array(112);backing.set(b,7);assert.deepEqual(derive(backing.subarray(7,103)),derive(b));
  for(const [at,value] of [[0,86],[1,2],[2,6],[3,2],[4,2],[5,2]]){const copy=b.slice();copy[at!]=value!;assert.throws(()=>derive(copy));}
});
