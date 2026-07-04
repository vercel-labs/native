# RFC: Session sync protocol

**Status:** draft · **Owner:** platform team · **Target:** v0.4

Client sessions currently persist locally and diverge across devices. This RFC proposes a pull-based sync protocol with bounded payloads and last-writer-wins conflict resolution.

## Goals

- [x] Deterministic merge for concurrent edits on two devices
- [x] Payloads bounded at 256 KiB so a sync can never stall the UI thread
- [ ] Offline queue with at-most-once delivery
- [ ] End-to-end property tests across three simulated devices

## Non-goals

- Real-time collaborative editing (out of scope until the CRDT spike lands)
- Multi-account merge — sessions stay per-account

## Protocol sketch

1. Client sends `HEAD /sessions/:id` with its local revision
2. Server replies `204` (up to date) or `200` with the missing delta
3. Client applies the delta, then pushes its own pending ops
4. Any rejected op re-queues with exponential backoff

```
client                          server
  |--- HEAD rev=41 ------------->|
  |<-- 200 delta rev=42..44 -----|
  |--- POST ops (3) ------------>|
  |<-- 201 rev=45 ---------------|
```

> The delta format is the existing snapshot diff — no new wire format. A sync is just a replayed edit history.

<details>
<summary>Failure modes considered</summary>

- Server unreachable: the offline queue holds ops; the UI shows the queued count
- Delta larger than the payload bound: server falls back to a full snapshot
- Clock skew: revisions are server-assigned, wall clocks are never compared

</details>

<details>
<summary>Rejected alternatives</summary>

- **Push-based sync** — requires a persistent connection per client; the fleet cost is not justified at current scale
- **Operational transforms** — the editing model is line-based, so OT's character-level machinery buys nothing here

</details>

---

## Rollout

| Stage  | Cohort         | Gate                        |
| :----- | :------------- | :-------------------------- |
| 1      | Internal       | Zero data-loss reports, 1wk |
| 2      | 5% of traffic  | Error rate < 0.1%           |
| 3      | Everyone       | Stage 2 holds for 2wks      |
