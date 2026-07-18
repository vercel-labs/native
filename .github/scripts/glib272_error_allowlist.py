#!/usr/bin/env python3
"""The GLib 2.72 receipt's error-set allowlist.

Compiling gtk_host.c on stock ubuntu 22.04 (GLib 2.72, GTK 4.6) cannot
succeed: the toolkit's GTK floor is 4.10, so GTK-age failures are the
expected steady state. What this receipt pins is that NOTHING ELSE
fails - a glib/gio symbol needing 2.74+ without a version-checked
fallback shows up here as a diagnostic outside the allowlist below.

The allowlist is by diagnostic SHAPE, not symbol prefix:
- undeclared gtk_/GTK_ functions are the GTK-age roots;
- undeclared plain (non-glib-namespaced) identifiers are their
  cascades (locals whose declaring line failed);
- int-conversion lines are cascades of undeclared functions returning
  int, and incidentally name glib types (GListModel), so a prefix
  denylist would false-positive on them.
Everything else fails the step: unknown type name 'G...', undeclared
g_/G_ symbols, missing members, any located shape not seen before,
and any error line WITHOUT a file:line:col location (driver failures
like "error: Unknown Clang option" never classify as diagnostics, so
they must reject rather than sail through an empty error set).

The receipt also demands positive evidence it ran: at least
MIN_GTK_ROOTS allowlisted GTK-age root diagnostics. A compile that
produced no classifiable error set (wrong file, broken include path,
invocation failure) proves nothing and must fail loudly - the clean
run produces ~21 roots, so the floor sits far below real variance
while catching "nothing actually compiled".

Why the cascade allowances are sound despite looking broad: this
receipt is one lane in a lattice, not the sole guard on gtk_host.c.
Every full-GTK lane (linux-webkitgtk, the canvas smokes, macOS)
compiles the same file cleanly, so a typo'd local or an independent
conversion bug is a red build elsewhere before it ever reaches this
filter - the only errors unique to this lane are the old-glib delta.
And within that delta, regressions always announce themselves through
a REJECTED root before their cascades matter: a missing glib function
is "call to undeclared function 'g_...'" (only gtk_/GTK_ roots are
allowed), a missing glib type/macro is an unknown-type-name or
undeclared-G_-identifier line - all rejected. The cascades allowed
below can only follow roots this filter already failed the step for,
or GTK-age roots it exists to permit.
"""
import re
import sys

MIN_GTK_ROOTS = 5

located = re.compile(r"^[^:\n]+:\d+:\d+: error: (.*)")
rejected = []
gtk_roots = 0
for line in sys.stdin:
    if "error:" not in line:
        continue
    m = located.match(line)
    if not m:
        rejected.append(line.rstrip() + "  [unlocated error shape - driver or invocation failure]")
        continue
    msg = m.group(1)
    if re.match(r"call to undeclared function '(gtk_|GTK_)", msg):
        gtk_roots += 1
        continue
    if re.match(r"use of undeclared identifier '(?!g_|G_|G[A-Z])", msg):
        continue
    if "incompatible integer to pointer conversion" in msg and "from 'int'" in msg:
        # Only the cascade signature: an undeclared function defaults to
        # returning int, so its assignment lines convert FROM 'int'.
        # Conversions from any other type are not that cascade - reject.
        continue
    rejected.append(line.rstrip())

if rejected:
    print("non-GTK-age diagnostics against GLib 2.72 - the pre-2.74 fallback story regressed:")
    print("\n".join(rejected))
    sys.exit(1)
if gtk_roots < MIN_GTK_ROOTS:
    print(
        f"only {gtk_roots} GTK-age root diagnostics (need >= {MIN_GTK_ROOTS}) - "
        "the compile did not exercise the old-GTK error set, so this receipt proved nothing"
    )
    sys.exit(1)
print(f"fallback receipt ok: every error is GTK-age by shape ({gtk_roots} roots)")
