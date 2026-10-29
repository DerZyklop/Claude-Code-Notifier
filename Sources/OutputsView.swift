import Combine
import SwiftUI

/// The settings of the app as bindings for the setup window. The view updates also when the menu changes a setting.
@MainActor
final class SettingsStore: ObservableObject {
	static let shared = SettingsStore()

	let defaults: UserDefaults
	private var subscription: AnyCancellable?

	init(defaults: UserDefaults = .standard) {
		self.defaults = defaults
		subscription = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
			.receive(on: DispatchQueue.main)
			.sink { [weak self] _ in self?.objectWillChange.send() }
	}

	var mapping: KeyboardMapping { KeyboardMapping(defaults: defaults) }

	/// - Parameter isInverted: Is on while the setting is off.
	func binding(_ key: String, isInverted: Bool = false) -> Binding<Bool> {
		Binding(get: { SettingsKey.isOn(key, in: self.defaults) != isInverted }, set: { value in
			self.objectWillChange.send()
			SettingsKey.set(key, to: value != isInverted, in: self.defaults)
		})
	}

	var soundMode: Binding<SoundMode> {
		Binding(get: { SoundMode.current(in: self.defaults) }, set: { mode in
			self.objectWillChange.send()
			mode.store(in: self.defaults)
		})
	}

	func area(_ area: KeyArea, of signal: KeySignal) -> Binding<Bool> {
		Binding(get: { self.mapping.areas(of: signal).contains(area) }, set: { isOn in
			self.objectWillChange.send()
			let areas = self.mapping.areas(of: signal).filter { $0 != area }
			self.mapping.setAreas(isOn ? areas + [area] : areas, of: signal)
		})
	}

	func brightness(of signal: KeySignal) -> Binding<Double> {
		Binding(get: { self.mapping.brightness(of: signal) }, set: { value in
			self.objectWillChange.send()
			self.mapping.setBrightness(value, of: signal)
		})
	}
}

/// The tab »Outputs« of the setup window: which outputs show the state, and how the keyboard shows it. Each signal of
/// the keyboard has a switch that simulates it in the menu bar, on the blink(1) and on the keyboard.
struct OutputsView: View {
	@EnvironmentObject private var settings: SettingsStore
	@EnvironmentObject private var simulation: LightSimulation
	@EnvironmentObject private var setup: HookSetup

	var body: some View {
		let usesKeyboard = SettingsKey.isOn(SettingsKey.usesKeyboard, in: settings.defaults)
		let notifies = !SettingsKey.isOn(SettingsKey.muted, in: settings.defaults)
		Form {
			Section {
				Toggle("blink(1)", isOn: settings.binding(SettingsKey.usesBlink1))
			}
			Section {
				LabeledContent("Push Notifications") {
					HStack {
						Menu("Send Test") {
							ForEach(NotificationKind.allCases, id: \.self) { kind in
								Button(kind.subtitle) { SessionStore.shared.sendTestNotification(kind) }
							}
						}
						.fixedSize()
						.disabled(setup.notificationsAllowed != true)
						Toggle("Push Notifications", isOn: settings.binding(SettingsKey.muted, isInverted: true)).labelsHidden()
					}
				}
				Toggle("When It Is Your Turn", isOn: settings.binding(SettingsKey.notifyOnDone))
					.padding(.leading, 16)
					.disabled(!notifies)
			}
			Section {
				LabeledContent("Sound") {
					HStack {
						Button("Play") { AttentionBubble.playChimeSound() }
						Picker("Sound", selection: settings.soundMode) {
							ForEach(SoundMode.allCases, id: \.self) { Text($0.title).tag($0) }
						}
						.labelsHidden()
						.fixedSize()
					}
				}
			}
			Section {
				Toggle("Keyboard", isOn: settings.binding(SettingsKey.usesKeyboard))
				ForEach(KeySignal.allCases, id: \.self) { signal in
					signalRow(signal, isEnabled: usesKeyboard)
				}
			} footer: {
				Text("Where the areas of two signals overlap, the upper one wins. Simulate shows a signal in the menu bar, on the blink(1) and on the keyboard while this tab is open.")
					.font(.caption).foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
		.formStyle(.grouped)
		.frame(width: 600, height: 640)
	}

	private func signalRow(_ signal: KeySignal, isEnabled: Bool) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			LabeledContent(signal.title) { simulate(signal) }
			HStack(spacing: 12) {
				Menu(areasTitle(of: signal)) {
					ForEach(KeyArea.allCases, id: \.self) { area in
						Toggle(area.title, isOn: settings.area(area, of: signal))
					}
				}
				.frame(width: 260)
				Slider(value: settings.brightness(of: signal), in: 0...1) { Text("Brightness") }
			}
			.disabled(!isEnabled)
		}
	}

	@ViewBuilder private func simulate(_ signal: KeySignal) -> some View {
		switch signal {
		case .work:
			Picker("Simulate", selection: $simulation.work) {
				Text("Off").tag(Blink1.Wave.off)
				Text("Work").tag(Blink1.Wave.work)
				Text("Summary").tag(Blink1.Wave.report)
			}
			.pickerStyle(.segmented)
			.fixedSize()
		case .waiting:
			Toggle("Simulate", isOn: $simulation.waiting)
		case .ring:
			// The bubble always rings, so the simulation of »Waiting« shows the ring too.
			Text("Rings with Waiting").foregroundStyle(.secondary)
		case .unread:
			Toggle("Simulate", isOn: $simulation.unread)
		}
	}

	private func areasTitle(of signal: KeySignal) -> String {
		let areas = settings.mapping.areas(of: signal)
		return areas.isEmpty ? "No Keys" : areas.map(\.title).joined(separator: ", ")
	}
}
