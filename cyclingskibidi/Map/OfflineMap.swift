//
//  OfflineMap.swift
//  cyclingskibidi
//
//  The app's one map: an MKMapView whose whole base map is our bundled tile
//  pack (scripts/map/tiles.py), so it draws with no connection. SwiftUI's Map
//  can't host a tile overlay, hence the UIKit wrapper. Content is declarative:
//  lines, discs and pins, diffed on update so a ride's per-fix redraw is cheap.
//

import SwiftUI
import MapKit

struct MapLine {
    var coords: [CLLocationCoordinate2D]
    var color: UIColor = .systemBlue
    var width: CGFloat = 6
    var dashed = false
}

struct MapDisc {
    var center: CLLocationCoordinate2D
    var radius: Double
    var color: UIColor
}

struct MapPin: Identifiable {
    enum Look { case marker(symbol: String, tint: UIColor), view(AnyView) }
    let id: String
    var coordinate: CLLocationCoordinate2D
    var title = ""
    var look: Look
    var onTap: (() -> Void)?
}

/// Where the camera should go. A new value (new `token`) is applied once; the
/// rider is free to pan afterwards.
struct MapFocus: Equatable {
    enum Kind { case user(heading: Bool), region(MKCoordinateRegion) }
    var kind: Kind
    var token = UUID()
    static func == (a: MapFocus, b: MapFocus) -> Bool { a.token == b.token }

    static func user(heading: Bool = false) -> MapFocus { MapFocus(kind: .user(heading: heading)) }
    static func region(_ r: MKCoordinateRegion) -> MapFocus { MapFocus(kind: .region(r)) }
    /// Frame a line with a little air round it.
    static func fit(_ coords: [CLLocationCoordinate2D], pad: Double = 1.4, minSpan: Double = 0.005) -> MapFocus? {
        guard let la0 = coords.map(\.latitude).min(), let la1 = coords.map(\.latitude).max(),
              let lo0 = coords.map(\.longitude).min(), let lo1 = coords.map(\.longitude).max() else { return nil }
        return .region(MKCoordinateRegion(
            center: .init(latitude: (la0 + la1) / 2, longitude: (lo0 + lo1) / 2),
            span: .init(latitudeDelta: max((la1 - la0) * pad, minSpan), longitudeDelta: max((lo1 - lo0) * pad, minSpan))))
    }
}

/// Start and end flags for a recorded track.
func endPins(_ coords: [CLLocationCoordinate2D]) -> [MapPin] {
    guard let a = coords.first, let b = coords.last else { return [] }
    return [MapPin(id: "start", coordinate: a, title: "Start", look: .marker(symbol: "flag.fill", tint: .systemGreen)),
            MapPin(id: "end", coordinate: b, title: "End", look: .marker(symbol: "flag.checkered", tint: .systemRed))]
}

struct OfflineMap: UIViewRepresentable {
    var lines: [MapLine] = []
    var discs: [MapDisc] = []
    var pins: [MapPin] = []
    var focus: MapFocus?
    /// Where the map opens, for maps that don't move the camera afterwards.
    var initialRegion: MKCoordinateRegion?
    var showsUser = false
    var showsUserButton = false
    var interactive = true
    var onTap: ((CLLocationCoordinate2D) -> Void)?
    var onRegionChange: ((MKCoordinateRegion) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.addOverlay(OfflineTileOverlay.shared, level: .aboveLabels)
        map.pointOfInterestFilter = .excludingAll
        map.showsCompass = true
        map.isRotateEnabled = true
        map.cameraBoundary = MKMapView.CameraBoundary(coordinateRegion: TilePack.coverage)
        map.cameraZoomRange = MKMapView.CameraZoomRange(minCenterCoordinateDistance: 150, maxCenterCoordinateDistance: 90_000)
        map.setRegion(initialRegion ?? TilePack.coverage, animated: false)
        map.isUserInteractionEnabled = interactive
        map.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:))))

        // ODbL: the map data is OpenStreetMap's, and it says so on the map.
        let credit = UILabel()
        credit.text = " © OpenStreetMap contributors "
        credit.font = .preferredFont(forTextStyle: .caption2)
        credit.adjustsFontForContentSizeCategory = true
        credit.textColor = .label
        credit.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.7)
        credit.layer.cornerRadius = 4
        credit.clipsToBounds = true
        credit.translatesAutoresizingMaskIntoConstraints = false
        map.addSubview(credit)
        NSLayoutConstraint.activate([
            credit.trailingAnchor.constraint(equalTo: map.safeAreaLayoutGuide.trailingAnchor, constant: -6),
            credit.bottomAnchor.constraint(equalTo: map.safeAreaLayoutGuide.bottomAnchor, constant: -4),
        ])
        if showsUserButton {
            let button = MKUserTrackingButton(mapView: map)
            button.backgroundColor = .systemBackground.withAlphaComponent(0.85)
            button.layer.cornerRadius = 8
            button.translatesAutoresizingMaskIntoConstraints = false
            map.addSubview(button)
            NSLayoutConstraint.activate([
                button.trailingAnchor.constraint(equalTo: map.safeAreaLayoutGuide.trailingAnchor, constant: -10),
                button.topAnchor.constraint(equalTo: map.safeAreaLayoutGuide.topAnchor, constant: 10),
            ])
        }
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        c.parent = self
        map.isUserInteractionEnabled = interactive
        if showsUser != map.showsUserLocation {
            if showsUser { c.location.requestWhenInUseAuthorization() }
            map.showsUserLocation = showsUser
        }
        c.sync(lines: lines, discs: discs, on: map)
        c.sync(pins: pins, on: map)
        if let focus, focus != c.applied {
            c.applied = focus
            switch focus.kind {
            case .user(let heading): map.setUserTrackingMode(heading ? .followWithHeading : .follow, animated: true)
            case .region(let r):
                // Before the first layout the map has no size and would fit the region to nothing.
                if map.bounds.isEmpty {
                    DispatchQueue.main.async { map.setRegion(map.regionThatFits(r), animated: false) }
                } else {
                    map.setRegion(map.regionThatFits(r), animated: c.hasAppeared)
                }
            }
        }
        c.hasAppeared = true
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: OfflineMap?
        var applied: MapFocus?
        var hasAppeared = false
        let location = CLLocationManager()
        private var overlaySignature = ""
        private var annotations: [String: PinAnnotation] = [:]

        func sync(lines: [MapLine], discs: [MapDisc], on map: MKMapView) {
            // Re-add overlays only when they really changed: a ride redraws on every fix.
            func key(_ c: CLLocationCoordinate2D?) -> String { c.map { "\($0.latitude),\($0.longitude)" } ?? "-" }
            let sig = lines.map { "\($0.coords.count)|\(key($0.coords.first))|\(key($0.coords.last))|\($0.color)|\($0.width)|\($0.dashed)" }.joined(separator: ";")
                + "#" + discs.map { "\(key($0.center))|\($0.radius)|\($0.color)" }.joined(separator: ";")
            guard sig != overlaySignature else { return }
            overlaySignature = sig
            map.removeOverlays(map.overlays.filter { !($0 is MKTileOverlay) })
            for l in lines where l.coords.count > 1 {
                let p = StyledLine(coordinates: l.coords, count: l.coords.count)
                p.style = l
                map.addOverlay(p, level: .aboveLabels)
            }
            for d in discs {
                let c = StyledDisc(center: d.center, radius: d.radius)
                c.color = d.color
                map.addOverlay(c, level: .aboveLabels)
            }
        }

        func sync(pins: [MapPin], on map: MKMapView) {
            let wanted = Dictionary(pins.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for (id, a) in annotations where wanted[id] == nil {
                map.removeAnnotation(a); annotations[id] = nil
            }
            for pin in pins {
                if let a = annotations[pin.id] {
                    a.pin = pin
                    if a.coordinate.latitude != pin.coordinate.latitude || a.coordinate.longitude != pin.coordinate.longitude {
                        a.coordinate = pin.coordinate
                    }
                    if case .view(let v) = pin.look, let host = map.view(for: a)?.subviews.first?.next as? UIHostingController<AnyView> {
                        host.rootView = v
                    }
                } else {
                    let a = PinAnnotation(pin)
                    annotations[pin.id] = a
                    map.addAnnotation(a)
                }
            }
        }

        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard let map = g.view as? MKMapView, let onTap = parent?.onTap else { return }
            let pt = g.location(in: map)
            // A tap on a pin is the pin's, not the map's.
            if let hit = map.hitTest(pt, with: nil), hit is MKAnnotationView || hit.superview is MKAnnotationView
                || hit.superview?.superview is MKAnnotationView { return }
            onTap(map.convert(pt, toCoordinateFrom: map))
        }

        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let t = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: t) }
            if let l = overlay as? StyledLine {
                let r = MKPolylineRenderer(polyline: l)
                r.strokeColor = l.style.color
                r.lineWidth = l.style.width
                r.lineCap = .round; r.lineJoin = .round
                if l.style.dashed { r.lineDashPattern = [2, 6].map { NSNumber(value: $0 * Double(l.style.width) / 3) } }
                return r
            }
            if let c = overlay as? StyledDisc {
                let r = MKCircleRenderer(circle: c)
                r.fillColor = c.color
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ map: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let a = annotation as? PinAnnotation else { return nil }   // the user dot stays MapKit's
            switch a.pin.look {
            case .marker(let symbol, let tint):
                let v = MKMarkerAnnotationView(annotation: a, reuseIdentifier: nil)
                v.glyphImage = UIImage(systemName: symbol)
                v.markerTintColor = tint
                v.titleVisibility = .hidden
                v.displayPriority = .required
                return v
            case .view(let content):
                let v = MKAnnotationView(annotation: a, reuseIdentifier: nil)
                let host = UIHostingController(rootView: content)
                host.view.backgroundColor = .clear
                let size = host.sizeThatFits(in: CGSize(width: 200, height: 200))
                host.view.frame = CGRect(origin: .zero, size: size)
                v.frame = host.view.frame
                v.addSubview(host.view)
                v.displayPriority = .required
                v.accessibilityLabel = a.pin.title
                objc_setAssociatedObject(v, &hostKey, host, .OBJC_ASSOCIATION_RETAIN)
                return v
            }
        }

        func mapView(_ map: MKMapView, didSelect annotation: MKAnnotation) {
            guard let a = annotation as? PinAnnotation else { return }
            map.deselectAnnotation(a, animated: false)
            a.pin.onTap?()
        }

        func mapView(_ map: MKMapView, regionDidChangeAnimated animated: Bool) {
            parent?.onRegionChange?(map.region)
        }
    }
}

nonisolated(unsafe) private var hostKey: UInt8 = 0

private final class PinAnnotation: NSObject, MKAnnotation {
    var pin: MapPin
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String? { pin.title }
    init(_ pin: MapPin) { self.pin = pin; coordinate = pin.coordinate }
}

private final class StyledLine: MKPolyline { var style = MapLine(coords: []) }
private final class StyledDisc: MKCircle { var color: UIColor = .systemRed }

// MARK: - Bundled tiles

/// The bundled raster tiles: `tiles.pack` is a small index plus the PNGs back
/// to back (format in scripts/map/tiles.py). Deeper zooms crop and scale the
/// deepest bundled tile, so the map never runs out of detail-less blanks.
nonisolated final class TilePack: @unchecked Sendable {
    static let shared = TilePack()
    /// Must match scripts/map/tiles.py.
    static let minZ = 11, maxZ = 16
    static let coverage = MKCoordinateRegion(center: .init(latitude: 1.34, longitude: 103.85),
                                             span: .init(latitudeDelta: 0.28, longitudeDelta: 0.50))

    private let data: Data
    private var index: [UInt64: (offset: Int, length: Int)] = [:]
    private let scaled = NSCache<NSNumber, NSData>()

    init(url: URL? = Bundle.main.url(forResource: "tiles", withExtension: "pack")) {
        data = url.flatMap { try? Data(contentsOf: $0, options: .alwaysMapped) } ?? Data()
        guard data.count >= 8, data.prefix(4) == Data("TPK1".utf8) else { return }
        data.withUnsafeBytes { raw in
            let count = Int(raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian)
            for i in 0..<count {
                let o = 8 + i * 20
                func u32(_ at: Int) -> Int { Int(raw.loadUnaligned(fromByteOffset: o + at, as: UInt32.self).littleEndian) }
                index[Self.key(Int(raw[o]), u32(4), u32(8))] = (u32(12), u32(16))
            }
        }
    }

    var isEmpty: Bool { index.isEmpty }
    var count: Int { index.count }

    private static func key(_ z: Int, _ x: Int, _ y: Int) -> UInt64 { UInt64(z) << 56 | UInt64(x) << 28 | UInt64(y) }

    /// PNG bytes for a tile; the sea tile outside coverage; nil above the shallowest zoom.
    func tile(z: Int, x: Int, y: Int) -> Data? {
        if z > Self.maxZ { return deeper(z: z, x: x, y: y) }
        if let e = index[Self.key(z, x, y)] { return data.subdata(in: e.offset..<e.offset + e.length) }
        return index[Self.key(0, 0, 0)].map { data.subdata(in: $0.offset..<$0.offset + $0.length) }   // sea
    }

    private func deeper(z: Int, x: Int, y: Int) -> Data? {
        let k = NSNumber(value: Self.key(z, x, y))
        if let hit = scaled.object(forKey: k) { return hit as Data }
        let d = z - Self.maxZ, n = 1 << d
        guard let parent = tile(z: Self.maxZ, x: x >> d, y: y >> d), let img = UIImage(data: parent) else { return nil }
        let side = img.size.width / CGFloat(n)
        let crop = CGRect(x: CGFloat(x & (n - 1)) * side, y: CGFloat(y & (n - 1)) * side, width: side, height: side)
        let out = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: {
            let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()).pngData { ctx in
            ctx.cgContext.interpolationQuality = .medium
            img.draw(in: CGRect(x: -crop.minX * CGFloat(n), y: -crop.minY * CGFloat(n),
                                width: img.size.width * CGFloat(n), height: img.size.height * CGFloat(n)))
        }
        scaled.setObject(out as NSData, forKey: k)
        return out
    }

    static func selfCheck() {
        let p = TilePack.shared
        assert(!p.isEmpty, "tiles.pack missing from the bundle")
        // Central Singapore at z14 is bundled; a deeper zoom is scaled from z16; far away is sea.
        let n = 1 << 14
        let x = Int((103.85 + 180) / 360 * Double(n))
        let y = Int((1 - asinh(tan(1.29 * .pi / 180)) / .pi) / 2 * Double(n))
        assert(p.index[key(14, x, y)] != nil, "central Singapore tile missing at z14")
        assert(p.tile(z: 14, x: x, y: y).flatMap(UIImage.init(data:)) != nil, "tile bytes aren't a PNG")
        assert(p.tile(z: 18, x: x << 4, y: y << 4).flatMap(UIImage.init(data:))?.size.width == 256, "overzoom tile wrong")
        assert(p.tile(z: 14, x: 0, y: 0) != nil, "outside coverage must fall back to the sea tile")
    }
}

nonisolated final class OfflineTileOverlay: MKTileOverlay, @unchecked Sendable {
    static let shared = OfflineTileOverlay()
    private init() {
        super.init(urlTemplate: nil)
        canReplaceMapContent = true
        minimumZ = TilePack.minZ
        maximumZ = 20
    }
    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        result(TilePack.shared.tile(z: path.z, x: path.x, y: path.y), nil)
    }
}
