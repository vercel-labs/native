// A field and what an input method does to it: the composing text appears in the field while the
// method builds it, the page hears compositionstart, compositionupdate and compositionend, and the
// committed text takes the preview's place. The line under the field says what arrived last, with
// the value the field has at that moment, so a test can read what the page saw.
//
// Typing without an input method is the same page: the input event says insertText instead of
// insertCompositionText.


const field = document.getElementById("field") as HTMLInputElement;
const log = document.getElementById("log")!;
const arrivals: string[] = [];

/** What arrived, what the field holds now, and the data the event carried, kept in order. The
 *  line the page draws is for a person; the same words go to the program's output so a test can
 *  read what the page saw without a screen reader in the way. */
function note(what: string, data: string): void {
  const line = what + " value=" + field.value + (data === "" ? "" : " data=" + data);
  arrivals.push(line);
  log.textContent = arrivals.join(" | ");
  // The composition's arrivals go to the program's output too, so a test can read what the page
  // saw without a screen reader in the way; typing is left out, since the examples gate prints the
  // page's own line for that.
  if (what === "start" || what === "update" || what === "end") console.log(line);
}

/** The string an event carries, if it carries one. */
function carried(event: any): string {
  return event.data === undefined || event.data === null ? "" : String(event.data);
}

field.addEventListener("compositionstart", (event) => note("start", carried(event)));
field.addEventListener("compositionupdate", (event) => note("update", carried(event)));
field.addEventListener("compositionend", (event) => note("end", carried(event)));
field.addEventListener("input", (event) => {
  // Typing without an input method is declared by an empty inputType in this runtime.
  const kind = event.inputType === undefined || event.inputType === "" ? "input" : event.inputType;
  note(kind, carried(event));
});

field.focus();
