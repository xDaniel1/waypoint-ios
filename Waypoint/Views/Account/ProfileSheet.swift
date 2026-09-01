import AuthenticationServices
import GoogleSignInSwift
import SwiftUI

/// The account sheet: sign in with Apple, see who's signed in and whether sync is working, or
/// sign out. Diagnostics share this sheet because there's nowhere else in the app a user would
/// think to look for either one.
struct ProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    var coordinator: SyncCoordinator

    private let diagnostics = CrashReportingService.shared

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    var body: some View {
        NavigationStack {
            List {
                accountSection
                diagnosticsSection

                Section {
                    Text("Waypoint v\(appVersion)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .listRowSeparator(.hidden)
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var accountSection: some View {
        if let account = coordinator.account {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.displayName ?? account.provider.label)
                            .font(.headline)
                        Text(account.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)

                syncStatusRow

                Button("Sign Out", role: .destructive) { coordinator.signOut() }
            } footer: {
                if !coordinator.isBackendConfigured {
                    Text("Signed in on this device only — Waypoint has no server configured yet, so this account isn't syncing Favorites or Recents anywhere. They still sync between your own Apple devices via iCloud.")
                }
            }
        } else {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.secondary)
                    Text("Sign in to sync")
                        .font(.headline)
                    Text("Favorites and Recents already sync across your own Apple devices via iCloud. Signing in additionally backs them up to your account.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    SignInWithAppleButton(.signIn) { request in
                        request.requestedScopes = [.fullName, .email]
                    } onCompletion: { result in
                        switch result {
                        case .success(let authorization):
                            Task { await coordinator.signIn(with: authorization) }
                        case .failure(let error):
                            // The user canceled, or Apple's own sheet failed outright and already
                            // told them — nothing left for this screen to say.
                            print("Sign in with Apple failed: \(error.localizedDescription)")
                        }
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 44)
                    .padding(.top, 4)

                    GoogleSignInButton(scheme: .dark, style: .wide) {
                        guard let presenter = topViewController() else { return }
                        Task { await coordinator.signInWithGoogle(presenting: presenter) }
                    }
                    .frame(height: 44)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowSeparator(.hidden)
            }
        }
    }

    /// `GIDSignIn` needs a `UIViewController` to present its sheet from — SwiftUI has no direct
    /// equivalent, so this reaches into the key window the same way `UIApplication` itself would.
    private func topViewController() -> UIViewController? {
        guard
            let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
            let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController
        else { return nil }
        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }

    @ViewBuilder
    private var syncStatusRow: some View {
        switch coordinator.status {
        case .idle:
            Label("Synced", systemImage: "checkmark.icloud")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .syncing:
            Label("Syncing…", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.icloud")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private var diagnosticsSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: lastRunSymbol)
                    .foregroundStyle(lastRunTint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last Session").font(.subheadline.weight(.medium))
                    Text(lastRunDescription).font(.caption).foregroundStyle(.secondary)
                }
            }

            if diagnostics.reports.isEmpty {
                Text("No crash or hang reports recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(diagnostics.reports) { report in
                    HStack(spacing: 10) {
                        Image(systemName: report.kind.symbol).foregroundStyle(.red).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(report.kind.label).font(.subheadline.weight(.medium))
                            Text(report.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text("\(report.date.formatted(date: .abbreviated, time: .shortened)) · v\(report.appVersion) · iOS \(report.osVersion)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Button("Clear Reports", role: .destructive) { diagnostics.clearReports() }
                    .font(.caption)
            }

            if !diagnostics.isDetailedReportingAvailable {
                Text("Detailed crash/hang diagnostics need iOS 27 or later. The last-session status above still works on this OS version.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Collected on-device via MetricKit — nothing is sent off this phone.")
        }
    }

    private var lastRunSymbol: String {
        switch diagnostics.lastRunEndedCleanly {
        case .some(true): "checkmark.circle.fill"
        case .some(false): "exclamationmark.triangle.fill"
        case nil: "questionmark.circle"
        }
    }

    private var lastRunTint: Color {
        switch diagnostics.lastRunEndedCleanly {
        case .some(true): .green
        case .some(false): .orange
        case nil: .secondary
        }
    }

    private var lastRunDescription: String {
        switch diagnostics.lastRunEndedCleanly {
        case .some(true): "Ended normally"
        case .some(false): "Didn't shut down normally — may have crashed or been force-quit"
        case nil: "Not enough history yet"
        }
    }
}
