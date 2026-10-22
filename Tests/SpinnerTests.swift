import AppKit
import QuartzCore
import Testing
@testable import ClaudeCodeNotifier

/// The points of the path, one array per subpath.
private func subpaths(_ path: CGPath?) -> [[CGPoint]] {
	var result: [[CGPoint]] = []
	path?.applyWithBlock { element in
		switch element.pointee.type {
		case .moveToPoint: result.append([element.pointee.points[0]])
		case .addLineToPoint: result[result.count - 1].append(element.pointee.points[0])
		default: break
		}
	}
	return result
}

/// The glyphs of all runs of the line.
private func glyphs(_ line: CTLine) -> [CGGlyph] {
	((CTLineGetGlyphRuns(line) as? [CTRun]) ?? []).flatMap { run in
		var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
		CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
		return glyphs
	}
}

private func isClose(_ a: Double, _ b: Double, within tolerance: Double = 1e-9) -> Bool {
	abs(a - b) <= tolerance
}

private func controlPoints(_ function: CAMediaTimingFunction?) -> [Float] {
	guard let function else { return [] }
	var points: [Float] = []
	for index in 1...2 {
		var values: [Float] = [0, 0]
		function.getControlPoint(at: index, values: &values)
		points += values
	}
	return points
}

private let easeInEaseOut = controlPoints(CAMediaTimingFunction(name: .easeInEaseOut))

private func hasLimitedFrameRate(_ animation: CAAnimation?) -> Bool {
	guard let range = animation?.preferredFrameRateRange else { return false }
	return range.minimum == 20 && range.maximum == 30 && range.preferred == 30
}

private func doubles(_ values: [Any]?) -> [Double] {
	(values ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }
}

/// Sets layer values without implicit animations.
private func withoutActions(_ change: () -> Void) {
	CATransaction.begin()
	CATransaction.setDisableActions(true)
	change()
	CATransaction.commit()
}

/// The advance of the line, with the space around the glyphs.
private func advance(_ line: CTLine) -> Double {
	CTLineGetTypographicBounds(line, nil, nil, nil)
}

/// Draws the count into a 40 by 40 bitmap and returns the pixels with ink. Row y 0 is the top row.
@MainActor
private func inkedPixels(_ count: Int, at center: NSPoint, color: NSColor? = nil) throws -> [(x: Int, y: Int, color: NSColor)] {
	let bitmap = try #require(NSBitmapImageRep(
		bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 40, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
		isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
	let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
	let saved = NSGraphicsContext.current
	NSGraphicsContext.current = context
	defer { NSGraphicsContext.current = saved }
	if let color { Spinner.drawCount(count, at: center, color: color) } else { Spinner.drawCount(count, at: center) }
	context.flushGraphics()

	var inked: [(x: Int, y: Int, color: NSColor)] = []
	for x in 0..<40 {
		for y in 0..<40 {
			if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0 { inked.append((x, y, color)) }
		}
	}
	return inked
}

/// A status bar button with a chosen direction of the y axis.
private final class FlippableButton: NSStatusBarButton {
	var flips = true
	override var isFlipped: Bool { flips }
}

/// A window with a fixed backing scale. It never shows on the screen.
private final class ScaledWindow: NSWindow {
	override var backingScaleFactor: CGFloat { 3 }
}

@MainActor
private func makeButton() -> NSStatusBarButton {
	NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 40, height: 22))
}

private let imageFrame = NSRect(x: 4, y: 1, width: 30, height: 20)
private let stillColor = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)

@Suite @MainActor struct SpinnerWaveTests {
	@Test(arguments: [false, true])
	func waveStartsAtTheInsetInTheMiddle(yAxisDown: Bool) throws {
		let first = try #require(subpaths(Spinner.wave(to: 30, height: 20, yAxisDown: yAxisDown)).first?.first)
		#expect(first == CGPoint(x: Spinner.inset, y: 10))
	}

	@Test(arguments: [30.0, 30.3, 47.75])
	func waveEndsAtTheInsetBeforeTheEnd(end: Double) throws {
		let last = try #require(subpaths(Spinner.wave(to: end, height: 20, yAxisDown: false)).last?.last)
		#expect(isClose(last.x, end - Spinner.inset))
	}

	@Test func waveIsOneLineWithTwoPointsPerUnit() {
		let paths = subpaths(Spinner.wave(to: 30, height: 20, yAxisDown: false))
		#expect(paths.count == 1)
		#expect(paths.first?.count == 53)
	}

	@Test(arguments: [false, true])
	func waveStaysWithinTheAmplitude(yAxisDown: Bool) {
		let points = subpaths(Spinner.wave(to: 60, height: 22, yAxisDown: yAxisDown)).joined()
		#expect(!points.isEmpty)
		#expect(points.allSatisfy { abs($0.y - 11) <= Spinner.amplitude + 1e-9 })
	}

	@Test func waveReachesTheAmplitudeAfterAQuarterWavelength() throws {
		let points = try #require(subpaths(Spinner.wave(to: 30, height: 20, yAxisDown: false)).first)
		let peak = try #require(points.first { $0.x == Spinner.inset + Spinner.wavelength / 4 })
		#expect(isClose(peak.y, 10 + Spinner.amplitude))
		let middle = try #require(points.first { $0.x == Spinner.inset + Spinner.wavelength / 2 })
		#expect(isClose(middle.y, 10))
	}

	@Test func waveFirstGoesUp() throws {
		let points = try #require(subpaths(Spinner.wave(to: 30, height: 20, yAxisDown: false)).first)
		try #require(points.count > 1)
		#expect(points[1].y > 10)
	}

	@Test func flippedWaveFirstGoesUpToo() throws {
		let points = try #require(subpaths(Spinner.wave(to: 30, height: 20, yAxisDown: true)).first)
		try #require(points.count > 1)
		#expect(points[1].y < 10)
	}

	@Test func flippedWaveMirrorsTheWave() {
		let normal = subpaths(Spinner.wave(to: 30, height: 20, yAxisDown: false)).joined()
		let flipped = subpaths(Spinner.wave(to: 30, height: 20, yAxisDown: true)).joined()
		#expect(normal.map(\.x) == flipped.map(\.x))
		#expect(zip(normal, flipped).allSatisfy { isClose($0.y - 10, 10 - $1.y) })
	}

	@Test(arguments: [-10.0, 0, 3, 5])
	func veryShortWaveKeepsLengthOne(end: Double) throws {
		let points = try #require(subpaths(Spinner.wave(to: end, height: 20, yAxisDown: false)).first)
		#expect(points.map { Double($0.x) } == [Spinner.inset, Spinner.inset + 0.5, Spinner.inset + 1])
	}

	@Test func gapSplitsTheWaveInTwo() throws {
		let paths = subpaths(Spinner.wave(to: 30, height: 20, yAxisDown: false, gap: true))
		#expect(paths.count == 2)
		#expect(paths.first?.first == CGPoint(x: Spinner.inset, y: 10))
		let last = try #require(paths.last?.last)
		#expect(isClose(last.x, 30 - Spinner.inset))
	}

	@Test func gapHasNoPointInItsRange() {
		// The wave runs from 2 to 28, so the gap is 6 wide around 15.
		let points = subpaths(Spinner.wave(to: 30, height: 20, yAxisDown: false, gap: true)).joined()
		#expect(!points.contains { (12...18).contains($0.x) })
		#expect(points.contains { $0.x == 11.5 })
		#expect(points.contains { $0.x == 18.5 })
	}

	@Test func gapLeavesTheOtherPointsAsTheyAre() {
		let full = Array(subpaths(Spinner.wave(to: 30, height: 20, yAxisDown: true)).joined())
		let gapped = Array(subpaths(Spinner.wave(to: 30, height: 20, yAxisDown: true, gap: true)).joined())
		#expect(gapped == full.filter { !(12...18).contains($0.x) })
	}
}

@Suite @MainActor struct SpinnerCountTests {
	@Test(arguments: [
		(0, "0", 12.0),
		(1, "1", 12.0),
		(9, "9", 12.0),
		(10, "9+", 9.0),
		(99, "9+", 9.0),
		(1000, "9+", 9.0),
	])
	func countLine(count: Int, text: String, size: Double) throws {
		let line = Spinner.countLine(count, color: .red)
		let run = try #require((CTLineGetGlyphRuns(line) as? [CTRun])?.first)
		let attributes = CTRunGetAttributes(run) as NSDictionary
		let font = try #require(attributes[NSAttributedString.Key.font.rawValue] as? NSFont)
		#expect(Double(font.pointSize) == size)
		#expect(font.fontName == NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold).fontName)

		// The line shows the same glyphs as the text in the font.
		let reference = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
		#expect(CTLineGetStringRange(line).length == text.utf16.count)
		#expect(glyphs(line) == glyphs(reference))
	}

	@Test(arguments: [(2, "×2"), (10, "×9+")])
	func countLineStartsWithThePrefix(count: Int, text: String) {
		let line = Spinner.countLine(count, color: .black, prefix: "×")
		#expect(CTLineGetStringRange(line).length == text.utf16.count)
		#expect(Spinner.countWidth(count, prefix: "×") > Spinner.countWidth(count))
	}

	@Test func countLineHasTheColor() throws {
		let color = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 1)
		let run = try #require((CTLineGetGlyphRuns(Spinner.countLine(3, color: color)) as? [CTRun])?.first)
		let attributes = CTRunGetAttributes(run) as NSDictionary
		#expect(attributes[NSAttributedString.Key.foregroundColor.rawValue] as? NSColor == color)
	}

	@Test func countWidthIsPositive() {
		#expect(Spinner.countWidth(1) > 0)
		#expect(Spinner.countWidth(8) > 0)
	}

	@Test func twoDigitsAreWiderThanOne() {
		#expect(Spinner.countWidth(10) > Spinner.countWidth(9))
	}

	@Test func allCountsAbove9HaveOneWidth() {
		#expect(Spinner.countWidth(10) == Spinner.countWidth(99))
		#expect(Spinner.countWidth(10) == Spinner.countWidth(1000))
	}

	@Test func digitsHaveOneAdvance() {
		let advances = (0...9).map { advance(Spinner.countLine($0, color: .black)) }
		#expect(Set(advances).count == 1)
	}

	@Test func countWidthIsTheWidthOfTheInk() {
		// The digits have one advance, but 1 has less ink than 8.
		#expect(Spinner.countWidth(1) < Spinner.countWidth(8))
		for count in [1, 8, 10] {
			#expect(Spinner.countWidth(count) < advance(Spinner.countLine(count, color: .black)))
		}
	}

	@Test func drawCountWithoutContextDoesNothing() {
		let saved = NSGraphicsContext.current
		NSGraphicsContext.current = nil
		defer { NSGraphicsContext.current = saved }
		Spinner.drawCount(5, at: NSPoint(x: 10, y: 10))
	}

	@Test(arguments: [8, 10])
	func drawCountCentersTheDigitsAtThePoint(count: Int) throws {
		let inked = try inkedPixels(count, at: NSPoint(x: 15, y: 20), color: NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1))
		let xs = inked.map(\.x), ys = inked.map(\.y)
		let minX = try #require(xs.min()), maxX = try #require(xs.max())
		let minY = try #require(ys.min()), maxY = try #require(ys.max())
		// Pixel column x covers x...x + 1. The center 20 is also 20 from the top.
		#expect(abs(Double(minX + maxX + 1) / 2 - 15) <= 1)
		#expect(abs(Double(minY + maxY + 1) / 2 - 20) <= 1)
		#expect(abs(Double(maxX - minX + 1) - Spinner.countWidth(count)) <= 2)

		let darkest = try #require(inked.max { $0.color.alphaComponent < $1.color.alphaComponent }?.color)
		#expect(darkest.alphaComponent > 0.9)
		#expect(darkest.redComponent > 0.8)
		#expect(darkest.greenComponent < 0.2)
	}

	@Test func drawCountIsBlackByDefault() throws {
		let inked = try inkedPixels(8, at: NSPoint(x: 15, y: 20))
		let darkest = try #require(inked.max { $0.color.alphaComponent < $1.color.alphaComponent }?.color)
		#expect(darkest.alphaComponent > 0.9)
		#expect(darkest.redComponent < 0.1)
		#expect(darkest.greenComponent < 0.1)
		#expect(darkest.blueComponent < 0.1)
	}
}

@Suite @MainActor struct SpinnerInitTests {
	@Test func layersAreSublayersOfTheButtonInOrder() throws {
		let button = makeButton()
		let spinner = Spinner(button: button)
		#expect(button.wantsLayer)
		let sublayers = try #require(button.layer?.sublayers)
		let indexes = [spinner.still, spinner.track, spinner.segment].map { layer in sublayers.firstIndex { $0 === layer } }
		let found = indexes.compactMap { $0 }
		#expect(found.count == 3)
		#expect(found == found.sorted())
	}

	@Test func layersAreHiddenRoundLines() {
		let spinner = Spinner(button: makeButton())
		for layer in [spinner.still, spinner.track, spinner.segment] {
			#expect(layer.isHidden)
			#expect(layer.fillColor == nil)
			#expect(Double(layer.lineWidth) == Spinner.lineWidth)
			#expect(layer.lineCap == .round)
			#expect(layer.lineJoin == .round)
			#expect(layer.path == nil)
		}
	}

	@Test func onlyTheStillWaveIsDrawnAtTheStart() {
		let spinner = Spinner(button: makeButton())
		#expect(spinner.still.strokeStart == 0)
		#expect(spinner.still.strokeEnd == 1)
		#expect(spinner.track.strokeEnd == 0)
		#expect(spinner.segment.strokeEnd == 0)
		#expect(spinner.shownShape == nil)
		#expect(!spinner.isWorking)
	}

	@Test func greenLayersHaveTheirColors() {
		let spinner = Spinner(button: makeButton())
		#expect(spinner.track.strokeColor == Spinner.color.withAlphaComponent(0.3).cgColor)
		#expect(spinner.track.strokeColor?.alpha == 0.3)
		let dark = Spinner.color.blended(withFraction: 0.35, of: .black) ?? Spinner.color
		#expect(spinner.segment.strokeColor == dark.cgColor)
	}
}

@Suite @MainActor struct SpinnerShowTests {
	@Test func showPlacesTheLayersOverTheImage() {
		let spinner = Spinner(button: makeButton())
		spinner.show(waveEnd: 26, over: imageFrame, isWorking: false, hasGap: false, stillColor: stillColor)
		for layer in [spinner.still, spinner.track, spinner.segment] {
			#expect(!layer.isHidden)
			#expect(layer.bounds == CGRect(x: 0, y: 0, width: 30, height: 20))
			#expect(layer.position == CGPoint(x: 19, y: 11))
			#expect(layer.contentsScale == 2)
		}
		#expect(spinner.still.strokeColor == stillColor.cgColor)
	}

	@Test func showSetsTheWavePaths() {
		let button = makeButton()
		let spinner = Spinner(button: button)
		spinner.show(waveEnd: 26, over: imageFrame, isWorking: false, hasGap: false, stillColor: stillColor)
		let wave = subpaths(Spinner.wave(to: 26, height: 20, yAxisDown: button.isFlipped))
		#expect(subpaths(spinner.still.path) == wave)
		#expect(subpaths(spinner.track.path) == wave)
		#expect(subpaths(spinner.segment.path) == wave)
	}

	@Test(arguments: [false, true])
	func wavesUseTheYAxisOfTheButton(flipped: Bool) {
		let button = FlippableButton(frame: NSRect(x: 0, y: 0, width: 40, height: 22))
		button.flips = flipped
		let spinner = Spinner(button: button)
		spinner.show(waveEnd: 26, over: imageFrame, isWorking: false, hasGap: true, stillColor: stillColor)
		#expect(subpaths(spinner.track.path) == subpaths(Spinner.wave(to: 26, height: 20, yAxisDown: flipped)))
		#expect(subpaths(spinner.still.path) == subpaths(Spinner.wave(to: 26, height: 20, yAxisDown: flipped, gap: true)))
	}

	@Test func layersUseTheScaleOfTheWindow() {
		let window = ScaledWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 30), styleMask: [.borderless],
			backing: .buffered, defer: true)
		window.isReleasedWhenClosed = false
		let button = makeButton()
		window.contentView?.addSubview(button)
		let spinner = Spinner(button: button)
		spinner.show(waveEnd: 26, over: imageFrame, isWorking: false, hasGap: false, stillColor: stillColor)
		for layer in [spinner.still, spinner.track, spinner.segment] { #expect(layer.contentsScale == 3) }
	}

	@Test func showWithoutTheButtonUsesAnUpwardYAxis() throws {
		weak var weakButton: NSStatusBarButton?
		let spinner: Spinner = autoreleasepool {
			let button = FlippableButton(frame: NSRect(x: 0, y: 0, width: 40, height: 22))
			weakButton = button
			return Spinner(button: button)
		}
		// The spinner keeps only a weak reference to the button.
		try #require(weakButton == nil)
		spinner.show(waveEnd: 26, over: imageFrame, isWorking: false, hasGap: false, stillColor: stillColor)
		#expect(subpaths(spinner.track.path) == subpaths(Spinner.wave(to: 26, height: 20, yAxisDown: false)))
		for layer in [spinner.still, spinner.track, spinner.segment] {
			#expect(!layer.isHidden)
			#expect(layer.contentsScale == 2)
		}
	}

	@Test func showRemembersTheShape() throws {
		let spinner = Spinner(button: makeButton())
		spinner.show(waveEnd: 26, over: imageFrame, isWorking: false, hasGap: true, stillColor: stillColor)
		let shape = try #require(spinner.shownShape)
		#expect(shape.size == CGSize(width: 30, height: 20))
		#expect(shape.end == 26)
		#expect(shape.hasGap)
	}

	@Test func gapIsOnlyInTheStillWave() {
		let button = makeButton()
		let spinner = Spinner(button: button)
		spinner.show(waveEnd: 26, over: imageFrame, isWorking: false, hasGap: true, stillColor: stillColor)
		#expect(subpaths(spinner.still.path) == subpaths(Spinner.wave(to: 26, height: 20, yAxisDown: button.isFlipped, gap: true)))
		#expect(subpaths(spinner.still.path).count == 2)
		let wave = subpaths(Spinner.wave(to: 26, height: 20, yAxisDown: button.isFlipped))
		#expect(subpaths(spinner.track.path) == wave)
		#expect(subpaths(spinner.segment.path) == wave)
	}

	@Test func nilFrameHidesTheLayers() {
		let spinner = Spinner(button: makeButton())
		spinner.show(waveEnd: 26, over: imageFrame, isWorking: false, hasGap: false, stillColor: stillColor)
		spinner.show(waveEnd: 26, over: nil, isWorking: false, hasGap: false, stillColor: stillColor)
		for layer in [spinner.still, spinner.track, spinner.segment] { #expect(layer.isHidden) }
	}

	@Test func frameAfterNilShowsTheLayersAgain() {
		let spinner = Spinner(button: makeButton())
		spinner.show(waveEnd: 26, over: nil, isWorking: false, hasGap: false, stillColor: stillColor)
		spinner.show(waveEnd: 26, over: imageFrame, isWorking: false, hasGap: false, stillColor: stillColor)
		for layer in [spinner.still, spinner.track, spinner.segment] { #expect(!layer.isHidden) }
	}

	@Test func nilFrameChangesNothingElse() {
		let spinner = Spinner(button: makeButton())
		spinner.show(waveEnd: 26, over: nil, isWorking: true, hasGap: false, stillColor: stillColor)
		#expect(!spinner.isWorking)
		#expect(spinner.shownShape == nil)
		#expect(spinner.track.path == nil)
		#expect(spinner.segment.animation(forKey: "run") == nil)
	}

	@Test func sameShapeKeepsThePaths() {
		let spinner = Spinner(button: makeButton())
		spinner.show(waveEnd: 26, over: imageFrame, isWorking: false, hasGap: true, stillColor: stillColor)

		// A new build of the paths would replace the nil paths.
		withoutActions { for layer in [spinner.still, spinner.track, spinner.segment] { layer.path = nil } }
		let moved = imageFrame.offsetBy(dx: 5, dy: 1)
		spinner.show(waveEnd: 26, over: moved, isWorking: false, hasGap: true, stillColor: .red)
		for layer in [spinner.still, spinner.track, spinner.segment] { #expect(layer.path == nil) }
		#expect(spinner.track.position == CGPoint(x: moved.midX, y: moved.midY))
		#expect(spinner.still.strokeColor == NSColor.red.cgColor)
	}

	@Test(arguments: [
		(26.0, CGSize(width: 30, height: 20), false),
		(20.0, CGSize(width: 30, height: 20), true),
		(26.0, CGSize(width: 31, height: 20), true),
		(26.0, CGSize(width: 30, height: 18), true),
	])
	func changedShapeBuildsNewPaths(end: Double, size: CGSize, hasGap: Bool) throws {
		let button = makeButton()
		let spinner = Spinner(button: button)
		spinner.show(waveEnd: 26, over: imageFrame, isWorking: false, hasGap: true, stillColor: stillColor)
		withoutActions { for layer in [spinner.still, spinner.track, spinner.segment] { layer.path = nil } }
		spinner.show(waveEnd: end, over: NSRect(origin: imageFrame.origin, size: size), isWorking: false, hasGap: hasGap, stillColor: stillColor)
		let wave = subpaths(Spinner.wave(to: end, height: size.height, yAxisDown: button.isFlipped))
		#expect(subpaths(spinner.track.path) == wave)
		#expect(subpaths(spinner.segment.path) == wave)
		let still = Spinner.wave(to: end, height: size.height, yAxisDown: button.isFlipped, gap: hasGap)
		#expect(subpaths(spinner.still.path) == subpaths(still))
		let shape = try #require(spinner.shownShape)
		#expect(shape.size == size && shape.end == end && shape.hasGap == hasGap)
	}

	@Test func showWithoutWorkAtTheStartDoesNotEndWork() {
		let spinner = Spinner(button: makeButton())
		spinner.show(waveEnd: 26, over: imageFrame, isWorking: false, hasGap: false, stillColor: stillColor)
		#expect(!spinner.isWorking)
		#expect(spinner.track.strokeStart == 0)
		#expect(spinner.still.animation(forKey: "strokeEnd") == nil)
		#expect(spinner.track.animation(forKey: "strokeStart") == nil)
	}

	@Test func showWithWorkStartsWorkOnce() {
		let spinner = Spinner(button: makeButton())
		spinner.show(waveEnd: 26, over: imageFrame, isWorking: true, hasGap: false, stillColor: stillColor)
		#expect(spinner.isWorking)
		#expect(spinner.still.strokeStart == 1)
		#expect(spinner.segment.animation(forKey: "run") != nil)

		// A second call to startWork would set the value back to 1.
		withoutActions { spinner.still.strokeStart = 0.5 }
		spinner.show(waveEnd: 26, over: imageFrame, isWorking: true, hasGap: false, stillColor: stillColor)
		#expect(spinner.still.strokeStart == 0.5)
	}

	@Test func showWithoutWorkEndsWorkOnce() {
		let spinner = Spinner(button: makeButton())
		spinner.show(waveEnd: 26, over: imageFrame, isWorking: true, hasGap: false, stillColor: stillColor)
		spinner.show(waveEnd: 26, over: imageFrame, isWorking: false, hasGap: false, stillColor: stillColor)
		#expect(!spinner.isWorking)
		#expect(spinner.track.strokeStart == 1)
		#expect(spinner.segment.animation(forKey: "run") == nil)

		// A second call to endWork would set the value back to 1.
		withoutActions { spinner.track.strokeStart = 0.5 }
		spinner.show(waveEnd: 26, over: imageFrame, isWorking: false, hasGap: false, stillColor: stillColor)
		#expect(spinner.track.strokeStart == 0.5)
	}

	@Test func workStartsAgainAfterItEnds() {
		let spinner = Spinner(button: makeButton())
		spinner.show(waveEnd: 26, over: imageFrame, isWorking: true, hasGap: false, stillColor: stillColor)
		spinner.show(waveEnd: 26, over: imageFrame, isWorking: false, hasGap: false, stillColor: stillColor)
		spinner.show(waveEnd: 26, over: imageFrame, isWorking: true, hasGap: false, stillColor: stillColor)
		#expect(spinner.isWorking)
		#expect(spinner.still.strokeStart == 1)
		#expect(spinner.track.strokeStart == 0)
		#expect(spinner.segment.animation(forKey: "run") != nil)
	}
}

@Suite @MainActor struct SpinnerWorkTests {
	@Test func startWorkSwapsTheWaves() {
		let spinner = Spinner(button: makeButton())
		spinner.startWork()
		#expect(spinner.still.strokeStart == 1)
		#expect(spinner.track.strokeStart == 0)
		#expect(spinner.track.strokeEnd == 1)
	}

	@Test func startWorkAnimatesTheSwap() throws {
		let spinner = Spinner(button: makeButton())
		spinner.startWork()
		let still = try #require(spinner.still.animation(forKey: "strokeStart") as? CABasicAnimation)
		#expect(still.keyPath == "strokeStart")
		#expect(still.fromValue as? Double == 0)
		#expect(still.toValue as? Double == 1)
		#expect(still.duration == Spinner.swapDuration)
		#expect(hasLimitedFrameRate(still))
		let track = try #require(spinner.track.animation(forKey: "strokeEnd") as? CABasicAnimation)
		#expect(track.keyPath == "strokeEnd")
		#expect(track.fromValue as? Double == 0)
		#expect(track.toValue as? Double == 1)
		#expect(track.duration == Spinner.swapDuration)
		#expect(hasLimitedFrameRate(track))
	}

	@Test func startWorkRunsTheSegmentAfterTheSwap() throws {
		let spinner = Spinner(button: makeButton())
		let before = CACurrentMediaTime()
		spinner.startWork()
		let after = CACurrentMediaTime()
		let run = try #require(spinner.segment.animation(forKey: "run") as? CAAnimationGroup)
		#expect(run.duration == Spinner.runDuration)
		#expect(run.repeatCount == .infinity)
		#expect((before + Spinner.swapDuration...after + Spinner.swapDuration).contains(run.beginTime))
		#expect(controlPoints(run.timingFunction) == easeInEaseOut)
		#expect(hasLimitedFrameRate(run))

		let animations = try #require(run.animations as? [CAKeyframeAnimation])
		try #require(animations.count == 2)
		#expect(animations.map(\.keyPath) == ["strokeEnd", "strokeStart"])
		#expect(doubles(animations[0].values) == [0, 1, 1])
		#expect(doubles(animations[0].keyTimes) == [0, 0.65, 1])
		#expect(doubles(animations[1].values) == [0, 0, 1])
		#expect(doubles(animations[1].keyTimes) == [0, 0.35, 1])
	}

	@Test func endWorkStopsTheSegment() {
		let spinner = Spinner(button: makeButton())
		spinner.startWork()
		spinner.endWork()
		#expect(spinner.segment.animation(forKey: "run") == nil)
	}

	@Test func endWorkSwapsTheWavesBack() {
		let spinner = Spinner(button: makeButton())
		spinner.startWork()
		spinner.endWork()
		#expect(spinner.still.strokeStart == 0)
		#expect(spinner.still.strokeEnd == 1)
		#expect(spinner.track.strokeStart == 1)
	}

	@Test func endWorkAnimatesTheSwap() throws {
		let spinner = Spinner(button: makeButton())
		spinner.startWork()
		spinner.endWork()
		let still = try #require(spinner.still.animation(forKey: "strokeEnd") as? CABasicAnimation)
		#expect(still.keyPath == "strokeEnd")
		#expect(still.fromValue as? Double == 0)
		#expect(still.toValue as? Double == 1)
		#expect(still.duration == Spinner.swapDuration)
		#expect(hasLimitedFrameRate(still))
		let track = try #require(spinner.track.animation(forKey: "strokeStart") as? CABasicAnimation)
		#expect(track.keyPath == "strokeStart")
		#expect(track.fromValue as? Double == 0)
		#expect(track.toValue as? Double == 1)
		#expect(track.duration == Spinner.swapDuration)
		#expect(hasLimitedFrameRate(track))
	}

	@Test func endWorkWithoutStartSetsTheValues() {
		let spinner = Spinner(button: makeButton())
		spinner.endWork()
		#expect(spinner.segment.animation(forKey: "run") == nil)
		#expect(spinner.track.strokeStart == 1)
	}
}

@Suite @MainActor struct SpinnerAnimationTests {
	@Test func animateAddsABasicAnimationForTheKeyPath() throws {
		let layer = CAShapeLayer()
		Spinner.animate(layer, "lineWidth", from: 0.25, to: 4)
		let animation = try #require(layer.animation(forKey: "lineWidth") as? CABasicAnimation)
		#expect(animation.keyPath == "lineWidth")
		#expect(animation.fromValue as? Double == 0.25)
		#expect(animation.toValue as? Double == 4)
		#expect(animation.duration == Spinner.swapDuration)
		#expect(controlPoints(animation.timingFunction) == easeInEaseOut)
		#expect(hasLimitedFrameRate(animation))
	}

	@Test func animateDoesNotChangeTheValue() {
		let layer = CAShapeLayer()
		Spinner.animate(layer, "lineWidth", from: 0.25, to: 4)
		#expect(layer.lineWidth == 1)
	}

	@Test func limitFrameRateSetsTheRange() {
		#expect(!hasLimitedFrameRate(CABasicAnimation()))
		for animation in [CABasicAnimation(), CAKeyframeAnimation(), CAAnimationGroup()] as [CAAnimation] {
			Spinner.limitFrameRate(animation)
			#expect(hasLimitedFrameRate(animation))
		}
	}
}
