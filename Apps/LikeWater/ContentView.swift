import SwiftUI
import MapKit
import LikeWaterEngine

struct ContentView: View {
    @StateObject private var model = AppModel()
    @ObservedObject private var loadState = CityLoadState.shared
    @State private var showSearch = false
    @State private var longPressTarget: LongPressTarget = .destination

    var body: some View {
        ZStack(alignment: .top) {
            CorridorMapView(model: model, longPressTarget: longPressTarget)
                .ignoresSafeArea()

            VStack(spacing: 8) {
                searchBar
                statusBadges
                Spacer()
            }
            .padding(.top, 6)

            VStack { Spacer(); bottomControls }
        }
        .sheet(isPresented: $showSearch) {
            SearchSheet(model: model, search: model.search, isPresented: $showSearch)
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsSheet(model: model, longPressTarget: $longPressTarget)
        }
        .onReceive(model.location.$coordinate.compactMap { $0 }) { model.onLocationUpdate($0) }
        .onAppear {
            if model.effectiveUserCoordinate == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    if model.effectiveUserCoordinate == nil { model.useFallbackLocation() }
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            Button {
                showSearch = true
            } label: {
                Text(model.destination?.name ?? "Where to?")
                    .foregroundStyle(model.destination == nil ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("whereToButton")
            if model.destination != nil {
                Button { model.clearDestination() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("clearButton")
            }
            Button { model.showSettings = true } label: {
                Image(systemName: "gearshape").foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("settingsButton")
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 12)
    }

    @ViewBuilder private var statusBadges: some View {
        if let message = loadState.message {
            HStack(spacing: 8) {
                if let p = loadState.progress { ProgressView(value: p).frame(width: 90) } else { ProgressView() }
                Text(message).font(.caption)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .accessibilityIdentifier("cityLoadStatus")
        }
        if model.destination == nil, let message = model.ambientError {
            Text(message)
                .font(.caption)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .accessibilityIdentifier("ambientError")
        }
        if model.outsideCity {
            Text("No map data where you are — using the SoMa demo position")
                .font(.caption)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .accessibilityIdentifier("outsideCityBadge")
        }
        if model.arrived {
            Label("Arrived", systemImage: "checkmark.circle.fill")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color.green.opacity(0.9), in: Capsule())
                .foregroundStyle(.white)
                .accessibilityIdentifier("arrivedBadge")
        }
        if case .failed(let message) = model.phase {
            Text(message)
                .font(.caption).multilineTextAlignment(.center)
                .padding(10)
                .background(Color.red.opacity(0.88), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.white)
                .padding(.horizontal)
        }
        if model.phase == .working {
            HStack(spacing: 8) {
                ProgressView()
                Text("Computing corridor…").font(.caption)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }

    /// PRD state 1 hides the layer control until there is a destination. Before then the
    /// panel is the sun around the map: time, scrubber, legend.
    @ViewBuilder private var bottomControls: some View {
        if model.snapshot == nil, model.destination == nil, let field = model.ambient {
            VStack(alignment: .leading, spacing: 10) {
                Text(!field.sun.isUp ? "Sun is down around here"
                     : model.ambientClipped ? "Zoom in to see every street" : "Sun around here")
                    .font(.headline)
                    .accessibilityIdentifier("ambientTitle")
                sunScrubber
                HStack(spacing: 14) {
                    sunLegend
                    Spacer()
                    if let text = model.skyText {
                        Text(text).lineLimit(1).accessibilityIdentifier("skyStatus")
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
                Text("\(field.city)\(field.tiles > 0 ? " (\(field.tiles) tiles)" : "") · \(field.scoredEdges) edges · \(field.sunnyCount) sunny / \(field.mixedCount) mixed / \(field.shadedCount) shaded")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                    .accessibilityIdentifier("ambientStats")
                    .accessibilityValue(String(format: "%.4f,%.4f", field.center.latitude, field.center.longitude))
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .padding(10)
        } else if model.snapshot != nil {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.readout)
                            .font(.title3.weight(.semibold))
                            .accessibilityIdentifier("readout")
                        Text("\(model.distanceText) to go · corridor of \(model.snapshot!.edgeCount) segments")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("subtitle")
                        if let eta = model.etaText {
                            Text(eta)
                                .font(.subheadline.weight(.medium).monospacedDigit())
                                .accessibilityIdentifier("etaText")
                        }
                    }
                    Spacer()
                    Button { model.fitRequest += 1 } label: {
                        Image(systemName: "viewfinder").font(.title3)
                    }
                    .accessibilityIdentifier("fitButton")
                }

                if model.snapshot?.route != nil { routeControls }

                if model.layer == .sun { sunScrubber }

                Picker("Layer", selection: Binding(get: { model.layer },
                                                   set: { model.setLayer($0) })) {
                    ForEach(MapLayer.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("layerPicker")

                legend

                if model.showDebug, let s = model.snapshot {
                    Divider()
                    HStack(spacing: 10) {
                        Button { model.stepForward(meters: 120, random: false) } label: {
                            Label("Step", systemImage: "figure.walk")
                        }
                        .accessibilityIdentifier("stepButton")
                        Button { model.stepForward(meters: 120, random: true) } label: {
                            Label("Random", systemImage: "shuffle")
                        }
                        .accessibilityIdentifier("randomButton")
                    }
                    .buttonStyle(.bordered).font(.footnote)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(s.city) · corridor \(s.edgeCount) edges · \(s.crossingCount) crossings · \(s.nodesExplored) nodes")
                            .accessibilityIdentifier("debugStats")
                        Text("labels \(String(format: "%.1f", s.labelMs)) ms\(s.rebuiltLabels ? " (built)" : " (reused)") · corridor \(String(format: "%.1f", s.corridorMs)) ms · layer \(String(format: "%.1f", s.layerMs)) ms")
                            .accessibilityIdentifier("timingStats")
                        if let r = s.route {
                            Text("route \(String(format: "%.1f", r.routeMs)) ms · \(r.labelsExpanded) labels · \(r.kept ? "kept" : "new") · scored \(s.scoredPairs) (+\(s.cacheHits) cached) · pace \(String(format: "%.2f", model.pace)) m/s")
                                .accessibilityIdentifier("routeStats")
                                .accessibilityValue(r.kept ? "kept" : "new")
                        }
                        if let t = model.lastWalkTiming {
                            Text("last walk: predicted \(AppModel.minutes(t.predicted)) · actual \(AppModel.minutes(t.actual))")
                                .accessibilityIdentifier("walkTiming")
                        }
                    }
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .padding(10)
        }
    }

    /// Which route: Fastest ↔ Sunniest, with what each end gives and what this one costs.
    @ViewBuilder private var routeControls: some View {
        if let route = model.snapshot?.route {
            VStack(alignment: .leading, spacing: 6) {
                if let text = model.routeReadout {
                    Text(text).font(.subheadline.weight(.semibold).monospacedDigit())
                        .accessibilityIdentifier("routeReadout")
                }
                if route.hasSun {
                    Slider(value: Binding(get: { model.sunWeight }, set: { model.setSunWeight($0) }),
                           in: 0...1, step: 0.25)
                        .accessibilityIdentifier("sunWeightSlider")
                    HStack {
                        Text(model.fastestCaption)
                        Spacer()
                        Text(model.sunniestCaption)
                    }
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    SunStrip(route: route)
                        .frame(height: 10)
                        .accessibilityIdentifier("sunStrip")
                        .accessibilityLabel("Sun along the route")
                        .accessibilityValue(model.stripSummary)
                    if let note = model.sunsetNote {
                        HStack(spacing: 6) {
                            Image(systemName: "sunset.fill").accessibilityHidden(true)
                            Text(note).accessibilityIdentifier("sunsetNote")
                        }
                        .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    /// PRD: from now to sunset in 15 minute steps, with a reset back to now.
    @ViewBuilder private var sunScrubber: some View {
        VStack(spacing: 4) {
            HStack {
                Text(model.scrubTimeText)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .accessibilityIdentifier("scrubTime")
                Text(model.sunReadout)
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .accessibilityIdentifier("sunReadout")
                Spacer()
                Button("Now") { model.resetScrubToNow() }
                    .font(.caption).buttonStyle(.bordered)
                    .accessibilityIdentifier("nowButton")
            }
            if let window = model.daylight {
                // PRD: now to sunset. After sunset that range is empty, so fall back to
                // the whole daylight window rather than showing a scrubber that cannot move.
                let sunrise = window.sunrise.timeIntervalSince1970
                let sunset = window.sunset.timeIntervalSince1970
                let now = Date().timeIntervalSince1970
                let scrub = model.scrubDate.timeIntervalSince1970
                let lower = (now < sunset && now > sunrise) ? min(now, scrub) : min(sunrise, scrub)
                let upper = max(sunset, lower + 900)
                Slider(value: Binding(
                    get: { min(max(model.scrubDate.timeIntervalSince1970, lower), upper) },
                    set: { model.setScrubDate(Date(timeIntervalSince1970: ($0 / 900).rounded() * 900)) }),
                       in: lower...upper)
                .accessibilityIdentifier("timeScrubber")
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            switch model.layer {
            case .crossings:
                dot(.blue, "Shortest"); dot(.blue.opacity(0.45), "Free choice")
                dot(.teal.opacity(0.5), "Within slack"); dot(.green, "Crosswalk")
            case .interest:
                dot(Color(red: 0.55, green: 0.52, blue: 0.62), "Nothing")
                dot(Color(red: 0.72, green: 0.42, blue: 0.75), "1–3")
                dot(Color(red: 0.93, green: 0.36, blue: 0.72), "4+")
            case .sun:
                sunLegend
                if model.snapshot?.route != nil {
                    Text("at arrival").lineLimit(1)
                }
                if let text = model.skyText {
                    Text(text).lineLimit(1).accessibilityIdentifier("skyStatus")
                }
            }
        }
        .font(.caption2).foregroundStyle(.secondary)
    }

    /// Faded like the map, so the legend never promises sun the sky isn't giving.
    @ViewBuilder private var sunLegend: some View {
        let beam = model.beamStrength
        dot(Color(SkyPalette.fade(UIColor(red: 1.0, green: 0.73, blue: 0.13, alpha: 1), beam: beam)), "Sun")
        dot(Color(SkyPalette.fade(UIColor(red: 0.90, green: 0.84, blue: 0.62, alpha: 1), beam: beam)), "Mixed")
        dot(Color(SkyPalette.fade(UIColor(red: 0.30, green: 0.40, blue: 0.52, alpha: 1), beam: beam)), "Shade")
    }

    private func dot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 16, height: 4)
            Text(label)
        }
    }
}

/// PRD: settings has one control — slack, from Direct to Wander. The developer
/// section below it is not part of the product screen; it is what the UI tests drive.
struct SettingsSheet: View {
    @ObservedObject var model: AppModel
    @Binding var longPressTarget: LongPressTarget

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Slack")
                            Spacer()
                            Text("\(Int(model.slack * 100))%")
                                .font(.body.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(get: { model.slack }, set: { model.setSlack($0) }),
                               in: 0...0.6, step: 0.01)
                            .accessibilityIdentifier("slackSlider")
                        HStack {
                            Text("Direct"); Spacer(); Text("Wander")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("How much extra distance a street may cost and still count as a free choice.")
                }

                Section {
                    Picker("Walking pace", selection: Binding(get: { model.pace }, set: { model.setPace($0) })) {
                        Text("Relaxed").tag(WalkingPace.relaxed.metresPerSecond)
                        Text("Normal").tag(WalkingPace.normal.metresPerSecond)
                        Text("Brisk").tag(WalkingPace.brisk.metresPerSecond)
                        if ![1.1, 1.4, 1.7].contains(model.pace) {
                            Text(String(format: "Yours (%.1f km/h)", model.pace * 3.6)).tag(model.pace)
                        }
                    }
                    .accessibilityIdentifier("paceSetting")
                    Picker("Prefer", selection: Binding(get: { model.prefer }, set: { model.setPrefer($0) })) {
                        Text("Sun").tag(RoutePreference.sun)
                        Text("Shade").tag(RoutePreference.shade)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("preferSetting")
                } header: {
                    Text("Route")
                } footer: {
                    Text("Times use your pace plus hills, crossings and stairs. Slack above is how much longer the sunniest route may be.")
                }

                Section("Developer") {
                    Toggle("Show timings", isOn: $model.showDebug)
                        .accessibilityIdentifier("debugToggle")
                    Picker("Long press sets", selection: $longPressTarget) {
                        ForEach(LongPressTarget.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Button("Step forward 120 m") { model.stepForward(meters: 120, random: false) }
                        .accessibilityIdentifier("settingsStepButton")
                    Button("Random free choice") { model.stepForward(meters: 120, random: true) }
                        .accessibilityIdentifier("settingsRandomButton")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { model.showSettings = false }
                        .accessibilityIdentifier("settingsDone")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct SearchSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject var search: PlaceSearch
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            List {
                ForEach(search.suggestions, id: \.self) { suggestion in
                    Button {
                        Task {
                            if let place = await search.resolve(suggestion) {
                                model.setDestination(place)
                                isPresented = false
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title).foregroundStyle(.primary)
                            if !suggestion.subtitle.isEmpty {
                                Text(suggestion.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .searchable(text: $search.query, prompt: "Search a destination")
            .onSubmit(of: .search) {
                Task {
                    let center = model.effectiveUserCoordinate ?? AppModel.fallbackCoordinate
                    let region = MKCoordinateRegion(center: center, latitudinalMeters: 4000,
                                                    longitudinalMeters: 4000)
                    if let place = await search.searchText(search.query, near: region) {
                        model.setDestination(place)
                        isPresented = false
                    }
                }
            }
            .navigationTitle("Destination")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
            .onAppear {
                let center = model.effectiveUserCoordinate ?? AppModel.fallbackCoordinate
                search.setRegion(MKCoordinateRegion(center: center, latitudinalMeters: 5000,
                                                    longitudinalMeters: 5000))
            }
        }
        .presentationDetents([.large])
    }
}

/// Sun and shade along the route in walking order, the way the walker will meet them.
struct SunStrip: View {
    let route: RouteView

    var body: some View {
        Canvas { ctx, size in
            let total = max(route.seconds, 1)
            for seg in route.strip {
                let x0 = size.width * seg.start / total, x1 = size.width * seg.end / total
                let base: UIColor = [UIColor(red: 0.30, green: 0.40, blue: 0.52, alpha: 1),
                                     UIColor(red: 0.90, green: 0.84, blue: 0.62, alpha: 1),
                                     UIColor(red: 1.00, green: 0.73, blue: 0.13, alpha: 1)][min(max(seg.bucket, 0), 2)]
                ctx.fill(Path(CGRect(x: x0, y: 0, width: max(x1 - x0, 0.5), height: size.height)),
                         with: .color(Color(SkyPalette.fade(base, beam: Double(seg.beam)))))
            }
            if let t = route.sunsetSeconds {
                let x = size.width * t / total
                ctx.fill(Path(CGRect(x: x - 1, y: -2, width: 2, height: size.height + 4)), with: .color(.orange))
            }
        }
        .clipShape(Capsule())
    }
}
