---
worth: later
added: 2026-09-14
---
# stripped libghostty frames need a symbolication script

Release builds keep only the exported `ghostty_*` symbols; the Zig-internal functions are stripped and
the linker reorders them relative to `libghostty-internal.a`, so `atos` on a user's `sample` names
nothing inside libghostty. #606 was resolved by matching the instruction window before each sampled
return address against the object's disassembly (mnemonics and registers, immediates masked; 24
instructions, 12 where 24 finds nothing), one unique hit per frame. The method and the script
(`symbolicate-frames.py`, hardcoded to that session's dump files) are in
https://gist.github.com/umputun/9ffd6da3e3b93d649ae9c109c59823d4.

Worth a `scripts/` home: input is a binary or dylib, the matching `libghostty-internal.a`, and a list of
offsets; output is function name and enclosing source call per offset. Every future stripped-frame
report needs it again.
