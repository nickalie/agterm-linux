---
worth: later
where: agterm/AgentHooksInstaller.swift:opencodeText
added: 2026-09-21
---
# OpenCode integration does not say it is v1-only

The bundled `agterm-status.js` uses OpenCode's v1 plugin API, and OpenCode v2 does not run v1 plugins.
The installer gates only on `~/.config/opencode` existing, so on a v2 machine it reports "OpenCode
lifecycle plugin installed ... Restart OpenCode." and no status ever appears. `docs/troubleshooting.md`
and the bundled skill's `troubleshooting.md` give the same restart advice, which does nothing on v2.

Until v2 support exists (#637), say which OpenCode major the integration serves in the install dialog
text and both troubleshooting pages. When #637 is done the wording changes again, so fold this into that
work if it arrives first.
