#if os(macOS)
import AppKit

/// A picture of an app's own window for checking the design, without screen recording permission and without ever
/// seeing anything but that window. The window's background is painted first, because `cacheDisplay` leaves it
/// transparent. AppKit controls drawn by layers, such as pop-up buttons, and translucent materials are missing from
/// these pictures; they look right in the app.
@MainActor
public enum WindowPicture {
    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        if let scroll = view as? NSScrollView, scroll.documentView is NSTableView { return [scroll] }
        return view.subviews.flatMap(scrollViews)
    }

    private static func effectViews(in view: NSView) -> [NSVisualEffectView] {
        ((view as? NSVisualEffectView).map { [$0] } ?? []) + view.subviews.flatMap(effectViews)
    }

    public static func png(of view: NSView) -> Data? {
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        // Materials draw their content through the window server, which a cached picture never sees. For the
        // moment of the picture they become plain backgrounds.
        let materials = effectViews(in: view)
        let saved = materials.map { ($0.state, $0.blendingMode, $0.material) }
        for material in materials {
            material.state = .inactive
            material.blendingMode = .withinWindow
            material.material = .windowBackground
        }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        view.cacheDisplay(in: view.bounds, to: representation)
        for (material, value) in zip(materials, saved) {
            material.state = value.0
            material.blendingMode = value.1
            material.material = value.2
        }
        let size = representation.size
        guard let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: representation.pixelsWide,
                                            pixelsHigh: representation.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        canvas.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: size).fill()
        }
        representation.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1,
                            respectFlipped: true, hints: nil)
        // A sidebar list lies in glass or a material that the cached picture of the whole window leaves out, but it
        // draws itself when asked alone. Every list is drawn again at its place.
        do {
            for scroll in scrollViews(in: view) where scroll.window != nil && !scroll.isHiddenOrHasHiddenAncestor {
                guard let part = scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds) else { continue }
                scroll.cacheDisplay(in: scroll.bounds, to: part)
                var rect = scroll.convert(scroll.bounds, to: view)
                if view.isFlipped { rect.origin.y = size.height - rect.maxY }
                scroll.effectiveAppearance.performAsCurrentDrawingAppearance {
                    NSColor.controlBackgroundColor.setFill()
                    rect.fill()
                }
                part.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return canvas.representation(using: .png, properties: [:])
    }
}
#endif
