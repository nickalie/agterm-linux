---
worth: yes
where: cookbook/two-agent-chat/README.md:88
added: 2026-08-31
---
# peer-chat README claims both input modes keep the message out of the process list

"Both keep the message text out of the process list" holds only for `peer-chat.py`'s own argv. `type_text`
hands the body to `ctl`, which runs `subprocess.run(["agtermctl", "session", "type", <full body>, ...])`,
so the message sits in that child's command line for the duration of the send whichever input mode was
used.

Master's narrower sentence was true as written: "a message passed as an argument would sit in the process
list". The generalisation arrived with the file-backed input in #505, and the code it describes is
unchanged.

Small real risk. A different-uid observer cannot read that argv on macOS anyway, since `KERN_PROCARGS2`
refuses another user's process to a non-root caller, and a same-uid process could open a 0600 spool entry
directly. So this is a wrong claim in user-facing docs rather than an exposure the spool was meant to
close.

One clause: say both keep the body out of the invoking command line, and note that the `agtermctl session
type` hand-off still places it in a child's argv. Surfaced reviewing PR #505.
