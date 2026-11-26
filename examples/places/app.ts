// Places, a bookmark shelf in plain HTML, CSS and TypeScript: the links live
// in IndexedDB, a first run fills it from public/seed.json, and the cards are
// built with the DOM. No framework.

interface Place {
  id?: number;
  title: string;
  url: string;
  tags: string;
  note: string;
  added: number;
}

const list = document.getElementById("list")!;
const empty = document.getElementById("empty")!;
const count = document.getElementById("count")!;
const statusLine = document.getElementById("status")!;
const search = document.getElementById("search") as HTMLInputElement;
const tagBar = document.getElementById("tag-bar")!;
const editor = document.getElementById("editor")!;
const form = document.getElementById("form") as HTMLFormElement;
const fieldTitle = document.getElementById("field-title") as HTMLInputElement;
const fieldUrl = document.getElementById("field-url") as HTMLInputElement;
const fieldTags = document.getElementById("field-tags") as HTMLInputElement;
const fieldNote = document.getElementById("field-note") as HTMLTextAreaElement;
const errorLine = document.getElementById("error")!;
const editorTitle = document.getElementById("editor-title")!;

let database: IDBDatabase | null = null;
let places: Place[] = [];
let query = "";
let tag = "";
let editingId: number | null = null;

function openDb(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open("places", 1);
    request.onupgradeneeded = (): void => {
      request.result.createObjectStore("links", { keyPath: "id", autoIncrement: true });
    };
    request.onsuccess = (): void => resolve(request.result);
    request.onerror = (): void => reject(request.error);
  });
}

function loadAll(): Promise<Place[]> {
  return new Promise((resolve, reject) => {
    const db = database;
    if (db === null) {
      resolve([]);
      return;
    }
    const request = db.transaction("links", "readonly").objectStore("links").getAll();
    request.onsuccess = (): void => resolve(request.result as Place[]);
    request.onerror = (): void => reject(request.error);
  });
}

function putPlace(place: Place): Promise<void> {
  return new Promise((resolve, reject) => {
    const db = database;
    if (db === null) {
      reject(new Error("The database is not open"));
      return;
    }
    const tx = db.transaction("links", "readwrite");
    tx.objectStore("links").put(place);
    tx.oncomplete = (): void => resolve();
    tx.onerror = (): void => reject(tx.error);
  });
}

function removePlace(id: number): Promise<void> {
  return new Promise((resolve, reject) => {
    const db = database;
    if (db === null) {
      reject(new Error("The database is not open"));
      return;
    }
    const tx = db.transaction("links", "readwrite");
    tx.objectStore("links").delete(id);
    tx.oncomplete = (): void => resolve();
    tx.onerror = (): void => reject(tx.error);
  });
}

function tagList(tags: string): string[] {
  return tags.split(",").map((item) => item.trim()).filter((item) => item !== "");
}

function domainOf(url: string): string {
  let host = url.replace(/^https?:\/\//, "");
  const slash = host.indexOf("/");
  if (slash >= 0) host = host.slice(0, slash);
  return host;
}

function setStatus(text: string): void {
  statusLine.textContent = text;
}

function makeButton(className: string): HTMLButtonElement {
  const button = document.createElement("button") as HTMLButtonElement;
  button.type = "button";
  button.className = className;
  return button;
}

function makeCard(place: Place): HTMLElement {
  const card = document.createElement("article");
  card.className = "card";

  const top = document.createElement("div");
  top.className = "card-top";

  const heading = document.createElement("div");
  const title = document.createElement("h3");
  // scriptc 0.4.16 still types createElement as HTMLElement; the runtime builds an anchor here.
  const link = document.createElement("a") as HTMLAnchorElement;
  link.href = place.url;
  link.textContent = place.title;
  title.appendChild(link);
  const domain = document.createElement("p");
  domain.className = "domain";
  domain.textContent = domainOf(place.url);
  heading.appendChild(title);
  heading.appendChild(domain);

  const actions = document.createElement("div");
  actions.className = "card-actions";
  const edit = makeButton("icon-button");
  edit.textContent = "Edit";
  edit.addEventListener("click", () => openEditor(place));
  const del = makeButton("icon-button danger");
  del.textContent = "Delete";
  del.addEventListener("click", () => {
    if (del.getAttribute("data-armed") === "1") {
      deletePlace(place, del);
      return;
    }
    del.setAttribute("data-armed", "1");
    del.textContent = "Delete?";
    setTimeout(() => {
      del.setAttribute("data-armed", "0");
      del.textContent = "Delete";
    }, 2500);
  });
  actions.appendChild(edit);
  actions.appendChild(del);

  top.appendChild(heading);
  top.appendChild(actions);
  card.appendChild(top);

  if (place.note !== "") {
    const note = document.createElement("p");
    note.className = "card-note";
    note.textContent = place.note;
    card.appendChild(note);
  }

  const foot = document.createElement("div");
  foot.className = "card-foot";
  for (const name of tagList(place.tags)) {
    const chip = document.createElement("span");
    chip.className = "chip";
    chip.textContent = name;
    foot.appendChild(chip);
  }
  card.appendChild(foot);
  return card;
}

function renderTags(): void {
  const counts = new Map<string, number>();
  for (const place of places) {
    for (const name of tagList(place.tags)) counts.set(name, (counts.get(name) ?? 0) + 1);
  }
  tagBar.textContent = "";
  const all = makeButton("tag");
  all.textContent = "All";
  all.setAttribute("aria-pressed", tag === "" ? "true" : "false");
  all.addEventListener("click", () => {
    tag = "";
    render();
  });
  tagBar.appendChild(all);
  const names: string[] = [];
  for (const name of counts.keys()) names.push(name);
  names.sort();
  for (const name of names) {
    const chip = makeButton("tag");
    chip.textContent = name + " · " + String(counts.get(name));
    chip.setAttribute("aria-pressed", tag === name ? "true" : "false");
    chip.addEventListener("click", () => {
      tag = tag === name ? "" : name;
      render();
    });
    tagBar.appendChild(chip);
  }
}

function render(): void {
  const needle = query.trim().toLowerCase();
  const visible = places.filter((place) => {
    const text = place.title.toLowerCase() + " " + place.url.toLowerCase() + " " + place.note.toLowerCase();
    const matchesText = needle === "" || text.includes(needle);
    const matchesTag = tag === "" || tagList(place.tags).includes(tag);
    return matchesText && matchesTag;
  });
  list.textContent = "";
  for (const place of visible) list.appendChild(makeCard(place));
  empty.hidden = visible.length > 0;
  count.textContent = String(visible.length) + (visible.length === 1 ? " place" : " places") + (places.length === visible.length ? "" : " of " + String(places.length));
  renderTags();
}

function openEditor(place: Place | null): void {
  editingId = place === null ? null : place.id ?? null;
  editorTitle.textContent = place === null ? "Add a place" : "Edit this place";
  fieldTitle.value = place === null ? "" : place.title;
  fieldUrl.value = place === null ? "" : place.url;
  fieldTags.value = place === null ? "" : place.tags;
  fieldNote.value = place === null ? "" : place.note;
  errorLine.hidden = true;
  editor.hidden = false;
  fieldTitle.focus();
}

function closeEditor(): void {
  editor.hidden = true;
  editingId = null;
}

async function deletePlace(place: Place, button: HTMLElement): Promise<void> {
  if (place.id === undefined) return;
  button.textContent = "Delete";
  try {
    await removePlace(place.id);
    places = await loadAll();
    render();
    setStatus("Deleted “" + place.title + "”");
  } catch (error) {
    console.error(error);
    setStatus("Could not delete that place");
  }
}

async function save(): Promise<void> {
  const title = fieldTitle.value.trim();
  const url = fieldUrl.value.trim();
  const tags = fieldTags.value.trim();
  const note = fieldNote.value.trim();
  if (title === "") {
    errorLine.textContent = "A title helps you find it later.";
    errorLine.hidden = false;
    fieldTitle.focus();
    return;
  }
  if (!/^https?:\/\/[^\s]+\.[^\s]+$/i.test(url)) {
    errorLine.textContent = "That address does not look like a web link. Try https://example.com.";
    errorLine.hidden = false;
    fieldUrl.focus();
    return;
  }
  const wasEditing = editingId !== null;
  const place: Place = editingId === null
    ? { title: title, url: url, tags: tags, note: note, added: Date.now() }
    : { id: editingId, title: title, url: url, tags: tags, note: note, added: Date.now() };
  try {
    await putPlace(place);
    places = await loadAll();
    places.sort((a, b) => b.added - a.added);
    render();
    closeEditor();
    setStatus(wasEditing ? "Saved changes" : "Added “" + title + "”");
  } catch (error) {
    console.error(error);
    errorLine.textContent = "Could not save that place.";
    errorLine.hidden = false;
  }
}

form.addEventListener("submit", (event: Event) => {
  event.preventDefault();
  save().catch((error: any) => console.error(error));
});

(search as HTMLInputElement).addEventListener("input", () => {
  query = search.value;
  render();
});

document.getElementById("add")!.addEventListener("click", () => openEditor(null));
document.getElementById("cancel")!.addEventListener("click", closeEditor);
document.addEventListener("keydown", (event: KeyboardEvent) => {
  if ((event.metaKey || event.ctrlKey) && (event.key === "f" || event.key === "F")) {
    event.preventDefault();
    search.focus();
    search.select();
  } else if (event.key === "Escape" && !editor.hidden) {
    closeEditor();
  }
});

async function boot(): Promise<void> {
  database = await openDb();
  let existing = await loadAll();
  if (existing.length === 0) {
    const response = await fetch("seed.json");
    const seed = await response.json() as Place[];
    const db = database;
    if (seed.length > 0 && db !== null) {
      await new Promise<void>((resolve, reject) => {
        const tx = db.transaction("links", "readwrite");
        const store = tx.objectStore("links");
        for (const place of seed) store.add(place);
        tx.oncomplete = (): void => resolve();
        tx.onerror = (): void => reject(tx.error);
      });
      existing = await loadAll();
      setStatus("Filled the shelf from a starter set of links");
    }
  }
  places = existing;
  places.sort((a, b) => b.added - a.added);
  render();
}

boot().catch((error: any) => {
  console.error(error);
  setStatus("Could not open the library: " + String(error));
});
