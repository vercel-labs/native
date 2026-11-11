import { createSignal, onMount } from "solid-js";

export default function App() {
  const [bridge, setBridge] = createSignal("checking...");

  onMount(() => {
    setBridge((window as any).zero ? "available" : "not enabled");
  });

  return (
    <main>
      <p class="eyebrow">Native SDK + Solid</p>
      <h1>Solid</h1>
      <p class="lede">A Solid frontend running inside the system WebView.</p>
      <div class="card">
        <span>Native bridge</span>
        <strong>{bridge()}</strong>
      </div>
    </main>
  );
}
