// Wyhash (the final version, as Zig's std.hash.Wyhash implements it),
// one-shot form. The contract sidecar's synthesized identity fields hash
// the reflected surface with this function so the frontend-emitted
// document and the extraction-path document agree byte for byte on
// identical surfaces (tools/corewire/extract.zig hashes the same bytes
// with std.hash.Wyhash). BigInt-based: the transpiler is a build-time
// tool and the inputs are small.

const M64 = (1n << 64n) - 1n;

const SECRET = [0xa0761d6478bd642fn, 0xe7037ed1a0b428dbn, 0x8ebc6af09c88c6e3n, 0x589965cc75374cc3n] as const;

function mix(aIn: bigint, bIn: bigint): bigint {
  const x = (aIn & M64) * (bIn & M64);
  return (x & M64) ^ ((x >> 64n) & M64);
}

/// Little-endian read of `n` bytes at `offset`.
function read(data: Uint8Array, offset: number, n: number): bigint {
  let v = 0n;
  for (let i = n - 1; i >= 0; i--) v = (v << 8n) | BigInt(data[offset + i]);
  return v;
}

export function wyhash(seed: bigint, input: Uint8Array): bigint {
  const len = input.length;
  const state = new Array<bigint>(3);
  state[0] = (seed ^ mix(seed ^ SECRET[0], SECRET[1])) & M64;
  state[1] = state[0];
  state[2] = state[0];
  let a = 0n;
  let b = 0n;

  if (len <= 16) {
    if (len >= 4) {
      const end = len - 4;
      const quarter = (len >> 3) << 2;
      a = ((read(input, 0, 4) << 32n) | read(input, quarter, 4)) & M64;
      b = ((read(input, end, 4) << 32n) | read(input, end - quarter, 4)) & M64;
    } else if (len > 0) {
      a = (BigInt(input[0]) << 16n) | (BigInt(input[len >> 1]) << 8n) | BigInt(input[len - 1]);
      b = 0n;
    }
  } else {
    let i = 0;
    if (len >= 48) {
      while (i + 48 < len) {
        for (let j = 0; j < 3; j++) {
          const x = read(input, i + 8 * (2 * j), 8);
          const y = read(input, i + 8 * (2 * j + 1), 8);
          state[j] = mix(x ^ SECRET[j + 1], y ^ state[j]);
        }
        i += 48;
      }
      state[0] = state[0] ^ state[1] ^ state[2];
    }
    // The tail: 16-byte lanes relative to the last block start, then the
    // final 16 bytes of the WHOLE input.
    let k = i;
    while (k + 16 < len) {
      state[0] = mix(read(input, k, 8) ^ SECRET[1], read(input, k + 8, 8) ^ state[0]);
      k += 16;
    }
    a = read(input, len - 16, 8);
    b = read(input, len - 8, 8);
  }

  a = a ^ SECRET[1];
  b = b ^ state[0];
  const x = (a & M64) * (b & M64);
  a = x & M64;
  b = (x >> 64n) & M64;
  return mix(a ^ SECRET[0] ^ BigInt(len), b ^ SECRET[1]);
}

/// The sidecar's identity spelling: 16 lowercase hex digits.
export function wyhashHex(seed: bigint, input: Uint8Array): string {
  return wyhash(seed, input).toString(16).padStart(16, "0");
}
