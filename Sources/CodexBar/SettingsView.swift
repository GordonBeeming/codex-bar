import AppKit
import CodexBarCore
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var model: UsageViewModel
    @State private var folderError: String?
    @State private var telemetryIntervalDraft = 5
    @State private var telemetryRetentionDraft = 90
    @State private var telemetryUnlimitedRetentionDraft = false
    @State private var telemetryDirectoryDraft = TelemetryConfiguration.defaultDirectory.path

    var body: some View {
        Form {
            Section("Usage data source") {
                LabeledContent("Source", value: "Codex CLI")
                if let planType = model.planType {
                    LabeledContent("Plan", value: planType.capitalized)
                }
                Text("Uses Codex's managed ChatGPT sign-in through app-server. CodexBar never reads or refreshes your sign-in tokens itself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Usage colours") {
                Toggle("Use default severity levels", isOn: $settings.useDefaultSeverity)

                if !settings.useDefaultSeverity {
                    ThresholdBarView(
                        warningPercent: $settings.warningThresholdPercent,
                        criticalPercent: $settings.criticalThresholdPercent
                    )
                    .padding(.vertical, 4)

                    Text("Drag the splitters: blue is fine, orange from the warning threshold, red from the critical one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Telemetry") {
                Toggle("Record telemetry to disk", isOn: $settings.telemetryEnabled)

                Text("Save usage for every Codex limit and token totals from sessions on this Mac. Prompts, responses, and sign-in credentials aren't exported.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Capture every").fixedSize()
                    Spacer()
                    telemetryNumberField("Minutes", value: $telemetryIntervalDraft)
                    Text(telemetryIntervalDraft == 1 ? "minute" : "minutes")
                        .fixedSize()
                        .frame(width: 60, alignment: .leading)
                    Stepper("Interval", value: $telemetryIntervalDraft, in: 1...1_440)
                        .labelsHidden()
                        .fixedSize()
                }
                Toggle("Unlimited retention", isOn: $telemetryUnlimitedRetentionDraft)
                if telemetryUnlimitedRetentionDraft {
                    Text("Files are kept until you delete them. Automatic cleanup is disabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("Keep files for").fixedSize()
                        Spacer()
                        telemetryNumberField("Days", value: $telemetryRetentionDraft)
                        Text(telemetryRetentionDraft == 1 ? "day" : "days")
                            .fixedSize()
                            .frame(width: 60, alignment: .leading)
                        Stepper("Retention", value: $telemetryRetentionDraft, in: 1...3_650)
                            .labelsHidden()
                            .fixedSize()
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Save to")
                    Text(telemetryDirectoryDraft)
                        .font(.caption)
                        .textSelection(.enabled)
                        .lineLimit(nil)
                    HStack {
                        Button("Choose folder…", action: chooseTelemetryFolder)
                        Button("Open in Finder", action: openTelemetryFolder)
                    }
                }

                Button("Apply telemetry settings") {
                    settings.telemetryIntervalMinutes = telemetryIntervalDraft
                    settings.telemetryRetentionDays = selectedRetentionDays
                    settings.telemetryDirectory = telemetryDirectoryDraft
                }
                .disabled(!(1...1_440).contains(telemetryIntervalDraft)
                    || (!telemetryUnlimitedRetentionDraft && !(1...3_650).contains(telemetryRetentionDraft))
                    || (telemetryIntervalDraft == settings.telemetryIntervalMinutes && selectedRetentionDays == settings.telemetryRetentionDays
                        && telemetryDirectoryDraft == settings.telemetryDirectory))
                .help("Saves the interval, retention, and folder. Expired telemetry files are removed on later writes when retention is limited.")

                Text("OTLP JSON, in separate daily metrics and event files. Reset-credit changes are recorded when detected. Local token totals include archived sessions and exclude inherited fork usage. Account token summaries are included when Codex supplies them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.telemetryEnabled, let lastWrite = model.lastTelemetryWrite {
                    LabeledContent("Last capture") {
                        Text(lastWrite, format: .dateTime.hour().minute().second())
                    }
                }
                if let error = folderError ?? model.telemetryError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Menu bar") {
                Picker("Percentage", selection: menuBarPercentageSelection) {
                    Text("Highest").tag(MenuBarPercentageSelection.highest)
                    ForEach(model.limits) { limit in
                        Text(limit.name).tag(MenuBarPercentageSelection.limit(limit.id))
                    }
                }

                Text("If the selected percentage isn't available, CodexBar shows the highest percentage instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("⛽ Fuel tank mode", isOn: $settings.fuelTankMode)

                Text("Show fuel remaining instead of usage consumed: every percentage and bar starts full and drains toward empty as you burn through a limit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Show 🔥 when burning over pace", isOn: $settings.showMenuBarFlame)

                Text("The flame appears next to the percentage when a limit burns faster than its window's steady pace. Weekly turns a deeper red; the five-hour session stays orange.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Celebrations") {
                Toggle("Enable celebrations", isOn: $settings.celebrationsEnabled)

                if settings.celebrationsEnabled {
                    ForEach(CelebrationTrigger.allCases, id: \.self) { trigger in
                        celebrationRow(trigger)
                    }
                } else {
                    Text("Play a full-screen reaction when a usage window resets or your weekly usage moves over pace.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("General") {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                    .disabled(!model.launchAtLoginAvailable)
                    .help(model.launchAtLoginAvailable ? "" : "Available when installed as CodexBar.app")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 680)
        .onAppear {
            telemetryIntervalDraft = settings.telemetryIntervalMinutes
            telemetryUnlimitedRetentionDraft = settings.telemetryRetentionDays == TelemetryConfiguration.unlimitedRetentionDays
            telemetryRetentionDraft = telemetryUnlimitedRetentionDraft ? 90 : settings.telemetryRetentionDays
            telemetryDirectoryDraft = settings.telemetryDirectory
        }
    }

    private var selectedRetentionDays: Int {
        telemetryUnlimitedRetentionDraft ? TelemetryConfiguration.unlimitedRetentionDays : telemetryRetentionDraft
    }

    private func telemetryNumberField(_ title: String, value: Binding<Int>) -> some View {
        TextField(title, value: value, format: .number.grouping(.never))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 64)
            .accessibilityLabel(title)
    }

    private func chooseTelemetryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: telemetryDirectoryDraft, isDirectory: true)
        panel.prompt = "Use folder"
        if panel.runModal() == .OK, let url = panel.url {
            telemetryDirectoryDraft = url.path
            folderError = nil
        }
    }

    private func openTelemetryFolder() {
        let directory = URL(fileURLWithPath: telemetryDirectoryDraft, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            guard NSWorkspace.shared.open(directory) else {
                folderError = "Couldn't open the telemetry folder in Finder"
                return
            }
            folderError = nil
        } catch { folderError = error.localizedDescription }
    }

    private var menuBarPercentageSelection: Binding<MenuBarPercentageSelection> {
        Binding(
            get: {
                guard
                    let selectedID = settings.menuBarPercentageSelection.limitID,
                    model.limits.contains(where: { $0.id == selectedID })
                else {
                    return .highest
                }
                return .limit(selectedID)
            },
            set: { settings.menuBarPercentageSelection = $0 }
        )
    }

    private func celebrationRow(_ trigger: CelebrationTrigger) -> some View {
        let enabled = Binding(
            get: { settings.celebrationEnabled(for: trigger) },
            set: { settings.setCelebrationEnabled($0, for: trigger) }
        )
        let reaction = Binding(
            get: { settings.reaction(for: trigger) },
            set: { settings.setReaction($0, for: trigger) }
        )

        return VStack(alignment: .leading, spacing: 8) {
            Toggle(trigger.displayName, isOn: enabled)

            if enabled.wrappedValue {
                HStack {
                    Picker("Effect", selection: reaction) {
                        ForEach(ReactionChoice.allCases, id: \.self) { choice in
                            Text(choice.displayName).tag(choice)
                        }
                    }
                    Button("Test") {
                        model.previewCelebration(reaction.wrappedValue)
                    }
                }
                .padding(.leading, 16)
            }
        }
    }
}
