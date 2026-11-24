// Settings, a form-heavy app: a tabbed set of panels for a profile, email
// preferences, security and billing. React 19 renders it, Tailwind 4 styles it,
// and the buttons and switches come from the UI SDK.

import { useEffect, useRef, useState } from "react";
import type { ReactNode } from "react";
import { createRoot } from "react-dom/client";
import { Button } from "@ui-sdk/react/button";
import { Switch, SwitchThumb } from "@ui-sdk/react/switch";
import {
  IconBell,
  IconCamera,
  IconCard,
  IconCheck,
  IconChevron,
  IconLaptop,
  IconLock,
  IconShield,
  IconUser,
} from "./icons";

const inputClass = "h-10 w-full rounded-lg border border-slate-200 bg-white px-3 text-sm text-slate-800 outline-none placeholder:text-slate-400 focus:border-indigo-300 focus:ring-4 focus:ring-indigo-50";

function Avatar(props: { initials: string; className: string }) {
  return <span className={"grid place-items-center rounded-full font-semibold text-white " + props.className}>{props.initials}</span>;
}

function Row(props: { title: string; description: string; control: ReactNode }) {
  return (
    <div className="flex items-start justify-between gap-6 py-4">
      <div className="min-w-0">
        <p className="text-[13px] font-medium text-slate-800">{props.title}</p>
        <p className="mt-0.5 text-xs leading-relaxed text-slate-500">{props.description}</p>
      </div>
      <div className="shrink-0 pt-0.5">{props.control}</div>
    </div>
  );
}

function SwitchRow(props: { id: string; title: string; description: string; checked: boolean; onCheckedChange: (next: boolean) => void }) {
  return (
    <Row
      title={props.title}
      description={props.description}
      control={
        <Switch id={props.id} checked={props.checked} onCheckedChange={(next: boolean) => props.onCheckedChange(next)} className="inline-flex h-6 w-11 shrink-0 items-center rounded-full bg-slate-200 p-0.5 data-[checked]:bg-indigo-600">
          <SwitchThumb className="block h-5 w-5 rounded-full bg-white shadow-sm transition-transform data-[checked]:translate-x-5" />
        </Switch>
      }
    />
  );
}

function Section(props: { title: string; description: string; children: ReactNode }) {
  return (
    <section className="border-b border-slate-100 px-6 py-5 last:border-b-0">
      <h2 className="text-sm font-semibold text-slate-800">{props.title}</h2>
      <p className="mt-0.5 text-xs text-slate-500">{props.description}</p>
      <div className="mt-4">{props.children}</div>
    </section>
  );
}

/** A text field: a controlled input whose value the page owns. */
function TextInput(props: { id?: string; type?: string; value?: string; defaultValue?: string; placeholder?: string; className?: string; onValueChange?: (value: string) => void }) {
  return (
    <input
      id={props.id}
      type={props.type === undefined ? "text" : props.type}
      value={props.value}
      defaultValue={props.defaultValue}
      placeholder={props.placeholder}
      className={props.className}
      onInput={(event: any) => { if (props.onValueChange !== undefined) props.onValueChange(String(event.target.value)); }}
    />
  );
}

/** A modal dialog: the page's own dialog element, opened with showModal(). */
function Modal(props: { open: boolean; onClose: () => void; children: ReactNode }) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const dialog = ref.current;
    if (dialog === null) return;
    if (props.open && !dialog.open) dialog.showModal();
    if (!props.open && dialog.open) dialog.close();
  }, [props.open]);
  return (
    <dialog ref={ref} onClose={props.onClose} className="m-auto w-[440px] rounded-2xl bg-white p-0 shadow-2xl outline-none backdrop:bg-slate-950/40">
      <div className="flex flex-col gap-4 p-6">{props.children}</div>
    </dialog>
  );
}

function App() {
  const [tab, setTab] = useState("profile");
  const [status, setStatus] = useState("All changes saved");
  const [photoOpen, setPhotoOpen] = useState(false);
  const [photo, setPhoto] = useState("CT");
  const [planOpen, setPlanOpen] = useState(false);
  const [plan, setPlan] = useState("Team");
  const [twoFactor, setTwoFactor] = useState(false);
  const [confirmOpen, setConfirmOpen] = useState(false);
  const [product, setProduct] = useState(true);
  const [securityMail, setSecurityMail] = useState(true);
  const [weekly, setWeekly] = useState(true);
  const [mentions, setMentions] = useState(false);
  const [criticalOnly, setCriticalOnly] = useState(false);
  const [name, setName] = useState("Chris Tate");
  const [email, setEmail] = useState("chris@example.com");
  const [timezone, setTimezone] = useState("America/Los_Angeles");

  function save(what: string) {
    setStatus(what + " saved just now");
  }

  return (
    <div className="flex h-screen flex-col bg-slate-100 font-sans text-slate-900">
      <header className="flex h-16 shrink-0 items-center gap-4 border-b border-slate-200 bg-white px-8">
        <button type="button" className="grid h-8 w-8 place-items-center rounded-lg border border-slate-200 text-slate-500 hover:text-slate-700">
          <IconChevron className="h-4 w-4 rotate-180" />
        </button>
        <div>
          <h1 className="text-[17px] font-semibold tracking-tight">Settings</h1>
          <p className="text-[11px] text-slate-500">Workspace preferences for Northstar</p>
        </div>
        <p id="state" className="ml-auto mr-2 text-xs text-slate-500">{status}</p>
        <Button onClick={() => save("Settings")} className="inline-flex h-9 items-center rounded-lg bg-indigo-600 px-4 text-sm font-medium text-white shadow-sm hover:bg-indigo-500">
          Save changes
        </Button>
      </header>

      <main className="min-h-0 flex-1 overflow-y-auto px-8 py-6">
        <div className="mx-auto max-w-4xl">
          <div>
            <div role="tablist" aria-label="Settings sections" className="inline-flex items-center gap-1 rounded-xl bg-white p-1 shadow-sm ring-1 ring-slate-200">
              <button type="button" role="tab" id="tab-profile" onClick={() => setTab("profile")} aria-selected={tab === "profile"} className={"flex items-center gap-2 rounded-lg px-3.5 py-2 text-[13px] font-medium " + (tab === "profile" ? "bg-slate-900 text-white" : "text-slate-500 hover:text-slate-800")}>
                <IconUser className="h-4 w-4" /> Profile
              </button>
              <button type="button" role="tab" id="tab-notifications" onClick={() => setTab("notifications")} aria-selected={tab === "notifications"} className={"flex items-center gap-2 rounded-lg px-3.5 py-2 text-[13px] font-medium " + (tab === "notifications" ? "bg-slate-900 text-white" : "text-slate-500 hover:text-slate-800")}>
                <IconBell className="h-4 w-4" /> Notifications
              </button>
              <button type="button" role="tab" id="tab-security" onClick={() => setTab("security")} aria-selected={tab === "security"} className={"flex items-center gap-2 rounded-lg px-3.5 py-2 text-[13px] font-medium " + (tab === "security" ? "bg-slate-900 text-white" : "text-slate-500 hover:text-slate-800")}>
                <IconLock className="h-4 w-4" /> Security
              </button>
              <button type="button" role="tab" id="tab-billing" onClick={() => setTab("billing")} aria-selected={tab === "billing"} className={"flex items-center gap-2 rounded-lg px-3.5 py-2 text-[13px] font-medium " + (tab === "billing" ? "bg-slate-900 text-white" : "text-slate-500 hover:text-slate-800")}>
                <IconCard className="h-4 w-4" /> Billing
              </button>
            </div>

            {tab === "profile" && (<div className="mt-4 overflow-hidden rounded-2xl bg-white shadow-sm ring-1 ring-slate-200">
              <Section title="Profile" description="How you appear to people in this workspace.">
                <div className="flex items-center gap-5">
                  <Avatar initials={photo} className="h-16 w-16 bg-gradient-to-br from-amber-400 to-rose-500 text-lg" />
                  <div>
                    <p className="text-[13px] font-medium text-slate-800">Profile photo</p>
                    <p className="mt-0.5 text-xs text-slate-500">PNG or JPG, at least 256 px square.</p>
                    <button type="button" onClick={() => setPhotoOpen(true)} className="mt-2 inline-flex items-center gap-1.5 rounded-lg border border-slate-200 bg-white px-3 py-1.5 text-xs font-medium text-slate-600 hover:bg-slate-50">
                      <IconCamera className="h-3.5 w-3.5" /> Change photo
                    </button>
                  </div>
                </div>
                <div className="mt-6 grid grid-cols-2 gap-4">
                  <div>
                    <label className="mb-1.5 block text-[13px] font-medium text-slate-700">Full name</label>
                    <TextInput id="name" value={name} onValueChange={(value: string) => setName(value)} className={inputClass} />
                  </div>
                  <div>
                    <label className="mb-1.5 block text-[13px] font-medium text-slate-700">Email</label>
                    <TextInput id="email" value={email} onValueChange={(value: string) => setEmail(value)} className={inputClass} />
                    <p className="mt-1.5 block text-xs text-slate-500">Used for sign-in and receipts.</p>
                  </div>
                  <div>
                    <label className="mb-1.5 block text-[13px] font-medium text-slate-700">Role</label>
                    <TextInput defaultValue="Engineering lead" className={inputClass} />
                  </div>
                  <div>
                    <label className="mb-1.5 block text-[13px] font-medium text-slate-700">Timezone</label>
                    <select id="timezone" value={timezone} onChange={(event) => { const target: any = event.target; setTimezone(String(target.value)); }} className={inputClass}>
                      <option value="America/Los_Angeles">Pacific Time (US)</option>
                      <option value="America/New_York">Eastern Time (US)</option>
                      <option value="Europe/London">London</option>
                      <option value="Asia/Tokyo">Tokyo</option>
                    </select>
                  </div>
                </div>
                <div>
                  <label className="mb-1.5 mt-4 block text-[13px] font-medium text-slate-700">Bio</label>
                  <textarea id="bio" defaultValue="Building fast, small apps for the web and the desktop." className="min-h-24 w-full rounded-lg border border-slate-200 bg-white px-3 py-2 text-sm text-slate-800 outline-none focus:border-indigo-300 focus:ring-4 focus:ring-indigo-50"></textarea>
                  <p className="mt-1.5 block text-xs text-slate-500">A sentence or two shown on your profile.</p>
                </div>
                <div className="mt-5 flex justify-end">
                  <Button onClick={() => save("Profile")} className="inline-flex h-9 items-center rounded-lg bg-slate-900 px-4 text-sm font-medium text-white hover:bg-slate-800">
                    Save profile
                  </Button>
                </div>
              </Section>
            </div>)}

            {tab === "notifications" && (<div className="mt-4 overflow-hidden rounded-2xl bg-white shadow-sm ring-1 ring-slate-200">
              <Section title="Email notifications" description="Choose what reaches your inbox.">
                <div className="divide-y divide-slate-100">
                  <SwitchRow id="switch-product" title="Product updates" description="New features and improvements, at most twice a month." checked={product} onCheckedChange={(next) => { setProduct(next); setStatus("Product updates " + (next ? "on" : "off")); }} />
                  <SwitchRow id="switch-security" title="Security alerts" description="Sign-ins from new devices and changes to your account." checked={securityMail} onCheckedChange={(next) => { setSecurityMail(next); setStatus("Security alerts " + (next ? "on" : "off")); }} />
                  <SwitchRow id="switch-weekly" title="Weekly digest" description="A Monday summary of projects, deploys and incidents." checked={weekly} onCheckedChange={(next) => { setWeekly(next); setStatus("Weekly digest " + (next ? "on" : "off")); }} />
                  <SwitchRow id="switch-mentions" title="Mentions" description="When someone mentions you in a comment." checked={mentions} onCheckedChange={(next) => { setMentions(next); setStatus("Mentions " + (next ? "on" : "off")); }} />
                </div>
                <div className="mt-4">
                  <SwitchRow id="critical-only" title="Critical emails only" description="Hold every non-essential email while I'm on call." checked={criticalOnly} onCheckedChange={(next) => { setCriticalOnly(next); setStatus("Critical only " + (next ? "on" : "off")); }} />
                </div>
              </Section>
            </div>)}

            {tab === "security" && (<div className="mt-4 overflow-hidden rounded-2xl bg-white shadow-sm ring-1 ring-slate-200">
              <Section title="Password" description="Use at least 12 characters and a password manager.">
                <div className="grid grid-cols-2 gap-4">
                  <div>
                    <label className="mb-1.5 block text-[13px] font-medium text-slate-700">Current password</label>
                    <TextInput type="password" defaultValue="correct-horse" className={inputClass} />
                  </div>
                  <div>
                    <label className="mb-1.5 block text-[13px] font-medium text-slate-700">New password</label>
                    <TextInput type="password" placeholder="••••••••••••" className={inputClass} />
                  </div>
                </div>
                <div className="mt-4 flex justify-end">
                  <Button onClick={() => save("Password")} className="inline-flex h-9 items-center rounded-lg bg-slate-900 px-4 text-sm font-medium text-white hover:bg-slate-800">
                    Update password
                  </Button>
                </div>
              </Section>
              <Section title="Two-factor authentication" description="A second step at sign-in, from an authenticator app.">
                <Row
                  title={twoFactor ? "Two-factor is on" : "Two-factor is off"}
                  description={twoFactor ? "Authenticator codes are required to sign in." : "Add an authenticator app to protect this account."}
                  control={
                    twoFactor ? (
                      <span className="inline-flex items-center gap-1.5 rounded-full bg-emerald-50 px-2.5 py-1 text-[11px] font-medium text-emerald-700 ring-1 ring-emerald-200">
                        <IconCheck className="h-3.5 w-3.5" /> Enabled
                      </span>
                    ) : (
                      <button id="enable-2fa" type="button" onClick={() => setConfirmOpen(true)} className="inline-flex h-9 items-center gap-1.5 rounded-lg bg-slate-900 px-3.5 text-sm font-medium text-white hover:bg-slate-800">
                        <IconShield className="h-4 w-4" /> Enable
                      </button>
                    )
                  }
                />
              </Section>
              <Section title="Active sessions" description="Devices signed in to this account.">
                <ul className="divide-y divide-slate-100">
                  <li className="flex items-center gap-3 py-3">
                    <span className="grid h-9 w-9 place-items-center rounded-lg bg-emerald-50 text-emerald-600"><IconLaptop className="h-4 w-4" /></span>
                    <div className="flex-1">
                      <p className="text-[13px] font-medium text-slate-700">MacBook Pro · this device</p>
                      <p className="text-[11px] text-slate-400">San Francisco · current session</p>
                    </div>
                    <span className="text-[11px] font-medium text-emerald-600">Active</span>
                  </li>
                  <li className="flex items-center gap-3 py-3">
                    <span className="grid h-9 w-9 place-items-center rounded-lg bg-slate-100 text-slate-500"><IconLaptop className="h-4 w-4" /></span>
                    <div className="flex-1">
                      <p className="text-[13px] font-medium text-slate-700">iPhone 17 · Safari</p>
                      <p className="text-[11px] text-slate-400">San Francisco · 2 hours ago</p>
                    </div>
                    <button type="button" onClick={() => setStatus("Signed out the iPhone")} className="rounded-lg border border-slate-200 px-2.5 py-1 text-[11px] font-medium text-slate-600 hover:bg-slate-50">Sign out</button>
                  </li>
                </ul>
              </Section>
            </div>)}

            {tab === "billing" && (<div className="mt-4 overflow-hidden rounded-2xl bg-white shadow-sm ring-1 ring-slate-200">
              <Section title="Plan" description="Your workspace is on the Team plan.">
                <div className="flex items-center justify-between rounded-xl bg-gradient-to-br from-indigo-500 to-violet-600 p-5 text-white">
                  <div>
                    <p className="text-[11px] uppercase tracking-wide text-indigo-100">Current plan</p>
                    <p className="mt-1 text-2xl font-semibold tracking-tight">{plan}</p>
                    <p className="mt-1 text-xs text-indigo-100">$40 per member, per month · billed monthly</p>
                  </div>
                  <button type="button" onClick={() => setPlanOpen(true)} className="rounded-lg bg-white/15 px-3.5 py-2 text-sm font-medium text-white ring-1 ring-white/25 hover:bg-white/20">Change plan</button>
                </div>
                <div className="mt-5">
                  <div className="flex items-center justify-between text-xs">
                    <span className="font-medium text-slate-700">Edge requests</span>
                    <span className="text-slate-500">8.6M of 10M</span>
                  </div>
                  <div className="mt-2 h-2 w-full overflow-hidden rounded-full bg-slate-100"><div className="h-full w-[86%] rounded-full bg-indigo-500" /></div>
                  <p className="mt-2 text-[11px] text-slate-500">Resets on the 1st. Usage over the limit is billed at $0.40 per million requests.</p>
                </div>
              </Section>
              <Section title="Payment method" description="The card charged each month.">
                <div className="flex items-center gap-3 rounded-xl border border-slate-200 p-3.5">
                  <span className="grid h-9 w-12 place-items-center rounded-md bg-slate-900 text-[10px] font-semibold text-white">VISA</span>
                  <div className="flex-1">
                    <p className="text-[13px] font-medium text-slate-700">Visa ending 4242</p>
                    <p className="text-[11px] text-slate-400">Expires 08 / 28</p>
                  </div>
                  <button type="button" onClick={() => setStatus("Opened payment settings")} className="rounded-lg border border-slate-200 px-2.5 py-1 text-[11px] font-medium text-slate-600 hover:bg-slate-50">Update</button>
                </div>
              </Section>
            </div>)}
        </div>
        </div>
      </main>

      <Modal open={photoOpen} onClose={() => setPhotoOpen(false)}>
        <div>
          <h2 className="text-lg font-semibold tracking-tight">Change profile photo</h2>
          <p className="mt-1 text-sm text-slate-500">Pick one of these, or drop a PNG or JPG into the window.</p>
        </div>
        <div className="grid grid-cols-4 gap-3">
          {[["CT", "from-amber-400 to-rose-500"], ["NS", "from-indigo-500 to-violet-600"], ["ED", "from-emerald-400 to-teal-600"], ["AY", "from-sky-400 to-blue-600"]].map((choice) => (
            <button key={choice[0]} type="button" onClick={() => { setPhoto(choice[0]); setPhotoOpen(false); setStatus("Photo updated"); }} className={"grid h-16 place-items-center rounded-xl bg-gradient-to-br text-sm font-semibold text-white ring-2 ring-transparent hover:ring-indigo-400 " + choice[1]}>{choice[0]}</button>
          ))}
        </div>
        <div className="flex justify-end">
          <button type="button" onClick={() => setPhotoOpen(false)} className="inline-flex h-9 items-center rounded-lg border border-slate-200 px-3.5 text-sm font-medium text-slate-600 hover:bg-slate-50">Cancel</button>
        </div>
      </Modal>

      <Modal open={confirmOpen} onClose={() => setConfirmOpen(false)}>
        <div>
          <h2 className="text-lg font-semibold tracking-tight">Enable two-factor authentication?</h2>
          <p className="mt-1 text-sm leading-relaxed text-slate-500">You'll need an authenticator app. The next time you sign in, enter the six-digit code it shows.</p>
        </div>
        <div className="flex justify-end gap-2">
          <button type="button" onClick={() => setConfirmOpen(false)} className="inline-flex h-9 items-center rounded-lg border border-slate-200 px-3.5 text-sm font-medium text-slate-600 hover:bg-slate-50">Not now</button>
          <Button id="confirm-2fa" onClick={() => { setTwoFactor(true); setConfirmOpen(false); setStatus("Two-factor authentication on"); }} className="inline-flex h-9 items-center rounded-lg bg-slate-900 px-3.5 text-sm font-medium text-white hover:bg-slate-800">Turn on two-factor</Button>
        </div>
      </Modal>

      <Modal open={planOpen} onClose={() => setPlanOpen(false)}>
        <div>
          <h2 className="text-lg font-semibold tracking-tight">Change plan</h2>
          <p className="mt-1 text-sm text-slate-500">Change the plan for every member of this workspace.</p>
        </div>
        <div className="flex flex-col gap-2">
          {[
            { name: "Starter", price: "$0", note: "3 projects, community support" },
            { name: "Team", price: "$40", note: "Unlimited projects, edge network" },
            { name: "Enterprise", price: "$120", note: "SSO, audit log, priority support" },
          ].map((option) => (
            <button
              key={option.name}
              type="button"
              onClick={() => setPlan(option.name)}
              className={"flex items-center justify-between rounded-xl border px-4 py-3 text-left " + (plan === option.name ? "border-indigo-300 bg-indigo-50/70 ring-1 ring-indigo-200" : "border-slate-200 hover:border-slate-300")}
            >
              <span>
                <span className="block text-sm font-medium text-slate-800">{option.name}</span>
                <span className="text-[11px] text-slate-500">{option.note}</span>
              </span>
              <span className="text-sm font-semibold text-slate-700">{option.price}<span className="text-[11px] font-normal text-slate-400">/mo</span></span>
            </button>
          ))}
        </div>
        <div className="flex justify-end gap-2">
          <button type="button" onClick={() => setPlanOpen(false)} className="inline-flex h-9 items-center rounded-lg border border-slate-200 px-3.5 text-sm font-medium text-slate-600 hover:bg-slate-50">Cancel</button>
          <Button onClick={() => { setPlanOpen(false); save("Plan"); }} className="inline-flex h-9 items-center rounded-lg bg-indigo-600 px-3.5 text-sm font-medium text-white hover:bg-indigo-500">Update plan</Button>
        </div>
      </Modal>
    </div>
  );
}

createRoot(document.getElementById("root")!).render(<App />);
