import SwiftUI
import KSTCore

/// Who is on, with distance and beam heading from your own square — the
/// reason a VHF operator keeps the chat open at all.
struct StationPane: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: Station.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Table(model.stations, selection: $selection) {
                TableColumn("Call") { s in
                    HStack(spacing: 4) {
                        Text(s.callsign)
                            .font(.system(.body, design: .monospaced).weight(.medium))
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
                .width(min: 92)

                TableColumn("Name") { s in
                    Text(s.name ?? "").foregroundStyle(.secondary)
                }
                .width(min: 60)

                TableColumn("Loc") { s in
                    Text(s.locator ?? "").font(.system(.caption, design: .monospaced))
                }
                .width(min: 56)

                TableColumn("km") { s in
                    let path = model.path(to: s)
                    Text(path.map { String(format: "%.0f", $0.distanceKm) } ?? "")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(path.map { AnyShapeStyle(Palette.distance($0.distanceKm)) }
                                         ?? AnyShapeStyle(.secondary))
                }
                .width(min: 48)

                TableColumn("Bearing") { s in
                    Text(model.path(to: s).map { String(format: "%.0f°", $0.bearing) } ?? "")
                        .font(.system(.caption, design: .monospaced))
                }
                .width(min: 52)
            }
            .contextMenu(forSelectionType: Station.ID.self) { ids in
                if let call = ids.first {
                    Button("Direct message \(call)") { model.directedTo = call }
                    Button(model.isWatched(call) ? "Stop watching \(call)" : "Watch \(call)") {
                        model.toggleWatch(call)
                    }
                }
            }

            Divider()
            HStack {
                Text(model.stationsAreStale
                     ? "previous room — asking…"
                     : "\(model.stations.filter { !$0.isAway }.count) here, \(model.stations.count) listed")
                    .font(.caption)
                    .foregroundStyle(model.stationsAreStale ? .orange : .secondary)
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
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
        }
    }
}
