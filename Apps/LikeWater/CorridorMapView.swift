import SwiftUI
import MapKit
import LikeWaterEngine

final class CorridorBand0: MKMultiPolyline {}
final class CorridorBand1: MKMultiPolyline {}
final class CorridorBand2: MKMultiPolyline {}

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
            if model.snapshot == nil, model.destination == nil, let field = model.ambient {
                context.coordinator.renderAmbient(on: map, field: field)
            } else {
                context.coordinator.render(on: map, snapshot: model.snapshot)
            }
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
            map.removeOverlays(map.overlays)
            map.removeAnnotations(map.annotations)
            guard let snapshot else { return }

            var bands: [[MKPolyline]] = [[], [], []]
            for edge in snapshot.edges {
                var pair = [edge.a, edge.b]
                bands[band(for: edge, snapshot: snapshot)].append(MKPolyline(coordinates: &pair, count: 2))
            }
            if !bands[0].isEmpty { map.addOverlay(CorridorBand0(bands[0]), level: .aboveRoads) }
            if !bands[1].isEmpty { map.addOverlay(CorridorBand1(bands[1]), level: .aboveRoads) }
            if !bands[2].isEmpty { map.addOverlay(CorridorBand2(bands[2]), level: .aboveRoads) }

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

        /// The sun around the map centre, before there is a walk: same three bands as the
        /// corridor's sun layer, so the colours mean the same thing in both states.
        func renderAmbient(on map: MKMapView, field: SunField) {
            map.removeOverlays(map.overlays)
            map.removeAnnotations(map.annotations)
            var bands: [[MKPolyline]] = [[], [], []]
            for edge in field.edges {
                var pair = [edge.a, edge.b]
                bands[edge.bucket.rawValue].append(MKPolyline(coordinates: &pair, count: 2))
            }
            if !bands[0].isEmpty { map.addOverlay(CorridorBand0(bands[0]), level: .aboveRoads) }
            if !bands[1].isEmpty { map.addOverlay(CorridorBand1(bands[1]), level: .aboveRoads) }
            if !bands[2].isEmpty { map.addOverlay(CorridorBand2(bands[2]), level: .aboveRoads) }
            if let user = model.effectiveUserCoordinate {
                let dot = UserDotAnnotation(); dot.coordinate = user; dot.title = "You"
                map.addAnnotation(dot)
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
            let index: Int
            switch overlay {
            case is CorridorBand0: index = 0
            case is CorridorBand1: index = 1
            case is CorridorBand2: index = 2
            default: return MKOverlayRenderer(overlay: overlay)
            }
            guard let multi = overlay as? MKMultiPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKMultiPolylineRenderer(multiPolyline: multi)
            renderer.strokeColor = layer == .sun ? SkyPalette.fade(palette[index].0, beam: model.beamStrength)
                                                 : palette[index].0
            renderer.lineWidth = palette[index].1
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
