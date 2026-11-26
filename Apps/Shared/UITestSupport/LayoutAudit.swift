import XCTest

/// Finds layout mistakes a person sees at once and a test of "is it there?" doesn't: text drawn over other text, and
/// elements hanging out of the window. It reads the accessibility tree of one element in a single snapshot (one round
/// trip to the app, not one per element), so it is cheap enough to run on every page at every size.
///
/// Shared by the Mac and iOS UI tests (it is compiled into both targets), so it knows nothing about either app.
///
///     LayoutAudit.assertNoOverlaps(in: app.windows.firstMatch)
enum LayoutAudit {
    /// What counts as an overlap: more than this much, in points, in both directions.
    static let tolerance: CGFloat = 2

    /// One element of the tree, flattened.
    struct Item {
        let type: XCUIElement.ElementType
        let identifier: String
        let label: String
        let frame: CGRect
        /// Indices of the ancestors in the flattened list, nearest last.
        let ancestors: [Int]
        let isInScrollView: Bool

        var hasText: Bool { !label.isEmpty }

        var name: String {
            let kind = LayoutAudit.typeName(type)
            let words = [label.isEmpty ? nil : "\"\(label.prefix(60))\"", identifier.isEmpty ? nil : "#\(identifier)"]
                .compactMap { $0 }.joined(separator: " ")
            let box = frame.integral
            return "\(kind) \(words) at (\(Int(box.minX)), \(Int(box.minY)), \(Int(box.width))×\(Int(box.height)))"
        }
    }

    /// Fails, naming both elements, when two text-bearing frames under `root` intersect by more than 2×2 points and
    /// neither contains the other, or when an element sits partly outside the window (an element inside a scroll view
    /// may: that is what scrolling is).
    ///
    /// It looks at the visible static texts, images, buttons and identified other elements, with these exceptions:
    /// an element and its own ancestors or descendants are never compared (a container is meant to hold its parts),
    /// and the window itself, scroll views and scroll bars are the frame, not content.
    @MainActor static func assertNoOverlaps(
        in root: XCUIElement, file: StaticString = #filePath, line: UInt = #line
    ) {
        let snapshot: any XCUIElementSnapshot
        do {
            snapshot = try root.snapshot()
        } catch {
            XCTFail("LayoutAudit couldn't read \(root): \(error)", file: file, line: line)
            return
        }
        let (items, window) = collect(snapshot)
        for problem in problems(in: items, window: window) {
            XCTFail(problem, file: file, line: line)
        }
    }

    // MARK: Reading the tree

    /// The audited elements, and the window's frame: the nearest window above them, or `root`'s own frame.
    static func collect(_ snapshot: any XCUIElementSnapshot) -> (items: [Item], window: CGRect) {
        var items: [Item] = []
        var window = snapshot.frame
        var foundWindow = false
        func visit(
            _ node: any XCUIElementSnapshot, ancestors: [Int], inScroll: Bool
        ) {
            var chain = ancestors
            var scrolled = inScroll
            if node.elementType == .window, !foundWindow {
                window = node.frame
                foundWindow = true
            }
            let isScroll = node.elementType == .scrollView || node.elementType == .scrollBar
            if isScroll { scrolled = true }
            if isAudited(node) {
                items.append(
                    Item(
                        type: node.elementType, identifier: node.identifier, label: text(of: node),
                        frame: node.frame, ancestors: ancestors, isInScrollView: inScroll))
                chain.append(items.count - 1)
            }
            for child in node.children {
                visit(child, ancestors: chain, inScroll: scrolled)
            }
        }
        visit(snapshot, ancestors: [], inScroll: false)
        return (items, window)
    }

    private static func isAudited(_ node: any XCUIElementSnapshot) -> Bool {
        let frame = node.frame
        guard frame.width > 0, frame.height > 0, !frame.isNull, !frame.isInfinite else { return false }
        switch node.elementType {
        case .staticText, .image, .button, .link, .checkBox, .radioButton, .popUpButton, .menuButton, .slider,
            .textField, .searchField, .secureTextField, .textView, .progressIndicator, .levelIndicator:
            return true
        case .other, .group:
            return !node.identifier.isEmpty
        default:
            return false
        }
    }

    /// What is written on an element: its label, else its title, else its text value.
    private static func text(of node: any XCUIElementSnapshot) -> String {
        if !node.label.isEmpty { return node.label }
        if !node.title.isEmpty { return node.title }
        if node.elementType == .staticText || node.elementType == .textField, let value = node.value as? String {
            return value
        }
        return ""
    }

    // MARK: Checks

    static func problems(in items: [Item], window: CGRect) -> [String] {
        var found: [String] = []
        let visible = items.indices.filter { items[$0].frame.intersects(window) }
        for (position, i) in visible.enumerated() {
            let a = items[i]
            if !a.isInScrollView, !contains(window.insetBy(dx: -tolerance, dy: -tolerance), a.frame) {
                found.append("\(a.name) sits partly outside the window \(window.integral)")
            }
            guard a.hasText else { continue }
            for j in visible[(position + 1)...] {
                let b = items[j]
                guard b.hasText, !a.ancestors.contains(j), !b.ancestors.contains(i) else { continue }
                if overlaps(a.frame, b.frame) {
                    found.append("\(a.name) overlaps \(b.name)")
                }
            }
        }
        return found
    }

    /// Whether the frames share more than `tolerance` points in both directions without one holding the other.
    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let shared = a.intersection(b)
        guard !shared.isNull, shared.width > tolerance, shared.height > tolerance else { return false }
        return !contains(a, b) && !contains(b, a)
    }

    /// Whether `outer` holds `inner`, give or take a point (frames are rounded differently by different layers).
    private static func contains(_ outer: CGRect, _ inner: CGRect) -> Bool {
        outer.insetBy(dx: -1, dy: -1).contains(inner)
    }

    static func typeName(_ type: XCUIElement.ElementType) -> String {
        switch type {
        case .staticText: "text"
        case .image: "image"
        case .button: "button"
        case .other: "element"
        case .group: "group"
        default: "element(\(type.rawValue))"
        }
    }
}
