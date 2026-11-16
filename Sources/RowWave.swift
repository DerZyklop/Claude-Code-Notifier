import AppKit
import SwiftUI

/// The wave of a row in ``SessionCard``, in the space between the texts on the left and on the right. It looks like
/// the wave of the menu bar: a moving wave in `color` while the row works, else the still wave in the text color.
struct RowWave: NSViewRepresentable {
	/// The color of the moving wave, `nil` for the still wave.
	var color: NSColor?

	func makeNSView(context: Context) -> RowWaveView {
		RowWaveView()
	}

	func updateNSView(_ view: RowWaveView, context: Context) {
		view.color = color
	}
}

/// The layers of ``RowWave``. Core Animation runs the segment in the window server, also while the menu is open.
final class RowWaveView: NSView {
	static let height = 12.0

	var color: NSColor? {
		didSet { if color != oldValue { update() } }
	}

	private let still = CAShapeLayer()
	private let track = CAShapeLayer()
	private let segment = CAShapeLayer()
	private let segmentMask = CAShapeLayer()
	/// The size of the paths, to build them only when it changes.
	private var shownSize: CGSize?
	private var isRunning = false

	init() {
		super.init(frame: .zero)
		wantsLayer = true
		Spinner.style(still, track, segment, mask: segmentMask)
		for layer in [still, track, segment] { self.layer?.addSublayer(layer) }
		update()
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) is not available")
	}

	override var intrinsicContentSize: NSSize {
		NSSize(width: NSView.noIntrinsicMetric, height: Self.height)
	}

	override func layout() {
		super.layout()
		guard bounds.size != shownSize else { return }
		shownSize = bounds.size
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		let wave = Spinner.wave(to: bounds.width, height: bounds.height, yAxisDown: isFlipped)
		still.path = wave
		track.path = wave
		segmentMask.path = wave
		segment.path = Spinner.wave(to: bounds.width, height: bounds.height, yAxisDown: isFlipped, overhang: Spinner.lineWidth)
		for layer in [still, track, segment, segmentMask] {
			layer.frame = bounds
			layer.contentsScale = window?.backingScaleFactor ?? 2
		}
		CATransaction.commit()
		// A new length changes the dash of the segment.
		isRunning = false
		update()
	}

	override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		update()
	}

	/// Shows the still or the moving wave. The segment starts to run when the wave has its size.
	private func update() {
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
		still.strokeColor = StatusMenu.textColor(isDark: isDark).cgColor
		still.isHidden = color != nil
		track.isHidden = color == nil
		segment.isHidden = color == nil
		if let color { Spinner.paint(color, track: track, segment: segment) }
		CATransaction.commit()

		if color == nil {
			segment.removeAnimation(forKey: "run")
			isRunning = false
		} else if !isRunning && shownSize != nil {
			Spinner.run(segment, entersFromLeft: false)
			isRunning = true
		}
	}
}
