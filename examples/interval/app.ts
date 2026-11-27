// A focus timer: pick a length, press Space, and the ring drains to a two-note chime.
const STORE = "interval", R = 146, C = 2 * Math.PI * R;
const $ = (id: string): HTMLElement => document.getElementById(id)!;
const arc = $("arc"), timeEl = $("time"), labelEl = $("label"), stateEl = $("state");
const presets = document.querySelectorAll(".preset");

// 60 hairline ticks around the ring, every fifth one longer and brighter.
for (let i = 0; i < 60; i++) {
  const a = (i / 60) * Math.PI * 2, from = i % 5 === 0 ? 124 : 130;
  const line = document.createElementNS("http://www.w3.org/2000/svg", "line");
  line.setAttribute("x1", String(160 + Math.sin(a) * from));
  line.setAttribute("y1", String(160 - Math.cos(a) * from));
  line.setAttribute("x2", String(160 + Math.sin(a) * 138));
  line.setAttribute("y2", String(160 - Math.cos(a) * 138));
  if (i % 5 === 0) line.setAttribute("class", "major");
  $("ticks").appendChild(line);
}

let minutes = 25, remaining = minutes * 60, running = false, last = -1, stamped = -1;
let audio: AudioContext | null = null;

function show(): void {
  const whole = Math.max(0, Math.ceil(remaining));
  const text = String(Math.floor(whole / 60)).padStart(2, "0") + ":" + String(whole % 60).padStart(2, "0");
  const state = running ? "Running" : remaining <= 0 ? "Done" : "Paused";
  const label = running ? "Focus" : state;
  if (timeEl.textContent !== text) timeEl.textContent = text;
  if (stateEl.textContent !== state) stateEl.textContent = state;
  if (labelEl.textContent !== label) labelEl.textContent = label;
  arc.setAttribute("stroke-dashoffset", String(C * (1 - remaining / (minutes * 60))));
}

function mark(): void {
  for (let i = 0; i < presets.length; i++) {
    const button = presets[i] as HTMLButtonElement;
    button.classList.toggle("active", Number(button.getAttribute("data-minutes")) === minutes);
  }
}

function save(): void {
  localStorage.setItem(STORE, JSON.stringify({ minutes, remaining: Math.round(remaining) }));
}

function chime(): void {
  if (audio === null) audio = new AudioContext();
  const ctx = audio, start = ctx.currentTime + 0.02;
  [523.25, 659.25].forEach((hz, i) => {
    const at = start + i * 0.18, osc = ctx.createOscillator(), gain = ctx.createGain();
    osc.type = "sine";
    osc.frequency.value = hz;
    gain.gain.setValueAtTime(0, at);
    gain.gain.linearRampToValueAtTime(0.14, at + 0.02);
    gain.gain.exponentialRampToValueAtTime(0.0001, at + 0.8);
    osc.connect(gain);
    gain.connect(ctx.destination);
    osc.start(at);
    osc.stop(at + 0.82);
  });
}

function frame(now: number): void {
  if (!running) return;
  if (last >= 0) remaining = Math.max(0, remaining - (now - last) / 1000);
  last = now;
  show();
  if (Math.ceil(remaining) !== stamped) { stamped = Math.ceil(remaining); save(); }
  if (remaining > 0) { requestAnimationFrame(frame); return; }
  running = false;
  chime();
  show();
  save();
}

function toggle(): void {
  if (running) { running = false; show(); save(); return; }
  if (remaining <= 0) remaining = minutes * 60;
  if (audio === null) audio = new AudioContext();
  running = true;
  last = -1;
  show();
  requestAnimationFrame(frame);
}

function select(next: number): void {
  minutes = next;
  remaining = minutes * 60;
  running = false;
  mark();
  show();
  save();
  // Space starts the timer; a preset that kept focus would be clicked by it instead.
  const active = document.activeElement as HTMLElement | null;
  if (active !== null) active.blur();
}

for (let i = 0; i < presets.length; i++) {
  const button = presets[i] as HTMLButtonElement;
  button.addEventListener("click", () => select(Number(button.getAttribute("data-minutes"))));
}
$("menu-reset").addEventListener("click", () => select(minutes));
$("menu-25").addEventListener("click", () => select(25));
document.addEventListener("keydown", (event: KeyboardEvent) => {
  if (event.code === "Space") { event.preventDefault(); toggle(); }
});

// Restore the last length and time left; a timer that was running comes back paused.
const saved = localStorage.getItem(STORE);
if (saved !== null) {
  try {
    const value = JSON.parse(saved) as { minutes?: number; remaining?: number };
    if (value.minutes === 5 || value.minutes === 15 || value.minutes === 25) minutes = value.minutes;
    if (typeof value.remaining === "number") remaining = Math.min(Math.max(0, value.remaining), minutes * 60);
  } catch {}
}
mark();
show();
