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
    private var scoredBox: BBox?

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
                guard self.center == nil else { return }
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
        if SunArea.needsRecompute(visible: visible, scored: scoredBox) { recompute(force: true) }
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
        isComputing = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let visible = self.visibleBox ?? SunArea.around(center, metres: Self.radius)
                let area = SunArea.scoring(for: visible)
                let result = try await self.service.field(in: area.box, at: self.selectedDate,
                                                          skyMode: self.skyMode)
                guard !Task.isCancelled else { return }
                self.field = result
                self.lastComputedCenter = center
                self.scoredBox = area.box
                self.clipped = area.clipped
                self.daylight = await self.service.daylightWindow(at: center, on: self.selectedDate)
                self.overlayVersion += 1
                self.error = nil
                if !result.sun.isUp {
                    self.status = "Sun is down."
                } else if self.outsideCity {
                    self.status = "No map data where you are — showing SoMa"
                } else if area.clipped {
                    self.status = "Zoom in to see the sun on every street"
                } else {
                    self.status = ""
                }
                self.skyStatus = Self.skyLine(for: result)
                self.cityName = result.city
            } catch {
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

    /// 0…1 beam strength driving the palette; 1 when there is no forecast.
    var beamStrength: Double { field?.sky?.beamStrength ?? 1 }

    var readout: String {
        guard let field else { return "—" }
        guard field.sun.isUp else { return "Sun is down." }
        return String(format: "az %.0f°  ·  el %.0f°", field.sun.azimuth, field.sun.elevation)
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
