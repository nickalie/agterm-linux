---
worth: later
where: cookbook/two-agent-chat/test_peer_chat.py:117
added: 2026-08-31
---
# no test pins the single-row footer strip in the codex live prompt guard

`trailing_input_block` removes exactly one trailing footer row on purpose, so a multi-row Codex shortcut
overlay fails closed rather than being stripped away. That decision was made explicitly during the #505
review: stripping the whole indented region would let a `1. Allow` / `2. Deny` chooser sitting under a
stale `›` pass the live check, which is the case the guard exists for. Nothing in the suite holds it.

Changing the `if lines and CODEX_FOOTER_RE.match(lines[-1]): lines.pop()` at `peer-chat.py:245` to a
`while` loop leaves all 44 tests green. On this screen the guard then flips from refusing to accepting:

```
› previous user prompt
  Approve this command?
  1. Yes
  2. No
  <footer row>
```

`test_stale_prompt_under_a_dialog_is_not_live` survives the greedy version only because its dialog title
row is unindented, so the strip loop stops there by accident.

The fix is one screen and one assertion: a codex live test whose dialog rows are indented all the way up
to and including the title, asserting `live_prompt_text` returns `None`. Deferred off the contributor's
branch because the shipped code is correct and the missing test guards a future edit, not a present
defect. Surfaced reviewing PR #505.
