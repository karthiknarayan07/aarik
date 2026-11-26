#if os(macOS)
    import AppKit

    @MainActor
    public final class SystemPasteboard: Pasteboarding {
        public init() {}

        public func copy(text: String) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        public func copy(fileURLs: [URL]) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(fileURLs as [NSURL])
        }
    }
#elseif os(iOS)
    import UIKit

    @MainActor
    public final class SystemPasteboard: Pasteboarding {
        public init() {}

        public func copy(text: String) {
            UIPasteboard.general.string = text
        }

        public func copy(fileURLs: [URL]) {
            UIPasteboard.general.urls = fileURLs
        }
    }
#endif
