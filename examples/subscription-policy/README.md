# Pulse Board

A TypeScript + Native markup example with two repeating clocks and a one-shot reminder. The model declares active timer keys, intervals and message routes; stopping a clock removes its subscription.

Run with `native dev`. Run the deterministic app-loop tests with `native test`; they cover slot reuse, fractional intervals, route changes, reminder cancellation and session replay.
