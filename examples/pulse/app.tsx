// Pulse, a live dashboard: four metrics that move on a timer, a sparkline for each, one line chart
// over the last minute, an activity feed that fills as events arrive, and a pause control with a
// tick interval. React renders it, Tailwind styles it, and the buttons come from the UI SDK.

import { useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { Button } from "@ui-sdk/react/button";

const HISTORY = 60;

interface Sample {
  revenue: number;
  users: number;
  errors: number;
  latency: number;
}

interface EventLine {
  at: string;
  text: string;
  tone: string;
}

function clamp(value: number, low: number, high: number): number {
  return value < low ? low : value > high ? high : value;
}

function nextValue(current: number, drift: number, spread: number, low: number, high: number): number {
  const step = (Math.random() - 0.5) * spread + drift;
  return clamp(current + step, low, high);
}

function seedHistory(): Sample[] {
  const samples: Sample[] = [];
  let revenue = 1180;
  let users = 815;
  let errors = 0.42;
  let latency = 71;
  for (let i = 0; i < HISTORY; i++) {
    revenue = nextValue(revenue, 3, 90, 600, 1900);
    users = nextValue(users, 1, 32, 400, 1200);
    errors = nextValue(errors, 0, 0.12, 0.05, 1.4);
    latency = nextValue(latency, 0.2, 9, 30, 140);
    samples.push({ revenue: revenue, users: users, errors: errors, latency: latency });
  }
  return samples;
}

function money(value: number): string {
  const whole = Math.round(value);
  let text = String(whole);
  let out = "";
  while (text.length > 3) {
    out = "," + text.slice(text.length - 3) + out;
    text = text.slice(0, text.length - 3);
  }
  return "$" + text + out;
}

function clock(): string {
  const date = new Date();
  const h = date.getHours();
  const m = date.getMinutes();
  const s = date.getSeconds();
  return (h < 10 ? "0" + String(h) : String(h)) + ":" + (m < 10 ? "0" + String(m) : String(m)) + ":" + (s < 10 ? "0" + String(s) : String(s));
}

function sparkline(values: number[], width: number, height: number): string {
  let low = values[0];
  let high = values[0];
  for (const value of values) {
    if (value < low) low = value;
    if (value > high) high = value;
  }
  const span = high - low === 0 ? 1 : high - low;
  let path = "";
  for (let i = 0; i < values.length; i++) {
    const x = (i / (values.length - 1)) * width;
    const y = height - ((values[i] - low) / span) * (height - 4) - 2;
    path += (i === 0 ? "M" : " L") + x.toFixed(1) + " " + y.toFixed(1);
  }
  return path;
}

const EVENTS = [
  "Deploy finished for web",
  "Checkout latency back to normal",
  "New workspace created",
  "Cache warmed in fra1",
  "Edge function redeployed",
  "Payment provider slowed down",
  "Index rebuild completed",
  "Signups crossed 1,000",
];

const ORDERS = [
  { id: "INV-3014", client: "Northwind Supply", total: "$1,240.00", state: "Paid" },
  { id: "INV-3013", client: "Field & Pine", total: "$860.40", state: "Pending" },
  { id: "INV-3012", client: "Kestrel Labs", total: "$2,140.00", state: "Paid" },
  { id: "INV-3011", client: "Harbor Coffee", total: "$320.00", state: "Overdue" },
];

function Trend(props: { values: number[]; tone: string }) {
  const values = props.values.slice(-24);
  return (
    <svg viewBox="0 0 120 36" className="h-9 w-[120px]" preserveAspectRatio="none">
      <path d={sparkline(values, 120, 36)} fill="none" stroke={props.tone} strokeWidth="1.8" strokeLinejoin="round" strokeLinecap="round" />
    </svg>
  );
}

function App() {
  const [history, setHistory] = useState<Sample[]>(seedHistory());
  const [events, setEvents] = useState<EventLine[]>([]);
  // The tick reads and replaces the latest arrays through refs: a setState updater that returns
  // an array of records can't cross scriptc's generic boundary.
  const historyRef = useRef<Sample[]>(history);
  const eventsRef = useRef<EventLine[]>([]);
  const [live, setLive] = useState(true);
  const [interval, setIntervalMs] = useState(1000);
  const [ticks, setTicks] = useState(0);
  const [hover, setHover] = useState(-1);
  const chartRef = useRef<SVGSVGElement>(null);

  function tick(): void {
    const previous = historyRef.current;
    const last = previous[previous.length - 1];
    const sample: Sample = {
      revenue: nextValue(last.revenue, 3, 90, 600, 1900),
      users: nextValue(last.users, 1, 32, 400, 1200),
      errors: nextValue(last.errors, 0, 0.12, 0.05, 1.4),
      latency: nextValue(last.latency, 0.2, 9, 30, 140),
    };
    const nextHistory = previous.slice(1);
    nextHistory.push(sample);
    historyRef.current = nextHistory;
    setHistory(nextHistory);
    setTicks((previousTicks) => previousTicks + 1);
    const text = EVENTS[Math.floor(Math.random() * EVENTS.length)];
    const tone = text.indexOf("slowed") >= 0 ? "bg-amber-400" : text.indexOf("overdue") >= 0 ? "bg-rose-400" : "bg-emerald-400";
    const line: EventLine = { at: clock(), text: text, tone: tone };
    const nextEvents: EventLine[] = [line];
    for (const old of eventsRef.current) nextEvents.push(old);
    const trimmed = nextEvents.slice(0, 7);
    eventsRef.current = trimmed;
    setEvents(trimmed);
  }

  useEffect(() => {
    if (!live) return;
    const handle = window.setInterval(tick, interval);
    return () => window.clearInterval(handle);
  }, [live, interval]);

  const last = history[history.length - 1];
  const revenueSeries = history.map((sample) => sample.revenue);
  const userSeries = history.map((sample) => sample.users);
  const errorSeries = history.map((sample) => sample.errors);
  const latencySeries = history.map((sample) => sample.latency);

  // The chart's own geometry: 720 by 240 inside the card, with a 12px inset.
  const W = 720;
  const H = 240;
  let low = revenueSeries[0];
  let high = revenueSeries[0];
  for (const value of revenueSeries) {
    if (value < low) low = value;
    if (value > high) high = value;
  }
  const pad = Math.max(40, (high - low) * 0.15);
  low -= pad;
  high += pad;
  const span = high - low === 0 ? 1 : high - low;
  let line = "";
  let area = "";
  for (let i = 0; i < revenueSeries.length; i++) {
    const x = 12 + (i / (revenueSeries.length - 1)) * (W - 24);
    const y = H - 16 - ((revenueSeries[i] - low) / span) * (H - 40);
    line += (i === 0 ? "M" : " L") + x.toFixed(1) + " " + y.toFixed(1);
    if (i === 0) area += "M" + x.toFixed(1) + " " + (H - 16);
    area += " L" + x.toFixed(1) + " " + y.toFixed(1);
  }
  area += " L" + (W - 12) + " " + (H - 16) + " Z";

  const hovered = hover >= 0 && hover < history.length ? history[hover] : null;

  function onChartMove(event: any): void {
    const svg = chartRef.current;
    if (svg === null) return;
    const rect = svg.getBoundingClientRect();
    const ratio = (event.clientX - rect.left) / rect.width;
    const index = Math.round(ratio * (history.length - 1));
    setHover(clamp(index, 0, history.length - 1));
  }

  const metrics = [
    { id: "revenue", label: "Revenue / min", value: money(last.revenue), series: revenueSeries, tone: "#34d399", note: "+4.8% vs last hour" },
    { id: "users", label: "Active users", value: String(Math.round(last.users)), series: userSeries, tone: "#818cf8", note: "+2.1% vs last hour" },
    { id: "errors", label: "Error rate", value: last.errors.toFixed(2) + "%", series: errorSeries, tone: "#fb7185", note: "within budget" },
    { id: "latency", label: "p95 latency", value: String(Math.round(last.latency)) + " ms", series: latencySeries, tone: "#fbbf24", note: "edge median 41 ms" },
  ];

  return (
    <div className="flex h-screen flex-col bg-slate-950 font-sans text-slate-100">
      <header className="flex h-16 shrink-0 items-center gap-4 border-b border-white/10 bg-slate-900/60 px-7">
        <div className="grid h-8 w-8 place-items-center rounded-lg bg-gradient-to-br from-emerald-400 to-teal-600 text-[13px] font-bold text-slate-950">P</div>
        <div>
          <h1 className="text-[16px] font-semibold tracking-tight">Pulse</h1>
          <p className="text-[11px] text-slate-400">Production · fra1 · <span id="clock">{clock()}</span></p>
        </div>
        <div className="ml-auto flex items-center gap-3">
          <p id="tick" className="font-mono text-[11px] text-slate-500">tick {ticks}</p>
          <span className={"h-2 w-2 rounded-full " + (live ? "bg-emerald-400" : "bg-slate-600")}></span>
          <p id="live-state" className="text-[12px] text-slate-300">{live ? "Live" : "Paused"}</p>
          <Button id="pause" onClick={() => setLive(!live)} className={"inline-flex h-8 items-center rounded-lg border px-3 text-[12px] font-medium " + (live ? "border-white/10 bg-white/5 text-slate-200 hover:bg-white/10" : "border-emerald-400/40 bg-emerald-400/10 text-emerald-300")}>
            {live ? "Pause" : "Resume"}
          </Button>
          <div className="flex items-center gap-1 rounded-lg border border-white/10 bg-white/5 p-0.5">
            {[1000, 2000, 5000].map((ms) => (
              <button
                key={ms}
                id={"interval-" + String(ms / 1000)}
                type="button"
                onClick={() => setIntervalMs(ms)}
                className={"rounded-md px-2 py-1 text-[11px] font-medium " + (interval === ms ? "bg-white/10 text-white" : "text-slate-400 hover:text-slate-200")}
              >
                {ms / 1000}s
              </button>
            ))}
          </div>
        </div>
      </header>

      <main className="min-h-0 flex-1 overflow-y-auto px-7 py-6">
        <div className="grid grid-cols-4 gap-4">
          {metrics.map((metric) => (
            <section key={metric.id} className="rounded-xl border border-white/10 bg-slate-900/70 p-4">
              <p className="text-[11px] font-medium uppercase tracking-wider text-slate-400">{metric.label}</p>
              <div className="mt-2 flex items-end justify-between gap-2">
                <p id={metric.id} className="font-mono text-[26px] leading-none tracking-tight text-white">{metric.value}</p>
                <Trend values={metric.series} tone={metric.tone} />
              </div>
              <p className="mt-2 text-[11px] text-slate-500">{metric.note}</p>
            </section>
          ))}
        </div>

        <div className="mt-4 grid grid-cols-[minmax(0,1fr)_320px] gap-4">
          <section className="rounded-xl border border-white/10 bg-slate-900/70 p-4">
            <div className="flex items-center gap-3">
              <h2 className="text-[13px] font-semibold text-slate-200">Revenue, last minute</h2>
              <span className="rounded-full bg-emerald-400/10 px-2 py-0.5 text-[10px] font-medium text-emerald-300">live</span>
              <p className="ml-auto text-[11px] text-slate-500">hover the chart for a sample</p>
            </div>
            <div className="relative mt-3">
              <svg id="chart" ref={chartRef} viewBox={"0 0 " + String(W) + " " + String(H)} preserveAspectRatio="none" className="h-[240px] w-full" onMouseMove={onChartMove} onMouseLeave={() => setHover(-1)}>
                <defs>
                  <linearGradient id="revenue-fill" x1="0" y1="0" x2="0" y2="1">
                    <stop offset="0%" stopColor="#34d399" stopOpacity="0.35" />
                    <stop offset="100%" stopColor="#34d399" stopOpacity="0.02" />
                  </linearGradient>
                </defs>
                {[0, 1, 2, 3].map((row) => {
                  const y = 20 + row * 56;
                  return <line key={row} x1="12" x2={String(W - 12)} y1={String(y)} y2={String(y)} stroke="#ffffff" strokeOpacity="0.06" />;
                })}
                <path d={area} fill="url(#revenue-fill)" />
                <path d={line} fill="none" stroke="#34d399" strokeWidth="2.2" strokeLinejoin="round" strokeLinecap="round" />
                {hover >= 0 && (
                  <g>
                    <line x1={String(12 + (hover / (history.length - 1)) * (W - 24))} x2={String(12 + (hover / (history.length - 1)) * (W - 24))} y1="12" y2={String(H - 16)} stroke="#ffffff" strokeOpacity="0.25" />
                    <circle cx={String(12 + (hover / (history.length - 1)) * (W - 24))} cy={String(H - 16 - ((history[hover].revenue - low) / span) * (H - 40))} r="3.5" fill="#34d399" />
                  </g>
                )}
              </svg>
              <div id="tooltip" className={"pointer-events-none absolute rounded-lg border border-white/10 bg-slate-950 px-2.5 py-1.5 text-[11px] text-slate-200 shadow-lg " + (hovered === null ? "hidden" : "")} style={{ left: (hover < 0 ? 10 : (12 + (hover / (history.length - 1)) * (W - 24)) / W * 100).toFixed(1) + "%", top: "12px" }}>
                {hovered === null ? "" : money(hovered.revenue) + " · " + String(Math.round(hovered.users)) + " users · " + hovered.errors.toFixed(2) + "% errors"}
              </div>
            </div>
            <div className="mt-1 flex justify-between font-mono text-[10px] text-slate-600">
              <span>-60s</span><span>-45s</span><span>-30s</span><span>-15s</span><span>now</span>
            </div>
          </section>

          <section className="flex min-h-0 flex-col rounded-xl border border-white/10 bg-slate-900/70 p-4">
            <div className="flex items-center">
              <h2 className="text-[13px] font-semibold text-slate-200">Activity</h2>
              <p id="event-count" className="ml-auto text-[11px] text-slate-500">{events.length} events</p>
            </div>
            <ul id="events" className="mt-3 space-y-2.5">
              {events.map((line, index) => (
                <li key={line.at + "-" + String(index)} className="flex items-start gap-2 text-[11.5px]">
                  <span className={"mt-1 h-1.5 w-1.5 shrink-0 rounded-full " + line.tone}></span>
                  <span className="min-w-0 flex-1 text-slate-300">{line.text}</span>
                  <span className="shrink-0 font-mono text-[10px] text-slate-600">{line.at}</span>
                </li>
              ))}
              {events.length === 0 && <li className="py-6 text-center text-[11px] text-slate-600">Waiting for the first event…</li>}
            </ul>
          </section>
        </div>

        <section className="mt-4 rounded-xl border border-white/10 bg-slate-900/70">
          <div className="flex items-center px-4 py-3">
            <h2 className="text-[13px] font-semibold text-slate-200">Recent orders</h2>
            <p className="ml-auto text-[11px] text-slate-500">last four invoices</p>
          </div>
          <div className="grid grid-cols-[120px_minmax(0,1fr)_120px_100px] gap-4 border-t border-white/5 px-4 py-2 text-[10px] font-semibold uppercase tracking-wider text-slate-500">
            <span>Invoice</span><span>Client</span><span className="text-right">Total</span><span className="text-right">Status</span>
          </div>
          {ORDERS.map((order) => (
            <div key={order.id} className="grid grid-cols-[120px_minmax(0,1fr)_120px_100px] gap-4 border-t border-white/5 px-4 py-2.5 text-[12px]">
              <span className="font-mono text-slate-500">{order.id}</span>
              <span className="text-slate-300">{order.client}</span>
              <span className="text-right font-mono text-slate-300">{order.total}</span>
              <span className={"text-right text-[11px] font-medium " + (order.state === "Paid" ? "text-emerald-400" : order.state === "Overdue" ? "text-rose-400" : "text-amber-400")}>{order.state}</span>
            </div>
          ))}
        </section>
      </main>
    </div>
  );
}

createRoot(document.getElementById("root")!).render(<App />);
