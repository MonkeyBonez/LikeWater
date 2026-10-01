import Foundation
import CoreLocation
import SwiftUI
import MapKit
import LikeWaterEngine

@MainActor
final class SunMapModel: ObservableObject {
    @Published var field: SunField?
    @Published var status: String = "Loading city…"
    @Published var error: String?
    @Published var selectedDate: Date = Date()
    @Published var daylight: (sunrise: Date, sunset: Date)?
    @Published var overlayVersion = 0
    @Published var center: CLLocationCoordinate2D?
    @Published var isComputing = false
    /// True when the user is not in the bundled city, so the map is showing the demo area.
    @Published var outsideCity = false
    @Published var cityName: String = ""
    /// Auto = live forecast; the others freeze the sky for "what if it clears up".
    @Published var skyMode: SkyMode = .auto
    /// Bumped when the map should move to `center` (the first real fix, "demo area").
    @Published var recenterRequest = 0
    /// True when the field covers only the middle of a zoomed-out screen.
    @Published var clipped = false
    /// The fallback demo centre is standing in for a location fix that hasn't come yet.
    private var centerIsFallback = false
    /// The user has moved the map themselves; a late fix must not yank it back.
    var userMovedMap = false
    private var visibleBox: BBox?
    private var scoredPlan: SunArea.Plan?
    private var panDebounce: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    /// Which recompute is current; streamed partials of an older one are dropped.
    private var generation = 0
    /// Set when nothing is built under the screen: why, plus the sky and sun, which work anywhere.
    @Published var notCovered: (state: CoverageState, sky: SkyCondition?, sun: SolarPosition)?
    @Published var requestSent = false

    /// PRD: redraw when the map centre moves more than this, and the field covers 400 m.
    static let recomputeDistance: Double = 200
    static let radius: Double = 400
    static let refreshInterval: TimeInterval = 600

    let location = LocationService()
    private let service = SunService()
    private var lastComputedCenter: CLLocationCoordinate2D?
    private var task: Task<Void, Never>?
    private var ticker: Timer?

    /// Fallback when the simulator has no fix: 3rd & Howard, SoMa.
    static let fallbackCenter = CLLocationCoordinate2D(latitude: 37.78415, longitude: -122.40060)

    init() {
        location.start()
        applyLaunchOverrides()
        ticker = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIfFollowingNow() }
        }
    }

    private func applyLaunchOverrides() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "uiTestCenter") {
            let parts = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2 {
                center = CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1])
            }
        }
        if let raw = defaults.string(forKey: "uiTestDate") {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            if let d = f.date(from: raw) { selectedDate = d }
        }
    }

    var isFollowingNow: Bool { abs(selectedDate.timeIntervalSinceNow) < 90 }

    func onLocationUpdate(_ coordinate: CLLocationCoordinate2D) {
        guard UserDefaults.standard.string(forKey: "uiTestCenter") == nil else { return }
        // Follow the first real fix — including one that arrives after the demo fallback
        // took over — unless the user has already moved the map.
        guard center == nil || (centerIsFallback && !userMovedMap) else { return }
        Task { @MainActor in
            // Use the real fix if any city — local or downloadable — covers it;
            // otherwise show the demo area and say so.
            if await CityCatalog.shared.anyCoverage(coordinate) {
                self.center = coordinate
                self.centerIsFallback = false
                self.outsideCity = false
            } else {
                // Unbuilt where the user is: stay on (or move to) the demo area and say so.
                // The map usually reports its starting region before the fix, so "center is
                // set" doesn't mean the user chose it.
                guard self.center == nil || self.centerIsFallback else { return }
                self.center = Self.fallbackCenter
                self.centerIsFallback = true
                self.outsideCity = true
            }
            self.recenterRequest += 1
            self.recompute(force: true)
        }
    }

    /// No fix yet: show the demo area until one arrives.
    func useFallbackCenter() {
        guard center == nil else { return }
        center = Self.fallbackCenter
        centerIsFallback = true
        recenterRequest += 1
        recompute(force: true)
    }

    func jumpToDemoArea() {
        center = Self.fallbackCenter
        outsideCity = true
        recenterRequest += 1
        recompute(force: true)
    }

    /// The map moved: score everything on screen, not a fixed square around the centre.
    func mapRegionChanged(_ region: MKCoordinateRegion) {
        // The map reports its starting (demo) region before any fix has arrived; that
        // centre is a stand-in too, and a real fix must still replace it.
        if center == nil { centerIsFallback = true }
        center = region.center
        let visible = SunArea.box(region)
        visibleBox = visible
        // A swipe reports several regions; score only where the map settles.
        panDebounce?.cancel()
        panDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.notCovered != nil || SunArea.needsRecompute(visible: visible, scored: self.scoredPlan) {
                self.recompute(force: true)
            }
        }
    }

    func setDate(_ date: Date) {
        selectedDate = date
        recompute(force: true)
    }

    /// The PRD's scrubber moves in 15-minute steps; these are the same steps as buttons.
    func stepMinutes(_ minutes: Int) {
        var next = selectedDate.addingTimeInterval(Double(minutes) * 60)
        if let window = daylight {
            next = min(max(next, window.sunrise), window.sunset)
        }
        setDate(next)
    }

    func resetToNow() {
        selectedDate = Date()
        recompute(force: true)
    }

    func setSkyMode(_ mode: SkyMode) {
        skyMode = mode
        recompute(force: true)
    }

    private func refreshIfFollowingNow() {
        guard isFollowingNow else { return }
        selectedDate = Date()
        recompute(force: true)
    }

    func recompute(force: Bool) {
        guard let center else { return }
        task?.cancel()
        prefetchTask?.cancel()
        isComputing = true
        generation += 1
        let gen = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let visible = self.visibleBox ?? SunArea.around(center, metres: Self.radius)
                guard let plan = SunArea.plan(for: visible) else { throw SunServiceError.tooFarOut }
                // Tiles land as they are scored; the screen never waits for the last one. A
                // partial from a superseded recompute is dropped (its own task cancels late).
                let result = try await self.service.field(plan, at: self.selectedDate,
                                                          skyMode: self.skyMode) { partial in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == gen else { return }
                        self.field = partial
                        self.overlayVersion += 1
                    }
                }
                guard !Task.isCancelled else { return }
                self.field = result
                self.notCovered = nil
                self.lastComputedCenter = center
                self.scoredPlan = plan
                self.clipped = false
                self.daylight = await self.service.daylightWindow(at: center, on: self.selectedDate)
                self.overlayVersion += 1
                self.error = nil
                self.updateStatus()
                self.skyStatus = Self.skyLine(for: result)
                self.cityName = result.city
                // Score the ring around the screen quietly, so the next pan is already there.
                let date = self.selectedDate
                self.prefetchTask = Task.detached(priority: .background) { [service = self.service] in
                    await service.prefetch(plan, at: date)
                }
            } catch SunServiceError.notCovered(let state, let sky, let sun, _) {
                guard !Task.isCancelled else { return }
                self.field = nil
                self.scoredPlan = nil
                self.notCovered = (state, sky, sun)
                self.requestSent = false
                self.error = nil
                self.status = ""
                self.skyStatus = sun.isUp ? (sky?.summary ?? "No forecast") : ""
                self.daylight = await self.service.daylightWindow(at: center, on: self.selectedDate)
                self.overlayVersion += 1
            } catch SunServiceError.tooFarOut {
                guard !Task.isCancelled else { return }
                self.field = nil
                self.scoredPlan = nil
                self.notCovered = nil
                self.error = nil
                self.status = "Zoom in to see sun data"
                self.overlayVersion += 1
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            self.isComputing = false
        }
    }

    /// The weather line under the sun readout.
    @Published var skyStatus: String = ""

    static func skyLine(for field: SunField) -> String {
        guard field.sun.isUp else { return "" }
        guard let sky = field.sky else { return "No forecast · assuming clear sky" }
        var line = sky.summary
        if let spread = field.skySpread, spread.max - spread.min >= 0.4, field.skySource != "override" {
            // The city is in two weathers; say which one the user is in.
            line += sky.beamStrength < 0.4 ? " here · sun nearby" : " here · fog nearby"
        }
        if field.skySource == "override" { line += " (set by you)" }
        return line
    }

    /// One status line, from the current state: sun down, demo area, zoomed out past the
    /// cap, or a screen only partly covered.
    func updateStatus() {
        guard let field else { return }
        if !field.sun.isUp { status = "Sun is down." }
        else if showingDemoArea { status = "No map data where you are — showing SoMa" }
        else if field.detail.isBlocks {
            status = "Sun by block · zoom in for streets"
            if field.missingTiles > 0 { status += " · \(field.missingTiles) areas not downloaded" }
        }
        else if field.coverage == .partial { status = "Only part of this screen has sun data" }
        else { status = "" }
    }

    /// The demo area is on screen because the user's own position has no data — and they
    /// haven't moved the map since. Derived, so it can't go stale after a pan.
    var showingDemoArea: Bool { outsideCity && centerIsFallback && !userMovedMap }

    /// "No sun data here yet" + the nearest built place.
    var coverageDetail: String? {
        guard let nc = notCovered else { return nil }
        switch nc.state {
        case .notBuilt(let nearest?, let km?):
            return String(format: "Nearest with sun data: %@, %.0f km", nearest, km)
        case .noServer:
            return "This phone has no map data here and no bundle server is configured."
        default:
            return "We haven't built this area yet."
        }
    }

    var canRequestCoverage: Bool { CoverageRequest.url != nil }

    func requestCoverage() {
        guard let c = center else { return }
        Task { self.requestSent = await CoverageRequest.send(c) }
    }

    /// 0…1 beam strength driving the palette; 1 when there is no forecast.
    var beamStrength: Double { field?.sky?.beamStrength ?? notCovered?.sky?.beamStrength ?? 1 }

    var readout: String {
        guard let sun = field?.sun ?? notCovered?.sun else { return "—" }
        guard sun.isUp else { return "Sun is down." }
        return String(format: "az %.0f°  ·  el %.0f°", sun.azimuth, sun.elevation)
    }

    /// The city's time zone once a field has loaded; the device's until then.
    var cityTimeZone: TimeZone { field?.timeZone ?? .current }

    var timeText: String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        f.timeZone = cityTimeZone
        var text = f.string(from: selectedDate)
        if cityTimeZone.secondsFromGMT(for: selectedDate) != TimeZone.current.secondsFromGMT(for: selectedDate) {
            text += " " + (cityTimeZone.abbreviation(for: selectedDate) ?? "")
        }
        return text
    }
}
