import Foundation
import SQLite3

/// The session Devin keeps for itself — the active Devin Manager Desktop
/// profile when one is selected, otherwise Devin Desktop's SQLite store first
/// and the CLI's `credentials.toml` if that store is missing or has no sign-in.
///
/// Codenotch only ever reads it, the same bargain as Cursor and Claude Code:
/// the owning tool mints and refreshes it, we borrow the current value. These
/// stores hold the same kind of session token and answer the same
/// GetUserStatus call — the CLI path is only a fallback so the notch works on
/// a machine that has never had the Desktop app.
struct DevinCredentials {
    let apiKey: String
    let email: String?
    let source: String

    init(apiKey: String, email: String?, source: String = "Devin Desktop") {
        self.apiKey = apiKey
        self.email = email
        self.source = source
    }

    /// Devin Desktop (formerly Windsurf) keeps its auth in the app's own
    /// global-storage database, at `ItemTable.key = "windsurfAuthStatus"`.
    static var storeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Devin/User/globalStorage/state.vscdb")
    }

    /// Devin CLI writes its credentials to a plain TOML file on `devin auth login`.
    static var cliCredentialsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/devin/credentials.toml")
    }

    /// Identity, using the same credential source as the quota fetch.
    static func account(from url: URL = storeURL,
                        fallbackCLI cli: URL = cliCredentialsURL,
                        manager: DevinManagerLocator? = nil) -> ProviderAccount? {
        guard let auth = try? load(from: url, fallbackCLI: cli, manager: manager) else { return nil }
        return ProviderAccount(
            label: auth.email,
            plan: nil,
            source: auth.source,
            manageURL: URL(string: "https://app.devin.ai")
        )
    }

    /// True when any source exists — a selected Devin Manager profile, the
    /// standard Desktop database, or the CLI file.
    static func anySourceExists(desktop url: URL = storeURL,
                                cli: URL = cliCredentialsURL,
                                manager: DevinManagerLocator? = nil) -> Bool {
        if manager?.activeDesktopSelection(standardStore: url) != nil { return true }
        return FileManager.default.fileExists(atPath: url.path)
            || FileManager.default.fileExists(atPath: cli.path)
    }

    /// Open Devin Desktop when it is installed; otherwise name the CLI command.
    static func signInRoute(desktopInstalled: Bool) -> SignInRoute {
        if desktopInstalled {
            return .openApp(bundleID: "com.exafunction.windsurf", name: "Devin")
        }
        return .guidance(L10n.t("Run `devin auth login` in a terminal to sign in."))
    }

    /// Devin Manager's selected profile first when it exists. That choice is
    /// deliberately strict: a missing or signed-out managed profile must not
    /// fall through to the standard Desktop database or CLI file, because both
    /// can belong to another account. Without a manager selection the legacy
    /// order remains Desktop first, CLI second. Re-read on every call so a
    /// sign-in, switch, or token rotation takes effect without a restart.
    static func load(from url: URL = storeURL,
                     fallbackCLI cli: URL = cliCredentialsURL,
                     manager: DevinManagerLocator? = nil) throws -> DevinCredentials {
        if let selection = manager?.activeDesktopSelection(standardStore: url) {
            return try loadManaged(selection, fallbackCLI: cli)
        }
        if let auth = try? load(fromDatabase: url) { return auth }
        return try load(fromCLI: cli)
    }

    /// The active managed profile's own Desktop stores. The manager already
    /// knows the account email; use it only to reject a positive mismatch and
    /// to fill the label when that database does not carry the address itself.
    private static func loadManaged(_ selection: DevinManagerLocator.Selection,
                                    fallbackCLI cli: URL) throws -> DevinCredentials {
        for database in selection.databases {
            guard let auth = try? load(fromDatabase: database),
                  selection.allows(email: auth.email)
            else { continue }
            return DevinCredentials(
                apiKey: auth.apiKey,
                email: auth.email ?? selection.email,
                source: "Devin Manager"
            )
        }
        // The standard profile owns the shared CLI session too, so the old
        // fallback remains valid there. For an isolated profile that shared
        // file can belong to another account unless Devin Manager has just
        // synchronized it, and reading it would be a cross-account guess.
        if selection.usesStandardSessions,
           let auth = try? load(fromCLI: cli) {
            return DevinCredentials(
                apiKey: auth.apiKey,
                email: selection.email,
                source: auth.source
            )
        }
        throw UsageProviderError.needsAuth
    }

    /// Desktop store only. Tests, and the combined loader above, pin the path
    /// so a missing Desktop app cannot silently become a live CLI read.
    static func load(fromDatabase url: URL) throws -> DevinCredentials {
        guard let db = SQLiteStore.open(url) else { throw UsageProviderError.needsAuth }
        defer { sqlite3_close(db) }
        guard let json = SQLiteStore.rows(
            in: db, sql: "SELECT value FROM ItemTable WHERE key = ?", bind: "windsurfAuthStatus"
        ).first else { throw UsageProviderError.needsAuth }

        struct Row: Decodable {
            let apiKey: String
            let email: String?
        }
        guard let row = try? JSONDecoder().decode(Row.self, from: Data(json.utf8)),
              !row.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw UsageProviderError.needsAuth }
        return DevinCredentials(apiKey: row.apiKey, email: row.email ?? lastLoginEmail(in: db))
    }

    /// `windsurfAuthStatus` carries no address; the sign-in extension keeps it
    /// in `codeium.windsurf-auth` as `lastLoginEmail`.
    private static func lastLoginEmail(in db: OpaquePointer) -> String? {
        struct Row: Decodable { let lastLoginEmail: String? }
        guard let json = SQLiteStore.rows(
            in: db, sql: "SELECT value FROM ItemTable WHERE key = ?", bind: "codeium.windsurf-auth"
        ).first,
              let email = (try? JSONDecoder().decode(Row.self, from: Data(json.utf8)))?.lastLoginEmail?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty
        else { return nil }
        return email
    }

    /// The CLI's `credentials.toml`. The file is simple enough that a TOML
    /// parser is not warranted — only `windsurf_api_key` is needed.
    static func load(fromCLI url: URL) throws -> DevinCredentials {
        guard let content = try? String(contentsOf: url, encoding: .utf8),
              let line = content.split(separator: "\n")
                  .first(where: { $0.hasPrefix("windsurf_api_key") }),
              let value = line.split(separator: "\"").dropFirst().first
        else { throw UsageProviderError.needsAuth }
        let apiKey = String(value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw UsageProviderError.needsAuth }
        return DevinCredentials(apiKey: apiKey, email: nil, source: "Devin CLI")
    }
}
