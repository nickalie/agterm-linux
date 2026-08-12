# Linux catch-up to upstream v0.22.0

## Range

- Previous Linux parity base: upstream `v0.21.0`
  (`9e8105015f83f0b7a4a2040b7f6ff19851644265`)
- Target parity base: upstream `v0.22.0`
  (`8192f0ba48ebd3d716f77c8a02c8bec06535e708`, 2026-08-09)
- Integration branch: `linux-port`
- Merge commits: `31414b1` (`chore(upstream): merge upstream/master past v0.21.0`) took the branch to
  `28c256895db08a889f2c45eb12237733d869eb59`; upstream then tagged `v0.22.0` one commit later, and
  `chore(upstream): merge upstream v0.22.0` takes only that commit — the changelog entry and the plugin
  and site version bumps. The inventory below is therefore the whole `v0.21.0..v0.22.0` product range.
- 39 upstream commits. The parity work landed while the range was still untagged, at the maintainer's
  direction; the tag arrived afterwards and the base is now tag-bounded.

`linux-v0.21.0` was never cut, so this branch also still carries the whole unreleased
`v0.20.x`/`v0.21.0` range described in `20260807-linux-v0.21.0-catch-up.md`.

## Downstream feature shipped in the same cycle

`01670c0` adds `sessionNameFromTerminalTitle`, a General setting on both targets, and flips the default:
an unnamed session is named after its cwd basename, and the focused pane's OSC title names it only when the
setting is on. Upstream always prefers the title. This is a deliberate product divergence, approved for
this cycle, and Linux additionally gains `shell-integration-features = no-title`, which macOS already
emitted.

## Inventory

### Portable core and shared artifacts

Inherited from upstream; no Linux code required.

- `hasSplit` on `ControlSessionNode` (`a585694`, `1944540`): the field, its nil omission, the
  `agtermctl tree` `(split hidden)` tag, and the read-back rule all live in `AppStore.controlTree`,
  `ControlProtocol` and `agtermctlKit`. The Linux `controlTree` arm calls `store.controlTree` and the Linux
  CLI links the shared kit, so both halves arrive with no downstream edit.
- `Fuzzy`'s substring band cap under the subsequence floor (`2c8ad9f`) — the GTK palette, control picker
  and session switcher all score through it.
- The `keymap.conf` starter examples' bindable chord (`9846869`), in `ConfigPaths`. The protected
  `ConfigPathsTests.swift` changed upstream and was accepted unchanged; `git diff master --` on it is empty.
- `CommandPath` (`babc760`) — the shared widening the Linux adapter composes with, below.
- `AccessibilityInsert` (`93b8950`, `4155ed9`) — host-free, and unreferenced on Linux, see the exemption.
- The whole HUD core of `1923906`: `HudPosition`'s nine anchors with `top`/`bottom` aliases and
  `parse`, `HudSpec.textColor`, `HudLayout.foregroundSGR`, the dispatcher validation, the
  `ControlHudNode` read-back and the `agtermctl session hud --position/--text-color` arguments.
  `textColor` reaches the Linux panel for free: it rides the body header, which
  `writeHudBody` renders through `HudLayout.renderedBody`.
- `hud.sh`'s new header field and shift count merged cleanly over the carried `cellcount` fix.
- cookbook recipes, `docs/backlog`, `docs/troubleshooting.md`, `CLAUDE.md` and the `.claude/rules` files.

### Carried portable core fix

- `AccessibilityInsertTests.crlfRoutesToPaste` asserts `"ls -la\r\n".contains("\n") == false` to document
  that CRLF is one grapheme cluster. The bare literal picks a different overload per platform —
  Foundation's substring search on Darwin, the stdlib's `StringProtocol.contains` on Linux — and only the
  latter finds `"\n"` inside CRLF, so the test fails on Linux while `needsPasteRouting` itself is correct
  on both. Spelling the operands `as Character` makes it the grapheme comparison it documents everywhere.
  Portable and upstreamable.

### GTK parity work

- **HUD anchors.** `applyFloatingOverlayGeometry` handled three vertical positions and did not compile
  against the 3x3 enum. It now resolves each axis through `AppController.floatingOverlayAnchor`, reaching
  macOS' offset-from-center with `halign`/`valign` plus the edge margin on the side the band names, and
  collapsing that axis to center when the panel and its margin do not both fit.
- **Copy Name.** Both GTK context popovers gain the item under Rename, single-target only, writing
  `Session.displayName` or `AppStore.workspaceName` to the display clipboard. A vanished row or a blank
  workspace name leaves the clipboard untouched.
- **Custom-command PATH.** `LinuxCommandPath` composes `CommandPath.widened` with the running
  executable's directory — where the tarball bundle and `install-linux.sh` both put `agtermctl` — and
  appends `~/.local/bin`. Same #393 failure with Linux directories: a `.desktop`-launched app inherits the
  graphical session's environment and `/bin/sh -c` reads no profile, so a bare `agtermctl` exited 127.
  `CommandPath`'s own `/opt/homebrew/bin` is inert here and not worth forking the shared implementation.
- **CI ancestry pin** moved to `v0.22.0` in both workflows, back to a real release tag after the interim
  `upstream-28c2568` commit pin.

### Platform-specific adaptations and exemptions

- **Accessible terminal surface** (`93b8950`, `4155ed9`) is `NSAccessibility` on `GhosttySurfaceView`,
  exposing the grid as an editable text area for dictation and VoiceOver. The GTK equivalent is
  `GtkAccessibleText`, a GObject interface that has to be implemented **on the widget** — here
  libghostty's own GL area — and the port registers no `GType` of its own anywhere. Exempt, and stated in
  README rather than left implied.
- **The Full Screen menu item** (`1c63357`) is removed because AppKit injects its own into the View menu.
  GTK injects nothing and the Linux port already ships no such item: `toggle_fullscreen` reaches
  `toggleWindowFullscreen()` from `KeymapDispatch` and the palette. No change.
- **⌘W on the Settings window** (`a20ace7`) is AppKit menu-item validation picking the wrong window.
  Linux chords are dispatched only from `AppController.handleKey`, whose sole caller is
  `GhosttySurface.keyPressed`, so with the Settings `AdwDialog` focused no chord fires at all.
- **Palette pointer highlight and rounded clip** (`ab7b6a3`, `210b1fe`) are SwiftUI drawing fixes. The GTK
  palette is a `GtkListBox` of `GtkListBoxRow`s in a real toplevel: Adwaita paints `:hover` on rows and the
  window's corners are the theme's own.
- **Workspace row-click expand animation** (`f595631`) is a SwiftUI `withAnimation` around a deferral GTK
  does not have.
- **TCC entitlements, usage strings, and the entitlement-free `agtermctl` CI assertion**
  (`ab1256c`, `7f941fc`, `c7945c6`) are macOS signing.
- **App Shortcuts menu-equivalent test isolation** (`16d8cbc`) is macOS hosted-test infrastructure.

### Documentation and bundled surfaces

- README: upstream's Copy Name, `hasSplit`, PATH-widening and accessibility paragraphs arrive from
  upstream; the Linux section gains the Linux PATH directories, the accessibility exemption, and a base
  version corrected from v0.19.0 to v0.22.0.
- `plugins/agterm/skills/agterm/reference.md` merged upstream's `hasSplit` paragraph with the downstream
  naming clause on the same lines.
- `.claude/rules/control-api.md` and `sidebar.md` gained the two Linux adapter notes.

## Validation

Gates run in the `swift:6.3.2-noble`-derived container CI uses, with SwiftLint 0.65.0.

- [x] `cd agtermCore && swift test`
- [x] `cd agterm-linux && swift test`
- [x] `cd agterm-linux && swift build`
- [x] `cd agterm-linux && swift build -c release`
- [x] SwiftLint 0.65.0 `--strict`
- [x] `scripts/check-linux-core-boundary.sh`
- [x] `scripts/check-linux-cli-drift.sh`
- [x] `scripts/stage-linux.sh`
- [x] `scripts/test-linux-ui.sh`
- [x] `git diff --check`
- [x] `git diff --quiet master -- agtermCore/Tests/agtermCoreTests/ConfigPathsTests.swift`
- [ ] Branch CI green on `linux-port` — blocked, not failing. GitHub disables Actions on a new fork and the
  override exists only in the repository's Actions tab, so `nickalie/agterm-linux` has run no workflow.
  No Linux release tag is cut until it does.

## Not verified interactively

The nine HUD anchors and `--text-color` were validated by build, unit tests and the AT-SPI suite, which
asserts no pixels for the panel. Copy Name was likewise not exercised against a live clipboard. Both want a
hands-on pass before the release is announced.
