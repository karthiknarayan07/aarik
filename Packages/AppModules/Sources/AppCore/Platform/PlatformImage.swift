import CoreGraphics
import SwiftUI

#if os(macOS)
    import AppKit
    public typealias PlatformImage = NSImage
#else
    import UIKit
    public typealias PlatformImage = UIImage
#endif

extension PlatformImage {
    /// An image of the given pixels, shown at 1x.
    public static func make(cgImage: CGImage) -> PlatformImage {
        #if os(macOS)
            NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #else
            UIImage(cgImage: cgImage)
        #endif
    }
}

extension Image {
    public init(platformImage: PlatformImage) {
        #if os(macOS)
            self.init(nsImage: platformImage)
        #else
            self.init(uiImage: platformImage)
        #endif
    }
}
