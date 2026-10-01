import Foundation
import MapKit
import SwiftUI
import LikeWaterEngine

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case working
        case ready
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var destination: Place?
    @Published var snapshot: CorridorSnapshot?
    @Published var layer: MapLayer = .crossings
    /// PRD: slack slider runs 0 to 60%, default 10%.
    @Published var slack: Double = 0.10
    @Published var scrubDate: Date = Date()
    @Published var daylight: (sunrise: Date, sunset: Date)?
    @Published var userCoordinate: CLLocationCoordinate2D?
    @Published var overlayVersion = 0
    @Published var fitRequest = 0
    @Published var arrived = false
    @Published var showSettings = false
    @Published var showDebug = false
    @Published var usingSimulatedWalk = false
    /// True when the user is not in the bundled city, so the demo position is in use.
    @Published var outsideCity = false
    /// True when a launch argument pinned the scrub time, so the product's
    /// "never scrub into the past" clamp must not overwrite it.
    private var datePinned = false

    let location = LocationService()
    let search = PlaceSearch()
    private let service = CorridorService()
    private var recomputeTask: Task<Void, Never>?

    // MARK: Sun around the map, before there is a walk
    /// With no destination, the map still paints the sun on the sidewalks around whatever
    /// the user is looking at — the Sun Map, inside Like Water. A destination replaces it
    /// with the corridor; clearing the destination brings it back.
    @Published var ambient: SunField?
    @Published var ambientError: String?
    private let sunService = SunService()
    private var ambientTask: Task<Void, Never>?
    private var scoredBox: BBox?
    private var visibleBox: BBox?
    private var mapCenter: CLLocationCoordinate2D?
    /// Fallback radius before the map has reported what is on screen.
    static let ambientRadius: Double = 400
    /// True when a zoomed-out screen is only scored in the middle.
    @Published var ambientClipped = false
    /// Bumped when the map should move to the user (their first real fix).
    @Published var recenterRequest = 0
    /// The demo position is standing in for a fix that hasn't arrived.
    private var onFallback = false
    /// The user has panned or zoomed; a late fix must not yank the map back.
    var userMovedMap = false

    var showingAmbient: Bool { destination == nil && ambient != nil }

    /// The map moved: with no walk, paint the sun on everything now on screen.
    func mapRegionChanged(_ region: MKCoordinateRegion) {
        mapCenter = region.center
        let visible = SunArea.box(region)
        visibleBox = visible
        guard destination == nil else { return }
        if SunArea.needsRecompute(visible: visible, scored: scoredBox) { refreshAmbient() }
    }

    func refreshAmbient() {
        guard destination == nil, let center = mapCenter ?? effectiveUserCoordinate else { return }
        ambientTask?.cancel()
        let date = scrubDate
        let area = SunArea.scoring(for: visibleBox ?? SunArea.around(center, metres: Self.ambientRadius))
        ambientTask = Task { [weak self] in
            guard let self else { return }
            do {
                let field = try await self.sunService.field(in: area.box, at: date)
                guard !Task.isCancelled, self.destination == nil else { return }
                self.ambient = field
                self.scoredBox = area.box
                self.ambientClipped = area.clipped
                self.ambientError = nil
                self.daylight = await self.sunService.daylightWindow(at: center, on: date)
                self.overlayVersion += 1
            } catch {
                guard !Task.isCancelled else { return }
                self.ambient = nil
                self.ambientError = error.localizedDescription
                self.overlayVersion += 1
            }
        }
    }

    /// Fallback when there is no fix: 3rd & Howard, SoMa.
    static let fallbackCoordinate = CLLocationCoordinate2D(latitude: 37.78415, longitude: -122.40060)

    init() {
        location.start()
        applyLaunchOverrides()
        if let start = userCoordinate { Task { try? await service.prepare(for: start) } }
    }

    /// Launch arguments let the UI tests and demos pin a deterministic walk without
    /// depending on a GPS fix or a search round-trip.
    private func applyLaunchOverrides() {
        let defaults = UserDefaults.standard
        func coordinate(_ key: String) -> CLLocationCoordinate2D? {
            guard let raw = defaults.string(forKey: key) else { return nil }
            let parts = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 2 else { return nil }
            return CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1])
        }
        if defaults.string(forKey: "uiTestDebug") != nil { showDebug = true }
        if let raw = defaults.string(forKey: "uiTestSlack"), let value = Double(raw) {
            slack = min(max(value, 0), 0.6)
        }
        if let raw = defaults.string(forKey: "uiTestLayer"),
           let value = MapLayer(rawValue: raw) {
            layer = value
        }
        if let raw = defaults.string(forKey: "uiTestDate") {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            if let d = f.date(from: raw) { scrubDate = d; datePinned = true }
        }
        if let start = coordinate("uiTestStart") {
            usingSimulatedWalk = true
            userCoordinate = start
        }
        if let target = coordinate("uiTestDestination") {
            let name = defaults.string(forKey: "uiTestDestinationName") ?? "Test destination"
            Task { @MainActor in
                self.setDestination(Place(name: name, subtitle: "", coordinate: target))
            }
        }
    }

    var effectiveUserCoordinate: CLLocationCoordinate2D? {
        userCoordinate ?? location.coordinate
    }

    func onLocationUpdate(_ coordinate: CLLocationCoordinate2D) {
        // A launch-argument walk or a long-press position owns the user's position; the
        // demo fallback only stands in until a real fix arrives.
        guard !usingSimulatedWalk || onFallback else { return }
        Task { @MainActor in
            if await CityCatalog.shared.anyCoverage(coordinate) {
                let first = self.userCoordinate == nil || self.onFallback
                self.outsideCity = false
                self.userCoordinate = coordinate
                if self.onFallback {
                    self.onFallback = false
                    self.usingSimulatedWalk = false
                }
                if first && !self.userMovedMap && self.destination == nil { self.recenterRequest += 1 }
                self.scheduleRecompute()
            } else if self.userCoordinate == nil {
                // Nowhere we have data: put the user on the demo corner so the app is
                // still usable, and say so rather than failing to snap.
                self.outsideCity = true
                self.usingSimulatedWalk = true
                self.onFallback = true
                self.userCoordinate = Self.fallbackCoordinate
                self.recenterRequest += 1
                self.scheduleRecompute()
            }
        }
    }

    func useFallbackLocation() {
        usingSimulatedWalk = true
        onFallback = true
        userCoordinate = Self.fallbackCoordinate
        recenterRequest += 1
        scheduleRecompute()
    }

    func setUserCoordinate(_ coordinate: CLLocationCoordinate2D) {
        usingSimulatedWalk = true
        onFallback = false
        userCoordinate = coordinate
        scheduleRecompute()
    }

    func setDestination(_ place: Place) {
        destination = place
        snapshot = nil
        arrived = false
        phase = .working
        Task {
            await service.setDestination(place.coordinate)
            await recompute(fit: true)
        }
    }

    func clearDestination() {
        destination = nil
        snapshot = nil
        phase = .idle
        overlayVersion += 1
        Task { await service.clear() }
        scoredBox = nil
        refreshAmbient()
    }

    func setLayer(_ value: MapLayer) {
        layer = value
        if value == .sun && !datePinned { scrubDate = max(scrubDate, Date()) }
        scheduleRecompute(immediate: true)
    }

    func setSlack(_ value: Double) {
        slack = value
        scheduleRecompute()
    }

    func setScrubDate(_ value: Date) {
        datePinned = true
        scrubDate = value
        scheduleRecompute()
    }

    func resetScrubToNow() {
        datePinned = false
        scrubDate = Date()
        scheduleRecompute(immediate: true)
    }

    private func scheduleRecompute(immediate: Bool = false) {
        guard destination != nil else {
            // No walk: time changes redraw the sun around the map instead.
            refreshAmbient()
            return
        }
        recomputeTask?.cancel()
        recomputeTask = Task { [weak self] in
            if !immediate { try? await Task.sleep(nanoseconds: 100_000_000) }
            guard !Task.isCancelled else { return }
            await self?.recompute(fit: false)
        }
    }

    func recompute(fit: Bool) async {
        guard destination != nil else { return }
        guard let user = effectiveUserCoordinate else {
            phase = .failed("Waiting for a location fix.")
            return
        }
        do {
            let snap = try await service.update(user: user, slack: slack,
                                                layer: layer, date: scrubDate)
            snapshot = snap
            phase = .ready
            overlayVersion += 1
            if fit { fitRequest += 1 }
            if layer == .sun {
                daylight = await service.daylightWindow(at: user, on: scrubDate)
            }
            if snap.hasArrived { handleArrival() }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// PRD state 5: within 20 m, clear the corridor and return to state 1.
    private func handleArrival() {
        arrived = true
        clearDestination()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            self.arrived = false
        }
    }

    // MARK: - Simulated walk (development aid; not part of the product screen)

    func stepForward(meters: Double, random: Bool) {
        guard let user = effectiveUserCoordinate else { return }
        Task {
            if let next = await service.step(from: user, meters: meters, slack: slack,
                                             strategy: random ? .random : .shortest) {
                usingSimulatedWalk = true
                userCoordinate = next
                await recompute(fit: false)
            }
        }
    }

    // MARK: - Readouts

    var readout: String {
        guard let snap = snapshot else { return "—" }
        if snap.distance < 30 { return "You have arrived" }
        if snap.choicesHere == 0 { return "Follow the line to the end" }
        if snap.choicesHere == 1 { return "One way forward" }
        if snap.metersToDecision < 25 { return "\(snap.choicesHere) free choices here" }
        return "\(snap.choicesHere) free choices in \(Int(snap.metersToDecision.rounded())) m"
    }

    var distanceText: String {
        guard let snap = snapshot else { return "—" }
        return snap.distance >= 1000
            ? String(format: "%.2f km", snap.distance / 1000)
            : "\(Int(snap.distance.rounded())) m"
    }

    /// Fraction of the clear-sky beam getting through, for whichever sun view is on
    /// screen; 1 (clear) when there is no forecast.
    var beamStrength: Double {
        if let snap = snapshot { return snap.sky?.beamStrength ?? 1 }
        return ambient?.sky?.beamStrength ?? 1
    }

    var skyText: String? {
        let sky = snapshot.map { $0.layer == .sun ? $0.sky : nil } ?? ambient?.sky
        guard let sky, (snapshot?.sun ?? ambient?.sun)?.isUp == true else { return nil }
        return sky.summary
    }

    var sunReadout: String {
        guard let sun = snapshot?.sun ?? (showingAmbient ? ambient?.sun : nil) else { return "" }
        guard sun.isUp else { return "Sun is down." }
        return String(format: "az %.0f°  ·  el %.0f°", sun.azimuth, sun.elevation)
    }

    var scrubTimeText: String {
        let f = DateFormatter(); f.dateFormat = "h:mm a"
        let zone = snapshot?.timeZone ?? ambient?.timeZone ?? .current
        f.timeZone = zone
        var text = f.string(from: scrubDate)
        if zone.secondsFromGMT(for: scrubDate) != TimeZone.current.secondsFromGMT(for: scrubDate) {
            text += " " + (zone.abbreviation(for: scrubDate) ?? "")
        }
        return text
    }
}
