import SwiftUI
import KSTCore

struct ChatPane: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.lines) { line in
                            LineRow(line: line, highlighted: model.mentionsMe(line))
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.lines.count) { _ in
                    if let last = model.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            Divider()
            Composer(focused: $composerFocused)
        }
        .frame(minWidth: 480)
    }
}

private struct LineRow: View {
    let line: KSTLine
    let highlighted: Bool

    var body: some View {
        switch line.kind {
        case .message(let from, let name, let to, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(line.stamp ?? "")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 42, alignment: .leading)
                Text(from)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                if let name { Text(name).foregroundStyle(.secondary) }
                if let to {
                    Text("→ \(to)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                }
                Text(text)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 1)
            .padding(.horizontal, 4)
            .background(highlighted ? Color.yellow.opacity(0.18) : .clear)
            .cornerRadius(4)

        case .roster:
            // Belongs in the station table, not the chat log.
            EmptyView()

        case .prompt:
            // Server furniture — the chat log stays traffic only.
            EmptyView()

        case .local:
            Text(line.raw)
                .font(.caption)
                .foregroundStyle(.orange)

        case .other:
            // Unclassified server output — shown verbatim rather than
            // dropped, so banners, /HELP output and the user list are
            // never invisible just because the parser doesn't know them.
            Text(line.raw)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

private struct Composer: View {
    @EnvironmentObject private var model: AppModel
    @FocusState.Binding var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let to = model.directedTo {
                HStack(spacing: 4) {
                    Text("/CQ \(to)").font(.caption.monospaced())
                    Button {
                        model.directedTo = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.blue.opacity(0.15))
                .cornerRadius(5)
            }

            TextField(model.isInChat ? "Message" : "Not connected",
                      text: $model.draft)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .disabled(!model.isInChat)
                .onSubmit { model.sendDraft() }

            Button {
                model.loadBacklog()
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .disabled(!model.isInChat)
            .help("Fetch recent messages (/SHOW MSG). Uses one of the server's ~1-per-minute command slots.")

            Button("Send") { model.sendDraft() }
                .disabled(!model.isInChat || model.draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(8)
    }
}
