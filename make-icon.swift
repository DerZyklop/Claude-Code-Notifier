// Draws the app icon as a 1024 px PNG. Usage: make-icon <output.png>
import AppKit

let size = 1024.0
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

// The macOS icon grid: an 824 px rounded square in the middle, with a soft shadow below it.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowBlurRadius = 28
shadow.set()
NSColor.black.setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

let gradient = NSGradient(colors: [
	NSColor(srgbRed: 0.42, green: 0.55, blue: 1.00, alpha: 1),
	NSColor(srgbRed: 0.33, green: 0.30, blue: 0.86, alpha: 1),
])!

/// The background with a soft light from the top. Also fills the ring around the badge.
func drawBackground(clip: NSBezierPath) {
	NSGraphicsContext.saveGraphicsState()
	clip.addClip()
	gradient.draw(in: shape, angle: -90)
	NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])!
		.draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
	NSGraphicsContext.restoreGraphicsState()
}
drawBackground(clip: shape)

// The bell.
let configuration = NSImage.SymbolConfiguration(pointSize: 480, weight: .regular)
	.applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
let bell = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: nil)!.withSymbolConfiguration(configuration)!
let bellRect = NSRect(x: (size - bell.size.width) / 2, y: (size - bell.size.height) / 2 - 10, width: bell.size.width, height: bell.size.height)
NSGraphicsContext.saveGraphicsState()
let bellShadow = NSShadow()
bellShadow.shadowColor = NSColor(srgbRed: 0.15, green: 0.12, blue: 0.45, alpha: 0.35)
bellShadow.shadowOffset = NSSize(width: 0, height: -10)
bellShadow.shadowBlurRadius = 24
bellShadow.set()
bell.draw(in: bellRect)
NSGraphicsContext.restoreGraphicsState()

// The badge: a warm dot at the top right of the bell, with a ring in the background color.
let badgeCenter = NSPoint(x: bellRect.maxX - 70, y: bellRect.maxY - 70)
let ring = NSBezierPath(ovalIn: NSRect(x: badgeCenter.x - 92, y: badgeCenter.y - 92, width: 184, height: 184))
drawBackground(clip: ring)
let dot = NSBezierPath(ovalIn: NSRect(x: badgeCenter.x - 70, y: badgeCenter.y - 70, width: 140, height: 140))
NSGradient(colors: [
	NSColor(srgbRed: 1.00, green: 0.66, blue: 0.36, alpha: 1),
	NSColor(srgbRed: 0.96, green: 0.45, blue: 0.24, alpha: 1),
])!.draw(in: dot, angle: -90)

NSGraphicsContext.current = nil
try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
