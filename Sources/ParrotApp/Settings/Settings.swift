import Foundation
import ParrotCore

/// Every persistent preference, stored as `Paths.settingsFile`.
///
/// One field per feature, each a struct declared in that feature's folder.
/// A missing key decodes to its default, so a file written by an older
/// version, or `{}`, still loads. `SettingsStore` reads and writes it.
///
/// Feature structs follow the same rule: give every field a default and
/// decode it with `decodeIfPresent(…) ?? default` in `init(from:)`.
struct Settings: Codable, Equatable {
    var hotkey = HotkeySettings()
    var dictionary = DictionarySettings()
    var language = LanguageSettings()
    var model = ModelSettings()
    var audio = AudioSettings()
    var stats = StatsSettings()
    var mute = MuteSettings()
    var delivery = DeliverySettings()
    var onboarding = OnboardingSettings()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hotkey = try c.decodeIfPresent(HotkeySettings.self, forKey: .hotkey) ?? HotkeySettings()
        dictionary = try c.decodeIfPresent(DictionarySettings.self, forKey: .dictionary) ?? DictionarySettings()
        language = try c.decodeIfPresent(LanguageSettings.self, forKey: .language) ?? LanguageSettings()
        model = try c.decodeIfPresent(ModelSettings.self, forKey: .model) ?? ModelSettings()
        audio = try c.decodeIfPresent(AudioSettings.self, forKey: .audio) ?? AudioSettings()
        stats = try c.decodeIfPresent(StatsSettings.self, forKey: .stats) ?? StatsSettings()
        mute = try c.decodeIfPresent(MuteSettings.self, forKey: .mute) ?? MuteSettings()
        delivery = try c.decodeIfPresent(DeliverySettings.self, forKey: .delivery) ?? DeliverySettings()
        onboarding = try c.decodeIfPresent(OnboardingSettings.self, forKey: .onboarding) ?? OnboardingSettings()
    }
}
