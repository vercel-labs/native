// Record-store example: every database interaction is inert Cmd data and
// every observation returns through an ordinary Msg after the model commits.

import { Cmd, utf8Bytes } from "@native-sdk/core";

const ACTIVE_KEY = "drafts/current";

export interface Model {
  readonly recordCount: number;
  readonly current: Uint8Array;
  readonly present: boolean;
  readonly status: Uint8Array;
}

export type Msg =
  | { readonly kind: "seed" }
  | { readonly kind: "seeded" }
  | { readonly kind: "load" }
  | { readonly kind: "loaded"; readonly result: Uint8Array }
  | { readonly kind: "save" }
  | { readonly kind: "saved" }
  | { readonly kind: "remove" }
  | { readonly kind: "removed" }
  | { readonly kind: "refresh" }
  | { readonly kind: "scanned"; readonly page: Uint8Array }
  | { readonly kind: "store_failed"; readonly reason: Uint8Array };

export const viewUnbound = ["seeded", "loaded", "saved", "removed", "scanned", "store_failed"] as const;

function pageCount(page: Uint8Array): number {
  if (page.length < 4) return 0;
  return page[0] + page[1] * 256 + page[2] * 65536 + page[3] * 16777216;
}

export function initialModel(): [Model, Cmd<Msg>] {
  return [
    {
      recordCount: 0,
      current: new Uint8Array(0),
      present: false,
      status: utf8Bytes("Loading the drafts/ prefix…"),
    },
    Cmd.store.scan("drafts/", { limit: 16 }, {
      key: "scan-drafts",
      ok: "scanned",
      err: "store_failed",
    }),
  ];
}

export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "seed":
      return [
        { ...model, status: utf8Bytes("Writing three records atomically…") },
        Cmd.store.setMany([
          [ACTIVE_KEY, utf8Bytes("A saved draft from the record store")],
          ["drafts/archive/1", utf8Bytes("First archived draft")],
          ["drafts/archive/2", utf8Bytes("Second archived draft")],
        ], { key: "seed-drafts", ok: "seeded", err: "store_failed" }),
      ];
    case "seeded":
    case "refresh":
      return [
        { ...model, status: utf8Bytes("Scanning drafts/…") },
        Cmd.store.scan("drafts/", { limit: 16 }, {
          key: "scan-drafts",
          ok: "scanned",
          err: "store_failed",
        }),
      ];
    case "scanned": {
      const decoded = pageCount(msg.page);
      const count = decoded >= 0 && decoded <= 256 ? Math.trunc(decoded) : 0;
      return { ...model, recordCount: count, status: utf8Bytes("Prefix page loaded") };
    }
    case "load":
      return [
        { ...model, status: utf8Bytes("Loading drafts/current…") },
        Cmd.store.get(ACTIVE_KEY, {
          key: "load-current",
          ok: "loaded",
          err: "store_failed",
        }),
      ];
    case "loaded":
      return msg.result[0] === 1
        ? {
            ...model,
            current: msg.result.subarray(1),
            present: true,
            status: utf8Bytes("Record loaded"),
          }
        : {
            ...model,
            current: new Uint8Array(0),
            present: false,
            status: utf8Bytes("Record is absent"),
          };
    case "save":
      return [
        { ...model, status: utf8Bytes("Saving drafts/current…") },
        Cmd.store.set(
          ACTIVE_KEY,
          utf8Bytes("Updated independently of every other record"),
          { key: "save-current", ok: "saved", err: "store_failed" },
        ),
      ];
    case "saved":
      return [
        { ...model, status: utf8Bytes("Record saved; loading it back…") },
        Cmd.store.get(ACTIVE_KEY, {
          key: "load-current",
          ok: "loaded",
          err: "store_failed",
        }),
      ];
    case "remove":
      return [
        { ...model, status: utf8Bytes("Deleting drafts/current…") },
        Cmd.store.delete(ACTIVE_KEY, {
          key: "delete-current",
          ok: "removed",
          err: "store_failed",
        }),
      ];
    case "removed":
      return [
        {
          ...model,
          current: new Uint8Array(0),
          present: false,
          status: utf8Bytes("Record deleted; refreshing the prefix…"),
        },
        Cmd.store.scan("drafts/", { limit: 16 }, {
          key: "scan-drafts",
          ok: "scanned",
          err: "store_failed",
        }),
      ];
    case "store_failed":
      return { ...model, status: msg.reason };
  }
}
