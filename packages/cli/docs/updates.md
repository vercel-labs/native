# Updates

An app can check for a newer version without anyone shipping an update framework: it names an
update document in its web app manifest, and the page reads it the way a page reads a service
worker's update. The check is opt-in — an app with no `update_url` makes no request — and a build
writes the URL and the app's own version into the bundle, so the runtime needs no configuration.

## Opting in

```html
<link rel="manifest" href="app.webmanifest">
```

```json
{
  "name": "Notes",
  "short_name": "Notes",
  "version": "1.4.0",
  "update_url": "https://updates.example.com/notes.json"
}
```

`version` is the version the build is; `update_url` is an absolute `https:` (or `http:`) URL. The
build copies both into `.native/update.json` in the bundle (a release build's `.native/app.json`
answers first when it has one), and a build whose manifest drops `update_url` deletes the file.
A dev build has no bundle, so it never checks.

The URL names a document like this:

```json
{
  "version": "1.5.0",
  "url": "https://updates.example.com/Notes-1.5.0.dmg",
  "notes": "Fixes the sort order."
}
```

`version` is compared with the app's own version, numerically and in three parts; a prerelease
(`1.5.0-beta.1`) is older than its release. `url` is where the update's artifact lives (it can be
omitted, in which case the update document's own URL is reported), and `notes` is free text for
the page.

## The API

The check is exposed as a subset of the Service Worker API, because that is how the web exposes
"a newer version is ready":

```ts
const registration = await navigator.serviceWorker.getRegistration();
if (registration !== null && registration !== undefined) {
  registration.addEventListener("updatefound", () => {
    const update = registration.installing;   // "installing" while the document is read
    update?.addEventListener("statechange", () => {
      // "installed": the newer version is known; the registration's waiting worker names it.
      const waiting = registration.waiting;
      if (waiting !== null && waiting.state === "installed") {
        banner.textContent = "A new version is available: " + waiting.scriptURL;
      }
    });
  });
  await registration.update();   // check now; rejects on a network or document error
}
```

- `navigator.serviceWorker.ready` resolves to the registration when the app opted in; with no
  `update_url` it stays pending, as a browser's does with no registration.
- `getRegistration()` resolves to the registration or `undefined`; `getRegistrations()` returns the
  one-element list.
- `registration.update()` fetches the document and resolves when it is read. A version that is
  newer creates a `ServiceWorker`: its state goes `installing` → `installed`, `updatefound` fires,
  and it becomes `registration.waiting`. Its `scriptURL` is the artifact's URL. A version that
  isn't newer changes nothing.
- `registration.active` is the running version, state `activated`. `registration.scope` is the
  app's opaque `file:///` scope.
- `register()` rejects: the app is its own worker, and there is no script to register.
- Workers fire `statechange` and accept `postMessage()`; the events' `target` is null because the
  runtime's events are dispatched at DOM nodes, and a registration is not one. A listener reaches
  its registration through the closure that added it.

The check runs once a couple of seconds after the page loads and again every six hours; a page can
call `update()` whenever it likes. A failed automatic check is silent, and a failed manual
`update()` rejects.

## The next stage: downloading and installing

This first implementation stops at "a newer version exists", which is the part a page can act on
without executing anything. The install stage is designed to keep the same API:

1. The document gains `sha256` for its artifact (and, later, per-platform `artifacts` entries).
   A check downloads the artifact for the running platform (`waiting.scriptURL`), verifies the
   digest, and writes it to a staging directory beside the app; the worker's `installed` state
   then means the artifact is on disk.
2. `registration.waiting.postMessage({ type: "SKIP_WAITING" })` marks the staged update as the one
   to apply. On the next launch the app replaces itself: on macOS a detached helper waits for the
   process to exit, swaps the `.app` and reopens it; a Linux AppImage is replaced by renaming the
   staged file over it. `controllerchange` fires when the new version becomes active.
3. On macOS the staged app must carry its Developer ID signature and notarization; the update
   document's digest covers the bytes that were downloaded, and the code signature is what makes
   them a version of this app rather than any file the server sends.

Until that stage lands, the check downloads only the JSON document. It never fetches the artifact
and never runs anything from the server, so an update document that lies can at most mislead the
page's banner. A server that serves the document is still trusted to name the right version; the
`https:` requirement is what protects that connection.
