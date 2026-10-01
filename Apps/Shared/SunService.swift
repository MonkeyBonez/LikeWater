import Foundation
import CoreLocation
import MapKit
import LikeWaterEngine

struct SunEdge: Sendable {
    var a: CLLocationCoordinate2D
    var b: CLLocationCoordinate2D
    var bucket: SunBucket
}

struct SunField: Sendable {
    var city: String
    var edges: [SunEdge]
    var sun: SolarPosition
    var center: CLLocationCoordinate2D
    var date: Date
    var scoredEdges: Int
    var computeMs: Double
    var sunnyCount: Int
    var mixedCount: Int
    var shadedCount: Int
    /// The sky over the map centre at `date`; nil when no forecast could be had.
    var sky: SkyCondition?
    /// Spread of beam strength across the sampled cells, for "two weathers" wording.
    var skySpread: (min: Double, max: Double)?
    /// Where the sky came from: "forecast", a preset name, or "override".
    var skySource: String
    /// The city's own time zone, so a Californian looking at Manhattan sees New York time.
    var timeZone: TimeZone?
    /// Tiles stitched for this field (0 for a single-file city).
    var tiles: Int = 0
    var downloaded: Int = 0
    /// `.partial` when part of the screen is outside the place's data.
    var coverage: CoverageState = .covered
    /// The metro build painted (nil for a single-file city), and the on-disk cache size.
    var built: String?
    var cacheBytes: Int = 0
    var prefetched: Int = 0
}

/// Nothing built here. The sky and the sun still work anywhere, so they come along.
enum SunServiceError: Error, LocalizedError {
    case notCovered(CoverageState, sky: SkyCondition?, sun: SolarPosition, timeZone: TimeZone?)

    var errorDescription: String? { "No sun data here yet." }
}

/// How the user wants the sky handled.
enum SkyMode: String, CaseIterable, Identifiable {
    case auto = "Auto", clear = "Sunny", partly = "Partly", overcast = "Cloudy"
    var id: String { rawValue }

    var preset: WeatherService.Preset? {
        switch self {
        case .auto: return nil
        case .clear: return .clear
        case .partly: return .partly
        case .overcast: return .overcast
        }
    }
}

/// What part of the map gets a sun field: everything on screen plus a margin, so a small
/// pan doesn't expose an unpainted edge — capped, so a zoomed-out view stays interactive.
enum SunArea {
    /// Longest side scored. 2 km of downtown is ~20k edges: ~0.1 s on a phone, and past
    /// that the lines are too thin to read anyway.
    static let maxSideMetres = 2_000.0
    static let margin = 0.15

    static func box(_ region: MKCoordinateRegion) -> BBox {
        BBox(minLat: region.center.latitude - region.span.latitudeDelta / 2,
             minLon: region.center.longitude - region.span.longitudeDelta / 2,
             maxLat: region.center.latitude + region.span.latitudeDelta / 2,
             maxLon: region.center.longitude + region.span.longitudeDelta / 2)
    }

    static func around(_ c: CLLocationCoordinate2D, metres: Double) -> BBox {
        BBox.around([(c.latitude, c.longitude)], paddingMeters: metres)
    }

    /// The box to score for a visible box, and whether it had to be cut to the cap.
    static func scoring(for visible: BBox) -> (box: BBox, clipped: Bool) {
        let mLat = 111_320.0, mLon = 111_320.0 * max(0.2, cos(visible.centerLat * .pi / 180))
        var halfH = (visible.maxLat - visible.minLat) / 2 * (1 + 2 * margin)
        var halfW = (visible.maxLon - visible.minLon) / 2 * (1 + 2 * margin)
        let capH = maxSideMetres / 2 / mLat, capW = maxSideMetres / 2 / mLon
        let clipped = (visible.maxLat - visible.minLat) / 2 > capH || (visible.maxLon - visible.minLon) / 2 > capW
        halfH = min(halfH, capH); halfW = min(halfW, capW)
        return (BBox(minLat: visible.centerLat - halfH, minLon: visible.centerLon - halfW,
                     maxLat: visible.centerLat + halfH, maxLon: visible.centerLon + halfW), clipped)
    }

    /// Redraw when what is on screen (cut to the cap) leaves the scored box, or after
    /// zooming well in, so the field isn't spending its time far off screen.
    static func needsRecompute(visible: BBox, scored: BBox?) -> Bool {
        guard let scored else { return true }
        let wanted = scoring(for: visible)
        var core = visible
        if wanted.clipped {
            // Zoomed out past the cap: keep the field until its middle half is left behind.
            let q = 0.25
            core = BBox(minLat: wanted.box.minLat + (wanted.box.maxLat - wanted.box.minLat) * q,
                        minLon: wanted.box.minLon + (wanted.box.maxLon - wanted.box.minLon) * q,
                        maxLat: wanted.box.maxLat - (wanted.box.maxLat - wanted.box.minLat) * q,
                        maxLon: wanted.box.maxLon - (wanted.box.maxLon - wanted.box.minLon) * q)
        }
        let inside = core.minLat >= scored.minLat && core.maxLat <= scored.maxLat
            && core.minLon >= scored.minLon && core.maxLon <= scored.maxLon
        if !inside { return true }
        let area = { (b: BBox) in (b.maxLat - b.minLat) * (b.maxLon - b.minLon) }
        return area(scored) > 6 * area(wanted.box)
    }
}

/// Scores the sidewalk edges around a point for a given instant. Everything here
/// runs off the main actor; the UI only ever sees the finished field.
actor SunService {
    /// One scorer, for the city in use: a metro re-stitches as you move, and keeping a
    /// scorer (a building-count scratch array) per stitch would leak.
    private var scorer: (id: String, scorer: SunScorer)?

    func field(around center: CLLocationCoordinate2D, radius: Double, at date: Date,
               skyMode: SkyMode = .auto) async throws -> SunField {
        try await field(in: SunArea.around(center, metres: radius), at: date, skyMode: skyMode)
    }

    /// Scores every sidewalk edge in a box (normally what is on screen).
    func field(in box: BBox, at date: Date, skyMode: SkyMode = .auto) async throws -> SunField {
        let center = CLLocationCoordinate2D(latitude: box.centerLat, longitude: box.centerLon)
        let corners = [center,
                       CLLocationCoordinate2D(latitude: box.minLat, longitude: box.minLon),
                       CLLocationCoordinate2D(latitude: box.minLat, longitude: box.maxLon),
                       CLLocationCoordinate2D(latitude: box.maxLat, longitude: box.minLon),
                       CLLocationCoordinate2D(latitude: box.maxLat, longitude: box.maxLon)]
        let city: LoadedCity
        do {
            city = try await CityStore.shared.city(covering: corners)
        } catch CityCatalogError.noCoverage, CityCatalogError.noServer {
            // Not built here: say so calmly, with the sky and sun that work anywhere.
            let sun = Solar.position(latitude: center.latitude, longitude: center.longitude, date: date)
            let field: SkyField?
            if let preset = skyMode.preset ?? WeatherService.launchPreset() {
                field = WeatherService.field(for: preset, around: center, at: date)
            } else {
                field = await WeatherService.shared.sky(around: center, for: date)
            }
            let sky = field?.condition(latitude: center.latitude, longitude: center.longitude,
                                       at: date, sunElevation: sun.elevation)
            let state = await CityCatalog.shared.coverageState(for: box)
            throw SunServiceError.notCovered(state.hasData ? .notBuilt(nearest: nil, km: nil) : state,
                                             sky: sky, sun: sun, timeZone: nil)
        }
        try Task.checkCancellation()
        let graph = city.bundle.graph
        // Take the scorer out while mutating it, so its scratch buffer is not copied.
        var scorer = (self.scorer?.id == city.id ? self.scorer?.scorer : nil) ?? SunScorer(buildings: city.bundle.buildings)
        self.scorer = nil

        // Weather and geometry are independent; fetch the sky while scoring.
        let skyTask = Task<(SkyField?, String), Never> {
            if let preset = skyMode.preset {
                return (WeatherService.field(for: preset, around: center, at: date), "override")
            }
            let field = await WeatherService.shared.sky(around: center, for: date)
            return (field, WeatherService.launchPreset()?.rawValue ?? "forecast")
        }

        let t0 = CFAbsoluteTimeGetCurrent()
        let sun = Solar.position(latitude: center.latitude, longitude: center.longitude, date: date)
        let edgeIDs = graph.edges(in: box)
        let scores = scorer.score(graph: graph, edges: edgeIDs, sun: sun)
        self.scorer = (city.id, scorer)

        var out: [SunEdge] = []
        out.reserveCapacity(edgeIDs.count)
        var sunny = 0, mixed = 0, shaded = 0
        for (i, e) in edgeIDs.enumerated() {
            let a = Int(graph.edgeA[Int(e)]), b = Int(graph.edgeB[Int(e)])
            let bucket = sun.isUp ? SunBucket(fraction: scores[i]) : .shaded
            switch bucket {
            case .sunny: sunny += 1
            case .mixed: mixed += 1
            case .shaded: shaded += 1
            }
            out.append(SunEdge(
                a: CLLocationCoordinate2D(latitude: graph.nodeLat[a], longitude: graph.nodeLon[a]),
                b: CLLocationCoordinate2D(latitude: graph.nodeLat[b], longitude: graph.nodeLon[b]),
                bucket: bucket))
        }
        let computeMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        let (skyField, source) = await skyTask.value
        let sky = skyField?.condition(latitude: center.latitude, longitude: center.longitude,
                                      at: date, sunElevation: sun.elevation)
        let spread = skyField?.beamSpread(at: date, sunElevation: sun.elevation)

        return SunField(city: city.name, edges: out, sun: sun, center: center, date: date,
                        scoredEdges: edgeIDs.count, computeMs: computeMs,
                        sunnyCount: sunny, mixedCount: mixed, shadedCount: shaded,
                        sky: sky, skySpread: spread, skySource: source,
                        timeZone: city.timeZone, tiles: city.tiles.count,
                        downloaded: city.downloaded, coverage: city.coverage(of: box),
                        built: city.built, cacheBytes: await CityStore.shared.cachedBytes,
                        prefetched: await CityStore.shared.prefetched)
    }

    func daylightWindow(at center: CLLocationCoordinate2D, on date: Date) -> (sunrise: Date, sunset: Date)? {
        Solar.daylightWindow(latitude: center.latitude, longitude: center.longitude, containing: date)
    }
}
