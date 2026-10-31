# Pulse Board

A TypeScript + Native markup example with two repeating clocks and keyed and independent one-shot reminders. The model declares active timer keys, intervals and message routes; stopping a clock removes its subscription.

Run with `native dev`. Run the deterministic app-loop tests with `native test`; they cover slot reuse, fractional intervals, route changes, debounced route replacement, independent empty-key reminders, cancellation and session replay.
