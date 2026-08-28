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
    Usage: KSTCapture --call <CALLSIGN> [--room <1-7>] [--out <file>] [--seconds <n>]

      --call     Your ON4KST login (usually your callsign).
      --room     Chat number: 1=50/70  2=144/432  3=Microwave
                 4=EME/JT65  5=Low Band  7=50 MHz R2   (default 2)
      --out      Transcript path (default kst-transcript.txt)
      --seconds  How long to record after login (default 120)

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
let room = ChatRoom(rawValue: Int(option("--room") ?? "2") ?? 2) ?? .vhfUhf
let outPath = option("--out") ?? "kst-transcript.txt"
let seconds = Double(option("--seconds") ?? "120") ?? 120

let password = readSecret("ON4KST password for \(call): ")
guard !password.isEmpty else {
    FileHandle.standardError.write(Data("error: empty password\n".utf8))
    exit(2)
}

FileManager.default.createFile(atPath: outPath, contents: nil)
guard let out = FileHandle(forWritingAtPath: outPath) else {
    FileHandle.standardError.write(Data("error: cannot write \(outPath)\n".utf8))
    exit(1)
}

let conn = KSTConnection()
let lock = NSLock()
conn.rawMonitor = { chunk in
    lock.lock(); defer { lock.unlock() }
    out.write(Data(chunk.utf8))
}

print("Recording \(room.title) to \(outPath) for \(Int(seconds))s…")

Task {
    for await event in conn.events {
        switch event {
        case .status(let s):        FileHandle.standardError.write(Data("[\(s)]\n".utf8))
        case .loggedIn(let r):      FileHandle.standardError.write(Data("[logged in — \(r.title)]\n".utf8))
        case .disconnected(let r):  FileHandle.standardError.write(Data("[disconnected: \(r ?? "clean")]\n".utf8))
        case .line, .station:       break
        }
    }
}

conn.connect(username: call, password: password, room: room)

Thread.sleep(forTimeInterval: seconds)
conn.disconnect()
Thread.sleep(forTimeInterval: 0.5)
try? out.close()
print("Wrote \(outPath)")
