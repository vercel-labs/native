# checkout

A three-step order form — account, shipping and payment. Each step checks its fields on submit,
shows a message under the field that needs attention and focuses it, the card number groups in fours
and the expiry takes MM/YY, and the order summary follows the shipping choice. React 19 renders it,
Tailwind 4 styles it, and the text fields and buttons come from `@ui-sdk/react`.

## Build

```console
$ node ../../packages/cli/compiler/cli.ts build . -o build/checkout
$ NATIVE_STEPS='frame 0 | click #continue | frame 16 | print #error-name' NATIVE_SNAPSHOT=checkout.png ./build/checkout
```

The steps in `tests/examples.ts` drive a full order: an empty submit, a bad email, a valid account,
shipping with express delivery, then a formatted card and the confirmation.
