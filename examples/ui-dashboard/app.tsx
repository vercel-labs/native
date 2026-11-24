// Northstar, a launch dashboard: a dark sidebar, a row of live stat cards with
// sparklines, a revenue chart drawn as inline SVG, and a projects table with
// search, status pills and a modal that adds a project. React 19 renders it,
// Tailwind 4 styles it, and the buttons and text fields are the page's own controls.

import { useEffect, useRef, useState } from "react";
import type { ReactNode } from "react";
import { createRoot } from "react-dom/client";
import { Button } from "@ui-sdk/react/button";
import {
  IconBell,
  IconChart,
  IconCheck,
  IconDown,
  IconFolder,
  IconGlobe,
  IconHome,
  IconMore,
  IconPlus,
  IconSearch,
  IconSettings,
  IconSpark,
  IconUp,
  IconUsers,
  IconX,
} from "./icons";

type Status = "Live" | "Building" | "Error";

interface Project {
  name: string;
  repo: string;
  status: Status;
  owner: string;
  region: string;
  progress: number;
  updated: string;
}

const INITIAL_PROJECTS: Project[] = [
  { name: "Aurora", repo: "northstar/aurora", status: "Live", owner: "Maya Chen", region: "iad1", progress: 100, updated: "2m ago" },
  { name: "Beacon", repo: "northstar/beacon", status: "Live", owner: "Luis Ortega", region: "sfo1", progress: 100, updated: "18m ago" },
  { name: "Comet", repo: "northstar/comet", status: "Building", owner: "Priya Nair", region: "fra1", progress: 64, updated: "now" },
  { name: "Drift", repo: "northstar/drift", status: "Live", owner: "Sam Okafor", region: "hnd1", progress: 100, updated: "1h ago" },
  { name: "Ember", repo: "northstar/ember", status: "Error", owner: "Ava Lindqvist", region: "sfo1", progress: 38, updated: "3h ago" },
  { name: "Fathom", repo: "northstar/fathom", status: "Building", owner: "Noah Kim", region: "iad1", progress: 82, updated: "now" },
];

const REVENUE = [18, 21, 19, 26, 30, 28, 35, 39, 37, 45, 51, 58];
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

const STATS = [
  { label: "Monthly revenue", value: "$48,120", delta: "+12.4%", down: false, note: "vs. last month", points: [12, 15, 14, 19, 23, 21, 27, 31, 35, 38] },
  { label: "Active users", value: "2,847", delta: "+8.1%", down: false, note: "vs. last month", points: [20, 22, 21, 24, 23, 27, 29, 28, 32, 35] },
  { label: "Deployments", value: "1,204", delta: "+3.2%", down: false, note: "last 30 days", points: [30, 28, 31, 29, 33, 32, 35, 34, 36, 38] },
  { label: "Error rate", value: "0.42%", delta: "-0.18%", down: true, note: "vs. last week", points: [14, 12, 15, 11, 10, 12, 9, 8, 7, 6] },
];

/** Point (x, y) pairs for one sparkline, in a 100×32 box. */
function sparkPoints(values: number[]): string {
  let min = values[0];
  let max = values[0];
  for (const value of values) {
    if (value < min) min = value;
    if (value > max) max = value;
  }
  const span = max - min === 0 ? 1 : max - min;
  let out = "";
  for (let i = 0; i < values.length; i++) {
    const x = (i / (values.length - 1)) * 100;
    const y = 30 - ((values[i] - min) / span) * 26;
    out = out + (i === 0 ? "" : " ") + x.toFixed(1) + "," + y.toFixed(1);
  }
  return out;
}

/** The chart's line and filled area, in a 720×220 box. */
function chartPaths(): { line: string; area: string; tipX: number; tipY: number; labels: { x: number; month: string }[] } {
  const width = 720;
  const height = 180;
  const min = 10;
  const max = 62;
  let line = "";
  const labels: { x: number; month: string }[] = [];
  for (let i = 0; i < REVENUE.length; i++) {
    const x = 10 + (i / (REVENUE.length - 1)) * (width - 20);
    const y = height - ((REVENUE[i] - min) / (max - min)) * (height - 20);
    line = line + (i === 0 ? "M" : " L") + x.toFixed(1) + " " + y.toFixed(1);
    labels.push({ x: x, month: MONTHS[i] });
  }
  const lastX = 10 + (width - 20);
  const lastY = height - ((REVENUE[REVENUE.length - 1] - min) / (max - min)) * (height - 20);
  return { line: line, area: line + " L" + (width - 10) + " " + height + " L10 " + height + " Z", tipX: lastX, tipY: lastY, labels: labels };
}

const CHART = chartPaths();

const AVATAR_COLORS = ["bg-violet-500", "bg-sky-500", "bg-emerald-500", "bg-amber-500", "bg-rose-500", "bg-indigo-500"];

function initials(name: string): string {
  let out = "";
  const parts = name.split(" ");
  for (const part of parts) {
    if (part.length > 0) out = out + part.charAt(0);
  }
  return out.toUpperCase();
}

function avatarColor(name: string): string {
  let sum = 0;
  for (let i = 0; i < name.length; i++) sum = sum + name.charCodeAt(i);
  return AVATAR_COLORS[sum % AVATAR_COLORS.length];
}

function statusClasses(status: Status): string {
  if (status === "Live") return "bg-emerald-50 text-emerald-700 ring-1 ring-emerald-200";
  if (status === "Building") return "bg-amber-50 text-amber-700 ring-1 ring-amber-200";
  return "bg-rose-50 text-rose-700 ring-1 ring-rose-200";
}

function NavItem(props: { icon: ReactNode; label: string; active?: boolean; badge?: string }) {
  return (
    <button type="button" className={(props.active ? "bg-white/10 text-white " : "text-slate-400 hover:bg-white/5 hover:text-slate-200 ") + "flex w-full items-center gap-3 rounded-xl px-3 py-2 text-left text-sm font-medium"}>
      <span className="grid h-5 w-5 place-items-center">{props.icon}</span>
      <span className="flex-1">{props.label}</span>
      {props.badge !== undefined && <span className="rounded-full bg-white/10 px-2 py-0.5 text-[11px] font-semibold text-slate-300">{props.badge}</span>}
    </button>
  );
}

function StatCard(props: { label: string; value: string; delta: string; down: boolean; note: string; points: number[] }) {
  return (
    <div className="rounded-2xl border border-slate-200/80 bg-white p-5 shadow-sm">
      <p className="text-[13px] font-medium text-slate-500">{props.label}</p>
      <div className="mt-2 flex items-end justify-between">
        <p className="text-[26px] font-semibold tracking-tight text-slate-900">{props.value}</p>
        <svg viewBox="0 0 100 32" className="h-8 w-24" preserveAspectRatio="none" aria-hidden="true">
          <polyline points={sparkPoints(props.points)} fill="none" stroke={props.down ? "#f43f5e" : "#6366f1"} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      </div>
      <div className="mt-3 flex items-center gap-1.5 text-xs">
        <span className={(props.down ? "text-rose-600 " : "text-emerald-600 ") + "flex items-center gap-0.5 font-semibold"}>
          {props.down ? <IconDown className="h-3.5 w-3.5" /> : <IconUp className="h-3.5 w-3.5" />}
          {props.delta}
        </span>
        <span className="text-slate-400">{props.note}</span>
      </div>
    </div>
  );
}

/** A text field: a controlled input whose value the page owns. */
function TextInput(props: { id?: string; type?: string; value?: string; defaultValue?: string; placeholder?: string; className?: string; onValueChange?: (value: string) => void }) {
  return (
    <input
      id={props.id}
      type={props.type === undefined ? "text" : props.type}
      value={props.value}
      defaultValue={props.defaultValue}
      placeholder={props.placeholder}
      className={props.className}
      onInput={(event: any) => { if (props.onValueChange !== undefined) props.onValueChange(String(event.target.value)); }}
    />
  );
}

/** A modal dialog: the page's own dialog element, opened with showModal(). */
function Modal(props: { open: boolean; onClose: () => void; children: ReactNode }) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const dialog = ref.current;
    if (dialog === null) return;
    if (props.open && !dialog.open) dialog.showModal();
    if (!props.open && dialog.open) dialog.close();
  }, [props.open]);
  return (
    <dialog ref={ref} onClose={props.onClose} className="m-auto w-[440px] rounded-2xl bg-white p-0 shadow-2xl outline-none backdrop:bg-slate-950/40">
      <div className="flex flex-col gap-5 p-6">{props.children}</div>
    </dialog>
  );
}

function App() {
  const [query, setQuery] = useState("");
  const [projects, setProjects] = useState<Project[]>(INITIAL_PROJECTS);
  const [selected, setSelected] = useState("");
  const [status, setStatus] = useState("All systems operational");
  const [dialogOpen, setDialogOpen] = useState(false);
  const [newName, setNewName] = useState("");
  const [newRegion, setNewRegion] = useState("iad1");

  const needle = query.trim().toLowerCase();
  const visible = projects.filter((project) => project.name.toLowerCase().indexOf(needle) !== -1);

  function createProject() {
    const name = newName.trim();
    if (name.length === 0) {
      setStatus("Give the project a name first");
      return;
    }
    const project: Project = {
      name: name,
      repo: "northstar/" + name.toLowerCase(),
      status: "Building",
      owner: "You",
      region: newRegion,
      progress: 8,
      updated: "now",
    };
    setProjects([project].concat(projects));
    setNewName("");
    setDialogOpen(false);
    setStatus("Created " + name + " in " + newRegion);
  }

  return (
    <div className="flex h-screen bg-slate-50 font-sans text-slate-900">
      <aside className="flex w-60 shrink-0 flex-col bg-slate-950 px-3 py-5">
        <div className="flex items-center gap-2.5 px-2 pb-6">
          <span className="grid h-9 w-9 place-items-center rounded-xl bg-gradient-to-br from-indigo-500 to-violet-600 text-white shadow-lg shadow-indigo-950/40">
            <IconSpark className="h-5 w-5" />
          </span>
          <div>
            <p className="text-sm font-semibold text-white">Northstar</p>
            <p className="text-[11px] text-slate-500">Production</p>
          </div>
        </div>
        <nav className="flex flex-col gap-1">
          <NavItem icon={<IconHome className="h-4.5 w-4.5" />} label="Overview" active />
          <NavItem icon={<IconFolder className="h-4.5 w-4.5" />} label="Projects" badge="6" />
          <NavItem icon={<IconChart className="h-4.5 w-4.5" />} label="Analytics" />
          <NavItem icon={<IconUsers className="h-4.5 w-4.5" />} label="Team" />
          <NavItem icon={<IconBell className="h-4.5 w-4.5" />} label="Activity" badge="3" />
          <NavItem icon={<IconSettings className="h-4.5 w-4.5" />} label="Settings" />
        </nav>
        <div className="mt-auto rounded-2xl bg-white/5 p-3 ring-1 ring-white/10">
          <div className="flex items-center gap-2">
            <span className="grid h-8 w-8 place-items-center rounded-full bg-emerald-500/15 text-emerald-400">
              <IconGlobe className="h-4 w-4" />
            </span>
            <div className="min-w-0">
              <p className="truncate text-xs font-medium text-slate-200">Edge network</p>
              <p className="text-[11px] text-slate-500">18 regions · healthy</p>
            </div>
          </div>
          <div className="mt-3 h-1.5 overflow-hidden rounded-full bg-white/10">
            <div className="h-full w-[86%] rounded-full bg-emerald-400" />
          </div>
        </div>
      </aside>

      <div className="flex min-w-0 flex-1 flex-col">
        <header className="flex h-16 shrink-0 items-center gap-4 border-b border-slate-200 bg-white/80 px-8 backdrop-blur">
          <div className="flex items-center gap-2 text-sm text-slate-400">
            <span>Projects</span>
            <span className="text-slate-300">/</span>
            <span className="font-medium text-slate-700">Overview</span>
          </div>
          <div className="ml-auto flex items-center gap-3">
            <div className="relative">
              <IconSearch className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400" />
              <TextInput
                id="search"
                value={query}
                onValueChange={(value: string) => { setQuery(value); setStatus(value.trim() === "" ? "All systems operational" : "Searching for " + value.trim()); }}
                placeholder="Search projects"
                className="h-9 w-64 rounded-lg border border-slate-200 bg-slate-50 pl-9 pr-3 text-sm outline-none placeholder:text-slate-400 focus:border-indigo-300 focus:bg-white focus:ring-4 focus:ring-indigo-50"
              />
            </div>
            <span className="flex items-center gap-1.5 rounded-full bg-emerald-50 px-2.5 py-1 text-[11px] font-medium text-emerald-700 ring-1 ring-emerald-200">
              <span className="h-1.5 w-1.5 animate-pulse rounded-full bg-emerald-500" />
              Live
            </span>
            <button type="button" className="grid h-9 w-9 place-items-center rounded-lg border border-slate-200 bg-white text-slate-500 hover:text-slate-700">
              <IconBell className="h-4 w-4" />
            </button>
            <span className="grid h-9 w-9 place-items-center rounded-full bg-gradient-to-br from-amber-400 to-rose-500 text-xs font-semibold text-white">CT</span>
          </div>
        </header>

        <main className="min-h-0 flex-1 overflow-y-auto px-8 py-6">
          <div className="flex items-end justify-between">
            <div>
              <h1 className="text-[26px] font-semibold tracking-tight">Good evening, Chris</h1>
              <p className="mt-1 text-sm text-slate-500">Six projects are active across 18 regions. Two deploys are in flight.</p>
            </div>
            <button id="new-project" type="button" onClick={() => setDialogOpen(true)} className="inline-flex h-9 items-center gap-1.5 rounded-lg bg-indigo-600 px-3.5 text-sm font-medium text-white shadow-sm hover:bg-indigo-500">
              <IconPlus className="h-4 w-4" />
              New project
            </button>
          </div>

          <div className="mt-6 grid grid-cols-4 gap-4">
            {STATS.map((stat) => (
              <StatCard key={stat.label} label={stat.label} value={stat.value} delta={stat.delta} down={stat.down} note={stat.note} points={stat.points} />
            ))}
          </div>

          <div className="mt-4 grid grid-cols-3 gap-4">
            <section className="col-span-2 rounded-2xl border border-slate-200/80 bg-white p-5 shadow-sm">
              <div className="flex items-start justify-between">
                <div>
                  <h2 className="text-sm font-semibold text-slate-800">Revenue</h2>
                  <p className="mt-0.5 text-xs text-slate-500">Recurring, all plans · last 12 months</p>
                </div>
                <div className="flex items-center gap-4 text-xs text-slate-500">
                  <span className="flex items-center gap-1.5"><span className="h-2 w-2 rounded-full bg-indigo-500" />2026</span>
                  <span className="flex items-center gap-1.5"><span className="h-2 w-2 rounded-full bg-slate-300" />2025</span>
                  <button type="button" className="grid h-7 w-7 place-items-center rounded-md border border-slate-200 text-slate-400 hover:text-slate-600"><IconMore className="h-4 w-4" /></button>
                </div>
              </div>
              <svg viewBox="0 0 720 220" className="mt-4 h-44 w-full" preserveAspectRatio="none">
                <defs>
                  <linearGradient id="revenue-fill" x1="0" y1="0" x2="0" y2="1">
                    <stop offset="0%" stopColor="#6366f1" stopOpacity="0.28" />
                    <stop offset="100%" stopColor="#6366f1" stopOpacity="0" />
                  </linearGradient>
                </defs>
                <line x1="10" y1="45" x2="710" y2="45" stroke="#e2e8f0" strokeWidth="1" />
                <line x1="10" y1="90" x2="710" y2="90" stroke="#e2e8f0" strokeWidth="1" />
                <line x1="10" y1="135" x2="710" y2="135" stroke="#e2e8f0" strokeWidth="1" />
                <line x1="10" y1="180" x2="710" y2="180" stroke="#e2e8f0" strokeWidth="1" />
                <path d={CHART.area} fill="url(#revenue-fill)" />
                <path d={CHART.line} fill="none" stroke="#6366f1" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" />
                <circle cx={CHART.tipX} cy={CHART.tipY} r="4" fill="#6366f1" stroke="#ffffff" strokeWidth="2" />
                {CHART.labels.map((label) => (
                  <text key={label.month} x={label.x} y="210" textAnchor="middle" fill="#94a3b8" fontSize="11">{label.month}</text>
                ))}
              </svg>
            </section>

            <section className="rounded-2xl border border-slate-200/80 bg-white p-5 shadow-sm">
              <div className="flex items-center justify-between">
                <h2 className="text-sm font-semibold text-slate-800">Recent deploys</h2>
                <span className="rounded-full bg-indigo-50 px-2 py-0.5 text-[11px] font-medium text-indigo-600">live</span>
              </div>
              <ul className="mt-4 flex flex-col gap-3.5">
                <li className="flex items-center gap-3">
                  <span className="grid h-8 w-8 place-items-center rounded-full bg-emerald-50 text-emerald-600"><IconCheck className="h-4 w-4" /></span>
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-[13px] font-medium text-slate-700">Beacon</p>
                    <p className="text-[11px] text-slate-400">main · 18 minutes ago</p>
                  </div>
                  <span className="text-[11px] font-medium text-emerald-600">42s</span>
                </li>
                <li className="flex items-center gap-3">
                  <span className="grid h-8 w-8 place-items-center rounded-full bg-emerald-50 text-emerald-600"><IconCheck className="h-4 w-4" /></span>
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-[13px] font-medium text-slate-700">Drift</p>
                    <p className="text-[11px] text-slate-400">release-8 · 1 hour ago</p>
                  </div>
                  <span className="text-[11px] font-medium text-emerald-600">38s</span>
                </li>
                <li className="flex items-center gap-3">
                  <span className="grid h-8 w-8 place-items-center rounded-full bg-indigo-50 text-indigo-600"><IconSpark className="h-4 w-4" /></span>
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-[13px] font-medium text-slate-700">Comet</p>
                    <p className="text-[11px] text-slate-400">main · building now</p>
                  </div>
                  <span className="text-[11px] font-medium text-amber-600">64%</span>
                </li>
                <li className="flex items-center gap-3">
                  <span className="grid h-8 w-8 place-items-center rounded-full bg-rose-50 text-rose-600"><IconX className="h-4 w-4" /></span>
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-[13px] font-medium text-slate-700">Ember</p>
                    <p className="text-[11px] text-slate-400">failed · 3 hours ago</p>
                  </div>
                  <span className="text-[11px] font-medium text-rose-600">log</span>
                </li>
              </ul>
              <button type="button" className="mt-4 w-full rounded-lg border border-slate-200 py-2 text-xs font-medium text-slate-600 hover:bg-slate-50">View all deployments</button>
            </section>
          </div>

          <section className="mt-4 rounded-2xl border border-slate-200/80 bg-white shadow-sm">
            <div className="flex items-center justify-between px-5 py-4">
              <div>
                <h2 className="text-sm font-semibold text-slate-800">Projects</h2>
                <p className="mt-0.5 text-xs text-slate-500">{visible.length} of {projects.length} shown</p>
              </div>
              <p id="status" className="text-xs text-slate-500">{status}</p>
            </div>
            <table className="w-full border-t border-slate-100 text-left">
              <thead>
                <tr className="text-[11px] uppercase tracking-wide text-slate-400">
                  <th className="px-5 py-2.5 font-medium">Project</th>
                  <th className="px-3 py-2.5 font-medium">Status</th>
                  <th className="px-3 py-2.5 font-medium">Owner</th>
                  <th className="px-3 py-2.5 font-medium">Region</th>
                  <th className="px-3 py-2.5 font-medium">Build</th>
                  <th className="px-5 py-2.5 text-right font-medium">Updated</th>
                </tr>
              </thead>
              <tbody>
                {visible.map((project) => (
                  <tr
                    key={project.name}
                    onClick={() => { setSelected(project.name); setStatus("Selected " + project.name + " · " + project.repo); }}
                    className={(selected === project.name ? "bg-indigo-50/60 " : "hover:bg-slate-50 ") + "cursor-default border-t border-slate-100"}
                  >
                    <td className="px-5 py-3">
                      <div className="flex items-center gap-2.5">
                        <span className="grid h-7 w-7 place-items-center rounded-lg bg-slate-900 text-[11px] font-semibold text-white">{project.name.charAt(0)}</span>
                        <div>
                          <p className="text-[13px] font-medium text-slate-800">{project.name}</p>
                          <p className="text-[11px] text-slate-400">{project.repo}</p>
                        </div>
                      </div>
                    </td>
                    <td className="px-3 py-3">
                      <span className={"inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-[11px] font-medium " + statusClasses(project.status)}>
                        <span className="h-1.5 w-1.5 rounded-full bg-current" />
                        {project.status}
                      </span>
                    </td>
                    <td className="px-3 py-3">
                      <div className="flex items-center gap-2">
                        <span className={"grid h-6 w-6 place-items-center rounded-full text-[10px] font-semibold text-white " + avatarColor(project.owner)}>{initials(project.owner)}</span>
                        <span className="text-xs text-slate-600">{project.owner}</span>
                      </div>
                    </td>
                    <td className="px-3 py-3 text-xs text-slate-500">{project.region}</td>
                    <td className="px-3 py-3">
                      <div className="flex w-28 items-center gap-2">
                        <div className="h-1.5 flex-1 overflow-hidden rounded-full bg-slate-100">
                          <div className="h-full rounded-full bg-indigo-500" style={{ width: project.progress + "%" }} />
                        </div>
                        <span className="text-[11px] text-slate-400">{project.progress}%</span>
                      </div>
                    </td>
                    <td className="px-5 py-3 text-right text-xs text-slate-400">{project.updated}</td>
                  </tr>
                ))}
              </tbody>
            </table>
            {visible.length === 0 && (
              <p className="px-5 py-10 text-center text-sm text-slate-400">No projects match “{query}”.</p>
            )}
          </section>
        </main>
      </div>

      <Modal open={dialogOpen} onClose={() => setDialogOpen(false)}>
        <div>
          <h2 className="text-lg font-semibold tracking-tight">New project</h2>
          <p className="mt-1 text-sm text-slate-500">Deploy a project to the edge in a few seconds.</p>
        </div>
        <div>
          <label className="mb-1.5 block text-[13px] font-medium text-slate-700" htmlFor="project-name">Project name</label>
          <TextInput
            id="project-name"
            value={newName}
            onValueChange={(value: string) => setNewName(value)}
            placeholder="acme-web"
            className="h-9 w-full rounded-lg border border-slate-200 bg-white px-3 text-sm outline-none placeholder:text-slate-400 focus:border-indigo-300 focus:ring-4 focus:ring-indigo-50"
          />
          <p className="mt-1.5 text-xs text-slate-500">Letters, numbers and dashes. You can rename it later.</p>
        </div>
        <div>
          <p className="mb-1.5 text-[13px] font-medium text-slate-700">Region</p>
          <div className="grid grid-cols-3 gap-2">
            {["iad1", "sfo1", "fra1"].map((region) => (
              <button
                key={region}
                type="button"
                onClick={() => setNewRegion(region)}
                className={"rounded-lg border px-3 py-2 text-left text-sm " + (newRegion === region ? "border-indigo-300 bg-indigo-50 text-indigo-700 ring-1 ring-indigo-200" : "border-slate-200 bg-white text-slate-600 hover:border-slate-300")}
              >
                <span className="block font-medium">{region}</span>
                <span className="text-[11px] text-slate-400">{region === "iad1" ? "Washington" : region === "sfo1" ? "San Francisco" : "Frankfurt"}</span>
              </button>
            ))}
          </div>
        </div>
        <div className="flex justify-end gap-2 pt-1">
          <button type="button" onClick={() => setDialogOpen(false)} className="inline-flex h-9 items-center rounded-lg border border-slate-200 bg-white px-3.5 text-sm font-medium text-slate-600 hover:bg-slate-50">Cancel</button>
          <Button id="create-project" onClick={createProject} className="inline-flex h-9 items-center rounded-lg bg-indigo-600 px-3.5 text-sm font-medium text-white shadow-sm hover:bg-indigo-500">Create project</Button>
        </div>
      </Modal>
    </div>
  );
}

createRoot(document.getElementById("root")!).render(<App />);
