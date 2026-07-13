// The expense-ledger app core: seeded expenses, removal, derived totals.
// Written in the app-core TypeScript subset — see
// .claude/skills/ts-core/SKILL.md and README.md.

import { asciiBytes } from "@native-sdk/core";

export type Bytes = Uint8Array;
export type Category = "food" | "gear" | "travel";

export interface Expense {
  readonly id: number;
  readonly label: Bytes;
  readonly category: Category;
  readonly cents: number;
}

export interface Model {
  readonly expenses: readonly Expense[];
}

export type Msg =
  | { readonly kind: "remove"; readonly id: number }
  | { readonly kind: "reset" };

function seededExpenses(): readonly Expense[] {
  return [
    { id: 1, label: asciiBytes("Standing desk"), category: "gear", cents: 45900 },
    { id: 2, label: asciiBytes("Cable, HDMI 2m"), category: "gear", cents: 1900 },
    { id: 3, label: asciiBytes("Team lunch"), category: "food", cents: 6400 },
    { id: 4, label: asciiBytes("Mug \"Team\" x4"), category: "gear", cents: 1250 },
  ];
}

export function initialModel(): Model {
  return { expenses: seededExpenses() };
}

export function totalCents(model: Model): number {
  return model.expenses.reduce((sum, e) => sum + e.cents, 0);
}

export function expenseCount(model: Model): number {
  return model.expenses.length;
}

export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "remove":
      return { ...model, expenses: model.expenses.filter((e) => e.id !== msg.id) };
    case "reset":
      return { ...model, expenses: seededExpenses() };
  }
}
