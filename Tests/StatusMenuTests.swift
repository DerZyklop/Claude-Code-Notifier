import AppKit
import Testing
@testable import ClaudeCodeNotifier

/// Draws the image at twice its size and returns the pixels that pass the test, with row 0 at the top. The components
/// go from 0 to 255, with the alpha already applied to the colors.
@MainActor
private func pixels(of image: NSImage, where test: (_ red: UInt8, _ green: UInt8, _ blue: UInt8, _ alpha: UInt8) -> Bool) throws -> [(x: Int, y: Int)] {
	let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * 2), pixelsHigh: Int(image.size.height * 2),
		bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
	rep.size = image.size
	NSGraphicsContext.saveGraphicsState()
	NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
	// The new bitmap can hold old memory.
	NSColor.clear.set()
	NSRect(origin: .zero, size: image.size).fill(using: .copy)
	image.draw(in: NSRect(origin: .zero, size: image.size))
	NSGraphicsContext.restoreGraphicsState()

	let data = try #require(rep.bitmapData)
	var found: [(x: Int, y: Int)] = []
	for y in 0..<rep.pixelsHigh {
		for x in 0..<rep.pixelsWide {
			let pixel = data + y * rep.bytesPerRow + x * 4
			if test(pixel[0], pixel[1], pixel[2], pixel[3]) { found.append((x, y)) }
		}
	}
	return found
}

/// The red, green, blue and alpha of the color in sRGB.
private func components(_ color: NSColor) throws -> [Double] {
	let color = try #require(color.usingColorSpace(.sRGB))
	return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
}

private func isClose(_ a: [Double], _ b: [Double]) -> Bool {
	a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 0.001 }
}

@MainActor @Suite struct StatusMenuLayoutTests {
	@Test func withoutSessionsTheWaveFillsTheIcon() {
		#expect(StatusMenu.layout(working: 0, waiting: 0) == StatusMenu.IconLayout(working: 0, waiting: 0, waveEnd: 58))
	}

	@Test func oneWorkingSessionHasNoNumber() {
		#expect(StatusMenu.layout(working: 1, waiting: 0) == StatusMenu.IconLayout(working: 1, waiting: 0, waveEnd: 58))
	}

	@Test(arguments: [2, 5, 9, 10])
	func moreWorkingSessionsGetANumberAtTheRight(working: Int) {
		let number = Spinner.countWidth(working, prefix: StatusMenu.workingPrefix)
		#expect(StatusMenu.layout(working: working, waiting: 0)
			== StatusMenu.IconLayout(working: working, waiting: 0, waveEnd: 58 - (number + 4), numberCenterX: 58 - number / 2))
	}

	@Test(arguments: [1, 3])
	func waitingSessionsGetTheBubbleAtTheRight(waiting: Int) {
		let bubble = StatusMenu.bubbleWidth
		#expect(StatusMenu.layout(working: 0, waiting: waiting)
			== StatusMenu.IconLayout(working: 0, waiting: waiting, waveEnd: 58 - bubble - 2, bubbleX: 58 - bubble))
	}

	@Test func oneWorkingSessionNextToTheBubbleHasNoNumber() {
		let bubble = StatusMenu.bubbleWidth
		#expect(StatusMenu.layout(working: 1, waiting: 1)
			== StatusMenu.IconLayout(working: 1, waiting: 1, waveEnd: 58 - bubble - 2, bubbleX: 58 - bubble))
	}

	@Test func numberGoesLeftOfTheBubble() {
		let bubble = StatusMenu.bubbleWidth
		let number = Spinner.countWidth(3, prefix: StatusMenu.workingPrefix)
		#expect(StatusMenu.layout(working: 3, waiting: 2) == StatusMenu.IconLayout(
			working: 3, waiting: 2, waveEnd: 58 - bubble - 2 - (number + 4), numberCenterX: 58 - bubble - 2 - number / 2, bubbleX: 58 - bubble))
	}

	@Test func partsKeepTheirGaps() throws {
		let layout = StatusMenu.layout(working: 4, waiting: 4)
		let number = Spinner.countWidth(4, prefix: StatusMenu.workingPrefix)
		let numberX = try #require(layout.numberCenterX)
		let bubbleX = try #require(layout.bubbleX)
		#expect(abs(numberX + number / 2 + StatusMenu.gap - bubbleX) < 0.001)
		#expect(abs(layout.waveEnd + 2 * StatusMenu.gap - (numberX - number / 2)) < 0.001)
	}

	@Test(arguments: [(9, 9), (10, 10), (11, 10), (100, 10)])
	func workingCountIsCappedAt10(working: Int, expected: Int) {
		#expect(StatusMenu.layout(working: working, waiting: 0).working == expected)
	}

	@Test(arguments: [(9, 9), (10, 10), (11, 10), (100, 10)])
	func waitingCountIsCappedAt10(waiting: Int, expected: Int) {
		#expect(StatusMenu.layout(working: 0, waiting: waiting).waiting == expected)
	}

	@Test func countsAbove10GiveTheLayoutOf10() {
		#expect(StatusMenu.layout(working: 15, waiting: 12) == StatusMenu.layout(working: 10, waiting: 10))
	}

	@Test func waveHasRoomWithTheMostContent() {
		#expect(StatusMenu.layout(working: 10, waiting: 10).waveEnd > 2 * Spinner.inset)
	}
}

@MainActor @Suite struct IconLayoutTests {
	@Test func defaultLayoutIsEmpty() {
		#expect(StatusMenu.IconLayout() == StatusMenu.IconLayout(working: 0, waiting: 0, waveEnd: 0, numberCenterX: nil, bubbleX: nil))
	}

	@Test func equalLayoutsHaveTheSameHash() {
		let a = StatusMenu.IconLayout(working: 2, waiting: 1, waveEnd: 30, numberCenterX: 40, bubbleX: 50)
		let b = StatusMenu.IconLayout(working: 2, waiting: 1, waveEnd: 30, numberCenterX: 40, bubbleX: 50)
		#expect(a == b)
		#expect(a.hashValue == b.hashValue)
		#expect(Set([a, b]).count == 1)
	}

	@Test func eachFieldMakesALayoutDifferent() {
		let layout = StatusMenu.IconLayout(working: 2, waiting: 1, waveEnd: 30, numberCenterX: 40, bubbleX: 50)
		var others = Array(repeating: layout, count: 5)
		others[0].working = 3
		others[1].waiting = 2
		others[2].waveEnd = 31
		others[3].numberCenterX = nil
		others[4].bubbleX = nil
		for other in others {
			#expect(layout != other)
		}
		#expect(Set(others + [layout]).count == 6)
	}
}

@MainActor @Suite struct StatusMenuIconTests {
	@Test func iconHasAFixedWidth() {
		#expect(StatusMenu.iconWidth == 58)
		#expect(StatusMenu.gap == 2)
	}

	@Test func bubbleWidthIsTheWidthOfTheBubble() {
		#expect(StatusMenu.bubbleWidth > 0)
		#expect(StatusMenu.bubbleWidth < StatusMenu.iconWidth)
		#expect(StatusMenu.bubbleWidth == StatusMenu.bubble(count: 1).size.width)
		#expect(StatusMenu.bubbleWidth == StatusMenu.bubble(count: 5).size.width)
	}

	@Test func textColorIsWhiteInDarkMode() throws {
		#expect(isClose(try components(StatusMenu.textColor(isDark: true)), [1, 1, 1, 1]))
	}

	@Test func textColorIsAlmostBlackInLightMode() throws {
		#expect(isClose(try components(StatusMenu.textColor(isDark: false)), [0, 0, 0, 0.85]))
	}

	@Test(arguments: [1, 5])
	func bubbleHeightCentersTheBodyOfTheSymbol(count: Int) throws {
		let configuration = NSImage.SymbolConfiguration(pointSize: NSFont.menuBarFont(ofSize: 0).pointSize + 4, weight: .regular)
			.applying(NSImage.SymbolConfiguration(paletteColors: [.systemOrange]))
		let symbol = try #require(NSImage(systemSymbolName: "bubble.left.fill", accessibilityDescription: nil)?.withSymbolConfiguration(configuration))
		let bubble = StatusMenu.bubble(count: count)
		#expect(bubble.size == NSSize(width: symbol.size.width, height: (symbol.size.height * 0.58 * 2).rounded(.up)))
		#expect(bubble.size.height > symbol.size.height)
	}

	@Test(arguments: [1, 5])
	func bubbleIsNotEmpty(count: Int) throws {
		let bubble = StatusMenu.bubble(count: count)
		let visible = try pixels(of: bubble) { _, _, _, alpha in alpha > 0 }.count
		#expect(bubble.size.width > 0 && bubble.size.height > 0)
		#expect(visible > 0)
	}

	@Test func oneWaitingSessionGetsNoNumber() throws {
		// The bubble is orange, which has no blue. Only the white number has.
		let white = try pixels(of: StatusMenu.bubble(count: 1)) { _, _, blue, _ in blue > 200 }.count
		#expect(white == 0)
	}

	@Test func moreWaitingSessionsGetAWhiteNumber() throws {
		let white = try pixels(of: StatusMenu.bubble(count: 5)) { _, _, blue, _ in blue > 200 }.count
		#expect(white > 0)
	}

	@Test(arguments: [2, 5, 10])
	func numberSitsInTheMiddleOfTheImage(count: Int) throws {
		// The middle of the body is the middle of the image, so the number lines up with the wave.
		let bubble = StatusMenu.bubble(count: count)
		let white = try pixels(of: bubble) { _, _, blue, _ in blue > 200 }
		let left = try #require(white.map(\.x).min()), right = try #require(white.map(\.x).max())
		let top = try #require(white.map(\.y).min()), bottom = try #require(white.map(\.y).max())
		// From pixels at twice the size to points.
		#expect(abs(Double(left + right + 1) / 4 - bubble.size.width / 2) < 1)
		#expect(abs(Double(top + bottom + 1) / 4 - bubble.size.height / 2) < 1)
	}

	@Test func symbolIsATemplateImage() throws {
		let image = try #require(StatusMenu.symbol("gearshape"))
		#expect(image.isTemplate)
	}

	@Test func unknownSymbolIsNil() {
		#expect(StatusMenu.symbol("no.such.symbol.name") == nil)
	}
}
