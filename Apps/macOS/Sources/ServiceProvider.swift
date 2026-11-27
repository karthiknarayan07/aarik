import AppKit
import QuickRunService

/// The Services menu item "Shrink Videos" (`NSServices` in Info.plist, message `shrinkVideos`). It converts the
/// movies on the service pasteboard in the background, like a Dock drop on a windowless app.
@MainActor
final class ServiceProvider: NSObject {
    private let receive: ([URL]) -> Void

    /// `receive` gets the movies; the delegate holds them until launch finishes when the service started the app.
    init(receive: @escaping ([URL]) -> Void) {
        self.receive = receive
    }

    @objc func shrinkVideos(
        _ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let media = MovieDropFilter.media(on: pasteboard)
        guard !media.isEmpty else {
            error.pointee = "No supported videos or images were selected." as NSString
            return
        }
        receive(media)
    }
}
