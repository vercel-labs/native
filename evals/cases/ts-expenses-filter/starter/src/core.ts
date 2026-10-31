// The expense-ledger app core, written in the app-core TypeScript subset
// (see .claude/skills/ts-core/SKILL.md and README.md).

export type Bytes = Uint8Array;
export type Category = "food" | "travel" | "gear";

export interface Expense {
  readonly id: number;
  readonly label: Bytes;
  readonly amountCents: number;
  readonly category: Category;
}

export interface Model {
  readonly expenses: readonly Expense[];
  readonly nextId: number;
}

export type Msg =
  | { readonly kind: "add_expense"; readonly label: Bytes; readonly amountCents: number; readonly category: Category }
  | { readonly kind: "remove_expense"; readonly id: number };

export function initialModel(): Model {
  return { expenses: [], nextId: 1 };
}

export function expenseCount(model: Model): number {
  return model.expenses.length;
}

export function totalCents(model: Model): number {
  let total = 0;
  for (let i = 0; i < model.expenses.length; i++) {
    total += model.expenses[i].amountCents;
  }
  return total;
}

export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "add_expense": {
      const expense: Expense = {
        id: model.nextId,
        label: msg.label,
        amountCents: msg.amountCents,
        category: msg.category,
      };
      return { ...model, expenses: [...model.expenses, expense], nextId: model.nextId + 1 };
    }
    case "remove_expense":
      return { ...model, expenses: model.expenses.filter((e) => e.id !== msg.id) };
  }
}
