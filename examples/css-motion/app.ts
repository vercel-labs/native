// CSS motion showcase: a kinetic launch page. Every moving part is a CSS
// transition or keyframe animation on transform and opacity; script only
// feeds the pointer parallax, cycles the feature chips and toggles the CTA.

const visual = document.querySelector(".visual") as HTMLElement;
const preorder = document.getElementById("preorder") as HTMLButtonElement;
const chips = [
  document.querySelector(".c1") as HTMLElement,
  document.querySelector(".c2") as HTMLElement,
  document.querySelector(".c3") as HTMLElement,
];

// --- Pointer parallax -------------------------------------------------------

const calm = matchMedia("(prefers-reduced-motion: reduce)");
let targetX = 0;
let targetY = 0;
let atX = 0;
let atY = 0;

window.addEventListener("pointermove", (event: Event) => {
  if (calm.matches) return;
  const pointer = event as PointerEvent;
  targetX = (pointer.clientX / window.innerWidth - 0.5) * 30;
  targetY = (pointer.clientY / window.innerHeight - 0.5) * 20;
});

function frame(): void {
  requestAnimationFrame(frame);
  atX += (targetX - atX) * 0.08;
  atY += (targetY - atY) * 0.08;
  visual.style.transform = "translate(" + atX.toFixed(2) + "px, " + atY.toFixed(2) + "px)";
}

requestAnimationFrame(frame);

// --- Feature chips ----------------------------------------------------------

let next = 1;
function light(index: number): void {
  for (let i = 0; i < chips.length; i++) {
    if (i === index) chips[i].classList.add("on");
    else chips[i].classList.remove("on");
  }
}
light(0);
setInterval(() => {
  light(next);
  next = (next + 1) % chips.length;
}, 2400);

// --- Call to action ---------------------------------------------------------

let armed = false;
preorder.addEventListener("click", () => {
  armed = !armed;
  if (armed) {
    preorder.textContent = "Added to bag";
    preorder.classList.add("armed");
  } else {
    preorder.textContent = "Pre-order";
    preorder.classList.remove("armed");
  }
});
