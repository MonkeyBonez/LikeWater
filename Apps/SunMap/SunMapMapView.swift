import SwiftUI
import MapKit
import LikeWaterEngine

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
        }
        if beamChanged {
            for overlay in map.overlays {
                if let r = map.renderer(for: overlay) {
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
        /// Overlays on the map, by score tile.
        var shown: [SunTileKey: SunOverlays.Shown] = [:]

        init(model: SunMapModel) { self.model = model }

        func render(on map: MKMapView, field: SunField?) {
            SunOverlays.sync(map, field: field, shown: &shown)
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
            let renderer: MKOverlayRenderer
            if let lines = overlay as? SunLinesOverlay {
                let r = MKMultiPolylineRenderer(multiPolyline: lines)
                r.lineCap = .round
                renderer = r
            } else if let cells = overlay as? SunCellsOverlay {
                renderer = MKMultiPolygonRenderer(multiPolygon: cells)
            } else {
                return MKOverlayRenderer(overlay: overlay)
            }
            style(renderer, for: overlay, beam: renderedBeam)
            return renderer
        }

        /// The palette under a given beam strength. At 1 it is the clear-sky palette;
        /// as the beam fades, sun and mixed edges fall toward the same flat light as
        /// shade, because under cloud there is no shadow to be on the wrong side of.
        func style(_ renderer: MKOverlayRenderer, for overlay: MKOverlay, beam: Double) {
            if let lines = overlay as? SunLinesOverlay, let r = renderer as? MKMultiPolylineRenderer {
                let palette = SkyPalette.colors(beam: beam)
                switch lines.bucket {
                case .sunny: r.strokeColor = palette.sun; r.lineWidth = 6
                case .mixed: r.strokeColor = palette.mixed; r.lineWidth = 5
                case .shaded: r.strokeColor = palette.shade; r.lineWidth = 5
                }
            } else if let cells = overlay as? SunCellsOverlay, let r = renderer as? MKMultiPolygonRenderer {
                r.fillColor = SkyPalette.cell(fraction: cells.fraction, beam: beam)
                r.strokeColor = nil
                r.lineWidth = 0
            }
        }
    }
}
