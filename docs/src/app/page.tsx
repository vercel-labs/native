import Link from "next/link";
import Image from "next/image";
import { Code } from "@/components/code";
import { Showcase } from "@/components/home/showcase";
import { InstallToggle } from "@/components/home/install-toggle";
import { HeroWindow } from "@/components/home/hero-window";
import { WindowDots } from "@/components/home/window-dots";
import { githubUrl, siteName } from "@/lib/site";

// ---------------------------------------------------------------- samples
// Both excerpts are real source from examples/ui-inbox in this repository.

const markupSample = `<column background="background">
  <row height="{header_height}" padding="12" gap="10" cross="center"
       background="surface" window-drag="true" label="Inbox header">
    <spacer width="{chrome_leading}" />
    <spacer grow="1" />
    <if test="{doneCount}">
      <button variant="ghost" on-press="clear_done">Clear done</button>
    </if>
  </row>
  <separator />
  <column grow="1" gap="12" padding="16">
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
            <checkbox checked="{t.done}" on-toggle="toggle:{t.id}"
                      label="Done" />
            <text grow="1">{t.title}</text>
          </row>
        </for>
      </column>
    </scroll>
  </column>
  <status-bar>{openCount} open · {doneCount} done</status-bar>
</column>`;

const zigSample = `pub const Msg = union(enum) {
    add,
    toggle: u32,
    set_filter: Filter,
    clear_done,
    draft_edit: canvas.TextInputEvent,
    chrome_changed: native_sdk.WindowChrome,
};

pub fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        .add => {
            if (model.draftEmpty()) {
                model.addGeneratedTask();
            } else {
                model.addTask(std.mem.trim(u8, model.draft(), " "));
                model.draft_buffer.clear();
            }
        },
        .toggle => |id| if (model.taskById(id)) |task| {
            task.done = !task.done;
        },
        .set_filter => |filter| model.filter = filter,
        .clear_done => model.clearDone(),
        .draft_edit => |edit| model.draft_buffer.apply(edit),
        .chrome_changed => |chrome| {
            model.chrome_leading = chrome.insets.left;
            model.header_height =
                @max(header_natural_height, chrome.insets.top);
        },
    }
}`;

// ------------------------------------------------------------ small parts

function SectionLabel({ children }: { children: React.ReactNode }) {
  return (
    <p className="text-center font-mono label-12 font-medium uppercase tracking-[0.2em] text-gray-900">
      {children}
    </p>
  );
}

function SectionTitle({ children }: { children: React.ReactNode }) {
  return (
    <h2 className="mt-3 text-center heading-32 text-gray-1000 sm:heading-40">{children}</h2>
  );
}

function SectionLede({ children }: { children: React.ReactNode }) {
  return <p className="mx-auto mt-4 max-w-2xl text-center copy-16 text-gray-900">{children}</p>;
}

function CodePane({ title, lang, code }: { title: string; lang: string; code: string }) {
  return (
    <div className="overflow-hidden rounded-md border border-gray-alpha-400 bg-background-100 shadow-card">
      <div className="flex items-center gap-1.5 border-b border-gray-alpha-400 bg-background-200 px-4 py-2.5 dark:bg-gray-alpha-100">
        <span className="h-2.5 w-2.5 rounded-full bg-gray-500" />
        <span className="h-2.5 w-2.5 rounded-full bg-gray-500" />
        <span className="h-2.5 w-2.5 rounded-full bg-gray-500" />
        <span className="ml-3 font-mono label-12 text-gray-900">{title}</span>
      </div>
      <div className="[&>div]:my-0! [&>div]:rounded-none! [&>div]:border-none! [&>div]:bg-transparent!">
        <Code lang={lang}>{code}</Code>
      </div>
    </div>
  );
}

function Terminal({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="overflow-hidden rounded-md border border-gray-alpha-400 bg-background-100 text-left shadow-card">
      <div className="flex items-center gap-1.5 border-b border-gray-alpha-400 bg-background-200 px-4 py-2.5 dark:bg-gray-alpha-100">
        <span className="h-2.5 w-2.5 rounded-full bg-gray-500" />
        <span className="h-2.5 w-2.5 rounded-full bg-gray-500" />
        <span className="h-2.5 w-2.5 rounded-full bg-gray-500" />
        <span className="ml-3 font-mono label-12 text-gray-900">{title}</span>
      </div>
      <pre className="overflow-x-auto px-4 py-4 font-mono text-[13px] leading-5 text-gray-1000">
        {children}
      </pre>
    </div>
  );
}

function Prompt({ children }: { children: React.ReactNode }) {
  return (
    <span className="block">
      <span className="select-none text-gray-700">$ </span>
      {children}
    </span>
  );
}

function Muted({ children }: { children: React.ReactNode }) {
  return <span className="block text-gray-900">{children}</span>;
}

function InlineCode({ children }: { children: React.ReactNode }) {
  return (
    <code className="rounded-md bg-gray-100 px-1.5 py-0.5 text-[14px]">{children}</code>
  );
}

// ----------------------------------------------------------------- data

// Verified in this repository on macOS arm64 (Apple silicon):
// - Sizes: fresh release build per app —
//   `cd examples/<app> && native build && ls -lh zig-out/bin/<app>`;
//   the largest of the seven showcase apps measures 4.8M unstripped
//   (4.3M after `strip -x`), so "<6 MB" holds for every binary either way.
// - Launch: process spawn to the window shown with its first frame present,
//   warm median of 6 launches per app on an idle box, measured 71-131 ms
//   across the showcase apps (the ~131 ms outlier carries a known host-side
//   present-to-shown gap). Reproduce per app with
//   `NATIVE_SDK_WINDOW_TIMING=1 ./zig-out/bin/<app>` and wall-clock the
//   spawn externally, differencing the printed launch-phase laps.
const stats = [
  {
    value: "<6 MB",
    label: "Every app on this page — engine, widgets, renderer — as one static release binary.",
  },
  {
    value: "~100 ms",
    label: "From launch to the first frame on the glass — 71–131 ms warm across these apps on macOS arm64.",
  },
  {
    value: "0",
    label: "Embedded browsers, script engines, or interpreters inside those binaries.",
  },
];

const principles = [
  {
    name: "Beautiful by default",
    detail: "Great software should not start from a blank slate.",
  },
  {
    name: "Customizable by design",
    detail: "Your app should have its own identity, not ours.",
  },
  {
    name: "Native from the start",
    detail: "Every interface is rendered without a browser or WebView.",
  },
  {
    name: "Predictable state",
    detail: "State changes should be explicit, inspectable and easy to reason about.",
  },
  {
    name: "Simple authoring",
    detail: "Interfaces should be easy to read, easy to write and easy to generate.",
  },
  {
    name: "AI is part of the workflow",
    detail: "Native SDK is designed for a world where humans and AI agents build software together.",
  },
];

const nativeFeel = [
  { name: "OS scroll physics", detail: "momentum and rubber-band overscroll on macOS" },
  { name: "Context menus", detail: "declare one menu in markup or Zig; the OS presents it natively, with an automatic anchored fallback" },
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
    status: "Experimental",
    detail:
      "Apps compile into an embed library and present via CAMetalLayer. Verified on the iOS Simulator; device support is in progress.",
  },
  {
    name: "Android",
    status: "Experimental",
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
        <div className="relative mx-auto max-w-[1200px] px-6 pt-16 text-center sm:pt-24">
          <p className="font-mono text-[11px] font-medium uppercase tracking-[0.18em] text-gray-900 sm:text-xs sm:tracking-[0.25em]">
            macOS · Linux · Windows · iOS · Android
          </p>
          <h1 className="mx-auto mt-4 max-w-5xl heading-40 text-gray-1000 sm:heading-64 lg:heading-72">
            Toolkit for building{" "}
            <br className="hidden sm:block" />
            native desktop apps
          </h1>
          <p className="mx-auto mt-4 max-w-2xl copy-16 text-gray-900 sm:copy-18">
            Write your interface in native markup and Zig. The toolkit&apos;s own engine renders
            it into real OS windows — no browser, no WebView.
          </p>
          <div className="mx-auto mt-8 w-full max-w-xs sm:max-w-sm">
            <InstallToggle />
          </div>
        </div>
        <div className="relative mt-8 pb-16 sm:mt-10 sm:pb-24">
          <HeroWindow />
        </div>
      </section>

      {/* Numbers */}
      <section className="border-t border-gray-alpha-400 bg-background-200 dark:bg-gray-alpha-100">
        <div className="mx-auto max-w-[1200px] px-6 py-16">
          <div className="grid gap-10 sm:grid-cols-3">
            {stats.map((stat) => (
              <div key={stat.value} className="text-center sm:text-left">
                <div className="font-mono text-5xl font-semibold tabular-nums text-gray-1000 sm:text-[56px] sm:leading-[56px]">
                  {stat.value}
                </div>
                <p className="mt-3 copy-14 text-gray-900">{stat.label}</p>
              </div>
            ))}
          </div>
          <p className="mt-10 text-center copy-13 text-gray-900">
            Measured in this repository: <code>zig build -Doptimize=ReleaseFast</code> on macOS
            arm64; launch is process spawn to first presented frame.
          </p>
        </div>
      </section>

      {/* Principles */}
      <section className="border-t border-gray-alpha-400">
        <div className="mx-auto max-w-[1200px] px-6 py-16 sm:py-24">
          <SectionLabel>Principles</SectionLabel>
          <SectionTitle>Beautiful by default. Customizable by design.</SectionTitle>
          <SectionLede>
            {siteName} exists because expressive UI and native performance should not be competing
            goals. Developers often choose web-based runtimes because they offer freedom, speed and
            control over the product experience. But that freedom often comes with a heavy runtime.{" "}
            {siteName} keeps the expressive authoring model and replaces the runtime with native
            rendering.
          </SectionLede>
          {/* The proof: soundboard and deck are the same player — same
              library, transport, and search — separated only by
              design tokens and a chrome pass. Both windows own their own
              chrome (soundboard's header IS its titlebar; deck is a fixed
              512x264 chassis), so neither gets an invented window frame —
              each capture sits on the page as its own silhouette, and the
              size contrast is part of the point. The site draws only the
              stoplights into soundboard's reserved header gap (WindowDots);
              deck's skin draws its own window keys. Soundboard follows the
              site theme; deck has one finish by design, so it never swaps. */}
          <figure className="mt-12">
            <div className="grid gap-6 lg:grid-cols-2">
              <div className="relative overflow-hidden rounded-md border border-gray-alpha-400 shadow-[0_24px_48px_-24px_rgba(0,0,0,0.18)] dark:border-gray-alpha-200 dark:shadow-[0_24px_48px_-24px_rgba(0,0,0,0.7)]">
                {(["light", "dark"] as const).map((scheme) => (
                  <Image
                    key={scheme}
                    src={`/home/soundboard-${scheme}.webp`}
                    alt={`The Soundboard example app rendered by the Native SDK engine (${scheme} theme): a clean music library with album covers and a playback bar`}
                    width={2160}
                    height={1440}
                    quality={90}
                    className={`block h-auto w-full ${
                      scheme === "light" ? "dark:hidden" : "hidden dark:block"
                    }`}
                  />
                ))}
                <WindowDots width={1080} height={720} />
              </div>
              <div className="flex items-center justify-center px-6 py-10 sm:px-10">
                <Image
                  src="/home/deck-dark.webp"
                  alt="The Deck example app rendered by the Native SDK engine: the same music player rebuilt as a fixed 512 by 264 chromeless hardware unit in cream enamel with smoked-glass display bays, a phosphor seven-segment timecode, a spectrum analyzer, and a rotary volume knob"
                  width={1024}
                  height={528}
                  quality={90}
                  className="block h-auto w-full max-w-[512px]"
                />
              </div>
            </div>
            <figcaption className="mx-auto mt-6 max-w-3xl text-center">
              <p className="copy-16 text-gray-1000">
                The same toolkit. The same player. Two identities.
              </p>
              <p className="mt-2 copy-14 text-gray-900">
                Every difference between <InlineCode>examples/soundboard</InlineCode> and{" "}
                <InlineCode>examples/deck</InlineCode> is design tokens and a chrome pass — same
                widgets, same engine. One is an airy app window that follows the site theme; the
                other is a dense 512×264 enamel-and-glass hardware unit with one finish by design.
              </p>
            </figcaption>
          </figure>
          <div className="mx-auto mt-14 grid max-w-4xl gap-x-10 gap-y-8 sm:grid-cols-2 lg:grid-cols-3">
            {principles.map((principle) => (
              <div key={principle.name} className="border-t border-gray-alpha-400 pt-4">
                <h3 className="heading-16 text-gray-1000">{principle.name}</h3>
                <p className="mt-2 copy-14 text-gray-900">{principle.detail}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* The loop */}
      <section className="border-t border-gray-alpha-400">
        <div className="mx-auto max-w-[1200px] px-6 py-16 sm:py-24">
          <SectionLabel>Predictable by design</SectionLabel>
          <SectionTitle>Events. Messages. State. Interface.</SectionTitle>
          <SectionLede>
            Events produce messages, messages update state, and state renders the interface —
            simple to debug, simple to maintain, and simple for AI to generate. This is{" "}
            <InlineCode>examples/ui-inbox</InlineCode> from the repository: the whole UI is one
            declarative view, and one update function is the only place state changes. Mistakes in
            a view are compile errors with line and column, and in dev you edit the view while the
            app runs, keeping state.
          </SectionLede>
          <div className="mt-10 grid gap-6 lg:grid-cols-2">
            <CodePane title="src/inbox.native" lang="html" code={markupSample} />
            <CodePane title="src/main.zig" lang="zig" code={zigSample} />
          </div>
          <figure className="mt-6">
            <div className="mx-auto max-w-4xl rounded-md border border-gray-alpha-400 bg-gradient-to-b from-gray-100 to-background-200 p-6 sm:p-8 dark:from-gray-alpha-100 dark:to-background-100">
              <div className="mx-auto max-w-2xl overflow-hidden rounded-md border border-gray-alpha-400 shadow-[0_24px_48px_-24px_rgba(0,0,0,0.3)] dark:border-gray-alpha-200 dark:shadow-[0_24px_48px_-16px_rgba(0,0,0,0.9)]">
                <Image
                  src="/home/ui-inbox-macos.png"
                  alt="The ui-inbox example app running in a native macOS window: the window controls share the header band with a Clear done action, above a text field, filter tabs, a checklist of tasks, and a status bar"
                  width={720}
                  height={520}
                  className="block h-auto w-full"
                />
              </div>
            </div>
            <figcaption className="mx-auto mt-4 max-w-3xl text-center copy-14 text-gray-900">
              Built from the source above and captured running on macOS. The pixels come from{" "}
              {siteName}’s engine; the window and scroll physics come from the OS.
            </figcaption>
          </figure>
        </div>
      </section>

      {/* Showcase */}
      <section className="border-t border-gray-alpha-400" id="showcase">
        <div className="mx-auto max-w-[1200px] px-6 py-16 sm:py-24">
          <SectionLabel>Built for modern apps</SectionLabel>
          <SectionTitle>Seven real apps, in the repo</SectionTitle>
          <SectionLede>
            Dashboards, editors, tools, internal apps, creative software — every screenshot is
            rendered by {siteName}’s deterministic engine from the example apps in{" "}
            <InlineCode>examples/</InlineCode>, the same state captured once per color scheme.
            Flip the site theme and the apps flip with it — deck alone stays dark, by design.
          </SectionLede>
          <div className="mt-10">
            <Showcase />
          </div>
        </div>
      </section>

      {/* Native feel */}
      <section className="border-t border-gray-alpha-400">
        <div className="mx-auto max-w-[1200px] px-6 py-16 sm:py-24">
          <div className="grid items-center gap-10 lg:grid-cols-2">
            <div>
              <p className="font-mono label-12 font-medium uppercase tracking-[0.2em] text-gray-900">
                Native from the start
              </p>
              <h2 className="mt-3 heading-32 text-gray-1000 sm:heading-40">
                Feels native because it is
              </h2>
              <p className="mt-4 copy-16 text-gray-900">
                {siteName} owns its renderer — no embedded browser, no heavy runtime pretending to
                be native. One engine draws every widget into real OS windows, and the parts users
                touch stay with the operating system: scrolling carries OS momentum, menus are
                real menus, and the tray is the real tray.
              </p>
              <Link
                href="/native-ui"
                className="mt-6 inline-block button-14 text-gray-1000 hover:underline"
              >
                Native UI Guide →
              </Link>
            </div>
            <div className="grid gap-3 sm:grid-cols-2">
              {nativeFeel.map((item) => (
                <div key={item.name} className="rounded-md border border-gray-alpha-400 p-4">
                  <div className="heading-14 text-gray-1000">{item.name}</div>
                  <p className="mt-1 copy-14 text-gray-900">{item.detail}</p>
                </div>
              ))}
            </div>
          </div>
        </div>
      </section>

      {/* Agents */}
      <section className="border-t border-gray-alpha-400">
        <div className="mx-auto max-w-[1200px] px-6 py-16 sm:py-24">
          <div className="grid items-center gap-10 lg:grid-cols-2">
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
              <p className="font-mono label-12 font-medium uppercase tracking-[0.2em] text-gray-900">
                AI is part of the workflow
              </p>
              <h2 className="mt-3 heading-32 text-gray-1000 sm:heading-40">
                Built to be written by AI agents
              </h2>
              <p className="mt-4 copy-16 text-gray-900">
                Declarative markup and one typed update function make a surface agents author
                reliably — and the repository ships an agent skill that teaches all of it. Every
                app embeds an automation server, so any agent can see and drive the running window:
                snapshots, assertions, input, screenshots. An eval harness hands a clean agent a
                scaffolded workspace and grades the result — builds, markup checks, live snapshots,
                and an LLM judge.
              </p>
              <Link
                href="/automation"
                className="mt-6 inline-block button-14 text-gray-1000 hover:underline"
              >
                Automation →
              </Link>
            </div>
          </div>
        </div>
      </section>

      {/* One binary */}
      <section className="border-t border-gray-alpha-400">
        <div className="mx-auto max-w-[1200px] px-6 py-16 sm:py-24">
          <div className="grid items-center gap-10 lg:grid-cols-2">
            <div>
              <p className="font-mono label-12 font-medium uppercase tracking-[0.2em] text-gray-900">
                One binary
              </p>
              <h2 className="mt-3 heading-32 text-gray-1000 sm:heading-40">
                The whole app is one small file
              </h2>
              <p className="mt-4 copy-16 text-gray-900">
                Markup compiles into the executable, so release builds carry no parser, no
                interpreter, and no scripting engine — just your logic and the engine, linking the
                system’s own frameworks. Effects run HTTP fetches, process spawns, file I/O, and
                timers off the loop; results come back into <InlineCode>update</InlineCode> as
                plain messages. And when part of your product is the web, WebView panes coexist
                with the canvas in the same window.
              </p>
              <Link
                href="/packaging"
                className="mt-6 inline-block button-14 text-gray-1000 hover:underline"
              >
                Packaging →
              </Link>
            </div>
            <Terminal title="examples — release builds">
              <Prompt>zig build -Doptimize=ReleaseFast</Prompt>
              <Prompt>ls -lh */zig-out/bin</Prompt>
              <Muted>3.6M calculator</Muted>
              <Muted>4.2M deck</Muted>
              <Muted>3.6M feed</Muted>
              <Muted>3.5M markdown-viewer</Muted>
              <Muted>3.5M notes</Muted>
              <Muted>5.7M soundboard</Muted>
              <Muted>3.7M system-monitor</Muted>
            </Terminal>
          </div>
        </div>
      </section>

      {/* Platforms */}
      <section className="border-t border-gray-alpha-400">
        <div className="mx-auto max-w-[1200px] px-6 py-16 sm:py-24">
          <SectionLabel>Cross-platform</SectionLabel>
          <SectionTitle>One SDK, desktop and mobile</SectionTitle>
          <SectionLede>
            One codebase compiles for macOS, Linux, Windows, iOS, and Android. Desktop is the
            mature surface; mobile is experimental — verified on the simulator and emulator, with
            APIs and tooling still evolving. These statuses describe what ships and is verified
            today — not a roadmap.
          </SectionLede>
          <div className="mt-10 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
            {platforms.map((platform) => (
              <div key={platform.name} className="rounded-md border border-gray-alpha-400 p-6">
                <div className="flex items-baseline justify-between gap-2">
                  <h3 className="heading-14 text-gray-1000">{platform.name}</h3>
                  <span className="label-12 font-medium uppercase tracking-wider text-gray-900">
                    {platform.status}
                  </span>
                </div>
                <p className="mt-2 copy-14 text-gray-900">{platform.detail}</p>
              </div>
            ))}
          </div>
          <p className="mt-8 text-center">
            <Link
              href="/platform-support"
              className="button-14 text-gray-1000 hover:underline"
            >
              Full Support Matrix →
            </Link>
          </p>
        </div>
      </section>

      {/* Footer CTA */}
      <section className="relative overflow-hidden border-t border-gray-alpha-400">
        <div
          aria-hidden
          className="pointer-events-none absolute left-1/2 bottom-[-14rem] h-[28rem] w-[64rem] -translate-x-1/2 rounded-[100%] bg-gradient-to-t from-gray-200/70 to-transparent blur-3xl dark:from-white/[0.04]"
        />
        <div className="relative mx-auto max-w-[1200px] px-6 py-16 text-center sm:py-24">
          <h2 className="heading-32 text-gray-1000 sm:heading-40">Build something native</h2>
          <p className="mx-auto mt-4 max-w-xl copy-16 text-gray-900">
            Scaffold an app, open a real window, and edit the view while it runs.
          </p>
          <div className="mx-auto mt-8 max-w-md">
            <Terminal title="terminal">
              <Prompt>native init my_app</Prompt>
              <Prompt>cd my_app && native dev</Prompt>
              <Muted>a real window opens — edit src/app.native while it runs</Muted>
            </Terminal>
          </div>
          <div className="mt-8 flex items-center justify-center gap-3">
            <Link
              href="/quick-start"
              className="inline-flex h-10 items-center justify-center rounded-md bg-gray-1000 px-4 button-14 text-background-100 transition-colors hover:bg-gray-1000/85"
            >
              Quick Start
            </Link>
            <Link
              href="/native-ui"
              className="inline-flex h-10 items-center justify-center rounded-md border border-gray-alpha-400 bg-background-100 px-4 button-14 text-gray-1000 transition-colors hover:bg-gray-100"
            >
              Native UI Guide
            </Link>
          </div>
        </div>
      </section>

      {/* Footer */}
      <footer className="border-t border-gray-alpha-400">
        <div className="mx-auto flex max-w-[1200px] flex-col items-center justify-between gap-4 px-6 py-10 label-14 text-gray-900 sm:flex-row">
          <p>{siteName}</p>
          <nav className="flex flex-wrap items-center justify-center gap-x-6 gap-y-2">
            <Link href="/quick-start" className="transition-colors hover:text-gray-1000">
              Quick Start
            </Link>
            <Link href="/native-ui" className="transition-colors hover:text-gray-1000">
              Native UI
            </Link>
            <Link href="/automation" className="transition-colors hover:text-gray-1000">
              Automation
            </Link>
            <Link href="/platform-support" className="transition-colors hover:text-gray-1000">
              Platforms
            </Link>
            <a
              href={githubUrl}
              target="_blank"
              rel="noopener noreferrer"
              className="transition-colors hover:text-gray-1000"
            >
              GitHub
            </a>
          </nav>
        </div>
      </footer>
    </div>
  );
}
