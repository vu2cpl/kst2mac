import SwiftUI
import KSTCore

/// Who is on, with distance and beam heading from your own square — the
/// reason a VHF operator keeps the chat open at all.
struct StationPane: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(Typography.key) private var scale: Double = Typography.defaultScale
    @State private var selection: Station.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(Typography.text(11, scale))
                    .foregroundStyle(Palette.utc)
                Text("Stations")
                    .font(Typography.text(11, scale, weight: .semibold))
                    .foregroundStyle(Palette.utc)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Palette.utc.opacity(0.10))

            Table(model.stations, selection: $selection) {
                TableColumn("Call") { s in
                    HStack(spacing: 4) {
                        Text(s.callsign)
                            .font(Typography.mono(13, scale, weight: .medium))
                            // Same colour the callsign has in the log, so
                            // the two panes read as one thing.
                            .foregroundStyle(s.isAway
                                             ? AnyShapeStyle(.secondary)
                                             : AnyShapeStyle(Palette.color(for: s.callsign)))
                        if s.isAway {
                            Image(systemName: "moon.zzz")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .help("Away from the terminal")
                        }
                        if model.isWatched(s.callsign) {
                            Image(systemName: "eye.fill")
                                .font(.caption2)
                                .foregroundStyle(Palette.watchedBar)
                                .help("Watched — their traffic is tinted in the log")
                        }
                    }
                }
                .width(min: 88, ideal: 104, max: 150)

                TableColumn("Name") { s in
                    Text(s.name ?? "")
                        .font(Typography.text(13, scale))
                        .foregroundStyle(.secondary)
                }
                .width(min: 64, ideal: 96,  max: 200)

                TableColumn("Loc") { s in
                    Text(s.locator ?? "")
                        .font(Typography.mono(13, scale))
                }
                .width(min: 62, ideal: 70,  max: 90)

                TableColumn("km") { s in
                    let path = model.path(to: s)
                    Text(path.map { String(format: "%.0f", $0.distanceKm) } ?? "")
                        .font(Typography.mono(13, scale))
                        .foregroundStyle(path.map { AnyShapeStyle(Palette.distance($0.distanceKm)) }
                                         ?? AnyShapeStyle(.secondary))
                }
                .width(min: 52, ideal: 58,  max: 80)

                TableColumn("Bearing") { s in
                    Text(model.path(to: s).map { String(format: "%.0f°", $0.bearing) } ?? "")
                        .font(Typography.mono(13, scale))
                }
                .width(min: 56, ideal: 64,  max: 90)
            }
            .contextMenu(forSelectionType: Station.ID.self) { ids in
                if let call = ids.first {
                    Button("Direct message \(call)") { model.directedTo = call }
                    if call.uppercased() != model.callsign.uppercased() {
                        Button(model.isWatched(call) ? "Stop watching \(call)" : "Watch \(call)") {
                            model.toggleWatch(call)
                        }
                    }
                }
            }

            Divider()
            HStack {
                if model.stationsAreStale {
                    Text("previous room — asking…")
                        .font(Typography.text(11, scale))
                        .foregroundStyle(Palette.connecting)
                } else {
                    HStack(spacing: 3) {
                        Text("\(model.stations.filter { !$0.isAway }.count)")
                            .font(Typography.text(11, scale, weight: .semibold))
                            .foregroundStyle(Palette.connected)
                        Text("here,")
                            .font(Typography.text(11, scale))
                            .foregroundStyle(.secondary)
                        Text("\(model.stations.count)")
                            .font(Typography.text(11, scale, weight: .semibold))
                            .foregroundStyle(Palette.utc)
                        Text("listed")
                            .font(Typography.text(11, scale))
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    model.refreshRoster()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(!model.isInChat)
                .help("Ask the server who is present (/SHOW USER)")
                Spacer()
                if model.homeGrid.isEmpty {
                    Text("Set your locator in Settings for distances")
                        .font(Typography.text(11, scale)).foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
        }
    }
}
