import SwiftUI

/// Settings for an OpenAI compatible chat completions endpoint.
struct LLMAPICard: View {
    @ObservedObject private var settings = LLMSettings.shared
    @ObservedObject private var llmManager = LLMManager.shared
    @Environment(\.colorScheme) var colorScheme

    private enum TestState: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

    @State private var testState: TestState = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            presetRow
            endpointRow
            modelRow
            reasoningRow
            keyRow
            testRow
            testNote
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

    private var reasoningRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            row(title: t("Reasoning")) {
                Picker("", selection: $settings.reasoningEffort) {
                    ForEach(LLMSettings.reasoningEffortOptions, id: \.self) { option in
                        Text(option.isEmpty ? t("Service default") : option).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            Text(t("Sonor sends this as `reasoning_effort`. A model without reasoning ignores it. A high effort makes the model think longer before it answers."))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

    private var testNote: some View {
        Text(t("The test runs one small rewrite with the settings above, so the times match real dictation. A high reasoning effort makes the test slow."))
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
        case .success(let summary):
            message(text: summary, systemImage: "checkmark.circle.fill", color: .green)
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
                let probe = try await service.probe()
                llmManager.lastAPIError = nil
                testState = .success(Self.summary(for: probe))
            } catch {
                testState = .failure(error.localizedDescription)
            }
        }
    }

    /// Reads as: Connection works.  First reply 1.2 s · Total 3.4 s · 90 chars/s
    private static func summary(for probe: RemoteLLMProbe) -> String {
        let first = String(format: "%.1f", probe.timeToFirstToken)
        let total = String(format: "%.1f", probe.totalTime)
        let speed = String(format: "%.0f", probe.charactersPerSecond)
        return "\(t("Connection works."))  \(t("First reply")) \(first) s · \(t("Total")) \(total) s · \(speed) \(t("chars/s"))"
    }
}
