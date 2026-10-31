/** Exact native image identities, represented without a floating-point u64. */
export interface ImageIdentity { readonly imageLower: number; readonly imageUpper: number; }
function imageXor(a: ImageIdentity, b: ImageIdentity): ImageIdentity {
  return { imageLower: (a.imageLower ^ b.imageLower) >>> 0, imageUpper: (a.imageUpper ^ b.imageUpper) >>> 0 };
}
function imageMultiply(a: ImageIdentity, b: ImageIdentity): { productLower: ImageIdentity; productUpper: ImageIdentity } {
  // Sixteen-bit limbs keep every intermediate exactly representable in f64.
  const left = [a.imageLower & 65535, a.imageLower >>> 16, a.imageUpper & 65535, a.imageUpper >>> 16];
  const right = [b.imageLower & 65535, b.imageLower >>> 16, b.imageUpper & 65535, b.imageUpper >>> 16];
  const limbs = [0, 0, 0, 0, 0, 0, 0, 0];
  for (let i = 0; i < 4; i++) for (let j = 0; j < 4; j++) limbs[i + j] = limbs[i + j]! + left[i]! * right[j]!;
  for (let i = 0; i < 7; i++) { limbs[i + 1] = limbs[i + 1]! + Math.floor(limbs[i]! / 65536); limbs[i] = limbs[i]! % 65536; }
  return {
    productLower: { imageLower: (limbs[0]! + limbs[1]! * 65536) >>> 0, imageUpper: (limbs[2]! + limbs[3]! * 65536) >>> 0 },
    productUpper: { imageLower: (limbs[4]! + limbs[5]! * 65536) >>> 0, imageUpper: (limbs[6]! + limbs[7]! * 65536) >>> 0 },
  };
}
function imageMix(a: ImageIdentity, b: ImageIdentity): ImageIdentity {
  const product = imageMultiply(a, b); return imageXor(product.productLower, product.productUpper);
}

function imageRead(data: Uint8Array, offset: number, length: number): ImageIdentity {
  let lower = 0, upper = 0;
  for (let i = 0; i < length; i++) {
    if (i < 4) lower += data[offset + i]! * 2 ** (i * 8);
    else upper += data[offset + i]! * 2 ** ((i - 4) * 8);
  }
  return { imageLower: lower, imageUpper: upper };
}
/** Final Wyhash, seed zero, matching the native registry's document identities. */
export function imageSourceIdentity(input: Uint8Array): ImageIdentity {
  const secrets: ImageIdentity[] = [
    { imageLower: 0x78bd642f, imageUpper: 0xa0761d64 },
    { imageLower: 0xa0b428db, imageUpper: 0xe7037ed1 },
    { imageLower: 0x9c88c6e3, imageUpper: 0x8ebc6af0 },
    { imageLower: 0x75374cc3, imageUpper: 0x589965cc },
  ];
  const initial = imageMix(secrets[0]!, secrets[1]!);
  const state: ImageIdentity[] = [initial, initial, initial];
  const length = input.length;
  let a: ImageIdentity = { imageLower: 0, imageUpper: 0 };
  let b: ImageIdentity = { imageLower: 0, imageUpper: 0 };
  if (length <= 16) {
    if (length >= 4) {
      const end = length - 4, quarter = (length >>> 3) << 2;
      a = { imageLower: imageRead(input, quarter, 4).imageLower, imageUpper: imageRead(input, 0, 4).imageLower };
      b = { imageLower: imageRead(input, end - quarter, 4).imageLower, imageUpper: imageRead(input, end, 4).imageLower };
    } else if (length > 0) {
      a = { imageLower: input[0]! * 65536 + input[length >>> 1]! * 256 + input[length - 1]!, imageUpper: 0 };
    }
  } else {
    let at = 0;
    if (length >= 48) {
      while (at + 48 < length) {
        for (let j = 0; j < 3; j++) state[j] = imageMix(imageXor(imageRead(input, at + 16 * j, 8), secrets[j + 1]!), imageXor(imageRead(input, at + 16 * j + 8, 8), state[j]!));
        at += 48;
      }
      state[0] = imageXor(imageXor(state[0]!, state[1]!), state[2]!);
    }
    while (at + 16 < length) {
      state[0] = imageMix(imageXor(imageRead(input, at, 8), secrets[1]!), imageXor(imageRead(input, at + 8, 8), state[0]!));
      at += 16;
    }
    a = imageRead(input, length - 16, 8); b = imageRead(input, length - 8, 8);
  }
  const product = imageMultiply(imageXor(a, secrets[1]!), imageXor(b, state[0]!));
  const hash = imageMix(imageXor(imageXor(product.productLower, secrets[0]!), { imageLower: length, imageUpper: 0 }), imageXor(product.productUpper, secrets[1]!));
  // Bit 63 belongs to media surfaces; the five document effect keys are avoided.
  const upper = hash.imageUpper & 0x7fffffff;
  return { imageLower: upper === 0 && hash.imageLower <= 5 ? hash.imageLower + 16 : hash.imageLower, imageUpper: upper };
}
