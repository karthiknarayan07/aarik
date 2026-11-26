import XCTest

/// A layout check for UI tests: reads the screen's accessibility snapshot (one query, fast) and fails the test when
/// text or controls overlap each other or hang off the screen. Platform-neutral, so the iOS and Mac UI tests share it.
///
/// What it collects: the static texts, images, buttons and identified other elements under `root` that have a
/// non-empty frame on screen. What it reports:
/// - two text-bearing elements (a label or a value) whose frames intersect by more than 2 x 2 pt while neither
///   contains the other (a button that holds its own label, an icon in a button, a row that holds its texts all nest);
/// - an element that sits partly outside the screen, unless it is inside a scroll view, list or grid, which scrolls.
///
/// Content that scrolls under a bar (a tab bar, the queue accessory, a bottom action bar) is not an overlap: a pair
/// is skipped when exactly one of the two is inside a scroll view.
@MainActor
enum LayoutAudit {
    /// The smallest intersection, in points, that counts as an overlap (both width and height must exceed it).
    static let overlapTolerance: CGFloat = 2

    struct Item {
        let type: XCUIElement.ElementType
        let label: String
        let identifier: String
        let frame: CGRect
        let inScroll: Bool

        var hasText: Bool { !label.isEmpty }
        var name: String {
            let kind = Self.kindName(type)
            let title = label.isEmpty ? "" : " \"\(label.prefix(40))\""
            let id = identifier.isEmpty ? "" : " #\(identifier)"
            return "\(kind)\(title)\(id) \(Self.describe(frame))"
        }

        private static func kindName(_ type: XCUIElement.ElementType) -> String {
            switch type {
            case .staticText: "text"
            case .image: "image"
            case .button: "button"
            case .other: "element"
            default: "type\(type.rawValue)"
            }
        }

        private static func describe(_ rect: CGRect) -> String {
            "(\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height)))"
        }
    }

    static func assertNoOverlaps(in root: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let snapshot: any XCUIElementSnapshot
        do {
            snapshot = try root.snapshot()
        } catch {
            XCTFail("LayoutAudit couldn't read the screen: \(error)", file: file, line: line)
            return
        }
        let screen = screenBounds(fallback: snapshot.frame)
        for problem in findProblems(in: snapshot, screen: screen) {
            XCTFail("Layout: \(problem)", file: file, line: line)
        }
    }

    // MARK: Analysis (pure: it reads a snapshot and a screen rectangle)

    static func findProblems(in snapshot: any XCUIElementSnapshot, screen: CGRect) -> [String] {
        var items: [Item] = []
        collect(snapshot, inScroll: false, into: &items, screen: screen)
        var problems: [String] = []

        for item in items where !item.inScroll && !contains(screen, item.frame) {
            problems.append("\(item.name) is partly outside the screen \(Int(screen.width))x\(Int(screen.height))")
        }

        let texts = items.filter(\.hasText)
        for (index, first) in texts.enumerated() {
            for second in texts[(index + 1)...] where first.inScroll == second.inScroll {
                let overlap = first.frame.intersection(second.frame)
                guard !overlap.isNull, overlap.width > overlapTolerance, overlap.height > overlapTolerance else {
                    continue
                }
                if contains(first.frame, second.frame) || contains(second.frame, first.frame) { continue }
                problems.append(
                    "\(first.name) overlaps \(second.name) by \(Int(overlap.width))x\(Int(overlap.height))")
            }
        }
        return problems
    }

    private static let collected: Set<XCUIElement.ElementType> = [.staticText, .image, .button, .other]
    private static let scrolling: Set<XCUIElement.ElementType> = [
        .scrollView, .table, .collectionView, .webView, .outline,
    ]

    private static func collect(
        _ node: any XCUIElementSnapshot, inScroll: Bool, into items: inout [Item], screen: CGRect
    ) {
        let type = node.elementType
        let frame = node.frame
        let identifier = node.identifier
        let isCandidate =
            collected.contains(type) && (type != .other || !identifier.isEmpty)
            && frame.width > 0 && frame.height > 0 && frame.intersects(screen)
        if isCandidate {
            let label = node.label.isEmpty ? ((node.value as? String) ?? "") : node.label
            items.append(Item(type: type, label: label, identifier: identifier, frame: frame, inScroll: inScroll))
        }
        let nested = inScroll || scrolling.contains(type)
        for child in node.children {
            collect(child, inScroll: nested, into: &items, screen: screen)
        }
    }

    private static func contains(_ outer: CGRect, _ inner: CGRect) -> Bool {
        outer.insetBy(dx: -1, dy: -1).contains(inner)
    }

    /// The visible area: the app's first window (the whole screen on iPhone and iPad), or the snapshot's own frame.
    private static func screenBounds(fallback: CGRect) -> CGRect {
        let window = XCUIApplication().windows.firstMatch
        if window.exists, !window.frame.isEmpty { return window.frame }
        return fallback
    }
}
