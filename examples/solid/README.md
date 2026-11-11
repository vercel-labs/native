# Solid Example

A super basic Native SDK example using SolidJS for the frontend and Zig for the native shell.

## Run

```bash
zig build run
```

The build installs frontend dependencies, builds the frontend, and opens the native app shell with WebView content.

## Dev Server

```bash
zig build dev
```

This starts the Solid dev server from `app.zon`, waits for `http://127.0.0.1:5173/`, and launches the native shell with `NATIVE_SDK_FRONTEND_URL`.

## Frontend

- Frontend: `solid`
- Production assets: `frontend/dist`
- Dev URL: `http://127.0.0.1:5173/`

## Using Outside The Repo

This example references the Native SDK via relative path (`../../`). To use it standalone, override the path:

```bash
zig build run -Dnative-sdk-path=/path/to/native-sdk
```
