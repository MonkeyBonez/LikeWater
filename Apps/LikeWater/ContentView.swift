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
                    }
                    Spacer()
                    Button { model.fitRequest += 1 } label: {
                        Image(systemName: "viewfinder").font(.title3)
                    }
                    .accessibilityIdentifier("fitButton")
                }

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
                    }
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .padding(10)
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
