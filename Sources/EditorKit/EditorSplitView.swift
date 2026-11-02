import AppKit

@MainActor final class EditorSplitView: NSSplitView, NSSplitViewDelegate {
    private let sidebar: OutlineSidebar
    private let editor: NSScrollView
    private var preferredSidebarWidth: CGFloat = 200
    private var sidebarVisible = false
    private var arranging = false

    init(sidebar: OutlineSidebar, editor: NSScrollView) {
        self.sidebar = sidebar
        self.editor = editor
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        isVertical = true
        dividerStyle = .thin
        delegate = self
        addSubview(sidebar)
        addSubview(editor)
        sidebar.onVisibilityChanged = { [weak self] visible in self?.setSidebarVisible(visible) }
        resizeSubviews(withOldSize: .zero)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var dividerThickness: CGFloat { sidebarVisible ? super.dividerThickness : 0 }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        arranging = true
        defer { arranging = false }
        super.resizeSubviews(withOldSize: oldSize)
    }

    override func setPosition(_ position: CGFloat, ofDividerAt dividerIndex: Int) {
        if sidebarVisible, !arranging { preferredSidebarWidth = constrainedWidth(position) }
        super.setPosition(position, ofDividerAt: dividerIndex)
    }

    private func setSidebarVisible(_ visible: Bool) {
        guard sidebarVisible != visible else { return }
        sidebarVisible = visible
        resizeSubviews(withOldSize: bounds.size)
        needsDisplay = true
    }

    private func constrainedWidth(_ width: CGFloat) -> CGFloat {
        let maximum = max(0, min(480, bounds.width - dividerThickness - 180))
        return min(maximum, max(min(120, maximum), width))
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        let width = sidebarVisible ? constrainedWidth(preferredSidebarWidth) : 0
        sidebar.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        let start = width + dividerThickness
        editor.frame = NSRect(x: start, y: 0, width: max(0, bounds.width - start), height: bounds.height)
    }

    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let width = constrainedWidth(proposedPosition)
        if !arranging { preferredSidebarWidth = width }
        return width
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        constrainedWidth(0)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        constrainedWidth(bounds.width)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        editor.documentView?.needsLayout = true
    }
}