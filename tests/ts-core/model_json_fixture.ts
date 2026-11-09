// A compiled core whose Model reaches every shape the committed-model JSON
// export writes: exact integers (plain and optional), floats including the
// signed zero, infinities and NaN, non-UTF-8 bytes, booleans, every enum
// member, every union arm family, optional records and unions, and slices
// of records.

export type Mode = "idle" | "busy" | "done";

// Message payload records are stored by value (an object-literal alias);
// records the model holds in arrays or with bytes fields are interfaces.
export type Point = {
  readonly x: number;
  readonly y: number;
};

export interface Sample {
  readonly value: number;
}

export interface Tag {
  readonly label: Uint8Array;
  readonly weight: number;
}

export type Inner =
  | { readonly kind: "on" }
  | { readonly kind: "off"; readonly reason: Uint8Array };

export type Shape =
  | { readonly kind: "empty" }
  | { readonly kind: "box"; readonly width: number; readonly height: number }
  | { readonly kind: "dot"; readonly at: Point }
  | { readonly kind: "named"; readonly name: Uint8Array }
  | { readonly kind: "moded"; readonly mode: Mode }
  | { readonly kind: "nested"; readonly inner: Inner }
  | { readonly kind: "sized"; readonly size: number }
  | { readonly kind: "ranked"; readonly rank: number }
  | { readonly kind: "flagged"; readonly on: boolean };

export interface Model {
  readonly count: number;
  readonly maybeCount: number | null;
  readonly ratio: number;
  readonly samples: readonly Sample[];
  readonly bytes: Uint8Array;
  readonly flag: boolean;
  readonly mode: Mode;
  readonly shape: Shape;
  readonly maybeShape: Shape | null;
  readonly maybePoint: Point | null;
  readonly tags: readonly Tag[];
}

export type Msg =
  | { readonly kind: "count_set"; readonly count: number }
  | { readonly kind: "count_clear" }
  | { readonly kind: "ratio_set"; readonly value: number }
  | { readonly kind: "bytes_set"; readonly value: Uint8Array }
  | { readonly kind: "flag_set"; readonly value: boolean }
  | { readonly kind: "mode_set"; readonly mode: Mode }
  | { readonly kind: "shape_set"; readonly shape: Shape }
  | { readonly kind: "shape_clear" }
  | { readonly kind: "point_set"; readonly point: Point }
  | { readonly kind: "point_clear" }
  | { readonly kind: "tag_add"; readonly weight: number; readonly label: Uint8Array };

export function initialModel(): Model {
  return {
    count: 0,
    maybeCount: null,
    ratio: 0,
    samples: [],
    bytes: new Uint8Array(0),
    flag: false,
    mode: "idle",
    shape: { kind: "empty" },
    maybeShape: null,
    maybePoint: null,
    tags: [],
  };
}

export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "count_set":
      return { ...model, count: msg.count, maybeCount: msg.count };
    case "count_clear":
      return { ...model, maybeCount: null };
    case "ratio_set":
      return { ...model, ratio: msg.value, samples: model.samples.concat([{ value: msg.value }]) };
    case "bytes_set":
      return { ...model, bytes: msg.value };
    case "flag_set":
      return { ...model, flag: msg.value };
    case "mode_set":
      return { ...model, mode: msg.mode };
    case "shape_set":
      return { ...model, shape: msg.shape, maybeShape: msg.shape };
    case "shape_clear":
      return { ...model, maybeShape: null };
    case "point_set":
      return { ...model, maybePoint: msg.point };
    case "point_clear":
      return { ...model, maybePoint: null };
    case "tag_add":
      return { ...model, tags: model.tags.concat([{ label: msg.label, weight: msg.weight }]) };
  }
}

// Bitwise operands are integer positions, so these helpers attest the
// integer class of every slot the integer arms feed.
export function countParity(model: Model): number {
  return model.count & 1;
}

export function maybeCountParity(model: Model): number {
  return (model.maybeCount ?? 0) & 1;
}

export function weightParity(model: Model): number {
  return model.tags.reduce((acc, tag) => acc ^ (tag.weight & 1), 0);
}

export function rankParity(model: Model): number {
  return model.shape.kind === "ranked" ? model.shape.rank & 1 : 0;
}
