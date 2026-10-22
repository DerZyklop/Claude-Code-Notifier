import AppKit
import QuartzCore

/// The wave of the menu bar icon, as three layers on the same curve above the image of the button.
///
/// - The still wave in the menu bar color, while no session works.
/// - A pale green wave, while sessions work.
/// - A dark green segment that runs along the pale green wave from left to right, without a jump between rounds.
///
/// When work starts, the green wave grows in from the left and the still wave shrinks back at the same point. When
/// work ends, the green wave leaves to the right and the still wave grows back. The wave keeps its wavelength and gets
/// shorter when the number or the bubble needs room in the icon. Core Animation runs all of it in the window server,
/// so the app does no work per frame.
@MainActor
final class Spinner {
	static let wavelength = 20.0
	static let amplitude = 2.5
	static let lineWidth = 3.4
	/// The ends of the wave keep this distance from the edges of the space it has.
	static let inset = 2.0
	/// The gap in the middle of the still wave for a setup problem.
	static let gapWidth = 6.0
	/// One run of the segment from left to right.
	static let runDuration = 1.4
	/// The length of the segment, as a share of the wave.
	static let segmentShare = 0.35
	/// The change between the still and the green wave.
	static let swapDuration = 0.6
	static let color = NSColor.systemGreen

	let still = CAShapeLayer()
	let track = CAShapeLayer()
	let segment = CAShapeLayer()
	/// Shows the segment only inside the shape of the green wave. The segment runs on a longer path, so it slides in
	/// behind the rounded end of the wave instead of popping up with a full round cap.
	let segmentMask = CAShapeLayer()
	private weak var button: NSStatusBarButton?
	/// The shape of the shown waves, to build their paths only when it changes.
	private(set) var shownShape: (size: CGSize, end: Double, hasGap: Bool)?
	private(set) var isWorking = false

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
		segmentMask.fillColor = nil
		segmentMask.strokeColor = NSColor.black.cgColor
		segmentMask.lineWidth = Self.lineWidth
		segmentMask.lineCap = .round
		segmentMask.lineJoin = .round
		segment.mask = segmentMask
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
		let shape = (size: imageFrame.size, end: waveEnd, hasGap: hasGap)
		if shownShape.map({ $0 != shape }) ?? true {
			let wave = Self.wave(to: waveEnd, height: imageFrame.height, yAxisDown: yAxisDown)
			still.path = hasGap ? Self.wave(to: waveEnd, height: imageFrame.height, yAxisDown: yAxisDown, gap: true) : wave
			track.path = wave
			segmentMask.path = wave
			segment.path = Self.wave(to: waveEnd, height: imageFrame.height, yAxisDown: yAxisDown, overhang: Self.lineWidth)
			shownShape = shape
			// A new length changes the dash of the segment. It keeps running without a new entry.
			if self.isWorking { runSegment(entersFromLeft: false) }
		}
		for layer in [still, track, segment] {
			layer.bounds = CGRect(origin: .zero, size: imageFrame.size)
			layer.position = CGPoint(x: imageFrame.midX, y: imageFrame.midY)
			layer.contentsScale = button?.window?.backingScaleFactor ?? 2
			layer.isHidden = false
		}
		segmentMask.frame = CGRect(origin: .zero, size: imageFrame.size)
		segmentMask.contentsScale = segment.contentsScale
		still.strokeColor = stillColor.cgColor
		CATransaction.commit()

		guard isWorking != self.isWorking else { return }
		self.isWorking = isWorking
		if isWorking { startWork() } else { endWork() }
	}

	/// Lets the waves glow in dark red together with the bubble of the waiting sessions. Without a shown bubble, the glow
	/// stops.
	func glow(with bubble: AttentionBubble) {
		let peak = AttentionBubble.glowColor
		for (layer, peakColor) in [(still, peak.cgColor), (track, peak.withAlphaComponent(0.45).cgColor), (segment, peak.cgColor)] {
			if let normal = layer.strokeColor, let animation = bubble.glow("strokeColor", normal: normal, peak: peakColor) {
				layer.add(animation, forKey: "glow")
			} else {
				layer.removeAnimation(forKey: "glow")
			}
		}
	}

	/// The green wave grows in from the left while the still wave shrinks back, then the segment starts to run.
	func startWork() {
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		still.strokeStart = 1
		track.strokeStart = 0
		track.strokeEnd = 1
		segmentMask.strokeStart = 0
		segmentMask.removeAnimation(forKey: "strokeStart")
		CATransaction.commit()
		Self.animate(still, "strokeStart", from: 0, to: 1)
		Self.animate(track, "strokeEnd", from: 0, to: 1)
		runSegment(entersFromLeft: true)
	}

	/// The segment is one dash on the wave that moves to the right at an even speed. It leaves at the right end while it
	/// enters again at the left end, so a new round does not jump back.
	/// - Parameter entersFromLeft: Starts with the dash just before the left end. In the first round, the end of the
	///   stroke moves with the front of the dash, so the dash does not also show at the right end.
	private func runSegment(entersFromLeft: Bool) {
		let length = Self.length(of: segment.path)
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		segment.strokeEnd = 1
		segment.lineDashPattern = [NSNumber(value: length * Self.segmentShare), NSNumber(value: length * (1 - Self.segmentShare))]
		CATransaction.commit()

		let run = CABasicAnimation(keyPath: "lineDashPhase")
		// A falling phase moves the dash toward the end of the path.
		run.fromValue = length
		run.toValue = 0
		run.duration = Self.runDuration
		run.repeatCount = .infinity
		Self.limitFrameRate(run)
		segment.removeAnimation(forKey: "enter")
		if entersFromLeft {
			// At the phase of the dash length, the dash lies just before the start of the path.
			run.timeOffset = Self.runDuration * (1 - Self.segmentShare)
			let enter = CABasicAnimation(keyPath: "strokeEnd")
			enter.fromValue = 0
			enter.toValue = 1
			enter.duration = Self.runDuration
			Self.limitFrameRate(enter)
			segment.add(enter, forKey: "enter")
		}
		segment.add(run, forKey: "run")
	}

	/// The length of a path of lines.
	static func length(of path: CGPath?) -> Double {
		var length = 0.0
		var last: CGPoint?
		path?.applyWithBlock { element in
			let point = element.pointee.points[0]
			if element.pointee.type == .addLineToPoint, let last { length += hypot(point.x - last.x, point.y - last.y) }
			last = point
		}
		return length
	}

	/// The green wave leaves to the right while the still wave grows back from the left. The segment keeps running and
	/// leaves with the green wave, because its mask leaves the same way. The end of the mask moves faster than the
	/// segment, so a new round of the segment stays hidden.
	func endWork() {
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		still.strokeStart = 0
		still.strokeEnd = 1
		track.strokeStart = 1
		segmentMask.strokeStart = 1
		CATransaction.commit()
		CATransaction.begin()
		CATransaction.setCompletionBlock { [weak self] in
			MainActor.assumeIsolated { if self?.isWorking == false { self?.stopSegment() } }
		}
		Self.animate(still, "strokeEnd", from: 0, to: 1)
		Self.animate(track, "strokeStart", from: 0, to: 1)
		Self.animate(segmentMask, "strokeStart", from: 0, to: 1)
		CATransaction.commit()
	}

	/// Stops the hidden segment after the green wave left.
	func stopSegment() {
		segment.removeAnimation(forKey: "run")
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		segment.strokeEnd = 0
		segmentMask.strokeStart = 0
		CATransaction.commit()
	}

	static func animate(_ layer: CAShapeLayer, _ keyPath: String, from: Double, to: Double) {
		let animation = CABasicAnimation(keyPath: keyPath)
		animation.fromValue = from
		animation.toValue = to
		animation.duration = swapDuration
		animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
		limitFrameRate(animation)
		layer.add(animation, forKey: keyPath)
	}

	/// 30 frames per second look smooth and keep the work of the window server low.
	static func limitFrameRate(_ animation: CAAnimation) {
		animation.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
	}

	/// A sine wave with a fixed wavelength from the left end to `end`, vertically centered. It starts upward also where
	/// the y axis points down, as in the layers of the flipped button.
	/// - Parameters:
	///   - gap: Leaves out the middle of the wave.
	///   - overhang: Continues the wave by this length past both ends, with the same curve.
	static func wave(to end: Double, height: Double, yAxisDown: Bool, gap: Bool = false, overhang: Double = 0) -> CGPath {
		let path = CGMutablePath()
		let start = inset
		let length = max(end - inset - start, 1)
		let gapRange = (start + length / 2 - gapWidth / 2)...(start + length / 2 + gapWidth / 2)
		let steps = Int((length + 2 * overhang) * 2)
		var isDrawing = false
		for step in 0...steps {
			let x = start - overhang + (length + 2 * overhang) * Double(step) / Double(steps)
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

	static func countLine(_ count: Int, color: NSColor, prefix: String = "") -> CTLine {
		let text = prefix + (count > 9 ? "9+" : "\(count)")
		let font = NSFont.monospacedDigitSystemFont(ofSize: count > 9 ? 9 : 12, weight: .bold)
		return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
	}

	/// The visible width of the number that ``drawCount(_:at:color:prefix:)`` draws.
	static func countWidth(_ count: Int, prefix: String = "") -> Double {
		CTLineGetBoundsWithOptions(countLine(count, color: .black, prefix: prefix), .useGlyphPathBounds).width
	}

	/// Centers the visible outline of the digits. The line box of the text has room for descenders, so centering it
	/// would put the digits too high. The bubble of the waiting sessions uses it too, so both numbers have one size.
	static func drawCount(_ count: Int, at center: NSPoint, color: NSColor = .black, prefix: String = "") {
		let line = countLine(count, color: color, prefix: prefix)
		let outline = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
		guard let context = NSGraphicsContext.current?.cgContext else { return }
		context.textPosition = CGPoint(x: center.x - outline.midX, y: center.y - outline.midY)
		CTLineDraw(line, context)
	}
}
