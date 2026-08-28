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

## Login — verified behaviour

The server prompts for three things, **one at a time**, and rejects the
login if they arrive together. Each answer must wait for its own prompt:

1. `Login:` → the callsign/login
2. `Password:` → the password
3. chat menu → a single digit

`KSTConnection` answers each prompt only after seeing it, with a 400 ms
settle delay, and blocks re-entry with a `responding` flag so one prompt is
never answered twice.

## Chat menu

```
50/70 MHz..............1
144/432 MHz............2
Microwave..............3
EME/JT65...............4
Low Band...............5
50 MHz IARU Region 2...7
```

There is no 6 in the published menu. These are the `ChatRoom` cases.

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
swift run KSTCapture --call VU2CPL --room 2 --seconds 180 --out kst-transcript.txt
```

It prompts for the password with echo off, never puts it in `argv`, and
never writes it to the transcript. The transcript *does* contain whatever
the room said while recording, so it is git-ignored — read it, don't
publish it.

Open questions the transcript answers:

1. **Is the stamp `21:15` or `2115`?** The format documentation says only
   "TIME". `LineParser` accepts both; once we know, tighten it.
2. **Exact prompt wording.** `checkForPrompt()` matches loosely
   (`login`/`callsign`/`user`, `password`, then a menu-shaped tail). Real
   prompt text lets us match exactly.
3. **The user list.** Which command produces the roster, and its column
   layout. This is the big one — the station table currently learns
   callsigns only from chat traffic, so it shows who has *spoken*, not who
   is *present*. A roster parser replaces that.
4. **Locator source.** Whether the roster carries locators directly, or
   whether we keep scraping them out of message text.
5. **Join/leave notices** — their shape, so the roster can age out.
6. **The full `/HELP` command set**, for the commands worth surfacing in
   the UI.

## Prior art

- **KST2Me** — the long-standing Windows client.
- **EA6VQ's telnet client** — <https://www.dxmaps.com/kstclient.html>
- **Tučňák** has a built-in KST chat pane —
  <https://tucnak.nagano.cz/wiki/KST_chat>

This client is written fresh against the protocol, not ported from any of
them. If code or layout is ever borrowed, credit goes in the README per the
shack credit rule.
