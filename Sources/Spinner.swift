import AppKit
import QuartzCore

/// The menu bar indicator while sessions work: a pale green wave, and a dark green segment that runs along it from left
/// to right. The wave keeps its wavelength and gets shorter when the number or the bubble needs room in the icon.
///
/// The waves are layers above the image of the button, and Core Animation moves the segment. The window server runs
/// that animation, so the app does no work per frame.
@MainActor
final class Spinner {
	private static let wavelength = 20.0
	private static let amplitude = 5.0
	private static let lineWidth = 2.6
	/// The ends of the wave keep this distance from the edges of the space it has.
	private static let inset = 2.0
	/// One run from left to right in 1.4 s.
	private static let runDuration = 1.4
	private static let color = NSColor.systemGreen

	private let track = CAShapeLayer()
	private let segment = CAShapeLayer()
	private weak var button: NSStatusBarButton?
	/// The size and the end of the current wave, to build its path only when they change.
	private var shownShape: (size: CGSize, end: Double)?

	init(button: NSStatusBarButton) {
		self.button = button
		button.wantsLayer = true
		track.strokeColor = Self.color.withAlphaComponent(0.3).cgColor
		segment.strokeColor = (Self.color.blended(withFraction: 0.35, of: .black) ?? Self.color).cgColor
		segment.strokeEnd = 0
		for layer in [track, segment] {
			layer.fillColor = nil
			layer.lineWidth = Self.lineWidth
			layer.lineCap = .round
			layer.lineJoin = .round
			layer.isHidden = true
			button.layer?.addSublayer(layer)
		}
	}

	/// Shows the wave over the image frame of the button, from its left end to `waveEnd`, or hides it with `nil`.
	func show(waveEnd: Double, over imageFrame: NSRect?) {
		guard let imageFrame else {
			track.isHidden = true
			segment.isHidden = true
			segment.removeAllAnimations()
			shownShape = nil
			return
		}
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		let path = shownShape.map { $0.size == imageFrame.size && $0.end == waveEnd } == true ? nil : Self.wave(to: waveEnd, height: imageFrame.height)
		for layer in [track, segment] {
			layer.bounds = CGRect(origin: .zero, size: imageFrame.size)
			layer.position = CGPoint(x: imageFrame.midX, y: imageFrame.midY)
			layer.contentsScale = button?.window?.backingScaleFactor ?? 2
			if let path { layer.path = path }
			layer.isHidden = false
		}
		shownShape = (imageFrame.size, waveEnd)
		CATransaction.commit()
		guard segment.animation(forKey: "run") == nil else { return }

		// The segment grows from the left end, runs along the wave, and shrinks into the right end.
		let end = CAKeyframeAnimation(keyPath: "strokeEnd")
		end.values = [0, 1, 1]
		end.keyTimes = [0, 0.65, 1]
		let start = CAKeyframeAnimation(keyPath: "strokeStart")
		start.values = [0, 0, 1]
		start.keyTimes = [0, 0.35, 1]
		let run = CAAnimationGroup()
		run.animations = [end, start]
		run.duration = Self.runDuration
		run.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
		run.repeatCount = .infinity
		// 30 frames per second look smooth and keep the work of the window server low.
		if #available(macOS 12, *) {
			run.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
		}
		segment.add(run, forKey: "run")
	}

	/// A sine wave with a fixed wavelength from the left end to `end`, vertically centered.
	private static func wave(to end: Double, height: Double) -> CGPath {
		let path = CGMutablePath()
		let start = inset
		let length = max(end - inset - start, 1)
		let steps = Int(length * 2)
		for step in 0...steps {
			let x = start + length * Double(step) / Double(steps)
			let point = CGPoint(x: x, y: height / 2 + sin((x - start) / wavelength * 2 * .pi) * amplitude)
			if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
		}
		return path
	}

	private static func countLine(_ count: Int, color: NSColor) -> CTLine {
		let text = count > 9 ? "9+" : "\(count)"
		let font = NSFont.monospacedDigitSystemFont(ofSize: count > 9 ? 9 : 12, weight: .bold)
		return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
	}

	/// The visible width of the number that ``drawCount(_:at:color:)`` draws.
	static func countWidth(_ count: Int) -> Double {
		CTLineGetBoundsWithOptions(countLine(count, color: .black), .useGlyphPathBounds).width
	}

	/// Centers the visible outline of the digits. The line box of the text has room for descenders, so centering it
	/// would put the digits too high. The bubble of the waiting sessions uses it too, so both numbers have one size.
	static func drawCount(_ count: Int, at center: NSPoint, color: NSColor = .black) {
		let line = countLine(count, color: color)
		let outline = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
		guard let context = NSGraphicsContext.current?.cgContext else { return }
		context.textPosition = CGPoint(x: center.x - outline.midX, y: center.y - outline.midY)
		CTLineDraw(line, context)
	}
}
