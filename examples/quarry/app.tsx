// Quarry, a settings app with a wide spread of form controls: text, email, password, number,
// range, colour, date and time fields, selects, radios, checkboxes and switches, in five sections,
// with two native dialogs (reset to defaults, add a forwarding address), validation on save and a
// Cmd+S shortcut. React renders it, Tailwind styles it, and the inputs, buttons and switches come
// from the UI SDK.

import { useEffect, useRef, useState } from "react";
import type { ReactNode } from "react";
import { createRoot } from "react-dom/client";
import { Button } from "@ui-sdk/react/button";
import { Input } from "@ui-sdk/react/input";
import { Switch, SwitchThumb } from "@ui-sdk/react/switch";

const inputClass = "h-10 w-full rounded-lg border border-slate-200 bg-white px-3 text-[13px] text-slate-800 outline-none placeholder:text-slate-400 focus:border-indigo-300 focus:ring-4 focus:ring-indigo-50";
const sections = [
  { id: "general", title: "General" },
  { id: "appearance", title: "Appearance" },
  { id: "notifications", title: "Notifications" },
  { id: "privacy", title: "Privacy" },
  { id: "advanced", title: "Advanced" },
];

function Modal(props: { open: boolean; onClose: () => void; id: string; title: string; children: ReactNode }) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const dialog = ref.current;
    if (dialog === null) return;
    if (props.open && !dialog.open) dialog.showModal();
    if (!props.open && dialog.open) dialog.close();
  }, [props.open]);
  return (
    <dialog id={props.id} ref={ref} onClose={props.onClose} className="m-auto w-[440px] rounded-2xl border border-slate-200 bg-white p-0 shadow-2xl outline-none backdrop:bg-slate-950/40">
      <div className="flex flex-col gap-4 p-6">
        <h2 className="text-[17px] font-semibold tracking-tight">{props.title}</h2>
        {props.children}
      </div>
    </dialog>
  );
}

function Section(props: { title: string; description: string; children: ReactNode }) {
  return (
    <section className="border-b border-slate-100 px-6 py-5 last:border-b-0">
      <h2 className="text-[14px] font-semibold text-slate-800">{props.title}</h2>
      <p className="mt-0.5 text-[12px] text-slate-500">{props.description}</p>
      <div className="mt-4">{props.children}</div>
    </section>
  );
}

function Label(props: { text: string; children: ReactNode }) {
  return (
    <label className="block">
      <span className="mb-1.5 block text-[12.5px] font-medium text-slate-700">{props.text}</span>
      {props.children}
    </label>
  );
}

function SwitchRow(props: { id: string; title: string; description: string; checked: boolean; onChange: (next: boolean) => void }) {
  return (
    <div className="flex items-start justify-between gap-6 py-3">
      <div>
        <p className="text-[13px] font-medium text-slate-800">{props.title}</p>
        <p className="mt-0.5 text-[11.5px] leading-relaxed text-slate-500">{props.description}</p>
      </div>
      <Switch
        id={props.id}
        checked={props.checked}
        onCheckedChange={(next: boolean) => props.onChange(next)}
        className="inline-flex h-6 w-11 shrink-0 items-center rounded-full bg-slate-200 p-0.5 data-[checked]:bg-indigo-600"
      >
        <SwitchThumb className="block h-5 w-5 rounded-full bg-white shadow-sm transition-transform data-[checked]:translate-x-5" />
      </Switch>
    </div>
  );
}

function App() {
  const [tab, setTab] = useState("general");
  const [saved, setSaved] = useState("All changes saved");
  const [invalid, setInvalid] = useState<string[]>([]);

  const [name, setName] = useState("Robin Avery");
  const [email, setEmail] = useState("robin@example.com");
  const [signature, setSignature] = useState("Sent from the workshop.");
  const [language, setLanguage] = useState("English (US)");
  const [timezone, setTimezone] = useState("America/Los_Angeles");

  const [theme, setTheme] = useState("system");
  const [accent, setAccent] = useState("#4f46e5");
  const [textSize, setTextSize] = useState(16);
  const [reduceMotion, setReduceMotion] = useState(false);

  const [mailProduct, setMailProduct] = useState(true);
  const [mailDesktop, setMailDesktop] = useState(false);
  const [weekly, setWeekly] = useState(true);
  const [digest, setDigest] = useState("weekly");
  const [quietStart, setQuietStart] = useState("21:00");
  const [launchDate, setLaunchDate] = useState("2026-12-04");

  const [analytics, setAnalytics] = useState(true);
  const [crashReports, setCrashReports] = useState(true);
  const [password, setPassword] = useState("");
  const [timeout, setTimeoutMinutes] = useState("30");

  const [resetOpen, setResetOpen] = useState(false);
  const [addressOpen, setAddressOpen] = useState(false);
  const [address, setAddress] = useState("");
  const [addressError, setAddressError] = useState("");
  const [addresses, setAddresses] = useState<string[]>(["ops@example.com"]);

  const emailOk = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email);
  const timeoutValue = Number(timeout);
  const timeoutOk = timeout !== "" && timeoutValue >= 5 && timeoutValue <= 120;

  function save(): void {
    const bad: string[] = [];
    if (name.trim() === "") bad.push("name");
    if (!emailOk) bad.push("email");
    if (!timeoutOk) bad.push("timeout");
    setInvalid(bad);
    if (bad.length > 0) {
      setSaved("Fix the highlighted fields");
      return;
    }
    setSaved("Saved just now");
  }

  function clear(field: string): void {
    if (invalid.indexOf(field) >= 0) setInvalid(invalid.filter((item) => item !== field));
  }

  function restoreDefaults(): void {
    setName("Robin Avery");
    setEmail("robin@example.com");
    setSignature("Sent from the workshop.");
    setLanguage("English (US)");
    setTimezone("America/Los_Angeles");
    setTheme("system");
    setAccent("#4f46e5");
    setTextSize(16);
    setReduceMotion(false);
    setMailProduct(true);
    setMailDesktop(false);
    setWeekly(true);
    setDigest("weekly");
    setQuietStart("21:00");
    setLaunchDate("2026-12-04");
    setAnalytics(true);
    setCrashReports(true);
    setPassword("");
    setTimeoutMinutes("30");
    setAddresses(["ops@example.com"]);
    setInvalid([]);
    setResetOpen(false);
    setSaved("Defaults restored");
  }

  function addAddress(): void {
    const value = address.trim();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(value)) {
      setAddressError("Enter an email address like naming@example.com.");
      return;
    }
    if (addresses.indexOf(value) >= 0) {
      setAddressError("That address is already on the list.");
      return;
    }
    setAddresses([...addresses, value]);
    setAddress("");
    setAddressError("");
    setAddressOpen(false);
    setSaved("Forwarding address added");
  }

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && (event.key === "s" || event.key === "S")) {
        event.preventDefault();
        save();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  const nameBad = invalid.indexOf("name") >= 0;
  const emailBad = invalid.indexOf("email") >= 0;
  const timeoutBad = invalid.indexOf("timeout") >= 0;

  return (
    <div className="flex h-screen flex-col bg-slate-50 font-sans text-slate-900">
      <header className="flex h-16 shrink-0 items-center gap-4 border-b border-slate-200 bg-white px-7">
        <div className="grid h-8 w-8 place-items-center rounded-lg bg-slate-900 text-[13px] font-bold text-white">Q</div>
        <div>
          <h1 className="text-[16px] font-semibold tracking-tight">Preferences</h1>
          <p className="text-[11.5px] text-slate-500">Workspace settings for Quarry</p>
        </div>
        <p id="saved" className="ml-auto text-[11.5px] text-slate-500">{saved}</p>
        <button id="revert" type="button" onClick={restoreDefaults} className="inline-flex h-9 items-center rounded-lg border border-slate-200 bg-white px-3.5 text-[12.5px] font-medium text-slate-600 hover:bg-slate-50">Revert</button>
        <Button id="save" onClick={save} className="inline-flex h-9 items-center rounded-lg bg-slate-900 px-4 text-[12.5px] font-medium text-white shadow-sm hover:bg-slate-800">Save changes</Button>
      </header>

      <div className="flex min-h-0 flex-1">
        <aside className="w-56 shrink-0 border-r border-slate-200 bg-white px-3 py-4">
          {sections.map((section) => (
            <button
              key={section.id}
              id={"tab-" + section.id}
              type="button"
              onClick={() => setTab(section.id)}
              className={"mb-1 block w-full rounded-lg px-3 py-2 text-left text-[12.5px] font-medium " + (tab === section.id ? "bg-slate-900 text-white" : "text-slate-600 hover:bg-slate-100")}
            >
              {section.title}
            </button>
          ))}
          <div className="mt-4 rounded-lg bg-slate-50 p-3 text-[11px] leading-relaxed text-slate-500">
            Controls here cover the field types, the three kinds of choice, the switches and the two dialogs.
          </div>
        </aside>

        <main className="min-h-0 flex-1 overflow-y-auto px-7 py-6">
          <div className="mx-auto max-w-[680px] overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-sm">
            {tab === "general" && (
              <div>
                <Section title="Profile" description="How you appear across the workspace.">
                  <div className="grid grid-cols-2 gap-4">
                    <Label text="Full name">
                      <Input id="name" value={name} onValueChange={(value: string) => { setName(value); clear("name"); }} className={inputClass + (nameBad ? " border-rose-300 ring-4 ring-rose-50" : "")} />
                      {nameBad && <span id="error-name" className="mt-1 block text-[11.5px] font-medium text-rose-600">Enter your name.</span>}
                    </Label>
                    <Label text="Email">
                      <Input id="email" value={email} onValueChange={(value: string) => { setEmail(value); clear("email"); }} className={inputClass + (emailBad ? " border-rose-300 ring-4 ring-rose-50" : "")} />
                      {emailBad && <span id="error-email" className="mt-1 block text-[11.5px] font-medium text-rose-600">Enter an email like name@example.com.</span>}
                    </Label>
                    <Label text="Language">
                      <select id="language" value={language} onChange={(event: any) => setLanguage(String(event.target.value))} className={inputClass}>
                        <option>English (US)</option>
                        <option>English (UK)</option>
                        <option>Deutsch</option>
                        <option>日本語</option>
                      </select>
                    </Label>
                    <Label text="Timezone">
                      <select id="timezone" value={timezone} onChange={(event: any) => setTimezone(String(event.target.value))} className={inputClass}>
                        <option value="America/Los_Angeles">Pacific Time</option>
                        <option value="America/New_York">Eastern Time</option>
                        <option value="Europe/London">London</option>
                        <option value="Asia/Tokyo">Tokyo</option>
                      </select>
                    </Label>
                  </div>
                  <div className="mt-4">
                    <Label text="Email signature">
                      <textarea id="signature" value={signature} onInput={(event: any) => setSignature(String(event.target.value))} rows={3} className="w-full resize-none rounded-lg border border-slate-200 bg-white px-3 py-2 text-[13px] text-slate-800 outline-none focus:border-indigo-300 focus:ring-4 focus:ring-indigo-50"></textarea>
                    </Label>
                  </div>
                </Section>
                <Section title="Session" description="How long a session stays open on a shared machine.">
                  <Label text="Timeout (minutes)">
                    <input id="timeout" type="number" min="5" max="120" value={timeout} onInput={(event: any) => { setTimeoutMinutes(String(event.target.value)); clear("timeout"); }} className={inputClass + " w-32" + (timeoutBad ? " border-rose-300 ring-4 ring-rose-50" : "")} />
                    {timeoutBad && <span id="error-timeout" className="mt-1 block text-[11.5px] font-medium text-rose-600">Use a whole number from 5 to 120.</span>}
                  </Label>
                </Section>
              </div>
            )}

            {tab === "appearance" && (
              <div>
                <Section title="Theme" description="The palette every window opens with.">
                  <div className="flex gap-3">
                    {[
                      { id: "theme-system", value: "system", label: "System" },
                      { id: "theme-light", value: "light", label: "Light" },
                      { id: "theme-dark", value: "dark", label: "Dark" },
                    ].map((choice) => (
                      <label key={choice.value} className={"flex flex-1 cursor-pointer flex-col gap-2 rounded-xl border p-3 " + (theme === choice.value ? "border-indigo-300 bg-indigo-50/60 ring-1 ring-indigo-200" : "border-slate-200 hover:border-slate-300")}>
                        <input id={choice.id} type="radio" name="theme" checked={theme === choice.value} onChange={() => setTheme(choice.value)} />
                        <span className="text-[12.5px] font-medium text-slate-700">{choice.label}</span>
                      </label>
                    ))}
                  </div>
                </Section>
                <Section title="Accent" description="Used for links, focus rings and the send button.">
                  <div className="flex items-center gap-3">
                    <input id="accent" type="color" value={accent} onInput={(event: any) => setAccent(String(event.target.value))} className="h-10 w-16 rounded-lg border border-slate-200" />
                    <div className="h-10 flex-1 rounded-lg" style={{ backgroundColor: accent }}></div>
                    <p id="accent-value" className="w-24 font-mono text-[12px] text-slate-500">{accent}</p>
                  </div>
                </Section>
                <Section title="Reading" description="Comfort settings for long pages.">
                  <Label text={"Text size · " + String(textSize) + " px"}>
                    <input id="text-size" type="range" min="12" max="22" step="1" value={textSize} onInput={(event: any) => setTextSize(Number(event.target.value))} className="w-full" />
                  </Label>
                  <label className="mt-3 flex items-center gap-3">
                    <input id="reduce-motion" type="checkbox" checked={reduceMotion} onChange={() => setReduceMotion(!reduceMotion)} />
                    <span className="text-[12.5px] text-slate-600">Reduce motion (turn off the page and panel animations)</span>
                  </label>
                </Section>
              </div>
            )}

            {tab === "notifications" && (
              <div>
                <Section title="Email" description="What Quarry may email you about.">
                  <SwitchRow id="switch-email" title="Product updates" description="New features, at most twice a month." checked={mailProduct} onChange={setMailProduct} />
                  <SwitchRow id="switch-desktop" title="Desktop alerts" description="A banner when a build finishes or fails." checked={mailDesktop} onChange={setMailDesktop} />
                  <SwitchRow id="switch-weekly" title="Weekly digest" description="A Monday summary of the workspace." checked={weekly} onChange={setWeekly} />
                </Section>
                <Section title="Digest" description="When the summary leaves the building.">
                  <div className="grid grid-cols-2 gap-4">
                    <Label text="Frequency">
                      <select id="digest" value={digest} onChange={(event: any) => setDigest(String(event.target.value))} className={inputClass}>
                        <option value="daily">Every day</option>
                        <option value="weekly">Every Monday</option>
                        <option value="monthly">First of the month</option>
                      </select>
                    </Label>
                    <Label text="Quiet hours start">
                      <input id="quiet-start" type="time" value={quietStart} onInput={(event: any) => setQuietStart(String(event.target.value))} className={inputClass} />
                    </Label>
                    <Label text="Campaign start">
                      <input id="launch-date" type="date" value={launchDate} onInput={(event: any) => setLaunchDate(String(event.target.value))} className={inputClass} />
                    </Label>
                  </div>
                </Section>
              </div>
            )}

            {tab === "privacy" && (
              <div>
                <Section title="Sharing" description="What leaves this machine.">
                  <label className="flex items-center gap-3 py-2">
                    <input id="analytics" type="checkbox" checked={analytics} onChange={() => setAnalytics(!analytics)} />
                    <span className="text-[12.5px] text-slate-600">Send anonymous usage counts</span>
                  </label>
                  <label className="flex items-center gap-3 py-2">
                    <input id="crash" type="checkbox" checked={crashReports} onChange={() => setCrashReports(!crashReports)} />
                    <span className="text-[12.5px] text-slate-600">Send crash reports</span>
                  </label>
                </Section>
                <Section title="Password" description="Change the password for this account.">
                  <Label text="New password">
                    <Input id="password" type="password" value={password} onValueChange={(value: string) => setPassword(value)} placeholder="At least 12 characters" className={inputClass} />
                  </Label>
                </Section>
              </div>
            )}

            {tab === "advanced" && (
              <div>
                <Section title="Forwarding" description="A copy of every receipt goes to these addresses.">
                  <ul id="addresses" className="space-y-2">
                    {addresses.map((item) => (
                      <li key={item} className="flex items-center gap-2 rounded-lg border border-slate-200 px-3 py-2 text-[12.5px] text-slate-700">
                        <span className="h-1.5 w-1.5 rounded-full bg-emerald-500"></span>
                        {item}
                      </li>
                    ))}
                  </ul>
                  <p id="address-count" className="mt-2 text-[11.5px] text-slate-500">{addresses.length} {addresses.length === 1 ? "address" : "addresses"}</p>
                  <Button id="address-open" onClick={() => { setAddressError(""); setAddress(""); setAddressOpen(true); }} className="mt-3 inline-flex h-9 items-center rounded-lg border border-slate-200 bg-white px-3.5 text-[12.5px] font-medium text-slate-600 hover:bg-slate-50">
                    Add a forwarding address
                  </Button>
                </Section>
                <Section title="Reset" description="Put every setting back the way it shipped.">
                  <button id="reset-open" type="button" onClick={() => setResetOpen(true)} className="inline-flex h-9 items-center rounded-lg border border-rose-200 bg-rose-50 px-3.5 text-[12.5px] font-medium text-rose-600 hover:bg-rose-100">
                    Restore defaults…
                  </button>
                </Section>
              </div>
            )}
          </div>
          <p className="mx-auto mt-3 max-w-[680px] text-[11px] text-slate-400">Cmd+S saves. The two dialogs are native modal dialogs; Escape closes them.</p>
        </main>
      </div>

      <Modal open={resetOpen} onClose={() => setResetOpen(false)} id="reset-dialog" title="Restore every default?">
        <p className="text-[12.5px] leading-relaxed text-slate-500">This puts the profile, appearance, notifications and privacy settings back to their defaults. Forwarding addresses are cleared too.</p>
        <div className="flex justify-end gap-2">
          <button id="reset-cancel" type="button" onClick={() => setResetOpen(false)} className="inline-flex h-9 items-center rounded-lg border border-slate-200 px-3.5 text-[12.5px] font-medium text-slate-600 hover:bg-slate-50">Cancel</button>
          <button id="reset-confirm" type="button" onClick={restoreDefaults} className="inline-flex h-9 items-center rounded-lg bg-rose-600 px-3.5 text-[12.5px] font-medium text-white hover:bg-rose-500">Restore defaults</button>
        </div>
      </Modal>

      <Modal open={addressOpen} onClose={() => setAddressOpen(false)} id="address-dialog" title="Add a forwarding address">
        <Label text="Email">
          <Input id="address-email" value={address} onValueChange={(value: string) => { setAddress(value); setAddressError(""); }} placeholder="billing@example.com" className={inputClass + (addressError === "" ? "" : " border-rose-300 ring-4 ring-rose-50")} />
        </Label>
        {addressError !== "" && <p id="address-error" className="text-[11.5px] font-medium text-rose-600">{addressError}</p>}
        <div className="flex justify-end gap-2">
          <button id="address-cancel" type="button" onClick={() => setAddressOpen(false)} className="inline-flex h-9 items-center rounded-lg border border-slate-200 px-3.5 text-[12.5px] font-medium text-slate-600 hover:bg-slate-50">Cancel</button>
          <button id="address-save" type="button" onClick={addAddress} className="inline-flex h-9 items-center rounded-lg bg-slate-900 px-3.5 text-[12.5px] font-medium text-white hover:bg-slate-800">Add address</button>
        </div>
      </Modal>
    </div>
  );
}

createRoot(document.getElementById("root")!).render(<App />);
