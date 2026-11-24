const status = document.getElementById("status")!;
let clicks = 0;

function report(what: string): void {
  clicks++;
  status.textContent = `Clicked ${what} (${clicks} total).`;
}

document.getElementById("link")!.addEventListener("click", () => report("the link"));
document.getElementById("inline-btn")!.addEventListener("click", () => report("the inline button"));
