// Ledger, a data table over three thousand invoices: sortable columns, a text
// search, status filters and a body that only builds the rows on screen. React
// renders it and Tailwind styles it; the search field and the buttons come from
// the UI SDK. The footer reports the cost of the last scroll render.

import { useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { Button } from "@ui-sdk/react/button";
import { Input } from "@ui-sdk/react/input";

interface Invoice {
  id: string;
  client: string;
  initials: string;
  status: string;
  amount: number;
  due: string;
  owner: string;
}

const ROW_H = 44;
const OVERSCAN = 6;
const CLIENTS = ["Northwind Supply", "Acme Studio", "Field & Pine", "Kestrel Labs", "Harbor Coffee", "Bluewater Freight", "Mint & Co", "Orchard Health", "Juniper Works", "Atlas Fabrication"];
const OWNERS = ["Avery", "Priya", "Jordan", "Mina", "Sam", "Theo"];
const STATUSES = ["Paid", "Pending", "Overdue", "Draft"];
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

function makeInvoices(count: number): Invoice[] {
  const rows: Invoice[] = [];
  for (let i = 0; i < count; i++) {
    const client = CLIENTS[i % CLIENTS.length];
    const parts = client.split(" ");
    const initials = (parts[0].slice(0, 1) + (parts.length > 1 ? parts[1].slice(0, 1) : "")).toUpperCase();
    const month = (i * 5) % 12;
    const day = ((i * 11) % 27) + 1;
    const year = 2026 + (i % 2);
    rows.push({
      id: "INV-" + String(1000 + i),
      client: client,
      initials: initials,
      status: STATUSES[i % STATUSES.length],
      amount: ((i * 7919) % 480000) + 12000,
      due: MONTHS[month] + " " + String(day) + ", " + String(year),
      owner: OWNERS[i % OWNERS.length],
    });
  }
  return rows;
}

const ALL = makeInvoices(3000);

function money(cents: number): string {
  const dollars = Math.floor(cents / 100);
  const rest = cents % 100;
  let whole = String(dollars);
  let out = "";
  while (whole.length > 3) {
    out = "," + whole.slice(whole.length - 3) + out;
    whole = whole.slice(0, whole.length - 3);
  }
  return "$" + whole + out + "." + (rest < 10 ? "0" : "") + String(rest);
}

function statusClass(status: string): string {
  if (status === "Paid") return "bg-emerald-50 text-emerald-700 ring-emerald-200";
  if (status === "Pending") return "bg-amber-50 text-amber-700 ring-amber-200";
  if (status === "Overdue") return "bg-rose-50 text-rose-700 ring-rose-200";
  return "bg-slate-100 text-slate-600 ring-slate-200";
}

function compare(a: Invoice, b: Invoice, key: string): number {
  if (key === "amount") return a.amount - b.amount;
  if (key === "invoice") return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
  if (key === "client") return a.client < b.client ? -1 : a.client > b.client ? 1 : 0;
  return a.due < b.due ? -1 : a.due > b.due ? 1 : 0;
}

function App() {
  const [query, setQuery] = useState("");
  const [status, setStatus] = useState("All");
  const [sortKey, setSortKey] = useState("invoice");
  const [sortDir, setSortDir] = useState("asc");
  const [scrollTop, setScrollTop] = useState(0);
  const [viewportH, setViewportH] = useState(520);
  const [selected, setSelected] = useState<string | null>(null);
  const [lastRenderMs, setLastRenderMs] = useState(0);
  const [notice, setNotice] = useState("");
  const listRef = useRef<HTMLDivElement>(null);
  const scrollStarted = useRef(0);

  useEffect(() => {
    const measure = (): void => {
      if (listRef.current !== null) setViewportH(listRef.current.clientHeight);
    };
    // A window listener has to name the event it may receive; a resize sends one.
    const onResize = (event: any): void => { measure(); };
    measure();
    window.addEventListener("resize", onResize);
    return () => window.removeEventListener("resize", onResize);
  }, []);

  useEffect(() => {
    if (scrollStarted.current > 0) {
      setLastRenderMs(performance.now() - scrollStarted.current);
      scrollStarted.current = 0;
    }
  }, [scrollTop]);

  function toggleSort(key: string): void {
    if (key === sortKey) setSortDir(sortDir === "asc" ? "desc" : "asc");
    else {
      setSortKey(key);
      setSortDir("asc");
    }
    if (listRef.current !== null) listRef.current.scrollTop = 0;
    setScrollTop(0);
  }

  let filtered = ALL;
  if (query.trim() !== "") {
    const needle = query.toLowerCase();
    filtered = filtered.filter((row) => row.id.toLowerCase().includes(needle) || row.client.toLowerCase().includes(needle) || row.owner.toLowerCase().includes(needle));
  }
  if (status !== "All") filtered = filtered.filter((row) => row.status === status);

  const sorted = filtered.slice().sort((a, b) => sortDir === "asc" ? compare(a, b, sortKey) : compare(b, a, sortKey));

  const start = Math.max(0, Math.floor(scrollTop / ROW_H) - OVERSCAN);
  const end = Math.min(sorted.length, Math.ceil((scrollTop + viewportH) / ROW_H) + OVERSCAN);
  const windowRows = sorted.slice(start, end);

  function onScroll(event: any): void {
    scrollStarted.current = performance.now();
    setScrollTop(Number(event.target.scrollTop));
  }

  function selectNext(delta: number): void {
    const index = selected === null ? -1 : sorted.findIndex((row) => row.id === selected);
    const next = Math.max(0, Math.min(sorted.length - 1, index + delta));
    setSelected(sorted[next].id);
    const top = next * ROW_H;
    if (listRef.current !== null) {
      const view = listRef.current;
      if (top < view.scrollTop) view.scrollTop = top;
      else if (top + ROW_H > view.scrollTop + viewportH) view.scrollTop = top + ROW_H - viewportH;
      setScrollTop(view.scrollTop);
    }
  }

  function onKeyDown(event: any): void {
    if (event.key === "ArrowDown") {
      event.preventDefault();
      selectNext(1);
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      selectNext(-1);
    }
  }

  function exportCsv(): void {
    const lines = ["Invoice,Client,Status,Amount,Due,Owner"];
    for (const row of sorted) lines.push([row.id, row.client, row.status, money(row.amount), row.due, row.owner].join(","));
    navigator.clipboard.writeText(lines.join("\n")).then(() => {
      setNotice("Copied " + String(sorted.length) + " rows");
    }).catch(() => {
      setNotice("Could not copy the table");
    });
  }

  function header(key: string, label: string, alignRight: boolean): any {
    const active = sortKey === key;
    return (
      <button
        type="button"
        onClick={() => toggleSort(key)}
        className={"flex items-center gap-1 text-[11px] font-semibold uppercase tracking-wider " + (alignRight ? "justify-end " : "") + (active ? "text-slate-800" : "text-slate-500 hover:text-slate-700")}
      >
        {label}
        <span className={active ? "text-indigo-500" : "text-slate-300"}>{active && sortDir === "desc" ? "↓" : "↑"}</span>
      </button>
    );
  }

  const counts = {
    All: ALL.length,
    Paid: ALL.filter((row) => row.status === "Paid").length,
    Pending: ALL.filter((row) => row.status === "Pending").length,
    Overdue: ALL.filter((row) => row.status === "Overdue").length,
  };

  return (
    <div className="flex h-screen flex-col bg-slate-50 font-sans text-slate-900">
      <header className="flex h-16 shrink-0 items-center gap-4 border-b border-slate-200 bg-white px-6">
        <div>
          <h1 className="text-[17px] font-semibold tracking-tight">Invoices</h1>
          <p className="text-[11.5px] text-slate-500">{ALL.length} invoices across {CLIENTS.length} clients</p>
        </div>
        <div className="ml-auto flex items-center gap-3">
          <Input
            id="search"
            value={query}
            onValueChange={(value: string) => setQuery(value)}
            placeholder="Search invoice, client or owner"
            className="h-9 w-72 rounded-lg border border-slate-200 bg-slate-50 px-3 text-[13px] text-slate-700 outline-none placeholder:text-slate-400 focus:border-indigo-300 focus:bg-white focus:ring-4 focus:ring-indigo-50"
          />
          <Button id="export" onClick={exportCsv} className="inline-flex h-9 items-center rounded-lg border border-slate-200 bg-white px-3.5 text-[13px] font-medium text-slate-700 shadow-sm hover:bg-slate-50">
            Export CSV
          </Button>
        </div>
      </header>

      <div className="flex h-12 shrink-0 items-center gap-1 border-b border-slate-200 bg-white px-6">
        {["All", "Paid", "Pending", "Overdue"].map((name) => {
          const active = status === name;
          const count = name === "All" ? counts.All : name === "Paid" ? counts.Paid : name === "Pending" ? counts.Pending : counts.Overdue;
          return (
            <button
              key={name}
              id={"filter-" + name.toLowerCase()}
              type="button"
              onClick={() => { setStatus(name); if (listRef.current !== null) listRef.current.scrollTop = 0; setScrollTop(0); }}
              className={"inline-flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-[13px] font-medium " + (active ? "bg-slate-900 text-white" : "text-slate-600 hover:bg-slate-100")}
            >
              {name}
              <span className={"rounded-full px-1.5 text-[10.5px] " + (active ? "bg-white/15 text-white" : "bg-slate-100 text-slate-500")}>{count}</span>
            </button>
          );
        })}
        <p id="result-count" className="ml-auto text-[11.5px] text-slate-500">{sorted.length} of {ALL.length} rows</p>
        {notice !== "" && <p id="notice" className="text-[11.5px] font-medium text-emerald-600">{notice}</p>}
      </div>

      <div className="flex min-h-0 flex-1 flex-col px-6 py-4">
        <div className="flex min-h-0 flex-1 flex-col overflow-hidden rounded-xl border border-slate-200 bg-white shadow-sm">
          <div className="grid h-10 shrink-0 grid-cols-[116px_minmax(0,1fr)_96px_120px_120px_132px] items-center gap-4 border-b border-slate-200 bg-slate-50 px-5">
            {header("invoice", "Invoice", false)}
            {header("client", "Client", false)}
            <p className="text-[11px] font-semibold uppercase tracking-wider text-slate-500">Status</p>
            {header("amount", "Amount", true)}
            {header("due", "Due", false)}
            <p className="text-[11px] font-semibold uppercase tracking-wider text-slate-500">Owner</p>
          </div>

          <div id="rows" ref={listRef} onScroll={onScroll} onKeyDown={onKeyDown} tabIndex={0} className="min-h-0 flex-1 overflow-y-auto outline-none">
            <div style={{ height: String(sorted.length * ROW_H) + "px", position: "relative" }}>
              {windowRows.map((row, offset) => {
                const index = start + offset;
                const isSelected = row.id === selected;
                return (
                  <div
                    key={row.id}
                    id={"row-" + row.id}
                    style={{ position: "absolute", top: String(index * ROW_H) + "px", left: 0, right: 0, height: String(ROW_H) + "px" }}
                  >
                    <button
                      type="button"
                      onClick={() => setSelected(row.id)}
                      className={"grid h-full w-full grid-cols-[116px_minmax(0,1fr)_96px_120px_120px_132px] items-center gap-4 border-b border-slate-100 px-5 text-left " + (isSelected ? "bg-indigo-50/70" : "hover:bg-slate-50")}
                    >
                      <span className="font-mono text-[12px] text-slate-500">{row.id}</span>
                      <span className="flex min-w-0 items-center gap-2.5">
                        <span className="grid h-6 w-6 shrink-0 place-items-center rounded-full bg-slate-200 text-[9.5px] font-semibold text-slate-600">{row.initials}</span>
                        <span className="truncate text-[13px] font-medium text-slate-800">{row.client}</span>
                      </span>
                      <span className={"inline-flex w-fit items-center rounded-full px-2 py-0.5 text-[11px] font-medium ring-1 " + statusClass(row.status)}>{row.status}</span>
                      <span className="text-right font-mono text-[12.5px] text-slate-700">{money(row.amount)}</span>
                      <span className="text-[12.5px] text-slate-500">{row.due}</span>
                      <span className="text-[12.5px] text-slate-500">{row.owner}</span>
                    </button>
                  </div>
                );
              })}
            </div>
          </div>

          <div className="flex h-9 shrink-0 items-center gap-4 border-t border-slate-200 bg-slate-50 px-5 text-[11px] text-slate-500">
            <p id="showing">Showing rows {sorted.length === 0 ? 0 : start + 1}–{end} of {sorted.length}</p>
            <p id="selected">{selected === null ? "No row selected" : "Selected " + selected}</p>
            <p id="perf" className="ml-auto font-mono">last scroll render {lastRenderMs.toFixed(1)} ms</p>
          </div>
        </div>
        <p className="mt-2 text-[11px] text-slate-400">Rows are built as they scroll into view. Click a header to sort; use ↑ and ↓ to move the selection.</p>
      </div>
    </div>
  );
}

createRoot(document.getElementById("root")!).render(<App />);
