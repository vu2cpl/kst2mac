# KST Mac

Native macOS SwiftUI client for the [ON4KST](https://www.on4kst.info/) VHF /
UHF / microwave / EME chat — the DX-liaison chat VHF operators keep open
next to the radio during a lift or a contest.

Written fresh against the chat's telnet protocol; not a port of KST2Me or
any other existing client (see [docs/PROTOCOL.md](docs/PROTOCOL.md) for the
prior art).

## Status

**v0.1 — working chat client.** Connects, logs in, joins a room, shows the
traffic, sends messages and `/CQ` directed messages, and builds a station
table with distance and beam heading from your own square.

| Piece | State |
|---|---|
| Telnet codec (IAC stripping, option refusal) | done, unit-tested |
| Prompt-driven login state machine | done — CRLF-terminated prompts, 6 regression tests |
| Chat message parser | done — accepts both `21:15` and `2115` stamps, neither yet seen live |
| Chat room list | done — all 13 rooms, transcribed from a live menu |
| Maidenhead distance / bearing | done, unit-tested |
| Password in Keychain | done |
| Station table | **partial** — learns callsigns from chat traffic, not from the server's roster |
| User-list / roster parser | **not started** — blocked on a transcript, see below |
| Map view | not planned for v0.1 |

## Build and run

```bash
swift build && swift run KSTMac
```

For a drag-to-Applications bundle:

```bash
./build_app.sh
```

Then `cp -R "build/KST Mac.app" /Applications/`.

Tests:

```bash
swift test
```

## Setup

1. You need an ON4KST account — register at <https://www.on4kst.info/>.
2. **Use a password you use nowhere else.** The chat runs on plain TCP with
   no TLS, so it crosses the network in clear. This is a property of the
   service, not of this client.
3. Launch, open Settings (⌘,), and set your callsign, your locator
   (e.g. `MK83`), and save the password to the Keychain.
4. Pick a room from the toolbar and press Connect. From VU the ones you
   want are **144 / 432 MHz IARU R3** (the default) and **50 MHz IARU R3**.

## Safety note about sending

Once you are in a room, **anything written to the connection is broadcast
immediately** — the chat has no draft state or confirmation step. The client
is built around that:

- the composer is disabled until the login handshake is fully complete;
- `KSTConnection.send(_:)` refuses to write before that point;
- nothing is ever sent automatically.

## Layout

```
Sources/KSTCore/       protocol layer — no UI, unit-testable
  Telnet.swift         IAC stripping + option refusal
  KSTConnection.swift  NWConnection client + login state machine
  LineParser.swift     chat-line classification
  Maidenhead.swift     locator → lat/lon, distance, bearing
  Keychain.swift       password storage
  Models.swift         ChatRoom, KSTLine, Station, KSTEvent
Sources/KSTMacApp/     SwiftUI app
tools/KSTCapture/      transcript recorder for protocol work
docs/PROTOCOL.md       what's verified vs inferred about the protocol
```

## Next step

The station table is the weak half: it currently lists who has *spoken*,
not who is *present*, because the server's user-list command and its column
format haven't been confirmed. Record a transcript —

```bash
swift run KSTCapture --call VU2CPL --room 9 --seconds 180 --probe
```

— and the roster parser can be written against real bytes. The recorder
mirrors traffic to the terminal live and ticks a countdown, so a quiet room
looks different from a hung client. `--probe` sends `/HELP` after joining,
whose reply should name the roster command.

It prompts for the password with echo off and never writes it to the file.
Transcripts are git-ignored — they contain whatever the room said while you
were recording, and the login banner echoes your public IP.

## Conventions

Shack-wide rules apply (see `~/.claude/CLAUDE.md`): CDP (Commit, Document,
Push together), private GitHub repos unless explicitly published, credit
upstream authors where due. See `HANDOVER.md` for working notes.
