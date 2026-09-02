---
worth: yes
where: cookbook/two-agent-chat/README.md:88
added: 2026-08-31
---
# peer-chat README states two different one-shot file lifecycles

The *How it works* paragraph says the send "rejects links, non-regular files, files accessible to other
users, and bodies over 64 KiB, then removes the directory entry before reading the message", which reads
as all four checks preceding the unlink. `read_message` does not work that way, and the *Limits*
paragraph in the same file describes the real order correctly.

What the code does: `O_NOFOLLOW` makes a symlink fail before anything is removed, and a non-regular or
multiply-linked entry raises without unlinking. Mode and size are checked *after* the entry is gone. The
recipe's own tests pin the split — `test_symlink_is_rejected` and `test_non_regular_message_is_rejected`
assert the entry survives, while the world-readable and oversized tests assert it does not.

The cost of the wrong ordering is a reader who expects a mode-rejected or oversized prepared file to
still be on disk and retries the send by name, hitting ENOENT. Softened by both post-unlink errors saying
"and was consumed; run `--prepare-message` again", so the error text alone gets them out.

One clause: links and non-regular files rejected before the entry is removed, a public mode or an
oversized body after. Surfaced reviewing PR #505 and left off the contributor's branch as a maintainer
doc fix.
