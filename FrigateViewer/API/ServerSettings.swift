import Foundation
import Observation
import Security

/// Connection settings, persisted in UserDefaults (password in the Keychain).
@Observable
final class ServerSettings {
    var serverURL: String { didSet { defaults.set(serverURL, forKey: Keys.url) } }
    var username: String { didSet { defaults.set(username, forKey: Keys.user) } }
    var password: String { didSet { Keychain.set(password, for: Keys.password) } }
    var allowSelfSignedCertificates: Bool { didSet { defaults.set(allowSelfSignedCertificates, forKey: Keys.selfSigned) } }
    var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) } }
    /// User-chosen camera order. Cameras not listed here go after, A–Z.
    var cameraOrder: [String] { didSet { defaults.set(cameraOrder, forKey: Keys.cameraOrder) } }
    /// Event labels (like "car") left off the timeline and its event list.
    var hiddenEventLabels: Set<String> {
        didSet { defaults.set(hiddenEventLabels.sorted(), forKey: Keys.hiddenEventLabels) }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let url = "serverURL"
        static let user = "username"
        static let password = "frigate.password"
        static let selfSigned = "allowSelfSigned"
        static let cameraOrder = "cameraOrder"
        static let appearance = "appearance"
        static let hiddenEventLabels = "hiddenEventLabels"
    }

    enum Appearance: String, CaseIterable, Identifiable {
        case auto, light, dark
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: "Auto"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
    }

    init() {
        serverURL = defaults.string(forKey: Keys.url) ?? ""
        username = defaults.string(forKey: Keys.user) ?? ""
        password = Keychain.get(Keys.password) ?? ""
        allowSelfSignedCertificates = defaults.bool(forKey: Keys.selfSigned)
        cameraOrder = defaults.stringArray(forKey: Keys.cameraOrder) ?? []
        hiddenEventLabels = Set(defaults.stringArray(forKey: Keys.hiddenEventLabels) ?? [])
        appearance = Appearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .auto
    }

    /// Sorts camera names by the saved order; unknown cameras go last, alphabetically.
    func ordered(_ names: [String]) -> [String] {
        let rank = Dictionary(cameraOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return names.sorted { a, b in
            switch (rank[a], rank[b]) {
            case let (ra?, rb?): ra < rb
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): a < b
            }
        }
    }

    var isConfigured: Bool { baseURL != nil }
    var usesAuthentication: Bool { !username.isEmpty }

    /// Normalized base URL. Adds `http://` if no scheme was typed and strips a trailing slash.
    var baseURL: URL? {
        var text = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.host != nil else { return nil }
        return url
    }
}

enum Keychain {
    static func set(_ value: String, for key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
