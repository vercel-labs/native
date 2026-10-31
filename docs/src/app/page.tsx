import Link from "next/link";
import Image from "next/image";
import { Code } from "@/components/code";
import { Showcase } from "@/components/home/showcase";
import { InstallToggle } from "@/components/home/install-toggle";
import { HeroWindow } from "@/components/home/hero-window";
import { WindowDots } from "@/components/home/window-dots";
import { githubUrl, siteName } from "@/lib/site";

// ---------------------------------------------------------------- samples
// The markup is excerpted from examples/ui-inbox. The core excerpt shows
// the same loop in the default TypeScript authoring language.

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

const tsSample = `export type Msg =
  | { readonly kind: "add" }
  | { readonly kind: "toggle"; readonly id: number }
  | { readonly kind: "set_filter"; readonly filter: Filter }
  | { readonly kind: "clear_done" }
  | { readonly kind: "draft_edit"; readonly edit: TextInputEvent };

export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "add":
      return addTask(model);
    case "toggle":
      return {
        ...model,
        tasks: model.tasks.map((task) =>
          task.id === msg.id ? { ...task, done: !task.done } : task,
        ),
      };
    case "set_filter":
      return { ...model, filter: msg.filter };
    case "clear_done":
      return { ...model, tasks: model.tasks.filter((task) => !task.done) };
    case "draft_edit":
      return { ...model, draft: applyDraftEdit(model.draft, msg.edit) };
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

const features = [
  { name: "Components", detail: "Buttons, text inputs, lists, tables, dialogs, and charts." },
  { name: "Design tokens", detail: "Configure colors, spacing, typography, and themes by name." },
  { name: "Native rendering", detail: "The toolkit renders views in OS windows; web content is optional." },
  { name: "App state", detail: "Typed messages drive updates; views derive their content from the model." },
  { name: "Native markup", detail: "Declare layout, bindings, and message dispatch in .native files." },
  { name: "Automation", detail: "Inspect accessibility snapshots, send input, and capture screenshots." },
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
            Write app logic in TypeScript and views in Native markup. The toolkit compiles them to native code and renders the interface in OS windows. Zig cores and embedded web content are also supported.
          </p>
          <div className="mx-auto mt-8 w-full max-w-xs sm:max-w-sm">
            <InstallToggle />
          </div>
        </div>
        <div className="relative mt-8 pb-16 sm:mt-10 sm:pb-24">
          <HeroWindow />
        </div>
      </section>

      {/* Components and themes */}
      <section className="border-t border-gray-alpha-400">
        <div className="mx-auto max-w-[1200px] px-6 py-16 sm:py-24">
          <SectionLabel>Components and themes</SectionLabel>
          <SectionTitle>Configure components with design tokens</SectionTitle>
          <SectionLede>
            {siteName} provides native-rendered components with named tokens for colors, spacing, and typography. These examples use the same widgets and playback logic with different themes.
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
                Two themes for the same app
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
            {features.map((feature) => (
              <div key={feature.name} className="border-t border-gray-alpha-400 pt-4">
                <h3 className="heading-16 text-gray-1000">{feature.name}</h3>
                <p className="mt-2 copy-14 text-gray-900">{feature.detail}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* The loop */}
      <section className="border-t border-gray-alpha-400">
        <div className="mx-auto max-w-[1200px] px-6 py-16 sm:py-24">
          <SectionLabel>App model</SectionLabel>
          <SectionTitle>Events. Messages. State. Interface.</SectionTitle>
          <SectionLede>
            Events dispatch typed messages to the update function, which produces the next model and any effects. The view reads the committed model. TypeScript cores compile to native code; markup changes can reload while the app runs, preserving state.
          </SectionLede>
          <div className="mt-10 grid gap-6 lg:grid-cols-2">
            <CodePane title="src/app.native" lang="html" code={markupSample} />
            <CodePane title="src/core.ts" lang="ts" code={tsSample} />
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
              The <InlineCode>ui-inbox</InlineCode> reference captured running on macOS. The pixels
              come from {siteName}’s engine; the window and scroll physics come from the OS.
            </figcaption>
          </figure>
        </div>
      </section>

      {/* Showcase */}
      <section className="border-t border-gray-alpha-400" id="showcase">
        <div className="mx-auto max-w-[1200px] px-6 py-16 sm:py-24">
          <SectionLabel>Examples</SectionLabel>
          <SectionTitle>Explore the example apps</SectionTitle>
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
                Platform integration
              </p>
              <h2 className="mt-3 heading-32 text-gray-1000 sm:heading-40">
                OS windows and platform services
              </h2>
              <p className="mt-4 copy-16 text-gray-900">
                {siteName} renders widgets in OS windows and integrates with platform menus, dialogs, text input, and scrolling. Available capabilities vary by host; see the platform support matrix for details.
              </p>
              <Link
                href="/docs/native-ui"
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
                Automation
              </p>
              <h2 className="mt-3 heading-32 text-gray-1000 sm:heading-40">
                Inspect and drive a running app
              </h2>
              <p className="mt-4 copy-16 text-gray-900">
                Enable the automation server to expose accessibility snapshots, send input commands, assert on app state, and capture screenshots. The CLI includes agent skills for app authoring and inspection.
              </p>
              <Link
                href="/docs/automation"
                className="mt-6 inline-block button-14 text-gray-1000 hover:underline"
              >
                Automation →
              </Link>
            </div>
          </div>
        </div>
      </section>

      {/* Distribution */}
      <section className="border-t border-gray-alpha-400">
        <div className="mx-auto max-w-[1200px] px-6 py-16 sm:py-24">
          <div className="grid items-center gap-10 lg:grid-cols-2">
            <div>
              <p className="font-mono label-12 font-medium uppercase tracking-[0.2em] text-gray-900">
                Distribution
              </p>
              <h2 className="mt-3 heading-32 text-gray-1000 sm:heading-40">
                Build and package your app
              </h2>
              <p className="mt-4 copy-16 text-gray-900">
                Native markup and app logic compile into the executable. Packaging includes app assets and metadata. Apps that embed web content also include the configured frontend assets and, when selected, a web engine.
              </p>
              <Link
                href="/docs/packaging"
                className="mt-6 inline-block button-14 text-gray-1000 hover:underline"
              >
                Packaging →
              </Link>
            </div>
            <div className="rounded-md border border-gray-alpha-400 bg-background-100 p-6">
              <h3 className="heading-20 text-gray-1000">Distribution guides</h3>
              <ul className="mt-4 space-y-4 copy-14 text-gray-900">
                <li><Link href="/docs/packaging">Package a desktop app</Link></li>
                <li><Link href="/docs/packaging/signing">Sign a release</Link></li>
                <li><Link href="/docs/updates">Configure app updates</Link></li>
                <li><Link href="/docs/platform-support">Check platform requirements</Link></li>
              </ul>
            </div>
          </div>
        </div>
      </section>

      {/* Platforms */}
      <section className="border-t border-gray-alpha-400">
        <div className="mx-auto max-w-[1200px] px-6 py-16 sm:py-24">
          <SectionLabel>Cross-platform</SectionLabel>
          <SectionTitle>Desktop and experimental mobile hosts</SectionTitle>
          <SectionLede>
            Native SDK has hosts for macOS, Linux, and Windows. Mobile support is experimental, and capabilities and verification differ by platform. Check the support matrix before choosing a target.
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
              href="/docs/platform-support"
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
          <div className="mt-8 flex flex-wrap items-center justify-center gap-3">
            <Link
              href="/docs/quick-start"
              className="inline-flex h-10 items-center justify-center rounded-md bg-gray-1000 px-4 button-14 text-background-100 transition-colors hover:bg-gray-1000/85"
            >
              Quick Start
            </Link>
            <Link
              href="/docs/typescript"
              className="inline-flex h-10 items-center justify-center rounded-md border border-gray-alpha-400 bg-background-100 px-4 button-14 text-gray-1000 transition-colors hover:bg-gray-100"
            >
              TypeScript Cores
            </Link>
            <Link
              href="/docs/native-ui"
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
            <Link href="/docs/quick-start" className="transition-colors hover:text-gray-1000">
              Quick Start
            </Link>
            <Link href="/docs/native-ui" className="transition-colors hover:text-gray-1000">
              Native UI
            </Link>
            <Link href="/docs/typescript" className="transition-colors hover:text-gray-1000">
              TypeScript
            </Link>
            <Link href="/docs/automation" className="transition-colors hover:text-gray-1000">
              Automation
            </Link>
            <Link href="/docs/platform-support" className="transition-colors hover:text-gray-1000">
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
