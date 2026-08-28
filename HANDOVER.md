# KST2Mac — Project Handover
*For continuation in a new Claude session*

**Created:** 2026-08-28 · **Type:** generic (SwiftPM macOS app) · **Status:** v0.3 — login, roster and message parsing all verified against live traffic

---

## What this is

A native macOS SwiftUI client for the ON4KST VHF/UHF/microwave/EME chat.
Same shape as `DXClusterAggregator` and `SkimServer Mac`: SwiftPM package,
`build_app.sh` producing an ad-hoc-signed `.app`, no Xcode project.

Named after and modelled on **KST2Me by Bo OZ2M**. The protocol work is
original — written from captures of the live service, not from KST2Me's
source, which was never consulted — but the name is a play on its, and the
highlight conventions (`/CQ` / preamble / watches, their precedence and
their colours) come straight from OZ2M's manual. The credit line is in the
README and belongs anywhere this project is described publicly, per the
shack credit rule.

## Current state

`swift build` and `swift test` are clean (15 tests). `./build_app.sh`
produces `build/KST2Mac.app`, verified to launch and render.

**Working:** connect / login / join a room, live chat pane with own-call
highlighting, composer with `/CQ` directed messages, station table with
distance + bearing from the operator's locator, password in Keychain,
room + host + port in Settings.

**Verified against live traffic:** login handshake, chat menu, roster
(`/SHow USer`), command set, message lines, the command prompt, away
status, HTML-escaped names. `docs/PROTOCOL.md` marks what is captured
versus inferred — keep that distinction honest, it has caught real bugs
four times now.

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

**2026-08-28, sixth pass — the message format, at last.** A capture in
room 2 (144/432 EU, ~60 stations) produced real traffic, and it broke the
parser in three ways at once.

The big one: **the stamp is `HHMMZ`**, e.g. `0846Z`. Every write-up gives
it as just "TIME". The parser had been accepting `2115` and `21:15` — both
invented — and matched neither `0846Z` nor anything else the server sends,
so it was classifying *every real message* as unrecognised text. It had
never once parsed a genuine chat line. Both speculative forms are still
tolerated (free, harmless) but the tests now say in as many words that
they have never been observed, so nobody cites them as protocol facts.

Also from that capture:

- The `>` hangs off the **end of the name** with no space, and the name
  carries station notes: `Jens 2m>`, `Paolo 2-70-23-13>`, `Bert  2/70>`
  (double space inside the name). Message text can start with a hyphen.
- **Parenthesised roster callsigns mean the operator is away** from the
  terminal (`/UNSET HERE`) — `(DF7KF)`. They stay listed. Now
  `Station.isAway`; the table sorts present operators first and marks the
  rest.
- Callsigns carry `/P` and `-N` suffixes — `F6IFX/P`, `DN9APW-2`. The
  roster callsign pattern rejected the hyphen form outright.
- **Names are HTML-escaped**: `Heinz 2 &amp; 4m`, `Andy &#8482;`. Decoded
  by a hand-rolled `HTMLText` rather than `NSAttributedString(html:)`,
  which would drag in WebKit and require the main thread to unescape a
  name on a socket queue.

Seventeen tests now assert against lines copied verbatim from that
capture. That is the difference between a parser written from
documentation and one written from the wire — the first five passes of
this project were the former, and every one of them was wrong in a way
only traffic could show.

**2026-08-28, seventh pass — first real use.** Connecting to the app for
the first time surfaced a UX bug no test would have caught: the room picker
defaulted to 144/432 IARU **R3**, which is empty, and its title differs
from the busy 144/432 room only by a suffix in a narrow picker. The
operator believed they were in room 2 and were in room 9; the window looked
broken when it was merely showing an empty room faithfully.

Two changes. The default is now **144/432 MHz (room 2)** — a first run that
shows an empty window reads as a broken client, and being regionally
correct is worth less than being obviously working. And the picker is live
while connected: changing it sends `/CHAT <token>` and the server moves the
session without a reconnect, so a wrong choice costs one click instead of a
full re-login. Tokens are asserted against the captured `/HELP` list.

Lesson worth keeping: every protocol bug in this project was found by
capturing traffic, and this one could only be found by *using* the app. Do
both.

**2026-08-28, eighth pass — the command rate limit.** Running the app
against a busy room surfaced the biggest behavioural bug yet, and one no
transcript could have shown:

```
Please wait 55 second(s) between two commands.
```

The server accepts about **one command per minute**. The app was firing
`/SHOW MSG` and `/SHOW USER` 1.5s apart on join and polling the roster
every 60s, so most were refused — the station table sat empty — and worse,
the app was spending the operator's command budget on its own housekeeping,
which can block a command they actually type.

The rule now: **never spend the operator's command budget without being
asked.** Operator input goes out immediately (they are watching, and will
see a refusal); the app's own commands are queued, deduplicated, throttled
to one a minute, and cleared on room switch or disconnect. One command on
join, roster polling at five minutes, `/SHOW MSG` demoted to a button that
says in its tooltip what it costs.

The wait notice is parsed and believed over our own estimate — but
**anchored, and only tested against lines that did not parse as chat**. An
earlier version of that check ran before message parsing, so an operator
typing "please wait 30 seconds, turning the beam" would have been swallowed
as a rate-limit notice and never shown. There is a test for exactly that.

Also: a room switch no longer blanks the station table. With a rate limit,
the replacement roster can be a minute away, and an empty table reads as
"nobody here" rather than "asking" — it now stays visible and marked.

**2026-08-28, ninth pass — banner noise.** The four-line welcome banner
repeats verbatim on every `/CHAT` switch, not just at login, so hopping
rooms filled the chat log with copies of it. The `Welcome …` line is now a
one-line room divider (`.joined`, which also drives the status bar — after
a switch it is the first confirmation the server actually moved us), and
the fixed lines that follow are suppressed (`.boilerplate`). Matching is
prefix-anchored and tested against a message that mentions the same text,
so suppression cannot swallow traffic.

**2026-08-28, tenth pass — clipped composer.** The status bar was attached
with `.safeAreaInset(edge: .bottom)` on an `HSplitView`, and HSplitView
does not pass a bottom safe-area inset down to its children — so the bar
drew *over* the composer and hid the message field, the backlog button and
Send entirely. Replaced with an explicit `VStack { HSplitView; Divider;
statusBar }`, and the composer carries `layoutPriority(1)` plus a minimum
height so the log can never squeeze it out. Worth remembering before
reaching for `safeAreaInset` over any split view.

**2026-08-28, eleventh pass — colour.** The window was legible but flat.
The colour added is meant to carry information rather than decorate:

- **Callsign identity.** Each callsign gets a stable colour from an FNV-1a
  hash into a twelve-entry palette, and wears it in *both* the chat log and
  the station table — so a conversation can be followed down the log and
  tied to its row in the table. Stability across sessions is the whole
  point; changing the palette order retroactively changes what colours
  mean, so treat it as fixed.
- **Distance shading** in the km column, warm (near) to cool (far).
  Deliberately a plain perceptual ramp, *not* a claim about what is
  workable — the same table serves 160 m and 10 GHz.
- **Grids and frequencies** tinted inside message text (`MessageText`).
  Only those two: chat prose is full of numbers ("420/5db", "2x10",
  "160/1") and a highlighter that fires on all of them tints the whole
  line, which is the same as tinting none of it. Frequencies need a
  decimal point for that reason.
- **Mentions** get an accent bar down the left edge as well as a wash, so
  a line naming you is findable while scrolling.

Palette entries are picked to stay legible on both the light and dark
system backgrounds — the app follows the system appearance and has no
theme of its own.

**2026-08-28, twelfth pass — notifications and multiple windows.**

Mention notifications: a Notification Center banner when a line names you,
**only while the app is not frontmost** — a banner for a line you are
looking at is noise, and this app stays open for hours. Authorisation is
requested on first connect rather than at launch, so the prompt arrives
when there is something to be notified about. `Notifier` no-ops entirely
when `Bundle.main.bundleIdentifier` is nil, because
`UNUserNotificationCenter.current()` **traps** in a process without one —
which is exactly what `swift run KST2Mac` is. Do not remove that guard or
command-line runs start crashing.

Multiple windows required a restructure. `AppModel.room` was
`@AppStorage`-backed, which is wrong the moment two windows exist — they
would fight over one stored value. It is now per-instance `@Published`
state, seeded from the stored value and writing back only as the *default
for the next new window*. `SettingsView` likewise no longer takes an
`AppModel` from the environment: settings are global, and with several
windows there is no single model to reach for, so it reads `@AppStorage`
directly.

Each window owns an `AppModel` and therefore its own `KSTConnection` —
one window per room, which is the point.

**Resolved same day:** the server **does** allow several simultaneous
logins on one callsign — three windows were opened in different rooms with
no session dropped. No SSID suffix needed. (`DN9APW-2` in the roster shows
a suffix exists; what it signifies is untested and no longer blocking.)

Three windows did expose one thing: two windows in the *same* room would
each raise a banner for the same message. `Notifier` now suppresses a
repeat of the same sender-plus-text within 30s, so one message means one
banner however many windows can see it.

**2026-08-28, thirteenth pass — emphasis, from KST2Me.** Looking at the
Windows client (KST2Me) surfaced a real gap: it tints three kinds of line
differently — addressed to you, sent by you, and from a callsign you are
watching — and those are exactly the three things you scan a busy chat
for. This client only had the first.

Added `AppModel.Emphasis` with that precedence: mention beats watch beats
own. A line addressed to you matters more than one merely from a station
you follow, and your own line matters least — you already know what you
said.

Watches are stored in shared defaults, not per window: a watch is about a
station, not a room. Right-click a station to watch or unwatch; Chat ▸
Clear all watches empties the list.

One bug fixed along the way: `mentionsMe` matched our callsign anywhere in
the text, so **our own** message quoting our own call read as a mention of
us. The sender is now checked first. There is a test for it.

KST2Me uses saturated fills for these. On a modern display a quiet wash
plus a solid edge bar reads as clearly and keeps the text legible, which a
magenta background does not.

**2026-08-28, fourteenth pass — the KST2Me manual.** Reading OZ2M's
manual (55 pages) settled several things guesswork had got wrong, and
explains the colours in the reference screenshot.

**Two reply mechanisms, not one.** Besides `/CQ` there is the
**preamble**: the partner's callsign typed as the first word of an
ordinary message. It is a *client-side convention with no server
involvement* — §4.7 says plainly it "works for other KST2Me users",
whereas `/CQ` "works for all chat users". I had been about to treat
preamble as a way to dodge the one-command-per-minute limit; it is not,
because a non-participating client would show it as plain text. `/CQ`
stays the outgoing default, with preamble available behind a toggle on
the reply chip.

**Highlight tiers and precedence** now follow the manual (§4.6): `/CQ`
orange (1), preamble pink (2), watch green (3). Those hues are kept
deliberately — ON4KST regulars already read them that way, and recolouring
a familiar convention only makes an unfamiliar client harder to use. The
rendering still differs: quiet wash plus edge bar rather than KST2Me's
saturated row fills, which stay legible on a modern display. `own` is a
fourth tier of our own, since a sent message that looks like everyone
else's gives no confirmation it went out.

**Own callsign is now an implicit watch.** §3.4 recommends exactly this —
watch your own call "in case no /CQ or preamble are received". That
demotes the old loose behaviour (callsign anywhere in the text counted as
a mention) to watch level, which is the right weight, and it comes from
the reference rather than from me.

**Watches match message text, not just callsigns.** KST2Me gives each
watch a scope (message / user list / spots / frequency); this implements
the "included in the chat message" case, its own worked example.

`Preamble.addresses(_:in:)` lives in KSTCore so it is testable — it has to
reject a prefix match (`VU2CPLX`) and survive callsign punctuation (`/P`,
`-2`) while ignoring trailing `:` and `,`.

Also: clicking a callsign in the log addresses your next message to them,
as KST2Me does.

**2026-08-28, fifteenth pass — renamed to KST2Mac.** `~/projects/kst-mac`
→ `~/projects/kst2mac`, product and bundle `KSTMac` → `KST2Mac`,
`net.vu2cpl.kstmac` → `net.vu2cpl.kst2mac`.

A bundle identifier **is** the preferences domain and the Keychain
namespace, so the rename would have silently dropped the operator's
callsign, locator, watches and saved password and looked like a fresh
install. `Migration.swift` carries them over once, copying only where the
new domain is empty and never deleting the old values so a downgrade still
finds its settings. Its two `old…` constants must never be caught by a
find-and-replace — they are the only route back. A blanket rename pass did
exactly that and had to be undone.

The name being a play on KST2Me's brings the shack credit rule into scope;
the README now credits OZ2M.

**2026-08-28, sixteenth pass — two-pane layout and title bar.** Using the
stacked layout for real showed the split was wrong: `VSplitView` gave the
first pane its ideal height and squeezed the second below its 260px
minimum, where it was clipped and lost its Connect button. Both panes now
carry `maxHeight: .infinity` so the space is shared, and the window's own
minimum grows to 780 when the second pane is on — two panes need two of
every chrome row (header, composer, status).

The title bar said only the room name. It now reads `KST2Mac` as the title
with `VU2CPL · Low Band` as the subtitle, which is where macOS expects the
changing detail and keeps the app identifiable in Mission Control and the
Window menu. With two panes the subtitle lists both rooms.

**2026-08-28, seventeenth pass — floating panes and an app icon.**

Panes can now be added, closed, or **torn out into their own window**, and
that forced the right architecture: sessions no longer belong to windows.
`SessionStore` owns every `AppModel` by id; a window holds only a list of
ids. Floating a pane is therefore a list operation — drop the id here,
hand it to a new window — and the TCP connection, scrollback and roster
never notice. Had the window owned the model, moving a pane would have
logged out and back in, losing the scrollback and spending two of the
operator's one-per-minute command slots.

`store.discard(_:)` is the only thing that disconnects, and it must be
called *only* when a pane is genuinely being closed — never when it is
moving between windows, or floating would kill the session it is meant to
preserve.

The window scene is now `WindowGroup(id:"chat", for: String.self)` whose
value is a comma-separated id list, which is what lets a window be opened
around sessions that already exist.

One Swift-specific snag: the `ForEach` body with two optional closures
plus the modifier chain defeated the type checker ("unable to type-check
in reasonable time"). Extracted to a `@ViewBuilder` method, which is the
usual fix.

App icon: a Yagi on a mast with radiating arcs, generated by
`tools/make_icon.swift` (AppKit/CoreGraphics, no dependencies) into
`Resources/AppIcon.png`, which `build_app.sh` already packs into an
`.icns`. A Yagi rather than a generic wifi glyph because this is a VHF
chat, and it still reads as a silhouette at 16pt. Re-run the script to
change it; the source is checked in rather than a binary blob alone.

**2026-08-28, eighteenth pass — legibility and colour, after real use.**

Text size is now a **setting**, not a guess: `Typography` scales every
font from `fontScale`, with View ▸ Bigger / Smaller / Actual size on ⌘+,
⌘- and ⌘0. Default is 1.15, deliberately above macOS default. Two rounds
of picking sizes by eye both landed too small — this is read at arm's
length from a radio, sometimes across a room, and that is not guessable.
New text should use `Typography.mono/text`, never a bare `.caption`.

The window said "Not connected" **twice** — once as the composer
placeholder and once in the status bar. The field now says "Message"; the
status bar owns connection state.

Colour now carries state rather than decorating: one `stateColor` (green
in chat / amber connecting / grey offline) drives the header edge bar, the
header tint, the status dot and the status text together, so any part of
the pane answers "am I on?". Connect is a prominent green button, and the
station table has a tinted "Stations" strip instead of being a grey slab.

Table columns had `min` widths only, so they expanded and pushed Bearing
off the edge behind a scrollbar. They now carry ideal and max widths, and
the station pane is wider by default.

**Regression worth remembering:** changing the window scene to
`WindowGroup(for: String.self)` invalidated saved scene state, so an
existing two-pane window came back with one pane and the operator's setup
was silently lost. Changing a scene's identity discards its restoration
data — say so before shipping such a change.

**2026-08-28, nineteenth pass — the invisible close button.** With three
panes open, only the *first* showed Connect, Float and Close; every pane
below it showed the room picker and nothing else. The controls were being
positioned by a `Spacer()` against the right edge, which held for the top
pane and clipped for the rest — so the close button the operator was
looking for genuinely was not there.

Controls are now **left-aligned immediately after the picker**, where
nothing can push them off. The room name moved to the right of the header
instead, since it is the part that can be truncated harmlessly.

Lesson: a `Spacer`-positioned control is a control that can vanish. In a
stacked layout, put actions on the left and let the decoration take the
squeeze.

Note for anyone repeating the rename: the migrated Keychain item is still
owned by the previous app identity, so macOS prompts once on first use
("KST2Mac wants to use your confidential information…"). Always Allow
settles it.

**2026-08-28, twentieth pass — own title bar, and the probe from inside
the app.**

The title bar is now drawn by the app, not AppKit. `navigationTitle` /
`navigationSubtitle` text takes no font, colour or size from SwiftUI, so
`WindowAccessor` hides the system title (`titleVisibility = .hidden`) and
a `.navigation` toolbar item draws it instead: antenna glyph, **KST2Mac**
in the UTC blue, the callsign in an amber capsule, then the rooms in the
connection colour. It scales with `Typography` like everything else.
`navigationTitle` is still set so the Window menu and Mission Control have
a name to show.

**The spot probe now runs from a connected session.** `KSTCapture` has to
ask for the password on a terminal; a connected app already holds an
authenticated session, so Chat ▸ Record spot-format transcript sends the
probe commands (a minute apart, per the rate limit) and writes every byte
the server returns to `~/Desktop/kst2mac-spot-probe.txt`. Chat ▸ Finish
spot transcript closes it.

`TranscriptWriter` is a separate `@unchecked Sendable` class rather than
part of `AppModel`, because the raw monitor is a `@Sendable` closure
invoked on the connection's own queue — reaching into a `@MainActor` model
from there does not compile, correctly, since it would be a data race.

## Open items

1. **Is the command rate limit per connection or per callsign?** With
   several windows open this decides whether they contend for one budget.
   Symptom if shared: "Please wait N second(s)" appearing far more often
   with three windows than with one. Each window currently polls the
   roster every five minutes independently.
2. **Join/leave notices** — shape unknown, so the table only updates on
   the 60s roster poll. Needs a longer capture.
3. **`/SHow DX` spot format** — now wanted, to bridge spots into dxca.
   dxca ingests via `[[cluster_nodes]]` (host/port/login_call), so the
   clean shape is for KST2Mac to *serve* a small DX-cluster telnet node
   that dxca dials, rather than inventing a private channel. Spots arrive
   disabled (`DX OFF`), so a capture with `/SET DX` — and especially
   `/SET DXCLX`, which the help says gives "CLX format" and may already be
   standard `DX de` cluster lines — is the next step.
4. **Worth stealing from the manual, not yet built:** per-event sounds
   (§3.5); watch scopes beyond message text (§3.4); QRB highlight
   thresholds (§3.10.3); "away" toggle via `/UNSET HERE` (§5.3.4);
   spot-squares filter (§3.6.4). They arrive
   disabled (`DX OFF, ANN OFF, WWC OFF` from `/SHow CONFig`), which is
   why no capture has contained one.
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
