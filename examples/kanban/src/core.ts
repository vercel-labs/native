// kanban: a three-column board authored entirely in the TypeScript app-core
// subset. The model and update loop live here, src/app.native is the whole
// view, and app.zon supplies the desktop shell. Dropping files anywhere on
// the board adds their basenames to Todo through the native dropMsg channel.

import { asciiBytes } from "@native-sdk/core";
import {
  type ChromeButtons,
  type ChromeInsets,
  type FileDropEvent,
  type ScrollState,
} from "@native-sdk/core/events";

const MAX_CARDS = 64;
const HEADER_NATURAL_HEIGHT = 52;
const BOARD_PADDING = 16;
const COLUMN_PADDING = 10;
const COLUMN_TITLE_HEIGHT = 17.5;
const COLUMN_TITLE_GAP = 8;
const CARD_HEIGHT = 69.5;
const CARD_GAP = 8;
const DRAG_CHANGE = 0;
const DRAG_END = 1;
const DRAG_CANCEL = 2;

export type Column = "todo" | "doing" | "done";
export type Agent = "openai" | "claude";

export interface Card {
  readonly id: number;
  readonly column: Column;
  readonly title: Uint8Array;
  readonly ticketNumber: number;
  readonly assignee: Agent;
  readonly avatarId: number;
}

export interface CardDrop {
  readonly sourceId: number;
  readonly phase: number;
  readonly x: number;
  readonly y: number;
  readonly viewWidth: number;
  readonly viewHeight: number;
}

export interface Model {
  readonly cards: readonly Card[];
  readonly nextId: number;
  readonly droppedCount: number;
  readonly chromeLeading: number;
  readonly headerHeight: number;
  readonly todoScroll: number;
  readonly doingScroll: number;
  readonly doneScroll: number;
  readonly draggingId: number;
  readonly dragTargetColumn: Column;
  readonly dragBeforeId: number;
}

/// A path is wrapped before it enters Msg: arrays of byte strings are a host
/// event shape, while committed app data uses record elements.
export interface DroppedPath {
  readonly path: Uint8Array;
}

/// The value-stored payload for one native file-drop dispatch.
export type DroppedFiles = {
  readonly files: readonly DroppedPath[];
};

export type Msg =
  | { readonly kind: "add" }
  | { readonly kind: "card_dropped"; readonly sourceId: number; readonly phase: number; readonly x: number; readonly y: number; readonly viewWidth: number; readonly viewHeight: number }
  | { readonly kind: "files_dropped"; readonly drop: DroppedFiles }
  | { readonly kind: "todo_scrolled"; readonly scroll: ScrollState }
  | { readonly kind: "doing_scrolled"; readonly scroll: ScrollState }
  | { readonly kind: "done_scrolled"; readonly scroll: ScrollState }
  | {
      readonly kind: "chrome_changed";
      readonly insets: ChromeInsets;
      readonly buttons: ChromeButtons;
      readonly tabsProjected: boolean;
    };

export function initialModel(): Model {
  return {
    cards: [
      { id: 1, column: "todo", title: asciiBytes("Retry failed agent runs"), ticketNumber: 1841, assignee: "openai", avatarId: 1 },
      { id: 2, column: "todo", title: asciiBytes("Preserve reconnect output"), ticketNumber: 1842, assignee: "claude", avatarId: 2 },
      { id: 3, column: "doing", title: asciiBytes("Fix duplicate dispatch"), ticketNumber: 1843, assignee: "openai", avatarId: 1 },
      { id: 4, column: "done", title: asciiBytes("Log agent handoffs"), ticketNumber: 1844, assignee: "claude", avatarId: 2 },
      { id: 5, column: "done", title: asciiBytes("Document sandbox denials"), ticketNumber: 1845, assignee: "openai", avatarId: 1 },
    ],
    nextId: 6,
    droppedCount: 0,
    chromeLeading: 0,
    headerHeight: HEADER_NATURAL_HEIGHT,
    todoScroll: 0,
    doingScroll: 0,
    doneScroll: 0,
    draggingId: 0,
    dragTargetColumn: "todo",
    dragBeforeId: 0,
  };
}

// --------------------------------------------------------- host channels

/// File drops arrive after widget routing. Only this app's canvas consumes
/// them; all paths in the platform event become one ordinary Msg so the
/// update remains deterministic and record/replay sees one atomic drop.
export function dropMsg(drop: FileDropEvent): Msg | null {
  // Desktop hosts may know only which window received the drop. In that case
  // viewLabel is empty, so accept it for this single-canvas example.
  if (drop.paths.length === 0) return null;
  if (drop.viewLabel !== "" && drop.viewLabel !== "kanban-canvas") return null;
  const files: DroppedPath[] = [];
  for (const path of drop.paths) files.push({ path: path });
  return { kind: "files_dropped", drop: { files: files } };
}

/// The tall hidden-inset titlebar geometry is delivered before the first
/// view build and whenever the window chrome changes.
export const chromeMsg = "chrome_changed";

/// Host-only arms and backing state reached through derived view helpers.
export const viewUnbound = [
  "files_dropped",
  "chrome_changed",
  "cards",
  "nextId",
  "draggingId",
  "dragTargetColumn",
  "dragBeforeId",
  "droppedCount",
  "todoCount",
  "doingCount",
  "doneCount",
] as const;

// -------------------------------------------------------------- derived

/// The live view carries exactly one reserved slot. It starts where the
/// source stood, then moves the same globally keyed row into each candidate
/// position while committed data stays untouched. The renderer leaves that
/// row blank in flow and paints its real appearance under the pointer.
function cardsForColumn(model: Model, column: Column): readonly Card[] {
  if (model.draggingId === 0) {
    return model.cards.filter((card) => card.column === column);
  }
  const sourceIndex = model.cards.findIndex((card) => card.id === model.draggingId);
  if (sourceIndex < 0) {
    return model.cards.filter((card) => card.column === column);
  }
  const source = model.cards[sourceIndex];
  const cards = model.cards.filter(
    (card) => card.column === column && card.id !== model.draggingId,
  );
  if (model.dragTargetColumn !== column) return cards;
  const reserved: Card = { ...source, column: column };
  const projected: Card[] = [];
  let inserted = false;
  for (const card of cards) {
    if (!inserted && card.id === model.dragBeforeId) {
      projected.push(reserved);
      inserted = true;
    }
    projected.push(card);
  }
  if (!inserted) projected.push(reserved);
  return projected;
}

export function todoCards(model: Model): readonly Card[] {
  return cardsForColumn(model, "todo");
}

export function doingCards(model: Model): readonly Card[] {
  return cardsForColumn(model, "doing");
}

export function doneCards(model: Model): readonly Card[] {
  return cardsForColumn(model, "done");
}

export function todoCount(model: Model): number {
  return model.cards.filter((card) => card.column === "todo").length;
}

export function doingCount(model: Model): number {
  return model.cards.filter((card) => card.column === "doing").length;
}

export function doneCount(model: Model): number {
  return model.cards.filter((card) => card.column === "done").length;
}

// --------------------------------------------------------------- update

function appendCard(model: Model, title: Uint8Array): Model {
  if (model.cards.length >= MAX_CARDS) return model;
  const id = model.nextId;
  if (!(id >= 0)) return model;
  if (id >= 9007199254739151) return model;
  const wholeId = Math.trunc(id);
  const openaiAssigned = wholeId % 2 !== 0;
  const card: Card = {
    id: wholeId,
    column: "todo",
    title: title,
    ticketNumber: Math.trunc(1840 + wholeId),
    assignee: openaiAssigned ? "openai" : "claude",
    avatarId: openaiAssigned ? 1 : 2,
  };
  return {
    ...model,
    cards: [...model.cards, card],
    nextId: Math.trunc(wholeId + 1),
  };
}

function pathBasename(path: Uint8Array): Uint8Array {
  let start = 0;
  for (let i = 0; i < path.length; i++) {
    // Accept both native path separators so recorded drops replay the same
    // useful title on every desktop host.
    if (path[i] === 47 || path[i] === 92) start = i + 1;
  }
  return path.subarray(start);
}

function committedCardMove(model: Model, id: number, target: Column, beforeId: number): Model {
  const sourceIndex = model.cards.findIndex((card) => card.id === id);
  if (sourceIndex < 0) return { ...model, draggingId: 0, dragBeforeId: 0 };
  const source = model.cards[sourceIndex];
  const moved: Card = { ...source, column: target };
  const remaining = model.cards.filter((card) => card.id !== id);
  const cards: Card[] = [];
  let inserted = false;
  for (const card of remaining) {
    if (!inserted && card.column === target && card.id === beforeId) {
      cards.push(moved);
      inserted = true;
    }
    cards.push(card);
  }
  if (!inserted) cards.push(moved);
  return {
    ...model,
    cards: cards,
    draggingId: 0,
    dragBeforeId: 0,
  };
}

function dropColumn(drop: CardDrop): Column {
  if (drop.viewWidth <= 0) return "todo";
  const third = drop.viewWidth / 3;
  if (drop.x < third) return "todo";
  if (drop.x < third * 2) return "doing";
  return "done";
}

function columnScroll(model: Model, column: Column): number {
  if (column === "todo") return model.todoScroll;
  if (column === "doing") return model.doingScroll;
  return model.doneScroll;
}

function dropBeforeCard(model: Model, drop: CardDrop, target: Column): Card | null {
  const targetCards = model.cards.filter(
    (card) => card.column === target && card.id !== drop.sourceId,
  );
  const firstCardTop = model.headerHeight + BOARD_PADDING + COLUMN_PADDING +
    COLUMN_TITLE_HEIGHT + COLUMN_TITLE_GAP;
  const firstCardCenter = firstCardTop + CARD_HEIGHT / 2;
  const stride = CARD_HEIGHT + CARD_GAP;
  const contentY = drop.y + columnScroll(model, target);
  let threshold = firstCardCenter;
  for (const card of targetCards) {
    if (contentY < threshold) return card;
    threshold += stride;
  }
  return null;
}

export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "add":
      return appendCard(model, asciiBytes(`Investigate agent task ${model.nextId}`));
    case "card_dropped": {
      if (msg.phase === DRAG_CANCEL) return { ...model, draggingId: 0, dragBeforeId: 0 };
      const sourceIndex = model.cards.findIndex((card) => card.id === msg.sourceId);
      if (sourceIndex < 0) return { ...model, draggingId: 0, dragBeforeId: 0 };
      const target = dropColumn(msg);
      const beforeCard = dropBeforeCard(model, msg, target);
      const beforeId = beforeCard === null ? 0 : beforeCard.id;
      if (msg.phase === DRAG_CHANGE) {
        return {
          ...model,
          draggingId: msg.sourceId,
          dragTargetColumn: target,
          dragBeforeId: beforeId,
        };
      }
      if (msg.phase === DRAG_END) {
        return committedCardMove(model, msg.sourceId, target, beforeId);
      }
      return model;
    }
    case "files_dropped": {
      let next = model;
      let added = 0;
      for (const file of msg.drop.files) {
        const grown = appendCard(next, pathBasename(file.path));
        if (grown.cards.length > next.cards.length) added += 1;
        next = grown;
      }
      const total = model.droppedCount + added;
      const droppedCount = total <= 9007199254740991 ? Math.trunc(total) : model.droppedCount;
      return { ...next, droppedCount: droppedCount };
    }
    case "todo_scrolled":
      return { ...model, todoScroll: msg.scroll.offsetY };
    case "doing_scrolled":
      return { ...model, doingScroll: msg.scroll.offsetY };
    case "done_scrolled":
      return { ...model, doneScroll: msg.scroll.offsetY };
    case "chrome_changed":
      return {
        ...model,
        chromeLeading: msg.insets.left,
        headerHeight: Math.max(HEADER_NATURAL_HEIGHT, msg.insets.top),
      };
  }
}
