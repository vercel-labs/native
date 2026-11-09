import { asciiBytes, utf8Bytes } from "@native-sdk/core";
import { type ChromeInsets, type ChromeButtons } from "@native-sdk/core/events";

export type Filter = "all" | "active";
export interface Habit {
  readonly id: number;
  readonly name: Uint8Array;
  readonly streak: number;
}
export interface Model {
  readonly habits: readonly Habit[];
  readonly next_id: number;
  readonly filter: Filter;
  readonly chrome_leading: number;
  readonly header_height: number;
}
export type Msg =
  | { readonly kind: "add" }
  | { readonly kind: "done"; readonly id: number }
  | { readonly kind: "set_filter"; readonly filter: Filter }
  | { readonly kind: "chrome_changed"; readonly insets: ChromeInsets; readonly buttons: ChromeButtons; readonly tabsProjected: boolean };
export const chromeMsg = "chrome_changed";

export function initialModel(): Model {
  return {
    habits: [
      { id: 1, name: asciiBytes("Meditate"), streak: 12 },
      { id: 2, name: asciiBytes("Exercise"), streak: 0 },
      { id: 3, name: asciiBytes("Read 20 pages"), streak: 9 },
    ],
    next_id: 4, filter: "all", chrome_leading: 0, header_height: 52,
  };
}
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "add": {
      if (model.habits.length >= 64) return model;
      const habits: Habit[] = [];
      for (const habit of model.habits) habits.push(habit);
      habits.push({ id: model.next_id, name: utf8Bytes(`Habit ${model.next_id}`), streak: 0 });
      return { ...model, habits, next_id: (model.next_id + 1) >>> 0 };
    }
    case "done": {
      const habits: Habit[] = [];
      for (const habit of model.habits) habits.push(habit.id === msg.id ? { id: habit.id, name: habit.name, streak: (habit.streak + 1) >>> 0 } : habit);
      return { ...model, habits };
    }
    case "set_filter": return { ...model, filter: msg.filter };
    case "chrome_changed": return { ...model, chrome_leading: msg.insets.left, header_height: Math.max(52, msg.insets.top) };
  }
}
export function filters(_model: Model): readonly Filter[] { return ["all", "active"]; }
export function habit_count(model: Model): number { return model.habits.length; }
export function visible(model: Model): readonly Habit[] {
  const habits: Habit[] = [];
  for (const habit of model.habits) if (model.filter === "all" || habit.streak > 0) habits.push(habit);
  return habits;
}
export function totalDays(model: Model): number {
  let total = 0;
  for (const habit of model.habits) total += habit.streak;
  return total;
}
export function summaryLine(model: Model): Uint8Array {
  return utf8Bytes(`${model.habits.length} habits · ${totalDays(model)} total days`);
}
