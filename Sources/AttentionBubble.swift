import AppKit
import QuartzCore

/// The orange bubble of the waiting sessions, as a layer above the image of the button, so that it can move. It has the
/// highest priority in the icon: it pops in when it appears, and then it rings twice every ``ringInterval`` seconds
/// until no session asks you anymore. With each ring, it glows from orange to dark red and back, and a halo grows out
/// from behind it and fades. The wave glows with it, see ``glow(_:normal:peak:)``. Core Animation runs it in the window server, so the app does no work per frame.
@MainActor
final class AttentionBubble {
	static let popDuration = 0.45
	static let ringInterval = 5.0
	/// How long the two rings of a round move. The rest of ``ringInterval``, the bubble rests.
	static let ringLength = 1.6
	static let color = NSColor.systemOrange
	/// The color at the peak of a ring.
	static let glowColor = NSColor.systemRed.blended(withFraction: 0.35, of: .black) ?? NSColor.systemRed

	let layer = CALayer()
	/// Behind the bubble. Its diameter is a share of the bubble width, so that the grown halo still fits into the menu bar.
	let halo = CAShapeLayer()
	private static let haloShare = 0.9
	private weak var button: NSView?
	/// The count that the bubble shows, 0 while it is hidden.
	private(set) var shownCount = 0
	/// The bubble in its normal and in its glow color, for the color animation.
	private var contents: (normal: Any, glow: Any)?

	init(button: NSView) {
		self.button = button
		button.wantsLayer = true
		layer.contentsGravity = .resizeAspect
		halo.fillColor = Self.color.cgColor
		halo.opacity = 0
		for sublayer in [halo, layer] {
			sublayer.isHidden = true
			button.layer?.addSublayer(sublayer)
		}
	}

	/// Shows the bubble for `count` waiting sessions in the given frame of the button, or hides it when the count is 0.
	/// - Parameter image: The bubble in the given color.
	func show(count: Int, image: (NSColor) -> NSImage, in frame: NSRect?) {
		guard count > 0, let frame else {
			for sublayer in [halo, layer] {
				sublayer.isHidden = true
				sublayer.removeAllAnimations()
			}
			shownCount = 0
			ringStart = nil
			return
		}
		let scale = button?.window?.backingScaleFactor ?? 2
		let diameter = frame.width * Self.haloShare
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		for sublayer in [halo, layer] {
			sublayer.bounds = CGRect(origin: .zero, size: frame.size)
			sublayer.position = CGPoint(x: frame.midX, y: frame.midY)
			sublayer.contentsScale = scale
			sublayer.isHidden = false
		}
		halo.path = CGPath(ellipseIn: CGRect(x: (frame.width - diameter) / 2, y: (frame.height - diameter) / 2, width: diameter, height: diameter), transform: nil)
		let isNewCount = count != shownCount
		if isNewCount {
			let normal = image(Self.color).layerContents(forContentsScale: scale)
			contents = (normal, image(Self.glowColor).layerContents(forContentsScale: scale))
			layer.contents = normal
		}
		CATransaction.commit()

		// A new count needs new pictures in the color animation, so the animations start again.
		if isNewCount { attract(isNew: shownCount == 0) }
		shownCount = count
	}

	/// Pops in, then rings twice per round: it grows and swings to both sides while it glows red and the halo pings,
	/// and then it rests until the next round.
	/// - Parameter isNew: Pops the bubble in first, when it appears.
	private func attract(isNew: Bool) {
		var start = CACurrentMediaTime()
		if isNew {
			let pop = CAKeyframeAnimation(keyPath: "transform.scale")
			pop.values = [0.2, 1.3, 0.9, 1]
			pop.keyTimes = [0, 0.5, 0.8, 1]
			pop.duration = Self.popDuration
			pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
			layer.add(pop, forKey: "pop")
			start += Self.popDuration
		}
		ringStart = start

		let swingOnce: [(Double, Any)] = [(0, 0), (0.06, -0.55), (0.12, 0.55), (0.18, -0.45), (0.24, 0.35), (0.3, -0.2), (0.36, 0)]
		let swing = Self.keyframes("transform.rotation.z", swingOnce + swingOnce.map { ($0.0 + 0.5, $0.1) })
		let grow = Self.keyframes("transform.scale", Self.twice(rest: 1, peak: 1.25))
		var bubbleAnimations: [CAAnimation] = [swing, grow]
		if let contents {
			// Core Animation blends between the two pictures, so the white number stays white.
			bubbleAnimations.append(Self.keyframes("contents", Self.twice(rest: contents.normal, peak: contents.glow)))
		}
		layer.add(Self.repeating(bubbleAnimations, from: start), forKey: "ring")

		let ping: [(Double, Any)] = [(0, 0.9), (0.4, 1.6), (0.5, 1.6)]
		let spread = Self.keyframes("transform.scale", ping + [(0.5, 0.9), (0.9, 1.6)])
		let fade = Self.keyframes("opacity", [(0, 0.9), (0.4, 0), (0.5, 0), (0.5, 0.9), (0.9, 0)])
		let haloColor = Self.keyframes("fillColor", [(0, Self.glowColor.cgColor), (0.4, Self.color.cgColor), (0.5, Self.color.cgColor),
			(0.5, Self.glowColor.cgColor), (0.9, Self.color.cgColor)])
		halo.add(Self.repeating([spread, fade, haloColor], from: start), forKey: "ring")
	}

	/// When the current round of rings started, `nil` while the bubble is hidden. ``glow(_:normal:peak:)`` uses it.
	private(set) var ringStart: CFTimeInterval?

	/// The red glow of the bubble for another layer, e.g. the wave, so that both glow at the same time. `nil` while the
	/// bubble is hidden.
	func glow(_ keyPath: String, normal: CGColor, peak: CGColor) -> CAAnimation? {
		guard shownCount > 0, let ringStart else { return nil }
		return Self.repeating([Self.keyframes(keyPath, Self.twice(rest: normal, peak: peak))], from: ringStart)
	}

	/// Two pulses per round: up at the start of each half of the ring, back down at its end.
	private static func twice(rest: Any, peak: Any) -> [(Double, Any)] {
		[(0, rest), (0.06, peak), (0.3, peak), (0.36, rest), (0.5, rest), (0.56, peak), (0.8, peak), (0.86, rest)]
	}

	/// A keyframe animation over one round. The times are shares of ``ringLength``. The last value lasts until the end of
	/// ``ringInterval``.
	private static func keyframes(_ keyPath: String, _ frames: [(Double, Any)]) -> CAKeyframeAnimation {
		let animation = CAKeyframeAnimation(keyPath: keyPath)
		animation.values = frames.map(\.1) + [frames.last!.1]
		animation.keyTimes = (frames.map { $0.0 * ringLength / ringInterval } + [1]).map { NSNumber(value: $0) }
		return animation
	}

	private static func repeating(_ animations: [CAAnimation], from start: CFTimeInterval) -> CAAnimationGroup {
		let group = CAAnimationGroup()
		group.animations = animations
		group.duration = ringInterval
		group.repeatCount = .infinity
		group.beginTime = start
		return group
	}
}
