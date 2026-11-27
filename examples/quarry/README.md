# quarry

A settings app spread over five sections with a wide range of controls: text, email, password,
number, range, colour, date and time fields; three selects; radios for the theme; checkboxes and
switches for alerts and privacy; a textarea signature; validation on save; and two native modal
dialogs (restore defaults, add a forwarding address). React 19 renders it, Tailwind 4 styles it, and
the inputs, buttons and switches come from `@ui-sdk/react`.

## Build

```console
$ node ../../packages/cli/compiler/cli.ts build . -o build/quarry
$ NATIVE_STEPS='frame 0 | click #save | frame 16 | print #error-name' NATIVE_SNAPSHOT=quarry.png ./build/quarry
```
