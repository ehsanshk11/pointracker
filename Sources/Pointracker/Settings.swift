import Foundation
import PointrackerCore

/// User preferences, persisted in UserDefaults.
final class Settings {
    private let defaults = UserDefaults.standard

    private enum Key {
        static let cameraUniqueID = "cameraUniqueID"
        static let pauseOnBattery = "pauseOnBattery"
        static let learnFromClicks = "learnFromClicks"
        static let movePointer = "movePointer"
        static let dwellMilliseconds = "dwellMilliseconds"
    }

    init() {
        defaults.register(defaults: [
            Key.pauseOnBattery: true,
            Key.learnFromClicks: true,
            Key.movePointer: true,
            Key.dwellMilliseconds: 300,
        ])
    }

    /// Nil means the system default camera.
    var cameraUniqueID: String? {
        get { defaults.string(forKey: Key.cameraUniqueID) }
        set { defaults.set(newValue, forKey: Key.cameraUniqueID) }
    }

    /// Stop the camera entirely while the Mac runs on battery.
    var pauseOnBattery: Bool {
        get { defaults.bool(forKey: Key.pauseOnBattery) }
        set { defaults.set(newValue, forKey: Key.pauseOnBattery) }
    }

    /// Treat each click as a hint of which screen the user faces.
    var learnFromClicks: Bool {
        get { defaults.bool(forKey: Key.learnFromClicks) }
        set { defaults.set(newValue, forKey: Key.learnFromClicks) }
    }

    /// Bring the pointer along to the newly focused screen.
    var movePointer: Bool {
        get { defaults.bool(forKey: Key.movePointer) }
        set { defaults.set(newValue, forKey: Key.movePointer) }
    }

    var deciderConfig: DeciderConfig {
        var config = DeciderConfig()
        config.dwell = Double(max(100, defaults.integer(forKey: Key.dwellMilliseconds))) / 1000
        return config
    }
}

/// Calibration and click samples. These are head angles only, never images.
enum SampleStorage {
    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pointracker", isDirectory: true)
            .appendingPathComponent("samples.json")
    }

    static func load() -> SampleStore? {
        guard let data = try? Data(contentsOf: fileURL),
              let store = try? JSONDecoder().decode(SampleStore.self, from: data),
              store.version == SampleStore.currentVersion else { return nil }
        return store
    }

    static func save(_ store: SampleStore) {
        let url = fileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(store).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("Pointracker: could not save samples: \(error)")
        }
    }

    static func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
