/// A tool as the sidebar shows it. The full Tool contract arrives with the job model.
struct ToolEntry: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let systemImage: String
}

/// The one list of tools.
enum ToolRegistry {
    static let tools: [ToolEntry] = [
        ToolEntry(id: "downscale-video", title: "Downscale Video", systemImage: "arrow.down.right.and.arrow.up.left")
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
