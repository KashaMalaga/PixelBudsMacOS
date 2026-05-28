# Architecture

Audience: developers (human or AI) extending the app or porting it to a
different language.

## At a glance

```
┌─────────────────────────────────────────────────────────────────────┐
│  PixelBudsBar (SwiftUI / AppKit menu-bar app)                       │
│  ├── AppDelegate         NSStatusItem, popover, settings window     │
│  ├── BudsViewModel       @Published state, reconnect loop, setters  │
│  ├── BudsConnection      one session: Maestro + (optional) GFPS     │
│  ├── BudsPopoverView     batteries, ANC picker, Find menu           │
│  ├── SettingsView        Form with all advanced settings            │
│  ├── LoginItemManager    SMAppService wrapper                       │
│  └── GFPSChannel         Fast Pair Message Stream → Ring command    │
└─────────────────────────────────────────────────────────────────────┘
                                    ▲
                                    │ MaestroService API + GFPS frames
                                    │
┌─────────────────────────────────────────────────────────────────────┐
│  MaestroIOBluetooth (macOS / IOBluetooth bridge)                    │
│  ├── MaestroChannelOpener   find paired buds by CoD                 │
│  └── RFCOMMTransportAdapter open / write / read RFCOMM (any UUID)   │
└─────────────────────────────────────────────────────────────────────┘
                                    ▲
                                    │ raw bytes in/out (AsyncStream)
                                    │
┌─────────────────────────────────────────────────────────────────────┐
│  Maestro (pure Swift, no IOBluetooth)                               │
│  ├── HDLC/        Pigweed-style framing (CRC32, varint, escape)     │
│  ├── PwRPC/       Pigweed RPC client, channel resolution, addresses │
│  ├── Protos/      maestro_pw.proto, pw.rpc.packet.proto             │
│  └── Services/    MaestroService: typed RPC calls + setting getters │
└─────────────────────────────────────────────────────────────────────┘
```

The package boundary matters: **Maestro has zero IOBluetooth dependency**,
so it can be unit-tested with a mock transport (and is — see
`Tests/MaestroTests/`). All platform code lives in `MaestroIOBluetooth`
and `PixelBudsBar`.

## Protocol stack

Two RFCOMM channels share the same Bluetooth Classic link to a single pair
of buds. They are independent — one can drop without affecting the other.

### Maestro — primary channel

```
   Maestro RPC call (e.g. SetAncState)
              │
              ▼
   Protobuf encoded payload
              │
              ▼
   Pigweed RPC packet  (channel id, method hash, payload)
              │
              ▼
   HDLC U-frame  (start 0x7e, address, control 0x03, data, CRC32, end 0x7e)
              │
              ▼
   RFCOMM channel (UUID 25e97ff7-24ce-4c4c-8951-f764a708f7b5)
```

Key bits:

- HDLC uses **CRC32** (not CRC16 as some older notes suggest). The
  encoder/decoder lives in `Sources/Maestro/HDLC/`.
- Channel ID resolution is dynamic. We try a list of candidate channels by
  sending `GetSoftwareInfo` on each and seeing which one answers — that's
  the Maestro channel for the active bud. See
  `Sources/Maestro/PwRPC/ChannelResolver.swift`.
- `MaestroService` exposes typed getters/setters on top of the RPC client.
  Adding a new setting boils down to adding `getFoo()`/`setFoo()` that
  wrap `readSetting(.allegroFoo)` / `writeSetting(...)`.

### GFPS — secondary channel

```
   Ring command
        │
        ▼
   Message Stream frame  (group 0x04, code 0x01, length 2B BE, data 1B)
        │
        ▼
   RFCOMM channel (UUID df21fe2c-2515-4fdb-8886-f12c4d67927c)
```

GFPS in Pixel Buds Pro travels on RFCOMM (not the BLE GATT
characteristics most other GFPS implementations use). This is a happy
accident: the same `RFCOMMTransportAdapter` already knows how to open a
channel by SDP UUID, so the only new code is the Message Stream frame
builder in `GFPSChannel.swift`.

The inbound stream is **drained but ignored** — battery and ANC events
also come from Maestro, and we don't need duplicates.

## Connection lifecycle

`BudsViewModel` owns the entire session. Three pieces work together:

### 1. Observer counting

Multiple UI surfaces (popover + settings window) can both want the
connection alive. The view model exposes `acquireConnection()` and
`releaseConnection()`; first acquire opens the session, last release
tears it down. This is what keeps the RFCOMM channel from churning when
you click the gear button:

```
   popover.onAppear         → acquireConnection()  (count 0 → 1, open)
   gear → settings opens    → acquireConnection()  (count 1 → 2)
   popover.onDisappear      → releaseConnection()  (count 2 → 1)
   settings window closes   → releaseConnection()  (count 1 → 0, close)
```

### 2. Session driver

`runLiveSession()` is a `while !Task.isCancelled` loop. Each iteration:

1. Calls `runOneSession()` — opens the connection, fetches initial
   settings, subscribes to runtime + settings change streams. Returns
   when either stream ends (drop).
2. Tears down the dead connection.
3. Computes a backoff (1s, 2s, 4s, 8s, 10s cap) and sleeps.
4. Loops.

A failure budget (5 attempts) only counts attempts that never published a
snapshot. Once a session shows real data, the counter resets — a healthy
session can recover from intermittent drops indefinitely.

### 3. Snapshot pattern

`BudsSnapshot` is a single `Equatable` struct holding everything we want
to render. The view model never mutates it in place from the UI; setters
are pessimistic (write succeeds → patch snapshot → publish) or rely on
the device's settings subscription to push the canonical value back. If a
write is rejected by the firmware (status 9 "not allowed in current
state", which Pixel Buds Pro use for "put them in your ears first"), the
optimistic UI snaps back when the device echoes the old value, and the
user sees a transient banner.

Importantly, **write errors don't poison `connectionState`**. That
distinction landed after an early bug where a rejected hold-gesture write
flagged the whole connection as `.error` and the only way out was to
close and reopen the app. Write errors now live in
`lastWriteError: String?`, dismissible from the UI.

## State diagram

```
   .idle ────acquireConnection()──→ .connecting
                                         │
                                         ▼
                              ┌── runOneSession ──┐
                              │                   │
                       success│                   │failure (budget!)
                              ▼                   ▼
                        .connected            .error(msg)
                              │
                       stream drops
                              │
                              ▼
                          backoff + retry
                              │
                              ▼
                       (loop until cancelled or budget exhausted)
```

## Module boundaries (Swift Package targets)

| Target | What lives here | Depends on |
|--------|-----------------|------------|
| `Maestro` | HDLC, Pigweed RPC, protobuf-generated types, `MaestroService` | swift-protobuf |
| `MaestroIOBluetooth` | RFCOMM transport adapter, paired-device finder | `Maestro`, IOBluetooth.framework |
| `BudsSpike` | Phase 0 probe (CLI) | IOBluetooth.framework |
| `BudsRead` | End-to-end CLI tester | `MaestroIOBluetooth` |
| `PixelBudsBar` | The menu-bar app (SwiftUI + AppKit) | `MaestroIOBluetooth`, SwiftUI, AppKit, ServiceManagement |

Tests live in `Tests/MaestroTests/` and only exercise the pure-Swift
`Maestro` target — that's the layer where we have real algorithms (CRC,
varint, HDLC roundtrip, Pigweed hash, RPC packet construction).

## Build pipeline (`Scripts/build-app.sh`)

`swift build` produces a CLI-shaped executable. To make it a proper macOS
app the script:

1. Builds release (`swift build -c release --product PixelBudsBar`).
2. Creates `build/PixelBudsBar.app/Contents/{MacOS,Resources}`.
3. Copies the executable in.
4. Copies a hand-written `Resources/PixelBudsBar/Info.plist` (with
   `LSUIElement=YES` so it's menu-bar only, `LSMinimumSystemVersion=14.0`,
   `NSBluetoothAlwaysUsageDescription`).
5. Copies the flat resources from `Sources/PixelBudsBar/Resources/` into
   `Contents/Resources/`. We deliberately don't ship the SwiftPM-generated
   `.bundle` because ad-hoc codesigning that nested bundle is finicky and
   `Bundle.main` works just fine for our needs.
6. Generates `AppIcon.icns` from `Resources/PixelBudsBar/icon-source.png`
   via `sips` (to make every required size) + `iconutil`.
7. Ad-hoc signs (`codesign --sign -`).

The result is a self-contained, drag-to-/Applications bundle that macOS
will run after the first Gatekeeper prompt.

## Threading model

- **`BudsViewModel`** is `@MainActor`. Setters are sync (they kick off a
  `Task` internally for the RPC); state updates always happen on main.
- **`MaestroService`** is an actor.
- **`RpcConnection`** is an actor.
- **`RFCOMMTransportAdapter`** uses a dedicated serial `DispatchQueue` for
  writes (IOBluetooth's `writeSync` isn't thread-safe).
- **`GFPSChannel`** drains its inbound stream on a `Task.detached`. It's
  not actor-isolated because there's nothing concurrent to serialize.

Cancellation propagates through `Task.isCancelled` checks at every await
point in `runLiveSession` / `runOneSession`. When the user closes the
popover and the consumer count drops to zero, the live task is cancelled
and the next checkpoint exits cleanly.

## Things that have bitten us before

Cataloging these here so the next maintainer (or AI assistant) can find
them quickly:

- **Stuck "Connecting…" on popover reopen.** The fix was making
  `RFCOMMTransportAdapter.close()` actually wait for IOBluetooth's
  `rfcommChannelClosed` delegate to fire before returning (it's async).
- **`kIOReturnNotOpen` (`0xE00002CD`) on write.** The peer closed the
  RFCOMM channel but we still held the `IOBluetoothRFCOMMChannel*`. Fix:
  nil out the reference in `rfcommChannelClosed`.
- **Status 9 ("FAILED_PRECONDITION") on settings writes.** Pixel Buds Pro
  reject several writes if the buds aren't in your ears. We surface a
  friendly message (see `RpcError.statusName`) and rely on the settings
  subscription to push the canonical value back so the UI reverts.
- **Stuck "Error" state after a single failed write.** Old code wrote
  rejection errors into `connectionState`. We now have a separate
  `lastWriteError` field; the connection state only reflects RFCOMM/RPC
  health.
- **Ad-hoc signed `.bundle` inside the `.app` fails to codesign.** We
  flatten resources into `Contents/Resources/` instead of shipping the
  SwiftPM-generated `PixelBudsBar_PixelBudsBar.bundle`.
- **Menu-bar icon rendered huge.** `NSImage(contentsOf:)` reports the
  PNG's native size. Set `img.size = NSSize(width: 18, height: 18)`
  explicitly before assigning.
