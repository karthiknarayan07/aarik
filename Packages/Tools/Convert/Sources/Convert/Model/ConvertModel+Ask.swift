import AppUI
import Assistant
import Foundation
import LocalLibrary

extension ChatContext {
    /// What the model is told about a video chosen with Ask About This…: its name and the facts the grid shows. Never
    /// the file's folder or a Photos identifier.
    public init(video item: LibraryItem, calendar: Calendar = .current) {
        var facts: [String] = [ByteFormat.string(item.byteSize)]
        let width = Int(item.pixelSize.width)
        let height = Int(item.pixelSize.height)
        if width > 0, height > 0 { facts.append("\(width)×\(height)") }
        if item.frameRate > 0 { facts.append("\(Int(item.frameRate.rounded())) fps") }
        if item.duration > 0 { facts.append("\(Int(item.duration.rounded())) seconds long") }
        if let date = item.captureDate {
            facts.append("recorded \(date.formatted(.dateTime.day().month(.wide).year()))")
        }
        let badges = MediaBadge.ordered(item.badges).map(\.displayName)
        if !badges.isEmpty { facts.append(badges.joined(separator: ", ")) }
        facts.append(item.photosIdentifier != nil ? "in the Photos library" : "a local file")
        self.init(title: item.name, details: "It is " + facts.joined(separator: "; ") + ".")
    }
}

extension ConvertModel {
    /// Whether Ask can be used: the signal the sidebar and the menus read.
    public var isAskAvailable: Bool { services.assistantAvailability.isAvailable }

    /// File → New Chat: an empty chat on the Ask page.
    public func startNewChat() {
        services.assistantChat.newChat()
        selection = .ask
    }

    /// "Ask About This…" on a video: a fresh chat on the Ask page that knows which video it is about. Does nothing
    /// to the video.
    public func askAbout(_ item: LibraryItem) {
        guard isAskAvailable else { return }
        let chat = services.assistantChat
        chat.newChat()
        chat.setContext(ChatContext(video: item))
        selection = .ask
    }
}
