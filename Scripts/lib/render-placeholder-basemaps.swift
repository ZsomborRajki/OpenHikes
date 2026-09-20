//
//  render-placeholder-basemaps.swift
//  Scripts/lib
//
//  The body of `Scripts/placeholder-basemaps.sh`: four MKMapSnapshotter passes
//  over the widget's placeholder route, written into the widget's asset
//  catalogue as data sets plus a Swift manifest.
//
//  It is a near-copy of `TrailBasemapRenderer.renderWithMapKit` and `measure`,
//  and that is deliberate rather than an oversight. The renderer is in the app
//  target, which a command-line tool cannot link; the alternative to this
//  sixty-line copy is moving a MapKit-dependent renderer into the shared
//  package so a development script can reach it, which would put MapKit into
//  the one module the widget extension and the watch both import. What keeps
//  the copy honest is that its *output* is checked: `placeholderBasemapsFrameTheTrail`
//  asserts every point of the real placeholder route lands inside every image
//  this produced, so a copy that has drifted into framing the wrong ground
//  fails a gate rather than shipping a wrong map.
//
//  Runs on macOS, against a macOS snapshotter. The appearance is chosen with
//  `NSAppearance` and the geometry is measured from `snapshot.point(for:)` in
//  whatever coordinate space AppKit reports — `UnitMercatorRect.init(imageWidth:…)`
//  works the origin corner and the y direction out rather than assuming them,
//  which is what makes one measuring step correct on both platforms.
//

import AppKit
import Foundation
import MapKit
import OpenHikesShared

// MARK: Arguments

struct Arguments {
    var assets: URL
    var manifest: URL
    var polyline: [SharedTrailSnapshot.CodableCoordinate]
}

func parseArguments() -> Arguments {
    var assets: String?
    var manifest: String?
    var polyline: [SharedTrailSnapshot.CodableCoordinate] = []
    var pending: String?

    for argument in CommandLine.arguments.dropFirst() {
        if argument.hasPrefix("--") {
            pending = String(argument.dropFirst(2))
            continue
        }
        switch pending {
        case "assets": assets = argument
        case "manifest": manifest = argument
        case "polyline":
            let parts = argument.split(separator: ",")
            guard parts.count == 2,
                  let latitude = Double(parts[0]),
                  let longitude = Double(parts[1])
            else { fail("not a coordinate: \(argument)") }
            polyline.append(.init(latitude: latitude, longitude: longitude))
        default: fail("unexpected argument: \(argument)")
        }
    }

    guard let assets, let manifest, polyline.count > 1 else {
        fail("usage: --assets <dir> --manifest <file> --polyline lat,lon …")
    }
    return Arguments(
        assets: URL(fileURLWithPath: assets),
        manifest: URL(fileURLWithPath: manifest),
        polyline: polyline
    )
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

// MARK: Rendering

/// The `hikeID` the generated manifest carries — see the doc comment it is
/// emitted with. A literal rather than a fresh `UUID()` per run, so a
/// re-render shows only the numbers that moved.
let placeholderHikeID = "72C096C0-D02C-425B-A0AA-906586C4E92A"

/// The scale the renderer's images land on disk at — see
/// `TrailBasemapRenderer.renderScale` for why it is 2 and not the device's own.
let renderScale: CGFloat = 2

/// One finished snapshot: the JPEG, its pixel size, and the patch of Earth it
/// turned out to cover.
struct Rendered {
    var data: Data
    var pixelWidth: Int
    var pixelHeight: Int
    var visibleRect: UnitMercatorRect
}

/// The renderer's own corner bookkeeping — two spellings of one longitude, so
/// a region crossing the antimeridian is asked about inside ±180° and measured
/// as the region names it.
struct Corner {
    var latitude: Double
    var longitude: Double
    var coordinate: CLLocationCoordinate2D

    init(latitude: Double, unitX: Double) {
        self.latitude = latitude
        longitude = Mercator.longitude(unitX: unitX)
        coordinate = CLLocationCoordinate2D(
            latitude: latitude,
            longitude: Mercator.longitude(unitX: Mercator.wrappedUnitX(unitX))
        )
    }
}

@MainActor
func render(
    unitRect: UnitMercatorRect,
    variant: TrailBasemapVariant,
    appearance: TrailBasemapAppearance
) async -> Rendered? {
    let options = MKMapSnapshotter.Options()
    let world = MKMapSize.world.width
    options.mapRect = MKMapRect(
        x: unitRect.originX * world,
        y: unitRect.originY * world,
        width: unitRect.width * world,
        height: unitRect.height * world
    )
    // Twice the variant's point size, which is what `TrailBasemapRenderer`
    // ends up on disk with: it asks for the point size and then resamples to
    // `renderScale`, because MKMapSnapshotter honours neither
    // `traitCollection.displayScale` nor the deprecated `options.scale` and
    // returns the device's own. Asking for the pixels directly is the same
    // picture by a shorter route — the snapshotter is free to adjust the
    // region to suit the size it is given, and the measuring step below reads
    // back whatever it actually covered either way.
    options.size = CGSize(
        width: variant.pointSize.width * renderScale,
        height: variant.pointSize.height * renderScale
    )

    // The renderer's configuration, verbatim: a muted basemap with no points
    // of interest, because someone else's line is drawn over it.
    let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
    configuration.pointOfInterestFilter = .excludingAll
    options.preferredConfiguration = configuration
    options.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)

    let northWest = Corner(
        latitude: Mercator.latitude(unitY: unitRect.originY),
        unitX: unitRect.originX
    )
    let southEast = Corner(
        latitude: Mercator.latitude(unitY: unitRect.originY + unitRect.height),
        unitX: unitRect.originX + unitRect.width
    )

    guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }

    let pointNW = snapshot.point(for: northWest.coordinate)
    let pointSE = snapshot.point(for: southEast.coordinate)
    let size = snapshot.image.size
    guard let visibleRect = UnitMercatorRect(
        imageWidth: Double(size.width),
        imageHeight: Double(size.height),
        .init(
            latitude: northWest.latitude,
            longitude: northWest.longitude,
            x: Double(pointNW.x),
            y: Double(pointNW.y)
        ),
        .init(
            latitude: southEast.latitude,
            longitude: southEast.longitude,
            x: Double(pointSE.x),
            y: Double(pointSE.y)
        )
    ) else { return nil }

    guard let encoded = encode(snapshot.image) else { return nil }
    return Rendered(
        data: encoded.data,
        pixelWidth: encoded.pixelWidth,
        pixelHeight: encoded.pixelHeight,
        visibleRect: visibleRect
    )
}

/// JPEG at the renderer's own quality, for the renderer's own reason: these
/// are photographic-ish raster maps a widget extension decodes inside a hard
/// memory budget.
func encode(_ image: NSImage) -> (data: Data, pixelWidth: Int, pixelHeight: Int)? {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    else { return nil }
    return (data, bitmap.pixelsWide, bitmap.pixelsHigh)
}

// MARK: Writing

func assetName(_ variant: TrailBasemapVariant, _ appearance: TrailBasemapAppearance) -> String {
    "PlaceholderBasemap\(variant.rawValue.capitalized)\(appearance.rawValue.capitalized)"
}

func writeDataSet(_ rendered: Rendered, named name: String, in assets: URL) throws {
    let directory = assets.appendingPathComponent("\(name).dataset", isDirectory: true)
    try? FileManager.default.removeItem(at: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try rendered.data.write(to: directory.appendingPathComponent("\(name).jpg"))
    let contents = """
    {
      "data" : [
        {
          "filename" : "\(name).jpg",
          "idiom" : "universal"
        }
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """
    try Data(contents.utf8).write(to: directory.appendingPathComponent("Contents.json"))
}

func literal(_ value: Double) -> String {
    String(format: "%.12g", value)
}

func manifestSource(_ images: [(TrailBasemap, String)], coverage: UnitMercatorRect) -> String {
    var lines: [String] = []
    for (basemap, name) in images {
        lines += [
            "            TrailBasemap(",
            "                fileName: \"\(name)\",",
            "                variant: .\(basemap.variant.rawValue),",
            "                appearance: .\(basemap.appearance.rawValue),",
            "                pixelWidth: \(basemap.pixelWidth),",
            "                pixelHeight: \(basemap.pixelHeight),",
            "                visibleRect: UnitMercatorRect(",
            "                    originX: \(literal(basemap.visibleRect.originX)),",
            "                    originY: \(literal(basemap.visibleRect.originY)),",
            "                    width: \(literal(basemap.visibleRect.width)),",
            "                    height: \(literal(basemap.visibleRect.height))",
            "                )",
            "            ),",
        ]
    }
    let entries = lines.joined(separator: "\n")

    return """
    //
    //  TrailWidgetPlaceholderBasemaps.swift
    //  OpenWidget
    //
    //  GENERATED by Scripts/placeholder-basemaps.sh — do not edit by hand.
    //
    //  The map the widget gallery and the Xcode previews draw under the
    //  placeholder trail. A real trail's basemaps are rendered by the app into
    //  the App Group; the placeholder is not a real trail, so its four images
    //  are rendered ahead of time and shipped in the widget's asset catalogue
    //  instead. See that script's header, and `TrailWidgetPlaceholder.swift`
    //  for the route these frame.
    //
    //  `fileName` names an `NSDataAsset` here rather than a file in the App
    //  Group's basemap directory, which is the whole of the difference: every
    //  other field means exactly what it means for a rendered set, and
    //  `TrailWidgetBasemapImages` is the reader that tells the two apart.
    //

    import Foundation
    import OpenHikesShared

    enum TrailWidgetPlaceholderBasemaps {
        /// The `hikeID` below. A literal rather than a fresh `UUID()` per run
        /// of the generator, so a re-render is a diff of the numbers that
        /// actually moved.
        private static let hikeID = UUID(
            uuidString: "\(placeholderHikeID)"
        ) ?? UUID()

        /// The set as `TrailMapView` wants it, reading from the widget's asset
        /// catalogue rather than from the App Group.
        ///
        /// Its `hikeID` is never compared against the placeholder snapshot's,
        /// which is a fresh `UUID()` per process. The field exists because a
        /// *rendered* set has to name the trail it frames —
        /// `SharedStore.loadBasemapSet(for:)` refuses one that does not — and
        /// nothing here goes near the store.
        static let set = TrailBasemapSet(
            hikeID: hikeID,
            coverage: UnitMercatorRect(
                originX: \(literal(coverage.originX)),
                originY: \(literal(coverage.originY)),
                width: \(literal(coverage.width)),
                height: \(literal(coverage.height))
            ),
            images: [
    \(entries)
            ]
        )
    }

    """
}

// MARK: Run

let arguments = parseArguments()

guard let coverage = UnitMercatorRect(bounding: arguments.polyline) else {
    fail("the polyline does not bound a region")
}

var images: [(TrailBasemap, String)] = []
for variant in TrailBasemapVariant.allCases {
    let framed = coverage.framed(toAspectRatio: variant.aspectRatio)
    for appearance in TrailBasemapAppearance.allCases {
        guard let rendered = await render(
            unitRect: framed,
            variant: variant,
            appearance: appearance
        ) else {
            fail("the snapshotter refused \(variant.rawValue)/\(appearance.rawValue)")
        }
        let name = assetName(variant, appearance)
        try writeDataSet(rendered, named: name, in: arguments.assets)
        images.append((
            TrailBasemap(
                fileName: name,
                variant: variant,
                appearance: appearance,
                pixelWidth: rendered.pixelWidth,
                pixelHeight: rendered.pixelHeight,
                visibleRect: rendered.visibleRect
            ),
            name
        ))
        print("  \(name)  \(rendered.pixelWidth)×\(rendered.pixelHeight)  \(rendered.data.count / 1024) KB")
    }
}

try Data(manifestSource(images, coverage: coverage).utf8).write(to: arguments.manifest)
