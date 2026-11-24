// A ticket tracker: a few hundred tickets in a list, each with a long description, labels and
// comments. The list and the description scroll, so it is the app to profile when a scroll or a
// text selection has to keep up with the pointer.

type Block = { kind: "p" | "code" | "list"; text: string };

interface Comment {
  author: string;
  body: string;
}

interface Ticket {
  key: string;
  title: string;
  status: string;
  priority: string;
  labels: string[];
  author: string;
  updated: string;
  body: Block[];
  comments: Comment[];
}

/** A deterministic generator, so every run shows the same tickets. */
function rng(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const PROJECTS = ["NAT", "LAY", "EDT", "INP", "CMP"];
const AUTHORS = ["ada", "grace", "linus", "margaret", "alan", "barbara", "ken", "frances"];
const LABELS = ["bug", "perf", "macos", "input", "layout", "paint", "p1", "p2", "needs review", "ready"];
const TITLES = [
  "Trackpad scroll stops after a fast swipe in a long list",
  "Selection highlight lags behind the pointer in a long description",
  "Rows scrolled into view are blank until the next frame",
  "Frame time grows with the number of tickets, not with the change",
  "Wheel events are read in a burst, then the page stalls",
  "Scrolling a detail pane repaints the list beside it",
  "Text selection across a code block misses the last line",
  "The list jumps when the scrollbar appears",
  "Dragging a selection past the edge does not scroll",
  "A 500 ticket list takes too long to open",
  "Comments below a long description paint slowly",
  "Momentum scroll events arrive after the finger lifts",
];

const SENTENCES = [
  "The list has a few hundred rows and each one is a line of text with a second line of metadata.",
  "Scrolling with the trackpad moved the content for a moment and then stopped, as if the app had lost the gesture.",
  "Once the description grew past a screen, selecting text in it took most of a second to show the highlight.",
  "A frame log showed the whole page being recorded again for every wheel event, whether or not anything changed.",
  "Hit testing walked every box in the page for each pointer move instead of descending from the box under the pointer.",
  "The work should be proportional to what changed, not to what the page contains.",
  "The description is long on purpose: several long paragraphs, a list, and a code block, like a real report.",
  "The selection is painted per line, so the number of lines that change is what the frame should cost.",
  "A scroll moves the content under a transform the compositor already holds, so no text has to be shaped again.",
  "When the boxes under a scrollport are measured, the offset of that scrollport has to be part of the test.",
  "The row under the pointer takes its hover state without restyling the page around it.",
  "The fix keeps the work local, and the frame line in the log shows it.",
];

const CODE = `const rows = tickets.filter((ticket) => ticket.status === "open");
for (const row of rows) {
  render(row);
}

// Only the rows a frame can show are painted.
for (let i = firstVisible; i < lastVisible; i++) {
  paint(rows[i]);
}`;

function makeBody(seed: number, paragraphs: number): Block[] {
  const rand = rng(seed);
  const blocks: Block[] = [];
  for (let p = 0; p < paragraphs; p++) {
    const n = 2 + Math.floor(rand() * 4);
    const parts: string[] = [];
    for (let s = 0; s < n; s++) parts.push(SENTENCES[Math.floor(rand() * SENTENCES.length)]);
    blocks.push({ kind: "p", text: parts.join(" ") });
    if (p % 4 === 2) {
      blocks.push({ kind: "list", text: "Reproduce with a 500 ticket list\nRecord the frame times while scrolling\nCompare the selection highlight with the pointer\nAdd a test that drives the wheel" });
    }
    if (p % 6 === 3) blocks.push({ kind: "code", text: CODE });
  }
  return blocks;
}

function makeTickets(): Ticket[] {
  const tickets: Ticket[] = [];
  const now = Date.UTC(2026, 10, 20, 6, 0, 0);
  for (let i = 0; i < 500; i++) {
    const rand = rng(7 + i);
    const project = PROJECTS[i % PROJECTS.length];
    const paragraphs = i % 97 === 0 ? 90 : 5 + Math.floor(rand() * 9);
    const comments: Comment[] = [];
    const commentCount = Math.floor(rand() * 6);
    for (let c = 0; c < commentCount; c++) {
      comments.push({
        author: AUTHORS[(i + c * 3) % AUTHORS.length],
        body: SENTENCES[(i + c) % SENTENCES.length] + " " + SENTENCES[(i + c + 5) % SENTENCES.length],
      });
    }
    tickets.push({
      key: `${project}-${1000 + i * 3}`,
      title: TITLES[i % TITLES.length],
      status: rand() < 0.75 ? "Open" : rand() < 0.5 ? "In review" : "Blocked",
      priority: rand() < 0.2 ? "Urgent" : rand() < 0.5 ? "High" : "Normal",
      labels: [LABELS[i % LABELS.length], LABELS[(i * 5 + 3) % LABELS.length]],
      author: AUTHORS[i % AUTHORS.length],
      updated: new Date(now - i * 41 * 60 * 1000).toISOString(),
      body: makeBody(5000 + i, paragraphs),
      comments,
    });
  }
  return tickets;
}

const tickets = makeTickets();
const filters = [
  { id: "all", title: "All tickets", test: (_: Ticket) => true },
  { id: "open", title: "Open", test: (t: Ticket) => t.status === "Open" },
  { id: "review", title: "In review", test: (t: Ticket) => t.status === "In review" },
];

let filter = "all";
let selected: string | null = null;

function relative(iso: string): string {
  const then = Date.parse(iso);
  if (Number.isNaN(then)) return "";
  const minutes = Math.max(0, Math.round((Date.now() - then) / 60000));
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 48) return `${hours}h ago`;
  return `${Math.round(hours / 24)}d ago`;
}

function el(tag: string, className: string, text: string = ""): HTMLElement {
  const node = document.createElement(tag);
  if (className !== "") node.className = className;
  if (text !== "") node.textContent = text;
  return node;
}

const app = document.getElementById("app")!;
const shell = el("div", "shell");
const sidebar = el("nav", "sidebar");
sidebar.appendChild(el("div", "brand", "Tickets"));
sidebar.appendChild(el("div", "section", "Projects"));
const counts = el("div", "");
sidebar.appendChild(counts);
sidebar.appendChild(el("div", "spacer"));

const list = el("section", "list");
const listHeader = el("header", "list-header");
const rows = el("div", "rows");
const status = el("div", "");
status.id = "status";
list.appendChild(listHeader);
list.appendChild(rows);
list.appendChild(status);

const detail = el("section", "detail");
detail.appendChild(el("p", "empty", "Select a ticket."));

shell.appendChild(sidebar);
shell.appendChild(list);
shell.appendChild(detail);
app.appendChild(shell);

function renderSidebar(): void {
  counts.replaceChildren();
  for (const entry of filters) {
    const total = tickets.filter(entry.test).length;
    const nav = el("a", entry.id === filter ? "nav on" : "nav");
    nav.appendChild(el("span", "", entry.title));
    nav.appendChild(el("span", "count", String(total)));
    nav.addEventListener("click", () => {
      filter = entry.id;
      selected = null;
      render();
    });
    counts.appendChild(nav);
  }
}

/** Rows built per frame: enough to fill a screen of the list, so the first frame carries the
 *  work of a screen rather than of the whole list, and the rest arrive as frames come. */
const ROWS_PER_FRAME = 4;

/** The rows the current filter shows, and how many of them are built. */
let shownTickets: Ticket[] = [];
let builtRows = 0;
/** Which render's rows a scheduled frame belongs to: a filter change starts a new list, and the
 *  frames queued for the old one must not add to it. */
let rowGeneration = 0;

/** Builds the next frame's rows, then asks for another frame until the list is complete. */
function appendRows(again: boolean): void {
  const generation = rowGeneration;
  const end = Math.min(builtRows + ROWS_PER_FRAME, shownTickets.length);
  for (; builtRows < end; builtRows++) {
    const ticket = shownTickets[builtRows];
    const row = el("a", ticket.key === selected ? "row on" : "row");
    const title = el("div", "row-title");
    title.appendChild(el("span", "tag", ticket.priority));
    title.appendChild(document.createTextNode(ticket.title));
    row.appendChild(title);
    row.appendChild(el("div", "row-meta", `${ticket.key} · ${ticket.author} · ${relative(ticket.updated)}`));
    row.addEventListener("click", () => {
      selected = ticket.key;
      status.textContent = `Showing ${ticket.key}`;
      render();
    });
    rows.appendChild(row);
  }
  if (again && builtRows < shownTickets.length) {
    requestAnimationFrame(() => {
      if (generation === rowGeneration) appendRows(true);
    });
  }
}

function renderRows(): void {
  const shown = tickets.filter(filters.find((entry) => entry.id === filter)!.test);
  listHeader.textContent = `${filters.find((entry) => entry.id === filter)!.title} (${shown.length})`;
  rows.replaceChildren();
  shownTickets = shown;
  builtRows = 0;
  rowGeneration++;
  appendRows(true);
}

function renderDetail(): void {
  const ticket = tickets.find((entry) => entry.key === selected) ?? null;
  detail.replaceChildren();
  if (ticket === null) {
    detail.appendChild(el("p", "empty", "Select a ticket."));
    return;
  }
  const pane = el("div", "ticket");
  pane.appendChild(el("div", "ticket-key", `${ticket.key} · ${ticket.status}`));
  pane.appendChild(el("h1", "", ticket.title));
  const meta = el("div", "meta");
  meta.appendChild(el("span", "pill", ticket.status));
  meta.appendChild(el("span", "", ticket.priority));
  meta.appendChild(el("span", "", "·"));
  meta.appendChild(el("span", "", `${ticket.comments.length} comments`));
  meta.appendChild(el("span", "", "·"));
  meta.appendChild(el("span", "", `updated ${relative(ticket.updated)}`));
  pane.appendChild(meta);
  const labels = el("div", "labels");
  for (const label of ticket.labels) labels.appendChild(el("span", "label", label));
  pane.appendChild(labels);
  const prose = el("div", "prose");
  for (const block of ticket.body) {
    if (block.kind === "p") prose.appendChild(el("p", "", block.text));
    else if (block.kind === "code") prose.appendChild(el("pre", "code", block.text));
    else {
      const ul = el("ul", "");
      for (const line of block.text.split("\n")) ul.appendChild(el("li", "", line));
      prose.appendChild(ul);
    }
  }
  pane.appendChild(prose);
  if (ticket.comments.length > 0) {
    const comments = el("div", "comments");
    for (const comment of ticket.comments) {
      const card = el("div", "comment");
      card.appendChild(el("div", "comment-head", comment.author));
      card.appendChild(el("div", "comment-body", comment.body));
      comments.appendChild(card);
    }
    pane.appendChild(comments);
  }
  detail.appendChild(pane);
}

function render(): void {
  renderSidebar();
  renderRows();
  renderDetail();
}

render();
