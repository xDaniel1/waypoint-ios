import SwiftUI
import MapKit

struct TestMap: View {
    var body: some View {
        Map {
            Marker("Foo", coordinate: CLLocationCoordinate2D())
                // .clusteringIdentifier is on Marker in iOS 17?
        }
    }
}
