import Foundation

final class SettingsStore: @unchecked Sendable {
    static let shared = SettingsStore()

    private let defaults: UserDefaults
    private let configKey = "ollamaGuardianConfig"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> GuardianConfig {
        guard let data = defaults.data(forKey: configKey),
              let config = try? decoder.decode(GuardianConfig.self, from: data) else {
            return .default
        }
        return config
    }

    func save(_ config: GuardianConfig) throws {
        let data = try encoder.encode(config)
        defaults.set(data, forKey: configKey)
    }
}
