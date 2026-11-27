// Kite, a kanban board: four columns of task cards that drag between and
// within them. React renders it, Tailwind styles it, and the primary button
// comes from the UI SDK. A card's composer takes new cards on Enter.

import { useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { Button } from "@ui-sdk/react/button";

interface Card {
  id: string;
  title: string;
  tag: string;
  points: number;
  owner: string;
  tone: string;
  status: string;
}

interface Column {
  id: string;
  title: string;
  accent: string;
  dot: string;
}

const COLUMNS: Column[] = [
  { id: "backlog", title: "Backlog", accent: "from-slate-400 to-slate-500", dot: "bg-slate-400" },
  { id: "next", title: "Next up", accent: "from-sky-400 to-sky-500", dot: "bg-sky-400" },
  { id: "doing", title: "In progress", accent: "from-amber-400 to-orange-500", dot: "bg-amber-400" },
  { id: "done", title: "Done", accent: "from-emerald-400 to-emerald-500", dot: "bg-emerald-400" },
];

const START: Card[] = [
  { id: "k1", title: "Empty states for the board", tag: "Design", points: 2, owner: "AR", tone: "bg-rose-100 text-rose-700", status: "backlog" },
  { id: "k2", title: "Filter cards by assignee", tag: "Feature", points: 5, owner: "MP", tone: "bg-indigo-100 text-indigo-700", status: "backlog" },
  { id: "k3", title: "Fix card shadow on resize", tag: "Bug", points: 1, owner: "JT", tone: "bg-amber-100 text-amber-700", status: "backlog" },
  { id: "k4", title: "Column limits and a warning", tag: "Feature", points: 3, owner: "AR", tone: "bg-indigo-100 text-indigo-700", status: "next" },
  { id: "k5", title: "Keyboard reordering", tag: "Accessibility", points: 5, owner: "SB", tone: "bg-sky-100 text-sky-700", status: "next" },
  { id: "k6", title: "Drag a card between columns", tag: "Feature", points: 8, owner: "MP", tone: "bg-indigo-100 text-indigo-700", status: "doing" },
  { id: "k7", title: "Card composer on Enter", tag: "Feature", points: 2, owner: "JT", tone: "bg-indigo-100 text-indigo-700", status: "doing" },
  { id: "k8", title: "Ship the board to staging", tag: "Release", points: 1, owner: "SB", tone: "bg-emerald-100 text-emerald-700", status: "done" },
];

function App() {
  const [cards, setCards] = useState<Card[]>(START);
  const [dragging, setDragging] = useState<string | null>(null);
  const [overColumn, setOverColumn] = useState<string | null>(null);
  const [composing, setComposing] = useState<string | null>(null);
  const [draft, setDraft] = useState("");
  const [status, setStatus] = useState("Drag a card onto another column to move it.");
  const startX = useRef(0);
  const startY = useRef(0);
  // The card being dragged, kept in a ref as well as state: a press, the moves and the release can
  // all arrive in one turn, before React commits the press's state update.
  const draggingId = useRef<string | null>(null);

  function moveCard(id: string, column: string, beforeId: string | null): void {
    const card = cards.find((item) => item.id === id);
    if (card === undefined) return;
    const rest = cards.filter((item) => item.id !== id);
    const moved: Card = { id: card.id, title: card.title, tag: card.tag, points: card.points, owner: card.owner, tone: card.tone, status: column };
    if (beforeId === null) {
      rest.push(moved);
    } else {
      const index = rest.findIndex((item) => item.id === beforeId);
      if (index < 0) rest.push(moved);
      else rest.splice(index, 0, moved);
    }
    setCards(rest);
    const title = COLUMNS.find((item) => item.id === column);
    setStatus("Moved “" + card.title + "” to " + (title === undefined ? column : title.title));
  }

  // A press on a card starts a pointer drag; the column under the pointer is highlighted as it
  // moves and the card lands there on release. Pointer events rather than HTML5 drag and drop, so
  // the same gesture works for a mouse, a trackpad and a touch screen alike.
  function columnUnder(x: number, y: number): Element | null {
    const under = document.elementFromPoint(x, y);
    return under === null ? null : under.closest("[data-column-id]");
  }

  function onBoardPointerMove(event: any): void {
    if (draggingId.current === null) return;
    const column = columnUnder(event.clientX, event.clientY);
    setOverColumn(column === null ? null : column.getAttribute("data-column-id"));
  }

  function onBoardPointerUp(event: any): void {
    const id = draggingId.current;
    if (id === null) return;
    const moved = Math.abs(event.clientX - startX.current) + Math.abs(event.clientY - startY.current) > 4;
    if (moved) {
      const column = columnUnder(event.clientX, event.clientY);
      const columnId = column === null ? null : column.getAttribute("data-column-id");
      const under = document.elementFromPoint(event.clientX, event.clientY);
      const cardEl = under === null ? null : under.closest("[data-card-id]");
      const beforeId = cardEl === null ? null : cardEl.getAttribute("data-card-id");
      if (columnId !== null) moveCard(id, columnId, beforeId === id ? null : beforeId);
    }
    draggingId.current = null;
    setDragging(null);
    setOverColumn(null);
    startX.current = 0;
    startY.current = 0;
  }

  function addCard(column: string): void {
    const title = draft.trim();
    if (title === "") {
      setStatus("Give the card a title first.");
      return;
    }
    const id = "k" + String(Date.now());
    const card: Card = { id: id, title: title, tag: "New", points: 1, owner: "ARK", tone: "bg-slate-100 text-slate-600", status: column };
    setCards([...cards, card]);
    setDraft("");
    setComposing(null);
    setStatus("Added “" + title + "” to " + column);
  }

  const done = cards.filter((card) => card.status === "done").length;

  return (
    <div className="flex h-screen flex-col bg-slate-100 font-sans text-slate-900">
      <header className="flex h-16 shrink-0 items-center gap-4 border-b border-slate-200 bg-white px-7">
        <div className="grid h-9 w-9 place-items-center rounded-xl bg-gradient-to-br from-indigo-500 to-violet-600 text-sm font-bold text-white">K</div>
        <div>
          <h1 className="text-[17px] font-semibold tracking-tight">Kite</h1>
          <p className="text-[11.5px] text-slate-500">Product board · {cards.length} cards · {done} done</p>
        </div>
        <div className="ml-auto flex items-center gap-3">
          <p id="board-status" className="text-[12px] text-slate-500">{status}</p>
          <Button id="add-board-card" onClick={() => { setComposing("backlog"); setStatus("Adding a card to Backlog."); }} className="inline-flex h-9 items-center gap-1.5 rounded-lg bg-slate-900 px-3.5 text-[13px] font-medium text-white shadow-sm hover:bg-slate-800">
            New card
          </Button>
        </div>
      </header>

      <main
        id="board"
        onPointerMove={onBoardPointerMove}
        onPointerUp={onBoardPointerUp}
        className="flex min-h-0 flex-1 select-none gap-4 overflow-x-auto px-7 py-5"
      >
        {COLUMNS.map((column) => {
          const columnCards = cards.filter((card) => card.status === column.id);
          const isOver = overColumn === column.id;
          return (
            <section
              key={column.id}
              id={"col-" + column.id}
              data-column-id={column.id}
              className={"flex h-full w-72 shrink-0 flex-col rounded-2xl border p-3 " + (isOver ? "border-indigo-300 bg-indigo-50/60" : "border-slate-200 bg-white/70")}
            >
              <div className="mb-3 flex items-center gap-2 px-1">
                <span className={"h-2 w-2 rounded-full " + column.dot} />
                <h2 className="text-[12.5px] font-semibold uppercase tracking-wider text-slate-600">{column.title}</h2>
                <span id={"count-" + column.id} className="rounded-full bg-slate-100 px-1.5 text-[10.5px] font-medium text-slate-500">{columnCards.length}</span>
              </div>

              <div className="flex min-h-0 flex-1 flex-col gap-2 overflow-y-auto">
                {columnCards.map((card) => (
                  <article
                    key={card.id}
                    id={"card-" + card.id}
                    data-card-id={card.id}
                    onPointerDown={(event: any) => {
                      if (event.button !== 0) return;
                      startX.current = event.clientX;
                      startY.current = event.clientY;
                      draggingId.current = card.id;
                      setDragging(card.id);
                      setOverColumn(card.status);
                      event.currentTarget.setPointerCapture(event.pointerId);
                    }}
                    className={"cursor-grab rounded-xl border border-slate-200 bg-white p-3 shadow-sm " + (dragging === card.id ? "opacity-40 ring-2 ring-indigo-300" : "hover:border-slate-300")}
                  >
                    <div className="flex items-start justify-between gap-2">
                      <p className="text-[13px] font-medium leading-snug text-slate-800">{card.title}</p>
                      <span className={"shrink-0 rounded-md px-1.5 py-0.5 text-[10px] font-medium " + card.tone}>{card.points}</span>
                    </div>
                    <div className="mt-2.5 flex items-center gap-2">
                      <span className="rounded-md bg-slate-100 px-1.5 py-0.5 text-[10px] font-medium text-slate-500">{card.tag}</span>
                      <span className="ml-auto grid h-6 w-6 place-items-center rounded-full bg-gradient-to-br from-slate-200 to-slate-300 text-[9px] font-semibold text-slate-700">{card.owner}</span>
                    </div>
                  </article>
                ))}

                {composing === column.id && (
                  <div className="rounded-xl border border-indigo-200 bg-white p-2.5 shadow-sm">
                    <textarea
                      id={"composer-" + column.id}
                      value={draft}
                      autoFocus={true}
                      onInput={(event: any) => setDraft(String(event.target.value))}
                      onKeyDown={(event: any) => {
                        if (event.key === "Enter") {
                          event.preventDefault();
                          addCard(column.id);
                        } else if (event.key === "Escape") {
                          setComposing(null);
                          setDraft("");
                        }
                      }}
                      placeholder="What needs doing?"
                      className="h-16 w-full resize-none border-none bg-transparent text-[13px] leading-5 text-slate-700 outline-none placeholder:text-slate-400"
                    ></textarea>
                    <div className="mt-1 flex items-center justify-end gap-1.5">
                      <button type="button" id={"composer-cancel-" + column.id} onClick={() => { setComposing(null); setDraft(""); }} className="rounded-md px-2 py-1 text-[11.5px] font-medium text-slate-500 hover:bg-slate-100">Cancel</button>
                      <button type="button" id={"composer-add-" + column.id} onClick={() => addCard(column.id)} className="rounded-md bg-slate-900 px-2.5 py-1 text-[11.5px] font-medium text-white hover:bg-slate-800">Add card</button>
                    </div>
                  </div>
                )}

                {composing !== column.id && (
                  <button
                    type="button"
                    id={"add-" + column.id}
                    onClick={() => { setComposing(column.id); setDraft(""); }}
                    className="rounded-lg px-2 py-1.5 text-left text-[12px] font-medium text-slate-400 hover:bg-slate-100 hover:text-slate-600"
                  >
                    + Add a card
                  </button>
                )}
              </div>
            </section>
          );
        })}
      </main>
    </div>
  );
}

createRoot(document.getElementById("root")!).render(<App />);
