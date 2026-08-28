import Foundation

/// Maidenhead locator maths — enough of it to put a distance and a beam
/// heading next to every callsign in the station list, which is the whole
/// point of a VHF/microwave chat client.
public enum Maidenhead {

    /// Centre of the square described by a 2/4/6/8-character locator.
    /// Returns nil for anything that isn't a well-formed locator.
    public static func coordinates(_ locator: String) -> (latitude: Double, longitude: Double)? {
        let g = locator.trimmingCharacters(in: .whitespaces).uppercased()
        let n = g.count
        guard n >= 2, n % 2 == 0, n <= 8 else { return nil }
        let c = Array(g)

        func idx(_ ch: Character, in range: ClosedRange<Character>) -> Int? {
            guard ch >= range.lowerBound, ch <= range.upperBound,
                  let a = ch.asciiValue, let lo = range.lowerBound.asciiValue else { return nil }
            return Int(a - lo)
        }

        // Field: A..R, 20° lon / 10° lat per square.
        guard let lonField = idx(c[0], in: "A"..."R"),
              let latField = idx(c[1], in: "A"..."R") else { return nil }
        var lon = Double(lonField) * 20.0 - 180.0
        var lat = Double(latField) * 10.0 - 90.0
        var lonSize = 20.0, latSize = 10.0

        if n >= 4 {
            // Square: 0..9, 2° lon / 1° lat.
            guard let lonSq = idx(c[2], in: "0"..."9"),
                  let latSq = idx(c[3], in: "0"..."9") else { return nil }
            lonSize = 2.0; latSize = 1.0
            lon += Double(lonSq) * lonSize
            lat += Double(latSq) * latSize
        }
        if n >= 6 {
            // Subsquare: A..X, 5' lon / 2.5' lat.
            guard let lonSub = idx(c[4], in: "A"..."X"),
                  let latSub = idx(c[5], in: "A"..."X") else { return nil }
            lonSize = 2.0 / 24.0; latSize = 1.0 / 24.0
            lon += Double(lonSub) * lonSize
            lat += Double(latSub) * latSize
        }
        if n >= 8 {
            // Extended square: 0..9.
            guard let lonEx = idx(c[6], in: "0"..."9"),
                  let latEx = idx(c[7], in: "0"..."9") else { return nil }
            lonSize /= 10.0; latSize /= 10.0
            lon += Double(lonEx) * lonSize
            lat += Double(latEx) * latSize
        }

        // Report the centre of the square, not its south-west corner.
        return (lat + latSize / 2.0, lon + lonSize / 2.0)
    }

    /// Great-circle distance in km and initial bearing in degrees true,
    /// from `from` to `to`. Spherical earth (R = 6371.0 km) — good to
    /// better than 0.5%, which is far inside the precision a 6-character
    /// locator carries anyway.
    public static func path(from: String, to: String) -> (distanceKm: Double, bearing: Double)? {
        guard let a = coordinates(from), let b = coordinates(to) else { return nil }
        let R = 6371.0
        let φ1 = a.latitude  * .pi / 180.0
        let φ2 = b.latitude  * .pi / 180.0
        let Δφ = φ2 - φ1
        let Δλ = (b.longitude - a.longitude) * .pi / 180.0

        let h = sin(Δφ / 2) * sin(Δφ / 2) + cos(φ1) * cos(φ2) * sin(Δλ / 2) * sin(Δλ / 2)
        let distance = 2 * R * atan2(sqrt(h), sqrt(1 - h))

        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        let bearing = (atan2(y, x) * 180.0 / .pi + 360.0).truncatingRemainder(dividingBy: 360.0)

        return (distance, bearing)
    }
}
