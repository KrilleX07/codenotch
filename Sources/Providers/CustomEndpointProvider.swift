import Foundation

/// Refuses to carry the key across a redirect.
///
/// The endpoint's address comes from the user, but where it *redirects* to does
/// not. Following a 302 with `URLSession`'s default policy re-sends every header,
/// so a hostile or merely misconfigured endpoint could hand the key to another
/// host. There is nothing a usage probe needs from a redirect, so it stops.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public actor CustomEndpointNetwork {
    public static let shared = CustomEndpointNetwork()

    private let noRedirects = NoRedirects()

    /// What a plausible `/models` reply holds. Anything past this is not a list
    /// someone is going to pick from.
    static let maxModels = 200
    static let maxModelIDLength = 200

    public func testEndpoint(
        baseURL: String,
        apiKey: String,
        headerKey: String = "Authorization"
    ) async -> (health: CustomEndpointHealth, latencyMs: Int, models: [String], error: String?) {
        guard CustomEndpoint.isValidURL(baseURL), let url = URL(string: baseURL) else {
            return (.unreachable, 0, [], L10n.t("The address must start with http:// or https://"))
        }

        let modelsURL: URL
        if baseURL.hasSuffix("/models") {
            modelsURL = url
        } else if baseURL.hasSuffix("/") {
            modelsURL = url.appendingPathComponent("models")
        } else {
            modelsURL = url.appendingPathComponent("models")
        }

        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 6.0

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            let header = headerKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if header.lowercased() == "authorization" && !trimmedKey.lowercased().hasPrefix("bearer ") {
                request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
            } else {
                request.setValue(trimmedKey, forHTTPHeaderField: header.isEmpty ? "Authorization" : header)
            }
        }

        let start = DispatchTime.now()
        do {
            let (data, response) = try await URLSession.shared.data(for: request, delegate: noRedirects)
            let elapsedNano = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            let latencyMs = max(1, Int(elapsedNano / 1_000_000))

            guard let httpResponse = response as? HTTPURLResponse else {
                return (.unreachable, latencyMs, [], L10n.t("Not an HTTP endpoint"))
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                return (.unreachable, latencyMs, [], L10n.t("The endpoint answered \(httpResponse.statusCode)"))
            }

            // Parse models from {"data": [{"id": "model-name"}]} or {"models": [...]}
            var discoveredModels: [String] = []
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let list = json["data"] as? [[String: Any]] {
                    discoveredModels = list.compactMap { $0["id"] as? String }.sorted()
                } else if let list = json["models"] as? [[String: Any]] {
                    discoveredModels = list.compactMap { ($0["name"] as? String) ?? ($0["id"] as? String) }.sorted()
                }
            }

            let health: CustomEndpointHealth = latencyMs > 800 ? .slow : .online
            // Bounded before it is stored: this list is JSON-encoded into the
            // defaults plist and decoded again on every provider property access,
            // so an endpoint answering with a hundred thousand ids would bloat the
            // plist and stall the picker. No real endpoint lists more than a few.
            let bounded = discoveredModels
                .filter { !$0.isEmpty && $0.count <= Self.maxModelIDLength }
                .prefix(Self.maxModels)
            return (health, latencyMs, Array(bounded), nil)
        } catch {
            let elapsedNano = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            let latencyMs = Int(elapsedNano / 1_000_000)
            // The code, never the endpoint's own words. A URLError's description can
            // carry the host and path, and this string is shown in Settings and kept
            // in the endpoint's saved health. The kind of failure is what helps.
            let reason = (error as? URLError)?.code == .timedOut
                ? L10n.t("The endpoint did not answer in time")
                : L10n.t("Could not reach the endpoint")
            return (.unreachable, latencyMs, [], reason)
        }
    }

    public func scanCommonLocalPorts() async -> [CustomEndpointPreset] {
        let candidates: [(name: String, port: Int, defaultModel: String, glyph: String, color: String)] = [
            ("Local vLLM", 8000, "", "ollama", "#10B981"),
            ("Local llama.cpp", 8080, "", "lmstudio", "#8B5CF6"),
            ("Local LM Studio / Proxy", 1234, "", "lmstudio", "#8B5CF6"),
            ("Local Ollama", 11434, "", "ollama-local", "#14B8A6"),
            ("Local AI Server", 5000, "", "openai", "#3B82F6")
        ]

        var found: [CustomEndpointPreset] = []
        await withTaskGroup(of: CustomEndpointPreset?.self) { group in
            for candidate in candidates {
                group.addTask {
                    let baseURL = "http://localhost:\(candidate.port)/v1"
                    guard let url = URL(string: "\(baseURL)/models") else { return nil }
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 1.2
                    guard let (_, res) = try? await URLSession.shared.data(for: req),
                          let http = res as? HTTPURLResponse,
                          (200...299).contains(http.statusCode) else {
                        return nil
                    }
                    return CustomEndpointPreset(
                        id: "detected-\(candidate.port)",
                        name: "\(candidate.name) (:\(candidate.port))",
                        baseURL: baseURL,
                        headerKey: "Authorization",
                        defaultModel: candidate.defaultModel,
                        iconPreset: candidate.glyph,
                        accentColorHex: candidate.color
                    )
                }
            }
            for await preset in group {
                if let preset {
                    found.append(preset)
                }
            }
        }
        return found.sorted { $0.name < $1.name }
    }
}

actor CustomEndpointProvider: UsageProvider {
    nonisolated let id: String
    private let endpointID: String
    private let session: URLSession

    init(endpoint: CustomEndpoint, session: URLSession = .shared) {
        self.endpointID = endpoint.id
        self.id = endpoint.providerID
        self.session = session
    }

    nonisolated static func storedEndpoint(id: String) -> CustomEndpoint? {
        Preferences.storedCustomEndpoints().first(where: { $0.id == id })
    }

    nonisolated var glyph: ProviderGlyph {
        if let current = Self.storedEndpoint(id: endpointID),
           let iconPreset = current.iconPreset,
           let presetGlyph = ProviderGlyph(rawValue: iconPreset) {
            return presetGlyph
        }
        return .openai
    }

    nonisolated var displayName: String {
        Self.storedEndpoint(id: endpointID)?.name ?? L10n.t("Custom Endpoint")
    }

    nonisolated var customIconFilename: String? {
        Self.storedEndpoint(id: endpointID)?.customIconFilename
    }

    nonisolated var isVisibleWhenAbsent: Bool { false }

    nonisolated func account() -> ProviderAccount? {
        guard let current = Self.storedEndpoint(id: endpointID) else { return nil }
        let modelSummary = current.selectedModel.isEmpty ? current.baseURL : current.selectedModel

        // Only use manageURL for strictly https schemes to prevent launching arbitrary schemes
        var safeManageURL: URL? = nil
        if let url = URL(string: current.baseURL), url.scheme?.lowercased() == "https" {
            safeManageURL = url
        }

        return ProviderAccount(
            label: current.name,
            plan: modelSummary,
            source: L10n.t("Custom Endpoint"),
            manageURL: safeManageURL
        )
    }

    nonisolated var signInRoute: SignInRoute {
        .guidance(L10n.t("Configure endpoint details and credentials in Settings."))
    }

    func signOut() async {
        if let current = Self.storedEndpoint(id: endpointID) {
            current.deleteAPIKey()
        }
    }

    nonisolated func presentSignIn() {}

    nonisolated func forgetCachedCredential() {}

    private static func nextMonthlyResetDate() -> Date {
        let calendar = Calendar.current
        let now = Date()
        guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: now),
              let startOfNextMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: nextMonth)) else {
            return now.addingTimeInterval(30 * 86400)
        }
        return startOfNextMonth
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        guard let current = Self.storedEndpoint(id: endpointID) else {
            throw UsageProviderError.needsAuth
        }
        guard current.isEnabled else {
            throw UsageProviderError.needsAuth
        }
        guard CustomEndpoint.isValidURL(current.baseURL) else {
            throw UsageProviderError.badResponse(status: 400)
        }

        // Live network probe to verify reachability and authentication
        let apiKey = current.apiKey ?? ""
        let probe = await CustomEndpointNetwork.shared.testEndpoint(
            baseURL: current.baseURL,
            apiKey: apiKey,
            headerKey: current.headerKey
        )

        if probe.health == .unreachable {
            if let err = probe.error, err.contains("401") || err.contains("403") {
                throw UsageProviderError.needsAuth
            }
            throw UsageProviderError.badResponse(status: 503)
        }

        var windows: [LimitWindow] = []

        switch current.trackingUnit {
        case .currency:
            let spend = current.computedSpendUSD
            let budget = current.monthlyBudgetUSD

            if let budget = budget, budget > 0 {
                let remaining = max(0.0, budget - spend)
                let isRemaining = current.displayRemaining
                let displayFraction = isRemaining ? current.remainingFraction : current.usedFraction
                let usedFormatted = String(format: "$%.2f", isRemaining ? remaining : spend)
                let budgetFormatted = String(format: "$%.2f", budget)
                let detailText = isRemaining
                    ? String(format: L10n.t("%@ / %@ remaining"), usedFormatted, budgetFormatted)
                    : "\(usedFormatted) / \(budgetFormatted)"
                let label = isRemaining ? L10n.t("Remaining Budget") : L10n.t("Monthly Budget")

                // Exhaustion band is based on spend fraction so 100% remaining is ample
                let spendFraction = min(max(spend / budget, 0.0), 1.0)
                let bandOverride = isRemaining ? UsageBand.band(for: spendFraction) : nil

                windows.append(
                    LimitWindow(
                        id: "monthly-budget",
                        group: nil,
                        label: label,
                        usedFraction: displayFraction,
                        remaining: nil,
                        used: nil,
                        usedText: usedFormatted,
                        detail: detailText,
                        resetsAt: Self.nextMonthlyResetDate(),
                        duration: 30 * 86400,
                        bandOverride: bandOverride,
                        prefersUsedText: current.showCurrency
                    )
                )
            } else {
                let usedFormatted = String(format: "$%.2f", spend)
                windows.append(
                    LimitWindow(
                        id: "spend-tracking",
                        group: nil,
                        label: L10n.t("Total Spend"),
                        usedFraction: nil,
                        remaining: nil,
                        used: nil,
                        usedText: usedFormatted,
                        detail: usedFormatted,
                        resetsAt: nil,
                        duration: nil,
                        prefersUsedText: true
                    )
                )
            }

        case .tokens:
            let tokensUsed = current.computedTokensUsedM
            let budget = current.monthlyBudgetTokensM

            if let budget = budget, budget > 0 {
                let remaining = max(0.0, budget - tokensUsed)
                let isRemaining = current.displayRemaining
                let displayFraction = isRemaining ? current.remainingFraction : current.usedFraction
                let usedFormatted = CustomEndpoint.formatTokenMillions(isRemaining ? remaining : tokensUsed)
                let budgetFormatted = CustomEndpoint.formatTokenMillions(budget)
                let detailText = isRemaining
                    ? String(format: L10n.t("%@ / %@ tokens remaining"), usedFormatted, budgetFormatted)
                    : String(format: L10n.t("%@ / %@ tokens"), usedFormatted, budgetFormatted)
                let label = isRemaining ? L10n.t("Remaining Tokens") : L10n.t("Monthly Tokens")

                let tokensFraction = min(max(tokensUsed / budget, 0.0), 1.0)
                let bandOverride = isRemaining ? UsageBand.band(for: tokensFraction) : nil

                windows.append(
                    LimitWindow(
                        id: "token-budget",
                        group: nil,
                        label: label,
                        usedFraction: displayFraction,
                        remaining: nil,
                        used: nil,
                        usedText: usedFormatted,
                        detail: detailText,
                        resetsAt: Self.nextMonthlyResetDate(),
                        duration: 30 * 86400,
                        bandOverride: bandOverride,
                        prefersUsedText: current.showCurrency
                    )
                )
            } else {
                let usedFormatted = CustomEndpoint.formatTokenMillions(tokensUsed)
                let detailText = String(format: L10n.t("%@ tokens"), usedFormatted)
                windows.append(
                    LimitWindow(
                        id: "token-tracking",
                        group: nil,
                        label: L10n.t("Tokens Used"),
                        usedFraction: nil,
                        remaining: nil,
                        used: nil,
                        usedText: usedFormatted,
                        detail: detailText,
                        resetsAt: nil,
                        duration: nil,
                        prefersUsedText: true
                    )
                )
            }
        }

        let headlineID = windows.first?.id

        var snapshot = ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .derived,
            status: .ok,
            windows: windows,
            headlineID: headlineID,
            weeklyID: nil,
            block: nil,
            kind: .usage
        )
        snapshot.customIconFilename = current.customIconFilename
        return snapshot
    }
}
