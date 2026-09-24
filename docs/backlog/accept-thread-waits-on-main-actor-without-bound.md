---
worth: maybe
where: agterm/Control/ControlServer.swift:handleConnection
added: 2026-09-14
---
# the accept thread waits on the main actor without a bound

`handleConnection` runs every command inline on the single accept thread and parks it in `runBlocking`
until the main-actor dispatch returns. A main thread that never returns (#606, a join inside
`ghostty_surface_free`) therefore takes the whole control socket with it once the backlog fills, even
though `fastPathResponse` could still answer cached `window.list` and closed-window `tree` errors. The
documented contract in `.claude/rules/control-api.md` keeps everything but `zmx.tree` and `zmx.attach`
inline so the cache refresh rides the same execution the fast path reads. Freeing the accept thread is a
design task, not a fix: a deadline on `runBlocking` does not cancel the queued main-actor mutation, and
per-connection threads need bounded admission and an ordering rule among concurrent mutations. Left as
`maybe` because nothing it buys unfreezes the app; it only keeps the read side answering.
