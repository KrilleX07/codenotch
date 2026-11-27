import Foundation

/// Finds the Devin Desktop profile currently selected by Devin Manager.
///
/// Devin Manager keeps every extra Desktop login in its own `--user-data-dir`
/// below `~/.devin-manager`. Reading only the standard Devin directory then
/// reports whichever account happened to use that directory, not the account
/// the user switched to. The manager's persisted selection is the narrow
/// source of truth for which of those directories is active.
struct DevinManagerLocator: Sendable {
    static let suiteName = "local.devin.manager"
    static let currentProfileKey = "currentDesktopProfile"

    let folder: URL
    let currentProfileID: @Sendable () -> String?

    static var live: Self {
        Self(folder: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".devin-manager", isDirectory: true)) {
            UserDefaults(suiteName: Self.suiteName)?.string(forKey: Self.currentProfileKey)
        }
    }

    init(folder: URL, currentProfileID: @escaping @Sendable () -> String?) {
        self.folder = folder
        self.currentProfileID = currentProfileID
    }

    struct Selection: Sendable {
        let profileID: UUID
        let email: String?
        let usesStandardSessions: Bool
        let databases: [URL]

        /// Reject only a positive mismatch. Some Desktop databases carry no
        /// email at all, and their profile directory is still stronger evidence
        /// than the absence of an address.
        func allows(email actual: String?) -> Bool {
            guard let expected = Self.normalized(email) else { return true }
            guard let found = Self.normalized(actual) else { return true }
            return expected == found
        }

        static func normalized(_ email: String?) -> String? {
            let value = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return value?.isEmpty == false ? value : nil
        }
    }

    /// The Desktop databases that may hold the selected profile, in preference
    /// order. A non-standard profile deliberately does *not* include the
    /// standard Devin store: that store is usually another account, and using
    /// it as a fallback recreates the cross-account reading this type exists
    /// to prevent.
    func activeDesktopSelection(standardStore: URL) -> Selection? {
        guard let list = loadProfiles(),
              let profile = activeProfile(in: list)
        else { return nil }

        var databases: [URL] = []
        if profile.usesStandard {
            databases.append(standardStore)
        }
        for id in profile.dataFolderIDs {
            databases.append(databaseURL(profileID: id))
        }

        var unique: [URL] = []
        for database in databases where !unique.contains(where: { $0.path == database.path }) {
            unique.append(database)
        }
        return Selection(
            profileID: profile.id,
            email: profile.email,
            usesStandardSessions: profile.usesStandard,
            databases: unique
        )
    }

    /// Devin Manager derives its directory by base64-encoding the UUID's raw
    /// bytes, then making the result URL-safe. The exact spelling matters:
    /// `UUID.uuidString` is not the directory name.
    static func profileFolderName(for id: UUID) -> String {
        var bytes = id.uuid
        return withUnsafeBytes(of: &bytes) { Data($0).base64EncodedString() }
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    private func databaseURL(profileID: UUID) -> URL {
        folder
            .appendingPathComponent(Self.profileFolderName(for: profileID), isDirectory: true)
            .appendingPathComponent("Desktop", isDirectory: true)
            .appendingPathComponent("User", isDirectory: true)
            .appendingPathComponent("globalStorage", isDirectory: true)
            .appendingPathComponent("state.vscdb")
    }

    private func activeProfile(in list: StoredList) -> StoredProfile? {
        let available = list.profiles.filter { !$0.isArchived }
        if let id = currentProfileID().flatMap(UUID.init(uuidString:)),
           let match = available.first(where: { $0.matches(id) }) {
            return match
        }
        guard let launch = list.lastLaunch,
              launch.target == "desktop" || launch.target == "switchDesktop"
        else { return nil }
        return available.first { $0.matches(launch.profileID) }
    }

    private func loadProfiles() -> StoredList? {
        let url = folder.appendingPathComponent("profiles.json")
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode(StoredList.self, from: data),
              list.version == 1
        else { return nil }
        return list
    }

    private struct StoredList: Decodable {
        let version: Int?
        let profiles: [StoredProfile]
        let lastLaunch: StoredLaunch?
    }

    private struct StoredLaunch: Decodable {
        let profileID: UUID
        let target: String
    }

    private struct StoredProfile: Decodable {
        let id: UUID
        let email: String?
        let usesStandardSessions: Bool?
        let archived: Bool?
        let mergedProfileIDs: [UUID]?
        let cliSessionID: UUID?

        var usesStandard: Bool { usesStandardSessions ?? false }
        var isArchived: Bool { archived ?? false }

        var dataFolderIDs: [UUID] {
            var ids = [id] + (mergedProfileIDs ?? [])
            if let cliSessionID { ids.append(cliSessionID) }
            var unique: [UUID] = []
            for id in ids where !unique.contains(id) { unique.append(id) }
            return unique
        }

        func matches(_ other: UUID) -> Bool {
            id == other || mergedProfileIDs?.contains(other) == true
        }
    }
}
