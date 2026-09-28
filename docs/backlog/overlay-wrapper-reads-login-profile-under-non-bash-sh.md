---
worth: later
where: agterm/agtermApp.swift:overlayExitWrapper
added: 2026-09-25
---
# overlay wrapper reads the login profile when /bin/sh is not bash

libghostty runs a surface command as `bash --noprofile --norc -c "exec -l <command>"`, and `-l` puts a dash
on argv[0]. `overlayExitWrapper` is a bare `sh -c '…'`, so when `/private/var/select/sh` points at dash or
zsh the overlay's shell starts as a login shell and runs `~/.profile` before the caller's command.
Measured: dash and zsh-as-`sh` under `exec -l` print a `~/.profile` marker, the `/usr/bin/env` form does
not. The stock bash selection is unaffected, and nobody has reported it.

Fix: `"/usr/bin/env /bin/sh -c '…'"`, so `env` takes the dash and `sh` starts non-login. Surfaced
reviewing PR #654, which wraps the remote pane command the same way.
