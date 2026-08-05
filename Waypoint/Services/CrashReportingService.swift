import Foundation
import MetricKit
import Observation

/// Captures on-device crash/hang diagnostics via MetricKit — no third-party SDK, server, or new
/// entitlement required. The tradeoff: Apple typically delivers a `DiagnosticReport` some hours
/// after the fact, not at the very next launch, so this isn't a substitute for real-time crash
/// reporting — it's "the next time the app is opened, eventually you'll see what broke," which
/// is still strictly better than "you won't know unless you notice it yourself."
///
/// `lastRunEndedCleanly` fills the immediacy gap with a much cruder same-session signal: it's
/// available on the very next launch, at the cost of only proving *something* interrupted the
/// previous run (crash, force-quit, or the OS killing it under memory pressure), not what.
///
/// MetricKit's structured `DiagnosticReport`/`MetricManager` API (used here) needs iOS 27; this
/// project's deployment target is iOS 26, so `isDetailedReportingAvailable` reports whether that
/// detail is actually being collected on the current OS. `lastRunEndedCleanly` has no such floor
/// — it's plain `UserDefaults` plumbing — so it still works on 26.
@MainActor
@Observable
final class CrashReportingService {
    struct Report: Identifiable, Codable {
        let id: UUID
        let date: Date
        let kind: Kind
        let summary: String
        let appVersion: String
        let osVersion: String

        enum Kind: String, Codable {
            case crash, hang, cpuException, diskWriteException, memoryException

            var label: String {
                switch self {
                case .crash: "Crash"
                case .hang: "Hang"
                case .cpuException: "CPU Exception"
                case .diskWriteException: "Disk Write Exception"
                case .memoryException: "Memory Exception"
                }
            }

            var symbol: String {
                switch self {
                case .crash: "exclamationmark.triangle.fill"
                case .hang: "hourglass"
                case .cpuException: "cpu"
                case .diskWriteException: "externaldrive.trianglebadge.exclamationmark"
                case .memoryException: "memorychip"
                }
            }
        }
    }

    static let shared = CrashReportingService()

    private(set) var reports: [Report] = []
    /// nil the very first launch ever (nothing to judge yet), then reflects whether
    /// `markCleanShutdown()` got called before this launch started.
    private(set) var lastRunEndedCleanly: Bool?
    private(set) var isDetailedReportingAvailable = false

    private static let cleanShutdownKey = "com.danielguzman.waypoint.diagnostics.cleanShutdown"
    private static let maxStoredReports = 20
    private let reportsFileURL: URL

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        reportsFileURL = documents.appendingPathComponent("crash-reports.json")
        let defaults = UserDefaults.standard
        lastRunEndedCleanly = defaults.object(forKey: Self.cleanShutdownKey) as? Bool
        loadStoredReports()
        // Marked dirty immediately; markCleanShutdown() flips it back once the app actually
        // backgrounds in an orderly way. A crash or force-quit never gets the chance to.
        defaults.set(false, forKey: Self.cleanShutdownKey)

        if #available(iOS 27.0, *) {
            isDetailedReportingAvailable = true
            Task { await self.observeDiagnostics() }
        }
    }

    /// Call when the app backgrounds normally — the closest a SwiftUI app gets to "shutting down
    /// in an orderly fashion," since there's no reliable will-terminate hook to depend on.
    func markCleanShutdown() {
        UserDefaults.standard.set(true, forKey: Self.cleanShutdownKey)
    }

    func clearReports() {
        reports = []
        try? FileManager.default.removeItem(at: reportsFileURL)
    }

    @available(iOS 27.0, *)
    private func observeDiagnostics() async {
        let manager = MetricManager()
        for await report in manager.diagnosticReports {
            guard let mapped = Self.report(from: report) else { continue }
            store(mapped)
        }
    }

    /// Maps to a storable `Report`, or nil for diagnostics that aren't actually a failure —
    /// `.appLaunch` is a slow-launch performance metric, not something worth surfacing in a
    /// crash/hang list; showing it as one would be misleading.
    @available(iOS 27.0, *)
    private static func report(from diagnostic: DiagnosticReport) -> Report? {
        let env = diagnostic.environment
        let appVersion = env.applicationBuildVersion
        let osVersion = env.osVersion.number
        let date = diagnostic.timeRange.end

        let kind: Report.Kind
        let summary: String
        switch diagnostic.result {
        case .crash(let crash):
            kind = .crash
            let type = crash.exceptionType.map(String.init) ?? "?"
            let signal = crash.signal.map(String.init) ?? "?"
            summary = "Exception type \(type), signal \(signal)"
                + (crash.terminationReason.map { " — \($0.rawValue)" } ?? "")
        case .hang(let hang):
            kind = .hang
            summary = "Hung for \(hang.hangDuration.formatted())"
        case .cpuException(let cpuException):
            kind = .cpuException
            summary = "\(cpuException.totalCPUTime.formatted()) CPU over \(cpuException.totalSampledTime.formatted())"
        case .diskWriteException(let diskException):
            kind = .diskWriteException
            summary = "\(diskException.totalBytesWritten.formatted()) written"
        case .memoryException:
            kind = .memoryException
            summary = "Terminated for excessive memory use"
        case .appLaunch:
            return nil
        @unknown default:
            return nil
        }
        return Report(id: UUID(), date: date, kind: kind, summary: summary, appVersion: appVersion, osVersion: osVersion)
    }

    private func loadStoredReports() {
        guard let data = try? Data(contentsOf: reportsFileURL),
              let decoded = try? JSONDecoder().decode([Report].self, from: data) else { return }
        reports = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(reports) else { return }
        try? data.write(to: reportsFileURL, options: .atomic)
    }

    private func store(_ report: Report) {
        reports.insert(report, at: 0)
        if reports.count > Self.maxStoredReports {
            reports.removeLast(reports.count - Self.maxStoredReports)
        }
        persist()
    }
}
