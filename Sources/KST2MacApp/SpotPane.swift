import SwiftUI
import KSTCore

/// DX spots, in their own pane.
///
/// A spot is reference data — you scan it for a callsign or a frequency —
/// where a chat line is read in sequence. Mixing them made both harder to
/// read, which is why KST2Me gives the cluster its own window and this
/// does the same.
struct SpotPane: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(Typography.key) private var scale: Double = Typography.defaultScale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.up.forward")
                    .font(Typography.text(11, scale))
                Text("DX spots")
                    .font(Typography.text(11, scale, weight: .semibold))
                Spacer()
                if SpotRelayHost.shared.enabled {
                    Text("relaying")
                        .font(Typography.text(10, scale))
                        .foregroundStyle(Palette.connected)
                }
                Text("\(model.spots.count)")
                    .font(Typography.text(10, scale))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(Palette.callsignTint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Palette.callsignTint.opacity(0.10))

            if model.spots.isEmpty {
                VStack(spacing: 4) {
                    Text("No spots yet")
                        .font(Typography.text(12, scale))
                        .foregroundStyle(.secondary)
                    Text(model.isInChat
                         ? "Spots appear here as the chat sends them."
                         : "Connect to receive spots.")
                        .font(Typography.text(10, scale))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.spots) {
                    TableColumn("Freq") { spot in
                        Text(spot.frequencyText)
                            .font(Typography.mono(12, scale, weight: .medium))
                            .foregroundStyle(Palette.utc)
                    }
                    .width(min: 62, ideal: 74, max: 100)

                    TableColumn("DX") { spot in
                        Text(spot.dx)
                            .font(Typography.mono(12, scale, weight: .medium))
                            .foregroundStyle(Palette.color(for: spot.dx))
                    }
                    .width(min: 70, ideal: 88, max: 130)

                    TableColumn("Comment") { spot in
                        Text(spot.comment.isEmpty ? spot.raw : spot.comment)
                            .font(Typography.text(12, scale))
                            .foregroundStyle(.secondary)
                    }

                    TableColumn("By") { spot in
                        Text(spot.spotter)
                            .font(Typography.mono(11, scale))
                            .foregroundStyle(.tertiary)
                    }
                    .width(min: 60, ideal: 76, max: 110)

                    TableColumn("UTC") { spot in
                        Text(spot.time)
                            .font(Typography.mono(11, scale))
                            .foregroundStyle(.tertiary)
                    }
                    .width(min: 46, ideal: 54, max: 70)
                }
            }
        }
    }
}

/// Raw server output — banners, `/HELP`, command replies, our own
/// notices. Hidden by default: it is the terminal underneath, useful when
/// something is wrong and noise the rest of the time.
struct ServerLogPane: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(Typography.key) private var scale: Double = Typography.defaultScale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(Typography.text(11, scale))
                Text("Server output")
                    .font(Typography.text(11, scale, weight: .semibold))
                Spacer()
                Text("\(model.serverLines.count)")
                    .font(Typography.text(10, scale))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.08))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(model.serverLines) { line in
                            ScrollView(.horizontal, showsIndicators: false) {
                                Text(line.raw)
                                    .font(Typography.mono(11, scale))
                                    .foregroundStyle(isNotice(line) ? Color.orange : .secondary)
                                    .textSelection(.enabled)
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                            .id(line.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.serverLines.count) { _ in
                    if let last = model.serverLines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func isNotice(_ line: KSTLine) -> Bool {
        if case .local = line.kind { return true }
        return false
    }
}
