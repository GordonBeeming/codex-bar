import AppKit
import CodexBarCore
import SwiftUI

struct UsageMenuView: View {
    @Bindable var model: UsageViewModel
    var settings: AppSettings

    @Environment(\.openSettings) private var openSettings
    @State private var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header(now: now)

            if let lastError = model.lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()
            rows(now: now)
            Divider()

            HStack {
                Button("Settings…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                Spacer()
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .padding()
        .frame(width: 320)
        .onAppear {
            now = Date()
            model.refreshIfStale()
        }
        .task {
            while !Task.isCancelled {
                guard (try? await Task.sleep(for: .seconds(1))) != nil else { break }
                now = Date()
            }
        }
    }

    private func header(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Codex")
                    .font(.headline)
                if let planType = model.planType {
                    Text(planType.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh")
                }
            }
            Text(model.lastUpdated.map { ResetFormatting.updatedAgoString(since: $0, now: now) } ?? "Never updated")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func rows(now: Date) -> some View {
        if model.limits.isEmpty {
            Text(model.isRefreshing ? "Loading usage…" : "No usage data")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            ForEach(Array(model.limits.enumerated()), id: \.element.id) { index, limit in
                if index > 0 {
                    Divider()
                }
                LimitRowView(
                    limit: limit,
                    now: now,
                    severity: settings.thresholds.resolve(for: limit)
                )
            }
        }
    }
}
