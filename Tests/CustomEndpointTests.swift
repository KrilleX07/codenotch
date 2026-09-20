import XCTest
@testable import Codenotch

final class CustomEndpointTests: XCTestCase {
    func testCustomEndpointDefaultValues() {
        let endpoint = CustomEndpoint(
            name: "Test vLLM",
            baseURL: "http://localhost:8000/v1"
        )

        XCTAssertEqual(endpoint.name, "Test vLLM")
        XCTAssertEqual(endpoint.baseURL, "http://localhost:8000/v1")
        XCTAssertEqual(endpoint.headerKey, "Authorization")
        XCTAssertEqual(endpoint.accentColorHex, "#6366F1")
        XCTAssertEqual(endpoint.iconPreset, "openai")
        XCTAssertTrue(endpoint.isEnabled)
        XCTAssertEqual(endpoint.lastHealthStatus, .idle)
        XCTAssertEqual(endpoint.computedSpendUSD, 0.0)
        XCTAssertEqual(endpoint.usedFraction, 0.0)
    }

    func testUsedFractionWithBudget() {
        var endpoint = CustomEndpoint(
            name: "Budget Test",
            baseURL: "https://api.groq.com/openai/v1",
            monthlyBudgetUSD: 20.0,
            currentSpendUSD: 5.0
        )

        XCTAssertEqual(endpoint.usedFraction, 0.25, accuracy: 0.001)

        // Spend at budget
        endpoint.currentSpendUSD = 20.0
        XCTAssertEqual(endpoint.usedFraction, 1.0, accuracy: 0.001)

        // Spend over budget caps at 1.0
        endpoint.currentSpendUSD = 25.0
        XCTAssertEqual(endpoint.usedFraction, 1.0, accuracy: 0.001)

        // No budget
        endpoint.monthlyBudgetUSD = nil
        XCTAssertEqual(endpoint.usedFraction, 0.0)

        // Display remaining mode
        var remainingEndpoint = CustomEndpoint(
            name: "Remaining Test",
            baseURL: "https://api.groq.com/openai/v1",
            monthlyBudgetUSD: 100.0,
            currentSpendUSD: 25.0,
            displayRemaining: true
        )
        XCTAssertEqual(remainingEndpoint.remainingFraction, 0.75, accuracy: 0.001)
        XCTAssertEqual(remainingEndpoint.usedFraction, 0.75, accuracy: 0.001)

        remainingEndpoint.currentSpendUSD = 100.0
        XCTAssertEqual(remainingEndpoint.remainingFraction, 0.0, accuracy: 0.001)
        XCTAssertEqual(remainingEndpoint.usedFraction, 0.0, accuracy: 0.001)

        // Show currency flag
        XCTAssertFalse(remainingEndpoint.showCurrency)
        remainingEndpoint.showCurrency = true
        XCTAssertTrue(remainingEndpoint.showCurrency)
    }

    func testURLValidation() {
        XCTAssertTrue(CustomEndpoint.isValidURL("https://api.openai.com/v1"))
        XCTAssertTrue(CustomEndpoint.isValidURL("http://localhost:8000/v1"))
        XCTAssertTrue(CustomEndpoint.isValidURL("http://127.0.0.1:11434"))

        XCTAssertFalse(CustomEndpoint.isValidURL(""))
        XCTAssertFalse(CustomEndpoint.isValidURL("not a url"))
        XCTAssertFalse(CustomEndpoint.isValidURL("ftp://server.local"))
        XCTAssertFalse(CustomEndpoint.isValidURL("javascript:alert(1)"))
        XCTAssertFalse(CustomEndpoint.isValidURL("file:///etc/passwd"))
    }

    func testPresetsCoverage() {
        let presets = CustomEndpointPreset.templates
        XCTAssertFalse(presets.isEmpty)

        let openRouter = presets.first { $0.id == "openrouter" }
        XCTAssertNotNil(openRouter)
        XCTAssertEqual(openRouter?.baseURL, "https://openrouter.ai/api/v1")
        XCTAssertTrue(CustomEndpoint.isValidURL(openRouter?.baseURL ?? ""))

        let groq = presets.first { $0.id == "groq" }
        XCTAssertNotNil(groq)
        XCTAssertEqual(groq?.baseURL, "https://api.groq.com/openai/v1")
        XCTAssertTrue(CustomEndpoint.isValidURL(groq?.baseURL ?? ""))

        let vllm = presets.first { $0.id == "vllm" }
        XCTAssertNotNil(vllm)
        XCTAssertEqual(vllm?.baseURL, "http://localhost:8000/v1")
        XCTAssertTrue(CustomEndpoint.isValidURL(vllm?.baseURL ?? ""))
    }

    func testCustomEndpointJSONCodableNeverStoresAPIKey() throws {
        let endpointID = "test-codable-\(UUID().uuidString)"
        let original = CustomEndpoint(
            id: endpointID,
            name: "Together AI",
            baseURL: "https://api.together.xyz/v1",
            headerKey: "Authorization",
            selectedModel: "meta-llama/Llama-3.3-70B-Instruct-Turbo",
            availableModels: ["meta-llama/Llama-3.3-70B-Instruct-Turbo"],
            isEnabled: true,
            accentColorHex: "#06B6D4",
            iconPreset: "meta",
            customIconFilename: "custom.png",
            monthlyBudgetUSD: 15.0,
            currentSpendUSD: 3.50,
            lastLatencyMs: 48,
            lastHealthStatus: .online,
            lastCheckedAt: Date(timeIntervalSince1970: 1700000000)
        )

        let data = try JSONEncoder().encode(original)
        let jsonString = String(data: data, encoding: .utf8) ?? ""

        // Crucial security check: apiKey must never be serialized into JSON
        XCTAssertFalse(jsonString.contains("apiKey"))
        XCTAssertFalse(jsonString.contains("secret"))

        let decoded = try JSONDecoder().decode(CustomEndpoint.self, from: data)
        XCTAssertEqual(decoded.id, endpointID)
        XCTAssertEqual(decoded.name, "Together AI")
        XCTAssertEqual(decoded.availableModels.count, 1)
        XCTAssertEqual(decoded.computedSpendUSD, 3.50)
        XCTAssertEqual(decoded.monthlyBudgetUSD, 15.0)
        XCTAssertEqual(decoded.lastLatencyMs, 48)
        XCTAssertEqual(decoded.lastHealthStatus, .online)
    }

    func testKeychainAPIKeyStorageAndDeletion() {
        let endpointID = "keychain-test-\(UUID().uuidString)"
        let endpoint = CustomEndpoint(
            id: endpointID,
            name: "Secure Endpoint",
            baseURL: "https://api.openai.com/v1"
        )

        defer {
            endpoint.deleteAPIKey()
        }

        XCTAssertNil(endpoint.apiKey)

        let testKey = "sk-test-secret-key-12345"
        endpoint.saveAPIKey(testKey)
        XCTAssertEqual(endpoint.apiKey, testKey)

        endpoint.deleteAPIKey()
        XCTAssertNil(endpoint.apiKey)
    }
}
