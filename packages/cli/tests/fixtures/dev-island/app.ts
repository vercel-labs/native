// The dev-island fixture's script: a class setter and getter, an instanceof, a
// click that changes the page, a window listener and an interval, all through the compiled DOM
// from the host's island.

const button = document.getElementById("b") as HTMLButtonElement;
const out = document.getElementById("out") as HTMLParagraphElement;

// The element's declared type from getElementById is HTMLElement, so the instance crosses with
// that class key; instanceof answers for the class the value crosses as.
const isParagraph = out instanceof HTMLElement;
button.className = "pressed";
const hasClass = button.className.includes("pressed");

button.addEventListener("click", () => {
  out.textContent = `clicked ${isParagraph} ${hasClass}`;
  console.log(`out ${out.textContent}`);
});

window.addEventListener("resize", () => {
  console.log("resized");
});

let ticks = 0;
setInterval(() => {
  ticks += 1;
  console.log(`tick ${ticks}`);
}, 200);

setTimeout(() => {
  button.click();
}, 300);

console.log("app started");
