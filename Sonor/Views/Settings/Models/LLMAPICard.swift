import SwiftUI

/// Settings for an OpenAI compatible chat completions endpoint.
struct LLMAPICard: View {
    @ObservedObject private var settings = LLMSettings.shared
    @ObservedObject private var llmManager = LLMManager.shared
    @Environment(\.colorScheme) var colorScheme

    private enum TestState: Equatable {
        case idle
        case testing
        case success
        case failure(String)
    }

    @State private var testState: TestState = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            presetRow
            endpointRow
            modelRow
            keyRow
            testRow
            privacyNote
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(colorScheme == .dark ? Color.white.opacity(0.02) : Color.black.opacity(0.01))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t("Cloud API"))
                .font(.system(size: 16, weight: .semibold))
            Text(t("Use any OpenAI compatible endpoint for text rewriting. No download is needed."))
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var presetBinding: Binding<String> {
        Binding(
            get: { settings.presetId },
            set: { settings.apply(preset: LLMAPIPreset.preset(id: $0)) }
        )
    }

    private var presetRow: some View {
        row(title: t("Service")) {
            Picker("", selection: presetBinding) {
                ForEach(LLMAPIPreset.all) { preset in
                    Text(preset.id == "custom" ? t("Custom") : preset.name).tag(preset.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    private var endpointRow: some View {
        row(title: t("API Endpoint")) {
            TextField("https://api.openai.com/v1", text: $settings.baseURL)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
    }

    private var modelRow: some View {
        row(title: t("Model Name")) {
            TextField("gpt-4o-mini", text: $settings.modelName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
    }

    private var keyRow: some View {
        row(title: t("API Key")) {
            SecureField(t("Optional for local servers"), text: $settings.apiKey)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
    }

    private var testRow: some View {
        HStack(spacing: 10) {
            Button(action: runTest) {
                testButtonLabel
            }
            .buttonStyle(.plain)
            .disabled(testState == .testing || !settings.isAPIConfigured)
            .opacity(settings.isAPIConfigured ? 1.0 : 0.5)

            statusLabel
        }
    }

    private var testButtonLabel: some View {
        HStack(spacing: 6) {
            if testState == .testing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }
            Text(t("Test Connection"))
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundColor(colorScheme == .dark ? .black : .white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(colorScheme == .dark ? Color.white : Color.black)
        .cornerRadius(8)
    }

    private var privacyNote: some View {
        Text(t("Your text leaves the Mac and goes to this service. On-Device mode keeps everything local."))
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch testState {
        case .idle:
            if let error = llmManager.lastAPIError {
                message(text: error, systemImage: "exclamationmark.triangle.fill", color: .orange)
            }
        case .testing:
            EmptyView()
        case .success:
            message(text: t("Connection works."), systemImage: "checkmark.circle.fill", color: .green)
        case .failure(let error):
            message(text: error, systemImage: "xmark.circle.fill", color: .red)
        }
    }

    private func message(text: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .foregroundColor(color)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.system(size: 13))
                .frame(width: 110, alignment: .leading)
            content()
        }
    }

    private func runTest() {
        testState = .testing
        let service = RemoteLLMService(configuration: settings.configuration)
        Task { @MainActor in
            do {
                try await service.verifyConnection()
                llmManager.lastAPIError = nil
                testState = .success
            } catch {
                testState = .failure(error.localizedDescription)
            }
        }
    }
}
