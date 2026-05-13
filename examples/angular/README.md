# Angular Example

A super basic zero-native example using Angular for the frontend and Zig for the native shell.

## Run

```bash
zig build run
```

The build installs frontend dependencies, builds the frontend, and opens the native WebView shell.

## Dev Server

```bash
zig build dev
```

This starts the Angular dev server from `app.zon`, waits for `http://127.0.0.1:4200/`, and launches the native shell with `ZERO_NATIVE_FRONTEND_URL`.

## Frontend

- Frontend: `angular` (Angular 20)
- Production assets: `frontend/dist`
- Dev URL: `http://127.0.0.1:4200/`

## Using Outside The Repo

This example references zero-native via relative path (`../../`). To use it standalone, override the path:

```bash
zig build run -Dzero-native-path=/path/to/zero-native
```
