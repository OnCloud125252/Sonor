import Foundation
import Combine

/// Where text refinement runs.
enum LLMProvider: String, CaseIterable, Identifiable {
    case local
    case remoteAPI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: return t("On-Device")
        case .remoteAPI: return t("Cloud API")
        }
    }
}

/// A ready made endpoint for an OpenAI compatible chat completions API.
struct LLMAPIPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let baseURL: String
    let suggestedModel: String

    static let all: [LLMAPIPreset] = [
        LLMAPIPreset(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1", suggestedModel: "gpt-4o-mini"),
        LLMAPIPreset(id: "anthropic", name: "Anthropic", baseURL: "https://api.anthropic.com/v1", suggestedModel: "claude-haiku-4-5"),
        LLMAPIPreset(id: "gemini", name: "Google Gemini", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", suggestedModel: "gemini-2.5-flash"),
        LLMAPIPreset(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", suggestedModel: "openai/gpt-4o-mini"),
        LLMAPIPreset(id: "groq", name: "Groq", baseURL: "https://api.groq.com/openai/v1", suggestedModel: "llama-3.3-70b-versatile"),
        LLMAPIPreset(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", suggestedModel: "deepseek-chat"),
        LLMAPIPreset(id: "ollama", name: "Ollama", baseURL: "http://localhost:11434/v1", suggestedModel: "llama3.2"),
        LLMAPIPreset(id: "lmstudio", name: "LM Studio", baseURL: "http://localhost:1234/v1", suggestedModel: "local-model"),
        LLMAPIPreset(id: "custom", name: "Custom", baseURL: "", suggestedModel: "")
    ]

    static func preset(id: String) -> LLMAPIPreset {
        all.first(where: { $0.id == id }) ?? all[0]
    }
}

/// One assistant's effective language model choice.
struct ResolvedLLM {
    let provider: LLMProvider
    let configuration: RemoteLLMConfiguration

    /// True when this choice can refine text right now.
    var isUsable: Bool {
        switch provider {
        case .local:
            return ModelManager.shared.gemmaState == .downloaded
        case .remoteAPI:
            guard !configuration.modelName.isEmpty else { return false }
            guard let url = URL(string: configuration.baseURL) else { return false }
            return url.scheme != nil && url.host != nil
        }
    }

    /// Name written into the message history.
    var label: String {
        switch provider {
        case .local: return "Gemma 3"
        case .remoteAPI: return configuration.modelName
        }
    }
}

/// Holds the user choice between the on-device model and a cloud API.
@MainActor
final class LLMSettings: ObservableObject {
    static let shared = LLMSettings()

    private enum Keys {
        static let provider = "llmProvider"
        static let presetId = "llmAPIPresetId"
        static let baseURL = "llmAPIBaseURL"
        static let modelName = "llmAPIModelName"
        static let temperature = "llmAPITemperature"
        static let reasoningEffort = "llmAPIReasoningEffort"
    }

    /// The reasoning efforts an OpenAI compatible endpoint accepts.
    ///
    /// The empty entry means Sonor sends no field, so the service keeps its own default.
    static let reasoningEffortOptions = ["", "minimal", "low", "medium", "high"]

    private static let keychainAccount = "llmAPIKey"

    @Published var provider: LLMProvider {
        didSet {
            UserDefaults.standard.set(provider.rawValue, forKey: Keys.provider)
            // The on-device model holds gigabytes of RAM that the cloud path never needs.
            if provider == .remoteAPI {
                LLMManager.shared.releaseModel()
            }
        }
    }

    @Published var presetId: String {
        didSet { UserDefaults.standard.set(presetId, forKey: Keys.presetId) }
    }

    @Published var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: Keys.baseURL) }
    }

    @Published var modelName: String {
        didSet { UserDefaults.standard.set(modelName, forKey: Keys.modelName) }
    }

    @Published var temperature: Double {
        didSet { UserDefaults.standard.set(temperature, forKey: Keys.temperature) }
    }

    @Published var reasoningEffort: String {
        didSet { UserDefaults.standard.set(reasoningEffort, forKey: Keys.reasoningEffort) }
    }

    @Published var apiKey: String {
        didSet { KeychainStore.write(apiKey, account: Self.keychainAccount) }
    }

    private init() {
        let defaults = UserDefaults.standard
        let storedProvider = defaults.string(forKey: Keys.provider) ?? LLMProvider.local.rawValue
        self.provider = LLMProvider(rawValue: storedProvider) ?? .local
        self.presetId = defaults.string(forKey: Keys.presetId) ?? LLMAPIPreset.all[0].id
        self.baseURL = defaults.string(forKey: Keys.baseURL) ?? LLMAPIPreset.all[0].baseURL
        self.modelName = defaults.string(forKey: Keys.modelName) ?? LLMAPIPreset.all[0].suggestedModel
        let storedTemperature = defaults.object(forKey: Keys.temperature) as? Double
        self.temperature = storedTemperature ?? 0.7
        self.reasoningEffort = defaults.string(forKey: Keys.reasoningEffort) ?? ""
        self.apiKey = KeychainStore.read(account: Self.keychainAccount) ?? ""
    }

    /// True when the endpoint and the model name can build a valid request.
    var isAPIConfigured: Bool {
        let trimmedModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return false }
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return url.scheme != nil && url.host != nil
    }

    var configuration: RemoteLLMConfiguration {
        RemoteLLMConfiguration(
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            modelName: modelName.trimmingCharacters(in: .whitespacesAndNewlines),
            temperature: temperature,
            reasoningEffort: reasoningEffort
        )
    }

    /// The provider and cloud settings a single assistant runs with.
    /// An assistant may pick its own provider, model and temperature. The endpoint and the
    /// API key stay shared, because they belong to one account.
    func resolved(for mode: VoiceMode?) -> ResolvedLLM {
        let chosenProvider = mode?.llmProviderOverride
            .flatMap(LLMProvider.init(rawValue:)) ?? provider

        let trimmedOverride = mode?.llmModelOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveModel = (trimmedOverride?.isEmpty == false ? trimmedOverride! : modelName)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ResolvedLLM(
            provider: chosenProvider,
            configuration: RemoteLLMConfiguration(
                baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                modelName: effectiveModel,
                temperature: mode?.llmTemperatureOverride ?? temperature,
                reasoningEffort: reasoningEffort
            )
        )
    }

    func apply(preset: LLMAPIPreset) {
        presetId = preset.id
        guard preset.id != "custom" else { return }
        baseURL = preset.baseURL
        modelName = preset.suggestedModel
    }
}
