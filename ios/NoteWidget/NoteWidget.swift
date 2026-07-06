import WidgetKit
import SwiftUI

struct NoteWidgetProvider: TimelineProvider {
    let slot: Int

    func placeholder(in context: Context) -> NoteWidgetEntry {
        NoteWidgetEntry(date: Date(), noteData: nil, slot: slot)
    }

    func getSnapshot(in context: Context, completion: @escaping (NoteWidgetEntry) -> Void) {
        if context.isPreview {
            completion(NoteWidgetEntry(date: Date(), noteData: nil, slot: slot))
            return
        }

        let data = readNoteWidgetData(slot: slot)
        completion(NoteWidgetEntry(date: Date(), noteData: data, slot: slot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NoteWidgetEntry>) -> Void) {
        let data = readNoteWidgetData(slot: slot)
        let entry = NoteWidgetEntry(date: Date(), noteData: data, slot: slot)
        let timeline = Timeline(entries: [entry], policy: .never)
        completion(timeline)
    }
}

struct NoteWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    var entry: NoteWidgetProvider.Entry

    var body: some View {
        if let note = entry.noteData {
            noteView(note)
                .widgetURL(URL(string: "betterkeep://note?id=\(note.noteId)"))
        } else {
            emptyView
                .widgetContainerBackground(Color(.systemBackground))
                .widgetURL(selectionURL)
        }
    }

    var selectionURL: URL? {
        guard let slot = entry.slot else {
            return nil
        }
        return URL(string: "betterkeep://widget/select-note?target=note&iosSlot=\(slot)")
    }

    var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "note.text")
                .font(.title2)
                .foregroundColor(.secondary)
            Text("No note selected")
                .font(.caption)
                .foregroundColor(.secondary)
            Text(entry.usesSystemConfiguration ? "Edit widget to select a note" : "Tap to select a note")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
    }

    @ViewBuilder
    func noteView(_ note: NoteWidgetData) -> some View {
        let bgColor = colorFromHex(note.colorHex)
        let textColor: Color = note.foregroundDark ? .white : .black
        let secondaryColor: Color = note.foregroundDark
            ? .white.opacity(0.7)
            : .black.opacity(0.6)

        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top) {
                    if note.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                            .foregroundColor(textColor.opacity(0.6))
                    }
                    if note.locked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundColor(textColor.opacity(0.6))
                    }
                    Spacer()
                    Text(note.updatedAt)
                        .font(.system(size: 9))
                        .foregroundColor(secondaryColor)
                }

                if !note.title.isEmpty {
                    Text(note.title)
                        .font(.system(size: family == .systemSmall ? 12 : 14, weight: .bold))
                        .foregroundColor(textColor)
                        .lineLimit(1)
                }

                if !note.text.isEmpty {
                    Text(note.text)
                        .font(.system(size: family == .systemSmall ? 10 : 12))
                        .foregroundColor(secondaryColor)
                        .lineLimit(family == .systemSmall ? 4 : 8)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 4)

                HStack(spacing: 4) {
                    if note.hasCheckboxes {
                        let progress = note.checkboxTotal > 0
                            ? "\(note.checkboxChecked)/\(note.checkboxTotal)"
                            : ""
                        if !progress.isEmpty {
                            Image(systemName: "checklist")
                                .font(.system(size: 9))
                            Text(progress)
                                .font(.system(size: 10))
                                .foregroundColor(secondaryColor)
                        }
                    }

                    if note.hasReminder {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 9))
                            .foregroundColor(textColor)
                    }

                    if note.hasAttachments {
                        Image(systemName: "paperclip")
                            .font(.system(size: 9))
                            .foregroundColor(secondaryColor)
                    }

                    Spacer()

                    if !note.labels.isEmpty {
                        Text(note.labels)
                            .font(.system(size: 8))
                            .foregroundColor(secondaryColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            .padding(12)
        }
        .widgetContainerBackground(bgColor)
    }
}

struct NoteWidget: Widget {
    let kind: String = "NoteWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NoteWidgetProvider(slot: 1)) { entry in
            NoteWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Better Keep Tap Note 1")
        .description("Tap the empty widget to choose note slot 1.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

struct NoteWidget2: Widget {
    let kind: String = "NoteWidget_2"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NoteWidgetProvider(slot: 2)) { entry in
            NoteWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Better Keep Tap Note 2")
        .description("Tap the empty widget to choose note slot 2.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

struct NoteWidget3: Widget {
    let kind: String = "NoteWidget_3"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NoteWidgetProvider(slot: 3)) { entry in
            NoteWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Better Keep Tap Note 3")
        .description("Tap the empty widget to choose note slot 3.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

struct NoteWidget4: Widget {
    let kind: String = "NoteWidget_4"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NoteWidgetProvider(slot: 4)) { entry in
            NoteWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Better Keep Tap Note 4")
        .description("Tap the empty widget to choose note slot 4.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}
