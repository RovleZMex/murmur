import AppKit

/// Murmur's mark (three rounded bars) as a template image for the menu bar.
enum MenuBarIcon {
    static let image: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            // (x, height) in an 18×18 box, bars centered vertically
            for (x, h) in [(3.5, 6.0), (7.75, 13.0), (12.0, 8.5)] as [(CGFloat, CGFloat)] {
                let r = NSRect(x: x, y: (18 - h) / 2, width: 2.5, height: h)
                NSBezierPath(roundedRect: r, xRadius: 1.25, yRadius: 1.25).fill()
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Murmur"
        return img
    }()
}
