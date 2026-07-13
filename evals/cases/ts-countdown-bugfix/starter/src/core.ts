// The countdown-timer app core, written in the app-core TypeScript subset
// (see .claude/skills/ts-core/SKILL.md and README.md). The host drives it
// by dispatching one "tick" message per elapsed second while a session runs.

export interface Model {
  readonly durationSeconds: number;
  readonly remainingSeconds: number;
  readonly running: boolean;
  readonly completedCount: number;
}

export type Msg =
  | { readonly kind: "start" }
  | { readonly kind: "pause" }
  | { readonly kind: "tick" }
  | { readonly kind: "reset" }
  | { readonly kind: "set_duration"; readonly seconds: number };

export function initialModel(): Model {
  return { durationSeconds: 300, remainingSeconds: 300, running: false, completedCount: 0 };
}

export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "start":
      return { ...model, running: model.remainingSeconds > 0 };
    case "pause":
      return { ...model, running: false };
    case "tick": {
      const remaining = model.remainingSeconds - 1;
      if (remaining === 0) {
        return { ...model, remainingSeconds: remaining, completedCount: model.completedCount + 1 };
      }
      return { ...model, remainingSeconds: remaining };
    }
    case "reset":
      return { ...model, remainingSeconds: 300, running: false };
    case "set_duration": {
      if (msg.seconds <= 0) return model;
      return { ...model, durationSeconds: msg.seconds, remainingSeconds: msg.seconds };
    }
  }
}
