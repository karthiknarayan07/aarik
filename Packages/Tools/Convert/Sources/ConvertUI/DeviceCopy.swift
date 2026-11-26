import AppCore
import Foundation

#if os(iOS)
    import UIKit
#endif

/// Platform-appropriate nouns for user-facing copy.
enum DeviceCopy {
    @MainActor
    static var thisDevice: String {
        #if os(macOS)
            "this Mac"
        #elseif os(iOS)
            UIDevice.current.userInterfaceIdiom == .pad ? "this iPad" : "this iPhone"
        #else
            "this device"
        #endif
    }

    @MainActor
    static var filesAppLocation: String {
        #if os(iOS)
            let root = UIDevice.current.userInterfaceIdiom == .pad ? "On My iPad" : "On My iPhone"
            return "\(root) › \(AppInfo.displayName)"
        #else
            return AppInfo.displayName
        #endif
    }
}
