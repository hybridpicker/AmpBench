import AppKit
import SwiftUI

extension View {
    /// Selected rows of the `List` or `Table` this is attached to are tinted amber with a 3 pt amber bar on the left,
    /// instead of the system's blue. Everything else about the list stays the system's: keyboard, VoiceOver,
    /// context menus, multiple selection.
    ///
    ///     Table(rows, selection: $selection) { ... }
    ///         .amberSelection()
    ///
    /// SwiftUI has no way to set the selection color of a list on macOS, so this reaches the `NSTableView` below and
    /// draws the selection itself. It is the one place where the design reaches into AppKit.
    public func amberSelection() -> some View {
        background(AmberSelectionInstaller())
    }
}

private struct AmberSelectionInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> InstallerView { InstallerView() }

    func updateNSView(_ view: InstallerView, context: Context) {
        view.install()
    }
}

final class InstallerView: NSView {
    private weak var table: NSTableView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        install()
    }

    func install() {
        // The table appears a moment after this view, so look again shortly.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.attach() }
        }
    }

    private func attach() {
        guard window != nil else { return }
        let found = table ?? findTable()
        guard let found else { return }
        table = found
        SelectionPainter.attach(to: found)
    }

    /// The table that shares the nearest ancestor with this view.
    private func findTable() -> NSTableView? {
        var ancestor = superview
        while let view = ancestor {
            if let table = Self.firstTable(in: view, skipping: self) { return table }
            ancestor = view.superview
        }
        return nil
    }

    private static func firstTable(in view: NSView, skipping: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews where subview !== skipping {
            if let table = firstTable(in: subview, skipping: skipping) { return table }
        }
        return nil
    }
}

/// Lies beneath the rows of a table and draws its selection in amber.
final class SelectionPainter: NSView {
    private weak var table: NSTableView?
    private var observers: [NSObjectProtocol] = []

    static func attach(to table: NSTableView) {
        if table.selectionHighlightStyle != .none { table.selectionHighlightStyle = .none }
        guard !table.subviews.contains(where: { $0 is SelectionPainter }) else {
            table.subviews.first { $0 is SelectionPainter }?.needsDisplay = true
            return
        }
        let painter = SelectionPainter(frame: table.bounds)
        painter.table = table
        painter.autoresizingMask = [.width, .height]
        table.addSubview(painter, positioned: .below, relativeTo: nil)
        painter.observe()
    }

    private func observe() {
        guard let table else { return }
        let center = NotificationCenter.default
        let redraw: (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let table = self.table else { return }
                // SwiftUI may set its own style again after an update.
                if table.selectionHighlightStyle != .none { table.selectionHighlightStyle = .none }
                self.frame = table.bounds
                self.needsDisplay = true
            }
        }
        observers.append(center.addObserver(forName: NSTableView.selectionDidChangeNotification, object: table,
                                            queue: .main, using: redraw))
        table.postsFrameChangedNotifications = true
        observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: table,
                                            queue: .main, using: redraw))
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let table else { return }
        let appearance = table.effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            let fill = Theme.desk.selection.nsColor
            let bar = Theme.desk.selectionBar.nsColor
            for row in table.selectedRowIndexes {
                let rect = table.rect(ofRow: row).insetBy(dx: table.style == .plain || table.style == .fullWidth ? 0 : 6,
                                                          dy: 0.5)
                guard rect.intersects(dirtyRect) else { continue }
                let shape = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
                fill.setFill()
                shape.fill()
                NSGraphicsContext.saveGraphicsState()
                shape.addClip()
                bar.setFill()
                NSRect(x: rect.minX, y: rect.minY, width: 3, height: rect.height).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }
}
