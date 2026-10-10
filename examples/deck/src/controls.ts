import { stepState, type DeckState, type DeckTransition } from "./state.ts";

// Slider events supply the applied native f32. Mirror that value before the
// transport transition, preserving the other fader and the complete state.
export function stepControl(model: DeckState, control: "seek" | "volume", fraction: number): DeckTransition {
  const applied = Math.fround(fraction);
  if (control === "seek") {
    const next = { ...model, playback: { ...model.playback, seek_fraction: applied } };
    return stepState(next, { kind: "seeked" });
  }
  const next = { ...model, playback: { ...model.playback, volume_fraction: applied } };
  return stepState(next, { kind: "volume_changed" });
}
