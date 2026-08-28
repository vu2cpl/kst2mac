# KST Mac — Project Handover
*For continuation in a new Claude session*

**Created:** 2026-08-28 · **Type:** generic (SwiftPM macOS app) · **Status:** v0.1 working

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

## Open items

1. **Record a live transcript** — `swift run KSTCapture --call VU2CPL
   --room 2 --seconds 180`. Everything below is blocked on it.
2. **Roster parser** — find the user-list command and its column layout,
   then populate the station table from the roster instead of from chat
   traffic. Biggest single improvement available.
3. **Tighten prompt matching** in `checkForPrompt()` once the real prompt
   wording is known (currently matched loosely on substrings).
4. **Confirm the timestamp format** — `21:15` or `2115`. The parser
   accepts both; narrow it once known.
5. **Join/leave notices** so the roster can age stations out.
6. App icon (`Resources/AppIcon.png`, 1024×1024) — `build_app.sh` packs
   it automatically if present.
7. Not yet decided: notarisation (`notarize.sh`, as in the sibling Mac
   apps) if this is ever distributed beyond the shack.
8. Not planned for v0.1: map view, DXClusterAggregator spot integration.
   Both were explicitly deferred when the scope was set.

## Gotchas

- **No TLS on port 23000.** The password is sent in clear. The README and
  both password UIs say so; keep saying so.
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
