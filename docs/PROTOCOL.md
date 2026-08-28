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
| `/CHAT value` | Switch rooms in place. Tokens: `28 40 50 50R2 50R3 144 144R2 144R3 GHZ EME HF KHZ WARC` — thirteen, one per menu digit. |
| `/SET NAme`, `/SET QRA` | Push the operator's name and locator from Settings. |
| `/SET HERE`, `/UNSET HERE` | Presence, for an away toggle. |
| `/DX qrg call` | Spot to the inline CLX cluster. |

## `/SHow USer` — the roster, captured 2026-08-28

```
VU2CPL           MK83TE Manoj
(DF7KF)          JO30FK Dithmar
DN9APW-2         JO50LQ TESTING
F6IFX/P          IN87XC Bert  2/70
DL6BF            JO32QI Heinz 2 &amp; 4m
GD0TEP           IO74SD Andy &#8482;
(F1NZC)          JN15MR Jean-Louis JN15
|<--- 17 cols --->|
```

Callsign left-justified in a 17-character field, then locator, then name.

Three things a single-station room could not reveal, all found in the
144/432 EU capture:

- **A callsign in parentheses means the operator is away** from the
  terminal (`/UNSET HERE`). They stay listed, so this is a property of the
  row — `Station.isAway` — not a reason to drop it. The table sorts
  present operators first and marks the rest.
- Callsigns carry `/P` and `-N` suffixes (`F6IFX/P`, `DN9APW-2`).
- **Names are HTML-escaped**: `Heinz 2 &amp; 4m`, `Andy &#8482;`. Decoded
  by `HTMLText`, which is hand-rolled rather than
  `NSAttributedString(html:)` — that would pull in WebKit and demand the
  main thread to unescape a name field on a socket queue.
- A name may end in something locator-shaped (`Jean-Louis JN15`), so only
  the field immediately after the callsign is treated as the locator.

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

## Message format — verified 2026-08-28 (144/432 EU)

```
0846Z OZ5QF Jens 2m> (F6IFX/P)  Tnx qso Bert. Best 340/5 73
0844Z SM5DWF Peder 2m> 160/1
0845Z F6IFX/P Bert  2/70>  tnx fast qso 73 Jens
0836Z YO7CGS Dumitru> - 083430, copy rrrr 420/5db. Tnx, Luigi! 73!
0831Z IK7UXW Paolo 2-70-23-13> stop cq cul tnx
```

    HHMMZ FROMCALL Name> [(TOCALL)]  text

- The stamp is `HHMM` **followed by `Z`** — UTC. Second-hand write-ups
  give it as just "TIME". An earlier revision of this parser accepted
  `2115` and `21:15` but not `0846Z`, so it classified **every** real
  message as unrecognised text. The parser still tolerates the other two
  forms; neither has ever been observed, and the tests say so.
- The `>` hangs off the **end of the name** with no space before it, and
  the name routinely carries station notes: `Jens 2m>`,
  `Paolo 2-70-23-13>`, `Bert  2/70>` — that last one has a double space
  inside the name.
- `(TOCALL)` appears only on a directed `/CQ` message; the text starts two
  spaces after it.
- Message text may begin with a hyphen.
- Sender callsigns carry `/P` and `-N` suffixes.
- The command prompt has the same shape and must be matched first.

Message text and names are **HTML-escaped** — see the roster note below.

## Command rate limit — verified 2026-08-28

The server accepts roughly **one command per minute**, and refuses a
too-soon one with:

```
Please wait 55 second(s) between two commands.
```

This is not in any write-up, and no transcript revealed it — it only
appears when a client issues commands at a realistic pace, which is to say
when the app is actually used. The first build fired `/SHOW MSG` and
`/SHOW USER` 1.5s apart on join and polled the roster every 60s, so almost
every one was refused and the station table sat empty.

Ordinary chat text does **not** appear to be limited; the notice says
"between two commands". Whether `/CQ` counts as a command is unverified.

The rule the client follows: **never spend the operator's command budget
without being asked.**

- Anything the operator types goes out immediately — they are watching and
  will see any refusal.
- The app's own housekeeping is queued, deduplicated, and throttled, and
  yields to user commands.
- One command on join (`/SHOW USER`), roster polling every five minutes,
  and `/SHOW MSG` demoted to a button.
- The notice is parsed and believed over our own estimate. It is matched
  **anchored to the start of a line, and only against lines that did not
  parse as chat**, so an operator typing "please wait 30 seconds" cannot
  silently reconfigure the throttle.

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

1. ~~Message-line format~~ — captured, see above.
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
