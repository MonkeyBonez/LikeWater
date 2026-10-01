import Foundation

// MARK: - What the sky is doing at one point and instant

/// The state of the sky over one point at one instant, reduced to what matters for
/// "does the shadow of that building exist right now": how much of the clear-sky
/// direct beam is getting through.
///
/// A geometric sun/shade map is only true under a clear sky. Under overcast there is no
/// beam, so nothing casts a shadow and every sidewalk is in the same flat light. In
/// between — thin cloud, broken cloud, the edge of the fog — the beam is weakened or
/// intermittent and the shade contrast shrinks with it. `beamStrength` is that scalar.
public struct SkyCondition: Sendable, Equatable {
    /// Direct normal irradiance, W/m² (the beam, measured perpendicular to the sun).
    public var directNormal: Double
    /// Diffuse horizontal irradiance, W/m² (sky light with no direction).
    public var diffuse: Double
    /// Total cloud cover, 0…1.
    public var cloudCover: Double
    /// Low cloud (below ~2 km), 0…1. In San Francisco this is the fog.
    public var lowCloud: Double
    /// Fraction of the clear-sky beam getting through, 0…1.
    public var beamStrength: Double

    public init(directNormal: Double, diffuse: Double, cloudCover: Double, lowCloud: Double,
                beamStrength: Double) {
        self.directNormal = directNormal; self.diffuse = diffuse
        self.cloudCover = cloudCover; self.lowCloud = lowCloud
        self.beamStrength = beamStrength
    }

    /// Builds the condition from irradiance plus the sun's elevation, which sets what
    /// "clear sky" would have delivered at that moment.
    public init(directNormal: Double, diffuse: Double, cloudCover: Double, lowCloud: Double,
                sunElevation: Double) {
        let clear = ClearSky.directNormal(elevation: sunElevation)
        let strength = clear > 1 ? min(1, max(0, directNormal / clear)) : 0
        self.init(directNormal: directNormal, diffuse: diffuse, cloudCover: cloudCover,
                  lowCloud: lowCloud, beamStrength: strength)
    }

    public static let clear = SkyCondition(directNormal: 900, diffuse: 90, cloudCover: 0, lowCloud: 0, beamStrength: 1)
    public static let overcast = SkyCondition(directNormal: 0, diffuse: 120, cloudCover: 1, lowCloud: 0.3, beamStrength: 0)
    public static let fog = SkyCondition(directNormal: 0, diffuse: 80, cloudCover: 1, lowCloud: 1, beamStrength: 0)
    public static let partly = SkyCondition(directNormal: 480, diffuse: 180, cloudCover: 0.55, lowCloud: 0.2, beamStrength: 0.55)

    /// Coarse class for wording and for the legend.
    public enum Regime: String, Sendable { case clear, hazy, broken, overcast }

    public var regime: Regime {
        if beamStrength >= 0.75 { return .clear }
        if beamStrength >= 0.4 { return .hazy }
        if beamStrength >= 0.15 { return .broken }
        return .overcast
    }

    /// Does the geometric shade map mean anything right now?
    public var shadowsMatter: Bool { beamStrength >= 0.15 }

    /// One line for the status pill.
    public var summary: String {
        switch regime {
        case .clear:
            return cloudCover >= 0.4 ? "Mostly sunny" : "Clear sky"
        case .hazy:
            return String(format: "Thin cloud · sun at %.0f%%", beamStrength * 100)
        case .broken:
            return String(format: "Broken cloud · sun at %.0f%%", beamStrength * 100)
        case .overcast:
            return lowCloud >= 0.6 ? "Fog · no direct sun" : "Overcast · no direct sun"
        }
    }
}

// MARK: - Clear-sky reference

/// What the beam would be with no cloud, so a forecast DNI can be read as a fraction.
/// Meinel & Meinel's fit (1353 · 0.7^(AM^0.678)) with the Kasten–Young air mass, which
/// tracks the model's own clear days to within ~5% between 20° and 60° elevation.
public enum ClearSky {
    public static func airMass(elevation: Double) -> Double {
        guard elevation > 0 else { return .infinity }
        let e = elevation
        return 1 / (sin(e * .pi / 180) + 0.50572 * pow(e + 6.07995, -1.6364))
    }

    /// Direct normal irradiance in W/m² under a clean, dry-ish sky.
    public static func directNormal(elevation: Double) -> Double {
        guard elevation > 0 else { return 0 }
        let am = airMass(elevation: elevation)
        return 1353 * pow(0.7, pow(am, 0.678))
    }
}

// MARK: - A field of sky samples over a city

/// One weather-model cell's time series.
public struct SkySample: Sendable {
    public var latitude: Double
    public var longitude: Double
    /// Unix seconds, ascending, evenly spaced (15-minute steps from the model).
    public var times: [Double]
    public var directNormal: [Double]
    public var diffuse: [Double]
    /// Hourly series, on its own clock.
    public var hourlyTimes: [Double]
    public var cloudCover: [Double]
    public var lowCloud: [Double]

    public init(latitude: Double, longitude: Double, times: [Double], directNormal: [Double],
                diffuse: [Double], hourlyTimes: [Double], cloudCover: [Double], lowCloud: [Double]) {
        self.latitude = latitude; self.longitude = longitude
        self.times = times; self.directNormal = directNormal; self.diffuse = diffuse
        self.hourlyTimes = hourlyTimes; self.cloudCover = cloudCover; self.lowCloud = lowCloud
    }

    /// Linear interpolation of a series at a time; nil outside the series.
    static func interpolate(_ t: Double, times: [Double], values: [Double]) -> Double? {
        guard times.count >= 2, times.count == values.count,
              t >= times[0], t <= times[times.count - 1] else { return nil }
        // Evenly spaced, so index directly.
        let step = times[1] - times[0]
        guard step > 0 else { return nil }
        let raw = (t - times[0]) / step
        let i = min(Int(raw.rounded(.down)), times.count - 2)
        let f = min(1, max(0, raw - Double(i)))
        let a = values[i], b = values[i + 1]
        if a.isNaN { return b.isNaN ? nil : b }
        if b.isNaN { return a }
        return a + (b - a) * f
    }

    public func condition(at date: Date, sunElevation: Double) -> SkyCondition? {
        let t = date.timeIntervalSince1970
        guard let dni = Self.interpolate(t, times: times, values: directNormal),
              let dif = Self.interpolate(t, times: times, values: diffuse) else { return nil }
        let cc = Self.interpolate(t, times: hourlyTimes, values: cloudCover) ?? 0
        let low = Self.interpolate(t, times: hourlyTimes, values: lowCloud) ?? 0
        return SkyCondition(directNormal: dni, diffuse: dif, cloudCover: cc / 100, lowCloud: low / 100,
                            sunElevation: sunElevation)
    }
}

/// Several model cells around the user, interpolated in space (inverse distance) and
/// time. Cells are ~2.5 km apart, so a city the size of San Francisco has 10–15 of
/// them and the fog line between the Sunset and the Mission is a real gradient here,
/// not a single number for the whole city.
public struct SkyField: Sendable {
    public var samples: [SkySample]
    public var fetchedAt: Date

    public init(samples: [SkySample], fetchedAt: Date = Date()) {
        self.samples = samples; self.fetchedAt = fetchedAt
    }

    public var isEmpty: Bool { samples.isEmpty }

    /// Inverse-distance-weighted (power 2) blend of the nearest cells.
    public func condition(latitude: Double, longitude: Double, at date: Date,
                          sunElevation: Double, nearest k: Int = 4) -> SkyCondition? {
        guard !samples.isEmpty else { return nil }
        var ranked: [(Double, SkyCondition)] = []
        for s in samples {
            guard let c = s.condition(at: date, sunElevation: sunElevation) else { continue }
            let d = haversineMeters(latitude, longitude, s.latitude, s.longitude)
            ranked.append((d, c))
        }
        guard !ranked.isEmpty else { return nil }
        ranked.sort { $0.0 < $1.0 }
        if ranked[0].0 < 50 { return ranked[0].1 }
        var wsum = 0.0
        var dni = 0.0, dif = 0.0, cc = 0.0, low = 0.0, beam = 0.0
        for (d, c) in ranked.prefix(k) {
            let w = 1 / (d * d)
            wsum += w
            dni += w * c.directNormal; dif += w * c.diffuse
            cc += w * c.cloudCover; low += w * c.lowCloud; beam += w * c.beamStrength
        }
        return SkyCondition(directNormal: dni / wsum, diffuse: dif / wsum, cloudCover: cc / wsum,
                            lowCloud: low / wsum, beamStrength: beam / wsum)
    }

    /// How different the sky is across the sampled cells right now: the spread of beam
    /// strength between the sunniest and cloudiest cell. Above ~0.4 the city is in two
    /// weathers at once, which in San Francisco means the fog line is somewhere inside it.
    public func beamSpread(at date: Date, sunElevation: Double) -> (min: Double, max: Double)? {
        var lo = Double.infinity, hi = -Double.infinity
        for s in samples {
            guard let c = s.condition(at: date, sunElevation: sunElevation) else { continue }
            lo = min(lo, c.beamStrength); hi = max(hi, c.beamStrength)
        }
        return lo.isFinite ? (lo, hi) : nil
    }

    /// A field with the same condition everywhere; the manual override and the UI tests.
    public static func uniform(_ condition: SkyCondition, latitude: Double, longitude: Double,
                               from: Date, to: Date) -> SkyField {
        // One hour of constant values at the given point, on 15-minute steps.
        let start = (from.timeIntervalSince1970 / 900).rounded(.down) * 900
        let end = (to.timeIntervalSince1970 / 900).rounded(.up) * 900
        var times: [Double] = []
        var t = start
        while t <= end { times.append(t); t += 900 }
        if times.count < 2 { times.append(start + 900) }
        let hours = times.filter { $0.truncatingRemainder(dividingBy: 3600) == 0 }
        let hourly = hours.count >= 2 ? hours : [times[0], times[0] + 3600]
        let sample = SkySample(
            latitude: latitude, longitude: longitude, times: times,
            directNormal: [Double](repeating: condition.directNormal, count: times.count),
            diffuse: [Double](repeating: condition.diffuse, count: times.count),
            hourlyTimes: hourly,
            cloudCover: [Double](repeating: condition.cloudCover * 100, count: hourly.count),
            lowCloud: [Double](repeating: condition.lowCloud * 100, count: hourly.count))
        return SkyField(samples: [sample])
    }
}

// MARK: - Open-Meteo decoding

/// Decodes the Open-Meteo forecast response (one object per requested point, or a bare
/// object for a single point) requested with `timeformat=unixtime`,
/// `minutely_15=direct_normal_irradiance,diffuse_radiation` and
/// `hourly=cloud_cover,cloud_cover_low`.
public enum OpenMeteoSky {
    public struct DecodeError: Error, CustomStringConvertible {
        public let description: String
    }

    private struct Location: Decodable {
        struct Series15: Decodable {
            let time: [Double]
            let direct_normal_irradiance: [Double?]
            let diffuse_radiation: [Double?]
        }
        struct SeriesHourly: Decodable {
            let time: [Double]
            let cloud_cover: [Double?]
            let cloud_cover_low: [Double?]?
        }
        let latitude: Double
        let longitude: Double
        let minutely_15: Series15
        let hourly: SeriesHourly
    }

    public static func decode(_ data: Data, fetchedAt: Date = Date()) throws -> SkyField {
        let decoder = JSONDecoder()
        let locations: [Location]
        if let many = try? decoder.decode([Location].self, from: data) {
            locations = many
        } else if let one = try? decoder.decode(Location.self, from: data) {
            locations = [one]
        } else {
            let text = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw DecodeError(description: "Open-Meteo response not understood: \(text)")
        }
        // Several requested points can land in one model cell (the model grid is ~3 km,
        // the request lattice 2.5 km). Keep one sample per cell so the inverse-distance
        // blend doesn't count a cell twice.
        var seen = Set<String>()
        let unique = locations.filter { seen.insert("\($0.latitude),\($0.longitude)").inserted }
        let samples = unique.map { loc in
            SkySample(latitude: loc.latitude, longitude: loc.longitude,
                      times: loc.minutely_15.time,
                      directNormal: loc.minutely_15.direct_normal_irradiance.map { $0 ?? .nan },
                      diffuse: loc.minutely_15.diffuse_radiation.map { $0 ?? .nan },
                      hourlyTimes: loc.hourly.time,
                      cloudCover: loc.hourly.cloud_cover.map { $0 ?? .nan },
                      lowCloud: (loc.hourly.cloud_cover_low ?? []).map { $0 ?? .nan })
        }
        return SkyField(samples: samples, fetchedAt: fetchedAt)
    }

    /// The request the apps make: the cells around a point on a fixed ~2.5 km lattice,
    /// so two nearby users (or two launches) ask for the same cells and cache hits.
    public static let latticeStepLat = 0.0225          // ≈ 2.5 km
    /// One longitude step per 1° latitude band, so every query in the band snaps to the
    /// same columns (a step that varied with the query latitude broke cache hits).
    public static func latticeStepLon(atLatitude lat: Double) -> Double {
        0.0225 / max(0.2, cos(lat.rounded() * .pi / 180))
    }

    /// Lattice points within `rings` of the point (rings=1 → 3×3 = 9 cells).
    public static func latticePoints(around latitude: Double, longitude: Double, rings: Int = 1)
        -> [(latitude: Double, longitude: Double)] {
        let dLat = latticeStepLat
        let dLon = latticeStepLon(atLatitude: latitude)
        let baseLat = (latitude / dLat).rounded() * dLat
        let baseLon = (longitude / dLon).rounded() * dLon
        var out: [(Double, Double)] = []
        for i in -rings...rings {
            for j in -rings...rings {
                out.append(((baseLat + Double(i) * dLat), (baseLon + Double(j) * dLon)))
            }
        }
        return out.map { (latitude: ($0.0 * 1e5).rounded() / 1e5, longitude: ($0.1 * 1e5).rounded() / 1e5) }
    }

    public static func requestURL(points: [(latitude: Double, longitude: Double)],
                                  pastDays: Int = 1, forecastDays: Int = 3) -> URL {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: points.map { String(format: "%.5f", $0.latitude) }.joined(separator: ",")),
            .init(name: "longitude", value: points.map { String(format: "%.5f", $0.longitude) }.joined(separator: ",")),
            .init(name: "minutely_15", value: "direct_normal_irradiance,diffuse_radiation"),
            .init(name: "hourly", value: "cloud_cover,cloud_cover_low"),
            .init(name: "past_days", value: String(pastDays)),
            .init(name: "forecast_days", value: String(forecastDays)),
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "timezone", value: "UTC"),
            .init(name: "models", value: "best_match"),
        ]
        return c.url!
    }
}
