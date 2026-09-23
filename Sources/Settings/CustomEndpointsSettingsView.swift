import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CustomEndpointsSettingsView: View {
    @ObservedObject var preferences: Preferences
    @State private var editingEndpoint: CustomEndpoint?
    @State private var draftAPIKey: String = ""
    @State private var urlValidationError: String? = nil
    @State private var isCreatingNew = false
    @State private var isScanningPorts = false
    @State private var detectedPresets: [CustomEndpointPreset] = []
    @State private var isTesting = false
    @State private var testResult: (health: CustomEndpointHealth, latencyMs: Int, models: [String], error: String?)?
    @State private var showApiKey = false
    @State private var showTemplates = false

    private static let presetColors: [String] = [
        "#6366F1", // Indigo
        "#10B981", // Emerald
        "#F97316", // Orange
        "#EC4899", // Pink
        "#14B8A6", // Teal
        "#8B5CF6", // Purple
        "#3B82F6", // Blue
        "#EAB308"  // Amber
    ]

    private static let presetIcons: [String] = [
        "openai",
        "claude",
        "deepseek",
        "grok",
        "meta",
        "mistral",
        "ollama",
        "lmstudio",
        "qwen",
        "gemini-spark"
    ]

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n.t("Custom Endpoints"))
                                .font(.title3.weight(.semibold))
                            Text(L10n.t("Connect any OpenAI-compatible API, local inference runtime, or custom proxy."))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            startNewEndpoint()
                        } label: {
                            Label(L10n.t("Add Endpoint"), systemImage: "plus")
                        }
                        .buttonStyle(SettingsButtonStyle(kind: .prominent))
                    }

                    HStack(spacing: 8) {
                        Button {
                            withAnimation(.snappy) {
                                showTemplates.toggle()
                            }
                        } label: {
                            Label(showTemplates ? L10n.t("Hide Templates") : L10n.t("Quick Templates"),
                                  systemImage: "bolt.fill")
                        }
                        .buttonStyle(SettingsButtonStyle(kind: .standard, compact: true))

                        Button {
                            scanLocalEngines()
                        } label: {
                            if isScanningPorts {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label(L10n.t("Scan Local Engines"), systemImage: "network")
                            }
                        }
                        .buttonStyle(SettingsButtonStyle(kind: .standard, compact: true))
                        .disabled(isScanningPorts)
                    }

                    if !detectedPresets.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.t("Discovered Local Services:"))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)

                            ForEach(detectedPresets) { preset in
                                HStack {
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 8, height: 8)
                                    Text(preset.name)
                                        .font(.caption)
                                    Text(preset.baseURL)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                    Spacer()
                                    Button(L10n.t("Add to Endpoints")) {
                                        applyPreset(preset)
                                    }
                                    .buttonStyle(SettingsButtonStyle(kind: .standard, compact: true))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
                            }
                        }
                        .padding(.top, 4)
                    }

                    if showTemplates {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.t("Choose a preset to pre-fill settings:"))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)

                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                                ForEach(CustomEndpointPreset.templates) { preset in
                                    Button {
                                        applyPreset(preset)
                                    } label: {
                                        HStack(spacing: 8) {
                                            Circle()
                                                .fill(Color(hex: preset.accentColorHex))
                                                .frame(width: 10, height: 10)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(preset.name)
                                                    .font(.system(size: 12, weight: .semibold))
                                                    .foregroundStyle(.primary)
                                                Text(preset.baseURL)
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                            Spacer()
                                            Image(systemName: "plus.circle")
                                                .font(.system(size: 13))
                                                .foregroundStyle(.secondary)
                                        }
                                        .padding(8)
                                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(.vertical, 4)
            }

            if let editing = editingEndpoint {
                Section(isCreatingNew ? L10n.t("New Custom Endpoint") : L10n.t("Edit Endpoint")) {
                    endpointEditorView(endpoint: editing)
                }
            }

            Section(L10n.t("Configured Endpoints")) {
                if preferences.customEndpoints.isEmpty {
                    Text(L10n.t("No custom endpoints yet. Click 'Add Endpoint' or pick a Quick Template to get started."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ForEach(preferences.customEndpoints) { endpoint in
                        endpointRow(endpoint: endpoint)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Endpoint Row

    @ViewBuilder
    private func endpointRow(endpoint: CustomEndpoint) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle("", isOn: Binding(
                    get: { endpoint.isEnabled },
                    set: { enabled in
                        var updated = endpoint
                        updated.isEnabled = enabled
                        preferences.updateCustomEndpoint(updated)
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)

                endpointIconView(endpoint: endpoint, size: 28)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(endpoint.name)
                            .font(.system(size: 13, weight: .semibold))

                        HStack(spacing: 4) {
                            Circle()
                                .fill(endpoint.lastHealthStatus.color)
                                .frame(width: 6, height: 6)
                            if let latency = endpoint.lastLatencyMs {
                                Text("\(latency) ms")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(endpoint.lastHealthStatus.title)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    }

                    Text(endpoint.baseURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                HStack(spacing: 6) {
                    Button(L10n.t("Test")) {
                        testSingleEndpoint(endpoint)
                    }
                    .buttonStyle(SettingsButtonStyle(kind: .standard, compact: true))

                    Button(L10n.t("Edit")) {
                        editingEndpoint = endpoint
                        draftAPIKey = endpoint.apiKey ?? ""
                        urlValidationError = nil
                        isCreatingNew = false
                        testResult = nil
                    }
                    .buttonStyle(SettingsButtonStyle(kind: .standard, compact: true))

                    Button(role: .destructive) {
                        endpoint.deleteAPIKey()
                        preferences.removeCustomEndpoint(id: endpoint.id)
                        if editingEndpoint?.id == endpoint.id {
                            editingEndpoint = nil
                        }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(SettingsButtonStyle(kind: .standard, compact: true))
                }
            }

            // Usage progress bar (Currency or Tokens)
            HStack(spacing: 8) {
                switch endpoint.trackingUnit {
                case .currency:
                    let spend = endpoint.computedSpendUSD
                    let budget = endpoint.monthlyBudgetUSD

                    if let budget = budget, budget > 0 {
                        ProgressView(value: endpoint.usedFraction)
                            .tint(Color(hex: endpoint.accentColorHex))
                            .scaleEffect(x: 1, y: 0.8, anchor: .center)

                        let amountText: String = {
                            if endpoint.displayRemaining {
                                let rem = max(0.0, budget - spend)
                                return String(format: L10n.t("%@ / %@ left"), String(format: "$%.2f", rem), String(format: "$%.2f", budget))
                            } else {
                                return String(format: "$%.2f / $%.2f", spend, budget)
                            }
                        }()

                        Text(amountText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(String(format: L10n.t("Spend: $%.2f"), spend))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                case .tokens:
                    let tokensUsed = endpoint.computedTokensUsedM
                    let budget = endpoint.monthlyBudgetTokensM

                    if let budget = budget, budget > 0 {
                        ProgressView(value: endpoint.usedFraction)
                            .tint(Color(hex: endpoint.accentColorHex))
                            .scaleEffect(x: 1, y: 0.8, anchor: .center)

                        let amountText: String = {
                            if endpoint.displayRemaining {
                                let rem = max(0.0, budget - tokensUsed)
                                return String(format: L10n.t("%@ / %@ left"), CustomEndpoint.formatTokenMillions(rem), CustomEndpoint.formatTokenMillions(budget))
                            } else {
                                return "\(CustomEndpoint.formatTokenMillions(tokensUsed)) / \(CustomEndpoint.formatTokenMillions(budget))"
                            }
                        }()

                        Text(amountText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(String(format: L10n.t("Tokens: %@"), CustomEndpoint.formatTokenMillions(tokensUsed)))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                if !endpoint.selectedModel.isEmpty {
                    Spacer()
                    Text(endpoint.selectedModel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.08)))
                }
            }
            .padding(.leading, 40)
        }
        .padding(.vertical, 4)
    }

    // MARK: Endpoint Editor View

    @ViewBuilder
    private func endpointEditorView(endpoint: CustomEndpoint) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Group {
                HStack {
                    Text(L10n.t("Name"))
                        .frame(width: 120, alignment: .leading)
                    TextField(L10n.t("e.g. My OpenRouter, Local vLLM"), text: Binding(
                        get: { editingEndpoint?.name ?? "" },
                        set: { editingEndpoint?.name = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Text(L10n.t("Base URL"))
                        .frame(width: 120, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(L10n.t("https://api.openai.com/v1"), text: Binding(
                            get: { editingEndpoint?.baseURL ?? "" },
                            set: {
                                editingEndpoint?.baseURL = $0
                                if CustomEndpoint.isValidURL($0) {
                                    urlValidationError = nil
                                }
                            }
                        ))
                        .textFieldStyle(.roundedBorder)

                        if let error = urlValidationError {
                            Text(error)
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }
                }

                HStack {
                    Text(L10n.t("API Key"))
                        .frame(width: 120, alignment: .leading)
                    HStack {
                        if showApiKey {
                            TextField(L10n.t("sk-... (optional for local)"), text: $draftAPIKey)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField(L10n.t("sk-... (optional for local)"), text: $draftAPIKey)
                                .textFieldStyle(.roundedBorder)
                        }

                        Button {
                            showApiKey.toggle()
                        } label: {
                            Image(systemName: showApiKey ? "eye.slash" : "eye")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(SettingsButtonStyle(kind: .standard, compact: true))
                    }
                }

                HStack {
                    Text(L10n.t("Auth Header"))
                        .frame(width: 120, alignment: .leading)
                    TextField(L10n.t("Authorization"), text: Binding(
                        get: { editingEndpoint?.headerKey ?? "Authorization" },
                        set: { editingEndpoint?.headerKey = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
            }

            Divider()

            // Test connection & Model discovery
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button {
                        runTestConnection()
                    } label: {
                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label(L10n.t("Test Connection & Fetch Models"), systemImage: "bolt.horizontal.fill")
                        }
                    }
                    .buttonStyle(SettingsButtonStyle(kind: .standard, compact: true))
                    .disabled(isTesting || (editingEndpoint?.baseURL.isEmpty ?? true))

                    if let res = testResult {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(res.health.color)
                                .frame(width: 8, height: 8)
                            Text(res.error ?? "\(res.health.title) (\(res.latencyMs) ms)")
                                .font(.caption)
                                .foregroundStyle(res.error != nil ? .red : .secondary)
                        }
                    }
                }

                HStack {
                    Text(L10n.t("Model"))
                        .frame(width: 120, alignment: .leading)
                    if let models = editingEndpoint?.availableModels, !models.isEmpty {
                        Picker("", selection: Binding(
                            get: { editingEndpoint?.selectedModel ?? "" },
                            set: { editingEndpoint?.selectedModel = $0 }
                        )) {
                            Text(L10n.t("Select a model...")).tag("")
                            ForEach(models, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .pickerStyle(.menu)
                    } else {
                        TextField(L10n.t("Model name (e.g. gpt-4o, llama-3.3)"), text: Binding(
                            get: { editingEndpoint?.selectedModel ?? "" },
                            set: { editingEndpoint?.selectedModel = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                }
            }

            Divider()

            // Icon & Accent Color
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.t("Appearance & Icon"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 16) {
                    Text(L10n.t("Ring Accent"))
                        .frame(width: 120, alignment: .leading)

                    HStack(spacing: 8) {
                        ForEach(Self.presetColors, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 22, height: 22)
                                .overlay {
                                    if editingEndpoint?.accentColorHex == hex {
                                        Circle()
                                            .stroke(Color.white, lineWidth: 2)
                                    }
                                }
                                .onTapGesture {
                                    editingEndpoint?.accentColorHex = hex
                                }
                        }
                    }
                }

                HStack(alignment: .top, spacing: 16) {
                    Text(L10n.t("Icon"))
                        .frame(width: 120, alignment: .leading)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            ForEach(Self.presetIcons, id: \.self) { icon in
                                Button {
                                    editingEndpoint?.iconPreset = icon
                                    editingEndpoint?.customIconFilename = nil
                                } label: {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(editingEndpoint?.iconPreset == icon && editingEndpoint?.customIconFilename == nil ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.1))
                                            .frame(width: 28, height: 28)

                                        if let glyph = ProviderGlyph(rawValue: icon) {
                                            ProviderGlyphView(glyph: glyph, size: 16)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        HStack(spacing: 10) {
                            Button(L10n.t("Upload Custom Image...")) {
                                pickCustomImage()
                            }
                            .buttonStyle(SettingsButtonStyle(kind: .standard, compact: true))

                            if let filename = editingEndpoint?.customIconFilename,
                               let image = CustomIconStore.loadIcon(filename: filename) {
                                Image(nsImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 24, height: 24)
                                    .clipShape(Circle())
                                    .overlay(Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 1))

                                Button(L10n.t("Remove")) {
                                    editingEndpoint?.customIconFilename = nil
                                }
                                .buttonStyle(SettingsButtonStyle(kind: .standard, compact: true))
                            }
                        }
                    }
                }
            }

            Divider()

            // Budget & Usage configuration (Currency or Tokens)
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.t("Monthly Budget & Spend Tracking"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack {
                    Text(L10n.t("Tracking Unit"))
                        .frame(width: 120, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { editingEndpoint?.trackingUnit ?? .currency },
                        set: { editingEndpoint?.trackingUnit = $0 }
                    )) {
                        Text(L10n.t("USD ($)")).tag(CustomEndpointTrackingUnit.currency)
                        Text(L10n.t("Tokens (Millions)")).tag(CustomEndpointTrackingUnit.tokens)
                    }
                    .pickerStyle(.segmented)
                }

                if (editingEndpoint?.trackingUnit ?? .currency) == .tokens {
                    HStack {
                        Text(L10n.t("Usage source"))
                            .frame(width: 120, alignment: .leading)
                        Picker("", selection: Binding(
                            get: { editingEndpoint?.usageSource ?? .manual },
                            set: { editingEndpoint?.usageSource = $0 }
                        )) {
                            Text(L10n.t("Manual")).tag(CustomEndpointUsageSource.manual)
                            Text(L10n.t("JSON endpoint")).tag(CustomEndpointUsageSource.jsonEndpoint)
                        }
                        .pickerStyle(.segmented)
                    }

                    if editingEndpoint?.usageSource == .jsonEndpoint {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField(L10n.t("Usage URL"), text: Binding(
                                get: { editingEndpoint?.usageURL ?? "" },
                                set: { editingEndpoint?.usageURL = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            TextField(L10n.t("Records path"), text: Binding(
                                get: { editingEndpoint?.usageRecordsPath ?? "" },
                                set: { editingEndpoint?.usageRecordsPath = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            HStack {
                                Text(L10n.t("Usage authentication"))
                                    .frame(width: 160, alignment: .leading)
                                Picker("", selection: Binding(
                                    get: { editingEndpoint?.usageAuthentication ?? .apiKey },
                                    set: { editingEndpoint?.usageAuthentication = $0 }
                                )) {
                                    Text(L10n.t("API key")).tag(CustomEndpointUsageAuthentication.apiKey)
                                    Text(L10n.t("Public")).tag(CustomEndpointUsageAuthentication.none)
                                }
                                .pickerStyle(.segmented)
                            }
                            HStack(spacing: 8) {
                                TextField(L10n.t("Model field"), text: Binding(
                                    get: { editingEndpoint?.usageModelField ?? "" },
                                    set: { editingEndpoint?.usageModelField = $0 }
                                ))
                                .textFieldStyle(.roundedBorder)
                                TextField(L10n.t("Token field"), text: Binding(
                                    get: { editingEndpoint?.usageTokenField ?? "" },
                                    set: { editingEndpoint?.usageTokenField = $0 }
                                ))
                                .textFieldStyle(.roundedBorder)
                            }
                            TextField(L10n.t("Model filter (optional)"), text: Binding(
                                get: { editingEndpoint?.usageModelFilter ?? "" },
                                set: { editingEndpoint?.usageModelFilter = $0.isEmpty ? nil : $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }
                    }
                }

                if (editingEndpoint?.trackingUnit ?? .currency) == .tokens {
                    HStack {
                        Text(L10n.t("Monthly Budget (M tokens)"))
                            .frame(width: 120, alignment: .leading)
                        TextField(L10n.t("e.g. 10.0 (leave empty for unlimited)"), text: Binding(
                            get: {
                                if let val = editingEndpoint?.monthlyBudgetTokensM {
                                    return val.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", val) : String(val)
                                }
                                return ""
                            },
                            set: {
                                if $0.trimmingCharacters(in: .whitespaces).isEmpty {
                                    editingEndpoint?.monthlyBudgetTokensM = nil
                                } else {
                                    editingEndpoint?.monthlyBudgetTokensM = Double($0)
                                }
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Text(L10n.t("Tokens Used (M tokens)"))
                            .frame(width: 120, alignment: .leading)
                        TextField(L10n.t("e.g. 2.5"), text: Binding(
                            get: {
                                if let val = editingEndpoint?.currentTokensUsedM {
                                    return val.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", val) : String(val)
                                }
                                return ""
                            },
                            set: {
                                if $0.trimmingCharacters(in: .whitespaces).isEmpty {
                                    editingEndpoint?.currentTokensUsedM = nil
                                } else {
                                    editingEndpoint?.currentTokensUsedM = Double($0)
                                }
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(L10n.t("Show token count instead of percentage (%)"), isOn: Binding(
                            get: { editingEndpoint?.showCurrency ?? false },
                            set: { editingEndpoint?.showCurrency = $0 }
                        ))
                        .toggleStyle(.checkbox)

                        Toggle(L10n.t("Show remaining budget instead of spent"), isOn: Binding(
                            get: { editingEndpoint?.displayRemaining ?? false },
                            set: { editingEndpoint?.displayRemaining = $0 }
                        ))
                        .toggleStyle(.checkbox)
                    }

                    HStack {
                        Spacer()
                        Button(L10n.t("Reset Tokens")) {
                            editingEndpoint?.currentTokensUsedM = 0
                        }
                        .buttonStyle(SettingsButtonStyle(kind: .standard, compact: true))
                    }
                } else {
                    HStack {
                        Text(L10n.t("Monthly Budget ($)"))
                            .frame(width: 120, alignment: .leading)
                        TextField(L10n.t("e.g. 20.00 (leave empty for unlimited)"), text: Binding(
                            get: {
                                editingEndpoint?.monthlyBudgetUSD.map { String(format: "%.2f", $0) } ?? ""
                            },
                            set: {
                                editingEndpoint?.monthlyBudgetUSD = Double($0)
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Text(L10n.t("Current Spend ($)"))
                            .frame(width: 120, alignment: .leading)
                        TextField(L10n.t("e.g. 4.25"), text: Binding(
                            get: {
                                editingEndpoint?.currentSpendUSD.map { String(format: "%.2f", $0) } ?? ""
                            },
                            set: {
                                editingEndpoint?.currentSpendUSD = Double($0)
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(L10n.t("Show dollar amount ($) instead of percentage (%)"), isOn: Binding(
                            get: { editingEndpoint?.showCurrency ?? false },
                            set: { editingEndpoint?.showCurrency = $0 }
                        ))
                        .toggleStyle(.checkbox)

                        Toggle(L10n.t("Show remaining budget instead of spent"), isOn: Binding(
                            get: { editingEndpoint?.displayRemaining ?? false },
                            set: { editingEndpoint?.displayRemaining = $0 }
                        ))
                        .toggleStyle(.checkbox)
                    }

                    HStack {
                        Spacer()
                        Button(L10n.t("Reset Spend")) {
                            editingEndpoint?.currentSpendUSD = 0
                        }
                        .buttonStyle(SettingsButtonStyle(kind: .standard, compact: true))
                    }
                }
            }

            Divider()

            // Save / Cancel Actions
            HStack {
                Button(L10n.t("Cancel")) {
                    editingEndpoint = nil
                    draftAPIKey = ""
                    urlValidationError = nil
                    isCreatingNew = false
                    testResult = nil
                }
                .buttonStyle(SettingsButtonStyle(kind: .standard))

                Spacer()

                Button(L10n.t("Save Endpoint")) {
                    saveEditingEndpoint()
                }
                .buttonStyle(SettingsButtonStyle(kind: .prominent))
                .disabled(editingEndpoint?.name.isEmpty ?? true || editingEndpoint?.baseURL.isEmpty ?? true)
            }
            .padding(.top, 4)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
    }

    // MARK: Icon View Helper

    @ViewBuilder
    private func endpointIconView(endpoint: CustomEndpoint, size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(Color(hex: endpoint.accentColorHex).opacity(0.2))
                .frame(width: size, height: size)

            if let filename = endpoint.customIconFilename,
               let image = CustomIconStore.loadIcon(filename: filename) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 0.75, height: size * 0.75)
                    .clipShape(Circle())
            } else if let icon = endpoint.iconPreset, let glyph = ProviderGlyph(rawValue: icon) {
                ProviderGlyphView(glyph: glyph, size: size * 0.6)
                    .foregroundStyle(Color(hex: endpoint.accentColorHex))
            } else {
                Image(systemName: "server.rack")
                    .font(.system(size: size * 0.5))
                    .foregroundStyle(Color(hex: endpoint.accentColorHex))
            }
        }
    }

    // MARK: Actions

    private func startNewEndpoint() {
        editingEndpoint = CustomEndpoint(
            name: "",
            baseURL: "https://",
            headerKey: "Authorization",
            selectedModel: "",
            accentColorHex: "#6366F1",
            iconPreset: "openai"
        )
        draftAPIKey = ""
        urlValidationError = nil
        isCreatingNew = true
        testResult = nil
    }

    private func applyPreset(_ preset: CustomEndpointPreset) {
        editingEndpoint = CustomEndpoint(
            name: preset.name,
            baseURL: preset.baseURL,
            headerKey: preset.headerKey,
            selectedModel: preset.defaultModel,
            accentColorHex: preset.accentColorHex,
            iconPreset: preset.iconPreset
        )
        draftAPIKey = ""
        urlValidationError = nil
        isCreatingNew = true
        showTemplates = false
        testResult = nil
    }

    private func saveEditingEndpoint() {
        guard var endpoint = editingEndpoint else { return }

        guard CustomEndpoint.isValidURL(endpoint.baseURL) else {
            urlValidationError = L10n.t("URL must start with http:// or https:// and have a valid host.")
            return
        }
        urlValidationError = nil

        endpoint.saveAPIKey(draftAPIKey)

        if isCreatingNew {
            preferences.addCustomEndpoint(endpoint)
        } else {
            preferences.updateCustomEndpoint(endpoint)
        }
        editingEndpoint = nil
        draftAPIKey = ""
        isCreatingNew = false
        testResult = nil
    }

    private func runTestConnection() {
        guard let endpoint = editingEndpoint else { return }
        isTesting = true
        testResult = nil

        Task {
            let res = await CustomEndpointNetwork.shared.testEndpoint(
                baseURL: endpoint.baseURL,
                apiKey: draftAPIKey,
                headerKey: endpoint.headerKey
            )
            await MainActor.run {
                self.isTesting = false
                self.testResult = res
                self.editingEndpoint?.lastHealthStatus = res.health
                self.editingEndpoint?.lastLatencyMs = res.latencyMs
                if !res.models.isEmpty {
                    self.editingEndpoint?.availableModels = res.models
                    if self.editingEndpoint?.selectedModel.isEmpty ?? true {
                        self.editingEndpoint?.selectedModel = res.models.first ?? ""
                    }
                }
            }
        }
    }

    private func testSingleEndpoint(_ endpoint: CustomEndpoint) {
        Task {
            let res = await CustomEndpointNetwork.shared.testEndpoint(
                baseURL: endpoint.baseURL,
                apiKey: endpoint.apiKey ?? "",
                headerKey: endpoint.headerKey
            )
            await MainActor.run {
                var updated = endpoint
                updated.lastHealthStatus = res.health
                updated.lastLatencyMs = res.latencyMs
                if !res.models.isEmpty {
                    updated.availableModels = res.models
                }
                preferences.updateCustomEndpoint(updated)
            }
        }
    }

    private func scanLocalEngines() {
        isScanningPorts = true
        detectedPresets = []

        Task {
            let found = await CustomEndpointNetwork.shared.scanCommonLocalPorts()
            await MainActor.run {
                self.isScanningPorts = false
                self.detectedPresets = found
            }
        }
    }

    private func pickCustomImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.png, UTType.jpeg, UTType.svg, UTType.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        if panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) {
            let endpointID = editingEndpoint?.id ?? UUID().uuidString
            if let savedFilename = CustomIconStore.saveIcon(image: image, for: endpointID) {
                editingEndpoint?.customIconFilename = savedFilename
            }
        }
    }
}

// MARK: Color Hex Helper

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 99, 102, 241)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
