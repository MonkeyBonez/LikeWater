import SwiftUI
import MapKit
import LikeWaterEngine

/// One colour band of the corridor (or of the ambient sun), at one beam strength: edges
/// reached in different 15-minute slots can sit under different skies.
final class CorridorBand: MKMultiPolyline {
    var band = 0
    var beam: Float = 1
    convenience init(_ lines: [MKPolyline], band: Int, beam: Float) {
        self.init(lines); self.band = band; self.beam = beam
    }
}

/// The suggested route, drawn on top. `band` nil = the accent colour (Crossings/Interest).
final class RouteLine: MKMultiPolyline {
    var band: Int?
    var beam: Float = 1
    var casing = false
    convenience init(_ lines: [MKPolyline], band: Int?, beam: Float, casing: Bool = false) {
        self.init(lines); self.band = band; self.beam = beam; self.casing = casing
    }
}

final class DestinationAnnotation: MKPointAnnotation {}
final class UserDotAnnotation: MKPointAnnotation {}
final class CrossingAnnotation: MKPointAnnotation {}

enum LongPressTarget: String, CaseIterable, Identifiable {
    case destination = "Destination"
    case myPosition = "My position"
    var id: String { rawValue }
}

struct CorridorMapView: UIViewRepresentable {
    @ObservedObject var model: AppModel
    var longPressTarget: LongPressTarget

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsCompass = true
        map.pointOfInterestFilter = .excludingAll
        let press = UILongPressGestureRecognizer(target: context.coordinator,
                                                 action: #selector(Coordinator.handleLongPress(_:)))
        press.minimumPressDuration = 0.35
        map.addGestureRecognizer(press)
        context.coordinator.map = map
        let start = model.effectiveUserCoordinate ?? AppModel.fallbackCoordinate
        map.setRegion(MKCoordinateRegion(center: start, latitudinalMeters: 900,
                                         longitudinalMeters: 900), animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.model = model
        context.coordinator.longPressTarget = longPressTarget
        if context.coordinator.rendered != model.overlayVersion {
            context.coordinator.rendered = model.overlayVersion
            context.coordinator.routeRendered = model.routeVersion
            if model.snapshot == nil, model.destination == nil, let field = model.ambient {
                context.coordinator.renderAmbient(on: map, field: field)
            } else {
                context.coordinator.render(on: map, snapshot: model.snapshot)
            }
        } else if context.coordinator.routeRendered != model.routeVersion {
            context.coordinator.routeRendered = model.routeVersion
            context.coordinator.renderRoute(on: map, snapshot: model.snapshot)
        }
        if context.coordinator.recentered != model.recenterRequest,
           let user = model.effectiveUserCoordinate {
            context.coordinator.recentered = model.recenterRequest
            context.coordinator.programmatic = true
            map.setCenter(user, animated: true)
        }
        if context.coordinator.fitted != model.fitRequest {
            context.coordinator.fitted = model.fitRequest
            context.coordinator.fit(map: map)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var model: AppModel
        weak var map: MKMapView?
        var rendered = -1
        var routeRendered = -1
        var fitted = 0
        var recentered = 0
        var programmatic = false
        var longPressTarget: LongPressTarget = .destination

        init(model: AppModel) { self.model = model }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let map else { return }
            let coordinate = map.convert(gesture.location(in: map), toCoordinateFrom: map)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            switch longPressTarget {
            case .destination:
                model.setDestination(Place(name: "Dropped pin",
                                           subtitle: String(format: "%.5f, %.5f",
                                                            coordinate.latitude, coordinate.longitude),
                                           coordinate: coordinate))
            case .myPosition:
                model.setUserCoordinate(coordinate)
            }
        }

        /// Bands 0/1/2 mean different things per layer, which is why the renderer asks
        /// the model for the active layer rather than baking colours into the overlay.
        private func band(for edge: CorridorEdgeView, snapshot: CorridorSnapshot) -> Int {
            switch snapshot.layer {
            case .crossings:
                let tight = max(2.0, snapshot.distance * 0.004)
                let mid = max(tight, snapshot.distance * snapshot.slack * 0.4)
                return edge.excess <= tight ? 2 : (edge.excess <= mid ? 1 : 0)
            case .interest:
                return edge.interestBucket
            case .sun:
                return edge.sunBucket ?? 0
            }
        }

        func render(on map: MKMapView, snapshot: CorridorSnapshot?) {
            clearAmbient(on: map)
            map.removeOverlays(map.overlays)
            map.removeAnnotations(map.annotations)
            guard let snapshot else { return }

            // Group by (band, beam to 0.1): ≤ 33 overlays however long the walk.
            var groups: [Int: [MKPolyline]] = [:]
            for edge in snapshot.edges {
                var pair = [edge.a, edge.b]
                let beam = snapshot.layer == .sun ? Int((edge.beam * 10).rounded()) : 10
                groups[band(for: edge, snapshot: snapshot) * 100 + beam, default: []]
                    .append(MKPolyline(coordinates: &pair, count: 2))
            }
            for (key, lines) in groups.sorted(by: { $0.key < $1.key }) {
                map.addOverlay(CorridorBand(lines, band: key / 100, beam: Float(key % 100) / 10), level: .aboveRoads)
            }
            addRoute(on: map, snapshot: snapshot)

            // PRD: crossing markers only on the Crossings layer.
            if snapshot.layer == .crossings {
                for node in snapshot.crossingNodes.prefix(400) {
                    let a = CrossingAnnotation(); a.coordinate = node
                    map.addAnnotation(a)
                }
            }

            let destination = DestinationAnnotation()
            destination.coordinate = snapshot.destination
            destination.title = model.destination?.name ?? "Destination"
            map.addAnnotation(destination)

            let user = UserDotAnnotation()
            user.coordinate = snapshot.snapped
            user.title = "You"
            map.addAnnotation(user)
        }

        /// Overlays of the ambient sun field, by score tile (diffed on pan, like Sun Map).
        var ambientShown: [SunTileKey: SunOverlays.Shown] = [:]
        var ambientBeam = 1.0

        /// The sun around the map centre, before there is a walk: same colours as the
        /// corridor's sun layer, so they mean the same thing in both states.
        func renderAmbient(on map: MKMapView, field: SunField) {
            map.removeOverlays(map.overlays.filter { !($0 is SunLinesOverlay || $0 is SunCellsOverlay) })
            map.removeAnnotations(map.annotations)
            SunOverlays.sync(map, field: field, shown: &ambientShown)
            let beam = model.beamStrength
            if abs(beam - ambientBeam) > 0.02 {
                // The sky changed, not the geometry: recolour the renderers in place.
                ambientBeam = beam
                for shown in ambientShown.values {
                    for o in shown.overlays {
                        guard let r = map.renderer(for: o) else { continue }
                        styleAmbient(r, for: o, beam: beam)
                        r.setNeedsDisplay()
                    }
                }
            }
            if let user = model.effectiveUserCoordinate {
                let dot = UserDotAnnotation(); dot.coordinate = user; dot.title = "You"
                map.addAnnotation(dot)
            }
        }

        func clearAmbient(on map: MKMapView) {
            for shown in ambientShown.values { map.removeOverlays(shown.overlays) }
            ambientShown.removeAll()
        }

        func styleAmbient(_ renderer: MKOverlayRenderer, for overlay: MKOverlay, beam: Double) {
            let sunPalette = colors(for: .sun)
            if let lines = overlay as? SunLinesOverlay, let r = renderer as? MKMultiPolylineRenderer {
                r.strokeColor = SkyPalette.fade(sunPalette[lines.bucket.rawValue].0, beam: beam)
                r.lineWidth = sunPalette[lines.bucket.rawValue].1
                r.lineCap = .round
            } else if let cells = overlay as? SunCellsOverlay, let r = renderer as? MKMultiPolygonRenderer {
                r.fillColor = SkyPalette.cell(fraction: cells.fraction, beam: beam)
                r.strokeColor = nil
            }
        }

        /// A slider move: swap only the route line.
        func renderRoute(on map: MKMapView, snapshot: CorridorSnapshot?) {
            map.removeOverlays(map.overlays.filter { $0 is RouteLine })
            guard let snapshot else { return }
            addRoute(on: map, snapshot: snapshot)
        }

        private func addRoute(on map: MKMapView, snapshot: CorridorSnapshot) {
            guard let route = snapshot.route, route.coordinates.count >= 2 else { return }
            let sun = snapshot.layer == .sun && route.hasSun
            var all: [MKPolyline] = []
            var groups: [Int: [MKPolyline]] = [:]
            for k in 0..<(route.coordinates.count - 1) {
                var pair = [route.coordinates[k], route.coordinates[k + 1]]
                let line = MKPolyline(coordinates: &pair, count: 2)
                all.append(line)
                let key = sun && k < route.edgeBuckets.count
                    ? route.edgeBuckets[k] * 100 + Int((route.edgeBeams[k] * 10).rounded()) : -1
                groups[key, default: []].append(MKPolyline(coordinates: &pair, count: 2))
            }
            // A white casing under the route lifts it off the corridor.
            map.addOverlay(RouteLine(all, band: nil, beam: 1, casing: true), level: .aboveLabels)
            for (key, lines) in groups.sorted(by: { $0.key < $1.key }) {
                map.addOverlay(RouteLine(lines, band: key < 0 ? nil : key / 100,
                                         beam: key < 0 ? 1 : Float(key % 100) / 10), level: .aboveLabels)
            }
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            let touching = mapView.subviews.first?.gestureRecognizers?.contains {
                $0.state == .began || $0.state == .changed
            } ?? false
            if touching && !programmatic { model.userMovedMap = true }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            programmatic = false
            model.mapRegionChanged(mapView.region)
        }

        func fit(map: MKMapView) {
            guard let snapshot = model.snapshot else { return }
            var rect = MKMapRect.null
            func include(_ c: CLLocationCoordinate2D) {
                rect = rect.union(MKMapRect(origin: MKMapPoint(c), size: .init(width: 1, height: 1)))
            }
            for edge in snapshot.edges { include(edge.a); include(edge.b) }
            for c in snapshot.route?.coordinates ?? [] { include(c) }
            include(snapshot.snapped); include(snapshot.destination)
            guard !rect.isNull else { return }
            map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 110, left: 50, bottom: 320, right: 50),
                                  animated: true)
        }

        private func colors(for layer: MapLayer) -> [(UIColor, CGFloat)] {
            switch layer {
            case .crossings:
                return [(UIColor.systemTeal.withAlphaComponent(0.30), 5),
                        (UIColor.systemBlue.withAlphaComponent(0.45), 6),
                        (UIColor.systemBlue.withAlphaComponent(0.80), 7)]
            case .interest:
                return [(UIColor(red: 0.55, green: 0.52, blue: 0.62, alpha: 0.35), 4),
                        (UIColor(red: 0.72, green: 0.42, blue: 0.75, alpha: 0.65), 6),
                        (UIColor(red: 0.93, green: 0.36, blue: 0.72, alpha: 0.95), 8)]
            case .sun:
                return [(UIColor(red: 0.30, green: 0.40, blue: 0.52, alpha: 0.80), 5),
                        (UIColor(red: 0.90, green: 0.84, blue: 0.62, alpha: 0.90), 6),
                        (UIColor(red: 1.00, green: 0.73, blue: 0.13, alpha: 0.97), 7)]
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            let layer = model.snapshot?.layer ?? (model.destination == nil && model.ambient != nil ? .sun : .crossings)
            let palette = colors(for: layer)
            if let lines = overlay as? SunLinesOverlay {
                let r = MKMultiPolylineRenderer(multiPolyline: lines)
                styleAmbient(r, for: overlay, beam: model.beamStrength)
                return r
            }
            if let cells = overlay as? SunCellsOverlay {
                let r = MKMultiPolygonRenderer(multiPolygon: cells)
                styleAmbient(r, for: overlay, beam: model.beamStrength)
                return r
            }
            if let route = overlay as? RouteLine {
                let renderer = MKMultiPolylineRenderer(multiPolyline: route)
                if route.casing {
                    renderer.strokeColor = UIColor.white.withAlphaComponent(0.95)
                    renderer.lineWidth = 12
                } else if let band = route.band {
                    let sunPalette = colors(for: .sun)
                    renderer.strokeColor = SkyPalette.fade(sunPalette[band].0.withAlphaComponent(1), beam: Double(route.beam))
                    renderer.lineWidth = 8
                } else {
                    renderer.strokeColor = UIColor.systemIndigo
                    renderer.lineWidth = 8
                }
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            guard let band = overlay as? CorridorBand else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKMultiPolylineRenderer(multiPolyline: band)
            // Full colour even with a route on top: dimming it read as "washed out" outdoors
            // (2026-10-01 walk); the route stands out by its width and white casing.
            let color = palette[band.band].0
            renderer.strokeColor = layer == .sun ? SkyPalette.fade(color, beam: Double(band.beam)) : color
            renderer.lineWidth = palette[band.band].1
            renderer.lineCap = .round
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            switch annotation {
            case is DestinationAnnotation:
                let id = "dest"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                view.markerTintColor = .systemRed
                view.glyphImage = UIImage(systemName: "flag.fill")
                view.canShowCallout = true
                return view
            case is UserDotAnnotation:
                let id = "user"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                view.image = Coordinator.userDotImage
                view.canShowCallout = true
                return view
            case is CrossingAnnotation:
                let id = "crossing"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                view.image = Coordinator.crossingImage
                view.canShowCallout = false
                return view
            default:
                return nil
            }
        }

        static let userDotImage: UIImage = {
            let size = CGSize(width: 20, height: 20)
            return UIGraphicsImageRenderer(size: size).image { ctx in
                ctx.cgContext.setFillColor(UIColor.white.cgColor)
                ctx.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
                ctx.cgContext.setFillColor(UIColor.systemBlue.cgColor)
                ctx.cgContext.fillEllipse(in: CGRect(x: 3, y: 3, width: 14, height: 14))
            }
        }()

        static let crossingImage: UIImage = {
            let size = CGSize(width: 9, height: 9)
            return UIGraphicsImageRenderer(size: size).image { ctx in
                ctx.cgContext.setFillColor(UIColor.white.cgColor)
                ctx.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
                ctx.cgContext.setFillColor(UIColor.systemGreen.cgColor)
                ctx.cgContext.fillEllipse(in: CGRect(x: 1.5, y: 1.5, width: 6, height: 6))
            }
        }()
    }
}
