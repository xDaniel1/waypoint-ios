import Foundation

/// Shared, pre-configured formatters.
///
/// Creating a `DateFormatter` is the expensive part, not using one — measured at 0.128ms to
/// allocate-and-parse an ISO8601 string versus 0.047ms to parse with an existing formatter, so
/// roughly 2.8x. That doesn't matter once, but these are called from view bodies: every transit
/// leg's departure and arrival time, every route card's duration and ETA. A transit itinerary
/// re-rendering mid-scroll was paying it per row per frame.
///
/// `nonisolated(unsafe)` is deliberate and safe here. Apple documents these formatters as safe to
/// *use* from multiple threads once configured; only mutating one concurrently is not. Nothing
/// below is ever mutated after this file finishes setting it up, which is also why the two
/// duration formatters exist separately rather than one whose `allowedUnits` gets reassigned.
enum Formatters {
    /// Google's transit timestamps.
    nonisolated(unsafe) static let iso8601 = ISO8601DateFormatter()

    /// The MTA's bus feed stamps some times with fractional seconds and some without.
    nonisolated(unsafe) static let iso8601FractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Locale-aware clock time — "7:49 PM", or "19:49" where that's the convention.
    nonisolated(unsafe) static let clockTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    /// The bare "7:49" on the route card, which deliberately drops the AM/PM the way Apple's
    /// arrival time does. Fixed pattern rather than a locale style, as it was before.
    nonisolated(unsafe) static let bareClockTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"
        return formatter
    }()

    /// "1 hr 12 min" — for trips of an hour or more.
    nonisolated(unsafe) static let hoursAndMinutes: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.hour, .minute]
        return formatter
    }()

    /// "12 min" — for anything under an hour.
    nonisolated(unsafe) static let minutesOnly: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.minute]
        return formatter
    }()
}
