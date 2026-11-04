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

	var mapping: LightMapping { LightMapping(defaults: defaults) }

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

	func area(_ area: LightArea, of signal: LightSignal) -> Binding<Bool> {
		Binding(get: { self.mapping.areas(of: signal).contains(area) }, set: { isOn in
			self.objectWillChange.send()
			let areas = self.mapping.areas(of: signal).filter { $0 != area }
			self.mapping.setAreas(isOn ? areas + [area] : areas, of: signal)
		})
	}

	/// - Parameter weekday: The weekday of `Calendar`: 1 is Sunday.
	func weekday(_ weekday: Int, of kind: Report.Kind) -> Binding<Bool> {
		Binding(get: { kind.schedule(in: self.defaults).weekdays.contains(weekday) }, set: { isOn in
			self.objectWillChange.send()
			var schedule = kind.schedule(in: self.defaults)
			if isOn { schedule.weekdays.insert(weekday) } else { schedule.weekdays.remove(weekday) }
			kind.setSchedule(schedule, in: self.defaults)
		})
	}

	/// The time of today with the hour and the minute of the schedule.
	func time(of kind: Report.Kind) -> Binding<Date> {
		Binding(get: {
			let schedule = kind.schedule(in: self.defaults)
			return Calendar.current.date(bySettingHour: schedule.hour, minute: schedule.minute, second: 0, of: Date()) ?? Date()
		}, set: { date in
			self.objectWillChange.send()
			var schedule = kind.schedule(in: self.defaults)
			(schedule.hour, schedule.minute) = (Calendar.current.component(.hour, from: date), Calendar.current.component(.minute, from: date))
			kind.setSchedule(schedule, in: self.defaults)
		})
	}

	func brightness(of signal: LightSignal) -> Binding<Double> {
		Binding(get: { self.mapping.brightness(of: signal) }, set: { value in
			self.objectWillChange.send()
			self.mapping.setBrightness(value, of: signal)
		})
	}
}

/// The tab »Outputs« of the setup window: which outputs show the state, and how the lights show it. The areas and the
/// brightness of each signal apply to both lights. Each signal has a switch that simulates it in the menu bar, on the
/// blink(1) and on the keyboard.
struct OutputsView: View {
	@EnvironmentObject private var settings: SettingsStore
	@EnvironmentObject private var simulation: LightSimulation
	@EnvironmentObject private var setup: HookSetup

	var body: some View {
		let usesBlink1 = SettingsKey.isOn(SettingsKey.usesBlink1, in: settings.defaults)
		let usesLights = usesBlink1 || SettingsKey.isOn(SettingsKey.usesKeyboard, in: settings.defaults)
		Form {
			Section("Lights") {
				Toggle("blink(1)", isOn: settings.binding(SettingsKey.usesBlink1))
				Toggle("Blink When a Session or a Report Ends", isOn: settings.binding(SettingsKey.blinksAtEnd))
					.padding(.leading, 16)
					.disabled(!usesBlink1)
				Toggle("Keyboard", isOn: settings.binding(SettingsKey.usesKeyboard))
				Toggle(isOn: settings.binding(SettingsKey.showsSessionsOnKeyboard)) {
					Text("Sessions on the Letter Keys")
					Text("Each session lights its letter key. A session without activity for 5 hours stays dark.")
				}
					.padding(.leading, 16)
					.disabled(!SettingsKey.isOn(SettingsKey.usesKeyboard, in: settings.defaults))
				Toggle(isOn: settings.binding(SettingsKey.usesMacBookBacklight)) {
					Text("MacBook Keyboard Backlight")
					Text("Blinks while sessions work or a report runs. At all other times, macOS controls the backlight.")
				}
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
				ForEach(LightSignal.allCases, id: \.self) { signal in
					signalRow(signal, isEnabled: usesLights)
				}
			} header: {
				Text("Signals")
			} footer: {
				Text("Each area has its LEDs on the keyboard and on the blink(1). Where the areas of two signals overlap, the upper one wins. A blink(1) LED without a signal shows the other LED. Simulate shows a signal in the menu bar and on the lights while this tab is open.")
					.font(.caption).foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
		.formStyle(.grouped)
		.frame(width: 600, height: 640)
	}

	private func signalRow(_ signal: LightSignal, isEnabled: Bool) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			LabeledContent(signal.title) { simulate(signal) }
			HStack(spacing: 12) {
				VStack(alignment: .leading, spacing: 2) {
					Menu(areasTitle(of: signal)) {
						ForEach(LightArea.allCases, id: \.self) { area in
							Toggle("\(area.title) · blink(1) \(area.blink1Title)", isOn: settings.area(area, of: signal))
						}
					}
					.frame(width: 240, alignment: .leading)
					Text("blink(1): \(blink1Title(of: signal))").font(.caption).foregroundStyle(.secondary)
				}
				.frame(width: 260, alignment: .leading)
				Slider(value: settings.brightness(of: signal), in: 0...1) { Text("Brightness") }
			}
			.disabled(!isEnabled)
		}
	}

	@ViewBuilder private func simulate(_ signal: LightSignal) -> some View {
		switch signal {
		case .work:
			Toggle("Simulate", isOn: $simulation.work)
		case .report:
			Toggle("Simulate", isOn: $simulation.report)
		case .waiting:
			Toggle("Simulate", isOn: $simulation.waiting)
		case .ring:
			// The bubble always rings, so the simulation of »Waiting« shows the ring too.
			Text("Rings with Waiting").foregroundStyle(.secondary)
		case .unread:
			Toggle("Simulate", isOn: $simulation.unread)
		}
	}

	private func areasTitle(of signal: LightSignal) -> String {
		let areas = settings.mapping.areas(of: signal)
		return areas.isEmpty ? "No Keys" : areas.map(\.title).joined(separator: ", ")
	}

	private func blink1Title(of signal: LightSignal) -> String {
		switch Set(settings.mapping.areas(of: signal).flatMap(\.blink1LEDs)) {
		case []: "No LED"
		case [1]: "LED 1"
		case [2]: "LED 2"
		default: "Both LEDs"
		}
	}
}

/// The tab »Schedules« of the setup window: the automatic run of each report, its weekdays and its time.
struct SchedulesView: View {
	@EnvironmentObject private var settings: SettingsStore

	/// Monday first.
	private static let weekdays = [2, 3, 4, 5, 6, 7, 1]

	var body: some View {
		Form {
			ForEach(Report.all.map(\.kind), id: \.settingsKey) { kind in
				Section(kind.title) {
					Toggle("Automatic Update", isOn: settings.binding(kind.settingsKey))
					LabeledContent("Weekdays") {
						HStack {
							ForEach(Self.weekdays, id: \.self) { weekday in
								Toggle(Calendar.current.shortWeekdaySymbols[weekday - 1], isOn: settings.weekday(weekday, of: kind))
									.toggleStyle(.checkbox)
							}
						}
					}
					DatePicker("Time", selection: settings.time(of: kind), displayedComponents: .hourAndMinute)
				}
			}
		}
		.formStyle(.grouped)
		.frame(width: 600, height: 640)
	}
}
