// Ember, a page of small motions in plain HTML, CSS and TypeScript: a scroll progress bar, an
// IntersectionObserver that reveals sections as they arrive, counters that run once, three
// parallax layers and a card that tilts toward the pointer.

const progress = document.getElementById("progress")!;
const theme = document.getElementById("theme")!;
const stats = document.getElementById("stats")!;
const parallax = document.getElementById("parallax")!;
const layers = parallax.querySelectorAll(".layer");
const tiltCard = document.getElementById("tilt-card")!;

let themeName = "dark";
theme.addEventListener("click", () => {
  themeName = themeName === "dark" ? "light" : "dark";
  if (themeName === "light") document.documentElement.setAttribute("data-theme", "light");
  else document.documentElement.removeAttribute("data-theme");
  theme.textContent = themeName === "dark" ? "Light mode" : "Dark mode";
});

// The progress bar follows the page's scroll.
function updateProgress(): void {
  const max = Math.max(1, document.documentElement.scrollHeight - window.innerHeight);
  const ratio = Math.min(1, Math.max(0, window.scrollY / max));
  progress.style.width = (ratio * 100).toFixed(2) + "%";
}

// Reveal sections once, as they come into view.
const reveals = document.querySelectorAll(".reveal");
const observer = new IntersectionObserver((entries) => {
  for (let i = 0; i < entries.length; i++) {
    const entry = entries[i];
    if (entry.isIntersecting) {
      entry.target.classList.add("in");
      observer.unobserve(entry.target);
    }
  }
}, { threshold: 0.2 });
for (let i = 0; i < reveals.length; i++) observer.observe(reveals[i]);

// Counters: each runs once, from zero to its target, over about a second.
let counted = false;
function runCounters(): void {
  if (counted) return;
  counted = true;
  const targets = [2841, 12, 36];
  const ids = ["count-a", "count-b", "count-c"];
  // The frame's own timestamp drives the count, so the same steps draw the same numbers.
  let started = -1;
  const step = (now: number): void => {
    if (started < 0) started = now;
    const t = Math.min(1, (now - started) / 1100);
    const eased = 1 - (1 - t) * (1 - t);
    for (let i = 0; i < ids.length; i++) {
      const el = document.getElementById(ids[i]);
      if (el !== null) el.textContent = String(Math.round(targets[i] * eased));
    }
    if (t < 1) requestAnimationFrame(step);
  };
  requestAnimationFrame(step);
}

const statsObserver = new IntersectionObserver((entries) => {
  for (let i = 0; i < entries.length; i++) if (entries[i].isIntersecting) runCounters();
}, { threshold: 0.4 });
statsObserver.observe(stats);

// Parallax: each layer moves by a different share of how far the section is through the viewport.
function updateParallax(): void {
  const rect = parallax.getBoundingClientRect();
  const offset = window.innerHeight / 2 - (rect.top + rect.height / 2);
  const shifts = [0.12, 0.24, 0.4];
  for (let i = 0; i < layers.length; i++) {
    const layer = layers[i] as HTMLElement;
    layer.style.transform = "translate3d(0," + (offset * shifts[i]).toFixed(1) + "px,0)";
  }
}

let ticking = false;
function onScroll(): void {
  if (ticking) return;
  ticking = true;
  requestAnimationFrame(() => {
    updateProgress();
    updateParallax();
    ticking = false;
  });
}

updateProgress();
updateParallax();
window.addEventListener("scroll", onScroll);

// The tilt card leans toward the pointer.
tiltCard.addEventListener("pointermove", (event: PointerEvent) => {
  const rect = tiltCard.getBoundingClientRect();
  const x = (event.clientX - rect.left) / rect.width - 0.5;
  const y = (event.clientY - rect.top) / rect.height - 0.5;
  tiltCard.style.transform = "rotateX(" + (-y * 12).toFixed(2) + "deg) rotateY(" + (x * 14).toFixed(2) + "deg)";
});
tiltCard.addEventListener("pointerleave", () => {
  tiltCard.style.transform = "rotateX(0deg) rotateY(0deg)";
});
