interface Todo {
  id: number;
  text: string;
  done: boolean;
}

const input = document.getElementById("new") as HTMLInputElement;
const list = document.getElementById("list")!;
const empty = document.getElementById("empty")!;
const left = document.getElementById("left")!;
const clear = document.getElementById("clear")!;

let todos: Todo[] = [];
let nextId = 1;

function row(todo: Todo): HTMLElement {
  const item = document.createElement("div");
  item.className = todo.done ? "item done" : "item";

  const check = document.createElement("span");
  check.className = "check";

  const label = document.createElement("span");
  label.className = "label";
  label.textContent = todo.text;

  const remove = document.createElement("button");
  remove.className = "remove";
  remove.textContent = "×";
  remove.addEventListener("click", (e) => {
    e.stopPropagation();
    todos = todos.filter((t) => t.id !== todo.id);
    render();
  });

  item.addEventListener("click", () => {
    todo.done = !todo.done;
    render();
  });

  item.append(check, label, remove);
  return item;
}

function render(): void {
  list.replaceChildren(...todos.map(row));
  empty.hidden = todos.length > 0;
  const remaining = todos.filter((t) => !t.done).length;
  left.textContent = `${remaining} item${remaining === 1 ? "" : "s"} left`;
  clear.hidden = !todos.some((t) => t.done);
}

function add(): void {
  const text = input.value.trim();
  if (text === "") return;
  todos.push({ id: nextId++, text, done: false });
  input.value = "";
  render();
  list.lastElementChild?.scrollIntoView();
}

input.addEventListener("keydown", (e: KeyboardEvent) => {
  if (e.key === "Enter") add();
});
document.getElementById("add")!.addEventListener("click", () => {
  add();
  input.focus();
});
clear.addEventListener("click", () => {
  todos = todos.filter((t) => !t.done);
  render();
});

input.focus();
render();
