import Foundation

struct SavedLocation: Codable, Equatable {
    var id = UUID()
    var name: String
    var connection: ConnectionProfile

    static func load(key: String = "savedLocations", from defaults: UserDefaults = .standard) -> [SavedLocation] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SavedLocation].self, from: data)) ?? []
    }

    static func save(_ locations: [SavedLocation], key: String = "savedLocations", to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(locations) { defaults.set(data, forKey: key) }
    }
}

// Match path components, so renaming /data/a never changes /data/abc.
func replacingRemotePath(_ path: String, from old: String, to new: String) -> String {
    if path == old { return new }
    if path.hasPrefix(old + "/") { return new + path.dropFirst(old.count) }
    return path
}
