---
worth: maybe
where: agterm/AppActions+Focus.swift:revealRestoredWindow
added: 2026-09-11
---
# restored-window reveal skips the sidebar reconcile

`revealRestoredWindow` publishes frontmost by hand (assign, `saveIndex`, post) and then raises, but it
never calls `applyInactiveWindowSidebarHiding`. It relies on `WindowAccessor.reportFrontmost` running the
reconcile on `didBecomeKey`, which AppKit does not deliver while agterm is inactive. A mapped
`reopen_recent` can run in that state when the quick terminal was summoned over another app: the panel is
`.nonactivatingPanel`, so agterm stays in the background while it takes input, and
`restoreDestination(for:requested:)` can pick a window other than the frontmost one. With
auto-hide-inactive-sidebars on, the window the item restored into is raised with its sidebar still
collapsed until the user next activates agterm.

The window step added in #591 handles this case in `AppActions+Navigation.takeFrontmost`, which is the
third hand-rolled copy of the publish block (the Dock menu's `activate` is the second, and that one
activates the app first, so it does not need the reconcile). Surfaced reviewing #591, with codex.

`maybe` because the symptom is unconfirmed by hand: the chain is verified in code, the collapsed sidebar
is not yet reproduced. If it reproduces, the scoped fix is the one extra reconcile call in
`revealRestoredWindow`; collapsing the three copies into one publisher is a separate call.
