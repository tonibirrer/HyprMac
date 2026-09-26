# Testing

## The test gate

`scripts/test-isolated.sh` is the test gate for contributors and for
`scripts/release.sh`. It generates a separate project that builds HyprMac as a
testable library. It never starts the window manager or reads live settings.
Home, cache, and tmp are redirected under `build/sizing/isolated-tests/`. A run
takes about five minutes, mostly the build.

```bash
./scripts/test-isolated.sh --debug-variant                  # full suite, no Sparkle
./scripts/test-isolated.sh --debug-variant BSPTreeTests     # one class
./scripts/test-isolated.sh --debug-variant BSPTreeTests/testName
./scripts/test-isolated.sh /path/to/Sparkle.xcframework     # release variant, as release.sh runs it
```

## Traps

- The second argument goes straight to `xcrun xctest -XCTest`. It must be a
  bare class name. A `HyprMacTests/` prefix runs 0 tests and still exits 0.
  Always check that `Executed N tests` shows a nonzero N and `0 failures`.
- A full run leaves a `config.json` fixture in the isolated home. The next run
  then fails two `ConfigUpdateCoordinatorTests`. Before a second full run:
  `find build/sizing/isolated-tests/home -name config.json -delete`.
- `PollingSchedulerTests.testScheduleAfterPollFiresAgain` is a known
  wall-clock flake. If it is the only failure, rerun that test alone.
- After config schema or `Action` changes, also run
  `KeybindDecoderToleranceTests` and `ConfigMigrationTests` by name.

## Headless runs

The hub runs tests with no display. Tests that need a real `NSScreen` throw
`XCTSkip`, so skips are expected. Engine tests still run: they pass a
synthetic `NSScreen` subclass through `DisplayManager(screenSource:)`. Use that
pattern for new tests. Examples: `TilingEngineTiledDragTests`,
`FullscreenWorkspaceTransferTests`.

Snapshot tests render only on request: `HYPRMAC_RENDER_UI=<dir>` for
`InterfaceSnapshotTests`, `HYPRMAC_RENDER_OVERVIEW=1` for
`WorkspaceOverviewPresentationTests`.

## Other builds

Release universal build, unsigned (resolves Sparkle over the network):

```bash
xcodebuild -project HyprMac.xcodeproj -scheme HyprMac -configuration Release \
  -derivedDataPath build/release-check ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO build
lipo -archs build/release-check/Build/Products/Release/HyprMac.app/Contents/MacOS/HyprMac
```

Static analyzer:

```bash
xcodebuild -project HyprMac.xcodeproj -scheme HyprMac -configuration Debug \
  -derivedDataPath build/analyze CODE_SIGNING_ALLOWED=NO build analyze
```

Lint: `.swiftlint.yml` exists, but `swiftlint` is not installed on the hub and
the last recorded baseline already had errors. Do not claim a lint pass.

Tests do not prove window behavior. For behavior changes, run the Debug app on
the MacBook ([laptop-debug-deployment.md](laptop-debug-deployment.md)).
