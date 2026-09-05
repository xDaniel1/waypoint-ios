import CoreLocation
import MapKit
import SwiftUI

/// The four map modes Apple Maps offers, and what each one actually changes about the map.
///
/// This replaced a loose `MapStyle` plus a separate transit-lines flag. Keeping them apart meant
/// every caller had to remember to set both, and it's why traffic colouring ended up switched on
/// in modes that have nothing to do with driving.
enum MapMode: String, CaseIterable, Identifiable {
    case explore, driving, transit, satellite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .explore: "Explore"
        case .driving: "Driving"
        case .transit: "Transit"
        case .satellite: "Satellite"
        }
    }

    /// MapKit has no transit style, so the subway lines are drawn from bundled MTA geometry over
    /// a standard map. See `MTASubwayLines`.
    var showsTransitLines: Bool { self == .transit }

    var style: MapStyle {
        switch self {
        // `.realistic` is what gives you Apple's 3D buildings and terrain once the map is
        // tilted. On `.flat` the 3D button produced a tilted *flat* map — the perspective
        // changed and nothing stood up — which is why the city never looked like Apple's.
        // MapKit only draws the geometry when the zoom and pitch warrant it, and navigation has
        // been running `.realistic` all along, so this isn't new load.
        case .explore:
            // Traffic off. Congestion colouring is a driving concern, and leaving it on here was
            // painting red over half of Brooklyn while you were only browsing shops.
            .standard(elevation: .realistic, pointsOfInterest: .all, showsTraffic: false)
        case .driving:
            .standard(elevation: .realistic, pointsOfInterest: .all, showsTraffic: true)
        case .transit:
            // The one exception: subway lines are drawn as flat overlays on top of this, and
            // raised buildings push them behind geometry they're meant to sit over.
            .standard(elevation: .flat, pointsOfInterest: .all, showsTraffic: false)
        case .satellite:
            // Apple's "Satellite" keeps road and place labels over the imagery, which is
            // `.hybrid`. Plain `.imagery` drops every label and reads as a different mode.
            .hybrid(elevation: .realistic, showsTraffic: false)
        }
    }
}

/// Apple's "Map Modes" card: a title, a close button, and a row of previews you pick from.
///
/// The previews are drawn rather than live `Map` views, which is what Apple's own tiles are. Live
/// maps were the first attempt and had two problems: MapKit stamps its "Legal" attribution into
/// every map it renders, including a 74pt thumbnail, and four `MKMapView`s is real memory for
/// four postage stamps. Apple's card also carries an OpenStreetMap credit under the tiles; ours
/// doesn't, because we don't use OpenStreetMap and crediting it would be false.
struct MapModesCard: View {
    @Binding var mode: MapMode
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Text("Map Modes")
                    .scaledFont(size: 20, weight: .bold, relativeTo: .title3)
                    .foregroundStyle(.primary)

                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .scaledFont(size: 14, weight: .bold, relativeTo: .subheadline)
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .background(.quaternary, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close map modes")
                }
            }

            // Even widths rather than a fixed tile size: measured off Apple's card, their tiles
            // run ~86pt on a Pro Max, which is exactly what four equal shares of this row come
            // to — and unlike a hardcoded 86 it still fits on a Mini.
            HStack(alignment: .top, spacing: 14) {
                ForEach(MapMode.allCases) { candidate in
                    MapModeTile(mode: candidate, isSelected: candidate == mode) {
                        Haptics.tap()
                        mode = candidate
                        // Apple's card closes the moment you pick, which is the point — you
                        // chose a map so you could look at it. Ours left the card sitting over
                        // the map it had just changed until you found the X.
                        onClose()
                    }
                }
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 20)
    }
}

private struct MapModeTile: View {
    let mode: MapMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                MapModeThumbnail(mode: mode)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.15),
                                    lineWidth: isSelected ? 3 : 1)
                    }

                Text(mode.title)
                    .font(.footnote)
                    // Apple marks the selection with the border alone; the label stays plain.
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mapMode-\(mode.rawValue)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// A small stylised street corner, drawn the way Apple draws theirs: the same blocks and roads in
/// every tile, with only the thing the mode actually changes rendered differently.
private struct MapModeThumbnail: View {
    let mode: MapMode

    @Environment(\.colorScheme) private var colorScheme

    private struct Palette {
        let land: Color, block: Color, road: Color
    }

    private var palette: Palette {
        if mode == .satellite {
            // Imagery has no light/dark variant — a photograph looks the same either way.
            return Palette(
                land: Color(red: 0.19, green: 0.25, blue: 0.15),
                block: Color(red: 0.28, green: 0.32, blue: 0.22),
                road: Color(red: 0.76, green: 0.74, blue: 0.66)
            )
        }
        return colorScheme == .dark
            ? Palette(
                land: Color(red: 0.16, green: 0.20, blue: 0.26),
                block: Color(red: 0.24, green: 0.29, blue: 0.36),
                road: Color(red: 0.60, green: 0.64, blue: 0.70)
              )
            : Palette(
                land: Color(red: 0.89, green: 0.90, blue: 0.92),
                block: Color(red: 0.81, green: 0.83, blue: 0.86),
                road: .white
              )
    }

    /// The main road every tile shares, running lower-left to upper-right.
    private func avenue(_ size: CGSize) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: -0.05 * size.width, y: 0.86 * size.height))
        path.addLine(to: CGPoint(x: 1.05 * size.width, y: 0.16 * size.height))
        return path
    }

    var body: some View {
        ZStack {
            Canvas { context, size in
                let w = size.width, h = size.height
                let palette = palette

                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(palette.land))

                // City blocks either side of the avenue.
                for rect in [
                    CGRect(x: 0.04 * w, y: 0.04 * h, width: 0.30 * w, height: 0.26 * h),
                    CGRect(x: 0.64 * w, y: 0.05 * h, width: 0.31 * w, height: 0.20 * h),
                    CGRect(x: 0.05 * w, y: 0.63 * h, width: 0.25 * w, height: 0.28 * h),
                    CGRect(x: 0.66 * w, y: 0.66 * h, width: 0.29 * w, height: 0.27 * h),
                ] {
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 0.04 * w),
                        with: .color(palette.block)
                    )
                }

                // Cross streets first, so the avenue reads as running over them.
                for (from, to) in [
                    (CGPoint(x: 0.34 * w, y: -0.05 * h), CGPoint(x: 0.52 * w, y: 1.05 * h)),
                    (CGPoint(x: 0.78 * w, y: -0.05 * h), CGPoint(x: 0.94 * w, y: 1.05 * h)),
                ] {
                    var street = Path()
                    street.move(to: from)
                    street.addLine(to: to)
                    context.stroke(street, with: .color(palette.road), lineWidth: 0.07 * w)
                }

                switch mode {
                case .explore, .satellite:
                    context.stroke(avenue(size), with: .color(palette.road), lineWidth: 0.15 * w)
                case .transit:
                    context.stroke(avenue(size), with: .color(palette.road), lineWidth: 0.15 * w)
                case .driving:
                    // The one thing Driving adds: the road painted by how badly it's moving.
                    context.stroke(avenue(size), with: .color(.red), lineWidth: 0.15 * w)
                    var clear = Path()
                    clear.move(to: CGPoint(x: -0.05 * w, y: 0.86 * h))
                    clear.addLine(to: CGPoint(x: 0.34 * w, y: 0.61 * h))
                    context.stroke(clear, with: .color(.yellow), lineWidth: 0.15 * w)
                }

                if mode == .explore {
                    // The dots are the mode: Explore is the one that puts shops, cafes and parks
                    // on the map, so the tile shows them the way Apple's does.
                    let pins: [(CGFloat, CGFloat, Color)] = [
                        (0.17, 0.33, .orange), (0.30, 0.52, .orange), (0.13, 0.72, .red),
                        (0.46, 0.24, .yellow), (0.60, 0.44, .green), (0.80, 0.34, .orange),
                        (0.72, 0.78, .yellow),
                    ]
                    for (x, y, colour) in pins {
                        let r = 0.055 * w
                        let dot = CGRect(x: x * w - r, y: y * h - r, width: r * 2, height: r * 2)
                        context.fill(Path(ellipseIn: dot), with: .color(colour))
                    }
                }

                if mode == .transit {
                    // Real MTA colours rather than decorative ones — the same reds, greens and
                    // oranges the badges and route lines use elsewhere in the app.
                    let services = ["1", "4", "N", "A", "G"]
                    for (index, service) in services.enumerated() {
                        guard let colour = MTASubwayLines.officialColor(forLine: service) else { continue }
                        let offset = (CGFloat(index) - 2) * 0.13 * h
                        var line = Path()
                        line.move(to: CGPoint(x: -0.05 * w, y: 0.72 * h + offset))
                        line.addLine(to: CGPoint(x: 1.05 * w, y: 0.30 * h + offset))
                        context.stroke(line, with: .color(colour), lineWidth: 0.06 * w)
                    }
                }
            }

            if mode == .driving {
                Image(systemName: "exclamationmark.triangle.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.black, .yellow)
                    .symbolRenderingMode(.palette)
                    .frame(width: 22, height: 22)
                    .offset(x: 6, y: 2)
            }
        }
        .drawingGroup()
    }
}
