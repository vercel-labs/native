/**
 * The Components section inventory: one entry per component page, in
 * sidebar order. Single source for the sidebar section, the index-page
 * grid, and page titles/OG metadata. `preview` names the engine-rendered
 * tile pair in /public/components (regenerate with
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
  { slug: "button", name: "Button", preview: "button", blurb: "Variants, sizes, inline icons, and button groups." },
  { slug: "toggle", name: "Toggle", preview: "toggle-group", blurb: "Pressed-state toggles, toggle buttons, and groups." },
  { slug: "input", name: "Input", preview: "input", blurb: "Single-line text entry: input, text field, search field." },
  { slug: "textarea", name: "Textarea", preview: "textarea", blurb: "Multi-line text entry." },
  { slug: "select", name: "Select & Combobox", preview: "select", blurb: "Triggers plus the anchored dropdown options pattern." },
  { slug: "checkbox", name: "Checkbox & Radio", preview: "checkbox", blurb: "Binary and single-choice controls." },
  { slug: "switch", name: "Switch", preview: "switch", blurb: "On/off switches with model-owned state." },
  { slug: "slider", name: "Slider", preview: "slider", blurb: "Continuous value control." },
  { slug: "progress", name: "Progress", preview: "progress", blurb: "Determinate progress bar." },
  { slug: "badge", name: "Badge", preview: "badge", blurb: "Status labels in every variant." },
  { slug: "avatar", name: "Avatar", preview: "avatar", blurb: "Initials fallback and runtime-registered images." },
  { slug: "card", name: "Card & Panel", preview: "card", blurb: "Bordered surface containers." },
  { slug: "alert", name: "Alert", preview: "alert", blurb: "Inline callouts with icon and variant color." },
  { slug: "accordion", name: "Accordion", preview: "accordion", blurb: "Disclosure surface with a model-owned open state." },
  { slug: "tabs", name: "Tabs", preview: "tabs", blurb: "Tab strip over segmented controls." },
  { slug: "dropdown-menu", name: "Dropdown Menu", preview: "dropdown-menu", blurb: "Anchored floating menus and menu items." },
  { slug: "tooltip", name: "Tooltip & Bubble", preview: "tooltip", blurb: "Tooltip leaves and chat bubbles." },
  { slug: "breadcrumb", name: "Breadcrumb", preview: "breadcrumb", blurb: "Hierarchy trail with separators." },
  { slug: "pagination", name: "Pagination", preview: "pagination", blurb: "Page navigation row." },
  { slug: "list", name: "List", preview: "list", blurb: "Rows with icons, selection, and virtualization." },
  { slug: "virtual-list", name: "Virtual List", preview: "virtual-list", blurb: "Windowed rows: the view builds only what's visible." },
  { slug: "table", name: "Table", preview: "table", blurb: "Rows and cells with hairline dividers." },
  { slug: "tree", name: "Tree", preview: "tree", blurb: "Disclosure tree with one roving focus set." },
  { slug: "split", name: "Split & Resizable", preview: "split", blurb: "Draggable two-pane splitters and resizable panels." },
  { slug: "scroll", name: "Scroll", preview: "scroll", blurb: "Scroll regions with model-observable offsets." },
  { slug: "dialog", name: "Dialog", preview: "dialog", blurb: "Modal surface with model-owned dismissal." },
  { slug: "drawer", name: "Drawer & Sheet", preview: "drawer", blurb: "Edge-anchored modal surfaces." },
  { slug: "separator", name: "Separator & Spacer", preview: "separator", blurb: "Hairline rules and flexible space." },
  { slug: "skeleton", name: "Skeleton & Spinner", preview: "skeleton", blurb: "Loading placeholders and progress spinners." },
  { slug: "markdown", name: "Markdown", preview: "markdown", blurb: "GFM rendering through native widgets." },
  { slug: "icon", name: "Icon", preview: "icon", blurb: "The built-in vector icon registry." },
  { slug: "chart", name: "Chart", preview: "chart", blurb: "Line, bar, and band series (Zig builder)." },
  { slug: "status-bar", name: "Status Bar", preview: "status-bar", blurb: "Window-bottom status text." },
  { slug: "stepper", name: "Stepper", preview: "stepper", blurb: "Stage progress with completed/active/pending steps." },
  { slug: "timeline", name: "Timeline", preview: "timeline", blurb: "Ledger list with indicators and connectors." },
];
