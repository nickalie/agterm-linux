---
paths:
  - "agtermCore/Sources/agtermCore/MainTimer.swift"
  - "agtermCore/Sources/agtermCore/Debouncer.swift"
  - "agtermCore/Sources/agtermCore/AppStore.swift"
  - "agtermCore/Sources/agtermCore/AppStore+PendingClose.swift"
  - "agtermCore/Sources/agtermCore/AppStore+AutoFollow.swift"
  - "agtermCore/Sources/agtermCore/WindowLibrary.swift"
  - "agterm-linux/Sources/AgtermLinux/**"
  - "agterm-linux/docs/main-loop.md"
---

## Main loop and deferred work (GTK/Linux port)

- **Deferred main-actor work goes through `agtermCore`'s `MainTimer` seam — never a dispatch or
  `Task.sleep` timer.**
  The Linux app hands its main thread to GTK (`g_application_run`), and the GLib main loop drains neither
  libdispatch's main queue nor the Swift Concurrency main-actor executor.
  `DispatchQueue.main.async`/`asyncAfter`, `Task { @MainActor }` + `Task.sleep`, `Timer.scheduledTimer`, and
  `RunLoop` scheduling compile, run, and then silently never fire there — the failure mode is silence, not a
  crash, which is why it survives review.
  This binds in shared `agtermCore` too, where the dependency is easiest to miss because the file looks
  host-free.
- **Use `MainTimer.schedule(after:_:)` (it returns a cancel closure) or `Debouncer`, which is built on it.**
  `MainTimer.scheduleTimer` is the injection point; its default is `DispatchQueue.main.asyncAfter` (correct
  on macOS, dead on Linux) and the Linux app replaces it exactly once in `installGLibMainTimer()`
  (`GLibMainTimer.swift`), at the top of `activateApplication`.
  Keep that default Dispatch-based — the GLib code belongs in the Linux target.
- **Main-thread HOPS use `runOnMain` (`g_idle_add`), which exists only in the Linux target.**
  Host-free `agtermCore` has no hop seam: from main-actor core code use `MainTimer.schedule(after: 0)`; add a
  hop seam next to `MainTimer` only if a real need appears.
  The one deliberate exception in core is `AppStore+AutoFollow`'s observation callback, a nonisolated→main
  hop the `@MainActor` timer seam cannot express — and unreachable under GTK.
- **A repeating or long-lived timer stays on the Linux side** with a direct `g_timeout_add`;
  `MainTimer` is deliberately one-shot.
  Two live here: `LinuxAutoFollowCoordinator`'s idle tick, and `SplitRatioRestoreCoordinator`'s 50 ms
  divider-restore poll (`AppControllerSurfaces.scheduleSplitRatioRestore`, whose tick returns
  `G_SOURCE_CONTINUE` until the paned has a width), each owning its `guint` source id and its own
  `g_source_remove` cancel.
- **Derive a coupled delay from the constant it trails**, never re-hardcode it — `reconcileSoftClose`
  schedules at the soft-close `grace + 0.1` so it cannot drift from the finalizer it must follow.
- **The grace window is a state, not a schedule — nothing that runs DURING it may reap a held session.**
  `AppController.reconcile` drops the host surfaces of every session the visible tree no longer names, and a
  soft close deliberately takes its session OUT of the tree while its record waits out the grace, so
  `reconcile` unions `AppStore.pendingHeldSessionIDs()` into the live set ITSELF rather than trusting the
  soft-close caller to pass the ids.
  A per-call opt-out would only cover the one reconcile the soft close arms; the ~40 other `reconcile()`
  calls (sidebar edits, `session.new`, the auto-follow timer) would still free the shells an undo promises
  to bring back — and the undo would then quietly spawn a fresh login shell and report success.
- **A deferred job that touches GTK widgets must be CANCELLED in `windowWillClose`, and `[weak self]` is not
  enough.**
  `windowWillClose` runs synchronously inside the close-request handler and GTK destroys the widget tree
  right after, but the controller itself survives whenever something still `passRetained`s it (a Settings
  dialog, the palette, the theme picker), so a live weak reference is exactly the use-after-free case.
  Keep the returned cancel closure — `AppController.softCloseReconcile`
  (`SoftCloseReconcileCoordinator`) is the pattern for a one-shot job, the `Debouncer`s for repeated ones —
  and disarm it alongside the other teardown there.
- **A STORE-scoped deferred job is not covered by those cancels — `windowWillClose` FINALIZES it.**
  The soft-close grace finalizer is armed on `AppStore`, not on the controller, so no window-scoped
  `cancel()` reaches it and it ends in `AppStore.save()`, which would re-create `windows/<id>.json` after
  `WindowLibrary.removeWindow` deleted it (window delete closes the window first, then removes it).
  `windowWillClose` calls `store.finalizeAllPendingCloses()` and the quit path calls
  `WindowLibrary.finalizeAllPendingCloses()` from `flushOnQuit`.
  Finalize, never cancel: cancelling strands the held records and leaks the surfaces, watermark PNGs and
  recency entries that only the finalizer's teardown sweeps.
- **EVERY dialog this window owns is dismissed in `windowWillClose` — not just the theme picker.**
  A bare toplevel (`gtk_window_new` + `gtk_window_set_transient_for`, today the theme picker and the command
  palette) is NOT destroyed with its transient parent under GTK4: left up it stays on screen orphaned, keeps
  the controller alive through the `passRetained` on its "destroy" handler — which is what lets every other
  deferred job outlive the window — and runs its rows against a freed widget tree.
  An AdwDialog hosted in the window (the Settings dialog, and the Keyboard Shortcuts / About dialogs its
  `prepareAuxiliaryDialog` sibling builds) does go away with it, but it holds the same `passRetained` on
  "closed", so force-close it here rather than trusting libadwaita's host teardown to emit the signal.
  The auxiliary pair is tracked in `AppController.auxiliaryDialogs` and swept by `dismissAuxiliaryDialogs()`,
  because it is built ad hoc (no single `settingsDialog`-style slot) and the Keyboard Shortcuts dialog's
  "Open Settings" button would otherwise drive `showSettings` against a destroyed widget tree.
  Dismissal for a dialog carrying unpersisted preview state is a CANCELLATION (revert + clear the override),
  never a bare close — the theme picker goes through `cancelTheme()` (which guards on "is a picker up?"
  itself), not `closeThemePicker`.
  Adding a dialog to `AppController` means adding its dismissal there in the same change.
  A dialog whose retained context is released by its OWN async callback and re-checked with a
  `gWindows[controller.windowID] === controller` staleness guard (the GtkFileDialog choosers) needs no
  dismissal — GTK owns the dialog and the guard is what makes the late callback a no-op.
- **A deferred job that rebuilds the sidebar defers while the user is interacting with it.**
  `rebuildSidebar()` destroys every row, so an async rebuild landing on a live inline rename commits its
  half-typed text (the entry's disposal fires a focus-out).
  An open context menu is NOT part of that gate: `anchorContextMenu` parents the popover to the sidebar
  scroller instead of to a row, so it survives every rebuild — a background session's status, an OSC title,
  a control command — and closes only on an outside click or a chosen item.
  Gate on the shared `AppController.sidebarInteractionInProgress` and re-arm at
  `AppController.sidebarInteractionRetryInterval` instead of dropping the rebuild; a synchronous sidebar
  action's rebuild is deliberately not gated.
  Both live with the GATE, not with either deferred job — `SoftCloseReconcileCoordinator` takes the cadence
  by injection so it stays independent of what its `deferWhile` reads.
  `reconcile` itself skips its rebuild during a rename, since the rename's end rebuilds anyway.
- **A deck focus grab goes through `AppController.deckMayTakeFocus`**: upstream's `focusActiveSession`
  bail list (zoom, dashboard, rename, palette or theme picker, pick or GUI ask, and the quick terminal while it
  holds the window's focus, upstream's `holdsKey`) plus its surfaces' refusal to steal from an `NSText`,
  here any visible `GtkEditable` holding the window's focus.
  `focusSession`/`focusActiveSession` apply it.
  `reconcile` grabs only through `showActive`, after its removals, and its overlay syncs never grab;
  `setSplitFocus` ends in `focusSession` too, so no caller of the three grabs after it.
  The direct `grabFocus` calls left are the zoom's own surface, the quick terminal's show, a pointer click or
  drop on a pane, and a replaced pane keeping focus it had.
  An overlay's exit, `session.overlay.close` and `submit`, a session dialog's answer and the search entry's
  close hand the keyboard back only when the closing widget held it, and through the gate to the session's
  topmost surface, never the one they opened over: a cover may have opened since.
  A deferred job still passes `reconcile(focusActive: false)`: the gate cannot see a sidebar row or any
  other widget the user moved to during the delay (the trailing soft-close reconcile does).
  The one exception is a search whose surface is gone while its entry held the keyboard: `reconcile` hides
  the entry and grabs through the gate anyway, as nothing else would take the keyboard off the hidden field.
- **Tests that swap `MainTimer.scheduleTimer` go through `withFakeMainTimer`** (agtermCore test fixtures):
  the seam is a process-global static and swift-testing runs in parallel, so the swap window must contain no
  `await` — the helper's synchronous closure makes that unrepresentable.
  The exception is the Linux `AgtermLinuxTests` suite, which cannot see the core test fixtures at all
  (separate package): `GLibMainTimerTests` installs the REAL GLib seam through its own synchronous
  `withGLibMainTimer` helper, holding the same no-`await` contract.
  A Linux test whose subject takes its scheduler by INJECTION (`SoftCloseReconcileCoordinator`) touches no
  global seam and needs neither helper.
- If a debounce, delay, or grace window "does nothing on Linux", check which mechanism scheduled it before
  suspecting the logic.
  Full contract, the repro matrix, and the unpersisted-preview override pattern:
  `agterm-linux/docs/main-loop.md`.
