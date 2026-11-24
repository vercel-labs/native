# ui-settings

A settings app: tabbed panels for a profile, email notifications, security and billing, with text
fields, a text area, switches, a checkbox, a select, two dialogs and a usage meter. React 19 renders
it, Tailwind 4 styles it, and the buttons and switches come from `@ui-sdk/react`.

## Build

```console
$ node ../../packages/cli/compiler/cli.ts build . -o build/ui-settings
$ NATIVE_STEPS='frame 0 | click #tab-notifications | frame 16 | click #switch-weekly | frame 16 | print #state' NATIVE_SNAPSHOT=settings.png ./build/ui-settings
```

## Styles

`style.css` is the Tailwind 4 build of `input.css`; regenerate it after editing the classes:

```console
$ npm run css
```
