# KST Mac — Project Handover
*For continuation in a new Claude session*

**Created:** 2026-08-28 · **Type:** generic (SwiftPM macOS app) · **Status:** v0.2 — login and roster working; message format still unseen

---

## What this is

A native macOS SwiftUI client for the ON4KST VHF/UHF/microwave/EME chat.
Same shape as `DXClusterAggregator` and `SkimServer Mac`: SwiftPM package,
`build_app.sh` producing an ad-hoc-signed `.app`, no Xcode project.

Written fresh from the protocol — **not** a fork or port of KST2Me,
EA6VQ's client, or Tučňák's chat pane, so no credit line is owed. If that
ever changes, the shack credit rule applies.

## Current state

`swift build` and `swift test` are clean (15 tests). `./build_app.sh`
produces `build/KST Mac.app`, verified to launch and render.

**Working:** connect / login / join a room, live chat pane with own-call
highlighting, composer with `/CQ` directed messages, station table with
distance + bearing from the operator's locator, password in Keychain,
room + host + port in Settings.

**Not working yet:** the station table is populated from chat traffic only
— it shows who has *spoken*, not who is *present*. That needs the server's
roster command, whose format is unverified.

## Architecture notes worth keeping

- **`KSTCore` has no UI dependency.** Telnet codec, login state machine,
  line parser and Maidenhead maths are all testable without AppKit. Keep
  it that way.
- **The login is prompt-driven and impatient.** The server rejects the
  login if callsign / password / chat number arrive together. Each answer
  waits for its own prompt, then pauses 400 ms. A `responding` flag stops
  a prompt being answered twice — an earlier draft set the phase before
  the delayed write landed, which raced.
- **Everything sent after login is broadcast instantly.** There is no
  draft state on the server. `send(_:)` refuses to write outside `.inChat`
  and the composer is disabled until then. Don't loosen this.
- **Unclassified server lines are shown verbatim**, never dropped. The
  banner, `/HELP` output and the roster all currently land in this bucket,
  and a client that hides what it doesn't understand is worse than one
  that shows it raw.
- **Maidenhead digit order is longitude-then-latitude.** JO20 → JO30 is a
  step *east*, not north. Three of the first-draft tests asserted the
  wrong thing here; the maths was right.

## What changed

**2026-08-28, second pass — first live capture.** The transcript
immediately falsified two things v0.1 was built on:

- **The chat menu has 13 rooms, not 6.** Every third-party write-up of
  this menu lists only 1–5 and 7 and asserts there is no 6. Wrong on both
  counts, and the omissions were the ones that matter from VU: 6 = 50 MHz
  IARU R3, 9 = 144/432 MHz IARU R3. `ChatRoom` now carries all thirteen,
  transcribed verbatim, and the app default moved from room 2 (Europe) to
  room 9.
- **`KSTCapture` printed nothing while running**, so a successful join to
  a silent room was indistinguishable from a hang — which is exactly how
  it was reported. It now mirrors traffic to the terminal and ticks a
  seconds-left / bytes-captured counter. A capture tool that shows nothing
  is not a capture tool.

**2026-08-28, third pass — the 480-byte stall.** The second capture came
back byte-for-byte identical to the first, in a different room, with
`/HELP` unanswered. Two rooms cannot both stop at exactly 480 bytes, so it
was never a quiet room: the client was stalling at the chat menu and had
been all along.

Root cause, and it is a good one to remember: **Swift treats `"\r\n"` as a
single `Character`**, so `pending.firstIndex(of: "\n")` never matched.
Nothing was ever split into lines — the whole session accumulated in one
buffer. `Login:` and `Password:` still got answered because the prompt test
was a substring search over that entire buffer. The chat menu did not,
because its test additionally required the buffer to *end* in a colon, and
the buffer ended with the CR-LF after `Your choice           :`.

Two fixes, both needed:

- Split on **unicode scalars**, where `\r` and `\n` are separate. This also
  makes a CR and its LF landing in different TCP segments a non-event.
- Take the prompt candidate from the un-terminated remainder **or**, when
  there is none, the last complete line — so a prompt is found whether or
  not it carries a newline.

Both now live in `LineAccumulator` / `LoginPrompt`, out of `KSTConnection`
and therefore testable without a socket. Six regression tests cover it,
including one that replays the real banner split at *every* byte offset and
asserts the prompt is found each time — the packet-segmentation dependence
is what made this look intermittent.

I had also written into this file and into `docs/PROTOCOL.md` that the
prompts carry no trailing newline, described as confirmed. It was inferred
from a transcript, never tested, and it was wrong: `nc` shows `Login:` is
CRLF-terminated. Both files are corrected.

**2026-08-28, fourth pass — login works.** With the scalar-splitting fix
the handshake completes: `Welcome Manoj VU2CPL on this 144/432 MHz IARU R 3
amateur chat`, and `/HELP` replied. 2739 bytes, up from the 480-byte stall.

The full command set is now captured verbatim in `docs/PROTOCOL.md`. The
headline: **`/SHow USer` is the roster command** the station table has been
waiting for. Also useful and previously unknown — `/SHow MSG [nbr]`
backfills scrollback, `/SHow LOC` gives server-side QRB/QTF, `/CHAT value`
switches rooms without reconnecting, `/SET NAme` and `/SET QRA` push the
operator's name and locator, `/SET HERE` is presence.

Two smaller findings folded in: the welcome banner contains a literal **NUL
byte** (the telnet codec drops it now), and the server reprints a command
prompt — `HHMMZ CALL <chat> chat>` — after every command and at idle. That
is furniture; `LineParser` gives it its own `.prompt` kind and the UI keeps
it out of the chat log, using it for the status line and the server clock.
It also shows the server thinks in `HHMM` + `Z`, UTC.

**2026-08-28, fifth pass — the roster works.** `/SHow USer` captured:

```
VU2CPL           MK83TE Manoj
```

Callsign in a 17-column field, then locator, then name — parsed by
whitespace split and locator *shape*, not by offset, since the one captured
row has a short callsign and `SV1DH/P` would overrun it.

The catch worth remembering: **field order is command-specific.**
`/SHow CONFig` prints `CALL Name LOC` where the roster prints
`CALL LOC Name`, so a roster row cannot be recognised in isolation. Command
replies have no delimiters — but the server reprints its prompt when one
ends, so the prompt *is* the delimiter. `KSTConnection` marks a
`/SHow USer` outstanding and parses roster rows only until the next
`.prompt`, then emits `.rosterComplete`. There is a test asserting the
config line parses wrongly in isolation, to keep that reasoning attached to
the code.

The app now asks for the roster 3s after joining and every 60s after, plus
a manual refresh button, and backfills the window with `/SHOW MSG` on join.
The station table finally shows who is *present* rather than who has
spoken.

**Why every capture has looked dead:** the 144/432 IARU R3 chat had exactly
one station in it — VU2CPL. `/SHOW MSG 15` returned nothing because that
room has no history. Nothing was ever wrong with the room choice; R3 is
just empty.

Still open, and now the only protocol unknown: **no chat message line has
ever been captured.** Probe room 2 (144/432 EU) during the EU evening or
room 4 (EME); `/SHOW MSG 15` there returns real messages even in silence.

## Open items

1. **Capture a real message line** — `swift run KSTCapture --call VU2CPL
   --room 2 --seconds 120 --probe` during the EU evening. The R3 chat is
   empty, so it can never supply one. This is the last protocol unknown.
2. **Confirm the message-line format** — `21:15` or `2115`. The parser
   accepts both; narrow it once known.
3. **Join/leave notices** so the table updates between roster polls.
4. App icon (`Resources/AppIcon.png`, 1024×1024) — `build_app.sh` packs
   it automatically if present.
5. Not yet decided: notarisation (`notarize.sh`, as in the sibling Mac
   apps) if this is ever distributed beyond the shack.
6. Not planned for v0.1: map view, DXClusterAggregator spot integration.
   Both were explicitly deferred when the scope was set.

## Gotchas

- **No TLS on port 23000.** The password is sent in clear. The README and
  both password UIs say so; keep saying so.
- **The login banner echoes your public IP back at you**, so a transcript
  identifies the machine that recorded it. One more reason not to publish
  one.
- **`KSTCapture` transcripts are git-ignored** (`*transcript*.txt`). They
  contain whatever the room said while recording. Read them locally, don't
  commit or publish them.
- The capture tool reads the password with `termios` echo off and never
  puts it in `argv` — `ps` is world-readable. Don't "simplify" it to a
  command-line flag.

## Conventions (see ~/.claude/CLAUDE.md)

- **CDP** — Commit, Document, Push together on every substantive change.
- GitHub repos are **private** unless explicitly published.
- Credit upstream authors where the work is derivative.
