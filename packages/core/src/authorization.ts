/** Complete byte-preserving authorization over native-owned policy tables.
 * Lengths/counts are exact little-endian words, never hashes or truncated text.
 * Native owns transport storage, JSON parsing, handlers and OS execution.
 */
type NscAuthorizationCommand = { name: Uint8Array; grants: Uint8Array[]; origins: Uint8Array[] };
class NscAuthorizationReader {
  bytes: Uint8Array;
  at: number;
  constructor(bytes: Uint8Array) { this.bytes = bytes; this.at = 8; }
  integer(): number {
    if (this.at > this.bytes.length - 8) throw new Error("truncated authorization length");
    const data = new DataView(this.bytes.buffer, this.bytes.byteOffset, this.bytes.byteLength);
    const low = data.getUint32(this.at, true), high = data.getUint32(this.at + 4, true);
    this.at += 8;
    if (high > 2097151) throw new Error("invalid authorization integer");
    return low + high * 4294967296;
  }
  count(): number {
    const value = this.integer();
    if (value > this.bytes.length - this.at) throw new Error("invalid authorization extent");
    return value;
  }
  field(): Uint8Array {
    const count = this.count(), value = this.bytes.slice(this.at, this.at + count);
    this.at += count;
    return value;
  }
  list(): Uint8Array[] {
    const count = this.count();
    if (count > Math.floor((this.bytes.length - this.at) / 8)) throw new Error("invalid authorization table");
    const values: Uint8Array[] = [];
    for (let i = 0; i < count; i++) values.push(this.field());
    return values;
  }
  commands(): NscAuthorizationCommand[] {
    const count = this.count();
    if (count > Math.floor((this.bytes.length - this.at) / 24)) throw new Error("invalid authorization commands");
    const values: NscAuthorizationCommand[] = [];
    for (let i = 0; i < count; i++) values.push({ name: this.field(), grants: this.list(), origins: this.list() });
    return values;
  }
  finish(): void { if (this.at !== this.bytes.length) throw new Error("trailing authorization bytes"); }
}
function nscAuthorizationEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}
function nscAuthorizationMember(values: Uint8Array[], value: Uint8Array, wildcard: boolean): boolean {
  for (const candidate of values) {
    if (wildcard && candidate.length === 1 && candidate[0] === 42) return true;
    if (nscAuthorizationEqual(candidate, value)) return true;
  }
  return false;
}
function nscAuthorizationGrants(grants: Uint8Array[], required: Uint8Array[]): boolean {
  for (const value of required) if (!nscAuthorizationMember(grants, value, false)) return false;
  return true;
}
function nscAuthorizationPrefix(bytes: Uint8Array, prefix: readonly number[]): boolean {
  if (bytes.length < prefix.length) return false;
  for (let i = 0; i < prefix.length; i++) if (bytes[i] !== prefix[i]) return false;
  return true;
}
function nscAuthorizationHttp(bytes: Uint8Array): number {
  if (nscAuthorizationPrefix(bytes, [104, 116, 116, 112, 115, 58, 47, 47])) return 8;
  if (nscAuthorizationPrefix(bytes, [104, 116, 116, 112, 58, 47, 47])) return 7;
  return 0;
}
function nscAuthorizationExternal(action: boolean, allowed: Uint8Array[], url: Uint8Array): boolean {
  if (!action) return false;
  for (const pattern of allowed) {
    if (pattern.length === 1 && pattern[0] === 42 || nscAuthorizationEqual(pattern, url)) return true;
    if (pattern.length === 0 || pattern[pattern.length - 1] !== 42) continue;
    const scheme = nscAuthorizationHttp(pattern);
    if (scheme === 0) continue;
    let slash = -1;
    for (let i = scheme; i < pattern.length - 1; i++) if (pattern[i] === 47) { slash = i; break; }
    if (slash <= scheme || url.length < pattern.length - 1) continue;
    let same = true;
    for (let i = 0; i < pattern.length - 1; i++) if (pattern[i] !== url[i]) { same = false; break; }
    if (same) return true;
  }
  return false;
}
function nscAuthorizationBridge(enabled: boolean, grants: Uint8Array[], commands: NscAuthorizationCommand[], command: Uint8Array, origin: Uint8Array): boolean {
  if (!enabled) return false;
  for (const candidate of commands) {
    if (!nscAuthorizationEqual(candidate.name, command)) continue;
    return nscAuthorizationGrants(grants, candidate.grants) &&
      (candidate.origins.length === 0 || nscAuthorizationMember(candidate.origins, origin, true));
  }
  return false;
}
function nscvAuthorization(request: Uint8Array): Uint8Array {
  if (request.length < 8 || request[0] !== 88 || request[1] !== 1 || request[2]! > 6) throw new Error("invalid authorization header");
  for (let i = 3; i < 7; i++) if (request[i]! > 1) throw new Error("invalid authorization flag");
  if (request[7] !== 0) throw new Error("invalid authorization reserve");
  const mode = request[2]!, reader = new NscAuthorizationReader(request);
  const result = new Uint8Array(16), out = new DataView(result.buffer);
  out.setUint32(0, 1, true); out.setUint32(4, mode, true);
  let allowed = false, error = 0;
  if (mode === 0) {
    const grants = reader.list(), required = reader.field();
    allowed = nscAuthorizationMember(grants, required, false);
  } else if (mode === 1) {
    const grants = reader.list(), required = reader.list();
    allowed = nscAuthorizationGrants(grants, required);
  } else if (mode === 2) {
    const origins = reader.list(), origin = reader.field();
    allowed = nscAuthorizationMember(origins, origin, true);
  } else if (mode === 3 || mode === 6) {
    const urls = reader.list(), url = reader.field();
    if (mode === 6) {
      const limit = reader.integer();
      if (url.length === 0) error = 1;
      else if (url.length > limit) error = 2;
      else if (nscAuthorizationHttp(url) === 0) error = 1;
      else for (const byte of url) if (byte <= 32 || byte === 127) { error = 1; break; }
    }
    allowed = error === 0 && nscAuthorizationExternal(request[3] === 1, urls, url);
    if (mode === 6 && error === 0 && !allowed) error = 3;
  } else if (mode === 4) {
    const grants = reader.list(), commands = reader.commands(), command = reader.field(), origin = reader.field();
    allowed = nscAuthorizationBridge(request[3] === 1, grants, commands, command, origin);
  } else {
    const security = reader.list(), grants = reader.list(), commands = reader.commands(), origins = reader.list();
    const command = reader.field(), origin = reader.field(), permission = reader.field();
    if (request[3] === 1) allowed = nscAuthorizationBridge(true, security.length > 0 ? security : grants, commands, command, origin);
    else if (request[4] === 1 && request[5] === 1 && nscAuthorizationMember(origins, origin, true)) {
      allowed = security.length === 0 || nscAuthorizationMember(security, permission, false) ||
        nscAuthorizationMember(security, new Uint8Array([119, 105, 110, 100, 111, 119]), false);
    }
  }
  reader.finish(); out.setUint32(8, allowed ? 1 : 0, true); out.setUint32(12, error, true);
  return result;
}
