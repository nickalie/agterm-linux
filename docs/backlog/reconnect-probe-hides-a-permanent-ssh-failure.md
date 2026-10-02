---
worth: later
where: agterm/Control/ControlServer+RemoteReconnect.swift:tickReconnects
added: 2026-09-29
---
# reconnect probe hides a permanent ssh failure

`tickReconnects` reads only `result.status == 0` from the `ssh -T -o BatchMode=yes HOST true` probe and drops
its stderr. A changed host key or a key removed from the origin's `authorized_keys` fails the probe with 255
every time, the same as an offline host, so the pane shows "reconnecting… · any key retries now" forever and
the attach that would print ssh's reason never runs. Before #655 that 255 held the pane with ssh's reason
visible, which is why control-api.md keeps `LogLevel=ERROR` on the attach. The pane recovers once the cause is
fixed, and ⌘W still works, so nothing is lost; the user just cannot tell why it waits.

Belongs with the follow-up that adds the connection state on the tree, `session reconnect` and the
no-response banner: carry the last probe's stderr there, and ideally tell a permanent failure from an offline
host. The backoff must still never give up on a host that is only offline.
