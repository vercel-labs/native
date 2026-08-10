// gpu-components: the state tier for the TypeScript + Native markup
// component gallery. The markup owns the complete view; this core only owns
// controlled component state and the messages produced by interaction.

import { Cmd, asciiBytes } from "@native-sdk/core";
import {
  applyTextInputEvent,
  clampedInsertEvent,
  type TextEditState,
  type TextInputEvent,
} from "@native-sdk/core/text";

const MAX_TEXT_BYTES = 160;

export interface ComponentItem {
  readonly id: number;
  readonly label: Uint8Array;
}

const COMPONENTS: readonly ComponentItem[] = [
  { id: 1, label: asciiBytes("Accordion") },
  { id: 2, label: asciiBytes("Alert") },
  { id: 3, label: asciiBytes("Avatar") },
  { id: 4, label: asciiBytes("Badge") },
  { id: 5, label: asciiBytes("Breadcrumb") },
  { id: 6, label: asciiBytes("Bubble") },
  { id: 7, label: asciiBytes("Button") },
  { id: 8, label: asciiBytes("Button Group") },
  { id: 9, label: asciiBytes("Card") },
  { id: 10, label: asciiBytes("Checkbox") },
  { id: 11, label: asciiBytes("Combobox") },
  { id: 12, label: asciiBytes("Dialog") },
  { id: 13, label: asciiBytes("Drawer") },
  { id: 14, label: asciiBytes("Dropdown Menu") },
  { id: 15, label: asciiBytes("Input") },
  { id: 16, label: asciiBytes("Pagination") },
  { id: 17, label: asciiBytes("Progress") },
  { id: 18, label: asciiBytes("Radio Group") },
  { id: 19, label: asciiBytes("Resizable") },
  { id: 20, label: asciiBytes("Select") },
  { id: 21, label: asciiBytes("Separator") },
  { id: 22, label: asciiBytes("Sheet") },
  { id: 23, label: asciiBytes("Skeleton") },
  { id: 24, label: asciiBytes("Slider") },
  { id: 25, label: asciiBytes("Spinner") },
  { id: 26, label: asciiBytes("Switch") },
  { id: 27, label: asciiBytes("Table") },
  { id: 28, label: asciiBytes("Tabs") },
  { id: 29, label: asciiBytes("Textarea") },
  { id: 30, label: asciiBytes("Toggle") },
  { id: 31, label: asciiBytes("Toggle Group") },
  { id: 32, label: asciiBytes("Tooltip") },
  { id: 33, label: asciiBytes("List") },
  { id: 34, label: asciiBytes("Tree") },
];

export interface Draft {
  readonly bytes: Uint8Array;
  readonly anchor: number;
  readonly focus: number;
  readonly compStart: number;
  readonly compEnd: number;
}

function draft(text: string): Draft {
  const bytes = asciiBytes(text);
  const length = bytes.length;
  const cursor = length >= 0 && length <= 9007199254740991 ? Math.trunc(length) : 0;
  return {
    bytes: bytes,
    anchor: cursor,
    focus: cursor,
    compStart: -1,
    compEnd: -1,
  };
}

function draftState(value: Draft): TextEditState {
  return {
    text: value.bytes,
    selection: { anchor: value.anchor, focus: value.focus },
    composition: value.compStart >= 0
      ? { start: value.compStart, end: value.compEnd }
      : null,
  };
}

function draftFromState(value: TextEditState): Draft {
  const start = value.composition !== null ? value.composition.start : -1;
  const end = value.composition !== null ? value.composition.end : -1;
  return {
    bytes: value.text,
    anchor: value.selection.anchor,
    focus: value.selection.focus,
    compStart: start >= -1 && start <= 9007199254740991 ? Math.trunc(start) : -1,
    compEnd: end >= -1 && end <= 9007199254740991 ? Math.trunc(end) : -1,
  };
}

function applyDraft(value: Draft, event: TextInputEvent): Draft {
  const state = draftState(value);
  const next = applyTextInputEvent(state, event, MAX_TEXT_BYTES);
  if (next !== null) return draftFromState(next);
  const clamped = clampedInsertEvent(state, event, MAX_TEXT_BYTES);
  if (clamped === null) return value;
  const nextClamped = applyTextInputEvent(state, clamped, MAX_TEXT_BYTES);
  return nextClamped === null ? value : draftFromState(nextClamped);
}

export type Density = "default" | "comfortable";
export type ThemePack = "house" | "geist";
export type DropdownChoice = "none" | "duplicate" | "rename" | "download" | "delete";
export type SelectChoice = "production" | "staging" | "development";
export type Tab = "account" | "password" | "team";
export type Alignment = "left" | "center" | "right";
export type ListSelection = "report" | "checklist" | "archive";
export type TreeSelection = "src" | "main" | "view" | "assets" | "logo";

export interface Model {
  readonly components: readonly ComponentItem[];
  readonly selectedComponentId: number;
  readonly theme: ThemePack;
  readonly catalogExpanded: boolean;
  readonly accordionOpen: boolean;
  readonly checkboxChecked: boolean;
  readonly usageReportsChecked: boolean;
  readonly comboboxOpen: boolean;
  readonly comboboxDraft: Draft;
  readonly dialogOpen: boolean;
  readonly drawerOpen: boolean;
  readonly onlyUnreadChecked: boolean;
  readonly hasAttachmentsChecked: boolean;
  readonly compactRows: boolean;
  readonly dropdownOpen: boolean;
  readonly dropdownChoice: DropdownChoice;
  readonly inputDraft: Draft;
  readonly page: number;
  readonly density: Density;
  readonly selectOpen: boolean;
  readonly selectChoice: SelectChoice;
  readonly sheetOpen: boolean;
  readonly sliderValue: number;
  readonly notificationsEnabled: boolean;
  readonly airplaneMode: boolean;
  readonly tab: Tab;
  readonly textareaDraft: Draft;
  readonly bold: boolean;
  readonly italic: boolean;
  readonly alignment: Alignment;
  readonly listSelection: ListSelection;
  readonly srcExpanded: boolean;
  readonly assetsExpanded: boolean;
  readonly treeSelection: TreeSelection;
}

export type Msg =
  | { readonly kind: "select_component"; readonly componentId: number }
  | { readonly kind: "theme_house" }
  | { readonly kind: "theme_geist" }
  | { readonly kind: "toggle_catalog" }
  | { readonly kind: "action" }
  | { readonly kind: "toggle_accordion" }
  | { readonly kind: "toggle_checkbox" }
  | { readonly kind: "toggle_usage_reports" }
  | { readonly kind: "combobox_edited"; readonly edit: TextInputEvent }
  | { readonly kind: "open_combobox" }
  | { readonly kind: "close_combobox" }
  | { readonly kind: "choose_native" }
  | { readonly kind: "choose_canvas" }
  | { readonly kind: "open_dialog" }
  | { readonly kind: "close_dialog" }
  | { readonly kind: "open_drawer" }
  | { readonly kind: "close_drawer" }
  | { readonly kind: "toggle_only_unread" }
  | { readonly kind: "toggle_has_attachments" }
  | { readonly kind: "toggle_compact_rows" }
  | { readonly kind: "toggle_dropdown" }
  | { readonly kind: "close_dropdown" }
  | { readonly kind: "dropdown_duplicate" }
  | { readonly kind: "dropdown_rename" }
  | { readonly kind: "dropdown_download" }
  | { readonly kind: "dropdown_delete" }
  | { readonly kind: "input_edited"; readonly edit: TextInputEvent }
  | { readonly kind: "previous_page" }
  | { readonly kind: "next_page" }
  | { readonly kind: "page_one" }
  | { readonly kind: "page_two" }
  | { readonly kind: "page_three" }
  | { readonly kind: "density_default" }
  | { readonly kind: "density_comfortable" }
  | { readonly kind: "toggle_select" }
  | { readonly kind: "close_select" }
  | { readonly kind: "select_production" }
  | { readonly kind: "select_staging" }
  | { readonly kind: "select_development" }
  | { readonly kind: "open_sheet" }
  | { readonly kind: "close_sheet" }
  | { readonly kind: "slider_changed"; readonly fraction: number }
  | { readonly kind: "toggle_notifications" }
  | { readonly kind: "toggle_airplane_mode" }
  | { readonly kind: "tab_account" }
  | { readonly kind: "tab_password" }
  | { readonly kind: "tab_team" }
  | { readonly kind: "textarea_edited"; readonly edit: TextInputEvent }
  | { readonly kind: "toggle_bold" }
  | { readonly kind: "toggle_italic" }
  | { readonly kind: "align_left" }
  | { readonly kind: "align_center" }
  | { readonly kind: "align_right" }
  | { readonly kind: "list_report" }
  | { readonly kind: "list_checklist" }
  | { readonly kind: "list_archive" }
  | { readonly kind: "toggle_src" }
  | { readonly kind: "toggle_assets" }
  | { readonly kind: "tree_src" }
  | { readonly kind: "tree_main" }
  | { readonly kind: "tree_view" }
  | { readonly kind: "tree_assets" }
  | { readonly kind: "tree_logo" };

// These records are intentionally read only through binding helpers.
export const viewUnbound = [
  "theme",
  "comboboxDraft",
  "inputDraft",
  "textareaDraft",
  "selectChoice",
] as const;

export function initialModel(): Model {
  return {
    components: COMPONENTS,
    selectedComponentId: 1,
    theme: "house",
    catalogExpanded: true,
    accordionOpen: true,
    checkboxChecked: true,
    usageReportsChecked: false,
    comboboxOpen: false,
    comboboxDraft: draft(""),
    dialogOpen: false,
    drawerOpen: false,
    onlyUnreadChecked: true,
    hasAttachmentsChecked: false,
    compactRows: true,
    dropdownOpen: false,
    dropdownChoice: "none",
    inputDraft: draft("native-sdk"),
    page: 1,
    density: "default",
    selectOpen: false,
    selectChoice: "production",
    sheetOpen: false,
    sliderValue: 0.64,
    notificationsEnabled: true,
    airplaneMode: false,
    tab: "account",
    textareaDraft: draft("TypeScript state, Native markup view."),
    bold: true,
    italic: false,
    alignment: "left",
    listSelection: "report",
    srcExpanded: true,
    assetsExpanded: false,
    treeSelection: "main",
  };
}

export function comboboxText(model: Model): Uint8Array {
  return model.comboboxDraft.bytes;
}

export function inputText(model: Model): Uint8Array {
  return model.inputDraft.bytes;
}

export function textareaText(model: Model): Uint8Array {
  return model.textareaDraft.bytes;
}

export function selectedLabel(model: Model): Uint8Array {
  for (const component of model.components) {
    if (component.id === model.selectedComponentId) return component.label;
  }
  return asciiBytes("Component");
}

// The default TypeScript launcher recognizes this exported single-model
// helper and selects the built-in pack on every rebuild. System light/dark,
// contrast, reduced-motion, accent, and surface scale remain runtime-owned.
export function themePack(model: Model): ThemePack {
  return model.theme;
}

export function selectLabel(model: Model): Uint8Array {
  switch (model.selectChoice) {
    case "production": return asciiBytes("Production");
    case "staging": return asciiBytes("Staging");
    case "development": return asciiBytes("Development");
  }
}

export function dropdownStatus(model: Model): Uint8Array {
  switch (model.dropdownChoice) {
    case "none": return asciiBytes("Last action: None");
    case "duplicate": return asciiBytes("Last action: Duplicate");
    case "rename": return asciiBytes("Last action: Rename");
    case "download": return asciiBytes("Last action: Download");
    case "delete": return asciiBytes("Last action: Delete");
  }
}

function closeTransientSurfaces(model: Model): Model {
  return {
    ...model,
    comboboxOpen: false,
    dialogOpen: false,
    drawerOpen: false,
    dropdownOpen: false,
    selectOpen: false,
    sheetOpen: false,
  };
}

export function update(model: Model, msg: Msg): [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "select_component": {
      if (!(msg.componentId >= 1 && msg.componentId <= COMPONENTS.length)) {
        return [model, Cmd.none];
      }
      const closed = closeTransientSurfaces(model);
      return [
        { ...closed, selectedComponentId: Math.trunc(msg.componentId) },
        Cmd.none,
      ];
    }
    case "theme_house":
      return [{ ...model, theme: "house" }, Cmd.none];
    case "theme_geist":
      return [{ ...model, theme: "geist" }, Cmd.none];
    case "toggle_catalog":
      return [{ ...model, catalogExpanded: !model.catalogExpanded }, Cmd.none];
    case "action":
      return [model, Cmd.none];
    case "toggle_accordion":
      return [{ ...model, accordionOpen: !model.accordionOpen }, Cmd.none];
    case "toggle_checkbox":
      return [{ ...model, checkboxChecked: !model.checkboxChecked }, Cmd.none];
    case "toggle_usage_reports":
      return [{ ...model, usageReportsChecked: !model.usageReportsChecked }, Cmd.none];
    case "combobox_edited":
      return [{ ...model, comboboxDraft: applyDraft(model.comboboxDraft, msg.edit), comboboxOpen: true }, Cmd.none];
    case "open_combobox":
      return [{ ...model, comboboxOpen: true }, Cmd.none];
    case "close_combobox":
      return [{ ...model, comboboxOpen: false }, Cmd.none];
    case "choose_native":
      return [{ ...model, comboboxDraft: draft("Native SDK"), comboboxOpen: false }, Cmd.none];
    case "choose_canvas":
      return [{ ...model, comboboxDraft: draft("Canvas") , comboboxOpen: false }, Cmd.none];
    case "open_dialog":
      return [{ ...model, dialogOpen: true }, Cmd.none];
    case "close_dialog":
      return [{ ...model, dialogOpen: false }, Cmd.none];
    case "open_drawer":
      return [{ ...model, drawerOpen: true }, Cmd.none];
    case "close_drawer":
      return [{ ...model, drawerOpen: false }, Cmd.none];
    case "toggle_only_unread":
      return [{ ...model, onlyUnreadChecked: !model.onlyUnreadChecked }, Cmd.none];
    case "toggle_has_attachments":
      return [{ ...model, hasAttachmentsChecked: !model.hasAttachmentsChecked }, Cmd.none];
    case "toggle_compact_rows":
      return [{ ...model, compactRows: !model.compactRows }, Cmd.none];
    case "toggle_dropdown":
      return [{ ...model, dropdownOpen: !model.dropdownOpen }, Cmd.none];
    case "close_dropdown":
      return [{ ...model, dropdownOpen: false }, Cmd.none];
    case "dropdown_duplicate":
      return [{ ...model, dropdownChoice: "duplicate", dropdownOpen: false }, Cmd.none];
    case "dropdown_rename":
      return [{ ...model, dropdownChoice: "rename", dropdownOpen: false }, Cmd.none];
    case "dropdown_download":
      return [{ ...model, dropdownChoice: "download", dropdownOpen: false }, Cmd.none];
    case "dropdown_delete":
      return [{ ...model, dropdownChoice: "delete", dropdownOpen: false }, Cmd.none];
    case "input_edited":
      return [{ ...model, inputDraft: applyDraft(model.inputDraft, msg.edit) }, Cmd.none];
    case "previous_page":
      return [{ ...model, page: model.page > 1 ? model.page - 1 : 1 }, Cmd.none];
    case "next_page":
      return [{ ...model, page: model.page < 3 ? model.page + 1 : 3 }, Cmd.none];
    case "page_one":
      return [{ ...model, page: 1 }, Cmd.none];
    case "page_two":
      return [{ ...model, page: 2 }, Cmd.none];
    case "page_three":
      return [{ ...model, page: 3 }, Cmd.none];
    case "density_default":
      return [{ ...model, density: "default" }, Cmd.none];
    case "density_comfortable":
      return [{ ...model, density: "comfortable" }, Cmd.none];
    case "toggle_select":
      return [{ ...model, selectOpen: !model.selectOpen }, Cmd.none];
    case "close_select":
      return [{ ...model, selectOpen: false }, Cmd.none];
    case "select_production":
      return [{ ...model, selectChoice: "production", selectOpen: false }, Cmd.none];
    case "select_staging":
      return [{ ...model, selectChoice: "staging", selectOpen: false }, Cmd.none];
    case "select_development":
      return [{ ...model, selectChoice: "development", selectOpen: false }, Cmd.none];
    case "open_sheet":
      return [{ ...model, sheetOpen: true }, Cmd.none];
    case "close_sheet":
      return [{ ...model, sheetOpen: false }, Cmd.none];
    case "slider_changed":
      if (!(msg.fraction >= 0 && msg.fraction <= 1)) return [model, Cmd.none];
      return [{ ...model, sliderValue: msg.fraction }, Cmd.none];
    case "toggle_notifications":
      return [{ ...model, notificationsEnabled: !model.notificationsEnabled }, Cmd.none];
    case "toggle_airplane_mode":
      return [{ ...model, airplaneMode: !model.airplaneMode }, Cmd.none];
    case "tab_account":
      return [{ ...model, tab: "account" }, Cmd.none];
    case "tab_password":
      return [{ ...model, tab: "password" }, Cmd.none];
    case "tab_team":
      return [{ ...model, tab: "team" }, Cmd.none];
    case "textarea_edited":
      return [{ ...model, textareaDraft: applyDraft(model.textareaDraft, msg.edit) }, Cmd.none];
    case "toggle_bold":
      return [{ ...model, bold: !model.bold }, Cmd.none];
    case "toggle_italic":
      return [{ ...model, italic: !model.italic }, Cmd.none];
    case "align_left":
      return [{ ...model, alignment: "left" }, Cmd.none];
    case "align_center":
      return [{ ...model, alignment: "center" }, Cmd.none];
    case "align_right":
      return [{ ...model, alignment: "right" }, Cmd.none];
    case "list_report":
      return [{ ...model, listSelection: "report" }, Cmd.none];
    case "list_checklist":
      return [{ ...model, listSelection: "checklist" }, Cmd.none];
    case "list_archive":
      return [{ ...model, listSelection: "archive" }, Cmd.none];
    case "toggle_src":
      return [{ ...model, srcExpanded: !model.srcExpanded }, Cmd.none];
    case "toggle_assets":
      return [{ ...model, assetsExpanded: !model.assetsExpanded }, Cmd.none];
    case "tree_src":
      return [{ ...model, treeSelection: "src" }, Cmd.none];
    case "tree_main":
      return [{ ...model, treeSelection: "main" }, Cmd.none];
    case "tree_view":
      return [{ ...model, treeSelection: "view" }, Cmd.none];
    case "tree_assets":
      return [{ ...model, treeSelection: "assets" }, Cmd.none];
    case "tree_logo":
      return [{ ...model, treeSelection: "logo" }, Cmd.none];
  }
}
