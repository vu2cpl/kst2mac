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

**2026-08-28, twenty-first pass — header, settled by mockup.** Several
build-and-look rounds had failed to land this, so the layouts were drawn
as mockups first and chosen before any code changed. Worth repeating for
anything visual.

Two rules came out of it, both from the operator:

1. **Global row carries only global facts** — app name, callsign, UTC.
   Room, station counts and connection state are per-pane; with three
   panes open a single global value for any of them says nothing. The
   callsign appears once for the same reason, and is identity rather than
   a control: connecting is per-pane, so one callsign button could not say
   which pane it would connect.
2. **Fixed-width controls.** "Connect" and "Disconnect" are different
   lengths, so a naturally-sized button changes width whenever a pane's
   state changes and the controls to its right stop lining up between
   panes. `OutlineButtonStyle` pins the width; the room picker is pinned
   too.

Buttons are outlined rather than filled — Connect is pressed once a
session, and with panes stacked the solid green fills dominated the
window. Three states now, including an amber **Connecting…** which
previously did not exist: the button jumped straight to Disconnect while
the handshake was still running.

The per-pane bottom status bar is gone; its content moved into the pane
header, giving every pane back about 26px, which matters when stacking
three.

**2026-08-28, twenty-second pass — sounds, and two header bugs.**

**Per-event sounds** (KST2Me manual §3.5): a chosen sound for `/CQ`, for a
preamble, and for a watch, picked in Settings from everything macOS ships
plus anything in `~/Library/Sounds` — enumerated at runtime, so dropping
in a personal `.aiff` needs no code change. Default for `/CQ` is Morse,
which a ham app may as well use.

Sound deliberately plays **whether or not the app is frontmost**, unlike
the notification banners. That is the case banners cannot cover, and the
one this app is actually used in: the window visible on a second monitor
while you work the radio.

Two suppressions matter more than the feature. Repeats inside two seconds
are dropped, and joining a room — or pressing the backlog button — goes
quiet for eight seconds, because `/SHOW MSG` replays fifteen lines at once
and several may name you. A volley of alerts about messages sent before
you arrived is worse than silence.

**Two header bugs found by the operator:**

- The app name appeared **twice**. `WindowAccessor` hid the system title,
  but `navigationTitle` re-applied it afterwards. Dropping
  `navigationTitle` and setting `window.title` directly gives the Window
  menu and Mission Control a name without drawing one.
- The **callsign box stayed amber when connected.** It had been made
  identity-only on the reasoning that aggregate state is ambiguous across
  panes — but that reasoning does not apply here: "am I on the chat at
  all" has one true answer however many panes are open. It goes green when
  any pane is in a chat; which pane is which stays the pane rows' job.

**2026-08-28, twenty-third pass — the header never redrew.** The callsign
stayed amber after connecting even though the logic was right, and this is
worth remembering because it will recur.

`ChatWindow` observes `SessionStore`. It does **not** observe the
individual `AppModel`s — nothing in SwiftUI makes a view observe objects
it merely reaches through another observed object. So `isInChat` flipping
on a session redrew that pane (which holds the model as an
`@EnvironmentObject`) but never the window header derived from the same
models.

The store now subscribes to each session's `$isInChat`, `$room` and
`$serverTime` and republishes the aggregate — `anyConnected`,
`connectedRooms`, `clock`. The header reads those. Anything else
window-wide derived from per-session state must go through the store the
same way; deriving it inline from `models` compiles and silently never
updates.

**2026-08-28, twenty-fourth pass — spot format captured, and two render
bugs.**

The probe ran from the app on a live session, and the answer is the good
one: **`/SET DXCLX` emits standard fixed-column `DX de …` cluster lines**,
identical in shape to what any AR-Cluster or CLX node sends. So the dxca
bridge is a *relay* — serve a small cluster telnet node, pass the lines
through verbatim, and let dxca dial it as one more `[[cluster_nodes]]`
entry. `/SET DX` gives the same content chat-prefixed and single-spaced;
CLX is the one to forward. Full detail in `docs/PROTOCOL.md`.

Two rendering bugs the operator spotted in the same window:

- **Wrapped messages drew over the row below.** The row used
  `HStack(alignment: .firstTextBaseline)`, which measured the row at
  one line's height, so a wrapped message overflowed its neighbour. Now
  `.top` alignment plus `.fixedSize(horizontal: false, vertical: true)` on
  the text, so the row reports its true wrapped height.
- **DX spot lines wrapped and scrambled.** They are fixed 80-column text;
  wrapping destroys the columns. Server lines now scroll sideways instead
  of wrapping.

Also fixed the app name appearing twice *again*: SwiftUI re-applies its
title handling whenever the toolbar rebuilds — several times a second on a
busy chat — which undid `titleVisibility = .hidden`. `WindowAccessor` now
re-applies after SwiftUI's pass rather than during it.

**2026-08-28, twenty-fifth pass — the DX-cluster relay.** KST2Mac now
serves its spots as a cluster node on 127.0.0.1:7373, which dxca dials as
one more `[[cluster_nodes]]` entry.

It is a **relay, not a translator**, and that is the whole design: with
`/SET DXCLX` the chat already emits the exact fixed-column `DX de …` line
a cluster client expects, so the line is forwarded byte-for-byte. The only
normalisation is stripping the chat's `HHMMZ ` prefix from `/SET DX`-format
spots, because dxca parses with a literal `strip_prefix("DX de ")` and
would otherwise reject them. Six tests cover both formats against captured
lines.

The handshake was written against dxca's actual client
(`crates/dxca-connect/src/dxcluster/mod.rs`), not guessed: it watches for
`login:` / `callsign:` / `call:` as case-insensitive substrings, sends its
`login_call`, uses no password, and takes a welcome line or any data as
evidence the session is alive. The banner and prompt satisfy all of that.
Verified end to end with `nc`.

Three things that bit, worth remembering:

- **The relay never started.** `SpotRelayHost` is a lazy singleton and
  nothing referenced it at launch, so it was only constructed when
  Settings was opened. `KST2MacApp.init` touches it now.
- **`@AppStorage` in an ObservableObject does not drive `didSet`
  dependably** — toggling the setting never started the listener. Plain
  `@Published` over `UserDefaults` instead. `@AppStorage` is a View
  wrapper; treat it as one.
- **`requiredLocalEndpoint` does not confine an `NWListener`** — it reads
  as if it should, and silently fails to bind at all. The working way is
  `parameters.requiredInterfaceType = .loopback`, verified by connecting
  from the LAN address and being refused.

Loopback is the default because the feed is unauthenticated: anyone who
connects gets the spots. There is a setting to open it to the network,
off unless asked for.

Port 7373 was checked against `/etc/services` and the shack's ports
(2237, 2333–2335, 7550, 7575, 7580, 8300, 8883, 1883, 23000) — no clash.

**Decision, 2026-08-28: cluster login only, and no relay password.**

The direction was questioned — why does KST2Mac not push to the Pi
instead? Because dxca has no inbound path for spots. It only *publishes*
to MQTT (never subscribes), its HTTP POST routes are setup/login/refresh
only, the UDP sources take WSJT-X binary datagrams rather than text, and
its telnet 7575 is an output for loggers. `[[cluster_nodes]]`, which dxca
*dials out* to, is the one door. So the supplier has to listen. Pushing
instead would mean changing dxca, not KST2Mac.

No password on the relay, by explicit instruction: cluster telnet is
plaintext anyway and this is a shack-internal link. The LAN is the trust
boundary. Do not add auth here unasked.

**2026-08-28, twenty-sixth pass — the amber link.** dxca connected to the
relay but showed amber, not green. Its client distinguishes *open* from
*proven*: a session is only proven once it sees a spot, a WWV report, an
announcement, or a **node prompt** — any line that ends in `>` and
contains ` de `. Our welcome lines classified as `Other`, so the link read
as unhealthy until a spot happened along, which on a quiet band could be a
long wait.

The relay now closes its login with `VU2CPL de KST2Mac 28-Aug-2026 1401Z >`,
which is what a real node sends anyway. Green immediately. There is a test
checking our prompt against the same rule dxca applies, plus a real
DXSpider prompt as a cross-check.

The lesson is the same as the ON4KST protocol work: read the other end's
parser rather than guessing what it wants. Three separate details —
`login:` as a prompt substring, `strip_prefix("DX de ")`, and this — all
came from `crates/dxca-connect/src/dxcluster/`.

**2026-08-28, twenty-seventh pass — stop depending on a manual `/SET
DXCLX`.** Whether the server remembers the DX flag between sessions is
unverified — `/SHow CONFig` lists it under "personal settings" beside the
name and locator, which *are* persistent, so it probably survives, but
probably is not good enough for something whose failure mode is a relay
that silently forwards nothing.

So while the relay is enabled, each pane sends `/SET DXCLX` on joining,
queued as housekeeping like the roster poll. Repeating it is harmless —
the server answers the same either way — and it costs one slot per join.
Switching the relay on mid-session asks every already-connected pane
immediately, rather than waiting for a reconnect.

Panes do **not** send it when the relay is off: nothing is listening, and
it would be changing the operator's server-side preferences for no reason.

**2026-08-28, twenty-eighth pass — one window, four streams.** Messages,
DX spots and raw server output were all landing in the same log, which
made the window a jumble. They are different kinds of thing: conversation
is read in sequence, spots and the roster are *scanned*, and the raw feed
matters only when something is wrong.

Layout now follows KST2Me — chat left, **DX spots** top right, **stations**
bottom right — with the raw feed behind a terminal toggle in the pane
header, off by default and remembered per pane.

`AppModel` keeps three streams instead of one: `lines` (conversation),
`spots`, `serverLines`. Anything `.other` or `.local` is routed to the
server log rather than the chat, which is what took the banners, `/HELP`
output, command replies and our own notices out of the conversation.

`SpotRecord` / `SpotParser` split a spot into frequency, DX call, comment,
spotter and time for the table. **The relay does not use it** — it still
forwards the original line verbatim — so every field is optional and the
raw line is always kept: a display slip must never become a data one.
Spots are newest-first, because nobody scrolls a cluster feed to catch up.

**2026-08-28, twenty-ninth pass — the message box in the wrong place.**
Splitting the panes left the composer inside `ChatPane`, so with the
server log open the input box sat *between* the two logs. An input box in
the middle of a column reads wrong: it belongs at the foot of everything
it writes into.

`Composer` moved out of `ChatPane` to the bottom of the left column, so
the order is chat, server log, input.

It also now knows what it is sending. A leading `/` makes it a command to
the server rather than a message to the room — the placeholder changes to
"Command", the `/CQ` recipient chip is hidden (a command is not addressed
to anyone), and sending one **opens the server log**, because that is
where the reply lands and typing a command into a pane you cannot see is
no use.

Worth recording: `/SHow CONFig` in the Low Band room reports `DXCLX ON,
ANN ON` and `Accepted QRG for DX spots: 137 KHz 1.8 MHz 3.5 MHz`.
**Corrected below** — settings turned out to be per chat, not per account.

**2026-08-28, thirtieth pass — three bugs, reported together.**

**`/CHAT` does not always move the session.** The server can answer by
re-presenting the chat-selection menu and waiting for a digit, exactly as
at login. We treated `/CHAT` as fire-and-forget and emitted `.loggedIn`
immediately, so the session sat at that menu: the room never changed, and
everything issued afterwards — the roster poll, `/SET DXCLX` — went into a
prompt. `pendingRoomChoice` now holds the digit until either the menu
appears and is answered, or a `Welcome … on this <room>` line confirms the
move. The welcome line is the only trustworthy end to a switch; `.loggedIn`
is emitted then, not on sending the command.

**Settings are per chat, not per account.** Earlier I read `DXCLX ON` from
`/SHow CONFig` and concluded the DX flag was account-wide. It was the Low
Band room's config. Each chat is configured separately, which makes the
automatic `/SET DXCLX` on room entry *required*, not belt-and-braces — and
it now fires on every confirmed room change, because `.loggedIn` follows
the welcome line.

**The doubled app name, third time.** Re-applying `titleVisibility` later
in the run loop was still not enough: SwiftUI re-applies its title
handling whenever the toolbar rebuilds, and a toolbar containing live
state rebuilds constantly. `WindowAccessor` now observes
`NSWindow.didUpdateNotification` for its own window and re-applies on
every update. It cannot loop because `configure` no-ops when the window is
already correct, and setting nothing posts nothing.

**2026-08-28, thirty-first pass — the roster in the wrong pane.** With
room switching fixed, the next bug surfaced: after a switch the entire
roster appeared in **Server output** while the station table held four
junk rows, one of them `144 | MHz`.

Cause: `requestRoster()` armed `expecting = .roster` when the roster was
*asked for*, but the command is queued and may not go out for a minute.
Everything arriving in that gap — the chat-selection menu, a welcome line,
live conversation — was parsed as roster rows. `144/432 MHz............2`
parses as callsign `144/432`, hence `144 | MHz`. By the time the real
reply arrived, something else had cleared the flag, so it fell through to
the server log.

Collection is now armed inside `write`, at the moment the command
actually leaves. **Any reply-scoped state must be armed at send time, not
at request time** — with a command queue between the two, "the next thing
that arrives" is not the reply.

`RosterParser` also rejects any line containing a run of dots, so
menu padding cannot produce a station however the timing goes. Three tests
cover the menu lines that were being accepted.

**2026-08-28, thirty-second pass — room ordering.** The server's menu
order is fixed and arbitrary from any one operator's point of view: the
two rooms actually used sit at positions 5 and 1 with eleven unused ones
in between.

`RoomOrder` lets any room be pinned to the top of every pane's picker, in
a chosen order, with the rest following in the server's own order below a
divider. Settings ▸ Rooms has the pins and up/down arrows. Defaults to Low
Band and 50/70 MHz — a guess, but a changeable one.

The pins are display order only. The menu digits and `/CHAT` tokens are
untouched, so nothing about the protocol depends on how the list is
arranged.

## Open items

**Ready to build**

1. ~~Wire dxca to the relay~~ — done and green on 2026-08-28. The Mac's
   address is DHCP, so a reservation or a `.local` name would keep the
   Pi's `cluster_nodes` entry from going stale.

1. **Away toggle** — `/SET HERE` / `/UNSET HERE` (§5.3.4). One command,
   and it is what puts the brackets round a callsign in everyone else's
   roster.
2. **Watch scopes** (§3.4) — watches currently match message text and
   callsigns; KST2Me also scopes them to the user list, spot calls,
   frequency, and locator.
3. **QRB highlight thresholds** (§3.10.3) — highlight stations beyond a
   set distance, rather than only shading by distance.

**Needs observation**

4. **Join/leave notices** — shape unknown, so the table only updates on
   the five-minute roster poll.
5. **Is the command rate limit per connection or per callsign?** Symptom
   if shared: wait notices appearing far more often with three panes than
   with one. Each pane polls the roster independently.

**Deferred**

6. **Notarisation and publishing.** Three things need doing beyond
   copying `notarize.sh` from the sibling apps:

   - **Universal binary.** `build_app.sh` runs a plain `swift build -c
     release`, so the app is arm64-only and will not launch on an Intel
     Mac. `DXClusterAggregator` ships
     `…-notarized-universal.zip`; this needs
     `--arch arm64 --arch x86_64` and a matching `lipo`/copy step.
   - **Hardened runtime.** Notarisation requires `codesign --options
     runtime` and a Developer ID Application certificate — the current
     signature is ad-hoc, which is fine locally and rejected by
     notarytool. Entitlements are unsandboxed with
     `com.apple.security.network.client`; that is enough. If the app is
     ever sandboxed, the spot relay listens on a socket and would then
     also need `com.apple.security.network.server`.
   - **Publishing.** The repo is private and stays private until
     explicitly told otherwise. The OZ2M credit is already in the README
     and belongs on any vu2cpl.com card too — the name is a play on
     KST2Me's and the highlight conventions come from its manual.
7. **Map view** — explicitly out of scope at v0.1 and still is.

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
