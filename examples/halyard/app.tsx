// Halyard, a team issue tracker: a sidebar of views and teams, a filterable list whose rows drag
// into a new order, a detail pane with a checklist and comments, and a command palette on
// Command-K. React 19 renders the page and Tailwind 4 styles it; the buttons and fields come from
// @ui-sdk/react, while the palette's overlay, list and key handling are the page's own.

import { useEffect, useRef, useState } from "react";
import type { ReactNode } from "react";
import { createRoot } from "react-dom/client";
import { Button } from "@ui-sdk/react/button";
import { Input } from "@ui-sdk/react/input";
import { ISSUES, ME, TEAMS } from "./data";
import type { Issue, Priority, Status } from "./data";
import {
  IconArrowDown,
  IconArrowUp,
  IconAt,
  IconBolt,
  IconCal,
  IconCheck,
  IconCheckCircle,
  IconChevronDown,
  IconChevronRight,
  IconCircle,
  IconClose,
  IconCommand,
  IconComment,
  IconFilter,
  IconGrip,
  IconHalf,
  IconInbox,
  IconLogo,
  IconMore,
  IconPlus,
  IconSearch,
  IconStack,
  IconTag,
  IconUser,
} from "./icons";

type View = "inbox" | "mine" | "all" | "open" | "progress" | "done";



const VIEWS: { id: View; label: string; icon: "inbox" | "user" | "stack" | "circle" | "half" | "check" }[] = [
  { id: "inbox", label: "Inbox", icon: "inbox" },
  { id: "mine", label: "My issues", icon: "user" },
  { id: "all", label: "All issues", icon: "stack" },
  { id: "open", label: "Open", icon: "circle" },
  { id: "progress", label: "In progress", icon: "half" },
  { id: "done", label: "Done", icon: "check" },
];

const STATUSES: Status[] = ["Todo", "In progress", "Done"];
const PRIORITIES: (Priority | "Any")[] = ["Any", "Urgent", "High", "Normal", "Low"];

// The palette's commands, laid out here rather than from mapped arrays so the literal is easy to
// read and the compiler doesn't have to infer a union of record types.
const PALETTE_COMMANDS = [
  { value: "view:inbox", label: "Inbox", group: "Go to", shortcut: "" },
  { value: "view:mine", label: "My issues", group: "Go to", shortcut: "" },
  { value: "view:all", label: "All issues", group: "Go to", shortcut: "" },
  { value: "view:open", label: "Open", group: "Go to", shortcut: "" },
  { value: "view:progress", label: "In progress", group: "Go to", shortcut: "" },
  { value: "view:done", label: "Done", group: "Go to", shortcut: "" },
  { value: "priority:Any", label: "Any priority", group: "Priority", shortcut: "" },
  { value: "priority:Urgent", label: "Urgent priority", group: "Priority", shortcut: "" },
  { value: "priority:High", label: "High priority", group: "Priority", shortcut: "" },
  { value: "priority:Normal", label: "Normal priority", group: "Priority", shortcut: "" },
  { value: "priority:Low", label: "Low priority", group: "Priority", shortcut: "" },
  { value: "action:new", label: "New issue", group: "Actions", shortcut: "n" },
  { value: "action:cycle", label: "Cycle status of selected issue", group: "Actions", shortcut: "e" },
  { value: "action:done", label: "Mark selected issue done", group: "Actions", shortcut: "d" },
  { value: "action:assign", label: "Assign selected issue to me", group: "Actions", shortcut: "m" },
  { value: "action:clear", label: "Clear filters", group: "Actions", shortcut: "" },
];
const PALETTE_GROUPS = ["Go to", "Priority", "Actions"];

const STATUS_META: { [status in Status]: { pill: string; dot: string; soft: string } } = {
  Todo: { pill: "bg-[#f1efea] text-[#5f594f]", dot: "bg-[#a8a29e]", soft: "text-[#8a8378]" },
  "In progress": { pill: "bg-[#fef3c7] text-[#92400e]", dot: "bg-[#f59e0b]", soft: "text-[#b45309]" },
  Done: { pill: "bg-[#dcfce7] text-[#166534]", dot: "bg-[#22c55e]", soft: "text-[#15803d]" },
};

const PRIORITY_META: { [priority in Priority]: { label: string; className: string; level: number } } = {
  Urgent: { label: "Urgent", className: "text-[#dc2626]", level: 4 },
  High: { label: "High", className: "text-[#ea580c]", level: 3 },
  Normal: { label: "Normal", className: "text-[#0284c7]", level: 2 },
  Low: { label: "Low", className: "text-[#94a3b8]", level: 1 },
};

const AVATAR_TONES = [
  "bg-[#0f766e]",
  "bg-[#7c3aed]",
  "bg-[#b45309]",
  "bg-[#be123c]",
  "bg-[#0369a1]",
  "bg-[#4d7c0f]",
];

function initials(name: string): string {
  const parts = name.split(" ");
  return (parts[0].slice(0, 1) + (parts[1] ? parts[1].slice(0, 1) : "")).toUpperCase();
}

function tone(name: string): string {
  let hash = 0;
  for (let i = 0; i < name.length; i++) hash = (hash * 31 + name.charCodeAt(i)) >>> 0;
  return AVATAR_TONES[hash % AVATAR_TONES.length];
}

function matchesView(issue: Issue, view: View): boolean {
  if (view === "mine") return issue.assignee === ME;
  if (view === "all") return true;
  if (view === "inbox") return issue.status !== "Done";
  if (view === "open") return issue.status !== "Done";
  if (view === "progress") return issue.status === "In progress";
  return issue.status === "Done";
}

function PriorityBars({ level, className }: { level: number; className?: string }) {
  return (
    <span className={`inline-flex items-end gap-[2px] ${className ?? ""}`} title="Priority">
      {[1, 2, 3, 4].map((bar) => (
        <span
          key={bar}
          className={`w-[3px] rounded-sm ${bar <= level ? "bg-current" : "bg-current opacity-20"}`}
          style={{ height: `${3 + bar * 2}px` }}
        />
      ))}
    </span>
  );
}

function StatusIcon({ status }: { status: Status }) {
  return (
    <span className={`inline-flex ${STATUS_META[status].soft}`}>
      {status === "Todo" ? <IconCircle className="h-3.5 w-3.5" /> : status === "In progress" ? <IconHalf className="h-3.5 w-3.5" /> : <IconCheckCircle className="h-3.5 w-3.5" />}
    </span>
  );
}

function Avatar({ name, size = "sm" }: { name: string; size?: "sm" | "md" }) {
  const box = size === "md" ? "h-7 w-7 text-[11px]" : "h-5 w-5 text-[9px]";
  return (
    <span className={`inline-flex shrink-0 items-center justify-center rounded-full font-semibold text-white ${box} ${tone(name)}`} title={name}>
      {initials(name)}
    </span>
  );
}

function NavItem(props: { id: string; icon: ReactNode; label: string; count: number; active: boolean; onClick: () => void }) {
  return (
    <button
      id={props.id}
      onClick={props.onClick}
      className={`flex w-full items-center gap-2.5 rounded-md px-2.5 py-[7px] text-left text-[12.5px] transition-colors ${
        props.active ? "bg-[#242a33] text-white" : "text-[#aab2bd] hover:bg-[#1c2129] hover:text-[#e5e9ee]"
      }`}
    >
      <span className={props.active ? "text-[#5eead4]" : "text-[#7d8794]"}>{props.icon}</span>
      <span className="flex-1 truncate">{props.label}</span>
      <span className={`rounded px-1.5 py-px text-[10.5px] tabular-nums ${props.active ? "bg-[#323a45] text-[#c9d1da]" : "text-[#6b7480]"}`}>{props.count}</span>
    </button>
  );
}

function App() {
  const [issues, setIssues] = useState<Issue[]>(ISSUES);
  const [view, setView] = useState<View>("all");
  const [query, setQuery] = useState("");
  const [priority, setPriority] = useState<Priority | "Any">("Any");
  const [selectedId, setSelectedId] = useState(ISSUES[0].id);
  const [paletteOpen, setPaletteOpen] = useState(false);
  const [paletteQuery, setPaletteQuery] = useState("");
  const [paletteIndex, setPaletteIndex] = useState(0);
  const [newOpen, setNewOpen] = useState(false);
  const [newTitle, setNewTitle] = useState("");
  const [newPriority, setNewPriority] = useState<Priority>("Normal");
  const [newStatus, setNewStatus] = useState<Status>("Todo");
  const [newSeq, setNewSeq] = useState(1);
  const [draggingId, setDraggingId] = useState<string | null>(null);
  const [dropTarget, setDropTarget] = useState<{ id: string; after: boolean } | null>(null);
  // Reordering follows the pointer: the press records where it started, a move past a few pixels
  // starts the drag, and the release over a row names where the issue lands.
  const dragStart = useRef<{ id: string; x: number; y: number; active: boolean } | null>(null);

  /** The row under a viewport point, read from the page rather than the event target, since a
   *  pressed pointer's moves may all be delivered to the row where the press began. */
  function rowUnder(x: number, y: number): HTMLElement | null {
    const hit = document.elementFromPoint(x, y);
    const row = hit === null ? null : hit.closest("[data-issue-id]");
    return row as HTMLElement | null;
  }
  const [commentDraft, setCommentDraft] = useState("");
  const [flash, setFlash] = useState("");

  // A plain computation rather than useMemo: scriptc refuses a memo callback whose result is an
  // array of records (SC1090), and 24 rows are cheap to filter on every render.
  const needle = query.trim().toLowerCase();
  const shown = issues.filter((issue) => {
    if (!matchesView(issue, view)) return false;
    if (priority !== "Any" && issue.priority !== priority) return false;
    if (needle !== "") {
      const haystack = `${issue.key} ${issue.title} ${issue.assignee} ${issue.labels.join(" ")} ${issue.team}`.toLowerCase();
      if (!haystack.includes(needle)) return false;
    }
    return true;
  });

  const selected = shown.find((issue) => issue.id === selectedId) ?? null;

  const needlePalette = paletteQuery.trim().toLowerCase();
  const paletteMatches = PALETTE_COMMANDS.filter((item) => `${item.label} ${item.value}`.toLowerCase().includes(needlePalette));

  function openPalette() {
    setPaletteQuery("");
    setPaletteIndex(0);
    setPaletteOpen(true);
  }

  function closePalette() {
    const active = document.activeElement as HTMLElement | null;
    if (active !== null) active.blur();
    setPaletteOpen(false);
  }

  // Counted field by field: scriptc refuses a write through a key typed `string | undefined`.
  const counts: { [name in View]: number } = { inbox: 0, mine: 0, all: 0, open: 0, progress: 0, done: 0 };
  for (const issue of issues) {
    counts.all += 1;
    if (issue.assignee === ME) counts.mine += 1;
    if (issue.status !== "Done") {
      counts.inbox += 1;
      counts.open += 1;
    }
    if (issue.status === "In progress") counts.progress += 1;
    if (issue.status === "Done") counts.done += 1;
  }

  useEffect(() => {
    const visible = issues.filter((issue) => matchesView(issue, view) && (priority === "Any" || issue.priority === priority));
    if (visible.length > 0 && !visible.some((issue) => issue.id === selectedId)) setSelectedId(visible[0].id);
  }, [issues, view, priority, selectedId]);

  useEffect(() => {
    setCommentDraft("");
  }, [selectedId]);

  useEffect(() => {
    if (!paletteOpen) return;
    const field = document.getElementById("palette-input");
    if (field !== null) field.focus();
  }, [paletteOpen]);

  useEffect(() => {
    if (!newOpen) return;
    const field = document.getElementById("new-title");
    if (field !== null) field.focus();
  }, [newOpen]);

  useEffect(() => {
    function down(event: MouseEvent) {
      if (event.button !== 0) return;
      const row = rowUnder(event.clientX, event.clientY);
      if (row === null) return;
      const id = row.getAttribute("data-issue-id");
      if (id === null || id === "") return;
      dragStart.current = { id, x: event.clientX, y: event.clientY, active: false };
      event.preventDefault();
    }
    function move(event: MouseEvent) {
      const drag = dragStart.current;
      if (drag === null) return;
      if (!drag.active) {
        if (Math.abs(event.clientX - drag.x) + Math.abs(event.clientY - drag.y) < 4) return;
        drag.active = true;
        setDraggingId(drag.id);
      }
      const row = rowUnder(event.clientX, event.clientY);
      const targetId = row === null ? null : row.getAttribute("data-issue-id");
      if (targetId === null || targetId === "" || targetId === drag.id) return;
      const box = row === null ? { top: 0, height: 0 } : row.getBoundingClientRect();
      setDropTarget({ id: targetId, after: event.clientY > box.top + box.height / 2 });
    }
    function up(event: MouseEvent) {
      const drag = dragStart.current;
      dragStart.current = null;
      setDraggingId(null);
      setDropTarget(null);
      if (drag === null || !drag.active) return;
      const row = rowUnder(event.clientX, event.clientY);
      const targetId = row === null ? null : row.getAttribute("data-issue-id");
      if (targetId === null || targetId === "" || targetId === drag.id) return;
      const box = row === null ? { top: 0, height: 0 } : row.getBoundingClientRect();
      reorder(drag.id, targetId, event.clientY > box.top + box.height / 2);
    }
    window.addEventListener("mousedown", down);
    window.addEventListener("mousemove", move);
    window.addEventListener("mouseup", up);
    return () => {
      window.removeEventListener("mousedown", down);
      window.removeEventListener("mousemove", move);
      window.removeEventListener("mouseup", up);
    };
  }, []);

  useEffect(() => {
    if (flash === "") return;
    const timer = setTimeout(() => setFlash(""), 1800);
    return () => clearTimeout(timer);
  }, [flash]);

  function patchIssue(id: string, patch: Partial<Issue>) {
    setIssues((prev) => prev.map((issue) => (issue.id === id ? { ...issue, ...patch } : issue)));
  }

  function cycleStatus(id: string) {
    const issue = issues.find((item) => item.id === id);
    if (!issue) return;
    const next = STATUSES[(STATUSES.indexOf(issue.status) + 1) % STATUSES.length];
    patchIssue(id, { status: next });
    setFlash(`${issue.key} is now ${next.toLowerCase()}`);
  }

  function moveSelected(delta: number) {
    if (selected === null) return;
    setIssues((prev) => {
      const next = prev.slice();
      const from = next.findIndex((issue) => issue.id === selected.id);
      const to = from + delta;
      if (from < 0 || to < 0 || to >= next.length) return prev;
      const moved = next.splice(from, 1)[0];
      next.splice(to, 0, moved);
      return next;
    });
  }

  function stepSelection(delta: number) {
    if (shown.length === 0) return;
    const at = shown.findIndex((issue) => issue.id === selectedId);
    const next = shown[Math.min(shown.length - 1, Math.max(0, (at < 0 ? 0 : at) + delta))];
    if (next) setSelectedId(next.id);
  }

  useEffect(() => {
    function onKey(event: KeyboardEvent) {
      const key = event.key;
      const mod = event.metaKey || event.ctrlKey;
      if (paletteOpen) {
        if (key === "Escape") {
          closePalette();
          return;
        }
        if (key === "ArrowDown") {
          event.preventDefault();
          setPaletteIndex(Math.min(paletteMatches.length - 1, paletteIndex + 1));
          return;
        }
        if (key === "ArrowUp") {
          event.preventDefault();
          setPaletteIndex(Math.max(0, paletteIndex - 1));
          return;
        }
        if (key === "Enter") {
          event.preventDefault();
          const command = paletteMatches[paletteIndex];
          if (command !== undefined) runCommand(command.value);
          return;
        }
      }
      if (key === "Escape") {
        if (newOpen) setNewOpen(false);
        return;
      }
      if (mod && (key === "k" || key === "K")) {
        event.preventDefault();
        openPalette();
        return;
      }
      if (paletteOpen || newOpen) return;
      const target = event.target as HTMLElement | null;
      const tag = target ? target.tagName : "";
      const typing = tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || (target ? target.isContentEditable : false);
      if (typing || mod) return;
      if (event.altKey) {
        if (selected !== null && (key === "ArrowUp" || key === "ArrowDown")) {
          event.preventDefault();
          moveSelected(key === "ArrowUp" ? -1 : 1);
        }
        return;
      }
      if (key === "j" || key === "ArrowDown") {
        event.preventDefault();
        stepSelection(1);
      } else if (key === "k" || key === "ArrowUp") {
        event.preventDefault();
        stepSelection(-1);
      } else if (key === "e" && selected) {
        event.preventDefault();
        cycleStatus(selected.id);
      } else if (key === "m" && selected) {
        event.preventDefault();
        patchIssue(selected.id, { assignee: ME });
        setFlash(`Assigned ${selected.key} to you`);
      } else if (key === "d" && selected) {
        event.preventDefault();
        patchIssue(selected.id, { status: selected.status === "Done" ? "Todo" : "Done" });
      } else if (key === "n") {
        event.preventDefault();
        setNewOpen(true);
      } else if (key === "?") {
        event.preventDefault();
        openPalette();
      } else if (key === "1") {
        setPriority("Any");
      } else if (key === "2") {
        setPriority("Urgent");
      } else if (key === "3") {
        setPriority("High");
      } else if (key === "4") {
        setPriority("Normal");
      }
    }
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [shown, selectedId, selected, paletteOpen, newOpen, paletteQuery, paletteIndex, paletteMatches.length]);

  function reorder(sourceId: string, targetId: string, after: boolean) {
    setIssues((prev) => {
      const next = prev.slice();
      const from = next.findIndex((issue) => issue.id === sourceId);
      if (from < 0) return prev;
      const moved = next.splice(from, 1)[0];
      let to = next.findIndex((issue) => issue.id === targetId);
      if (to < 0) return prev;
      if (after) to += 1;
      next.splice(to, 0, moved);
      return next;
    });
  }

  function createIssue() {
    const title = newTitle.trim();
    if (title === "") return;
    const id = `new-${newSeq}`;
    setNewSeq(newSeq + 1);
    const issue: Issue = {
      id,
      key: `HAL-${1001 + issues.length}`,
      title,
      status: newStatus,
      priority: newPriority,
      assignee: ME,
      labels: ["new"],
      team: "Atlas",
      age: "now",
      description: ["No description yet. Add the steps to reproduce and what you expected to see."],
      checklist: [],
      comments: [],
    };
    setIssues([issue, ...issues]);
    setSelectedId(id);
    setNewTitle("");
    setNewPriority("Normal");
    setNewStatus("Todo");
    setNewOpen(false);
    setFlash(`Created ${issue.key}`);
  }

  function addComment() {
    if (!selected || commentDraft.trim() === "") return;
    const body = commentDraft.trim();
    setIssues((prev) =>
      prev.map((issue) => (issue.id === selected.id ? { ...issue, comments: [...issue.comments, { author: ME, ago: "now", body }] } : issue)),
    );
    setCommentDraft("");
    setFlash("Comment added");
  }

  function toggleCheck(id: string, index: number, done: boolean) {
    setIssues((prev) =>
      prev.map((issue) => {
        if (issue.id !== id) return issue;
        const checklist = issue.checklist.map((item, at) => (at === index ? { ...item, done } : item));
        return { ...issue, checklist };
      }),
    );
  }

  function runCommand(value: string) {
    if (value === "action:new") setNewOpen(true);
    else if (value === "action:cycle" && selected) cycleStatus(selected.id);
    else if (value === "action:done" && selected) patchIssue(selected.id, { status: "Done" });
    else if (value === "action:assign" && selected) patchIssue(selected.id, { assignee: ME });
    else if (value === "action:clear") {
      setQuery("");
      setPriority("Any");
    } else if (value.startsWith("view:")) {
      setView(value.slice(5) as View);
    } else if (value.startsWith("priority:")) {
      setPriority(value.slice(9) as Priority | "Any");
    }
    closePalette();
  }

  const heading = view === "mine" ? "My issues" : view === "inbox" ? "Inbox" : view === "open" ? "Open issues" : view === "progress" ? "In progress" : view === "done" ? "Done" : "All issues";
  const checklistDone = selected ? selected.checklist.filter((item) => item.done).length : 0;
  const checklistTotal = selected ? selected.checklist.length : 0;

  return (
    <div className="flex h-full w-full overflow-hidden bg-[#f4f2ee] text-[13px] text-[#25211b] antialiased">
      <aside className="flex w-[232px] shrink-0 flex-col border-r border-[#20242b] bg-[#14171c]">
        <div className="flex items-center gap-2.5 px-4 pb-4 pt-5">
          <span className="text-[#5eead4]">
            <IconLogo className="h-7 w-7" />
          </span>
          <div className="leading-tight">
            <div className="text-[14.5px] font-semibold tracking-tight text-white">Halyard</div>
            <div className="text-[10px] font-medium uppercase tracking-[0.14em] text-[#6b7480]">Issues</div>
          </div>
        </div>

        <div className="px-4">
          <button
            id="open-palette"
            onClick={openPalette}
            className="flex w-full items-center gap-2 rounded-md border border-[#2b313b] bg-[#1a1e25] px-2.5 py-1.5 text-left text-[12px] text-[#8b95a1] transition-colors hover:border-[#3a424e] hover:text-[#c3cbd5]"
          >
            <IconSearch className="h-3.5 w-3.5" />
            <span className="flex-1">Search or jump to…</span>
            <span className="rounded border border-[#333b47] bg-[#232932] px-1 py-px text-[10px] text-[#8b95a1]">⌘K</span>
          </button>
        </div>

        {paletteOpen ? (
          <div className="fixed inset-0 z-50">
            <div className="absolute inset-0 bg-[rgba(16,19,23,0.42)]" onClick={closePalette} />
            <div id="palette" role="dialog" aria-label="Command palette" className="absolute left-[calc(50%_-_280px)] top-[14%] w-[560px] overflow-hidden rounded-xl border border-[#ddd6ca] bg-[#fffdfa] shadow-2xl">
              <div className="flex items-center gap-2.5 border-b border-[#eee8dd] px-4 py-3">
                <IconSearch className="h-4 w-4 text-[#a39b8e]" />
                <Input
                  id="palette-input"
                  aria-label="Search commands"
                  placeholder="Type a command…"
                  value={paletteQuery}
                  onValueChange={(value) => {
                    setPaletteQuery(value);
                    setPaletteIndex(0);
                  }}
                  className="w-full bg-transparent text-[13px] outline-none placeholder:text-[#a39b8e]"
                />
                <span className="rounded border border-[#e6e0d4] px-1.5 py-px text-[10px] text-[#a39b8e]">esc</span>
              </div>
              <div className="max-h-[340px] overflow-y-auto p-1.5">
                {paletteMatches.length === 0 ? (
                  <div className="px-4 py-6 text-center text-[12.5px] text-[#8a8378]">No matching commands.</div>
                ) : null}
                {PALETTE_GROUPS.map((group) => {
                  const items = paletteMatches.filter((item) => item.group === group);
                  if (items.length === 0) return null;
                  return (
                    <div key={group}>
                      <div className="px-2 py-1 text-[10px] font-semibold uppercase tracking-[0.12em] text-[#a39b8e]">{group}</div>
                      {items.map((item) => {
                        const index = paletteMatches.indexOf(item);
                        const active = index === paletteIndex;
                        return (
                          <button
                            key={item.value}
                            onClick={() => runCommand(item.value)}
                            onMouseEnter={() => setPaletteIndex(index)}
                            className={`flex w-full items-center gap-2.5 rounded-md px-2.5 py-1.5 text-left text-[12.5px] ${
                              active ? "bg-[#0f766e] text-white" : "text-[#3f3a33] hover:bg-[#f4f0e8]"
                            }`}
                          >
                            <span className={active ? "text-[#d7f3ee]" : "text-[#8a8378]"}>
                              {group === "Go to" ? <IconChevronRight className="h-3.5 w-3.5" /> : group === "Priority" ? <IconFilter className="h-3.5 w-3.5" /> : <IconBolt className="h-3.5 w-3.5" />}
                            </span>
                            <span className="flex-1">{item.label}</span>
                            {item.shortcut === "" ? null : (
                              <span className={`rounded border px-1 text-[10px] ${active ? "border-[#5aa79f] text-[#d7f3ee]" : "border-[#e6e0d4] text-[#a39b8e]"}`}>{item.shortcut}</span>
                            )}
                          </button>
                        );
                      })}
                    </div>
                  );
                })}
              </div>
            </div>
          </div>
        ) : null}

        <nav className="mt-4 flex flex-col gap-0.5 px-2">
          {VIEWS.slice(0, 3).map((item) => (
            <NavItem
              key={item.id}
              id={`nav-${item.id}`}
              icon={item.icon === "inbox" ? <IconInbox className="h-3.5 w-3.5" /> : item.icon === "user" ? <IconUser className="h-3.5 w-3.5" /> : <IconStack className="h-3.5 w-3.5" />}
              label={item.label}
              count={counts[item.id]}
              active={view === item.id}
              onClick={() => setView(item.id)}
            />
          ))}
        </nav>

        <div className="mt-5 px-4 text-[10px] font-semibold uppercase tracking-[0.14em] text-[#6b7480]">Saved views</div>
        <nav className="mt-1.5 flex flex-col gap-0.5 px-2">
          {VIEWS.slice(3).map((item) => (
            <NavItem
              key={item.id}
              id={`nav-${item.id}`}
              icon={item.icon === "half" ? <IconHalf className="h-3.5 w-3.5" /> : item.icon === "check" ? <IconCheckCircle className="h-3.5 w-3.5" /> : <IconCircle className="h-3.5 w-3.5" />}
              label={item.label}
              count={counts[item.id]}
              active={view === item.id}
              onClick={() => setView(item.id)}
            />
          ))}
        </nav>

        <div className="mt-5 px-4 text-[10px] font-semibold uppercase tracking-[0.14em] text-[#6b7480]">Teams</div>
        <nav className="mt-1.5 flex flex-col gap-0.5 px-2">
          {TEAMS.map((team) => (
            <button
              key={team.name}
              onClick={() => setQuery(team.name)}
              className="flex w-full items-center gap-2.5 rounded-md px-2.5 py-[7px] text-left text-[12.5px] text-[#aab2bd] transition-colors hover:bg-[#1c2129] hover:text-[#e5e9ee]"
            >
              <span className="h-2 w-2 rounded-sm" style={{ backgroundColor: team.color }} />
              <span className="flex-1">{team.name}</span>
              <span className="text-[10.5px] text-[#6b7480] tabular-nums">{issues.filter((issue) => issue.team === team.name && issue.status !== "Done").length}</span>
            </button>
          ))}
        </nav>

        <div className="mt-auto px-3 pb-3">
          <div className="rounded-lg border border-[#262d36] bg-[#181d24] p-2.5">
            <div className="flex items-center gap-1.5 text-[11px] font-medium text-[#c9d1da]">
              <IconCommand className="h-3.5 w-3.5 text-[#5eead4]" />
              Keyboard first
            </div>
            <div className="mt-1.5 space-y-1 text-[10.5px] leading-4 text-[#7d8794]">
              <div className="flex justify-between"><span>Move selection</span><span className="text-[#aab2bd]">j / k</span></div>
              <div className="flex justify-between"><span>Change status</span><span className="text-[#aab2bd]">e</span></div>
              <div className="flex justify-between"><span>Command palette</span><span className="text-[#aab2bd]">⌘K</span></div>
            </div>
          </div>
          <div className="mt-3 flex items-center gap-2 px-1 py-1">
            <Avatar name={ME} size="md" />
            <div className="min-w-0 flex-1 leading-tight">
              <div className="truncate text-[12px] font-medium text-[#e5e9ee]">{ME}</div>
              <div className="text-[10.5px] text-[#7d8794]">Brineworks</div>
            </div>
            <IconChevronDown className="h-3.5 w-3.5 text-[#6b7480]" />
          </div>
        </div>
      </aside>

      <main className="flex min-w-0 flex-1">
        <section className="flex w-[394px] shrink-0 flex-col border-r border-[#e6e0d5] bg-[#faf8f4]">
          <div className="border-b border-[#e6e0d5] px-4 pb-3 pt-4">
            <div className="flex items-center gap-2">
              <h1 className="text-[16px] font-semibold tracking-tight">{heading}</h1>
              <span className="rounded-full bg-[#eae5db] px-1.5 py-px text-[10.5px] font-medium text-[#6b655b] tabular-nums">{shown.length}</span>
              <span className="flex-1" />
              <button
                id="new-issue"
                onClick={() => setNewOpen(true)}
                className="flex items-center gap-1 rounded-md bg-[#0f766e] px-2 py-1.5 text-[11.5px] font-medium text-white transition-colors hover:bg-[#0d6a63]"
              >
                <IconPlus className="h-3.5 w-3.5" />
                New
              </button>
            </div>
            <div className="mt-3 flex items-center gap-2 rounded-md border border-[#e2dcd0] bg-white px-2.5 py-1.5 focus-within:border-[#0f766e]">
              <IconSearch className="h-3.5 w-3.5 shrink-0 text-[#a39b8e]" />
              <Input
                id="issue-search"
                type="search"
                aria-label="Search issues"
                placeholder="Filter by title, key, label…"
                value={query}
                onValueChange={(value) => setQuery(value)}
                className="w-full bg-transparent text-[12px] outline-none placeholder:text-[#a39b8e]"
              />
              {query === "" ? null : (
                <button onClick={() => setQuery("")} aria-label="Clear search" className="text-[#a39b8e] hover:text-[#5f594f]">
                  <IconClose className="h-3.5 w-3.5" />
                </button>
              )}
            </div>
            <div className="mt-2.5 flex flex-wrap items-center gap-1">
              {PRIORITIES.map((item) => (
                <button
                  key={item}
                  id={`filter-${item.toLowerCase()}`}
                  onClick={() => setPriority(item)}
                  className={`rounded-full border px-2 py-[3px] text-[10.5px] font-medium transition-colors ${
                    priority === item
                      ? "border-[#0f766e] bg-[#0f766e] text-white"
                      : "border-[#e2dcd0] bg-[#fdfcf8] text-[#6b655b] hover:border-[#cfc7b8] hover:text-[#3f3a33]"
                  }`}
                >
                  {item === "Any" ? "Any priority" : item}
                </button>
              ))}
            </div>
          </div>

          <div className="flex items-center justify-between px-4 py-1.5 text-[10px] font-medium uppercase tracking-[0.1em] text-[#a39b8e]">
            <span>Title</span>
            <span className="flex items-center gap-1">
              <IconGrip className="h-3 w-3" />
              drag to reorder
            </span>
          </div>

          <div className="min-h-0 flex-1 select-none overflow-y-auto">
            {shown.length === 0 ? (
              <div className="px-6 py-10 text-center">
                <div className="mx-auto flex h-9 w-9 items-center justify-center rounded-full bg-[#eee9df] text-[#a39b8e]">
                  <IconSearch className="h-4 w-4" />
                </div>
                <div className="mt-3 text-[12.5px] font-medium text-[#5f594f]">No issues match</div>
                <p className="mt-1 text-[11.5px] leading-5 text-[#8a8378]">Try another search, or clear the filters to see every issue.</p>
                <button onClick={() => { setQuery(""); setPriority("Any"); }} className="mt-3 rounded-md border border-[#ddd6ca] bg-white px-2.5 py-1 text-[11.5px] text-[#3f3a33] hover:border-[#c6bdad]">
                  Clear filters
                </button>
              </div>
            ) : (
              shown.map((issue) => {
                const active = issue.id === selectedId;
                const meta = STATUS_META[issue.status];
                const priorityMeta = PRIORITY_META[issue.priority];
                const drop = dropTarget !== null && dropTarget.id === issue.id;
                return (
                  <div
                    key={issue.id}
                    id={`issue-row-${issue.id}`}
                    data-issue-id={issue.id}
                    draggable={false}
                    onClick={() => setSelectedId(issue.id)}
                    className={`group relative cursor-pointer border-b border-[#efebe2] px-3.5 py-2.5 transition-colors ${
                      active ? "bg-white" : "hover:bg-[#fdfcf8]"
                    } ${draggingId === issue.id ? "opacity-40" : ""}`}
                  >
                    {drop ? <div className={`absolute inset-x-3 h-[2px] rounded bg-[#0f766e] ${dropTarget.after ? "-bottom-px" : "-top-px"}`} /> : null}
                    {active ? <div className="absolute inset-y-2 left-0 w-[3px] rounded-r bg-[#0f766e]" /> : null}
                    <div className="flex gap-2">
                      <span className={`mt-0.5 flex w-3 shrink-0 items-center justify-center ${active ? "text-[#b7af9f]" : "text-[#d4ccbd] opacity-0 group-hover:opacity-100"}`}>
                        <IconGrip className="h-3.5 w-3.5" />
                      </span>
                      <div className="min-w-0 flex-1">
                        <div className="flex items-center gap-1.5">
                          <span className="font-mono text-[10.5px] text-[#8a8378]">{issue.key}</span>
                          <span className={`h-[5px] w-[5px] rounded-full ${meta.dot}`} />
                          <span className="text-[10.5px] text-[#8a8378]">{issue.status}</span>
                          <span className="flex-1" />
                          <PriorityBars level={priorityMeta.level} className={priorityMeta.className} />
                        </div>
                        <div className="mt-0.5 truncate text-[12.5px] font-medium leading-5 text-[#25211b]">{issue.title}</div>
                        <div className="mt-1 flex items-center gap-1.5">
                          {issue.labels.slice(0, 2).map((label) => (
                            <span key={label} className="rounded border border-[#e8e2d7] bg-[#fdfcf9] px-1.5 py-px text-[10px] text-[#6b655b]">{label}</span>
                          ))}
                          <span className="flex-1" />
                          <span className="text-[10px] text-[#a39b8e]">{issue.age}</span>
                          <Avatar name={issue.assignee} />
                        </div>
                      </div>
                    </div>
                  </div>
                );
              })
            )}
          </div>

          <div id="order-first" className="hidden">{shown.slice(0, 3).map((issue) => issue.key).join(" ")}</div>
          <div id="status" className="border-t border-[#e6e0d5] px-4 py-2 text-[10.5px] text-[#8a8378]">
            {selected ? `${selected.key} · ${selected.status}` : "No issue selected"}
          </div>
        </section>

        <section className="flex min-w-0 flex-1 flex-col bg-[#fffdfa]">
          {selected === null ? (
            <div className="flex flex-1 flex-col items-center justify-center px-10 text-center">
              <span className="text-[#c6bdad]"><IconStack className="h-9 w-9" /></span>
              <div className="mt-3 text-[13px] font-medium text-[#5f594f]">Nothing selected</div>
              <p className="mt-1 max-w-[280px] text-[11.5px] leading-5 text-[#8a8378]">Pick an issue from the list, or press N to write a new one.</p>
            </div>
          ) : (
            <>
              <div className="flex h-[52px] shrink-0 items-center gap-2 border-b border-[#eee8dd] px-5">
                <span className="flex items-center gap-1 text-[11px] text-[#8a8378]">
                  <span className="h-2 w-2 rounded-sm" style={{ backgroundColor: TEAMS.find((team) => team.name === selected.team)?.color ?? "#8a8378" }} />
                  {selected.team}
                </span>
                <IconChevronRight className="h-3 w-3 text-[#c6bdad]" />
                <span className="font-mono text-[11px] text-[#8a8378]">{selected.key}</span>
                <span className="flex-1" />
                <div className="flex items-center rounded-md border border-[#e6e0d5] bg-[#faf8f4] p-0.5">
                  {STATUSES.map((status) => (
                    <button
                      key={status}
                      id={`set-status-${status === "In progress" ? "progress" : status.toLowerCase()}`}
                      onClick={() => patchIssue(selected.id, { status })}
                      className={`rounded px-2 py-1 text-[10.5px] font-medium transition-colors ${
                        selected.status === status ? `${STATUS_META[status].pill} shadow-sm` : "text-[#8a8378] hover:text-[#3f3a33]"
                      }`}
                    >
                      {status}
                    </button>
                  ))}
                </div>
                <button className="rounded-md p-1.5 text-[#8a8378] transition-colors hover:bg-[#f3efe7] hover:text-[#3f3a33]" aria-label="More actions">
                  <IconMore className="h-4 w-4" />
                </button>
              </div>

              <div className="min-h-0 flex-1 select-none overflow-y-auto">
                <div className="mx-auto max-w-[720px] px-8 pb-10 pt-7">
                  <div className="flex items-start gap-3">
                    <StatusIcon status={selected.status} />
                    <h2 className="flex-1 text-[22px] font-semibold leading-8 tracking-tight text-[#1f1c17]">{selected.title}</h2>
                  </div>

                  <div className="mt-4 flex flex-wrap items-center gap-x-2 gap-y-1.5 border-b border-[#efe9df] pb-4 text-[11.5px] text-[#6b655b]">
                    <span className="flex items-center gap-1.5">
                      <Avatar name={selected.assignee} size="md" />
                      <span className="font-medium text-[#3f3a33]">{selected.assignee}</span>
                      <IconChevronDown className="h-3 w-3 text-[#a39b8e]" />
                    </span>
                    <span className="text-[#d4ccbd]">·</span>
                    <span className={`flex items-center gap-1.5 font-medium ${PRIORITY_META[selected.priority].className}`}>
                      <IconBolt className="h-3.5 w-3.5" />
                      {selected.priority}
                    </span>
                    <span className="text-[#d4ccbd]">·</span>
                    <span className="flex items-center gap-1.5">
                      <IconCal className="h-3.5 w-3.5 text-[#a39b8e]" />
                      opened {selected.age} ago
                    </span>
                    <span className="flex-1" />
                    <span className="flex items-center gap-1.5 text-[#8a8378]">
                      <IconComment className="h-3.5 w-3.5" />
                      {selected.comments.length}
                    </span>
                  </div>

                  <div className="mt-4 flex flex-wrap items-center gap-1.5">
                    <span className="flex items-center gap-1 text-[10.5px] font-medium uppercase tracking-[0.1em] text-[#a39b8e]">
                      <IconTag className="h-3 w-3" />
                      Labels
                    </span>
                    {selected.labels.map((label) => (
                      <span key={label} className="rounded-full border border-[#e6e0d5] bg-[#faf8f4] px-2 py-[2px] text-[10.5px] text-[#5f594f]">{label}</span>
                    ))}
                    <button className="rounded-full border border-dashed border-[#dcd5c8] px-2 py-[1px] text-[10.5px] text-[#a39b8e] hover:border-[#c6bdad] hover:text-[#6b655b]">
                      + label
                    </button>
                  </div>

                  <div className="mt-7">
                    <h3 className="text-[10.5px] font-semibold uppercase tracking-[0.12em] text-[#a39b8e]">Description</h3>
                    <div className="mt-2 space-y-3 text-[13px] leading-[1.65] text-[#3f3a33]">
                      {selected.description.map((paragraph, index) => (
                        <p key={index}>{paragraph}</p>
                      ))}
                    </div>
                  </div>

                  {checklistTotal > 0 ? (
                    <div className="mt-7">
                      <div className="flex items-center gap-2">
                        <h3 className="text-[10.5px] font-semibold uppercase tracking-[0.12em] text-[#a39b8e]">Steps</h3>
                        <span className="text-[10.5px] text-[#8a8378] tabular-nums">{checklistDone}/{checklistTotal}</span>
                        <span className="h-[3px] flex-1 overflow-hidden rounded-full bg-[#eee9df]">
                          <span className="block h-full rounded-full bg-[#0f766e]" style={{ width: `${Math.round((checklistDone / checklistTotal) * 100)}%` }} />
                        </span>
                      </div>
                      <div className="mt-2.5 space-y-1">
                        {selected.checklist.map((item, index) => (
                          <div key={index} className="flex items-center gap-2.5 rounded-md px-1 py-1 hover:bg-[#faf8f4]">
                            <button
                              id={`check-${selected.id}-${index}`}
                              role="checkbox"
                              aria-checked={item.done}
                              onClick={() => toggleCheck(selected.id, index, !item.done)}
                              className={`flex h-[15px] w-[15px] shrink-0 items-center justify-center rounded border ${
                                item.done ? "border-[#0f766e] bg-[#0f766e] text-white" : "border-[#d7d0c4] bg-white"
                              }`}
                            >
                              {item.done ? <IconCheck className="h-2.5 w-2.5" /> : null}
                            </button>
                            <span className={`text-[12.5px] ${item.done ? "text-[#a39b8e] line-through" : "text-[#3f3a33]"}`}>{item.text}</span>
                          </div>
                        ))}
                      </div>
                    </div>
                  ) : null}

                  <div className="mt-7">
                    <div className="flex items-center gap-2">
                      <h3 className="text-[10.5px] font-semibold uppercase tracking-[0.12em] text-[#a39b8e]">Comments</h3>
                      <span className="rounded bg-[#f1ede5] px-1.5 text-[10px] text-[#8a8378] tabular-nums">{selected.comments.length}</span>
                    </div>
                    {selected.comments.length === 0 ? (
                      <p className="mt-2 text-[11.5px] text-[#a39b8e]">No comments yet. Start the conversation below.</p>
                    ) : (
                      <div className="mt-3 space-y-3">
                        {selected.comments.map((comment, index) => (
                          <div key={index} className="rounded-lg border border-[#eee9df] bg-[#faf8f4] p-3">
                            <div className="flex items-center gap-2">
                              <Avatar name={comment.author} />
                              <span className="text-[11.5px] font-medium text-[#3f3a33]">{comment.author}</span>
                              <span className="text-[10.5px] text-[#a39b8e]">{comment.ago} ago</span>
                            </div>
                            <p className="mt-1.5 text-[12px] leading-5 text-[#4a453d]">{comment.body}</p>
                          </div>
                        ))}
                      </div>
                    )}
                    <div className="mt-3 flex items-center gap-2 rounded-lg border border-[#e2dcd0] bg-white px-2 py-1.5 focus-within:border-[#0f766e]">
                      <Avatar name={ME} />
                      <Input
                        id="comment-input"
                        aria-label="Write a comment"
                        placeholder="Write a comment…"
                        value={commentDraft}
                        onValueChange={(value) => setCommentDraft(value)}
                        className="w-full bg-transparent text-[12px] outline-none placeholder:text-[#a39b8e]"
                      />
                      <Button id="add-comment" disabled={commentDraft.trim() === ""} onClick={addComment} className="rounded bg-[#0f766e] px-2.5 py-1 text-[11px] font-medium text-white disabled:bg-[#d7d0c4] enabled:hover:bg-[#0d6a63]">
                        Comment
                      </Button>
                    </div>
                  </div>
                </div>
              </div>

              <div className="flex h-[34px] shrink-0 items-center gap-3 border-t border-[#f0ebe1] px-5 text-[10px] text-[#a39b8e]">
                <span className="flex items-center gap-1"><IconArrowUp className="h-3 w-3" /><IconArrowDown className="h-3 w-3" />j k</span>
                <span>e status</span>
                <span>m assign</span>
                <span>d done</span>
                <span>⌥↑↓ move</span>
                <span className="flex-1" />
                {flash !== "" ? <span className="rounded bg-[#ecfdf5] px-2 py-0.5 font-medium text-[#0f766e]">{flash}</span> : <span>{issues.length} issues in Brineworks</span>}
              </div>
            </>
          )}
        </section>
      </main>

      {newOpen ? (
        <div className="fixed inset-0 z-50">
          <div className="absolute inset-0 bg-[rgba(16,19,23,0.42)]" onClick={() => setNewOpen(false)} />
          <div id="new-issue-dialog" role="dialog" aria-labelledby="new-issue-title" className="absolute left-[calc(50%_-_240px)] top-[18%] w-[480px] rounded-xl border border-[#ddd6ca] bg-[#fffdfa] p-5 shadow-2xl">
          <h2 id="new-issue-title" className="text-[15px] font-semibold tracking-tight text-[#1f1c17]">New issue</h2>
          <p className="mt-0.5 text-[11.5px] text-[#8a8378]">Keep the title short. The details can follow.</p>
          <div className="mt-4">
            <Input
              id="new-title"
              autoFocus
              placeholder="What needs to be done?"
              value={newTitle}
              onValueChange={(value) => setNewTitle(value)}
              className="w-full rounded-md border border-[#e2dcd0] bg-white px-2.5 py-2 text-[13px] outline-none placeholder:text-[#a39b8e] focus:border-[#0f766e]"
            />
          </div>
          <div className="mt-3 grid grid-cols-2 gap-3">
            <div>
              <div className="text-[10px] font-semibold uppercase tracking-[0.1em] text-[#a39b8e]">Status</div>
              <div className="mt-1 flex rounded-md border border-[#e6e0d5] bg-[#faf8f4] p-0.5">
                {STATUSES.map((status) => (
                  <button
                    key={status}
                    id={`new-status-${status === "In progress" ? "progress" : status.toLowerCase()}`}
                    onClick={() => setNewStatus(status)}
                    className={`flex-1 rounded px-1 py-1 text-[10.5px] font-medium ${newStatus === status ? STATUS_META[status].pill : "text-[#8a8378] hover:text-[#3f3a33]"}`}
                  >
                    {status}
                  </button>
                ))}
              </div>
            </div>
            <div>
              <div className="text-[10px] font-semibold uppercase tracking-[0.1em] text-[#a39b8e]">Priority</div>
              <div className="mt-1 flex rounded-md border border-[#e6e0d5] bg-[#faf8f4] p-0.5">
                {(["Urgent", "High", "Normal", "Low"] as Priority[]).map((item) => (
                  <button
                    key={item}
                    id={`new-priority-${item.toLowerCase()}`}
                    onClick={() => setNewPriority(item)}
                    className={`flex-1 rounded px-1 py-1 text-[10.5px] font-medium ${newPriority === item ? "bg-white text-[#3f3a33] shadow-sm" : "text-[#8a8378] hover:text-[#3f3a33]"}`}
                  >
                    {item}
                  </button>
                ))}
              </div>
            </div>
          </div>
          <div className="mt-5 flex items-center justify-end gap-2">
            <button id="cancel-new-issue" onClick={() => setNewOpen(false)} className="rounded-md border border-[#ddd6ca] bg-white px-2.5 py-1.5 text-[11.5px] text-[#3f3a33] hover:border-[#c6bdad]">Cancel</button>
            <Button id="create-issue" disabled={newTitle.trim() === ""} onClick={createIssue} className="rounded-md bg-[#0f766e] px-3 py-1.5 text-[11.5px] font-medium text-white disabled:bg-[#d7d0c4] enabled:hover:bg-[#0d6a63]">
              Create issue
            </Button>
          </div>
          </div>
        </div>
      ) : null}
    </div>
  );
}

createRoot(document.getElementById("root")!).render(<App />);
