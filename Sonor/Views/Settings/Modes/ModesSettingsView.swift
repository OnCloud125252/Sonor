import SwiftUI
import UniformTypeIdentifiers

struct ModesSettingsView: View {
    @Binding var modes: [VoiceMode]
    @Binding var selectedModeID: String
    @Binding var isShowingSidePanel: Bool
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject private var localizer = LocalizationManager.shared
    @State private var isShowingInfo = false
    let columns = [
        GridItem(.adaptive(minimum: 160))
    ]
    @State private var isHoveringPlus = false
    @State private var draggingModeID: UUID? = nil
    /// Mirrors the stored default so the star updates as soon as it is set.
    @State private var defaultModeID: String = UserDefaults.standard.string(forKey: VoiceMode.defaultModeIDKey) ?? ""

    /// "Pure Text" keeps its own wide card at the top, so the grid shows everything else.
    private var gridModes: [VoiceMode] {
        modes.filter { $0.name != "Pure Text" }
    }
    private var enabledCount: Int {
        VoiceMode.active(in: modes).count
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                HStack(spacing: 10) {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.primary)
                    Text(t("Assistants"))
                        .font(.system(size: 28, weight: .bold))
                    Button(action: {
                        isShowingInfo = true
                    }) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(t("Learn more about Assistants"))
                }
                Spacer()
                Button(action: {
                    addNewMode()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .bold))
                        Text(t("Add Assistant"))
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(colorScheme == .dark ? Color.white : Color.black)
                    .foregroundColor(colorScheme == .dark ? .black : .white)
                    .cornerRadius(20)
                    .scaleEffect(isHoveringPlus ? 1.05 : 1.0)
                    .animation(.spring(), value: isHoveringPlus)
                    .onHover { hovering in
                        isHoveringPlus = hovering
                    }
                }
                .buttonStyle(.plain)
            }
            Text(t("Drag a card to reorder. The order sets how the assistant shortcut cycles through them."))
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            ScrollView {
                VStack(spacing: 15) {
                    if let rawOutput = modes.first(where: { $0.name == "Pure Text" }) {
                        modeCard(for: rawOutput, isRawOutput: true)
                            .frame(maxWidth: .infinity)
                    }
                    LazyVGrid(columns: columns, spacing: 15) {
                        ForEach(gridModes) { mode in
                            modeCard(for: mode, isRawOutput: false)
                                .onDrag {
                                    draggingModeID = mode.id
                                    return NSItemProvider(object: mode.id.uuidString as NSString)
                                }
                                .onDrop(
                                    of: [UTType.text],
                                    delegate: ModeReorderDropDelegate(
                                        target: mode,
                                        modes: $modes,
                                        draggingModeID: $draggingModeID,
                                        onReordered: persistModes
                                    )
                                )
                        }
                    }
                }
                .padding(.top, 10)
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }
        }
        .onAppear {
            defaultModeID = UserDefaults.standard.string(forKey: VoiceMode.defaultModeIDKey) ?? ""
        }
        .sheet(isPresented: $isShowingInfo) {
            AssistantsExplanationView()
        }
    }

    private func modeCard(for mode: VoiceMode, isRawOutput: Bool) -> some View {
        ModeCard(
            mode: mode,
            isSelected: selectedModeID == mode.id.uuidString,
            isPremium: true,
            isRawOutput: isRawOutput,
            isDefault: defaultModeID == mode.id.uuidString,
            onToggleEnabled: { toggleEnabled(mode) },
            onMakeDefault: { makeDefault(mode) }
        ) {
            selectedModeID = mode.id.uuidString
        } onSettings: {
            selectedModeID = mode.id.uuidString
            withAnimation {
                isShowingSidePanel = true
            }
        }
        .opacity(draggingModeID == mode.id ? 0.4 : 1.0)
    }

    private func toggleEnabled(_ mode: VoiceMode) {
        guard let index = modes.firstIndex(where: { $0.id == mode.id }) else { return }
        let turningOff = modes[index].isActive
        // Recording needs somewhere to go, so the last enabled assistant cannot be switched off.
        if turningOff && enabledCount <= 1 { return }
        withAnimation {
            modes[index].isEnabled = !turningOff
        }
        if turningOff && defaultModeID == mode.id.uuidString {
            // The default was just disabled, so hand the role to the next enabled assistant.
            if let replacement = VoiceMode.active(in: modes).first {
                VoiceMode.setDefaultModeID(replacement.id)
                defaultModeID = replacement.id.uuidString
            }
        }
        persistModes()
    }

    private func makeDefault(_ mode: VoiceMode) {
        guard mode.isActive else { return }
        VoiceMode.setDefaultModeID(mode.id)
        defaultModeID = mode.id.uuidString
        NotificationCenter.default.post(name: Notification.Name("VoiceModesUpdated"), object: nil)
    }

    private func persistModes() {
        guard let data = try? JSONEncoder().encode(modes) else { return }
        UserDefaults.standard.set(data, forKey: "voiceModes")
        NotificationCenter.default.post(name: Notification.Name("VoiceModesUpdated"), object: nil)
    }
    private func addNewMode() {
        let baseName = t("New Assistant")
        var finalName = baseName
        var counter = 2
        
        while modes.contains(where: { $0.name == finalName }) {
            finalName = "\(baseName) (\(counter))"
            counter += 1
        }
        
        let newMode = VoiceMode(name: finalName, prompt: "", boundAppBundleIDs: [], audioBehavior: .keep, assistantType: "dictation", language: "auto", fallbackBehavior: "overlay")
        modes.append(newMode)
        persistModes()
        selectedModeID = newMode.id.uuidString
    }
}

/// Moves the dragged assistant in front of the card it is dropped on.
private struct ModeReorderDropDelegate: DropDelegate {
    let target: VoiceMode
    @Binding var modes: [VoiceMode]
    @Binding var draggingModeID: UUID?
    let onReordered: () -> Void

    func dropEntered(info: DropInfo) {
        guard let draggingModeID = draggingModeID,
              draggingModeID != target.id,
              let from = modes.firstIndex(where: { $0.id == draggingModeID }),
              let to = modes.firstIndex(where: { $0.id == target.id }) else { return }
        withAnimation {
            modes.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingModeID = nil
        onReordered()
        return true
    }
}
