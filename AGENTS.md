# AGENTS.md

Guidance for AI coding assistants (Claude Code, Cursor, Codex, …) working
in this repo. Read this before touching anything substantial.

## House style

- **Code, identifiers, comments, commit messages, and these docs are in
  English.** The original developer chats with assistants in Spanish, but
  what lands on disk is English. Don't mix.
- **Comments explain *why*, not *what*.** The code already says what it
  does. Comments earn their keep when they explain a constraint, a
  surprising decision, or something that bit us before.
- **No defensive boilerplate.** Don't add input validation or error
  branches for cases that physically can't happen given how a function is
  called. The codebase trusts itself.
- **No emoji in files unless explicitly requested.** Same for excessive
  formatting in commit messages.

## Build / run / test

```sh
swift build                     # builds everything
swift run BudsSpike             # Phase 0 hex-dump CLI
swift run BudsRead              # end-to-end CLI tester (reads + ANC)
swift test                      # runs the pure-Swift unit tests
./Scripts/build-app.sh          # produces build/PixelBudsBar.app
open ./build/PixelBudsBar.app   # launch the menu-bar app
```

After UI changes, you typically want `./Scripts/build-app.sh` and then
re-launch the `.app` (the existing instance won't pick up a rebuild).

## Repo layout

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the diagram. TL;DR:

```
Sources/
  Maestro/                 ← pure Swift protocol stack (HDLC, RPC, proto)
  MaestroIOBluetooth/      ← macOS IOBluetooth bridge
  PixelBudsBar/            ← the SwiftUI menu-bar app
  BudsSpike/, BudsRead/    ← diagnostic CLIs
Tests/MaestroTests/        ← unit tests for the protocol stack
Reference/                 ← upstream proto + notes from qzed/pbpctrl
Scripts/build-app.sh       ← .app bundler + ad-hoc signer
```

## Where things should go

- A new **settings toggle** (boolean, single field, no derived state) →
  add a getter/setter to `MaestroService` if missing, then extend
  `BudsSnapshot`, read it in `runOneSession`, add a setter via
  `writeSetting(label:write:update:)`, and surface it in the controls
  section. See the Mono Audio implementation as a clean template.
- A new **slider** or other continuous control → use the `@State
  inProgress` + `onEditingChanged` pattern (see `EqualizerSection` and
  `BalanceSection`) so you fire one RPC per gesture, not one per slider
  tick.
- A new **RPC** that doesn't fit the `readSetting` / `writeSetting`
  pattern → add it to `MaestroService` directly, mirroring an existing
  one. The RPC channel ID is `MaestroService.channel`; method names map
  to the Pigweed hash via `HashId.compute`.
- A protocol-stack change (HDLC, RPC, varint) → make it in `Maestro/`
  *with a test*. The unit tests there are quick (no Bluetooth) and the
  layer is finicky.

## Common gotchas

These cost us hours each:

- **Async close of IOBluetooth RFCOMM.** `IOBluetoothRFCOMMChannel.close()`
  is non-blocking. We wait for the `rfcommChannelClosed` delegate via a
  continuation with a 2s safety timeout. If you bypass this, the next
  `openRFCOMMChannelAsync` hangs.
- **Firmware status 9 ("FAILED_PRECONDITION").** Means "put the buds in
  your ears first" for most settings. Surface it via
  `lastWriteError`, **never** via `connectionState`. The settings
  subscription will push the canonical value back, reverting the
  optimistic UI for free.
- **Settings reads that return status 2 ("not readable").** Some fields
  (notably `speech_detection`) can be written but not read on certain
  firmwares. Treat the read as optional (`try? await …`) and let the
  UI render an indeterminate state until the device subscription
  delivers the canonical value.
- **GFPS channel can drop alone.** Maestro keeps working but the
  RFCOMM-level close fires `rfcommChannelClosed` on the GFPS adapter.
  We observe `GFPSChannel.whenClosed()` and hide the Ring control.
- **SwiftPM-generated `.bundle` doesn't ad-hoc sign.** Don't try to ship
  resources via SwiftPM into the `.app` directly — copy flat files from
  `Sources/PixelBudsBar/Resources/` into `Contents/Resources/` in the
  build script.
- **NSStatusItem icon size.** `NSImage(contentsOf:)` reports the PNG's
  intrinsic size. Set `img.size = NSSize(width: 18, height: 18)` before
  assigning to `button.image`. Also set `isTemplate = true` for proper
  dark/light mode rendering.
- **`SMAppService.mainApp` + ad-hoc signing.** First registration
  returns `.requiresApproval`. The app surfaces this with a banner and
  a deep link to System Settings → General → Login Items.
- **`@MainActor` and `windowWillClose`.** `NSWindowDelegate` is
  nonisolated. Hop back to main with `Task { @MainActor in … }` before
  touching the view model.

## Recipes

### Add a new boolean setting

1. **MaestroService**: add the getter/setter pair. Use the existing
   `readSetting(.allegroFoo)` / `writeSetting(value)` plumbing.
2. **`BudsSnapshot`**: add `var foo: Bool?` (optional; `nil` means we
   haven't read it yet).
3. **`runOneSession`**: `let initialFoo = try? await conn.service.getFoo()`,
   then pass it in the `BudsSnapshot(...)` init.
4. **`applySettingsUpdate`**: add a `case .foo(let v): s.foo = v` so the
   subscription keeps the UI in sync.
5. **`BudsViewModel`**: add `setFoo(_:)` using `writeSetting(label:…,
   write:…, update:…)`.
6. **SettingsView**: add a `toggleRow(...)` in `controlsSection` (or a
   dedicated section if it's conceptually separate).

### Investigate a write that fails

1. Look at the banner. If it says `server error: <message>` where
   `<message>` is friendly, the device rejected it — check
   `RpcError.statusName` to see which RPC status it was.
2. Status 9 → buds need to be in your ears (or some other
   precondition). Try again with them seated.
3. Status 12 ("unimplemented") → the firmware doesn't have this
   setting. We hide or disable it.
4. Anything else → it's probably a real bug. Reproduce with `swift run
   BudsRead` and a few `print`s; the CLI uses the same stack but
   doesn't involve SwiftUI.

### Add a new setting subscribed via SubscribeToSettingsChanges

The `subscribeToSettingsChanges` RPC delivers a stream of
`MaestroPw_SettingValue` messages. Each carries a `value_oneof` with one
of ~15 possible fields. Make sure `applySettingsUpdate` has a `case`
for your new field — otherwise the snapshot will go stale when the user
changes the setting from another device (e.g. the Pixel Buds web app in
Chrome).

## Things NOT to change without thinking hard

- **The reconnect budget logic** in `runLiveSession`. It's tuned to be
  patient on real drops and to give up quickly when the buds simply
  aren't there.
- **The `BudsConnection.openImpl` ordering.** Maestro is opened first
  (mandatory) then GFPS (best-effort). Reversing this would block the
  whole popover on a GFPS open that might never succeed.
- **The flat-resources copy in `build-app.sh`.** See ARCHITECTURE.md for
  why we don't ship the SwiftPM bundle.

## Validating changes

Before considering a UI-touching change done:

1. `swift build` is clean (warnings are OK if pre-existing).
2. `swift test` passes.
3. `./Scripts/build-app.sh` produces a working `.app`.
4. The change actually does what you say it does, **observed in the
   running app**. The protocol stack is convincing but the rare cases
   (firmware status, channel drop, etc.) only surface live.

## Pull request / commit style

- Imperative subject line ("Add Mono Audio toggle"), under 70 chars.
- Body explains the why if the diff doesn't make it obvious.
- One logical change per commit. The "A.4 hold gesture + ANC loop"
  pattern (one chunky commit per coherent feature) is preferred over
  fifty tiny diffs.
- No bot signatures unless the user asks for them.
