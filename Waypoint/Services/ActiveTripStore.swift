import CoreLocation
import Foundation
import OSLog

/// Keeps the trip in progress on disk so it survives the app going away mid-drive.
///
/// A phone that runs out of memory behind a navigation app, a crash, or a driver who swipes the
/// app away at a set of lights all end the same way today: the route is gone, and getting it back
/// needs signal the car may not have. The route itself is just geometry and a list of turns — a
/// few tens of kilobytes — so there's no good reason for it to only exist in memory.
///
/// This is also the part of "offline navigation" that's actually achievable on MapKit. Apple's map
/// *tiles* can't be pre-downloaded by a third-party app: there's no public API for it, and the
/// data isn't ours to cache. So the honest offline story is that a trip you've already started
/// keeps working — the line, the turns, the distances, the voice — over whatever the map manages
/// to draw, rather than a promise of full offline maps that MapKit can't keep.
///
/// Lives in Application Support rather than Caches: the system is free to evict a cache under
/// storage pressure, and evicting the trip someone is driving is exactly the wrong moment.
@MainActor
final class ActiveTripStore {
    static let shared = ActiveTripStore()

    /// A trip older than this isn't one anybody is still driving.
    nonisolated static let resumeWindow: TimeInterval = 2 * 60 * 60
    /// Writing on every GPS fix would rewrite the whole route several times a second for a number
    /// that only matters if the app dies.
    private static let saveInterval: TimeInterval = 15

    private let url: URL?
    private var lastSave: Date = .distantPast

    private init() {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let directory else {
            url = nil
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("active-trip.json")
    }

    /// The trip in progress, as little of it as is needed to pick it back up.
    struct SavedTrip: Codable {
        struct Point: Codable {
            let latitude: Double
            let longitude: Double

            init(_ coordinate: CLLocationCoordinate2D) {
                latitude = coordinate.latitude
                longitude = coordinate.longitude
            }

            var coordinate: CLLocationCoordinate2D {
                CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            }
        }

        struct Step: Codable {
            let instruction: String
            let distanceMeters: Double
            let start: Point?
            let maneuver: String?
        }

        let destinationName: String
        let destination: Point
        let stops: [Point]
        let coordinates: [Point]
        let steps: [Step]
        let travelTime: TimeInterval
        let distanceMeters: Double
        let summary: String
        let savedAt: Date

        var isResumable: Bool {
            Date().timeIntervalSince(savedAt) < ActiveTripStore.resumeWindow && coordinates.count > 1
        }

        var route: RouteOption {
            RouteOption(
                coordinates: coordinates.map(\.coordinate),
                travelTime: travelTime,
                distanceMeters: distanceMeters,
                summary: summary,
                transitSteps: [],
                steps: steps.map {
                    RouteStep(
                        instruction: $0.instruction,
                        distanceMeters: $0.distanceMeters,
                        startCoordinate: $0.start?.coordinate,
                        maneuver: $0.maneuver
                    )
                }
            )
        }
    }

    /// Writes the trip, at most every few seconds.
    ///
    /// Transit trips aren't saved: their value is in departure times and live arrivals, and
    /// resuming one from twenty minutes ago would put a rider on a train that's long gone. Driving
    /// directions don't go off in the same way — the road is still the road.
    func save(
        route: RouteOption,
        destinationName: String,
        destinationCoordinate: CLLocationCoordinate2D,
        stops: [CLLocationCoordinate2D],
        force: Bool = false
    ) {
        guard route.transitSegments.isEmpty, route.transitSteps.isEmpty else { return }
        guard force || Date().timeIntervalSince(lastSave) >= Self.saveInterval else { return }
        lastSave = Date()

        let trip = SavedTrip(
            destinationName: destinationName,
            destination: .init(destinationCoordinate),
            stops: stops.map(SavedTrip.Point.init),
            coordinates: route.coordinates.map(SavedTrip.Point.init),
            steps: route.steps.map {
                .init(
                    instruction: $0.instruction,
                    distanceMeters: $0.distanceMeters,
                    start: $0.startCoordinate.map(SavedTrip.Point.init),
                    maneuver: $0.maneuver
                )
            },
            travelTime: route.travelTime,
            distanceMeters: route.distanceMeters,
            summary: route.summary,
            savedAt: Date()
        )
        write(trip)
    }

    /// The saved trip, if there is one and it's recent enough to still be the one being driven.
    func resumableTrip() -> SavedTrip? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        guard let trip = try? JSONDecoder().decode(SavedTrip.self, from: data) else {
            clear()
            return nil
        }
        guard trip.isResumable else {
            clear()
            return nil
        }
        return trip
    }

    func clear() {
        lastSave = .distantPast
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func write(_ trip: SavedTrip) {
        guard let url, let data = try? JSONEncoder().encode(trip) else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            Logger.navigation.error("Couldn't save the active trip: \(error.localizedDescription)")
        }
    }
}
