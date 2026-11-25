import AppCore
import DownscaleVideo

/// A tool as the sidebar shows it.
struct ToolEntry: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let systemImage: String

    init(id: String, title: String, systemImage: String) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
    }

    init(_ descriptor: ToolDescriptor) {
        self.init(id: descriptor.id, title: descriptor.name, systemImage: descriptor.symbol)
    }
}

/// The one list of tools.
enum ToolRegistry {
    static let tools: [ToolEntry] = [
        ToolEntry(DownscaleTool.descriptor)
    ]

    /// Shown disabled with a "Soon" label until they ship.
    static let comingSoon: [ToolEntry] = [
        ToolEntry(id: "convert-image", title: "Convert Image", systemImage: "photo"),
        ToolEntry(id: "pdf-tools", title: "PDF Tools", systemImage: "doc.richtext"),
    ]

    static func tool(withID id: String) -> ToolEntry? {
        tools.first { $0.id == id }
    }
}
