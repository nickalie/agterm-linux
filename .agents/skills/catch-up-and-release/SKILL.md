---
name: catch-up-and-release
description: Guide maintenance of the agterm-linux fork from upstream discovery through Linux parity work and a local install of the validated build. Use when asked to catch up, sync, or merge from umputun/agterm; audit or restore Linux feature parity; or continue fork maintenance after a new upstream release.
---

# Catch Up

Maintain `melonamin/agterm-linux` as a close Linux port of `umputun/agterm`.
Drive the workflow, show evidence at each checkpoint, and pause only at the consequential gates defined below.

## Preserve the Fork Contract

- Treat root `AGENTS.md` as authoritative, then read `README.md` and `ARCHITECTURE.md` before changing code.
- Keep `master` as the upstream-tracking branch and `linux-port` as the maintained downstream branch.
- Preserve upstream behavior and protocol shapes wherever Linux permits.
- Keep `agtermCore/` host-free and upstream-compatible.
- Put GTK/libadwaita, Glibc, Linux CLI, packaging, and platform-adapter work in Linux-owned paths.
- Prefer upstream shared implementations over downstream copies. Remove carried fixes once upstream contains them.
- Never make a downstream edit to `agtermCore/Tests/agtermCoreTests/ConfigPathsTests.swift`. If upstream changes it, accept the upstream file unchanged and verify there is no Linux-only diff.
- Never include unrelated worktree files. In particular, leave `site/_screenshot.png` alone unless the user explicitly selects it.
- Do not update `CHANGELOG.md`.

## Use These Approval Gates

Continue autonomously through inspection, merging, implementation, testing, commits requested by the user, review fixes,
and fast-forward pushes of `master` and `linux-port` to `origin`.
A fast-forward push of either branch needs no approval: it adds commits and destroys nothing, and the fork is the
user's own workspace. Report the refs it moved instead of asking first.
Stop and obtain explicit approval immediately before:

1. any force-push;
2. making a product/UX divergence from upstream.

Show the exact commits, refs, command, and validation state at each gate.
Never use a blind force push; use a narrowly scoped `--force-with-lease` only after approval.

## Phase 1: Establish Facts

Run all path-sensitive commands from the absolute repository root.
Do not assume the current branch, remote ownership, latest version, or a clean worktree.

1. Inspect `git status --short --branch`, branches, worktrees, remotes, tags, and recent commits.
2. Fetch `upstream` and `origin`, including tags, without mutating local branches.
3. Query GitHub with an explicit repository every time. Bare `gh repo view` may resolve to upstream:
   - upstream: `--repo umputun/agterm`
   - fork: `--repo melonamin/agterm-linux`
4. Identify:
   - the newest upstream stable tag reachable from `upstream/master`;
   - the newest upstream tag already contained in `linux-port`;
   - whether upstream has commits after the target tag;
   - local commits or user changes that need preservation.
5. Read every matching file under `.claude/rules/` before touching its subsystem.

If the requested target is ambiguous, recommend the newest stable upstream release.
If `upstream/master` contains post-tag commits, ask whether to catch up to the exact release or to rolling master; do not silently ship unreleased upstream commits.

## Phase 2: Prepare the Toolchain

Derive tool versions from the repository's pins rather than the host defaults.
The current pins are Swift 6.3.2 and SwiftLint 0.65.0.

Install and invoke them with mise:

```sh
mise install swift@6.3.2 swiftlint@0.65.0
mise x swift@6.3.2 -- swift --version
mise x swiftlint@0.65.0 -- swiftlint version
```

Also verify the native dependencies documented by `README.md` and `scripts/setup-linux.sh`.
Do not silently run privileged package installation.
If dependencies are missing, tell the user exactly how to install them for the detected distribution.

## Phase 3: Synchronize Upstream

Use the branch model documented in `README.md`:

1. Check that switching branches will not overwrite user changes. Do not stash, discard, or relocate them without approval.
2. Switch to `master` and fast-forward it to the chosen upstream commit. Use `upstream/master` for rolling parity or the exact upstream tag for a tag-bounded catch-up.
3. Confirm the resulting `master` contains no downstream-only commit.
4. Push the fast-forwarded `master` to `origin`, reporting the refs it moved.
5. Switch to `linux-port`, update it from `origin/linux-port` with `--ff-only`, then merge `master` with a normal merge commit when one is needed.
6. Resolve shared-core conflicts toward upstream unless a carried fix remains portable, necessary, and intentionally upstreamable.
7. Confirm the selected upstream tag is an ancestor of `linux-port` and the protected test file has no downstream diff.

If a portable core fix belongs upstream, isolate it on a dedicated upstream-PR branch with no Linux-only changes.
Keep local fork documentation, such as Linux or zsh requirements, out of that upstream branch.

## Phase 4: Build a Parity Inventory

Compare the last incorporated upstream tag with the target using commit logs, name-status diffs, and the upstream changelog.
Classify every meaningful upstream change into one of these buckets:

- shared host-free behavior to inherit directly;
- shared protocol, model, persistence, or CLI behavior needing Linux adapter work;
- user-visible macOS behavior needing a native GTK/libadwaita equivalent;
- macOS-only behavior with a documented Linux exemption;
- documentation, bundled agent-skill, or packaging work.

Upstream CI and release changes are out of scope.

Turn the inventory into a checked plan under `docs/plans/` when the catch-up spans multiple features.
Record the upstream range, exclusions, integration rules, validation commands, and platform limitations.
Move it to `docs/plans/completed/` only after all required work passes.

For each user-visible capability, audit all applicable surfaces:

1. shared model/controller behavior;
2. GTK GUI, action palette, menus, and keymap;
3. control protocol and dispatcher;
4. Linux-local `agtermctl` arguments and output;
5. control read-back for mutable state;
6. unit, CLI, integration, and realistic runtime coverage;
7. `plugins/agterm/skills/agterm/` and user-facing documentation.

Explicitly record why any surface is inapplicable.

## Phase 5: Restore Linux Parity

- Implement pure decisions, validation, response shapes, and static catalogs in `agtermCore` only when they are portable and upstream-compatible.
- Keep GTK objects, processes, windows, libghostty, and C-boundary glue in the Linux app.
- Copy C strings into Swift-owned values before crossing actors, queues, or callbacks.
- Keep GUI actions and the control channel synchronized. A state mutation also needs observable read-back.
- Use native GTK/libadwaita behavior and document real Wayland or toolkit constraints instead of fabricating parity.
- Update the bundled agent skill under `plugins/agterm/skills/agterm/` whenever commands, arguments,
  keymaps, or the window/workspace/session/pane model changes.
- Validate maintainer, reviewer, and Copilot suggestions before implementing them. Reproduce the claimed issue and check per-platform types or APIs; do not accept comments merely because they sound plausible.
- Keep commits narrow and reviewable. Do not mix upstream synchronization, unrelated cleanup, and parity features when they can be separated.

## Phase 6: Validate the Candidate

Start with fast gates and expand in proportion to the touched surface.
Use the repository scripts as the final source of truth.

```sh
cd agtermCore && mise x swift@6.3.2 -- swift test
mise x swiftlint@0.65.0 -- swiftlint lint --strict --quiet
scripts/setup-linux.sh
cd agterm-linux && mise x swift@6.3.2 -- swift build --product agtermctl-linux
cd agterm-linux && mise x swift@6.3.2 -- swift build --product AgtermLinux
cd agterm-linux && mise x swift@6.3.2 -- swift build -c release
git diff --check
```

Add focused control round trips and runtime checks from the parity inventory.
For visual acceptance, launch a development instance with a temporary `AGTERM_STATE_DIR` and separate control socket, then hand it to the user without driving their live state.

Before declaring parity complete:

- inspect the full downstream diff from the target upstream commit;
- verify Linux-only changes stay in approved boundaries;
- verify the protected test file has no downstream changes;
- recheck unresolved maintainer review threads when the work belongs to a PR.

## Phase 7: Commit and Push

Push each branch fast-forward and report, with the pushed refs:

- target upstream version and merge commit;
- parity commits and deliberate exemptions;
- exact test, lint, build, and manual results;
- current worktree status and explicitly excluded files;
- the before and after object of every remote ref the push moved.

A push that is refused as non-fast-forward is a gate, not a retry: stop, show why, and ask.
If history was deliberately rewritten and the user approved it, fetch first and use `--force-with-lease` against the observed remote object.

Then roll the validated build out over the maintainer's own install, without asking.
The local install is how the user runs agterm day to day, so parity that never reaches it is not delivered.

```sh
rm -rf build/stage-deploy
docker run --rm -v "$PWD:/w" -w /w -e AGTERM_PACKAGE_VERSION=X.Y.Z localhost/agterm-build:6.3.2 \
  bash -lc '(cd agterm-linux && swift build -c release) && scripts/stage-linux.sh /w/build/stage-deploy'
rsync -a --delete build/stage-deploy/ ~/.local/share/agterm-linux/
rm -rf build/stage-deploy
```

- `stage-linux.sh` builds nothing: it packages whatever `.build/release` holds yet stamps `COMMIT` from `HEAD`,
  so without the `swift build -c release` first a commit made after the last release build ships stale
  binaries under a current commit.

- Stage INSIDE the build container: `stage-linux.sh` bundles the Swift runtime through `ldd`, which the
  host cannot resolve.
- `AGTERM_PACKAGE_VERSION` is the upstream version this parity base tracks, since `agtermctl version` is
  what a cookbook recipe's minimum is compared against; the commit is taken from `HEAD`.
- Smoke-test the staged `bin/agtermctl --help` on the host before the rsync — it needs no socket and proves
  the bundled runtime loads.
- Leave `~/.local/share/applications/*.desktop` alone: it carries the user's own `AGTERM_NO_UPDATE=1`
  guard, and the payload ships its own copy anyway. `~/.local/bin/agtermctl` is a symlink into the payload
  and survives the rsync.
- NEVER restart, quit, or relaunch the running app. Replacing files leaves the live process on its old
  inodes; when the user restarts is the user's call. Report the installed VERSION and COMMIT and say that a
  restart is what picks them up.

Then refresh the installed integrations from that payload, also without asking: the agent skill and the
agent-status hooks (lifecycle scripts, Claude Code and Codex hooks, Pi and OpenCode plugins).
`plugins/agterm/skills/agterm/` and `agterm/Resources/agent-status/` are only sources; the copies agents
load live under `~/.claude`, `~/.codex` and `~/.config/agterm/agent-status` and go stale otherwise.

```sh
~/.local/bin/agtermctl integration install skill --dry-run
~/.local/bin/agtermctl integration install skill
~/.local/bin/agtermctl integration install hooks --dry-run
~/.local/bin/agtermctl integration install hooks
~/.local/bin/agtermctl integration status
```

- Use the INSTALLED `~/.local/bin/agtermctl`, never a repo or container build: the installer copies from the
  payload's `share/agterm` and bakes that payload's `agtermctl` into the hook scripts, so it must run after
  the rsync above. A repo or container path baked into the hooks breaks them once that build goes away.
- Never copy, edit or merge the skill, hook scripts, `settings.json` or `config.toml` by hand. The installer
  changes only agterm-managed content and backs up what it merges.
- A dry run exits `2` on a protected conflict, such as user-defined Codex hooks or an unmarked `SKILL.md` or
  plugin. Apply anyway: the safe targets are written and the protected one is skipped. Never force or work
  around a conflict; report it with the path and the installer's reason.
- Report every target the apply changed, every conflict it skipped, and the final status lines.

## Finish with an Evidence-Based Handoff

Lead with the outcome.
Include the upstream range, parity status, platform exemptions, commits, pushed refs, the version and commit
now installed locally, the refreshed integrations and any skipped conflicts, validation evidence, and remaining work.
Mention protected or unrelated files that were intentionally left untouched when relevant.
