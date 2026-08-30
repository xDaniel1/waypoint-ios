import SwiftUI
import MapKit

struct TestMap2: View {
    var body: some View {
        Map {
        }
        .mapControls {
            MapScaleView()
        }
    }
}
