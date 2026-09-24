---
worth: yes
where: scripts/setup.sh
added: 2026-09-14
---
# surface free deadlock waits on a ghostty pin bump

`ghostty_surface_free` can block the main thread forever (#606): `Surface.deinit` joins the io thread,
the io thread joins its reader, and the reader can be waiting for capacity in the 64-slot app mailbox
that only `ghostty_app_tick` on the main thread drains. Filed upstream as
https://github.com/ghostty-org/ghostty/discussions/14234; agterm builds libghostty unpatched, so the fix
arrives by moving `GHOSTTY_REV`. Samples and symbolication:
https://gist.github.com/umputun/9ffd6da3e3b93d649ae9c109c59823d4.

Before the bump merges, run all three against an isolated Debug instance:

- one session running `while :; do printf '\e]0;t%s\a' $RANDOM; done`, closed over the control socket:
  the kill-loop shape, io thread in `Subprocess.stop` with the gather ring full;
- eight such sessions with one closed: the reader-join shape, io thread in `read_thread.join()`;
- eight idle sessions with one closed, as the control.

A fix to one shutdown stage can leave the other broken, so a bump that passes only one case is not
done. The same title-spam close is the re-test for any later `GHOSTTY_REV` move.
