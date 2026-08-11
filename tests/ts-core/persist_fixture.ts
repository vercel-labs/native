// Focused compiled-core fixture for Storage Tier 1. The model is deliberately
// small so the Zig battery can prove snapshot/restore/migration behavior
// without coupling persistence to one of the showcase apps.

import { Cmd, asciiBytes } from "@native-sdk/core";

export interface Model {
  readonly value: number;
  readonly label: Uint8Array;
  readonly restoreState: number;
  readonly lastError: Uint8Array;
}

export type Msg =
  | { readonly kind: "increment_and_persist" }
  | { readonly kind: "restored" }
  | { readonly kind: "fresh_boot" }
  | { readonly kind: "restore_failed"; readonly reason: Uint8Array };

export type MigrateError = { readonly kind: "unsupported_persist_version" };

export function initialModel(): [Model, Cmd<Msg>] {
  return [
    {
      value: 0,
      label: asciiBytes("initial"),
      restoreState: 0,
      lastError: asciiBytes(""),
    },
    Cmd.none,
  ];
}

export function update(model: Model, msg: Msg): [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "increment_and_persist":
      return [{
        ...model,
        value: model.value < 9007199254740991 ? model.value + 1 : model.value,
      }, Cmd.persist()];
    case "restored":
      return [{ ...model, restoreState: 1 }, Cmd.none];
    case "fresh_boot":
      return [{ ...model, restoreState: 2 }, Cmd.none];
    case "restore_failed":
      return [{ ...model, restoreState: 3, lastError: msg.reason }, Cmd.none];
  }
}

// Version 1 is the accepted legacy format in the battery. Version 2 throws,
// pinning the closed migrate_failed path independently of malformed bytes.
export function migrate(snapshot: Uint8Array, fromVersion: number): Model {
  if (fromVersion === 1) {
    return {
      value: 101,
      label: snapshot,
      restoreState: 0,
      lastError: asciiBytes(""),
    };
  }
  const err: MigrateError = { kind: "unsupported_persist_version" };
  throw err;
}

export const viewUnbound = [
  "increment_and_persist",
  "restored",
  "fresh_boot",
  "restore_failed",
  "restoreState",
  "lastError",
] as const;
