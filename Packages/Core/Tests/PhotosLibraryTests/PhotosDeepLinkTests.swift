import Foundation
import Testing

@testable import PhotosLibrary

@Suite struct PhotosDeepLinkTests {
    @Test func buildsTheAssetAddressFromALocalIdentifier() {
        let uuid = "B84E8479-475C-4727-A4A4-B77AA9980897"
        let url = PhotosDeepLink.assetURL(localIdentifier: "\(uuid)/L0/001")
        #expect(url?.absoluteString == "photos://asset?uuid=\(uuid)")
    }

    @Test func aBareUUIDWorksToo() {
        let uuid = "B84E8479-475C-4727-A4A4-B77AA9980897"
        #expect(PhotosDeepLink.assetURL(localIdentifier: uuid)?.absoluteString == "photos://asset?uuid=\(uuid)")
    }

    @Test func anIdentifierThatIsNotAUUIDHasNoAddress() {
        #expect(PhotosDeepLink.assetURL(localIdentifier: "not-a-uuid/L0/001") == nil)
        #expect(PhotosDeepLink.assetURL(localIdentifier: "") == nil)
        #expect(PhotosDeepLink.assetURL(localIdentifier: "../../etc?x=1") == nil)
    }
}
