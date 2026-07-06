import WidgetKit
import SwiftUI

struct QuickActionsProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickActionsEntry {
        QuickActionsEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (QuickActionsEntry) -> Void) {
        completion(QuickActionsEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickActionsEntry>) -> Void) {
        let entry = QuickActionsEntry(date: Date())
        let timeline = Timeline(entries: [entry], policy: .never)
        completion(timeline)
    }
}

struct QuickActionButton: View {
    let icon: String
    let label: String
    let url: URL?

    var body: some View {
        if let url = url {
            Link(destination: url) {
                buttonContent
            }
        } else {
            buttonContent
        }
    }

    var buttonContent: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(.white)
                .frame(width: 40, height: 40)
                .background(
                    Circle()
                        .fill(Color.accentColor)
                )
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.primary)
        }
    }
}

struct QuickActionsEntryView: View {
    var entry: QuickActionsProvider.Entry

    var body: some View {
        HStack(spacing: 12) {
            QuickActionButton(
                icon: "square.and.pencil",
                label: "New Note",
                url: URL(string: "betterkeep://create?type=note")
            )
            QuickActionButton(
                icon: "checklist",
                label: "To-do",
                url: URL(string: "betterkeep://create?type=todo")
            )
            QuickActionButton(
                icon: "mic.fill",
                label: "Voice",
                url: URL(string: "betterkeep://create?type=voice")
            )
            QuickActionButton(
                icon: "photo",
                label: "Photo",
                url: URL(string: "betterkeep://create?type=photo")
            )
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetContainerBackground(Color(.systemBackground))
    }
}

struct QuickActionsWidget: Widget {
    let kind: String = "QuickActionsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QuickActionsProvider()) { entry in
            QuickActionsEntryView(entry: entry)
        }
        .configurationDisplayName("Better Keep Quick Actions")
        .description("Quickly create a note, to-do list, voice note, or photo note.")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}
