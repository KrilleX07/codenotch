import Foundation

/// Watches Devin Manager's selected Desktop profile without polling the
/// network. The usage schedule can be five minutes apart while nothing is
/// running; the account itself is local state, so a switch is noticed on this
/// short timer and the old account's reading is discarded before the refresh.
@MainActor
final class DevinManagerMonitor {
    private let locator: DevinManagerLocator
    private let standardStore: URL
    private let interval: TimeInterval
    private let onChange: @MainActor () -> Void
    private var timer: Timer?
    private var identity: String?

    init(locator: DevinManagerLocator = .live,
         standardStore: URL = DevinCredentials.storeURL,
         interval: TimeInterval = 5,
         onChange: @escaping @MainActor () -> Void) {
        self.locator = locator
        self.standardStore = standardStore
        self.interval = interval
        self.onChange = onChange
    }

    func start() {
        guard timer == nil else { return }
        identity = currentIdentity()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// The identity is deliberately the profile, not the quota: a quota write
    /// in `profiles.json` must not clear a good reading, while a switch to a
    /// profile with no email still must.
    static func identity(for selection: DevinManagerLocator.Selection?) -> String? {
        guard let selection else { return nil }
        let email = DevinManagerLocator.Selection.normalized(selection.email) ?? ""
        return [selection.profileID.uuidString, email].joined(separator: "|")
    }

    private func currentIdentity() -> String? {
        Self.identity(for: locator.activeDesktopSelection(standardStore: standardStore))
    }

    private func check() {
        let current = currentIdentity()
        guard current != identity else { return }
        identity = current
        onChange()
    }

    func checkForTesting() {
        check()
    }
}
