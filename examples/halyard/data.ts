// The seed data for Halyard: a small team's issues, with labels, checklists and comments.
// Every run builds the same list, so a screenshot or a scripted run sees the same screen.

type Status = "Todo" | "In progress" | "Done";
type Priority = "Urgent" | "High" | "Normal" | "Low";

interface ChecklistItem {
  text: string;
  done: boolean;
}

interface Comment {
  author: string;
  ago: string;
  body: string;
}

interface Issue {
  id: string;
  key: string;
  title: string;
  status: Status;
  priority: Priority;
  assignee: string;
  labels: string[];
  team: string;
  age: string;
  description: string[];
  checklist: ChecklistItem[];
  comments: Comment[];
}

const SEED: Omit<Issue, "id" | "key">[] = [
  {
    title: "Board columns forget their width after a project switch",
    status: "Todo",
    priority: "High",
    assignee: "Mira Chen",
    labels: ["frontend", "layout"],
    team: "Atlas",
    age: "2h",
    description: [
      "Switching from one project to another leaves the board's columns at their old widths until the window is resized. The column widths are stored per project, but the board keeps the values it read on its first mount.",
      "Reproduce by opening Atlas, switching to Beacon and back. The middle column stays narrow and the right column takes the space instead of keeping a third each.",
    ],
    checklist: [
      { text: "Reproduce on a fresh workspace", done: true },
      { text: "Read widths of the project being shown", done: false },
      { text: "Add a test for switching projects", done: false },
    ],
    comments: [
      { author: "Tomas Reyes", ago: "1h", body: "The board is keyed by project id on purpose, so the fix probably belongs in the width hook rather than in the mount." },
    ],
  },
  {
    title: "Search should ignore punctuation in issue keys",
    status: "In progress",
    priority: "Normal",
    assignee: "Rae Molina",
    labels: ["search"],
    team: "Beacon",
    age: "3h",
    description: [
      "Typing HAL1004 or hal-1004 both find the issue, but hal 1004 finds nothing. The query is compared with the key character for character once the dash is removed only at the start.",
      "Normalize both sides: lowercase, drop dashes and spaces, then compare the numeric part.",
    ],
    checklist: [
      { text: "Fold case and separators in the matcher", done: true },
      { text: "Cover keys with multiple digits", done: false },
    ],
    comments: [],
  },
  {
    title: "Comment box loses the caret when a reply arrives",
    status: "Todo",
    priority: "Urgent",
    assignee: "June Park",
    labels: ["input", "regression"],
    team: "Atlas",
    age: "4h",
    description: [
      "A long thread re-renders when someone else replies, and the comment field is replaced along with it, so the caret jumps to the start and the scroll position resets.",
      "Keep the field's element across renders and update only the thread around it.",
    ],
    checklist: [
      { text: "Keep the composer out of the thread subtree", done: false },
      { text: "Check a reply while typing", done: false },
    ],
    comments: [
      { author: "Ada Okafor", ago: "3h", body: "This also happens when a label is added from the detail pane, so it may be the whole right column re-keying." },
      { author: "June Park", ago: "2h", body: "Confirmed. I can take it after the release branch is cut." },
    ],
  },
  {
    title: "Add a keyboard shortcut for the command palette",
    status: "Done",
    priority: "Normal",
    assignee: "Niall Byrne",
    labels: ["keyboard", "design"],
    team: "Cove",
    age: "5h",
    description: [
      "The palette is only reachable from the search button today. Bind Command-K on macOS and Control-K elsewhere, and show the keys on the button.",
      "The palette should open on the current view and keep the selection it had when it closes.",
    ],
    checklist: [{ text: "Bind the shortcut and document it", done: true }],
    comments: [{ author: "Mira Chen", ago: "4h", body: "Landed. The shortcut is listed in the palette's own help group too." }],
  },
  {
    title: "Drag a row to reorder the backlog",
    status: "Done",
    priority: "High",
    assignee: "Tomas Reyes",
    labels: ["drag", "frontend"],
    team: "Atlas",
    age: "6h",
    description: [
      "Backlog rows should be draggable, with a line showing where the row will land. The order is stored per view so a filter that hides rows doesn't scramble the rest.",
      "A drop on the top half of a row lands before it and the bottom half lands after it.",
    ],
    checklist: [
      { text: "Add a drag handle", done: true },
      { text: "Show a drop line", done: true },
      { text: "Save the order", done: true },
    ],
    comments: [],
  },
  {
    title: "Priority colors are indistinguishable in dark mode",
    status: "Todo",
    priority: "Normal",
    assignee: "Priya Rao",
    labels: ["design", "a11y"],
    team: "Cove",
    age: "7h",
    description: [
      "Urgent and High both read as orange in the dark palette. Give the priority bars the same hues as the status dots and check them against the dark surface with a contrast checker.",
    ],
    checklist: [
      { text: "Pick a hue per priority", done: false },
      { text: "Measure contrast on both surfaces", done: false },
    ],
    comments: [],
  },
  {
    title: "Escape should close the palette and keep the selected issue",
    status: "In progress",
    priority: "Low",
    assignee: "Rae Molina",
    labels: ["keyboard"],
    team: "Cove",
    age: "9h",
    description: [
      "Dismissing the palette with Escape returns focus to the button that opened it, but the issue under the pointer changes on the way out because the dialog's backdrop swallows a click.",
      "Keep the selection and restore focus to the search field when the palette closes without running a command.",
    ],
    checklist: [{ text: "Restore the old selection after Escape", done: true }],
    comments: [],
  },
  {
    title: "Show the number of open issues next to each view",
    status: "Done",
    priority: "Low",
    assignee: "Ada Okafor",
    labels: ["frontend"],
    team: "Beacon",
    age: "11h",
    description: [
      "The sidebar views show a count today only for Inbox. Count the issues a view would show, after its own filters, so the numbers match the list.",
    ],
    checklist: [{ text: "Count per view", done: true }],
    comments: [],
  },
  {
    title: "A filter that hides every issue leaves the pane blank",
    status: "Todo",
    priority: "Normal",
    assignee: "June Park",
    labels: ["empty-state", "design"],
    team: "Beacon",
    age: "13h",
    description: [
      "When a search matches nothing the list shows an empty state, but the detail pane keeps the last issue and its header still says it is selected.",
      "Clear the selection when the list is empty and show a short note with a way back to all issues.",
    ],
    checklist: [
      { text: "Clear the selection on an empty list", done: false },
      { text: "Draw an empty state for the detail pane", done: false },
    ],
    comments: [{ author: "Priya Rao", ago: "12h", body: "The note should name the filters that are on, so it's clear why nothing shows." }],
  },
  {
    title: "Typing in search re-renders every row",
    status: "Todo",
    priority: "High",
    assignee: "Tomas Reyes",
    labels: ["performance", "frontend"],
    team: "Atlas",
    age: "15h",
    description: [
      "Every keystroke in the search field rebuilds the whole list. With 300 issues the frame after a key takes 40ms on the test machine.",
      "Memoize the row and pass only the fields it draws, then measure the same 300 issue list again.",
    ],
    checklist: [
      { text: "Profile a keystroke", done: true },
      { text: "Memoize the row", done: false },
      { text: "Re-measure on the test machine", done: false },
    ],
    comments: [],
  },
  {
    title: "Quote a comment with the selected text",
    status: "Todo",
    priority: "Low",
    assignee: "Niall Byrne",
    labels: ["input"],
    team: "Cove",
    age: "1d",
    description: [
      "Pressing the quote button in a comment's menu should copy the selected lines into the composer as a block quote, with the author's name above them.",
    ],
    checklist: [{ text: "Read the current selection", done: false }],
    comments: [],
  },
  {
    title: "Keep the list scroll position when going back from an issue",
    status: "Done",
    priority: "Normal",
    assignee: "Mira Chen",
    labels: ["navigation"],
    team: "Beacon",
    age: "1d",
    description: [
      "Opening an issue and returning to the list starts at the top. Remember the scroll offset for each view for the session.",
    ],
    checklist: [{ text: "Restore the offset per view", done: true }],
    comments: [],
  },
  {
    title: "Labels with long names overflow the row",
    status: "Todo",
    priority: "Normal",
    assignee: "Priya Rao",
    labels: ["design", "layout"],
    team: "Cove",
    age: "2d",
    description: [
      "A label like needs-a-design-review pushes the avatar out of the row instead of truncating. The row's meta line needs a fixed order and a minimum width for the avatar.",
    ],
    checklist: [
      { text: "Truncate labels with an ellipsis", done: false },
      { text: "Keep the avatar at the end of the row", done: false },
    ],
    comments: [],
  },
  {
    title: "Comment count includes deleted comments",
    status: "In progress",
    priority: "High",
    assignee: "Ada Okafor",
    labels: ["data", "api"],
    team: "Beacon",
    age: "2d",
    description: [
      "The count next to the comment icon counts soft-deleted comments. Filter them out in the query that builds the thread summary.",
    ],
    checklist: [
      { text: "Add the deleted flag to the summary query", done: true },
      { text: "Backfill the count for open issues", done: false },
    ],
    comments: [{ author: "Tomas Reyes", ago: "2d", body: "The read path is fine; the stored count is the one that is stale." }],
  },
  {
    title: "Add a done column to the board",
    status: "Todo",
    priority: "Normal",
    assignee: "June Park",
    labels: ["frontend"],
    team: "Atlas",
    age: "3d",
    description: [
      "Done issues are hidden from the board today. Add a collapsed Done column that can be expanded and keeps its state per project.",
    ],
    checklist: [
      { text: "Make the column collapsible", done: false },
      { text: "Remember the collapsed state", done: false },
    ],
    comments: [],
  },
  {
    title: "Cursor jumps in the description editor",
    status: "Todo",
    priority: "Urgent",
    assignee: "Niall Byrne",
    labels: ["input", "regression"],
    team: "Cove",
    age: "3d",
    description: [
      "Typing quickly in a long description puts the caret one character behind every few words. The editor writes back its value on every input, which moves the selection to the end of the last edit.",
      "Only write back when the value really changed from somewhere else.",
    ],
    checklist: [
      { text: "Guard the write-back by value", done: false },
      { text: "Test with a long description", done: false },
    ],
    comments: [{ author: "Rae Molina", ago: "3d", body: "I can reproduce it on the test machine with a 2,000 word description." }],
  },
  {
    title: "Empty checklist should not draw a heading",
    status: "Done",
    priority: "Low",
    assignee: "Priya Rao",
    labels: ["design"],
    team: "Beacon",
    age: "4d",
    description: [
      "An issue with no checklist shows a 'Steps' heading over nothing. Hide the section until it has an item.",
    ],
    checklist: [{ text: "Hide an empty checklist", done: true }],
    comments: [],
  },
  {
    title: "Filter by assignee from the sidebar avatar",
    status: "Todo",
    priority: "Normal",
    assignee: "Mira Chen",
    labels: ["frontend"],
    team: "Atlas",
    age: "4d",
    description: [
      "Pressing an assignee's avatar in a row should filter the list to that person. A second press removes the filter.",
    ],
    checklist: [{ text: "Add the assignee filter", done: false }],
    comments: [],
  },
  {
    title: "Draft comments are dropped on quit",
    status: "Todo",
    priority: "High",
    assignee: "Tomas Reyes",
    labels: ["data", "input"],
    team: "Beacon",
    age: "5d",
    description: [
      "A comment typed but not sent is gone when the window closes. Keep drafts for the open issue in local storage and restore them when the issue comes back.",
    ],
    checklist: [
      { text: "Save the draft on input", done: false },
      { text: "Restore it when the issue is opened", done: false },
    ],
    comments: [],
  },
  {
    title: "Keyboard focus outline is invisible on the selected row",
    status: "In progress",
    priority: "Normal",
    assignee: "Rae Molina",
    labels: ["a11y", "keyboard"],
    team: "Cove",
    age: "5d",
    description: [
      "Moving with j and k gives the row focus, but the focus ring is drawn under the selected row's background. Draw the ring above the selection and test it with a keyboard only.",
    ],
    checklist: [
      { text: "Draw the ring above the row", done: true },
      { text: "Check with a keyboard only", done: false },
    ],
    comments: [],
  },
  {
    title: "Export a view to CSV",
    status: "Todo",
    priority: "Low",
    assignee: "Ada Okafor",
    labels: ["data"],
    team: "Atlas",
    age: "6d",
    description: [
      "A small menu item that writes the current view, with its columns and filters, to a CSV file beside the app bundle.",
    ],
    checklist: [{ text: "Pick the columns to export", done: false }],
    comments: [],
  },
  {
    title: "Status change from the palette skips the confirmation",
    status: "Todo",
    priority: "Normal",
    assignee: "June Park",
    labels: ["keyboard"],
    team: "Cove",
    age: "6d",
    description: [
      "Closing an issue from the palette closes it immediately. Closing should ask first when the issue has open checklist items.",
    ],
    checklist: [
      { text: "Check for open items before closing", done: false },
      { text: "Add the confirmation", done: false },
    ],
    comments: [],
  },
  {
    title: "List header count is one behind after a filter",
    status: "Done",
    priority: "Normal",
    assignee: "Niall Byrne",
    labels: ["frontend"],
    team: "Beacon",
    age: "1w",
    description: [
      "The header counted the previous list because both states were set in the same pass. Derive the count from the same filtered array the rows use.",
    ],
    checklist: [{ text: "Derive the count from the rows", done: true }],
    comments: [],
  },
  {
    title: "Remember the last selected issue per view",
    status: "Todo",
    priority: "Low",
    assignee: "Priya Rao",
    labels: ["navigation"],
    team: "Atlas",
    age: "1w",
    description: [
      "Coming back to a view should reopen the issue that was selected there, as long as it still matches the view's filters.",
    ],
    checklist: [{ text: "Keep a selection per view", done: false }],
    comments: [],
  },
];

const PROJECT_KEYS: Record<string, string> = { Atlas: "HAL", Beacon: "BEA", Cove: "COV" };

const ISSUES: Issue[] = SEED.map((issue, index) => ({
  ...issue,
  id: String(index + 1),
  key: `${PROJECT_KEYS[issue.team] ?? "HAL"}-${1001 + index}`,
}));

const TEAMS = [
  { name: "Atlas", color: "#0f766e" },
  { name: "Beacon", color: "#7c3aed" },
  { name: "Cove", color: "#c2410c" },
];

const ME = "Rae Molina";

export { ISSUES, ME, TEAMS };
export type { ChecklistItem, Comment, Issue, Priority, Status };
