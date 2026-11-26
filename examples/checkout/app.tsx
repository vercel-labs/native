// Checkout, a three-step order form: account, shipping and payment. Each step validates its
// fields on submit, inline messages name what is missing, and the card and expiry fields format as
// you type. React renders it, Tailwind styles it, and the text fields and buttons come from the UI
// SDK.

import { useState } from "react";
import { createRoot } from "react-dom/client";
import { Button } from "@ui-sdk/react/button";
import { Input } from "@ui-sdk/react/input";

interface Item {
  name: string;
  note: string;
  price: number;
}

const ITEMS: Item[] = [
  { name: "Field notes", note: "Pack of three", price: 1800 },
  { name: "Desk tray", note: "Walnut, small", price: 4200 },
];

const inputBase = "h-11 w-full rounded-lg border bg-white px-3 text-[13.5px] text-slate-800 outline-none placeholder:text-slate-400 focus:ring-4";
const inputOk = "border-slate-200 focus:border-indigo-300 focus:ring-indigo-50";

function money(cents: number): string {
  const dollars = Math.floor(cents / 100);
  const rest = cents % 100;
  return "$" + String(dollars) + "." + (rest < 10 ? "0" : "") + String(rest);
}

function two(n: number): string {
  return n < 10 ? "0" + String(n) : String(n);
}

function App() {
  const [step, setStep] = useState(1);
  const [done, setDone] = useState(false);
  const [invalid, setInvalid] = useState<string[]>([]);

  const [name, setName] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [address, setAddress] = useState("");
  const [city, setCity] = useState("");
  const [zip, setZip] = useState("");
  const [country, setCountry] = useState("United States");
  const [shipping, setShipping] = useState("standard");
  const [card, setCard] = useState("");
  const [expiry, setExpiry] = useState("");
  const [cvc, setCvc] = useState("");
  const [terms, setTerms] = useState(false);
  const [order, setOrder] = useState("");

  function clear(field: string): void {
    if (invalid.indexOf(field) >= 0) setInvalid(invalid.filter((item) => item !== field));
  }

  function errorOf(field: string): string {
    if (field === "name") return name.trim() === "" ? "Enter your full name." : "";
    if (field === "email") return /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email) ? "" : "Enter an email like name@example.com.";
    if (field === "password") return password.length < 8 ? "Use at least 8 characters." : "";
    if (field === "confirm") return confirm !== password ? "The passwords do not match." : "";
    if (field === "address") return address.trim() === "" ? "Enter a street address." : "";
    if (field === "city") return city.trim() === "" ? "Enter a city." : "";
    if (field === "zip") return /^\d{5}$/.test(zip) ? "" : "Enter a five-digit ZIP code.";
    if (field === "card") return /^\d{4} \d{4} \d{4} \d{4}$/.test(card) ? "" : "Enter the 16 digits on the card.";
    if (field === "expiry") {
      if (!/^(0[1-9]|1[0-2])\/\d{2}$/.test(expiry)) return "Use MM/YY.";
      const month = Number(expiry.slice(0, 2));
      const year = 2000 + Number(expiry.slice(3, 5));
      const now = new Date();
      if (year < now.getFullYear() || (year === now.getFullYear() && month < now.getMonth() + 1)) return "That date has passed.";
      return "";
    }
    if (field === "cvc") return /^\d{3,4}$/.test(cvc) ? "" : "Enter the 3 or 4 digit code.";
    if (field === "terms") return terms ? "" : "Accept the terms to continue.";
    return "";
  }

  function validate(fields: string[]): boolean {
    const bad: string[] = [];
    for (const field of fields) if (errorOf(field) !== "") bad.push(field);
    setInvalid(bad);
    if (bad.length === 0) return true;
    const first = document.getElementById(bad[0]);
    if (first !== null) first.focus();
    return false;
  }

  function next(): void {
    const fields = step === 1 ? ["name", "email", "password", "confirm"] : ["address", "city", "zip"];
    if (validate(fields)) setStep(step + 1);
  }

  function back(): void {
    setInvalid([]);
    setStep(step - 1);
  }

  function placeOrder(): void {
    if (!validate(["card", "expiry", "cvc", "terms"])) return;
    setOrder("NS-" + String(Date.now()).slice(-6));
    setDone(true);
  }

  function changeCard(value: string): void {
    const digits = value.replace(/\D/g, "").slice(0, 16);
    let text = "";
    for (let i = 0; i < digits.length; i++) {
      if (i > 0 && i % 4 === 0) text += " ";
      text += digits[i];
    }
    setCard(text);
    clear("card");
  }

  function changeExpiry(value: string): void {
    const digits = value.replace(/\D/g, "").slice(0, 4);
    const text = digits.length > 2 ? digits.slice(0, 2) + "/" + digits.slice(2) : digits;
    setExpiry(text);
    clear("expiry");
  }

  const subtotal = ITEMS.reduce((sum, item) => sum + item.price, 0);
  const ship = shipping === "express" ? 1500 : 500;
  const total = subtotal + ship;

  function field(props: { id: string; label: string; value: string; type?: string; placeholder?: string; change: (value: string) => void }): any {
    const bad = invalid.indexOf(props.id) >= 0;
    return (
      <label className="block">
        <span className="mb-1.5 block text-[12.5px] font-medium text-slate-700">{props.label}</span>
        <Input
          id={props.id}
          type={props.type === undefined ? "text" : props.type}
          value={props.value}
          placeholder={props.placeholder}
          onValueChange={(value: string) => props.change(value)}
          className={inputBase + " " + (bad ? "border-rose-300 ring-4 ring-rose-50 focus:border-rose-400" : inputOk)}
        />
        {bad && <span id={"error-" + props.id} className="mt-1 block text-[11.5px] font-medium text-rose-600">{errorOf(props.id)}</span>}
      </label>
    );
  }

  const stepNames = ["Account", "Shipping", "Payment"];

  if (done) {
    return (
      <div className="flex h-screen items-center justify-center bg-slate-50 font-sans text-slate-900">
        <div id="success" className="w-[440px] rounded-2xl border border-slate-200 bg-white p-8 text-center shadow-sm">
          <span className="mx-auto grid h-12 w-12 place-items-center rounded-full bg-emerald-50 text-2xl text-emerald-600">✓</span>
          <h1 id="placed" className="mt-4 text-xl font-semibold tracking-tight">Order placed</h1>
          <p className="mt-1 text-[13px] text-slate-500">A receipt is on its way to {email}.</p>
          <p id="order-number" className="mt-4 rounded-lg bg-slate-50 py-2 font-mono text-[13px] text-slate-700">{order}</p>
          <Button id="start-over" onClick={() => { setDone(false); setStep(1); setName(""); setEmail(""); setPassword(""); setConfirm(""); setAddress(""); setCity(""); setZip(""); setCard(""); setExpiry(""); setCvc(""); setTerms(false); setInvalid([]); }} className="mt-5 inline-flex h-10 items-center rounded-lg bg-slate-900 px-4 text-[13px] font-medium text-white hover:bg-slate-800">
            Back to the shop
          </Button>
        </div>
      </div>
    );
  }

  return (
    <div className="flex h-screen bg-slate-50 font-sans text-slate-900">
      <main className="flex min-w-0 flex-1 flex-col">
        <header className="flex h-16 shrink-0 items-center gap-3 border-b border-slate-200 bg-white px-8">
          <div className="grid h-8 w-8 place-items-center rounded-lg bg-slate-900 text-[13px] font-bold text-white">N</div>
          <div>
            <h1 className="text-[16px] font-semibold tracking-tight">Checkout</h1>
            <p className="text-[11.5px] text-slate-500">{stepNames[step - 1]} · step {step} of 3</p>
          </div>
          <p id="secure" className="ml-auto text-[11.5px] text-slate-400">Secure payment</p>
        </header>

        <div className="flex min-h-0 flex-1">
          <section className="min-w-0 flex-1 overflow-y-auto px-8 py-7">
            <div className="mx-auto max-w-[520px]">
              <div id="step-indicator" className="mb-6 flex items-center gap-2">
                {stepNames.map((title, index) => {
                  const number = index + 1;
                  const active = number === step;
                  const passed = number < step;
                  return (
                    <div key={title} className="flex items-center gap-2">
                      {index > 0 && <span className={"h-px w-8 " + (passed ? "bg-emerald-400" : "bg-slate-200")} />}
                      <span className={"grid h-6 w-6 place-items-center rounded-full text-[11px] font-semibold " + (passed ? "bg-emerald-500 text-white" : active ? "bg-slate-900 text-white" : "bg-slate-200 text-slate-500")}>
                        {passed ? "✓" : String(number)}
                      </span>
                      <span className={"text-[12px] " + (active ? "font-medium text-slate-800" : "text-slate-500")}>{title}</span>
                    </div>
                  );
                })}
              </div>

              {step === 1 && (
                <form onSubmit={(event: any) => { event.preventDefault(); next(); }} className="space-y-4">
                  <h2 className="text-[20px] font-semibold tracking-tight">Create your account</h2>
                  <p className="text-[12.5px] text-slate-500">We send the receipt and tracking here.</p>
                  {field({ id: "name", label: "Full name", value: name, placeholder: "Robin Avery", change: (value: string) => { setName(value); clear("name"); } })}
                  {field({ id: "email", label: "Email", value: email, type: "email", placeholder: "robin@example.com", change: (value: string) => { setEmail(value); clear("email"); } })}
                  {field({ id: "password", label: "Password", value: password, type: "password", placeholder: "At least 8 characters", change: (value: string) => { setPassword(value); clear("password"); } })}
                  {field({ id: "confirm", label: "Confirm password", value: confirm, type: "password", placeholder: "Type it again", change: (value: string) => { setConfirm(value); clear("confirm"); } })}
                  <div className="pt-2">
                    <Button id="continue" onClick={next} className="inline-flex h-11 w-full items-center justify-center rounded-lg bg-indigo-600 text-[13.5px] font-medium text-white shadow-sm hover:bg-indigo-500">
                      Continue to shipping
                    </Button>
                  </div>
                </form>
              )}

              {step === 2 && (
                <form onSubmit={(event: any) => { event.preventDefault(); next(); }} className="space-y-4">
                  <h2 className="text-[20px] font-semibold tracking-tight">Where should it go?</h2>
                  <p className="text-[12.5px] text-slate-500">Street address, city and ZIP for the carrier.</p>
                  {field({ id: "address", label: "Street address", value: address, placeholder: "18 Juniper Way", change: (value: string) => { setAddress(value); clear("address"); } })}
                  <div className="grid grid-cols-2 gap-4">
                    {field({ id: "city", label: "City", value: city, placeholder: "Portland", change: (value: string) => { setCity(value); clear("city"); } })}
                    {field({ id: "zip", label: "ZIP code", value: zip, placeholder: "97205", change: (value: string) => { setZip(value.replace(/\D/g, "").slice(0, 5)); clear("zip"); } })}
                  </div>
                  <label className="block">
                    <span className="mb-1.5 block text-[12.5px] font-medium text-slate-700">Country</span>
                    <select id="country" value={country} onChange={(event: any) => setCountry(String(event.target.value))} className={inputBase + " " + inputOk}>
                      <option>United States</option>
                      <option>Canada</option>
                      <option>United Kingdom</option>
                      <option>Germany</option>
                    </select>
                  </label>
                  <fieldset className="rounded-xl border border-slate-200 bg-white p-3">
                    <legend className="px-1 text-[12.5px] font-medium text-slate-700">Delivery</legend>
                    <label className="flex items-center gap-3 rounded-lg px-2 py-2 hover:bg-slate-50">
                      <input id="ship-standard" type="radio" name="shipping" checked={shipping === "standard"} onChange={() => setShipping("standard")} />
                      <span className="flex-1 text-[13px] text-slate-700">Standard · 3–5 days</span>
                      <span className="text-[12.5px] text-slate-500">$5.00</span>
                    </label>
                    <label className="flex items-center gap-3 rounded-lg px-2 py-2 hover:bg-slate-50">
                      <input id="ship-express" type="radio" name="shipping" checked={shipping === "express"} onChange={() => setShipping("express")} />
                      <span className="flex-1 text-[13px] text-slate-700">Express · next day</span>
                      <span className="text-[12.5px] text-slate-500">$15.00</span>
                    </label>
                  </fieldset>
                  <div className="flex gap-3 pt-2">
                    <button id="back" type="button" onClick={back} className="inline-flex h-11 items-center justify-center rounded-lg border border-slate-200 bg-white px-4 text-[13px] font-medium text-slate-600 hover:bg-slate-50">
                      Back
                    </button>
                    <Button id="continue" onClick={next} className="inline-flex h-11 flex-1 items-center justify-center rounded-lg bg-indigo-600 text-[13.5px] font-medium text-white shadow-sm hover:bg-indigo-500">
                      Continue to payment
                    </Button>
                  </div>
                </form>
              )}

              {step === 3 && (
                <form onSubmit={(event: any) => { event.preventDefault(); placeOrder(); }} className="space-y-4">
                  <h2 className="text-[20px] font-semibold tracking-tight">Payment</h2>
                  <p className="text-[12.5px] text-slate-500">Nothing is charged until you place the order.</p>
                  {field({ id: "card", label: "Card number", value: card, placeholder: "4242 4242 4242 4242", change: changeCard })}
                  <div className="grid grid-cols-2 gap-4">
                    {field({ id: "expiry", label: "Expiry", value: expiry, placeholder: "MM/YY", change: changeExpiry })}
                    {field({ id: "cvc", label: "CVC", value: cvc, placeholder: "123", change: (value: string) => { setCvc(value.replace(/\D/g, "").slice(0, 4)); clear("cvc"); } })}
                  </div>
                  <label className="flex items-start gap-3 rounded-xl border border-slate-200 bg-white p-3">
                    <input id="terms" type="checkbox" checked={terms} onChange={() => { setTerms(!terms); clear("terms"); }} className="mt-0.5" />
                    <span className="text-[12.5px] text-slate-600">I agree to the terms and the privacy policy.</span>
                  </label>
                  {invalid.indexOf("terms") >= 0 && <p id="error-terms" className="text-[11.5px] font-medium text-rose-600">{errorOf("terms")}</p>}
                  <div className="flex gap-3 pt-2">
                    <button id="back" type="button" onClick={back} className="inline-flex h-11 items-center justify-center rounded-lg border border-slate-200 bg-white px-4 text-[13px] font-medium text-slate-600 hover:bg-slate-50">
                      Back
                    </button>
                    <Button id="place-order" onClick={placeOrder} className="inline-flex h-11 flex-1 items-center justify-center rounded-lg bg-slate-900 text-[13.5px] font-medium text-white shadow-sm hover:bg-slate-800">
                      Place order · {money(total)}
                    </Button>
                  </div>
                </form>
              )}
            </div>
          </section>

          <aside className="w-[380px] shrink-0 border-l border-slate-200 bg-white px-7 py-7">
            <h2 className="text-[13px] font-semibold uppercase tracking-wider text-slate-500">Order summary</h2>
            <ul className="mt-4 space-y-3">
              {ITEMS.map((item) => (
                <li key={item.name} className="flex items-center gap-3">
                  <span className="grid h-10 w-10 place-items-center rounded-lg bg-slate-100 text-[11px] font-semibold text-slate-500">NS</span>
                  <span className="flex-1">
                    <span className="block text-[13px] font-medium text-slate-800">{item.name}</span>
                    <span className="block text-[11.5px] text-slate-500">{item.note}</span>
                  </span>
                  <span className="text-[12.5px] text-slate-700">{money(item.price)}</span>
                </li>
              ))}
            </ul>
            <div className="mt-5 space-y-2 border-t border-slate-100 pt-4 text-[12.5px]">
              <p className="flex justify-between text-slate-500"><span>Subtotal</span><span>{money(subtotal)}</span></p>
              <p className="flex justify-between text-slate-500"><span>Shipping</span><span>{money(ship)}</span></p>
              <p id="summary-total" className="flex justify-between pt-1 text-[14px] font-semibold text-slate-900"><span>Total</span><span>{money(total)}</span></p>
            </div>
            <p className="mt-6 text-[11px] leading-relaxed text-slate-400">Fields are checked as you leave a step; the card number groups in fours and the expiry takes MM/YY.</p>
          </aside>
        </div>
      </main>
    </div>
  );
}

createRoot(document.getElementById("root")!).render(<App />);
