import { asciiBytes } from "@native-sdk/core";
import { albums } from "./catalog.ts";
import type { DeckState } from "./state.ts";

// Native boot records a cover only after its declared asset decodes. Failure
// preserves the current ID, including a prior successful registration.
export function registerCover(model: DeckState, id: Uint8Array, registered: boolean): DeckState {
  if (!registered) return model;
  for (let index = 0; index < albums.length; index++) {
    const album = albums[index];
    if (album.art !== null && sameBytes(id, asciiBytes(`${album.id}`))) {
      const covers = model.covers.slice();
      covers[index] = id;
      return { ...model, covers };
    }
  }
  return model;
}

function sameBytes(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) return false;
  for (let index = 0; index < left.length; index++) {
    if (left[index] !== right[index]) return false;
  }
  return true;
}
