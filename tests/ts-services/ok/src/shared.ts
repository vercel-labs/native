interface SharedFailure {
  readonly kind: "fixture_failure";
  readonly message: "requested failure";
}

export type ParseRequest = {
  readonly source: Uint8Array;
  readonly caseSensitive: boolean;
};

export type ParseResult = {
  readonly bytes: Uint8Array;
  readonly matches: boolean;
  readonly facts: number;
};

export type ParseChunk = {
  readonly bytes: Uint8Array;
  readonly index: number;
};

export function sharedFailure(): ParseResult {
  throw { kind: "fixture_failure", message: "requested failure" } as SharedFailure;
}
