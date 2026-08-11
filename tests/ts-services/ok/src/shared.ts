interface SharedFailure {
  readonly kind: "fixture_failure";
  readonly message: "requested failure";
}

export function sharedFailure(): Uint8Array {
  throw { kind: "fixture_failure", message: "requested failure" } as SharedFailure;
}
