# Known compiler limitations

Native SDK compiles your app's TypeScript, and its own runtime, with [scriptc](https://scriptc.dev). scriptc supports a large part of TypeScript and Node.js, but it isn't yet at full parity. The CLI's `check` command reports the HTML, CSS and DOM an app uses that isn't supported; this page covers compiler gaps that can stop a build or change how an app behaves at runtime.

Most gaps are in the internals of libraries rather than in app code. Each item below gives the workaround to use until the compiler handles the pattern. If one blocks you and no workaround fits, open an issue with a small repro.

## Type checking

Every file in a build is type-checked, including JavaScript files in your dependencies.

- **Untyped JavaScript can be refused around typed values.** A value that reaches one of the SDK's typed objects can't be passed on untyped (`SC7005`). Add JSDoc types to the values at the boundary, or keep the untyped code behind a typed wrapper.
- **JSDoc types must be complete.** A bare `{Array}`, `{Promise}` or `{Set}` is an error where `tsc` accepts it (`SC0001`); write `{Array<unknown>}`, `{Promise<void>}`, and so on. `@readonly` on a getter is also an error.
- **JSDoc that names a DOM class is applied.** `@param {Image}` and similar annotations are checked against the class the build's type world uses for the name: the browser's when a dependency's declarations reference `lib.dom` (as Preact's do), otherwise the runtime's own. A name the file also uses as a value is the runtime's class.
- **An `any` object literal keeps the shape it was written with.** A field assigned after the literal is refused (`SC1090`). Put the field in the literal or declare an interface for the object.
- **A type import whose name is also a DOM global conflicts.** The runtime declares `DragEvent`, `KeyboardEvent`, `MouseEvent` and the rest, so `import type { DragEvent } from "react"` reports a duplicate identifier (`SC0001`) and the type can't take a generic argument. Alias it: `import type { DragEvent as ReactDragEvent } from "react"`. Naming the global without an import works.
- **A callback whose result is a typed array or record of records can't cross a generic boundary.** A `useMemo` or `useCallback` that returns `Issue[]` or `{ open: number; done: number }` is refused (`SC1090`, "re-materialized when the boxed function returns it"). Compute the value directly in the component, or keep the result in a primitive.

## Classes

- **A class can't extend a conditional expression, or a class returned from a helper that adds static members** (`SC1090`). Custom-element helpers built this way don't compile; define a plain class and extend it directly.
- **Static members can't be read through a class value.** `constructor.observedAttributes` and `Reflect.get(SomeClass, "name")` answer `undefined` (`SC1090`). Keep the value in a side table, or pass the class value as `any`.
- **`this` in a static block is refused** (`SC1090`). Move the initialization into a static method or module-level code.
- **A constructor that returns an object only compiles at the top level** (`SC1090`). Call such a factory without `new`, or return `this`.
- **Prototype reflection isn't supported.** `Object.create(SomeClass.prototype)`, `setPrototypeOf`, `getPrototypeOf` and `isPrototypeOf` don't reflect as they do in Node (`SC1090`). Avoid re-prototyping objects.
- **A class value typed as an array can lose its methods** when it is reached through the array type (`SC0001`, or a runtime throw). Keep the class-typed reference and call the method on it.
- **A class can't declare a numeric index signature** (`SC1090`). Extend `Array` if a class needs `list[0]`, as the DOM's list types do.
- **Accessor types can't differ between a class and its subclass, or between a getter and its setter** (`SC1090`, `SC2004`). Give both halves the same type.

## Functions and promises

- **`arguments.length` can't be used with default, optional or rest parameters** (`SC1090`). Test the parameter itself: `if (value === undefined)`.
- **A function that forwards `arguments` can't be called from typed TypeScript** (`SC1090`). Declare named parameters and forward those.
- **Omitting an optional parameter throws at runtime** (`expected function at $[2]`). Pass `undefined` or a no-op in the slot.
- **An unhandled promise rejection ends the program.** A browser reports the rejection and keeps running. Add a `.catch()` to every chain, or use `try`/`catch` in an `async` function.
- **A callback stored for later must name the arguments it may receive** (`SC1090`). `window.addEventListener("pointerup", () => { … })` is refused because the listener type may be called with an event; write `(event: Event) => { … }`, even when the event isn't read.
- **A `then` handler that returns `Promise.all` over a dynamically typed promise defers the rest of the chain** (`SC2020`). `await` the inner promise and return its value.

## Objects, arrays and numbers

- **A missing `Map` key read through `!` throws** where JavaScript passes `undefined` on. Use `map.get(key) ?? fallback`.
- **A record can't be written through a computed key from `Object.keys()`** (`SC1090`, "updating a record through a 'string | undefined' key"). Write the fields by name, or keep the counts in a `Map`.
- **`new WeakRef(x)` has no lowering** (`SC2020`). Keep a strong reference instead.
- **Spreading a `Map` iterator into a rest call, as in `Math.max(...map.keys())`, throws at runtime** (`expected array ..., got Array Iterator`). Collect the values into an array with a loop first.
- **A ragged tuple destructured in untyped JavaScript throws** when a missing element is read. Give every row the same length.
- **Writing `.length` on an array-typed value that isn't a native array fails** (`SC1090`). Assign a new array instead: `items = []`.
- **Assigning a number to a `string` property throws** instead of coercing as a browser does. Call `String(n)` first.
- **A computed property write on a class instance can break unrelated conversions** (`SC1090`), with the error reported elsewhere in the program. Write known properties directly, or keep the values in a `Map`.
- **`typeof document` in a library is refused** as a circular import (`SC1016`). Test `document !== undefined`.

## Modules and packages

- **CommonJS packages that assign `module.exports` inside a conditional don't run** (`SC1090`). React 18 and `scheduler` are built this way; React 19's builds compile from scriptc 0.4.16, which the React examples use. Prefer packages that ship an ES module build.
- **`Checkbox` from `@ui-sdk/react` 0.1.0-beta.13 doesn't compile.** Its `@ui-sdk/core` implementation builds a value missing a required property of its declared type (`SC1090`, `checkbox.js`). Use a `<button role="checkbox">` until the package or the compiler changes; the other parts in the package compile, including `Command`, `Button` and `Input`.
- **`Dialog` from `@ui-sdk/react` stops the page's events.** `DialogTrigger` reaches a bound method (`trigger.bind` in `dialog-parts.js`) that scriptc refuses (`SC1090`). The exception while the trigger binds leaves React unable to process later updates: the page paints, but clicks and keys do nothing. Build the overlay yourself; `Button` and `Input` work on their own.
- **`Command` from `@ui-sdk/react` throws when it highlights a row.** Its store helpers call `Object.getPrototypeOf` (`SC2020` in `@ui-sdk/core`'s `selects.js`), so filtering works until the first highlight and then the program stops. A page's own filtered list over an `Input` is the workaround until the compiler lowers `Object.getPrototypeOf`.
- **A library's own files are type-checked as part of the build.** A package whose JavaScript doesn't type-check stops the build. Patch the annotations, or use a build of the package that types.
- **An inline `<script>` that imports a package is compiled on its own** and can fail where the same code in a module compiles (`SC8005`). Move the code into a module file.
- **There is no per-module compile cache yet.** A large dependency is compiled again on each build, so the edit, build and run loop is slower with big libraries.

## Runtime notes

- **`fetch()` accepts a `string` or `URL` only, and `RequestInit` has no `cache` member** (`SC0001`). Pass a URL and set caching headers on the request.
- **`customElements.define` reports every attribute change to `attributeChangedCallback`**, because a class's static `observedAttributes` can't be read. Filter on the attribute name in the callback.
- **A `for…of` loop needs its loop variable declared in the loop head** (`SC1090`, `SC1091`). Write `for (const item of items)`.
- **A DOM member typed non-null can hold another value at runtime.** For example, `document.body` is the root element for a document that has no body, where a browser's is `null`. Don't rely on null checks for those members.
