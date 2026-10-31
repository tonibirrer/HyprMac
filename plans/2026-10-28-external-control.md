# Other apps control HyprMac through hyprmac:// links

Plan only, 2026-10-28, on main f8d3190 (v0.19.0). No code yet.

## Summary

- Other apps (BetterTouchTool, LeaderKey, Raycast, Karabiner, skhd) can run
  HyprMac actions with `open -g 'hyprmac://action/<name>?…'`.
- One new per-machine setting, "Allow other apps to control HyprMac", off by
  default. It is one row in Settings → General.
- A link runs the same path as a keybind press: the same pause rule, the same
  scratchpad rule, the same beep while displays settle.
- Not exposed: `runCommand`, `launchApp`, `saveLayout`. A web page can open a
  hyprmac:// link after the browser asks, so nothing a link does may run a
  program or overwrite saved state.
- The two status-bar links (`workspace`, `focus`) keep working as today.
- Asked for in #52 (LeaderKey). It is also the answer to #32: a trackpad tool
  maps swipes to `cycleWorkspace` links, so HyprMac needs no gesture code.

## URL format

```
hyprmac://action/<name>[?<arg>=<value>]
```

`<name>` is the Swift case name, matched case-insensitively. These names are
a new public API and are frozen once shipped, the same as the `Action` JSON
wire keys. They are not the wire keys: `switchWorkspace` is `switchDesktop`
on the wire, and a link should not carry that legacy name.

| name | arg | example |
|---|---|---|
| focusDirection, swapDirection, resizeDirection, moveWindowToMonitor | `dir=left\|right\|up\|down` | `hyprmac://action/focusDirection?dir=left` |
| switchWorkspace, moveToWorkspace, moveToWorkspaceAndFollow | `n=1…10` | `hyprmac://action/switchWorkspace?n=3` |
| cycleWorkspace | `delta=1\|-1` | `hyprmac://action/cycleWorkspace?delta=-1` |
| toggleFloating, toggleSplit, showKeybinds, showWorkspaceOverview, focusMenuBar, focusFloating, moveToNextEmptyWorkspace, closeWindow, toggleScratchpad, moveToScratchpad, toggleTiling, restoreLayout, retileAll | none | `hyprmac://action/toggleScratchpad` |

Parsing rules, the same strictness as `StatusURLCommand.parse` today:
exactly one value per expected key, digits only for `n`, `delta` exactly `1`
or `-1`, unknown extra query keys ignored, any other path or name is nil.
A nil parse logs once at `.notice` (`external action rejected: <reason>`)
and does nothing, so a typo in a BTT config is findable in the log.

## Gate

- New per-machine key `externalControlEnabled` in `monitor-config.json`, next
  to `statusExportEnabled`. Per machine because `config.json` can sync over
  iCloud: turning control on for one Mac must not turn it on for every Mac.
- Off and missing write no key, matching `statusExportEnabled`.
- `hyprmac://action/…` links need `externalControlEnabled`.
- `hyprmac://workspace` and `hyprmac://focus` keep working with either key
  on, so current sketchybar setups do not break.
- Settings row in `GeneralSettingsView` (after "Menu bar workspace
  indicator"): toggle, subtitle "Lets apps like BetterTouchTool run HyprMac
  actions with hyprmac:// links." Unlike the status export, this one gets a
  row: the users who want it (BTT, LeaderKey) are not config-file users.

## Code changes

1. `HyprMac/Core/StatusExport.swift` → move the URL type into a new file
   `HyprMac/Core/ExternalCommand.swift` (run `xcodegen generate` after):
   - `enum ExternalCommand: Equatable { case workspace(Int), focus(Int), action(Action) }`
   - `static func parse(_ url: URL) -> ExternalCommand?` keeps today's two
     hosts and adds host `action` with one path component.
   - `static let exposedActions: [String: …]` table from name to a builder
     that reads the args. The table is the single list of what links can do;
     a test pins it.
   - Keep `nextFocusTarget` where it is, or move it along with the enum.
   - Rename `StatusURLCommand` everywhere (`AppDelegate.handleGetURL`,
     `WindowManager.handleStatusURL`, `StatusExportTests`).
2. `HyprMac/Core/WindowManager.swift`:
   - Pull the body of `hotkeyManager.onAction` (~l.371-385: `toggleTiling`
     flip, the `config.enabled` gate with its `showKeybinds` and
     `showWorkspaceOverview` exceptions, the `mouse-focus` suppression,
     `handleAction`, and what follows) into
     `func performUserAction(_ action: Action, source: ActionSource)`.
     The hotkey closure calls it with `.hotkey`; skip
     `endSessionInterruption(evidence: "hotkey press")` for `.link`, since a
     link does not prove a person is at the keyboard.
   - `handleStatusURL` → `handleExternalURL(_ command: ExternalCommand)`.
     `.action(a)` checks `config.externalControlEnabled`, then calls
     `performUserAction(a, source: .link)`. Drop the `isRunning` guard for
     `.action` only where `performUserAction` already handles pause, so
     `toggleTiling` from a link can resume tiling, as the keybind can.
     Keep `workspace`/`focus` exactly as now, with the new either-key gate.
   - Log each accepted link at `.debug` with the action name
     (`ActionDispatcher.discriminator(for:)`, ~l.349).
3. `HyprMac/Models/UserConfig.swift`: `@Published var externalControlEnabled`,
   loaded from and saved to the monitor config the same way as
   `statusExportEnabled` (init ~l.206, `makeSavedMonitorConfig` ~l.341,
   reset ~l.418, reload ~l.523). Assign it at the top of `init`, with the
   status fields: an optional `@Published` assigned after the other stored
   properties fires `didSet` and rewrites config.json at launch (found on
   #50, caught by `ConfigUpdateCoordinatorTests`).
4. `HyprMac/Persistence/ConfigStore.swift`: field on `SavedMonitorConfig`
   (~l.494), coding key, `tolerant(c, .externalControlEnabled)`.
5. `HyprMac/Settings/GeneralSettingsView.swift`: the toggle row.
6. Docs:
   - new `docs/external-control.md`: the gate, the table above, BTT swipe
     recipe (three-finger swipe left → shell command
     `open -g 'hyprmac://action/cycleWorkspace?delta=1'`), LeaderKey and
     Raycast one-liners, what is not exposed and why.
   - `docs/status-bar.md` Links section: point to the new doc and say either
     key turns the two status links on.
   - `docs/keybinds-and-actions.md`: note that link names are frozen too.
   - CLAUDE.md doc map: one line for the new doc.
   - What's New for the release that ships it.

No `Action` change, no `ConfigMigration` step: the new key is additive and
optional, like `workspaceNames`.

## Acceptance criteria

- With the setting off, every `hyprmac://action/…` link does nothing and
  logs nothing above `.debug`; `workspace`/`focus` behave as on main.
- With it on, each name in the table runs the same action as its keybind.
- `toggleTiling` by link pauses and resumes. Other actions by link are
  dropped while paused, except `showKeybinds` and `showWorkspaceOverview`.
- `runCommand`, `launchApp`, `saveLayout`, `switchDesktop` (a wire key),
  bad args, extra path parts and unknown names all parse to nil.
- A link that opens while the scratchpad is up, or while displays settle,
  behaves exactly like the keybind (dismiss / beep).
- Settings toggle writes `externalControlEnabled: true` to
  `monitor-config.json` and removes the key when turned off; config.json is
  untouched.
- Live, on the MacBook Debug build: BTT (or `open -g` in Terminal) cycles
  workspaces left and right on two monitors; HyprMac keeps focus behavior;
  `open -g` does not bring HyprMac's own windows forward.

## Tests

- `ExternalCommandTests` (rename/extend the URL part of `StatusExportTests`):
  every table row parses; the exposed-name list is pinned exactly, so adding
  `runCommand` later fails a test; every excluded and malformed form is nil.
- `UserConfig` round trip: key saved in monitor config only, not config.json;
  launch with the key does not rewrite config.json (extend
  `ConfigUpdateCoordinatorTests` the way #50 did).
- `performUserAction` gate as a pure static helper
  (`static func admits(_ action: Action, enabled: Bool) -> Bool`) with tests,
  so the hotkey and link paths cannot drift.

## Risks

- **Web pages.** A page can open a hyprmac:// link; the browser prompts
  first. Worst case with the exposed set is a closed window or a moved
  workspace. `closeWindow` is the one to reconsider: drop it from the table
  if Zach wants links to be strictly non-destructive.
- **Frozen names.** Once shipped, link names can't change. Review the table
  before merge.
- **Spam.** A BTT gesture can fire links fast. Each runs a full switch, the
  same as fast keypresses today; Greg's `perf/coalesce-switch` (#59) only
  merges hotkey presses. When that lands, route `.link` actions through the
  same coalescer.
- **Apple Event handling** stays on the main thread as today. No new thread.

## Verify

```bash
cd ~/GitHub/.worktrees/HyprMac/<impl-branch>
xcodegen generate && git diff --stat HyprMac.xcodeproj
git diff --check
plutil -lint HyprMac.xcodeproj/project.pbxproj
for s in scripts/*.sh; do bash -n "$s"; done
./scripts/test-isolated.sh --debug-variant ExternalCommandTests      # check "Executed N" > 0
./scripts/test-isolated.sh --debug-variant ConfigUpdateCoordinatorTests
./scripts/test-isolated.sh --debug-variant                           # full suite, baseline 1686/28/0 on f8d3190
```

Then build Debug and redeploy to the MacBook (`docs/laptop-debug-deployment.md`)
and run the live checks above. Tests do not prove window behavior.

## Not in this plan

- A `hyprmac` command-line binary. `open -g` covers every tool above; add a
  thin wrapper later only if people ask.
- Reading state back over links. `state.json` from the status export already
  does that.
- Built-in trackpad gestures (#32): declined, see the reply drafted
  2026-10-28.
