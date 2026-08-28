# The ON4KST chat protocol, as far as we know it

This file is the single place where "what we actually verified" is kept
apart from "what we inferred". Anything in the **Unverified** section is a
guess the code is written to survive, not a fact.

## Connection

| | |
|---|---|
| Host | `www.on4kst.info` |
| Port | `23000` (plain TCP, **no TLS**) |
| Framing | Line-oriented text, CRLF |

The service is reachable with a telnet client, so a real telnet client will
open with option negotiation. `TelnetCodec` strips all IAC signalling and
refuses every option (DONT to every WILL, WONT to every DO) so the chat
stream stays plain 8-bit text.

**The password crosses the wire in clear.** Use a password dedicated to
ON4KST and used nowhere else.

## Login — verified against a live session (2026-08-28)

Full banner and handshake, captured verbatim:

```
This telnet access is reserved to HAM only
Your IP address is <your IP>
Login:
Password:

Chat selection ?
...menu...
Your choice           :
```

The prompts (`Login:`, `Password:`, `Your choice           :`) arrive with
**no trailing newline** — the CRLF that follows each one in a transcript is
the server acknowledging *our* answer, not part of the prompt. That is why
`checkForPrompt()` inspects the un-terminated tail rather than completed
lines, and it is confirmed correct.

The banner also echoes your public IP back at you, so a transcript
identifies the machine that recorded it.

## Login — behaviour

The server prompts for three things, **one at a time**, and rejects the
login if they arrive together. Each answer must wait for its own prompt:

1. `Login:` → the callsign/login
2. `Password:` → the password
3. chat menu → a single digit

`KSTConnection` answers each prompt only after seeing it, with a 400 ms
settle delay, and blocks re-entry with a `responding` flag so one prompt is
never answered twice.

## Chat menu

Captured verbatim — **thirteen** rooms, not six:

```
Chat selection ?
50/70 MHz..............1
144/432 MHz............2
Microwave..............3
EME/JT65...............4
Low Band...............5
50 MHz IARU Region 3...6
50 MHz IARU Region 2...7
144/432 MHz IARU R 2...8
144/432 MHz IARU R 3...9
kHz (2000-630m).......10
Warc (30,17,12m)......11
28 MHz................12
40 MHz................13
Your choice           :
```

Third-party write-ups of this menu list only rooms 1–5 and 7 and state
there is no 6. Both claims are wrong, and the missing rooms are the ones
that matter from VU: **6 = 50 MHz IARU R3** and **9 = 144/432 MHz IARU
R3**. These are the `ChatRoom` cases, and 9 is the app default.

## Message format

```
TIME FROMCALLSIGN FROMNAME > (TOCALLSIGN) MESSAGETEXT
```

The `(TOCALLSIGN)` group appears only on a directed message, which is sent
with `/CQ CALL text`. `/HELP` lists the command set.

## The one rule that shapes the client

**Anything written to the socket after login goes straight to the room.**
There is no draft state, no confirmation, no local echo layer. Hence:

- `KSTConnection.send(_:)` refuses to write unless the state machine is in
  `.inChat`.
- The composer field in the UI is disabled until then.
- Nothing is ever sent automatically once we are in the room.

## Unverified — settle these with a transcript

Run the recorder and read the output:

```bash
swift run KSTCapture --call VU2CPL --room 9 --seconds 180 --probe
```

It mirrors the traffic to the terminal live and ticks a
seconds-remaining/bytes counter, so a quiet room is visibly different from
a hung client. `--probe` sends `/HELP` once joined — the one command worth
sending, since its reply names the roster command we still need.

It prompts for the password with echo off, never puts it in `argv`, and
never writes it to the transcript. The transcript *does* contain whatever
the room said while recording, so it is git-ignored — read it, don't
publish it.

Open questions the transcript answers:

1. **Is the stamp `21:15` or `2115`?** The format documentation says only
   "TIME". `LineParser` accepts both; once we know, tighten it. The
   2026-08-28 capture joined a silent room, so no message lines were seen.
2. **The user list.** Which command produces the roster, and its column
   layout. This is the big one — the station table currently learns
   callsigns only from chat traffic, so it shows who has *spoken*, not who
   is *present*. A roster parser replaces that.
3. **Locator source.** Whether the roster carries locators directly, or
   whether we keep scraping them out of message text.
4. **Join/leave notices** — their shape, so the roster can age out.
5. **The full `/HELP` command set**, for the commands worth surfacing in
   the UI.

## Prior art

- **KST2Me** — the long-standing Windows client.
- **EA6VQ's telnet client** — <https://www.dxmaps.com/kstclient.html>
- **Tučňák** has a built-in KST chat pane —
  <https://tucnak.nagano.cz/wiki/KST_chat>

This client is written fresh against the protocol, not ported from any of
them. If code or layout is ever borrowed, credit goes in the README per the
shack credit rule.
