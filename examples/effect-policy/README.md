# Scratch Pad

A TypeScript and Native markup example using buffered file, clipboard and HTTP effects. Notes live in the app data directory supplied by the framework. Save, append, inspect and delete use the same keyed route; replacing a read delivers only the latest arm, and cancelling a read delivers neither arm. Two unkeyed reads complete independently.

Run with `native dev`, or build the compiled TypeScript view with `native build -Dtypescript-view=true`. Run `native test` for complete native snapshots, effect deliveries and session replay; the tests feed hermetic file, HTTP and clipboard results through the native effects channel.
