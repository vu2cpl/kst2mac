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

The prompts (`Login:`, `Password:`, `Your choice           :`) are each
**CRLF-terminated**. The server writes the prompt, ends the line, and then
waits. Verified by connecting with `nc` and sending nothing:

```
$ { sleep 6; } | nc www.on4kst.info 23000 | xxd
... 4c 6f 67 69 6e 3a 0d 0a          Login:..
```

An earlier revision of this file claimed the opposite — that prompts carry
no newline and the trailing CRLF in a transcript was the server
acknowledging our answer. That was wrong, inferred from a transcript rather
than tested, and it cost two dead capture runs. Treat anything in this file
that has no reproduction command attached with the same suspicion.

The banner also echoes your public IP back at you, so a transcript
identifies the machine that recorded it.

Note for anyone parsing this stream in Swift: `"\r\n"` is a **single**
`Character`, so splitting on `"\n"` at the Character level never fires.
Split on unicode scalars. This was the root cause of the 480-byte stall.

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

## After login — verified 2026-08-28

```
Welcome <Name> <CALL> on this 144/432 MHz IARU R 3 amateur chat (by ON4KST)
<NUL>
Use the inline ON4KST-2 CLX DX cluster for your spot.
More info type "/HELP"
0829Z VU2CPL 144/432 MHz IARU R 3 chat>
```

Two things to note. The banner contains a literal **NUL byte**, which the
telnet codec now drops. And the server reprints a **command prompt** after
every command and at idle:

```
HHMMZ CALLSIGN <chat name> chat>
```

That is furniture, not traffic — `LineParser` classifies it as `.prompt`
and the UI keeps it out of the chat log, using it only for the status line
and the server's UTC clock. It also tells us the server thinks in
**`HHMM` + `Z`, UTC**.

## Command set — captured verbatim from `/HELP`

```
/Help              The list of the commands available.
/CHAT  value       Login into another chat. Values are 28 40 50 50R2 50R3
                   144 144R2 144R3 GHZ EME HF KHZ WARC.
/CQ    call msg    To send a public msg seen in highlight by the callsign.
/DX    qrg call [info] To send a DX spot.
/SET   ANN         Allow announce messages to come out on your terminal.
/SET   DX          Allow DX messages to come out on your terminal.
/SET   DXCLX       Allow DX messages ... at CLX format.
/SET   HERE        Tell the system you are present at your terminal.
/SET   MYCLx value To give the cluster where to spot the DX.
/SET   NAme value  Set your name.
/SET   QRA value   Set your QRA Grid locator.
/SET   QRG value   Filter the DX spots. Values are 40 50 70 144 222 432 GHZ
/SET   WWC         Allow World Wide Converse messages ...
/SHow  CLx         The list of the available DX clusters.
/SHow  CONFig      Show your personal settings.
/SHow  DX [nbr]    Get the last DX spots (QRG as your filter settings).
/SHow  MSG [nbr]   Get the last chat messages.
/SHow  MYCLx       To show the DX cluster where the DX spot is sent.
/SHow  LOC value   To show the locator of a station with QRB and QTF.
/SHow  NODes       To show the way to access to the chat from packet radio.
/SHow  USer [call] Show the users connected to this chat.
/UNSET ANN | DX | HERE | QRG | WWC
/UPDTLOC call loc  To ask to the sysop to update the locator of a station.
/Quit              Exit from the chat.
```

Capitalisation in the listing marks the accepted abbreviation: `/SHow` →
`/SH`, `/SET NAme` → `/SET NA`.

The ones that matter for this client:

| Command | Why |
|---|---|
| `/SHow USer` | **The roster.** This is what the station table needs. |
| `/SHow MSG [nbr]` | Backfill scrollback on connect instead of starting blank. |
| `/SHow LOC call` | Server-side QRB/QTF — a cross-check on our own Maidenhead maths. |
| `/CHAT value` | Switch rooms without dropping the connection. |
| `/SET NAme`, `/SET QRA` | Push the operator's name and locator from Settings. |
| `/SET HERE`, `/UNSET HERE` | Presence, for an away toggle. |
| `/DX qrg call` | Spot to the inline CLX cluster. |

## `/SHow USer` — the roster, captured 2026-08-28

```
VU2CPL           MK83TE Manoj
|<--- 17 cols --->|
```

Callsign left-justified in a 17-character field, then locator, then name.

**Field order is command-specific.** `/SHow CONFig` prints the same three
values in a different order:

```
VU2CPL Manoj MK83TE
DX OFF, ANN OFF, WWC OFF
```

So a roster row cannot be recognised on its own — parsed blind, the config
line yields `MK83TE` as part of the name and no locator at all. Command
replies carry no start/end markers, but the server reprints its prompt when
one finishes, so **the prompt is the delimiter**: `KSTConnection` marks a
`/SHow USer` as outstanding and parses roster rows only until the next
`.prompt` line, then emits `.rosterComplete`.

Columns are parsed by splitting on whitespace and identifying the locator
by shape, not by fixed offset — the single captured row has a short
callsign in it, and `SV1DH/P` would overrun the field.

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

1. **Message-line format — the last unknown.** Still no chat message has
   ever been captured. `/SHOW MSG 15` in the R3 chat returned nothing at
   all, because that room has no history and, at the time of capture,
   exactly one station in it. The command prompt uses `HHMMZ`, so `HHMM`
   is the better guess of the two forms `LineParser` accepts — inference,
   not evidence.

   To settle it, probe a room that has traffic: `--room 2` (144/432 EU)
   during the European evening, or `--room 4` (EME). `/SHOW MSG 15` there
   will return real message lines even if nobody is speaking at that
   moment.
2. ~~Locator source~~ — `/SHow USer` carries the locator directly.
4. **Join/leave notices** — their shape, so the roster can age out.
4. ~~The full `/HELP` command set~~ — captured, see above.

## Prior art

- **KST2Me** — the long-standing Windows client.
- **EA6VQ's telnet client** — <https://www.dxmaps.com/kstclient.html>
- **Tučňák** has a built-in KST chat pane —
  <https://tucnak.nagano.cz/wiki/KST_chat>

This client is written fresh against the protocol, not ported from any of
them. If code or layout is ever borrowed, credit goes in the README per the
shack credit rule.
