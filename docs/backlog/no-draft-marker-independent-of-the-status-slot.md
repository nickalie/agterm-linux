---
worth: maybe
where: agtermCore/Sources/agtermCore/AgentStatus.swift:AgentIndicator
added: 2026-09-12
---
# no draft marker independent of the status slot

The two passive per-session markers a recipe can set are `session flag` and `session status active`
with a custom color and shape. Status gives the marker a glyph of its own and stays out of attention
navigation, but the indicator is one slot: the next `session.status` write from an agent hook
replaces it, and raising it over `blocked` or `completed` hides that glyph. Flag survives but has no
separately customizable glyph, it switches the session icon to its filled variant, and it joins the
flagged view, which is a curated list.

Surfaced answering discussion #595, which asks for a marker on a session holding a typed,
unsubmitted line. The detection is recipe work, one per program; the marker is the app's side. A
user-set marker with state independent of `AgentIndicator`, rendered beside the status glyph and
outside the attention set, would remove the collision. Undecided until the reporter says whether the
flag/status recipes cover him.
