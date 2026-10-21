import AppKit
import QuartzCore

/// The wave of the menu bar icon, as three layers on the same curve above the image of the button.
///
/// - The still wave in the menu bar color, while no session works.
/// - A pale green wave, while sessions work.
/// - A dark green segment that runs along the pale green wave from left to right.
///
/// When work starts, the green wave grows in from the left and the still wave shrinks back at the same point. When
/// work ends, the green wave leaves to the right and the still wave grows back. The wave keeps its wavelength and gets
/// shorter when the number or the bubble needs room in the icon. Core Animation runs all of it in the window server,
/// so the app does no work per frame.
@MainActor
final class Spinner {
	private static let wavelength = 20.0
	private static let amplitude = 2.5
	static let lineWidth = 2.6
	/// The ends of the wave keep this distance from the edges of the space it has.
	private static let inset = 2.0
	/// The gap in the middle of the still wave for a setup problem.
	private static let gapWidth = 6.0
	/// One run of the segment from left to right.
	private static let runDuration = 1.4
	/// The change between the still and the green wave.
	private static let swapDuration = 0.6
	private static let color = NSColor.systemGreen

	private let still = CAShapeLayer()
	private let track = CAShapeLayer()
	private let segment = CAShapeLayer()
	private weak var button: NSStatusBarButton?
	/// The shape of the shown waves, to build their paths only when it changes.
	private var shownShape: (size: CGSize, end: Double, hasGap: Bool)?
	private var isWorking = false

	init(button: NSStatusBarButton) {
		self.button = button
		button.wantsLayer = true
		track.strokeColor = Self.color.withAlphaComponent(0.3).cgColor
		track.strokeEnd = 0
		segment.strokeColor = (Self.color.blended(withFraction: 0.35, of: .black) ?? Self.color).cgColor
		segment.strokeEnd = 0
		for layer in [still, track, segment] {
			layer.fillColor = nil
			layer.lineWidth = Self.lineWidth
			layer.lineCap = .round
			layer.lineJoin = .round
			layer.isHidden = true
			button.layer?.addSublayer(layer)
		}
	}

	/// Shows the waves over the image frame of the button, from its left end to `waveEnd`.
	/// - Parameters:
	///   - hasGap: Breaks the still wave in the middle, for a setup problem.
	///   - stillColor: The menu bar color for the still wave.
	func show(waveEnd: Double, over imageFrame: NSRect?, isWorking: Bool, hasGap: Bool, stillColor: NSColor) {
		guard let imageFrame else {
			for layer in [still, track, segment] { layer.isHidden = true }
			return
		}
		let yAxisDown = button?.isFlipped ?? false
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		if shownShape.map({ $0.size == imageFrame.size && $0.end == waveEnd && $0.hasGap == hasGap }) != true {
			let wave = Self.wave(to: waveEnd, height: imageFrame.height, yAxisDown: yAxisDown)
			still.path = hasGap ? Self.wave(to: waveEnd, height: imageFrame.height, yAxisDown: yAxisDown, gap: true) : wave
			track.path = wave
			segment.path = wave
			shownShape = (imageFrame.size, waveEnd, hasGap)
		}
		for layer in [still, track, segment] {
			layer.bounds = CGRect(origin: .zero, size: imageFrame.size)
			layer.position = CGPoint(x: imageFrame.midX, y: imageFrame.midY)
			layer.contentsScale = button?.window?.backingScaleFactor ?? 2
			layer.isHidden = false
		}
		still.strokeColor = stillColor.cgColor
		CATransaction.commit()

		guard isWorking != self.isWorking else { return }
		self.isWorking = isWorking
		if isWorking { startWork() } else { endWork() }
	}

	/// The green wave grows in from the left while the still wave shrinks back, then the segment starts to run.
	private func startWork() {
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		still.strokeStart = 1
		track.strokeStart = 0
		track.strokeEnd = 1
		CATransaction.commit()
		Self.animate(still, "strokeStart", from: 0, to: 1)
		Self.animate(track, "strokeEnd", from: 0, to: 1)

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
		run.beginTime = CACurrentMediaTime() + Self.swapDuration
		Self.limitFrameRate(run)
		segment.add(run, forKey: "run")
	}

	/// The segment stops, the green wave leaves to the right while the still wave grows back from the left.
	private func endWork() {
		segment.removeAnimation(forKey: "run")
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		still.strokeStart = 0
		still.strokeEnd = 1
		track.strokeStart = 1
		CATransaction.commit()
		Self.animate(still, "strokeEnd", from: 0, to: 1)
		Self.animate(track, "strokeStart", from: 0, to: 1)
	}

	private static func animate(_ layer: CAShapeLayer, _ keyPath: String, from: Double, to: Double) {
		let animation = CABasicAnimation(keyPath: keyPath)
		animation.fromValue = from
		animation.toValue = to
		animation.duration = swapDuration
		animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
		limitFrameRate(animation)
		layer.add(animation, forKey: keyPath)
	}

	/// 30 frames per second look smooth and keep the work of the window server low.
	private static func limitFrameRate(_ animation: CAAnimation) {
		if #available(macOS 12, *) {
			animation.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
		}
	}

	/// A sine wave with a fixed wavelength from the left end to `end`, vertically centered. It starts upward also where
	/// the y axis points down, as in the layers of the flipped button.
	/// - Parameter gap: Leaves out the middle of the wave.
	static func wave(to end: Double, height: Double, yAxisDown: Bool, gap: Bool = false) -> CGPath {
		let path = CGMutablePath()
		let start = inset
		let length = max(end - inset - start, 1)
		let gapRange = (start + length / 2 - gapWidth / 2)...(start + length / 2 + gapWidth / 2)
		let steps = Int(length * 2)
		var isDrawing = false
		for step in 0...steps {
			let x = start + length * Double(step) / Double(steps)
			if gap && gapRange.contains(x) {
				isDrawing = false
				continue
			}
			let offset = sin((x - start) / wavelength * 2 * .pi) * amplitude
			let point = CGPoint(x: x, y: height / 2 + (yAxisDown ? -offset : offset))
			if isDrawing { path.addLine(to: point) } else { path.move(to: point) }
			isDrawing = true
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
