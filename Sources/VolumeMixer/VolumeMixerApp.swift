import MixerCore
import SwiftUI

@MainActor
final class AppModel {
    let engine: MixerEngine
    let wheel: ScrollWheelMonitor
    private let monitor = AudioProcessMonitor()

    init() {
        // Dark only, whatever the system appearance is.
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        let describer = AppDescriber()
        let engine = MixerEngine(
            store: VolumeStore(),
            permissions: AudioCapturePermission(),
            describe: describer.describe,
            factory: { try TapVolumeController(objectIDs: $0, gain: $1) })
        self.engine = engine
        wheel = ScrollWheelMonitor(engine: engine)
        monitor.onChange = { groups in
            MainActor.assumeIsolated { engine.update(groups: groups) }
        }
        monitor.onOutputDeviceChange = {
            MainActor.assumeIsolated { engine.outputDeviceChanged() }
        }
        monitor.start()
    }
}

@main
struct VolumeMixerApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("Volume Mixer", systemImage: "slider.vertical.3") {
            MixerView(engine: model.engine, wheel: model.wheel)
        }
        .menuBarExtraStyle(.window)
    }
}
