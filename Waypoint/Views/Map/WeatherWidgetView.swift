import SwiftUI

struct WeatherWidgetView: View {
    let temperature: String
    let symbolName: String
    var airQualityIndex: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: symbolName)
                    .symbolRenderingMode(.multicolor)
                Text(temperature)
                    .font(.subheadline.weight(.semibold))
            }
            if let airQualityIndex {
                // Apple puts the status dot after the number, not before it.
                HStack(spacing: 4) {
                    Text("AQI \(airQualityIndex)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    Circle()
                        .fill(aqiColor(airQualityIndex))
                        .frame(width: 6, height: 6)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }

    /// Google's universal AQI: 0-50 good, 51-100 moderate, 100+ increasingly unhealthy.
    private func aqiColor(_ aqi: Int) -> Color {
        switch aqi {
        case ..<51: .green
        case 51..<101: .yellow
        case 101..<151: .orange
        default: .red
        }
    }
}
