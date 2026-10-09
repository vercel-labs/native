/** Exact seed-zero Wyhash words used for saved editor snapshots. */
export interface ContentHash { readonly hash_lower: number; readonly hash_upper: number; }
function hashXor(a: ContentHash, b: ContentHash): ContentHash {
  return { hash_lower: (a.hash_lower ^ b.hash_lower) >>> 0, hash_upper: (a.hash_upper ^ b.hash_upper) >>> 0 };
}
function hashMultiply(a: ContentHash, b: ContentHash): { productLower: ContentHash; productUpper: ContentHash } {
  // Sixteen-bit limbs keep every intermediate exactly representable in f64.
  const left = [a.hash_lower & 65535, a.hash_lower >>> 16, a.hash_upper & 65535, a.hash_upper >>> 16];
  const right = [b.hash_lower & 65535, b.hash_lower >>> 16, b.hash_upper & 65535, b.hash_upper >>> 16];
  const limbs = [0, 0, 0, 0, 0, 0, 0, 0];
  for (let i = 0; i < 4; i++) for (let j = 0; j < 4; j++) limbs[i + j] = limbs[i + j]! + left[i]! * right[j]!;
  for (let i = 0; i < 7; i++) { limbs[i + 1] = limbs[i + 1]! + Math.floor(limbs[i]! / 65536); limbs[i] = limbs[i]! % 65536; }
  const lower0 = limbs[0]! + limbs[1]! * 65536, upper0 = limbs[2]! + limbs[3]! * 65536;
  const lower1 = limbs[4]! + limbs[5]! * 65536, upper1 = limbs[6]! + limbs[7]! * 65536;
  return {
    productLower: { hash_lower: lower0 > 0 && lower0 <= 4294967295 ? Math.trunc(lower0) : 0, hash_upper: upper0 > 0 && upper0 <= 4294967295 ? Math.trunc(upper0) : 0 },
    productUpper: { hash_lower: lower1 > 0 && lower1 <= 4294967295 ? Math.trunc(lower1) : 0, hash_upper: upper1 > 0 && upper1 <= 4294967295 ? Math.trunc(upper1) : 0 },
  };
}
function hashMix(a: ContentHash, b: ContentHash): ContentHash {
  const product = hashMultiply(a, b); return hashXor(product.productLower, product.productUpper);
}

function hashRead(data: Uint8Array, offset: number, length: number): ContentHash {
  let lower = 0, upper = 0, power = 1;
  for (let i = 0; i < length; i++) {
    if (i === 4) power = 1;
    if (i < 4) lower += data[Math.trunc(offset + i)]! * power;
    else upper += data[Math.trunc(offset + i)]! * power;
    power *= 256;
  }
  return { hash_lower: lower > 0 && lower <= 4294967295 ? Math.trunc(lower) : 0, hash_upper: upper > 0 && upper <= 4294967295 ? Math.trunc(upper) : 0 };
}
/** Full final Wyhash, seed zero, with all 64 bits retained. */
export function contentHash(input: Uint8Array): ContentHash {
  const secrets: ContentHash[] = [
    { hash_lower: 0x78bd642f, hash_upper: 0xa0761d64 },
    { hash_lower: 0xa0b428db, hash_upper: 0xe7037ed1 },
    { hash_lower: 0x9c88c6e3, hash_upper: 0x8ebc6af0 },
    { hash_lower: 0x75374cc3, hash_upper: 0x589965cc },
  ];
  const initial = hashMix(secrets[0]!, secrets[1]!);
  const state: ContentHash[] = [initial, initial, initial];
  const rawLength = input.length;
  const length = rawLength > 0 && rawLength <= 4294967295 ? Math.trunc(rawLength) : 0;
  let a: ContentHash = { hash_lower: 0, hash_upper: 0 };
  let b: ContentHash = { hash_lower: 0, hash_upper: 0 };
  if (length <= 16) {
    if (length >= 4) {
      const end = length - 4, quarter = (length >>> 3) << 2;
      a = { hash_lower: hashRead(input, quarter, 4).hash_lower, hash_upper: hashRead(input, 0, 4).hash_lower };
      b = { hash_lower: hashRead(input, end - quarter, 4).hash_lower, hash_upper: hashRead(input, end, 4).hash_lower };
    } else if (length > 0) {
      const short = input[0]! * 65536 + input[length >>> 1]! * 256 + input[length - 1]!;
      a = { hash_lower: short > 0 && short <= 16777215 ? Math.trunc(short) : 0, hash_upper: 0 };
    }
  } else {
    let at = 0;
    if (length >= 48) {
      while (at + 48 < length) {
        for (let j = 0; j < 3; j++) state[j] = hashMix(hashXor(hashRead(input, at + 16 * j, 8), secrets[j + 1]!), hashXor(hashRead(input, at + 16 * j + 8, 8), state[j]!));
        at += 48;
      }
      state[0] = hashXor(hashXor(state[0]!, state[1]!), state[2]!);
    }
    while (at + 16 < length) {
      state[0] = hashMix(hashXor(hashRead(input, at, 8), secrets[1]!), hashXor(hashRead(input, at + 8, 8), state[0]!));
      at += 16;
    }
    a = hashRead(input, length - 16, 8); b = hashRead(input, length - 8, 8);
  }
  const product = hashMultiply(hashXor(a, secrets[1]!), hashXor(b, state[0]!));
  const hash = hashMix(hashXor(hashXor(product.productLower, secrets[0]!), { hash_lower: length, hash_upper: 0 }), hashXor(product.productUpper, secrets[1]!));
  return hash;
}
