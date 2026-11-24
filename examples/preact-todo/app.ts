// A todo list written with Preact and hooks, compiled to a native app by native.
// No JSX: h() calls only, so the file is plain TypeScript. The headless steps in
// tests/preact.ts drive it the way a person would.
//
// The elements are built at runtime by Preact, so they can't be styled from the page's
// stylesheet (native compiles selectors against the markup it sees at build time). Their
// styles are set as properties here instead, which is what a renderer does anyway.

import { h, render } from "preact";
import { useEffect, useRef, useState } from "preact/hooks";

interface Todo {
  id: number;
  text: string;
  done: boolean;
}

let nextId = 1;

const inputStyle = {
  flex: "1",
  marginRight: "8px",
  padding: "8px",
  fontSize: "15px",
  border: "1px solid rgb(200, 205, 212)",
  borderRadius: "6px",
};
const buttonStyle = {
  padding: "8px 14px",
  fontSize: "15px",
  color: "rgb(255, 255, 255)",
  background: "rgb(45, 110, 230)",
  border: "0",
  borderRadius: "6px",
};
const buttonDisabledStyle = {
  padding: "8px 14px",
  fontSize: "15px",
  color: "rgb(255, 255, 255)",
  background: "rgb(165, 185, 220)",
  border: "0",
  borderRadius: "6px",
};
const rowsStyle = { margin: "16px 0", padding: "0", listStyle: "none" };
const rowStyle = {
  display: "flex",
  alignItems: "center",
  gap: "8px",
  padding: "8px 0",
  borderBottom: "1px solid rgb(230, 232, 236)",
};
const labelStyle: Record<string, string> = { flex: "1" };
const labelDoneStyle: Record<string, string> = { flex: "1", color: "rgb(150, 155, 162)", textDecoration: "line-through" };
const delStyle = {
  width: "22px",
  height: "22px",
  padding: "0",
  fontSize: "13px",
  lineHeight: "22px",
  color: "rgb(255, 255, 255)",
  background: "rgb(225, 90, 80)",
  border: "0",
  borderRadius: "4px",
};
const countStyle = { margin: "0", fontSize: "13px", color: "rgb(100, 106, 114)" };

function App() {
  // Preact's declarations type the hooks' state through the type argument.
  const [todos, setTodos] = useState<Todo[]>([]);
  const [draft, setDraft] = useState("");
  // The field is ready as soon as the app is on screen, so there is nothing to click first.
  const inputRef = useRef<HTMLInputElement>(null);
  useEffect(() => {
    const input = inputRef.current;
    if (input !== null) input.focus();
  }, []);

  const add = (): void => {
    const text = draft.trim();
    if (text === "") return;
    setTodos(todos.concat([{ id: nextId++, text, done: false }]));
    setDraft("");
  };

  const toggle = (id: number): void => {
    setTodos(todos.map((t: Todo) => (t.id === id ? { id: t.id, text: t.text, done: !t.done } : t)));
  };

  const remove = (id: number): void => {
    setTodos(todos.filter((t: Todo) => t.id !== id));
  };

  const left = todos.filter((t: Todo) => !t.done).length;

  return h("div", { id: "app", style: { padding: "16px" } },
    h("h1", { style: { margin: "0 0 12px", fontSize: "22px" } }, "Todos"),
    h("div", { style: { display: "flex" } },
      h("input", {
        id: "new",
        ref: inputRef,
        value: draft,
        placeholder: "What needs doing?",
        style: inputStyle,
        onInput: (e: Event) => { setDraft((e.target as HTMLInputElement).value); },
        onKeyDown: (e: KeyboardEvent) => { if (e.key === "Enter") add(); },
      }),
      h("button", { id: "add", onClick: add, disabled: draft.trim() === "", style: draft.trim() === "" ? buttonDisabledStyle : buttonStyle }, "Add"),
    ),
    h("ul", { id: "list", style: rowsStyle },
      todos.map((t: Todo) =>
        h("li", { key: t.id, id: "todo-" + t.id, style: rowStyle },
          h("span", { id: "label-" + t.id, class: "label", style: t.done ? labelDoneStyle : labelStyle, onClick: () => { toggle(t.id); } }, t.text),
          h("button", { id: "del-" + t.id, class: "del", style: delStyle, onClick: () => { remove(t.id); } }, "x"),
        ),
      ),
    ),
    h("p", { id: "count", style: countStyle }, todos.length === 0 ? "No todos" : left + " left of " + todos.length),
  );
}

render(h(App, null), document.getElementById("root")!);
