# chat

A chat window with a streaming assistant. Send a question and the reply arrives a word at a time,
the list follows it down, and Stop cuts it short. Threads live in `localStorage`. React 19 renders
it, Tailwind 4 styles it, and Send and Stop come from `@ui-sdk/react`.

## Build

```console
$ node ../../packages/cli/compiler/cli.ts build . -o build/chat
$ NATIVE_STEPS='frame 0 | click #composer | type How did the deploy go? | key Enter | wait 800 | print #message-count' NATIVE_SNAPSHOT=chat.png ./build/chat
```
