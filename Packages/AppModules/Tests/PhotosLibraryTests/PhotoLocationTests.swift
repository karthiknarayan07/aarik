import CoreLocation
import Foundation
import Testing

@testable import PhotosLibrary

/// How a location moves between Photos' `CLLocation` and `PhotoLocation`; an unknown altitude stays unknown.
@Suite struct PhotoLocationTests {
    private let date = Date(timeIntervalSince1970: 1_623_758_400)

    @Test func unknownAltitudeIsWrittenAsInvalid() {
        let location = PhotoLocation(latitude: 12.5, longitude: 45.25).clLocation(timestamp: date)
        #expect(location.verticalAccuracy < 0)
        #expect(location.coordinate.latitude == 12.5)
    }

    @Test func knownAltitudeIsWrittenAsValid() {
        let location = PhotoLocation(latitude: 12.5, longitude: 45.25, altitude: 7).clLocation(timestamp: date)
        #expect(location.verticalAccuracy >= 0)
        #expect(location.altitude == 7)
    }

    @Test func readingKeepsUnknownAltitudeUnknown() {
        let unknown = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 1, longitude: 2), altitude: 0, horizontalAccuracy: 0,
            verticalAccuracy: -1, timestamp: date)
        #expect(PhotoKitStore.location(unknown)?.altitude == nil)
        let known = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 1, longitude: 2), altitude: 30, horizontalAccuracy: 0,
            verticalAccuracy: 5, timestamp: date)
        #expect(PhotoKitStore.location(known)?.altitude == 30)
    }
}
