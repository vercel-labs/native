import Link from "next/link";
import Image from "next/image";
import { Code } from "@/components/code";
import { Showcase } from "@/components/home/showcase";
import { CopyCommand } from "@/components/home/copy-command";
import { githubUrl, npmCli, siteName } from "@/lib/site";

// ---------------------------------------------------------------- samples
// Both excerpts are real source from examples/ui-inbox in this repository.

const installCommands = [`npm install -g ${npmCli}`, "native init my_app", "cd my_app && zig build run"];

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

// ------------------------------------------------------------ small parts

function SectionLabel({ children }: { children: React.ReactNode }) {
  return (
    <p className="text-center font-mono text-xs font-medium uppercase tracking-[0.2em] text-neutral-400 dark:text-neutral-500">
      {children}
    </p>
  );
}

function SectionTitle({ children }: { children: React.ReactNode }) {
  return (
    <h2 className="mt-3 text-center text-3xl font-semibold tracking-tight text-neutral-900 sm:text-4xl dark:text-neutral-100">
      {children}
    </h2>
  );
}

function SectionLede({ children }: { children: React.ReactNode }) {
  return (
    <p className="mx-auto mt-4 max-w-2xl text-center text-base leading-relaxed text-neutral-600 dark:text-neutral-400">
      {children}
    </p>
  );
}

function CodePane({ title, lang, code }: { title: string; lang: string; code: string }) {
  return (
    <div className="overflow-hidden rounded-xl border border-neutral-200 bg-white shadow-sm dark:border-neutral-800 dark:bg-neutral-950">
      <div className="flex items-center gap-1.5 border-b border-neutral-200 bg-neutral-50 px-4 py-2.5 dark:border-neutral-800 dark:bg-neutral-900">
        <span className="h-2.5 w-2.5 rounded-full bg-neutral-300 dark:bg-neutral-700" />
        <span className="h-2.5 w-2.5 rounded-full bg-neutral-300 dark:bg-neutral-700" />
        <span className="h-2.5 w-2.5 rounded-full bg-neutral-300 dark:bg-neutral-700" />
        <span className="ml-3 font-mono text-xs text-neutral-500 dark:text-neutral-400">{title}</span>
      </div>
      <div className="[&>div]:my-0! [&>div]:rounded-none! [&>div]:border-none! [&>div]:bg-transparent!">
        <Code lang={lang}>{code}</Code>
      </div>
    </div>
  );
}

function Terminal({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="overflow-hidden rounded-xl border border-neutral-200 bg-white shadow-sm dark:border-neutral-800 dark:bg-neutral-950">
      <div className="flex items-center gap-1.5 border-b border-neutral-200 bg-neutral-50 px-4 py-2.5 dark:border-neutral-800 dark:bg-neutral-900">
        <span className="h-2.5 w-2.5 rounded-full bg-neutral-300 dark:bg-neutral-700" />
        <span className="h-2.5 w-2.5 rounded-full bg-neutral-300 dark:bg-neutral-700" />
        <span className="h-2.5 w-2.5 rounded-full bg-neutral-300 dark:bg-neutral-700" />
        <span className="ml-3 font-mono text-xs text-neutral-500 dark:text-neutral-400">{title}</span>
      </div>
      <pre className="overflow-x-auto px-4 py-4 font-mono text-[13px] leading-relaxed text-neutral-800 dark:text-neutral-200">
        {children}
      </pre>
    </div>
  );
}

function Prompt({ children }: { children: React.ReactNode }) {
  return (
    <span className="block">
      <span className="select-none text-neutral-400 dark:text-neutral-600">$ </span>
      {children}
    </span>
  );
}

function Muted({ children }: { children: React.ReactNode }) {
  return <span className="block text-neutral-500 dark:text-neutral-400">{children}</span>;
}

// ----------------------------------------------------------------- data

// Verified in this repository: sizes are `ls -lh` of
// `zig build -Doptimize=ReleaseFast` outputs on macOS arm64; line count is
// the app's src/ markup + Zig, tests excluded.
const stats = [
  {
    value: "2.4 MB",
    label: "The whole calculator — engine, widgets, renderer — as one static release binary.",
  },
  {
    value: "0",
    label: "JS engines, browsers, or interpreters inside a canvas app's binary.",
  },
  {
    value: "918",
    label: "Lines of markup + Zig for that entire calculator app.",
  },
  {
    value: "5",
    label: "Real apps in examples/, screenshotted below from actual builds.",
  },
];

const nativeFeel = [
  { name: "OS scroll physics", detail: "momentum and rubber-band overscroll on macOS" },
  { name: "Context menus", detail: "native menus from markup, with submenus and separators" },
  { name: "Menu bar & tray", detail: "app menus and menu-bar extras driven by the model" },
  { name: "Dialogs & file drop", detail: "native open/save panels and drop events as messages" },
  { name: "IME composition", detail: "real text input on macOS, Linux, and Windows" },
  { name: "HiDPI rendering", detail: "crisp scale-factor-aware pixels on every display" },
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

// ----------------------------------------------------------------- page

export default function HomePage() {
  return (
    <div>
      {/* Hero */}
      <section className="relative overflow-hidden">
        <div
          aria-hidden
          className="pointer-events-none absolute inset-0 bg-[radial-gradient(circle,#d4d4d4_1px,transparent_1px)] [background-size:22px_22px] [mask-image:radial-gradient(ellipse_70%_65%_at_50%_35%,black_30%,transparent_75%)] dark:bg-[radial-gradient(circle,#2e2e2e_1px,transparent_1px)]"
        />
        <div
          aria-hidden
          className="pointer-events-none absolute left-1/2 top-[-12rem] h-[26rem] w-[52rem] -translate-x-1/2 rounded-[100%] bg-gradient-to-b from-neutral-200/70 to-transparent blur-3xl dark:from-neutral-800/50"
        />
        <div className="relative mx-auto max-w-6xl px-6 pb-20 pt-20 text-center sm:pb-24 sm:pt-28">
          <h1 className="mx-auto max-w-4xl text-4xl font-semibold tracking-tight text-neutral-900 sm:text-6xl lg:text-7xl dark:text-neutral-100">
            Write markup.
            <br />
            Ship native pixels.
          </h1>
          <p className="mx-auto mt-6 max-w-2xl text-base leading-relaxed text-neutral-600 sm:text-lg dark:text-neutral-400">
            A cross-platform UI framework where views are HTML-like markup, styling is design
            tokens, and logic is plain Zig on one Elm-style loop — rendered by its own engine into
            real OS windows. No browser, no JS runtime.
          </p>
          <div className="mx-auto mt-9 max-w-md">
            <CopyCommand lines={installCommands} />
          </div>
          <div className="mt-8 flex items-center justify-center gap-3">
            <Link
              href="/quick-start"
              className="rounded-full bg-neutral-900 px-5 py-2.5 text-sm font-medium text-white transition-colors hover:bg-neutral-700 dark:bg-white dark:text-neutral-900 dark:hover:bg-neutral-200"
            >
              Get started
            </Link>
            <a
              href={githubUrl}
              target="_blank"
              rel="noopener noreferrer"
              className="rounded-full border border-neutral-300 bg-white/60 px-5 py-2.5 text-sm font-medium text-neutral-900 backdrop-blur-sm transition-colors hover:bg-neutral-100 dark:border-neutral-700 dark:bg-neutral-950/60 dark:text-neutral-100 dark:hover:bg-neutral-900"
            >
              View on GitHub
            </a>
          </div>
        </div>
      </section>

      {/* The loop */}
      <section className="border-t border-neutral-200 dark:border-neutral-800">
        <div className="mx-auto max-w-6xl px-6 py-20 sm:py-24">
          <SectionLabel>The architecture</SectionLabel>
          <SectionTitle>One view. One update. Real pixels.</SectionTitle>
          <SectionLede>
            This is{" "}
            <code className="rounded bg-neutral-100 px-1.5 py-0.5 text-[14px] dark:bg-neutral-800">
              examples/ui-inbox
            </code>{" "}
            from the repository. The entire UI is one markup file; the logic is a Model, a Msg
            union, and an update function. Markup compiles at comptime — view mistakes are compile
            errors with line and column — and in dev you edit the view while the app runs, keeping
            model state.
          </SectionLede>
          <div className="mt-12 grid gap-6 lg:grid-cols-2">
            <CodePane title="src/inbox.zml" lang="html" code={zmlSample} />
            <CodePane title="src/main.zig" lang="zig" code={zigSample} />
          </div>
          <figure className="mt-6">
            <div className="mx-auto max-w-4xl rounded-2xl border border-neutral-200/70 bg-gradient-to-b from-neutral-100 to-neutral-50 p-6 sm:p-12 dark:border-neutral-800 dark:from-neutral-900 dark:to-neutral-950">
              <div className="mx-auto max-w-2xl overflow-hidden rounded-xl border border-neutral-200 shadow-[0_24px_48px_-24px_rgba(0,0,0,0.3)] dark:border-neutral-700 dark:shadow-[0_24px_48px_-16px_rgba(0,0,0,0.9)]">
                <Image
                  src="/home/ui-inbox-macos.png"
                  alt="The ui-inbox example app running in a native macOS window: a task inbox with a text field, filter tabs, a checklist of tasks, and a status bar"
                  width={720}
                  height={548}
                  className="block h-auto w-full"
                />
              </div>
            </div>
            <figcaption className="mx-auto mt-4 max-w-3xl text-center text-sm text-neutral-500 dark:text-neutral-500">
              Built from the source above and captured running on macOS. The pixels come from the
              framework&apos;s engine; the window and scroll physics come from the OS.
            </figcaption>
          </figure>
        </div>
      </section>

      {/* Numbers */}
      <section className="border-t border-neutral-200 bg-neutral-50 dark:border-neutral-800 dark:bg-neutral-900/40">
        <div className="mx-auto max-w-6xl px-6 py-14 sm:py-16">
          <div className="grid gap-10 sm:grid-cols-2 lg:grid-cols-4">
            {stats.map((stat) => (
              <div key={stat.value} className="text-center lg:text-left">
                <div className="font-mono text-4xl font-semibold tracking-tight text-neutral-900 dark:text-neutral-100">
                  {stat.value}
                </div>
                <p className="mt-2 text-sm leading-relaxed text-neutral-600 dark:text-neutral-400">
                  {stat.label}
                </p>
              </div>
            ))}
          </div>
          <p className="mt-10 text-center text-xs text-neutral-400 dark:text-neutral-500">
            Measured in this repository: <code>zig build -Doptimize=ReleaseFast</code> on macOS
            arm64; line counts are app source with tests excluded.
          </p>
        </div>
      </section>

      {/* Showcase */}
      <section className="border-t border-neutral-200 dark:border-neutral-800" id="showcase">
        <div className="mx-auto max-w-6xl px-6 py-20 sm:py-24">
          <SectionLabel>Showcase</SectionLabel>
          <SectionTitle>Five real apps, in the repo</SectionTitle>
          <SectionLede>
            Every screenshot below is rendered by the framework&apos;s deterministic engine from
            the example apps in <code className="rounded bg-neutral-100 px-1.5 py-0.5 text-[14px] dark:bg-neutral-800">examples/</code>{" "}
            — the same state captured once per color scheme. Flip the site theme and the apps flip
            with it.
          </SectionLede>
          <div className="mt-12">
            <Showcase />
          </div>
        </div>
      </section>

      {/* Native feel */}
      <section className="border-t border-neutral-200 dark:border-neutral-800">
        <div className="mx-auto max-w-6xl px-6 py-20 sm:py-24">
          <div className="grid items-center gap-12 lg:grid-cols-2">
            <div>
              <p className="font-mono text-xs font-medium uppercase tracking-[0.2em] text-neutral-400 dark:text-neutral-500">
                Native feel
              </p>
              <h2 className="mt-3 text-3xl font-semibold tracking-tight text-neutral-900 sm:text-4xl dark:text-neutral-100">
                Feels native because it is
              </h2>
              <p className="mt-5 text-base leading-relaxed text-neutral-600 dark:text-neutral-400">
                One engine renders every widget into real OS windows — Metal presentation on
                macOS, lean software paths on Linux and Windows. The parts users touch stay with
                the operating system: scrolling carries OS momentum, menus are real menus, and the
                tray is the real tray.
              </p>
              <Link
                href="/native-ui"
                className="mt-6 inline-block text-sm font-medium text-neutral-900 hover:underline dark:text-neutral-100"
              >
                Native UI guide →
              </Link>
            </div>
            <div className="grid gap-3 sm:grid-cols-2">
              {nativeFeel.map((item) => (
                <div
                  key={item.name}
                  className="rounded-xl border border-neutral-200 p-4 dark:border-neutral-800"
                >
                  <div className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                    {item.name}
                  </div>
                  <p className="mt-1 text-sm leading-relaxed text-neutral-500 dark:text-neutral-400">
                    {item.detail}
                  </p>
                </div>
              ))}
            </div>
          </div>
        </div>
      </section>

      {/* Agents */}
      <section className="border-t border-neutral-200 dark:border-neutral-800">
        <div className="mx-auto max-w-6xl px-6 py-20 sm:py-24">
          <div className="grid items-center gap-12 lg:grid-cols-2">
            <div className="order-2 lg:order-1">
              <Terminal title="any agent, any running app">
                <Prompt>native automate wait</Prompt>
                <Prompt>native automate snapshot</Prompt>
                <Muted>role=button name=&quot;Add task&quot; …</Muted>
                <Prompt>native automate widget-click canvas 3</Prompt>
                <Prompt>native automate assert &apos;gpu_nonblank=true&apos;</Prompt>
                <Prompt>native automate screenshot</Prompt>
              </Terminal>
            </div>
            <div className="order-1 lg:order-2">
              <p className="font-mono text-xs font-medium uppercase tracking-[0.2em] text-neutral-400 dark:text-neutral-500">
                Agents first
              </p>
              <h2 className="mt-3 text-3xl font-semibold tracking-tight text-neutral-900 sm:text-4xl dark:text-neutral-100">
                Built to be written by AI agents
              </h2>
              <p className="mt-5 text-base leading-relaxed text-neutral-600 dark:text-neutral-400">
                Declarative markup and one typed update function make a surface agents author
                reliably — and the repository ships an agent skill that teaches all of it. Every
                app embeds an automation server, so any agent can see and drive the running window:
                snapshots, assertions, input, screenshots. An eval harness hands a clean agent a
                scaffolded workspace and grades the result — builds, markup checks, live snapshots,
                and an LLM judge.
              </p>
              <Link
                href="/automation"
                className="mt-6 inline-block text-sm font-medium text-neutral-900 hover:underline dark:text-neutral-100"
              >
                Automation →
              </Link>
            </div>
          </div>
        </div>
      </section>

      {/* One binary */}
      <section className="border-t border-neutral-200 dark:border-neutral-800">
        <div className="mx-auto max-w-6xl px-6 py-20 sm:py-24">
          <div className="grid items-center gap-12 lg:grid-cols-2">
            <div>
              <p className="font-mono text-xs font-medium uppercase tracking-[0.2em] text-neutral-400 dark:text-neutral-500">
                One binary
              </p>
              <h2 className="mt-3 text-3xl font-semibold tracking-tight text-neutral-900 sm:text-4xl dark:text-neutral-100">
                The whole app is one small file
              </h2>
              <p className="mt-5 text-base leading-relaxed text-neutral-600 dark:text-neutral-400">
                Markup compiles into the executable, so release builds carry no parser, no
                interpreter, and no JS engine — just your logic and the engine, linking the
                system&apos;s own frameworks. Effects run HTTP fetches, process spawns, file I/O,
                and timers off the loop; results come back into <code className="rounded bg-neutral-100 px-1 py-0.5 text-[14px] dark:bg-neutral-800">update</code> as
                plain messages. And when part of your product is the web, WebView panes coexist
                with the canvas in the same window.
              </p>
              <Link
                href="/packaging"
                className="mt-6 inline-block text-sm font-medium text-neutral-900 hover:underline dark:text-neutral-100"
              >
                Packaging →
              </Link>
            </div>
            <Terminal title="examples — release builds">
              <Prompt>zig build -Doptimize=ReleaseFast</Prompt>
              <Prompt>ls -lh */zig-out/bin</Prompt>
              <Muted>2.4M calculator</Muted>
              <Muted>2.4M markdown-viewer</Muted>
              <Muted>2.4M notes</Muted>
              <Muted>4.5M soundboard</Muted>
              <Muted>2.5M system-monitor</Muted>
            </Terminal>
          </div>
        </div>
      </section>

      {/* Platforms */}
      <section className="border-t border-neutral-200 dark:border-neutral-800">
        <div className="mx-auto max-w-6xl px-6 py-20 sm:py-24">
          <SectionLabel>Cross-platform</SectionLabel>
          <SectionTitle>Platforms, honestly</SectionTitle>
          <SectionLede>
            One codebase compiles for macOS, Linux, Windows, iOS, and Android. These statuses
            describe what ships and is verified today — not a roadmap.
          </SectionLede>
          <div className="mt-12 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
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
        </div>
      </section>

      {/* Footer CTA */}
      <section className="border-t border-neutral-200 dark:border-neutral-800">
        <div className="mx-auto max-w-6xl px-6 py-20 text-center sm:py-28">
          <h2 className="text-3xl font-semibold tracking-tight text-neutral-900 sm:text-4xl dark:text-neutral-100">
            Build something native
          </h2>
          <p className="mx-auto mt-4 max-w-xl text-base leading-relaxed text-neutral-600 dark:text-neutral-400">
            Scaffold an app, open a real window, and edit the view while it runs.
          </p>
          <div className="mt-8 flex items-center justify-center gap-3">
            <Link
              href="/quick-start"
              className="rounded-full bg-neutral-900 px-5 py-2.5 text-sm font-medium text-white transition-colors hover:bg-neutral-700 dark:bg-white dark:text-neutral-900 dark:hover:bg-neutral-200"
            >
              Quick Start
            </Link>
            <Link
              href="/native-ui"
              className="rounded-full border border-neutral-300 px-5 py-2.5 text-sm font-medium text-neutral-900 transition-colors hover:bg-neutral-100 dark:border-neutral-700 dark:text-neutral-100 dark:hover:bg-neutral-900"
            >
              Native UI guide
            </Link>
          </div>
        </div>
      </section>

      {/* Footer */}
      <footer className="border-t border-neutral-200 dark:border-neutral-800">
        <div className="mx-auto flex max-w-6xl flex-col items-center justify-between gap-4 px-6 py-10 text-sm text-neutral-500 sm:flex-row dark:text-neutral-400">
          <p>
            {siteName} · Apache-2.0 licensed
          </p>
          <nav className="flex flex-wrap items-center justify-center gap-x-6 gap-y-2">
            <Link href="/quick-start" className="hover:text-neutral-900 dark:hover:text-neutral-100">
              Quick Start
            </Link>
            <Link href="/native-ui" className="hover:text-neutral-900 dark:hover:text-neutral-100">
              Native UI
            </Link>
            <Link href="/automation" className="hover:text-neutral-900 dark:hover:text-neutral-100">
              Automation
            </Link>
            <Link href="/platform-support" className="hover:text-neutral-900 dark:hover:text-neutral-100">
              Platforms
            </Link>
            <a
              href={githubUrl}
              target="_blank"
              rel="noopener noreferrer"
              className="hover:text-neutral-900 dark:hover:text-neutral-100"
            >
              GitHub
            </a>
          </nav>
        </div>
      </footer>
    </div>
  );
}
