# KST2Mac

Native macOS SwiftUI client for the [ON4KST](https://www.on4kst.info/) VHF /
UHF / microwave / EME chat — the DX-liaison chat VHF operators keep open
next to the radio during a lift or a contest.

Named after and modelled on [KST2Me](https://www.rudius.net/oz2m/software/kst2me)
by Bo **OZ2M**, the long-standing Windows client. The protocol work here is
original — written from packet captures of the live service, see
[docs/PROTOCOL.md](docs/PROTOCOL.md) — but the interaction design follows
OZ2M's, and the highlight conventions it implements (`/CQ`, preamble,
watches, and their precedence and colours) are taken directly from the
KST2Me manual so that operators who know one can read the other.

## Status

**v0.3 — working chat client.** Connects, logs in, joins a room, shows the
traffic, sends messages and `/CQ` directed messages, and builds a station
table with distance and beam heading from your own square.

| Piece | State |
|---|---|
| Telnet codec (IAC stripping, option refusal) | done, unit-tested |
| Prompt-driven login state machine | done — CRLF-terminated prompts, 6 regression tests |
| Chat room list | done — all 13 rooms, transcribed from a live menu |
| Maidenhead distance / bearing | done, unit-tested |
| Password in Keychain | done |
| Station table | done — populated from the server roster, refreshed every 60s |
| User-list / roster parser | done — `/SHow USer`, prompt-delimited, unit-tested |
| Scrollback backfill on join | done — `/SHOW MSG` |
| Live room switching | done — `/CHAT`, no reconnect |
| DX-cluster relay | done — serves spots on port 7373; verified feeding dxca |
| Alert sounds | done — per event, plays even when frontmost, burst-suppressed |
| Mention notifications | done — banner when not frontmost, plus Dock badge |
| Multiple windows | done — concurrent logins verified |
| Stacked / floating panes | done — add, close, or tear a pane into its own window with its connection intact |
| Watched callsigns | done — right-click a station to watch; their traffic is tinted |
| Highlight tiers | done — /CQ, preamble, watch, own; hues and precedence per the KST2Me manual |
| Preamble convention | done — incoming highlight, and optional for outgoing replies |
| Callsign colour identity | done — stable per-callsign colour in log and table |
| Banner collapsing | done — repeated join banners become one room divider |
| Command rate limiting | done — server allows ~1/min; app never spends your budget unasked |
| Chat message parser | done — verified against captured EU traffic (`HHMMZ CALL Name> …`) |
| Away / present status | done — the roster brackets away operators |
| HTML-escaped names | done — `Heinz 2 &amp; 4m` → `Heinz 2 & 4m` |
| Map view | not planned for v0.1 |

## Build and run

```bash
swift build && swift run KST2Mac
```

For a drag-to-Applications bundle:

```bash
./build_app.sh
```

Then `cp -R "build/KST2Mac.app" /Applications/`.

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
4. Press Connect. The room picker defaults to **144 / 432 MHz** — the busy
   European room. It stays live while connected, so switching room is one
   click and no reconnect.

   Note the region-3 rooms (**144 / 432 MHz IARU R3**, **50 MHz IARU R3**)
   are usually empty — an empty station table there is the room, not a
   fault.

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
Sources/KST2MacApp/     SwiftUI app
tools/KSTCapture/      transcript recorder for protocol work
docs/PROTOCOL.md       what's verified vs inferred about the protocol
```

## Next step

The protocol layer is now verified against live traffic rather than
written from documentation — see [docs/PROTOCOL.md](docs/PROTOCOL.md) for
what is captured versus what is still inferred. The remaining unknowns are
join/leave notices and the `/SHow DX` spot format.

To capture more, record a transcript —

```bash
swift run KSTCapture --call VU2CPL --room 2 --probe
```

— and the roster parser can be written against real bytes. `--probe` runs
`/SHOW USER`, `/SHOW MSG 15`, `/SHOW CONFIG` and `/HELP` after joining; all
four reply privately to your own terminal and none post to the room. The
recorder mirrors traffic live and ticks a countdown, so a quiet room looks
different from a hung client.

See [docs/PROTOCOL.md](docs/PROTOCOL.md) for the full captured command set.

It prompts for the password with echo off and never writes it to the file.
Transcripts are git-ignored — they contain whatever the room said while you
were recording, and the login banner echoes your public IP.

## Layout

Each pane shows chat on the left, with **DX spots** above **stations** on
the right — the arrangement KST2Me uses. Raw server output (banners,
`/HELP`, command replies) is behind the terminal button in the pane
header, off by default.

## Windows and panes

**+** in the toolbar adds a chat pane below, with its own room, roster and
connection. Each pane can be closed, or floated into its own window with
the window button in its header — floating keeps the connection, so you do
not re-login or lose the scrollback. **File ▸ New chat window** opens an
empty one.

## Multiple windows

**File ▸ New chat window** opens another window with its own connection,
so you can watch two rooms at once. Each window has its own room picker
and its own station table; settings (callsign, locator, server) stay
global.

The server allows several simultaneous logins on one callsign — three
windows in three rooms have been run with no session dropped — so no SSID
suffix is needed.

## Feeding spots to a DX cluster client

Settings ▸ **DX spot relay** turns KST2Mac into a DX-cluster telnet node
that forwards ON4KST spots. Nothing is translated: with `/SET DXCLX` the
chat already emits standard fixed-column `DX de …` lines, so they are
passed through verbatim.

In [dxca](https://github.com/vu2cpl/dxca), add it as one more node:

```toml
[[cluster_nodes]]
name = "KST2Mac"
host = "127.0.0.1"
port = 7373
login_call = "VU2CPL"
```

Two things to know:

- Spots arrive **disabled** on the ON4KST side, but you do not have to
  remember that: while the relay is on, each pane sends `/SET DXCLX` when
  it joins, and switching the relay on mid-session asks every connected
  pane straight away.
- The feed is **unauthenticated** — anyone who connects gets the spots —
  so it binds `127.0.0.1` only. "Allow connections from the network"
  opens it to the LAN; leave it off unless something on another machine
  needs it.

## Capturing the spot format

Chat ▸ **Record spot-format transcript** runs `/SET DXCLX`, `/SHOW DX 10`,
`/SET DX`, `/SHOW DX 10` on the connected session — a minute apart, since
the server allows about one command a minute — and writes the raw replies
to `~/Desktop/kst2mac-spot-probe.txt`. Chat ▸ **Finish spot transcript**
closes the file after about four minutes.

Those two `/SET` commands change your own spot preferences on the server;
`/UNSET DX` puts them back. The transcript contains whatever the room said
while recording, and the login banner carries your public IP, so read it
before sharing.

## Text size

View ▸ Bigger text / Smaller text / Actual size (⌘+, ⌘-, ⌘0) scales every
font in the app. It defaults larger than the macOS norm because this is
read from across a shack.

## Conventions

Shack-wide rules apply (see `~/.claude/CLAUDE.md`): CDP (Commit, Document,
Push together), private GitHub repos unless explicitly published, credit
upstream authors where due. See `HANDOVER.md` for working notes.
