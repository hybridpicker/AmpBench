import AppKit

/// A picture of an app's own window for checking the design, without screen recording permission and without ever
/// seeing anything but that window. The window's background is painted first, because `cacheDisplay` leaves it
/// transparent. AppKit controls drawn by layers, such as pop-up buttons, and translucent materials are missing from
/// these pictures; they look right in the app.
@MainActor
public enum WindowPicture {
    public static func png(of view: NSView) -> Data? {
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: representation)
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
        NSGraphicsContext.restoreGraphicsState()
        return canvas.representation(using: .png, properties: [:])
    }
}
