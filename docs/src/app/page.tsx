import Link from "next/link";
import Image from "next/image";
import { Code } from "@/components/code";

const installCommands = `npm install -g zero-native
zero-native init my_app
cd my_app && zig build run`;

const zmlSample = `<column gap="12" padding="16">
  <row gap="8" cross="center">
    <text-field text="{draft}" placeholder="New task…"
                on-input="draft_edit" on-submit="add" grow="1" />
    <button variant="primary" on-press="add">Add task</button>
  </row>
  <tabs gap="8">
    <for each="filters" as="f">
      <button size="sm" selected="{f == filter}"
              on-press="set_filter:{f}">{f}</button>
    </for>
  </tabs>
  <scroll grow="1">
    <column gap="2">
      <for each="visible" key="id" as="t">
        <row gap="8" padding="6" cross="center">
          <checkbox checked="{t.done}" on-toggle="toggle:{t.id}" />
          <text grow="1">{t.title}</text>
        </row>
      </for>
    </column>
  </scroll>
  <status-bar>{openCount} open · {doneCount} done</status-bar>
</column>`;

const zigSample = `pub const Msg = union(enum) {
    add,
    toggle: u32,
    set_filter: Filter,
    clear_done,
    draft_edit: canvas.TextInputEvent,
};

pub fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        .add => {
            model.addTask(std.mem.trim(u8, model.draft(), " "));
            model.draft_buffer.clear();
        },
        .toggle => |id| if (model.taskById(id)) |task| {
            task.done = !task.done;
        },
        .set_filter => |filter| model.filter = filter,
        .clear_done => model.clearDone(),
        .draft_edit => |edit| model.draft_buffer.apply(edit),
    }
}`;

function CodePane({ title, lang, code }: { title: string; lang: string; code: string }) {
  return (
    <div className="overflow-hidden rounded-lg border border-neutral-200 dark:border-neutral-800">
      <div className="border-b border-neutral-200 bg-neutral-50 px-4 py-2 font-mono text-xs text-neutral-500 dark:border-neutral-800 dark:bg-neutral-900 dark:text-neutral-400">
        {title}
      </div>
      <div className="[&>div]:my-0! [&>div]:rounded-none! [&>div]:border-none!">
        <Code lang={lang}>{code}</Code>
      </div>
    </div>
  );
}

const pillars = [
  {
    title: "Native pixels on every platform",
    body: "One engine renders every widget into real OS windows. On macOS that means Metal presentation with OS scroll momentum, rubber-band overscroll, native context menus, and menu-bar extras. Linux and Windows present through lean software paths with full pointer, keyboard, and IME input. iOS runs in the simulator today; Android cross-compiles clean.",
    href: "/platform-support",
    linkLabel: "Platform support",
  },
  {
    title: "The Elm Architecture, in markup",
    body: "A view is a .zml file: elements, flex layout, {bindings}, and typed message dispatch. Logic is a Model struct, a Msg union, and an update function in plain Zig. Markup compiles at comptime, so view mistakes are compile errors with line and column — and release binaries carry no parser and no JS engine. In dev, edit the .zml while the app runs and the window updates in place, keeping model state.",
    href: "/native-ui",
    linkLabel: "Native UI guide",
  },
  {
    title: "AI agents are first-class authors",
    body: "The repository ships an agent skill that teaches the whole authoring surface, plus an eval harness that hands a clean agent a scaffolded workspace and a task, then grades the result: builds, markup checks, live automation snapshots, and an LLM judge. Any agent can see and drive a running app through the built-in automation server — snapshots, assertions, screenshots, and input.",
    href: "/automation",
    linkLabel: "Automation",
  },
  {
    title: "Typed effects. Real apps.",
    body: "Effects run HTTP fetches (streaming included), process spawns, file I/O, and timers off the loop; results arrive back in update as plain Msgs. And the web still belongs: WebView panes coexist with the canvas in one window, or carry the whole app — system WebView on every desktop, bundled Chromium via CEF on macOS.",
    href: "/web-engines",
    linkLabel: "Web engines",
  },
];

const platforms = [
  {
    name: "macOS",
    status: "Native",
    detail:
      "Metal presentation, OS scroll physics, native context menus, menus, tray, and dialogs. The primary development platform.",
  },
  {
    name: "Linux",
    status: "Software presentation",
    detail:
      "GTK windows driven by the deterministic software renderer, with pointer, keyboard, scroll, IME composition, and HiDPI.",
  },
  {
    name: "Windows",
    status: "Software presentation",
    detail:
      "Win32 host with IME composition. Cross-compiled and exercised in CI under Wine, including real input injection.",
  },
  {
    name: "iOS",
    status: "Simulator-proven",
    detail:
      "Apps compile into an embed library and present via CAMetalLayer. Verified on the iOS Simulator; device support is in progress.",
  },
  {
    name: "Android",
    status: "Compile-proven",
    detail:
      "Cross-compiles with the full embed ABI and a NativeActivity shim. On-device runs are not yet verified.",
  },
  {
    name: "WebViews",
    status: "Coexisting",
    detail:
      "System WebView apps and panes on macOS, Linux, and Windows; bundled Chromium (CEF) on macOS.",
  },
];

export default function HomePage() {
  return (
    <div className="mx-auto max-w-6xl px-6">
      {/* Hero */}
      <section className="pt-16 pb-16 text-center sm:pt-24">
        <h1 className="mx-auto max-w-3xl text-4xl font-semibold tracking-tight text-neutral-900 sm:text-5xl lg:text-6xl dark:text-neutral-100">
          Write markup.
          <br />
          Ship native pixels.
        </h1>
        <p className="mx-auto mt-6 max-w-2xl text-base leading-relaxed text-neutral-600 sm:text-lg dark:text-neutral-400">
          A cross-platform UI framework where the view is declarative markup, style is design
          tokens, and logic is plain Zig on one Elm-style loop — rendered by the framework&apos;s
          own engine into real OS windows. No browser in the binary.
        </p>
        <div className="mx-auto mt-8 max-w-md text-left [&>div]:my-0!">
          <Code lang="bash">{installCommands}</Code>
        </div>
        <div className="mt-8 flex items-center justify-center gap-3">
          <Link
            href="/quick-start"
            className="rounded-md bg-neutral-900 px-4 py-2 text-sm font-medium text-white transition-colors hover:bg-neutral-700 dark:bg-white dark:text-neutral-900 dark:hover:bg-neutral-200"
          >
            Get started
          </Link>
          <a
            href="https://github.com/vercel-labs/zero-native"
            target="_blank"
            rel="noopener noreferrer"
            className="rounded-md border border-neutral-200 px-4 py-2 text-sm font-medium text-neutral-900 transition-colors hover:bg-neutral-100 dark:border-neutral-800 dark:text-neutral-100 dark:hover:bg-neutral-900"
          >
            GitHub
          </a>
        </div>
      </section>

      {/* Code sample */}
      <section className="border-t border-neutral-200 py-16 sm:py-20 dark:border-neutral-800">
        <h2 className="text-center text-2xl font-semibold tracking-tight text-neutral-900 sm:text-3xl dark:text-neutral-100">
          One view. One update. Real pixels.
        </h2>
        <p className="mx-auto mt-4 max-w-2xl text-center text-sm leading-relaxed text-neutral-600 dark:text-neutral-400">
          This is <code className="rounded bg-neutral-100 px-1.5 py-0.5 text-[13px] dark:bg-neutral-800">examples/ui-inbox</code>{" "}
          from the repository: the entire UI is one <code className="rounded bg-neutral-100 px-1.5 py-0.5 text-[13px] dark:bg-neutral-800">.zml</code>{" "}
          file, and the logic is a Model, a Msg union, and an update function. Pointer and keyboard
          events resolve to typed messages; every state change rebuilds the view.
        </p>
        <div className="mt-10 grid gap-6 lg:grid-cols-2">
          <CodePane title="src/inbox.zml · excerpt" lang="html" code={zmlSample} />
          <CodePane title="src/main.zig · excerpt" lang="zig" code={zigSample} />
        </div>
        <figure className="mt-10">
          <div className="mx-auto max-w-3xl overflow-hidden rounded-xl border border-neutral-200 shadow-lg dark:border-neutral-800">
            <Image
              src="/home/ui-inbox-macos.png"
              alt="The ui-inbox example app running in a native macOS window: a task inbox with a text field, filter tabs, a checklist of tasks, and a status bar"
              width={720}
              height={548}
              className="block h-auto w-full"
              priority
            />
          </div>
          <figcaption className="mx-auto mt-3 max-w-3xl text-center text-xs text-neutral-500 dark:text-neutral-500">
            Built from this source and captured running on macOS. The pixels come from the
            framework&apos;s engine; the window and scroll physics come from the OS.
          </figcaption>
        </figure>
      </section>

      {/* Pillars */}
      <section className="border-t border-neutral-200 py-16 sm:py-20 dark:border-neutral-800">
        <div className="grid gap-4 sm:grid-cols-2">
          {pillars.map((pillar) => (
            <div
              key={pillar.title}
              className="flex flex-col rounded-xl border border-neutral-200 p-6 dark:border-neutral-800"
            >
              <h3 className="text-base font-semibold text-neutral-900 dark:text-neutral-100">
                {pillar.title}
              </h3>
              <p className="mt-3 flex-1 text-sm leading-relaxed text-neutral-600 dark:text-neutral-400">
                {pillar.body}
              </p>
              <Link
                href={pillar.href}
                className="mt-4 text-sm font-medium text-neutral-900 hover:underline dark:text-neutral-100"
              >
                {pillar.linkLabel} →
              </Link>
            </div>
          ))}
        </div>
      </section>

      {/* Platforms */}
      <section className="border-t border-neutral-200 py-16 sm:py-20 dark:border-neutral-800">
        <h2 className="text-center text-2xl font-semibold tracking-tight text-neutral-900 sm:text-3xl dark:text-neutral-100">
          Platforms, honestly
        </h2>
        <p className="mx-auto mt-4 max-w-2xl text-center text-sm leading-relaxed text-neutral-600 dark:text-neutral-400">
          These statuses describe what ships and is verified today — not a roadmap.
        </p>
        <div className="mt-10 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {platforms.map((platform) => (
            <div
              key={platform.name}
              className="rounded-xl border border-neutral-200 p-5 dark:border-neutral-800"
            >
              <div className="flex items-baseline justify-between gap-2">
                <h3 className="text-sm font-semibold text-neutral-900 dark:text-neutral-100">
                  {platform.name}
                </h3>
                <span className="text-xs font-medium uppercase tracking-wider text-neutral-400 dark:text-neutral-500">
                  {platform.status}
                </span>
              </div>
              <p className="mt-2 text-sm leading-relaxed text-neutral-600 dark:text-neutral-400">
                {platform.detail}
              </p>
            </div>
          ))}
        </div>
        <p className="mt-8 text-center">
          <Link
            href="/platform-support"
            className="text-sm font-medium text-neutral-900 hover:underline dark:text-neutral-100"
          >
            Full support matrix →
          </Link>
        </p>
      </section>

      {/* Footer CTA */}
      <section className="border-t border-neutral-200 py-16 text-center sm:py-24 dark:border-neutral-800">
        <h2 className="text-2xl font-semibold tracking-tight text-neutral-900 sm:text-3xl dark:text-neutral-100">
          Build something native
        </h2>
        <p className="mx-auto mt-4 max-w-xl text-sm leading-relaxed text-neutral-600 dark:text-neutral-400">
          Scaffold an app, open a real window, and edit the view while it runs.
        </p>
        <div className="mt-8 flex items-center justify-center gap-3">
          <Link
            href="/quick-start"
            className="rounded-md bg-neutral-900 px-4 py-2 text-sm font-medium text-white transition-colors hover:bg-neutral-700 dark:bg-white dark:text-neutral-900 dark:hover:bg-neutral-200"
          >
            Quick Start
          </Link>
          <Link
            href="/native-ui"
            className="rounded-md border border-neutral-200 px-4 py-2 text-sm font-medium text-neutral-900 transition-colors hover:bg-neutral-100 dark:border-neutral-800 dark:text-neutral-100 dark:hover:bg-neutral-900"
          >
            Native UI guide
          </Link>
        </div>
      </section>
    </div>
  );
}
