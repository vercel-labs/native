export interface Model {
  readonly ready: boolean;
}

export type Msg =
  | { readonly kind: "noop" }
  | { readonly kind: "reset" };

export const viewUnbound = ["noop", "reset"] as const;

export function initialModel(): Model {
  return { ready: true };
}

export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "noop":
    case "reset":
      return model;
  }
}
