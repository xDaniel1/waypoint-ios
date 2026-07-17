import SwiftUI

struct DirectionsCard: View {
    @Bindable var viewModel: DirectionsViewModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Directions")
                        .font(.title2.weight(.semibold))
                    Text(viewModel.destinationTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Picker("Mode", selection: $viewModel.mode) {
                ForEach(DirectionsViewModel.Mode.allCases, id: \.self) { mode in
                    Label(mode.label, systemImage: mode.symbolName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Group {
                if viewModel.isCalculating {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if let distance = viewModel.formattedDistance, let duration = viewModel.formattedDuration {
                    HStack(spacing: 16) {
                        Label(duration, systemImage: "clock.fill")
                            .font(.headline)
                        Label(distance, systemImage: "arrow.left.and.right")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Text("Waypoint shows the calculated route and ETA in-app. Live voice-guided turn-by-turn is a system feature Apple doesn't expose to third-party apps.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }
}
