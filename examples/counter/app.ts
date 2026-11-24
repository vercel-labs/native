const countEl = document.getElementById("count")!;
const statusEl = document.getElementById("status")!;
let count = 0;
let clicks = 0;

function render(): void {
  countEl.textContent = String(count);
  countEl.classList.toggle("negative", count < 0);
  countEl.classList.toggle("big", count >= 10);
  statusEl.textContent = clicks === 0 ? "Click a button to start." : `${clicks} click${clicks === 1 ? "" : "s"} so far`;
}

function change(delta: number): void {
  count += delta;
  clicks++;
  render();
}

document.getElementById("inc")!.addEventListener("click", () => change(1));
document.getElementById("dec")!.addEventListener("click", () => change(-1));
document.getElementById("reset")!.addEventListener("click", () => {
  count = 0;
  clicks++;
  render();
});

render();
