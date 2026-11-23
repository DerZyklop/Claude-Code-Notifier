import AppKit
import Intents
import QuartzCore

/// The orange bubble of the waiting sessions, as a layer above the image of the button, so that it can move. It has the
/// highest priority in the icon: it pops in when it appears, and then it rings once every ``ringInterval`` seconds
/// until no session asks you anymore. With each ring, it glows from orange to dark red and back, and a halo grows out
/// from behind it and fades. The wave glows with it, see ``glow(_:normal:peak:)``. A calm sound plays with each round. Core Animation runs it in the window server, so the app does no work per frame.
@MainActor
final class AttentionBubble {
	static let popDuration = 0.45
	static let ringInterval = 20.0
	/// How long the ring of a round moves. The rest of ``ringInterval``, the bubble rests.
	static let ringLength = 1.6
	/// The animations of a round start this many seconds after its sound and its LED ring are sent, because those
	/// come out later.
	static let syncDelay = 0.1
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
			chime?.invalidate()
			chime = nil
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

	/// Pops in, then rings once per round: it grows and swings to both sides while it glows red and the halo pings,
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
		startChime(at: start)
		// The sound and the LED of the round come a little later than the start, so the animations wait for them.
		start += Self.syncDelay
		ringStart = start

		let swing = Self.keyframes("transform.rotation.z", [(0, 0), (0.12, -0.55), (0.24, 0.55), (0.36, -0.45), (0.48, 0.35), (0.6, -0.2), (0.72, 0)])
		let grow = Self.keyframes("transform.scale", Self.once(rest: 1, peak: 1.25))
		var bubbleAnimations: [CAAnimation] = [swing, grow]
		if let contents {
			// Core Animation blends between the two pictures, so the white number stays white.
			bubbleAnimations.append(Self.keyframes("contents", Self.once(rest: contents.normal, peak: contents.glow)))
		}
		layer.add(Self.repeating(bubbleAnimations, from: start), forKey: "ring")

		let spread = Self.keyframes("transform.scale", [(0, 0.9), (0.8, 1.6)])
		let fade = Self.keyframes("opacity", [(0, 0.9), (0.8, 0)])
		let haloColor = Self.keyframes("fillColor", [(0, Self.glowColor.cgColor), (0.8, Self.color.cgColor)])
		halo.add(Self.repeating([spread, fade, haloColor], from: start), forKey: "ring")
	}

	/// Plays a calm sound with each round of rings, see ``startChime(at:)``.
	private var chime: Timer?
	/// The sound of a round: the short, quiet »Pop«.
	static let chimeSound = "Pop"
	static let chimeVolume: Float = 0.35

	/// Plays the chime and rings the blink(1) with each round, from the first one on. The light rings also after the
	/// chime stops, like the bubble.
	private func startChime(at start: CFTimeInterval) {
		chime?.invalidate()
		let firstFire = Date().addingTimeInterval(start - CACurrentMediaTime())
		let timer = Timer(fire: firstFire, interval: Self.ringInterval, repeats: true) { [weak self] _ in
			Task { @MainActor in
				guard let self else { return }
				Lights.ring()
				if self.allowsChime() { Self.playChime() }
			}
		}
		// The `common` modes include the one the run loop uses while a menu is open.
		RunLoop.main.add(timer, forMode: .common)
		chime = timer
	}

	/// Plays the ``holdSound`` every ``holdInterval`` seconds while an important session is idle, see ``Session/holdsRing``.
	private var holdChime: Timer?
	static let holdInterval = 5.0
	static let holdSound = "Sosumi"

	/// Starts or stops the sound of an idle important session. It follows the sound setting, without a time limit.
	func hold(_ isOn: Bool) {
		guard isOn != (holdChime != nil) else { return }
		holdChime?.invalidate()
		holdChime = nil
		guard isOn else { return }
		let timer = Timer(timeInterval: Self.holdInterval, repeats: true) { _ in
			Task { @MainActor in Self.playSound(Self.holdSound) }
		}
		RunLoop.main.add(timer, forMode: .common)
		holdChime = timer
		Self.playSound(Self.holdSound)
	}

	/// A session gets the chime for this many seconds after it starts to ask, see ``allowsChime(at:)``.
	static let chimeLimit = 300.0
	/// When each asking session started to ask, by its ID.
	private(set) var askedSince: [String: Date] = [:]

	/// Starts the time of each session that starts to ask, and forgets the sessions that do not ask anymore. A session
	/// that asks again later gets a new time.
	func track(asking ids: Set<String>, at now: Date = Date()) {
		askedSince = askedSince.filter { ids.contains($0.key) }
		for id in ids where askedSince[id] == nil { askedSince[id] = now }
	}

	/// Whether the chime may play: only while a session asks for less than ``chimeLimit`` seconds.
	func allowsChime(at now: Date = Date()) -> Bool {
		askedSince.values.contains { now.timeIntervalSince($0) < Self.chimeLimit }
	}

	/// Follows the sound setting of the setup window, see ``SoundMode``, and stays silent while a Focus of macOS is on.
	private static func playChime() {
		guard allowsSound else { return }
		playChimeSound()
	}

	/// Plays another macOS sound of the app, e.g. the one of a ready report. Follows the same rules as the chime.
	static func playSound(_ name: String) {
		guard allowsSound, let sound = NSSound(named: name)?.copy() as? NSSound else { return }
		sound.play()
	}

	/// The sound setting of the setup window allows sound, and no Focus of macOS is on.
	private static var allowsSound: Bool {
		SoundMode.current().allowsSound && INFocusStatusCenter.default.focusStatus.isFocused != true
	}

	/// Plays the chime without a check of the settings, e.g. for the »Play« button of the setup window.
	static func playChimeSound() {
		guard let sound = NSSound(named: chimeSound)?.copy() as? NSSound else { return }
		sound.volume = chimeVolume
		sound.play()
	}

	/// When the current round of rings started, `nil` while the bubble is hidden. ``glow(_:normal:peak:)`` uses it.
	private(set) var ringStart: CFTimeInterval?

	/// The red glow of the bubble for another layer, e.g. the wave, so that both glow at the same time. `nil` while the
	/// bubble is hidden.
	func glow(_ keyPath: String, normal: CGColor, peak: CGColor) -> CAAnimation? {
		guard shownCount > 0, let ringStart else { return nil }
		return Self.repeating([Self.keyframes(keyPath, Self.once(rest: normal, peak: peak))], from: ringStart)
	}

	/// The glow of a round: up at once, a long peak, then back down. ``LightScene/ring(from:to:at:)`` follows these times.
	static let glowTimes = (up: 0.06, down: 0.6, rest: 0.72)

	/// One pulse per round, at the ``glowTimes``.
	private static func once(rest: Any, peak: Any) -> [(Double, Any)] {
		[(0, rest), (glowTimes.up, peak), (glowTimes.down, peak), (glowTimes.rest, rest)]
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

/// When the chime plays. It is stored in two settings, ``SettingsKey/playsSound`` and
/// ``SettingsKey/mutesSoundWithLights``, so that the old setting »Play Sounds« keeps its value.
enum SoundMode: CaseIterable {
	case on
	/// Off while the blink(1) or the keyboard shows the state.
	case withoutLights
	case off

	var title: String {
		switch self {
		case .on: "On"
		case .withoutLights: "Off While a Light Is Connected"
		case .off: "Off"
		}
	}

	static func current(in defaults: UserDefaults = .standard) -> SoundMode {
		!SettingsKey.isOn(SettingsKey.playsSound, in: defaults) ? .off
			: SettingsKey.isOn(SettingsKey.mutesSoundWithLights, in: defaults) ? .withoutLights : .on
	}

	func store(in defaults: UserDefaults = .standard) {
		SettingsKey.set(SettingsKey.playsSound, to: self != .off, in: defaults)
		SettingsKey.set(SettingsKey.mutesSoundWithLights, to: self == .withoutLights, in: defaults)
	}

	@MainActor var allowsSound: Bool {
		switch self {
		case .on: true
		case .withoutLights: !Lights.isShowing
		case .off: false
		}
	}
}
