#if os(macOS)
    import AppCore
    import SwiftUI

    /// The sidebar: draws whatever sections the hosted tool module lists, through `ToolSidebarModel`.
    public struct MacSidebarView<Module: MacToolScene>: View {
        let module: Module

        public init(module: Module) { self.module = module }

        public var body: some View {
            let sidebar = ToolSidebarModel(module.sidebar)
            let selection = Binding<Module.Destination?> {
                module.selection
            } set: { newValue in
                if sidebar.accepts(newValue) { module.selection = newValue }
            }
            List(selection: selection) {
                ForEach(sidebar.sections) { section in
                    Section(section.title) {
                        ForEach(section.rows) { row in
                            SidebarRow(module: module, row: row)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        }
    }

    private struct SidebarRow<Module: MacToolScene>: View {
        let module: Module
        let row: ToolSidebarModel<Module.Destination>.Row
        var body: some View {
            if let destination = row.item.destination {
                available(destination)
            }
        }

        private func available(_ destination: Module.Destination) -> some View {
            let item = row.item
            return HStack {
                SidebarRowLabel(title: item.title, systemImage: item.systemImage, tint: item.tint)
                if let progress = item.progress {
                    Spacer()
                    ProgressView(value: progress)
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                }
            }
            .badge(item.count ?? 0)
            .tag(destination)
            // The row reads as its title; the count and the running progress are its value.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.accessibilityLabel)
            .accessibilityValue(item.accessibilityValue)
            .modifier(RowContextMenu(module: module, destination: destination))
            .modifier(RowFileDrop(module: module, destination: destination))
        }
    }

    /// The module's context menu for a row, only on the rows that have one.
    private struct RowContextMenu<Module: MacToolScene>: ViewModifier {
        let module: Module
        let destination: Module.Destination

        func body(content: Content) -> some View {
            if module.hasContextMenu(for: destination) {
                content.contextMenu { module.contextMenu(for: destination) }
            } else {
                content
            }
        }
    }

    /// Files dropped on a row, only on the rows that take them.
    private struct RowFileDrop<Module: MacToolScene>: ViewModifier {
        let module: Module
        let destination: Module.Destination

        func body(content: Content) -> some View {
            if module.acceptsFileDrop(on: destination) {
                content.dropDestination(for: URL.self) { urls, _ in
                    let urls = ImportDropGuard.importable(urls, isInternalDragActive: InternalDrag.isActive)
                    return !urls.isEmpty && module.dropFiles(urls, on: destination)
                }
            } else {
                content
            }
        }
    }

    extension SidebarTint {
        /// The system colour for the name, so the symbol follows the appearance and accessibility settings.
        public var color: Color {
            switch self {
            case .blue: .blue
            case .green: .green
            case .orange: .orange
            case .red: .red
            case .purple: .purple
            case .pink: .pink
            case .teal: .teal
            case .indigo: .indigo
            case .yellow: .yellow
            case .gray: .gray
            }
        }
    }

    /// A sidebar row's title with its symbol in the page's colour, hierarchical so it keeps its depth, as in Finder and Mail.
    public struct SidebarRowLabel: View {
        let title: String
        let systemImage: String
        let tint: SidebarTint?

        public init(title: String, systemImage: String, tint: SidebarTint?) {
            self.title = title
            self.systemImage = systemImage
            self.tint = tint
        }

        public var body: some View {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint?.color ?? Color.secondary)
            }
        }
    }
#endif
