/**
 * The Components section inventory: one entry per component page,
 * alphabetical. Single source for the sidebar section, the index-page
 * grid, and page titles/OG metadata. `preview` names the engine-rendered
 * tile pair in /public/components — the index grid uses the 16:9 hero
 * tiles (one representative variation per component; regenerate with
 * `zig build docs-component-previews`).
 */
export type ComponentPage = {
  slug: string;
  name: string;
  /** Preview tile stem: /components/<preview>-{light,dark}.webp */
  preview: string;
  /** One-line index-grid caption. */
  blurb: string;
};

export const componentPages: ComponentPage[] = [
  { slug: "accordion", name: "Accordion", preview: "accordion-hero", blurb: "Disclosure surface with a model-owned open state." },
  { slug: "alert", name: "Alert", preview: "alert-hero", blurb: "Inline callouts with icon and variant color." },
  { slug: "avatar", name: "Avatar", preview: "avatar-hero", blurb: "Initials fallback and runtime-registered images." },
  { slug: "badge", name: "Badge", preview: "badge-hero", blurb: "Status labels in every variant." },
  { slug: "breadcrumb", name: "Breadcrumb", preview: "breadcrumb-hero", blurb: "Hierarchy trail with separators." },
  { slug: "bubble", name: "Bubble", preview: "bubble-hero", blurb: "Chat-message surfaces for either side." },
  { slug: "button", name: "Button", preview: "button-hero", blurb: "Variants, sizes, inline icons, and button groups." },
  { slug: "card", name: "Card", preview: "card-hero", blurb: "The bordered, elevated surface container." },
  { slug: "chart", name: "Chart", preview: "chart-hero", blurb: "Line, bar, and band series (Zig builder)." },
  { slug: "checkbox", name: "Checkbox", preview: "checkbox-hero", blurb: "Binary choice with model-owned state." },
  { slug: "combobox", name: "Combobox", preview: "combobox-hero", blurb: "Text entry with an anchored suggestions menu." },
  { slug: "dialog", name: "Dialog", preview: "dialog-hero", blurb: "Modal surface with model-owned dismissal." },
  { slug: "drawer", name: "Drawer", preview: "drawer-hero", blurb: "Side-anchored modal surface." },
  { slug: "dropdown-menu", name: "Dropdown Menu", preview: "dropdown-menu-hero", blurb: "Anchored floating menus and menu items." },
  { slug: "icon", name: "Icon", preview: "icon-hero", blurb: "The built-in vector icon registry." },
  { slug: "input", name: "Input", preview: "input-hero", blurb: "Single-line text entry: input, text field, search field." },
  { slug: "list", name: "List", preview: "list-hero", blurb: "Rows with icons, selection, and virtualization." },
  { slug: "markdown", name: "Markdown", preview: "markdown-hero", blurb: "GFM rendering through native widgets." },
  { slug: "pagination", name: "Pagination", preview: "pagination-hero", blurb: "Page navigation row." },
  { slug: "panel", name: "Panel", preview: "panel-hero", blurb: "The plain surface container." },
  { slug: "progress", name: "Progress", preview: "progress-hero", blurb: "Determinate progress bar." },
  { slug: "radio", name: "Radio", preview: "radio-hero", blurb: "Single choice within a radio group." },
  { slug: "resizable", name: "Resizable", preview: "resizable-hero", blurb: "Panel with an engine-managed drag handle." },
  { slug: "scroll", name: "Scroll", preview: "scroll-hero", blurb: "Scroll regions with model-observable offsets." },
  { slug: "select", name: "Select", preview: "select-hero", blurb: "Trigger plus the anchored dropdown options pattern." },
  { slug: "separator", name: "Separator", preview: "separator-hero", blurb: "Hairline rules, horizontal and vertical." },
  { slug: "sheet", name: "Sheet", preview: "sheet-hero", blurb: "Bottom-anchored modal surface." },
  { slug: "skeleton", name: "Skeleton", preview: "skeleton-hero", blurb: "Loading placeholders that sketch the content." },
  { slug: "slider", name: "Slider", preview: "slider-hero", blurb: "Continuous value control." },
  { slug: "spacer", name: "Spacer", preview: "spacer-hero", blurb: "Flexible empty space between siblings." },
  { slug: "spinner", name: "Spinner", preview: "spinner-hero", blurb: "Indeterminate progress leaf." },
  { slug: "split", name: "Split", preview: "split-hero", blurb: "Draggable two-pane splitter." },
  { slug: "status-bar", name: "Status Bar", preview: "status-bar-hero", blurb: "Window-bottom status text." },
  { slug: "stepper", name: "Stepper", preview: "stepper-hero", blurb: "Stage progress with completed/active/pending steps." },
  { slug: "switch", name: "Switch", preview: "switch-hero", blurb: "On/off switches with model-owned state." },
  { slug: "table", name: "Table", preview: "table-hero", blurb: "Rows and cells with hairline dividers." },
  { slug: "tabs", name: "Tabs", preview: "tabs-hero", blurb: "Tab strip over segmented controls." },
  { slug: "textarea", name: "Textarea", preview: "textarea-hero", blurb: "Multi-line text entry." },
  { slug: "timeline", name: "Timeline", preview: "timeline-hero", blurb: "Ledger list with indicators and connectors." },
  { slug: "toggle", name: "Toggle", preview: "toggle-hero", blurb: "Pressed-state toggles, toggle buttons, and groups." },
  { slug: "tooltip", name: "Tooltip", preview: "tooltip-hero", blurb: "The floating label above the control it annotates." },
  { slug: "tree", name: "Tree", preview: "tree-hero", blurb: "Disclosure tree with one roving focus set." },
  { slug: "virtual-list", name: "Virtual List", preview: "virtual-list-hero", blurb: "Windowed rows: the view builds only what's visible." },
];
