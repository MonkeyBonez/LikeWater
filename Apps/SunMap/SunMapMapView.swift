import SwiftUI
import MapKit
import LikeWaterEngine

final class SunnyOverlay: MKMultiPolyline {}
final class MixedOverlay: MKMultiPolyline {}
final class ShadedOverlay: MKMultiPolyline {}

struct SunMapMapView: UIViewRepresentable {
    @ObservedObject var model: SunMapModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.pointOfInterestFilter = .excludingAll
        map.isRotateEnabled = false
        context.coordinator.map = map
        let start = model.center ?? SunMapModel.fallbackCenter
        map.setRegion(MKCoordinateRegion(center: start, latitudinalMeters: 900,
                                         longitudinalMeters: 900), animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.model = model
        // The sky changes the palette without changing the geometry, so a beam change
        // restyles the existing renderers; a field change rebuilds the overlays.
        let beam = model.beamStrength
        let beamChanged = abs(context.coordinator.renderedBeam - beam) > 0.02
        context.coordinator.renderedBeam = beam
        if context.coordinator.rendered != model.overlayVersion {
            context.coordinator.rendered = model.overlayVersion
            context.coordinator.render(on: map, field: model.field)
        } else if beamChanged {
            for overlay in map.overlays {
                if let r = map.renderer(for: overlay) as? MKMultiPolylineRenderer {
                    context.coordinator.style(r, for: overlay, beam: beam)
                    r.setNeedsDisplay()
                }
            }
        }
        if context.coordinator.recentered != model.recenterRequest, let center = model.center {
            context.coordinator.recentered = model.recenterRequest
            context.coordinator.programmatic = true
            map.setCenter(center, animated: true)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var model: SunMapModel
        weak var map: MKMapView?
        var rendered = -1
        var renderedBeam = 1.0
        var recentered = 0
        /// The next region change is ours, not the user's.
        var programmatic = false

        init(model: SunMapModel) { self.model = model }

        func render(on map: MKMapView, field: SunField?) {
            map.removeOverlays(map.overlays)
            guard let field else { return }
            var sunny: [MKPolyline] = [], mixed: [MKPolyline] = [], shaded: [MKPolyline] = []
            for edge in field.edges {
                var pair = [edge.a, edge.b]
                let line = MKPolyline(coordinates: &pair, count: 2)
                switch edge.bucket {
                case .sunny: sunny.append(line)
                case .mixed: mixed.append(line)
                case .shaded: shaded.append(line)
                }
            }
            if !shaded.isEmpty { map.addOverlay(ShadedOverlay(shaded), level: .aboveRoads) }
            if !mixed.isEmpty { map.addOverlay(MixedOverlay(mixed), level: .aboveRoads) }
            if !sunny.isEmpty { map.addOverlay(SunnyOverlay(sunny), level: .aboveRoads) }
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            // A pan or pinch in progress means the user is steering; stop following the fix.
            let touching = mapView.subviews.first?.gestureRecognizers?.contains {
                $0.state == .began || $0.state == .changed
            } ?? false
            if touching && !programmatic { model.userMovedMap = true }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            programmatic = false
            model.mapRegionChanged(mapView.region)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let multi = overlay as? MKMultiPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKMultiPolylineRenderer(multiPolyline: multi)
            style(renderer, for: overlay, beam: renderedBeam)
            renderer.lineCap = .round
            return renderer
        }

        /// The palette under a given beam strength. At 1 it is the clear-sky palette;
        /// as the beam fades, sun and mixed edges fall toward the same flat light as
        /// shade, because under cloud there is no shadow to be on the wrong side of.
        func style(_ renderer: MKMultiPolylineRenderer, for overlay: MKOverlay, beam: Double) {
            let palette = SkyPalette.colors(beam: beam)
            switch overlay {
            case is SunnyOverlay:
                renderer.strokeColor = palette.sun
                renderer.lineWidth = 6
            case is MixedOverlay:
                renderer.strokeColor = palette.mixed
                renderer.lineWidth = 5
            case is ShadedOverlay:
                renderer.strokeColor = palette.shade
                renderer.lineWidth = 5
            default:
                break
            }
        }
    }
}
