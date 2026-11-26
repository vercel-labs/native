// Fieldnotes, a markdown notes app: a searchable list on the left, a plain-text
// editor and a live preview on the right. React renders it, Tailwind styles it,
// and the search field, the editor and the buttons come from the UI SDK.
// Notes are kept in localStorage, so they are there the next time it opens.

import { useEffect, useState } from "react";
import type { ReactNode } from "react";
import { createRoot } from "react-dom/client";
import { Button } from "@ui-sdk/react/button";
import { Input } from "@ui-sdk/react/input";
import { Textarea } from "@ui-sdk/react/textarea";
import { IconColumns, IconEye, IconLeaf, IconPen, IconPlus, IconSearch, IconTrash } from "./icons";

interface Note {
  id: string;
  title: string;
  body: string;
  updated: number;
}

interface Block {
  kind: string;
  text: string;
  items: string[];
}

const STORAGE_KEY = "fieldnotes.notes.v1";

const SEED: Note[] = [
  {
    id: "n-welcome",
    title: "Welcome to Fieldnotes",
    body: [
      "# Welcome to Fieldnotes",
      "",
      "A quiet place to write in **Markdown**. Everything you type is saved to this machine as you go.",
      "",
      "## What it does",
      "",
      "- A searchable list of notes on the left",
      "- A plain-text editor with a live preview",
      "- `#` headings, **bold**, *italic*, `code` and lists",
      "- Cmd+N for a new note",
      "",
      "> Notes are yours. Nothing leaves the window.",
      "",
      "Try the **Split** view to see the preview update as you type.",
    ].join("\n"),
    updated: Date.now() - 1000 * 60 * 4,
  },
  {
    id: "n-shipping",
    title: "Launch checklist",
    body: [
      "# Launch checklist",
      "",
      "1. Freeze the branch on Thursday",
      "2. Run the numbers past Priya",
      "3. Record the two-minute walkthrough",
      "4. Send the note to everyone on Friday morning",
      "",
      "## Open questions",
      "",
      "- Do we need a new pricing page?",
      "- Who owns the changelog this month?",
    ].join("\n"),
    updated: Date.now() - 1000 * 60 * 60 * 3,
  },
  {
    id: "n-reading",
    title: "Reading list",
    body: [
      "# Reading list",
      "",
      "Books people keep recommending, in no particular order.",
      "",
      "- *The Timeless Way of Building* — a pattern language for rooms and towns",
      "- *Thinking in Systems* — a primer on feedback loops",
      "- *The Design of Everyday Things* — affordances, once more",
      "",
      "Finished **two** of them this year so far.",
    ].join("\n"),
    updated: Date.now() - 1000 * 60 * 60 * 26,
  },
  {
    id: "n-snippet",
    title: "Debounce snippet",
    body: [
      "# Debounce snippet",
      "",
      "Keep this around; it keeps showing up in reviews.",
      "",
      "```",
      "function debounce(fn, wait) {",
      "  let timer = 0;",
      "  return (...args) => {",
      "    clearTimeout(timer);",
      "    timer = setTimeout(() => fn(...args), wait);",
      "  };",
      "}",
      "```",
      "",
      "It returns a function that waits for a quiet moment before running.",
    ].join("\n"),
    updated: Date.now() - 1000 * 60 * 60 * 24 * 6,
  },
];

function loadNotes(): Note[] {
  const raw = localStorage.getItem(STORAGE_KEY);
  if (raw === null || raw === "") {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(SEED));
    return SEED;
  }
  try {
    const parsed = JSON.parse(raw) as Note[];
    if (Array.isArray(parsed) && parsed.length > 0) return parsed;
  } catch (error) {
    console.error("could not read saved notes", error);
  }
  return SEED;
}

/** Splits the text into block-level pieces: headings, paragraphs, lists, quotes, code and rules. */
function parseBlocks(source: string): Block[] {
  const blocks: Block[] = [];
  const lines = source.split("\n");
  let paragraph: string[] = [];
  let items: string[] = [];
  let listKind = "";
  let code: string[] = [];
  let inCode = false;

  function flushParagraph(): void {
    if (paragraph.length > 0) {
      blocks.push({ kind: "p", text: paragraph.join(" "), items: [] });
      paragraph = [];
    }
  }
  function flushList(): void {
    if (items.length > 0) {
      blocks.push({ kind: listKind, text: "", items: items });
      items = [];
      listKind = "";
    }
  }
  function flushCode(): void {
    if (code.length > 0) blocks.push({ kind: "code", text: code.join("\n"), items: [] });
    code = [];
    inCode = false;
  }

  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed.startsWith("```")) {
      if (inCode) flushCode();
      else {
        flushParagraph();
        flushList();
        inCode = true;
      }
      continue;
    }
    if (inCode) {
      code.push(line);
      continue;
    }
    if (trimmed === "") {
      flushParagraph();
      flushList();
      continue;
    }
    if (trimmed === "---" || trimmed === "***") {
      flushParagraph();
      flushList();
      blocks.push({ kind: "hr", text: "", items: [] });
      continue;
    }
    if (trimmed.startsWith("### ")) {
      flushParagraph();
      flushList();
      blocks.push({ kind: "h3", text: trimmed.slice(4), items: [] });
      continue;
    }
    if (trimmed.startsWith("## ")) {
      flushParagraph();
      flushList();
      blocks.push({ kind: "h2", text: trimmed.slice(3), items: [] });
      continue;
    }
    if (trimmed.startsWith("# ")) {
      flushParagraph();
      flushList();
      blocks.push({ kind: "h1", text: trimmed.slice(2), items: [] });
      continue;
    }
    if (trimmed.startsWith("> ")) {
      flushParagraph();
      flushList();
      blocks.push({ kind: "quote", text: trimmed.slice(2), items: [] });
      continue;
    }
    if (trimmed.startsWith("- ") || trimmed.startsWith("* ")) {
      flushParagraph();
      if (listKind !== "ul") flushList();
      listKind = "ul";
      items.push(trimmed.slice(2));
      continue;
    }
    const ordered = /^\d+\.\s+(.*)$/.exec(trimmed);
    if (ordered !== null) {
      flushParagraph();
      if (listKind !== "ol") flushList();
      listKind = "ol";
      items.push(ordered[1]);
      continue;
    }
    flushList();
    paragraph.push(trimmed);
  }
  flushParagraph();
  flushList();
  if (inCode) flushCode();
  return blocks;
}

type InlineNode = ReactNode;

/** Renders the **bold**, *italic*, `code` and [links](url) inside a line of text. */
function renderInline(text: string): InlineNode[] {
  const parts = text.split(/(\*\*[^*]+\*\*|\*[^*]+\*|`[^`]+`|\[[^\]]+\]\([^)]+\))/g);
  return parts.map((token, index) => {
    if (token.startsWith("**") && token.endsWith("**")) {
      return <strong key={index} className="font-semibold text-slate-900">{token.slice(2, token.length - 2)}</strong>;
    }
    if (token.startsWith("`") && token.endsWith("`")) {
      return <code key={index} className="rounded bg-slate-100 px-1.5 py-0.5 font-mono text-[0.9em] text-rose-600">{token.slice(1, token.length - 1)}</code>;
    }
    if (token.startsWith("[") && token.indexOf("](") > 0) {
      const close = token.indexOf("](");
      const label = token.slice(1, close);
      const href = token.slice(close + 2, token.length - 1);
      return <a key={index} href={href} className="text-indigo-600 underline underline-offset-2">{label}</a>;
    }
    if (token.startsWith("*") && token.endsWith("*") && token.length > 2) {
      return <em key={index} className="italic text-slate-700">{token.slice(1, token.length - 1)}</em>;
    }
    return token;
  });
}

function Markdown(props: { source: string }) {
  const blocks = parseBlocks(props.source);
  if (blocks.length === 0) {
    return <p className="text-sm text-slate-400">Nothing here yet. Start typing on the left.</p>;
  }
  return (
    <div id="preview-body" className="space-y-4">
      {blocks.map((block, index) => {
        if (block.kind === "h1") return <h1 key={index} className="text-[26px] font-semibold tracking-tight text-slate-900">{renderInline(block.text)}</h1>;
        if (block.kind === "h2") return <h2 key={index} className="pt-2 text-[18px] font-semibold tracking-tight text-slate-800">{renderInline(block.text)}</h2>;
        if (block.kind === "h3") return <h3 key={index} className="pt-1 text-[15px] font-semibold text-slate-800">{renderInline(block.text)}</h3>;
        if (block.kind === "ul") {
          return <ul key={index} className="list-disc space-y-1.5 pl-5 text-[15px] leading-7 text-slate-600">{block.items.map((item, i) => <li key={i}>{renderInline(item)}</li>)}</ul>;
        }
        if (block.kind === "ol") {
          return <ol key={index} className="list-decimal space-y-1.5 pl-5 text-[15px] leading-7 text-slate-600">{block.items.map((item, i) => <li key={i}>{renderInline(item)}</li>)}</ol>;
        }
        if (block.kind === "quote") {
          return <blockquote key={index} className="border-l-2 border-indigo-300 pl-4 text-[15px] italic leading-7 text-slate-500">{renderInline(block.text)}</blockquote>;
        }
        if (block.kind === "code") {
          return <pre key={index} className="overflow-x-auto rounded-xl bg-slate-900 p-4 font-mono text-[12.5px] leading-6 text-slate-100"><code>{block.text}</code></pre>;
        }
        if (block.kind === "hr") return <hr key={index} className="border-slate-200" />;
        return <p key={index} className="text-[15px] leading-7 text-slate-600">{renderInline(block.text)}</p>;
      })}
    </div>
  );
}

function relativeTime(when: number): string {
  const minutes = Math.floor((Date.now() - when) / 60000);
  if (minutes < 1) return "just now";
  if (minutes < 60) return String(minutes) + "m ago";
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return String(hours) + "h ago";
  const days = Math.floor(hours / 24);
  if (days < 7) return String(days) + "d ago";
  const date = new Date(when);
  const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  return months[date.getMonth()] + " " + String(date.getDate());
}

function snippetFor(body: string): string {
  const lines = body.split("\n");
  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed !== "" && !trimmed.startsWith("#") && !trimmed.startsWith("```")) {
      return trimmed.replace(/[*`#>]/g, "");
    }
  }
  return "No text yet";
}

function countWords(body: string): number {
  const trimmed = body.trim();
  if (trimmed === "") return 0;
  return trimmed.split(/\s+/).length;
}

const FIRST_NOTES = loadNotes();

function App() {
  const [notes, setNotes] = useState<Note[]>(FIRST_NOTES);
  const [selectedId, setSelectedId] = useState<string>(FIRST_NOTES[0].id);
  const [query, setQuery] = useState("");
  const [view, setView] = useState("split");
  const [saved, setSaved] = useState("All changes saved");
  const [confirmingDelete, setConfirmingDelete] = useState(false);

  const selected = notes.find((note) => note.id === selectedId) ?? notes[0];

  function commit(next: Note[]): void {
    setNotes(next);
    localStorage.setItem(STORAGE_KEY, JSON.stringify(next));
    setSaved("Saved just now");
  }

  function editTitle(value: string): void {
    commit(notes.map((note) => note.id === selected.id ? { id: note.id, title: value, body: note.body, updated: Date.now() } : note));
  }

  function editBody(value: string): void {
    commit(notes.map((note) => note.id === selected.id ? { id: note.id, title: note.title, body: value, updated: Date.now() } : note));
  }

  function newNote(): void {
    const id = "n-" + String(Date.now());
    const note: Note = { id: id, title: "Untitled note", body: "# Untitled note\n\n", updated: Date.now() };
    commit([note, ...notes]);
    setSelectedId(id);
    setView("split");
    setConfirmingDelete(false);
  }

  function deleteNote(): void {
    if (notes.length < 2) return;
    const next = notes.filter((note) => note.id !== selected.id);
    commit(next);
    setSelectedId(next[0].id);
    setConfirmingDelete(false);
  }

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      const accel = event.metaKey || event.ctrlKey;
      if (accel && (event.key === "n" || event.key === "N")) {
        event.preventDefault();
        newNote();
      }
      if (accel && (event.key === "s" || event.key === "S")) {
        event.preventDefault();
        localStorage.setItem(STORAGE_KEY, JSON.stringify(notes));
        setSaved("Saved just now");
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  const visible = notes.slice().sort((a, b) => b.updated - a.updated).filter((note) => {
    if (query.trim() === "") return true;
    const needle = query.toLowerCase();
    return note.title.toLowerCase().includes(needle) || note.body.toLowerCase().includes(needle);
  });

  const words = countWords(selected.body);

  return (
    <div className="flex h-screen bg-slate-50 font-sans text-slate-900">
      <aside className="flex w-[300px] shrink-0 flex-col bg-slate-950 text-slate-100">
        <div className="flex items-center gap-2.5 px-5 pb-4 pt-5">
          <span className="grid h-8 w-8 place-items-center rounded-lg bg-emerald-500/15 text-emerald-400"><IconLeaf className="h-4.5 w-4.5" /></span>
          <div>
            <p className="text-[15px] font-semibold tracking-tight">Fieldnotes</p>
            <p className="text-[10.5px] uppercase tracking-wider text-slate-500">Notes on this Mac</p>
          </div>
        </div>

        <div className="px-4 pb-3">
          <div className="relative">
            <span className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-slate-500"><IconSearch className="h-4 w-4" /></span>
            <Input
              id="search"
              value={query}
              onValueChange={(value: string) => setQuery(value)}
              placeholder="Search notes"
              className="h-9 w-full rounded-lg border border-white/10 bg-white/5 pl-9 pr-3 text-[13px] text-slate-100 outline-none placeholder:text-slate-500 focus:border-emerald-500/60 focus:bg-white/10"
            />
          </div>
        </div>

        <div className="flex items-center justify-between px-5 pb-2">
          <p id="note-count" className="text-[11px] font-medium uppercase tracking-wider text-slate-500">{visible.length} {visible.length === 1 ? "note" : "notes"}</p>
          <Button id="new-note" onClick={newNote} className="inline-flex items-center gap-1 rounded-md px-2 py-1 text-[12px] font-medium text-emerald-400 hover:bg-white/5">
            <IconPlus className="h-3.5 w-3.5" /> New
          </Button>
        </div>

        <div id="note-list" className="min-h-0 flex-1 overflow-y-auto px-3 pb-4">
          {visible.map((note) => (
            <button
              key={note.id}
              type="button"
              onClick={() => { setSelectedId(note.id); setConfirmingDelete(false); }}
              className={"mb-1 block w-full rounded-xl px-3 py-2.5 text-left " + (note.id === selected.id ? "bg-white/10" : "hover:bg-white/5")}
            >
              <span className="block truncate text-[13px] font-medium text-slate-100">{note.title === "" ? "Untitled note" : note.title}</span>
              <span className="mt-0.5 block truncate text-[11.5px] text-slate-500">{snippetFor(note.body)}</span>
              <span className="mt-1 block text-[10.5px] text-slate-600">{relativeTime(note.updated)}</span>
            </button>
          ))}
          {visible.length === 0 && <p className="px-3 py-6 text-center text-[12px] text-slate-500">No notes match “{query}”.</p>}
        </div>

        <div className="border-t border-white/10 px-4 py-3">
          <p id="saved" className="text-[11px] text-slate-500">{saved}</p>
        </div>
      </aside>

      <main className="flex min-w-0 flex-1 flex-col">
        <header className="flex h-14 shrink-0 items-center gap-3 border-b border-slate-200 bg-white px-6">
          <input
            id="note-title"
            value={selected.title}
            onChange={(event: any) => editTitle(String(event.target.value))}
            placeholder="Untitled note"
            className="min-w-0 flex-1 border-none bg-transparent text-[17px] font-semibold tracking-tight text-slate-900 outline-none placeholder:text-slate-400"
          />
          <div className="flex items-center gap-0.5 rounded-lg bg-slate-100 p-0.5" role="group" aria-label="View">
            <button id="view-write" type="button" aria-pressed={view === "write"} onClick={() => setView("write")} className={"inline-flex items-center gap-1.5 rounded-md px-2.5 py-1.5 text-[12px] font-medium " + (view === "write" ? "bg-white text-slate-900 shadow-sm" : "text-slate-500 hover:text-slate-700")}>
              <IconPen className="h-3.5 w-3.5" /> Write
            </button>
            <button id="view-split" type="button" aria-pressed={view === "split"} onClick={() => setView("split")} className={"inline-flex items-center gap-1.5 rounded-md px-2.5 py-1.5 text-[12px] font-medium " + (view === "split" ? "bg-white text-slate-900 shadow-sm" : "text-slate-500 hover:text-slate-700")}>
              <IconColumns className="h-3.5 w-3.5" /> Split
            </button>
            <button id="view-preview" type="button" aria-pressed={view === "preview"} onClick={() => setView("preview")} className={"inline-flex items-center gap-1.5 rounded-md px-2.5 py-1.5 text-[12px] font-medium " + (view === "preview" ? "bg-white text-slate-900 shadow-sm" : "text-slate-500 hover:text-slate-700")}>
              <IconEye className="h-3.5 w-3.5" /> Preview
            </button>
          </div>
          {confirmingDelete ? (
            <div className="flex items-center gap-1.5">
              <button id="delete-cancel" type="button" onClick={() => setConfirmingDelete(false)} className="rounded-lg px-2.5 py-1.5 text-[12px] font-medium text-slate-500 hover:bg-slate-100">Cancel</button>
              <button id="delete-confirm" type="button" onClick={deleteNote} className="rounded-lg bg-rose-600 px-2.5 py-1.5 text-[12px] font-medium text-white hover:bg-rose-500">Delete</button>
            </div>
          ) : (
            <button id="delete-note" type="button" onClick={() => setConfirmingDelete(true)} title="Delete note" className="grid h-8 w-8 place-items-center rounded-lg text-slate-400 hover:bg-slate-100 hover:text-rose-600">
              <IconTrash className="h-4 w-4" />
            </button>
          )}
        </header>

        <div className="flex min-h-0 flex-1">
          {view !== "preview" && (
            <div className={"flex min-w-0 flex-col " + (view === "split" ? "w-1/2 border-r border-slate-200" : "flex-1")}>
              <Textarea
                id="body"
                value={selected.body}
                onValueChange={(value: string) => editBody(value)}
                spellCheck={false}
                className="h-full w-full resize-none border-none bg-white px-7 py-6 font-mono text-[13.5px] leading-7 text-slate-700 outline-none placeholder:text-slate-400"
              />
            </div>
          )}
          {view !== "write" && (
            <div id="preview" className={"min-w-0 overflow-y-auto bg-white " + (view === "split" ? "w-1/2" : "flex-1")}>
              <div className="mx-auto max-w-[640px] px-8 py-6">
                <Markdown source={selected.body} />
              </div>
            </div>
          )}
        </div>

        <footer className="flex h-9 shrink-0 items-center justify-between border-t border-slate-200 bg-slate-50 px-6 text-[11px] text-slate-500">
          <p id="word-count">{words} {words === 1 ? "word" : "words"} · about {Math.max(1, Math.round(words / 220))} min read</p>
          <p>Markdown · saved on this Mac</p>
        </footer>
      </main>
    </div>
  );
}

createRoot(document.getElementById("root")!).render(<App />);
