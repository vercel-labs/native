# ui-inbox

A task inbox authored in TypeScript and Native markup. The compiled core owns task capacity, UTF-8 editing and composition, filtering, clear-on-submit, and titlebar insets. Keyed rows retain widget identities while native hosts present their declared context menus.

```sh
native dev
native test
native test -Dtypescript-view=true
```

The example retains its build entry for native-only platform link audits and the host-built mobile embed archive:

```sh
zig build lib -Dmobile=true
```

Mobile targets use the same core through the standard `lib` build step. The native behavior reference and layout audit remain in the SDK test suite.
