import Foundation

/// Reads Devin usage using the session owned by Devin Desktop or Devin CLI.
///
/// The cached quota in the Desktop database can lag behind the account, so
/// each refresh asks GetUserStatus instead. The session is read-only:
/// whichever tool owns sign-in and token rotation, Codenotch never refreshes
/// or writes its token.
actor DevinLocalProvider: UsageProvider {
    nonisolated let id = "devin"
    nonisolated let displayName = "Devin"
    nonisolated let glyph = ProviderGlyph.devin

    nonisolated private let store: URL
    nonisolated private let cliCredentials: URL
    nonisolated private let accountManager: DevinManagerLocator?
    private let session: URLSession
    private var retryNoEarlierThan: Date?
    private var rateLimitedAccount: String?

    init(database: URL = DevinCredentials.storeURL,
         cliCredentials: URL = DevinCredentials.cliCredentialsURL,
         session: URLSession = URLSession(configuration: .ephemeral,
                                          delegate: DevinRedirectPolicy(), delegateQueue: nil),
         accountManager: DevinManagerLocator? = nil) {
        self.store = database
        self.cliCredentials = cliCredentials
        let systemStores = database.path == DevinCredentials.storeURL.path
            && cliCredentials.path == DevinCredentials.cliCredentialsURL.path
        self.accountManager = accountManager ?? (systemStores ? .live : nil)
        self.session = session
    }

    nonisolated var isVisibleWhenAbsent: Bool {
        DevinCredentials.anySourceExists(desktop: store, cli: cliCredentials, manager: accountManager)
    }

    nonisolated var signInRoute: SignInRoute {
        if accountManager?.activeDesktopSelection(standardStore: store) != nil {
            return .openApp(bundleID: DevinManagerLocator.suiteName, name: "Devin Manager")
        }
        return DevinCredentials.signInRoute(
            desktopInstalled: FileManager.default.fileExists(atPath: store.path))
    }

    nonisolated func account() -> ProviderAccount? {
        DevinCredentials.account(from: store, fallbackCLI: cliCredentials, manager: accountManager)
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        let auth = try DevinCredentials.load(from: store, fallbackCLI: cliCredentials, manager: accountManager)
        // A 429 belongs to the account that received it, not to the provider
        // adapter. Devin Manager can put another login in front of the same
        // actor, and that login must not inherit the previous one's cool-down.
        let accountKey = DevinManagerLocator.Selection.normalized(auth.email) ?? auth.apiKey
        if rateLimitedAccount != accountKey {
            retryNoEarlierThan = nil
            rateLimitedAccount = nil
        }
        if let retryNoEarlierThan, retryNoEarlierThan > Date() {
            throw UsageProviderError.rateLimited(retryAfter: retryNoEarlierThan.timeIntervalSinceNow)
        }
        var request = URLRequest(
            url: URL(string: "https://server.self-serve.windsurf.com/exa.seat_management_pb.SeatManagementService/GetUserStatus")!,
            cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "metadata": ["apiKey": auth.apiKey, "ideName": "windsurf", "ideVersion": "1.108.2",
                         "extensionName": "windsurf", "extensionVersion": "1.108.2", "locale": "en"]
        ])
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 401 { throw UsageProviderError.needsAuth }
        if status == 403 { throw UsageProviderError.accessDenied }
        if status == 429 {
            let hint = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 60
            let delay = hint.isFinite ? max(60, hint) : 60
            retryNoEarlierThan = Date().addingTimeInterval(delay)
            rateLimitedAccount = accountKey
            throw UsageProviderError.rateLimited(retryAfter: delay)
        }
        guard (200..<300).contains(status) else { throw UsageProviderError.badResponse(status: status) }
        let windows = try DevinUsage.windows(fromJSON: String(decoding: data, as: UTF8.self))
        retryNoEarlierThan = nil
        rateLimitedAccount = nil
        return ProviderSnapshot(
            id: id, displayName: displayName, glyph: glyph,
            fidelity: .official, status: .ok, windows: windows,
            headlineID: windows.first?.id, weeklyID: nil,
            plan: auth.email
        )
    }
}

final class DevinRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
