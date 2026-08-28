import SwiftUI
import KSTCore

struct ChatPane: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(Typography.key) private var scale: Double = Typography.defaultScale

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.lines) { line in
                            LineRow(line: line, emphasis: model.emphasis(for: line), scale: scale)
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

        }
        .frame(minWidth: 420, minHeight: 140)
    }
}

private struct LineRow: View {
    @EnvironmentObject private var model: AppModel
    let line: KSTLine
    let emphasis: AppModel.Emphasis
    let scale: Double

    private var fill: Color {
        switch emphasis {
        case .directed: return Palette.directedFill
        case .preamble: return Palette.preambleFill
        case .watched:  return Palette.watchedFill
        case .own:      return Palette.ownFill
        case .none:     return .clear
        }
    }

    private var bar: Color {
        switch emphasis {
        case .directed: return Palette.directedBar
        case .preamble: return Palette.preambleBar
        case .watched:  return Palette.watchedBar
        case .own:      return Palette.ownBar
        case .none:     return .clear
        }
    }

    var body: some View {
        switch line.kind {
        case .message(let from, let name, let to, let text):
            // .top, not .firstTextBaseline: with a wrapping message the
            // baseline alignment pulled the row's measured height back to
            // one line, and the wrapped text drew over the row below.
            HStack(alignment: .top, spacing: 6) {
                // A left bar rather than only a wash, so a line naming you
                // is findable while scrolling fast.
                Rectangle()
                    .fill(bar)
                    .frame(width: 2)

                Text(line.stamp ?? "")
                    .font(Typography.mono(11, scale))
                    .foregroundStyle(.tertiary)
                    .frame(width: 46 * Typography.clamped(scale), alignment: .leading)
                    .padding(.top, 1)

                Button {
                    model.directedTo = from
                } label: {
                    Text(from)
                        .font(Typography.mono(13, scale, weight: .semibold))
                        .foregroundStyle(Palette.color(for: from))
                }
                .buttonStyle(.plain)
                .help("Address your next message to \(from)")

                if let name {
                    Text(name)
                        .font(Typography.text(12, scale))
                        .foregroundStyle(.secondary)
                }
                if let to {
                    Text(to)
                        .font(Typography.mono(11, scale, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Palette.color(for: to).opacity(0.22), in: Capsule())
                        .foregroundStyle(Palette.color(for: to))
                }

                Text(MessageText.attributed(text))
                    .font(Typography.text(13, scale))
                    .textSelection(.enabled)
                    // Report the full wrapped height, or the row is sized
                    // for one line and the rest spills over its neighbour.
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

            }
            .padding(.vertical, 2)
            .padding(.trailing, 4)
            .background(fill)

        case .joined(let chat):
            // One divider per join or /CHAT switch, instead of a
            // four-line banner every time.
            HStack(spacing: 8) {
                VStack { Divider() }
                Text(chat.uppercased())
                    .font(Typography.text(10, scale, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                    .fixedSize()
                VStack { Divider() }
            }
            .padding(.vertical, 7)

        case .boilerplate:
            EmptyView()

        case .spot:
            // Shown in the DX spots pane.
            EmptyView()

        case .roster:
            // Belongs in the station table, not the chat log.
            EmptyView()

        case .prompt:
            // Server furniture — the chat log stays traffic only.
            EmptyView()

        case .local:
            // Routed to the server log; nothing to draw here.
            EmptyView()

        case .other:
            // Shown in the server log pane.
            EmptyView()

        case .prompt:
            // Server furniture — the chat log stays traffic only.
            EmptyView()

        case .local:
            // Routed to the server log; nothing to draw here.
            EmptyView()

        case .other:
            // Unclassified server output — shown verbatim rather than
            // dropped, so banners, /HELP output and DX spots are never
            // invisible just because the parser doesn't know them.
            //
            // Not wrapped: this is fixed-column text (a DX spot is laid
            // out in 80 columns) and wrapping scrambles the columns into
            // exactly the mess it is meant to avoid. It scrolls sideways
            // instead.
            ScrollView(.horizontal, showsIndicators: false) {
                Text(line.raw)
                    .font(Typography.mono(11, scale))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }
}

/// The message box. Lives at the foot of the whole left column rather
/// than inside the chat pane, so it sits below the server log instead of
/// between the two — an input box in the middle of a column reads wrong.
struct Composer: View {
    /// Called when what was sent was a command, so the caller can reveal
    /// the server log: a `/` reply lands there, and typing a command into
    /// a pane you cannot see is no use.
    var onCommandSent: (() -> Void)?

    @EnvironmentObject private var model: AppModel
    @AppStorage(Typography.key) private var scale: Double = Typography.defaultScale
    @FocusState private var focused: Bool

    /// A leading `/` makes it a command to the server rather than a
    /// message to the room — the reply comes back privately, into the
    /// server log.
    private var isCommand: Bool { model.draft.hasPrefix("/") }

    private func send() {
        let wasCommand = isCommand
        model.sendDraft()
        if wasCommand { onCommandSent?() }
    }

    var body: some View {
        HStack(spacing: 8) {
            if let to = model.directedTo, !isCommand {
                HStack(spacing: 4) {
                    Text(model.replyWithPreamble ? to : "/CQ \(to)")
                        .font(Typography.mono(11, scale, weight: .semibold))
                    Button {
                        model.directedTo = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Palette.directedBar.opacity(0.18))
                .cornerRadius(5)
                .contextMenu {
                    Toggle("Reply with preamble instead of /CQ",
                           isOn: $model.replyWithPreamble)
                }
                .help(model.replyWithPreamble
                      ? "Preamble — highlights only for clients that implement the convention"
                      : "/CQ — highlights for every chat user")
            }

            TextField(model.draft.hasPrefix("/") ? "Command" : "Message",
                      text: $model.draft)
                .font(Typography.text(13, scale))
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .disabled(!model.isInChat)
                .onSubmit(send)

            Button {
                model.loadBacklog()
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .tint(Palette.utc)
            .disabled(!model.isInChat)
            .help("Fetch recent messages (/SHOW MSG). Uses one of the server's ~1-per-minute command slots.")

            Button("Send", action: send)
                .buttonStyle(.borderedProminent)
                .tint(model.directedTo == nil ? Palette.utc : Palette.directedBar)
                .disabled(!model.isInChat || model.draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(8)
        .frame(minHeight: 36)
    }
}
