---
worth: maybe
added: 2026-09-20
---
# session type Enter may not submit in a TUI composer

The skill says `session type` is real typing, Enter included. Driving a Claude Code pane on 2026-09-20,
a message typed with its newline in the same call stayed in the composer unsubmitted; a second
`session type` carrying only a literal newline submitted it. One cause was the caller's own:
`$(...)` strips trailing newlines, so the newline never reached the argument. [Unverified] The other
is the TUI treating a fast burst ending in Enter as a paste and keeping the Enter as text; this was
inferred, never isolated.

Isolate it on a Claude Code pane in a Debug instance: text plus newline in one call, against text and
newline in two calls, with the argument checked byte for byte. If the single call fails, document the
two-call form in the skill's `session type` entry; if it holds, document only the `$(...)` trap.
