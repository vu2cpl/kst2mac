import Foundation
import KSTCore

// Transcript recorder for protocol work.
//
// Connects, logs in, joins a chat, and writes every byte the server sends
// to a file — including the prompts, which carry no newline and so never
// appear as parsed lines. That transcript is what the LineParser and the
// roster parser get written against; see docs/PROTOCOL.md.
//
// The password is read from the terminal with echo off and is never passed
// on the command line (argv is world-readable via `ps`) and never written
// to the transcript.

func readSecret(_ prompt: String) -> String {
    FileHandle.standardError.write(Data(prompt.utf8))
    var original = termios()
    let haveTTY = tcgetattr(STDIN_FILENO, &original) == 0
    if haveTTY {
        var quiet = original
        quiet.c_lflag &= ~UInt(ECHO)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &quiet)
    }
    let value = readLine(strippingNewline: true) ?? ""
    if haveTTY {
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        FileHandle.standardError.write(Data("\n".utf8))
    }
    return value
}

let args = CommandLine.arguments
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

if args.contains("-h") || args.contains("--help") {
    print("""
    Usage: KSTCapture --call <CALLSIGN> [--room <1-13>] [--out <file>] [--seconds <n>]

      --call     Your ON4KST login (usually your callsign).
      --room     Chat number (default 9, 144/432 IARU R3):
                  1 50/70 MHz        2 144/432 MHz      3 Microwave
                  4 EME/JT65         5 Low Band         6 50 MHz R3
                  7 50 MHz R2        8 144/432 R2       9 144/432 R3
                 10 kHz 2000-630m   11 WARC            12 28 MHz
                 13 40 MHz
      --out      Transcript path (default kst-transcript.txt)
      --seconds  How long to record after login (default 120)
      --quiet    Do not mirror the traffic to the terminal
      --probe    After joining, run the commands whose output format we
                 still need: /SET DXCLX, /SHOW DX 10, /SET DX, /SHOW DX 10,
                 /SHOW USER, /SHOW CONFIG. All reply privately to your own
                 terminal -- none post to the room. The two /SET commands
                 change your own spot preferences on the server (DX spots
                 start OFF); /UNSET DX puts them back. Off by default so
                 nothing reaches the connection unless you ask.

                 The server allows about one command a minute, so a probe
                 run needs --seconds 420 or more to get through them all.

    The password is prompted for with echo off and never written to the
    transcript. Read what lands in the file before sharing it — it contains
    whatever the room said while you were recording.
    """)
    exit(0)
}

guard let call = option("--call")?.uppercased() else {
    FileHandle.standardError.write(Data("error: --call is required (try --help)\n".utf8))
    exit(2)
}
let room = ChatRoom(rawValue: Int(option("--room") ?? "9") ?? 9) ?? .vhfUhfRegion3
let outPath = option("--out") ?? "kst-transcript.txt"
let seconds = Double(option("--seconds") ?? (args.contains("--probe") ? "480" : "120")) ?? 120

let password = readSecret("ON4KST password for \(call): ")
guard !password.isEmpty else {
    FileHandle.standardError.write(Data("error: empty password\n".utf8))
    exit(2)
}

let mirror = !args.contains("--quiet")
let probe  = args.contains("--probe")

FileManager.default.createFile(atPath: outPath, contents: nil)
guard let out = FileHandle(forWritingAtPath: outPath) else {
    FileHandle.standardError.write(Data("error: cannot write \(outPath)\n".utf8))
    exit(1)
}

let err = FileHandle.standardError
let lock = NSLock()
var byteCount = 0

func note(_ text: String) {
    lock.lock(); defer { lock.unlock() }
    err.write(Data("\u{001B}[2K\r\(text)\n".utf8))
}

let conn = KSTConnection()
conn.rawMonitor = { chunk in
    lock.lock(); defer { lock.unlock() }
    out.write(Data(chunk.utf8))
    byteCount += chunk.utf8.count
    // Mirroring the traffic is the whole point of watching a capture run.
    // Without it a quiet room is indistinguishable from a hung client --
    // which is exactly how the first run of this tool looked.
    if mirror { err.write(Data(chunk.utf8)) }
}

note("Recording \(room.title) to \(outPath) for \(Int(seconds))s. Ctrl-C to stop early.")

let events = conn.events    // claim the stream before connecting
Task {
    for await event in events {
        switch event {
        case .status(let s):        note("[\(s)]")
        case .loggedIn(let r):
            note("[joined \(r.title)]")
            if probe {
                // Give the room banner a moment to land first, then walk
                // the commands whose *output format* we still need to see.
                // All four reply to us privately; none post to the room.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                // DXCLX first: /HELP calls it "CLX format", which may
                // already be standard `DX de ...` cluster lines. If so a
                // bridge into dxca is a relay, not a re-encoding. /SET DX
                // is the plain format for comparison; spots arrive
                // disabled (DX OFF) so one of these must be sent before
                // /SHOW DX returns anything at all.
                for command in ["/SET DXCLX", "/SHOW DX 10", "/SET DX", "/SHOW DX 10",
                                "/SHOW USER", "/SHOW CONFIG"] {
                    note("[sending \(command)]")
                    conn.send(command)
                    // One command per minute is the server's limit; a
                    // shorter gap just collects "Please wait" notices.
                    try? await Task.sleep(nanoseconds: 62_000_000_000)
                }
            }
        case .disconnected(let r):  note("[disconnected: \(r ?? "clean")]")
        case .rosterComplete(let stations):
            note("[roster: \(stations.count) present — \(stations.map(\.callsign).joined(separator: ", "))]")
        case .line, .station:       break
        }
    }
}

conn.connect(username: call, password: password, room: room)

// Tick once a second so the terminal always shows the run is alive, even
// when the room says nothing for minutes at a stretch.
let deadline = Date().addingTimeInterval(seconds)
while Date() < deadline {
    Thread.sleep(forTimeInterval: 1.0)
    lock.lock()
    let remaining = Int(deadline.timeIntervalSinceNow.rounded())
    let bytes = byteCount
    err.write(Data("\u{001B}[2K\r\(remaining)s left, \(bytes) bytes captured".utf8))
    lock.unlock()
}
note("")

conn.disconnect()
Thread.sleep(forTimeInterval: 0.5)
try? out.close()
note("Wrote \(outPath) (\(byteCount) bytes)")
