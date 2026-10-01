import SwiftUI
import MapKit
import LikeWaterEngine

struct SunMapScreen: View {
    @StateObject private var model = SunMapModel()
    @ObservedObject private var loadState = CityLoadState.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            SunMapMapView(model: model)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()
                panel
            }
        }
        .overlay(alignment: .top) { topStatus }
        .onReceive(model.location.$coordinate.compactMap { $0 }) { model.onLocationUpdate($0) }
        .onAppear {
            if model.center == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { model.useFallbackCenter() }
            } else {
                model.recompute(force: true)
            }
        }
    }

    @ViewBuilder private var topStatus: some View {
        VStack(spacing: 6) {
            if let error = model.error {
                Text(error)
                    .font(.caption).foregroundStyle(.white)
                    .padding(10)
                    .background(Color.red.opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal)
            }
            if let message = loadState.message {
                HStack(spacing: 8) {
                    if let p = loadState.progress { ProgressView(value: p).frame(width: 90) } else { ProgressView() }
                    Text(message).font(.caption)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .accessibilityIdentifier("cityLoadStatus")
            } else if model.field == nil && model.error == nil {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading city…").font(.caption)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
            }
            if !model.status.isEmpty {
                Text(model.status)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                    .accessibilityIdentifier("sunStatus")
            }
        }
        .padding(.top, 8)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.timeText)
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .accessibilityIdentifier("sunTime")
                Text(model.readout)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("sunReadout")
                Spacer()
                Button("Now") { model.resetToNow() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("nowButton")
            }

            if let window = model.daylight {
                HStack(spacing: 8) {
                    Button { model.stepMinutes(-15) } label: { Image(systemName: "minus.circle") }
                        .accessibilityIdentifier("stepBack")
                    Slider(value: Binding(
                        get: { model.selectedDate.timeIntervalSince1970 },
                        set: { model.setDate(Date(timeIntervalSince1970: ($0 / 900).rounded() * 900)) }),
                           in: window.sunrise.timeIntervalSince1970...window.sunset.timeIntervalSince1970)
                    .accessibilityIdentifier("timeScrubber")
                    Button { model.stepMinutes(15) } label: { Image(systemName: "plus.circle") }
                        .accessibilityIdentifier("stepForward")
                }
                .buttonStyle(.borderless)
                HStack {
                    Text(short(window.sunrise)); Spacer(); Text(short(window.sunset))
                }
                .font(.caption2).foregroundStyle(.secondary)
            }

            legend

            Picker("Sky", selection: Binding(get: { model.skyMode }, set: { model.setSkyMode($0) })) {
                ForEach(SkyMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("skyPicker")

            if !model.skyStatus.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: skyIcon)
                    Text(model.skyStatus)
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(model.beamStrength < 0.15 ? .secondary : .primary)
                .accessibilityIdentifier("skyStatus")
            }

            if let field = model.field {
                Text("\(field.city)\(field.tiles > 0 ? " (\(field.tiles) tiles\(field.downloaded > 0 ? ", \(field.downloaded) downloaded" : ""))" : "") · \(field.scoredEdges) edges scored in \(String(format: "%.0f", field.computeMs)) ms · \(field.sunnyCount) sunny / \(field.mixedCount) mixed / \(field.shadedCount) shaded · sky \(String(format: "%.2f", model.beamStrength)) \(field.skySource)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("sunStats")
                    .accessibilityValue(String(format: "%.4f,%.4f", field.center.latitude, field.center.longitude))
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(10)
    }

    private var skyIcon: String {
        guard let sky = model.field?.sky else { return "questionmark.circle" }
        switch sky.regime {
        case .clear: return "sun.max.fill"
        case .hazy: return "sun.haze.fill"
        case .broken: return "cloud.sun.fill"
        case .overcast: return sky.lowCloud >= 0.6 ? "cloud.fog.fill" : "cloud.fill"
        }
    }

    private var legend: some View {
        let p = SkyPalette.colors(beam: model.beamStrength)
        return HStack(spacing: 14) {
            swatch(Color(p.sun), "Sun")
            swatch(Color(p.mixed), "Mixed")
            swatch(Color(p.shade), "Shade")
        }
        .font(.caption2).foregroundStyle(.secondary)
    }

    private func swatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 18, height: 4)
            Text(label)
        }
    }

    private func short(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mm a"
        f.timeZone = model.cityTimeZone
        return f.string(from: date)
    }
}
