---
worth: maybe
where: agtermCore/Sources/agtermCore/ControlEvents.swift:ControlEventKind
added: 2026-09-12
---
# events stream has no selection-change event

`ControlEventKind` carries `session.created`, `session.closed` and `tree.changed`, and `tree.changed` fires
on structure and context changes (add, remove, move, rename, `setContext`), not on selection. A session's
`active` flag moving to another session has no event of its own, so a watcher that reacts to a session
losing selection has to poll `tree` and diff the flag itself. Selecting can emit a status event as a side
effect of an auto-reset, which is not a selection signal.

Surfaced answering discussion #595, where the agent-side draft-marker recipe needs exactly that trigger.
Emitting on selection change turns that watcher from a one-second poller into an `events` subscriber like
`status-announcer`. Undecided because the volume and shape are a design call: a `session.selected` event
with the previous and new ids, or `tree.changed` firing on the flip, and whether a window-level focus
change counts.
