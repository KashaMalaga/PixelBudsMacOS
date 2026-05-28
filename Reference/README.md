# Reference materials

Files in this directory are external references used to understand the Pixel Buds protocol. They are not compiled into the app.

## Sources

All files copied verbatim from [qzed/pbpctrl](https://github.com/qzed/pbpctrl), licensed under Apache-2.0 OR MIT.

| File | Origin |
|------|--------|
| `maestro_pw.proto` | `libmaestro/proto/maestro_pw.proto` |
| `pw.rpc.packet.proto` | `libmaestro/proto/pw.rpc.packet.proto` |
| `pbpctrl-Notes.md` | `docs/Notes.md` |

## Key facts distilled from these sources

- **Maestro RFCOMM SDP UUID**: `25e97ff7-24ce-4c4c-8951-f764a708f7b5`
- **Class of Device**:
  - Pixel Buds Pro (Gen 1): `0x240404`
  - Pixel Buds Pro (Gen 2): `0x244404`
- **Transport stack**: RFCOMM → HDLC U-frames (control byte `0x03`, CRC-16) → Pigweed RPC → Protobuf
- **Two protocols share the device**:
  - Maestro (proprietary, this UUID) — settings: ANC, EQ, gestures, HW/SW info
  - GFPS (Google Fast Pair Service) — battery events, ring, multipoint
