import SQLite3
import SwiftUI
import XCTest
@testable import Codenotch

final class DevinUsageTests: XCTestCase {
    /// GetUserStatus quota shape, with synthetic values and no account data.
    private let recorded = """
    {"userStatus":{"planStatus":{
     "dailyQuotaRemainingPercent":99,"weeklyQuotaRemainingPercent":50,
     "dailyQuotaResetAtUnix":"1789113600","weeklyQuotaResetAtUnix":"1789286400",
     "overageBalanceMicros":"14277951"}}}
    """

    private func windows(_ json: String) throws -> [LimitWindow] {
        try DevinUsage.windows(fromJSON: json)
    }

    @MainActor
    func testDevinLogoIsBundledAndRendersAsAMark() throws {
        let glyph = DevinLocalProvider().glyph
        XCTAssertEqual(glyph, .devin)
        XCTAssertEqual(glyph.assetName, "glyph-devin")
        let image = try XCTUnwrap(NSImage(named: glyph.assetName))
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
        let renderer = ImageRenderer(content: ProviderGlyphView(glyph: glyph, size: 32)
            .foregroundStyle(.white))
        let data = try XCTUnwrap(renderer.nsImage?.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        var inkPixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { inkPixels += 1 }
            }
        }
        let coverage = Double(inkPixels) / Double(bitmap.pixelsWide * bitmap.pixelsHigh)
        XCTAssertGreaterThan(coverage, 0.05)
        XCTAssertLessThan(coverage, 0.85)
        XCTAssertNotNil(Bundle.main.url(forResource: "LobeIcons-LICENSE", withExtension: "txt"))
    }

    func testFormattedBalanceSurvivesArchivingWithoutChangingPlainCounts() throws {
        let old = try JSONDecoder().decode(LimitWindow.self,
            from: Data(#"{"id":"requests","label":"Requests","used":3}"#.utf8))
        XCTAssertNil(old.usedText)
        XCTAssertEqual(old.summary, "3 used")
        let balance = try XCTUnwrap(windows(recorded).last)
        let restored = try JSONDecoder().decode(LimitWindow.self,
            from: JSONEncoder().encode(balance))
        XCTAssertEqual(restored.summary, "$14.28")
    }

    func testLegacyDevinArchiveGetsNewLogoWithoutChangingReadings() throws {
        let suite = "DevinArchiveTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let archive = UsageArchive(defaults: defaults)
        let captured = Date(timeIntervalSince1970: 100)
        let windows = try windows(recorded)
        let old = ProviderSnapshot(id: "devin", displayName: "Devin", glyph: .third,
                                   fidelity: .official, status: .ok, windows: windows)
        let other = ProviderSnapshot(id: "other", displayName: "Other", glyph: .third,
                                     fidelity: .official, status: .ok, windows: [])
        archive.save(["devin": (old, captured), "other": (other, captured)])
        let restored = archive.load()
        XCTAssertEqual(restored["devin"]?.snapshot.glyph, .devin)
        XCTAssertEqual(restored["devin"]?.snapshot.windows, windows)
        XCTAssertEqual(restored["devin"]?.fetchedAt, captured)
        XCTAssertEqual(restored["devin"]?.snapshot.status, .stale(since: captured))
        XCTAssertEqual(restored["other"]?.snapshot.glyph, .third)
    }

    func testReadsLiveResponseAndFormatsBalance() throws {
        let w = try windows(recorded)
        XCTAssertEqual(w.map(\.id), ["weekly", "overage"])
        XCTAssertEqual(w[0].usedFraction, 0.50)
        XCTAssertEqual(w[0].resetsAt, Date(timeIntervalSince1970: 1789286400))
        XCTAssertEqual(w[1].usedText, "$14.28")
        XCTAssertEqual(w[1].summary, "$14.28")
    }

    func testPastResetIsNotRolledForward() throws {
        // An expired timestamp must remain expired, not disguise an old reading.
        let json = recorded.replacingOccurrences(of: "1789286400", with: "100")
        let w = try windows(json)
        XCTAssertEqual(w[0].resetsAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(try XCTUnwrap(w[0].usedFraction), 0.50, accuracy: 0.00001)
    }

    func testFractionalPercentAndNumericTimestamps() throws {
        let json = #"{"userStatus":{"planStatus":{"weeklyQuotaRemainingPercent":99.5,"weeklyQuotaResetAtUnix":1789113600}}}"#
        let w = try windows(json)
        XCTAssertEqual(try XCTUnwrap(w[0].usedFraction), 0.005, accuracy: 0.00001)
        XCTAssertEqual(w[0].resetsAt, Date(timeIntervalSince1970: 1789113600))
    }

    func testZeroBalanceIsAReading() throws {
        let w = try windows(recorded.replacingOccurrences(of: "14277951", with: "0"))
        XCTAssertEqual(w.last?.usedText, "$0.00")
    }

    func testHiddenQuotaAndMissingReset() throws {
        let json = #"{"userStatus":{"planStatus":{"dailyQuotaRemainingPercent":99,"weeklyQuotaRemainingPercent":50}}}"#
        let w = try windows(json)
        XCTAssertEqual(w.map(\.id), ["weekly"])
        XCTAssertNil(w[0].resetsAt)
        let hidden = #"{"userStatus":{"planStatus":{"hideWeeklyQuota":true,"weeklyQuotaRemainingPercent":50,"overageBalanceMicros":"0"}}}"#
        XCTAssertEqual(try windows(hidden).map(\.id), ["overage"])
    }

    func testRejectsMissingOrInvalidQuotaInsteadOfInventingZero() {
        for value in ["null", "true", "-1", "101", #""NaN""#, #""Infinity""#] {
            XCTAssertThrowsError(try windows("{\"userStatus\":{\"planStatus\":{\"weeklyQuotaRemainingPercent\":\(value)}}}"))
        }
        XCTAssertThrowsError(try windows(#"{"dailyRemainingPercent":100}"#))
        XCTAssertThrowsError(try windows(#"{"userStatus":{"planStatus":{}}}"#))
        XCTAssertThrowsError(try windows("not json"))
    }

    func testInvalidBalanceDoesNotDiscardQuotaOrTrap() throws {
        for value in ["-1", "true", "1e100", #""Infinity""#] {
            let json = recorded.replacingOccurrences(of: #""14277951""#, with: value)
            XCTAssertEqual(try windows(json).map(\.id), ["weekly"])
        }
    }

    /// The service drops *QuotaRemainingPercent at 0 (fully used) but keeps the
    /// reset timestamp. A missing percent with a reset is 100% used, not absent.
    func testMissingRemainingWithResetMeansFullyUsed() throws {
        let json = #"{"userStatus":{"planStatus":{"dailyQuotaResetAtUnix":"1789113600","weeklyQuotaResetAtUnix":"1789286400","overageBalanceMicros":"4632524"}}}"#
        let w = try windows(json)
        XCTAssertEqual(w.map(\.id), ["weekly", "overage"])
        XCTAssertEqual(try XCTUnwrap(w[0].usedFraction), 1.0)    // weekly 100% used
        XCTAssertEqual(w[0].resetsAt, Date(timeIntervalSince1970: 1789286400))
        XCTAssertEqual(w[1].usedText, "$4.63")
    }

    func testRefreshFetchesChangedUsageInsteadOfLocalCache() async throws {
        let database = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: database) }
        DevinEndpoint.reset([(200, recorded), (200, recorded.replacingOccurrences(of: "\"weeklyQuotaRemainingPercent\":50", with: "\"weeklyQuotaRemainingPercent\":49"))])
        let provider = makeProvider(database: database)
        let first = try await provider.fetchSnapshot()
        let second = try await provider.fetchSnapshot()
        XCTAssertEqual(try XCTUnwrap(first.usedFraction), 0.50, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(second.usedFraction), 0.51, accuracy: 0.00001)
        XCTAssertEqual(second.status, .ok)
        XCTAssertEqual(DevinEndpoint.requestCount, 2)
    }

    func testNetworkFailureDoesNotReturnStaleSQLiteQuotaAsOK() async throws {
        let database = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: database) }
        DevinEndpoint.reset([(200, recorded), (503, "")])
        let provider = makeProvider(database: database)
        _ = try await provider.fetchSnapshot()
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("An HTTP failure must reach UsageStore's stale-reading handling")
        } catch UsageProviderError.badResponse(let status) {
            XCTAssertEqual(status, 503)
        }
    }

    func testAuthenticationErrorsAndRateLimit() async throws {
        let database = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: database) }
        for (code, expected) in [(401, ProviderStatus.needsAuth), (403, .accessDenied)] {
            DevinEndpoint.reset([(code, "")])
            do {
                _ = try await makeProvider(database: database).fetchSnapshot()
                XCTFail("Expected authentication failure")
            } catch {
                let status = await UsageStore.statusForTesting(error)
                XCTAssertEqual(status, expected)
            }
        }
        DevinEndpoint.reset([(429, "")])
        let provider = makeProvider(database: database)
        for _ in 0..<2 {
            do {
                _ = try await provider.fetchSnapshot()
                XCTFail("Expected rate limit")
            } catch UsageProviderError.rateLimited(let delay) {
                XCTAssertGreaterThan(delay, 0)
            }
        }
        XCTAssertEqual(DevinEndpoint.requestCount, 1)
    }

    func testMissingAuthenticationDoesNotMakeNetworkRequest() async throws {
        DevinEndpoint.reset([])
        do {
            _ = try await makeProvider(database: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)).fetchSnapshot()
            XCTFail("Expected needsAuth")
        } catch UsageProviderError.needsAuth {}
        XCTAssertEqual(DevinEndpoint.requestCount, 0)
    }

    /// When the Desktop database is absent, the CLI credentials file is the
    /// fallback. A valid key there must produce a snapshot, not needsAuth.
    func testCLICredentialsAreUsedWhenDesktopDatabaseIsAbsent() async throws {
        let cli = FileManager.default.temporaryDirectory.appendingPathComponent("cli-\(UUID().uuidString).toml")
        try #"windsurf_api_key = "devin-session-token$test-key""#.write(to: cli, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: cli) }
        DevinEndpoint.reset([(200, recorded)])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DevinEndpoint.self]
        let provider = DevinLocalProvider(
            database: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            cliCredentials: cli, session: URLSession(configuration: configuration))
        let snapshot = try await provider.fetchSnapshot()
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(DevinEndpoint.requestCount, 1)
    }

    func testDevinManagerFolderNameUsesRawUUIDBytes() {
        let id = UUID(uuidString: "90A26BE2-DC30-41BD-AFB6-F4B2212AE963")!
        XCTAssertEqual(DevinManagerLocator.profileFolderName(for: id), "kKJr4twwQb2vtvSyISrpYw")
    }

    /// Switching profiles in Devin Manager must switch the credential read by
    /// the next poll; neither the token nor the account label may be cached.
    func testManagerSelectionSwitchIsRereadOnEveryLoad() throws {
        let root = try makeManagerRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstID = UUID()
        let secondID = UUID()
        let firstEmail = "first@example.com"
        let secondEmail = "second@example.com"
        try writeManagerProfiles(root: root, profiles: [
            managerProfile(id: firstID, email: firstEmail),
            managerProfile(id: secondID, email: secondEmail),
        ])
        _ = try makeManagedDatabase(root: root, id: firstID, token: "first-token", email: firstEmail)
        _ = try makeManagedDatabase(root: root, id: secondID, token: "second-token", email: secondEmail)
        let standard = try makeDatabase(token: "standard-token", email: "standard@example.com",
                                        at: root.appendingPathComponent("standard-state.vscdb"))
        let cli = root.appendingPathComponent("missing-cli.toml")
        let current = MutableString(firstID.uuidString)
        let locator = DevinManagerLocator(folder: root) { current.value }

        let first = try DevinCredentials.load(from: standard, fallbackCLI: cli, manager: locator)
        XCTAssertEqual(first.apiKey, "first-token")
        XCTAssertEqual(first.email, firstEmail)
        XCTAssertEqual(first.source, "Devin Manager")

        current.value = secondID.uuidString
        let second = try DevinCredentials.load(from: standard, fallbackCLI: cli, manager: locator)
        XCTAssertEqual(second.apiKey, "second-token")
        XCTAssertEqual(second.email, secondEmail)
    }

    /// A switch is a change of profile identity, not any write to the
    /// manager's metadata: quota refreshes in `profiles.json` must not throw
    /// away a good reading, while a different selected profile must.
    @MainActor
    func testManagerMonitorFiresOnlyWhenSelectedProfileChanges() throws {
        let root = try makeManagerRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstID = UUID()
        let secondID = UUID()
        try writeManagerProfiles(root: root, profiles: [
            managerProfile(id: firstID, email: "first@example.com"),
            managerProfile(id: secondID, email: "second@example.com"),
        ])
        let current = MutableString(firstID.uuidString)
        let locator = DevinManagerLocator(folder: root) { current.value }
        var changes = 0
        let monitor = DevinManagerMonitor(
            locator: locator,
            standardStore: root.appendingPathComponent("standard-state.vscdb"),
            interval: 60
        ) { changes += 1 }
        monitor.start()
        defer { monitor.stop() }

        try writeManagerProfiles(root: root, profiles: [
            managerProfile(id: firstID, email: "first@example.com"),
            managerProfile(id: secondID, email: "second@example.com"),
        ])
        monitor.checkForTesting()
        XCTAssertEqual(changes, 0)

        current.value = secondID.uuidString
        monitor.checkForTesting()
        XCTAssertEqual(changes, 1)
        monitor.checkForTesting()
        XCTAssertEqual(changes, 1)
    }

    /// Once Devin Manager names a non-standard active profile, falling back to
    /// the standard Desktop or shared CLI login would often mean falling back
    /// to the wrong person. A missing managed login is signed-out instead.
    func testManagedSelectionDoesNotFallBackToAnotherAccount() throws {
        let root = try makeManagerRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        try writeManagerProfiles(root: root, profiles: [managerProfile(id: id, email: "managed@example.com")])
        let standard = try makeDatabase(token: "standard-token", email: "standard@example.com",
                                        at: root.appendingPathComponent("standard-state.vscdb"))
        let cli = root.appendingPathComponent("credentials.toml")
        try #"windsurf_api_key = "cli-token""#.write(to: cli, atomically: true, encoding: .utf8)
        let locator = DevinManagerLocator(folder: root) { id.uuidString }

        XCTAssertThrowsError(try DevinCredentials.load(from: standard, fallbackCLI: cli, manager: locator)) { error in
            guard case UsageProviderError.needsAuth = error else {
                return XCTFail("Expected needsAuth, got \(error)")
            }
        }
    }

    /// The built-in standard profile owns both standard locations. Losing its
    /// Desktop database therefore does not also lose the shared CLI fallback.
    func testManagedStandardProfileKeepsSharedCLIFallback() throws {
        let root = try makeManagerRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let email = "standard@example.com"
        try writeManagerProfiles(root: root, profiles: [
            managerProfile(id: id, email: email, usesStandard: true)
        ])
        let standard = root.appendingPathComponent("missing-standard-state.vscdb")
        let cli = root.appendingPathComponent("credentials.toml")
        try #"windsurf_api_key = "standard-cli-token""#.write(to: cli, atomically: true, encoding: .utf8)
        let locator = DevinManagerLocator(folder: root) { id.uuidString }

        let auth = try DevinCredentials.load(from: standard, fallbackCLI: cli, manager: locator)
        XCTAssertEqual(auth.apiKey, "standard-cli-token")
        XCTAssertEqual(auth.email, email)
        XCTAssertEqual(auth.source, "Devin CLI")
    }

    /// The manager's current-profile preference is its freshest value, while
    /// `lastLaunch` keeps older installs and relaunches meaningful.
    func testManagerLastDesktopLaunchIsFallbackSelection() throws {
        let root = try makeManagerRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let email = "launched@example.com"
        try writeManagerProfiles(
            root: root,
            profiles: [managerProfile(id: id, email: email)],
            lastLaunch: ["profileID": id.uuidString, "target": "switchDesktop"]
        )
        _ = try makeManagedDatabase(root: root, id: id, token: "launched-token", email: email)
        let standard = try makeDatabase(at: root.appendingPathComponent("standard-state.vscdb"))
        let locator = DevinManagerLocator(folder: root) { nil }

        let auth = try DevinCredentials.load(from: standard, fallbackCLI: root.appendingPathComponent("missing.toml"),
                                             manager: locator)
        XCTAssertEqual(auth.apiKey, "launched-token")
        XCTAssertEqual(auth.email, email)
    }

    /// Duplicate cards can be merged by the manager. The stored current id may
    /// be the merged-away id, and the surviving login may live in its folder.
    func testManagerMergedProfileIDResolvesToCanonicalProfile() throws {
        let root = try makeManagerRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let canonicalID = UUID()
        let mergedID = UUID()
        let email = "merged@example.com"
        try writeManagerProfiles(root: root, profiles: [
            managerProfile(id: canonicalID, email: email, merged: [mergedID])
        ])
        _ = try makeManagedDatabase(root: root, id: mergedID, token: "merged-token", email: email)
        let standard = try makeDatabase(at: root.appendingPathComponent("standard-state.vscdb"))
        let locator = DevinManagerLocator(folder: root) { mergedID.uuidString }

        let auth = try DevinCredentials.load(from: standard, fallbackCLI: root.appendingPathComponent("missing.toml"),
                                             manager: locator)
        XCTAssertEqual(auth.apiKey, "merged-token")
        XCTAssertEqual(auth.email, email)
    }

    /// The provider passes the same managed selection to both the network
    /// reading and the account row, so the email beside the ring cannot be
    /// for a different login than the percentage.
    func testProviderUsesActiveManagedProfileForSnapshotAndAccount() async throws {
        let root = try makeManagerRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let email = "active@example.com"
        try writeManagerProfiles(root: root, profiles: [managerProfile(id: id, email: email)])
        _ = try makeManagedDatabase(root: root, id: id, token: "active-token", email: email)
        let standard = try makeDatabase(token: "standard-token", email: "standard@example.com",
                                        at: root.appendingPathComponent("standard-state.vscdb"))
        let locator = DevinManagerLocator(folder: root) { id.uuidString }
        DevinEndpoint.reset([(200, recorded)])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DevinEndpoint.self]
        let provider = DevinLocalProvider(
            database: standard,
            cliCredentials: root.appendingPathComponent("missing.toml"),
            session: URLSession(configuration: configuration),
            accountManager: locator
        )

        let snapshot = try await provider.fetchSnapshot()
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.plan, email)
        XCTAssertEqual(provider.account()?.label, email)
        XCTAssertEqual(provider.account()?.source, "Devin Manager")
        XCTAssertEqual(DevinEndpoint.requestCount, 1)
    }

    /// A 429 is a property of the account that received it. Switching Devin
    /// Manager to another login must let that login ask immediately rather
    /// than wait out the previous account's cool-down.
    func testRateLimitDoesNotFollowManagedAccountSwitch() async throws {
        let root = try makeManagerRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstID = UUID()
        let secondID = UUID()
        try writeManagerProfiles(root: root, profiles: [
            managerProfile(id: firstID, email: "first@example.com"),
            managerProfile(id: secondID, email: "second@example.com"),
        ])
        _ = try makeManagedDatabase(root: root, id: firstID, token: "first-token", email: "first@example.com")
        _ = try makeManagedDatabase(root: root, id: secondID, token: "second-token", email: "second@example.com")
        let current = MutableString(firstID.uuidString)
        let locator = DevinManagerLocator(folder: root) { current.value }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DevinEndpoint.self]
        let provider = DevinLocalProvider(
            database: root.appendingPathComponent("standard-state.vscdb"),
            cliCredentials: root.appendingPathComponent("missing.toml"),
            session: URLSession(configuration: configuration),
            accountManager: locator
        )
        DevinEndpoint.reset([(429, ""), (200, recorded)])

        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("Expected the first account to be rate-limited")
        } catch UsageProviderError.rateLimited {}
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("Expected the same account to keep its cool-down")
        } catch UsageProviderError.rateLimited {}
        XCTAssertEqual(DevinEndpoint.requestCount, 1)

        current.value = secondID.uuidString
        let snapshot = try await provider.fetchSnapshot()
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.plan, "second@example.com")
        XCTAssertEqual(DevinEndpoint.requestCount, 2)
    }

    func testLiveDevinUsageWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["CODENOTCH_TEST_DEVIN_LIVE"] == "1" else {
            throw XCTSkip("Opt-in live check requires a signed-in Devin Desktop")
        }
        let snapshot = try await DevinLocalProvider().fetchSnapshot()
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertNotNil(snapshot.usedFraction)
        print("Devin live quota: weekly \(snapshot.headlineText)")
        for window in snapshot.windows {
            print("Devin live \(window.id): \(window.summary), reset \(window.resetsAt?.description ?? "none")")
        }
    }

    func testActivityStateFromLastConversationNode() {
        let user = #"{"message_id":"a","role":"user","content":"hi"}"#
        let tool = #"{"message_id":"a","role":"tool","content":"ok"}"#
        let answer = #"{"message_id":"a","role":"assistant","content":"done","tool_calls":[]}"#
        XCTAssertEqual(DevinActivity.turn(inLastNode: user), .inFlight)
        XCTAssertEqual(DevinActivity.turn(inLastNode: tool), .inFlight)
        XCTAssertEqual(DevinActivity.turn(inLastNode: answer + #""@tools""#), .inFlight)
        XCTAssertEqual(DevinActivity.turn(inLastNode: answer), .finished)
        let silent = #"{"message_id":"a","role":"assistant","content":"","tool_calls":[],"metadata":{}}"#
        XCTAssertEqual(DevinActivity.turn(inLastNode: silent), .inFlight)
        XCTAssertNil(DevinActivity.turn(inLastNode: ""))
    }

    private func makeProvider(database: URL) -> DevinLocalProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DevinEndpoint.self]
        // A non-existent CLI path so the fallback is not triggered by the
        // developer's own credentials file during tests.
        let cli = FileManager.default.temporaryDirectory.appendingPathComponent("nonexistent-\(UUID().uuidString).toml")
        return DevinLocalProvider(database: database, cliCredentials: cli,
                                  session: URLSession(configuration: configuration))
    }

    private func makeDatabase(token: String = "test-only-key",
                              email: String? = "user@example.com",
                              at explicitURL: URL? = nil) throws -> URL {
        let url = explicitURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("devin-\(UUID().uuidString).sqlite")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var auth: [String: Any] = ["apiKey": token]
        if let email { auth["email"] = email }
        let authJSON = try jsonString(auth)
        var statements = [
            "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT);",
            "INSERT INTO ItemTable VALUES ('windsurfAuthStatus', '\(sqlEscape(authJSON))');",
            "INSERT INTO ItemTable VALUES ('windsurf.reactSettings.cachedPlanInfoData:test', "
                + "'{\"dailyRemainingPercent\":100,\"dailyResetAtUnix\":100,\"weeklyRemainingPercent\":50,\"weeklyResetAtUnix\":100}');",
        ]
        if let email {
            let loginJSON = try jsonString(["lastLoginEmail": email])
            statements.append("INSERT INTO ItemTable VALUES ('codeium.windsurf-auth', '\(sqlEscape(loginJSON))');")
        }

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, statements.joined(separator: "\n"), nil, nil, nil), SQLITE_OK)
        return url
    }

    private func makeManagerRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("devin-manager-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeManagedDatabase(root: URL, id: UUID, token: String, email: String) throws -> URL {
        let url = root
            .appendingPathComponent(DevinManagerLocator.profileFolderName(for: id), isDirectory: true)
            .appendingPathComponent("Desktop", isDirectory: true)
            .appendingPathComponent("User", isDirectory: true)
            .appendingPathComponent("globalStorage", isDirectory: true)
            .appendingPathComponent("state.vscdb")
        return try makeDatabase(token: token, email: email, at: url)
    }

    private func writeManagerProfiles(root: URL,
                                      profiles: [[String: Any]],
                                      lastLaunch: [String: Any]? = nil) throws {
        var object: [String: Any] = ["version": 1, "profiles": profiles]
        if let lastLaunch { object["lastLaunch"] = lastLaunch }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("profiles.json"), options: .atomic)
    }

    private func managerProfile(id: UUID,
                                email: String,
                                usesStandard: Bool = false,
                                merged: [UUID]? = nil,
                                archived: Bool = false) -> [String: Any] {
        var profile: [String: Any] = [
            "id": id.uuidString,
            "email": email,
            "usesStandardSessions": usesStandard,
            "archived": archived,
        ]
        if let merged { profile["mergedProfileIDs"] = merged.map { $0.uuidString } }
        return profile
    }

    private func jsonString(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func sqlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}

private final class MutableString: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    init(_ value: String?) {
        stored = value
    }

    var value: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

private final class DevinEndpoint: URLProtocol {
    private static let lock = NSLock()
    private static var answers: [(Int, String)] = []
    private static var count = 0

    static var requestCount: Int { lock.withLock { count } }

    static func reset(_ values: [(Int, String)]) {
        lock.withLock { answers = values; count = 0 }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        XCTAssertEqual(request.url?.absoluteString, "https://server.self-serve.windsurf.com/exa.seat_management_pb.SeatManagementService/GetUserStatus")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Connect-Protocol-Version"), "1")
        let answer = Self.lock.withLock {
            Self.count += 1
            return Self.answers.isEmpty ? (500, "") : Self.answers.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.0,
                                       httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
