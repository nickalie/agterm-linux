---
worth: maybe
where: agtermCore/Sources/agtermctlKit/ZmxCommands.swift:Zmx
added: 2026-09-21
---
# no CLI read of a detached daemon's scrollback

A Live pane's zmx daemon keeps 10,000 lines of its own scrollback outside the app, and `ZmxClient.screen(name:all:)`
already reads it by shelling out to `zmx screen <name> --all`. Nothing exposes that: `Zmx`'s subcommands are
`List, Prune, Kill, Reset, Tree, Attach, Present`, and the only caller of `screen` is the lead-covered fallback in
`ControlServer+PaneLead.coveredText`, reached after `session.text` has already passed `surface.isRealized`.

So a session whose surface is not realized answers `session not realized` even when its daemon holds the history
on disk. That is the one path to a session's output that needs no realization, which matters for anything reading
across many sessions at once. Surfaced investigating issue #638 (global search), where the absence of a
realization-free read is what makes a built-in cross-session search unable to keep its promise.

`maybe` rather than `later`: it is a small addition on its own, but whether a daemon read belongs in the CLI at all
is a design call nobody has made. The reachable set is zmx-backed panes only, not plain closed-window sessions.
