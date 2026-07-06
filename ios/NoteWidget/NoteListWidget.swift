import WidgetKit
import SwiftUI

struct NoteListWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> NoteListEntry {
        NoteListEntry(date: Date(), notes: [])
    }

    func getSnapshot(in context: Context, completion: @escaping (NoteListEntry) -> Void) {
        let notes = readNoteListData()
        completion(NoteListEntry(date: Date(), notes: notes))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NoteListEntry>) -> Void) {
        let notes = readNoteListData()
        let entry = NoteListEntry(date: Date(), notes: notes)
        let timeline = Timeline(entries: [entry], policy: .never)
        completion(timeline)
    }
}

struct NoteListWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    var entry: NoteListWidgetProvider.Entry

    var body: some View {
        Group {
            if entry.notes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("No notes")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(entry.notes.enumerated()), id: \.offset) { index, note in
                        noteRowView(note)
                            .widgetURL(URL(string: "betterkeep://note?id=\(note.noteId)"))
                        if index < entry.notes.count - 1 {
                            Divider().opacity(0.3)
                        }
                    }
                    if entry.notes.count < 4 {
                        Spacer()
                    }
                }
            }
        }
        .widgetContainerBackground(Color(.systemBackground))
    }

    func noteRowView(_ note: NoteWidgetData) -> some View {
        let stripColor = colorFromHex(note.colorHex)
        let textColor: Color = .primary

        return HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(stripColor)
                .frame(width: 4)
                .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    if note.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                    Text(note.title.isEmpty ? "Untitled" : note.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(textColor)
                        .lineLimit(1)
                    Spacer()
                    Text(note.updatedAt)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }

                if !note.text.isEmpty {
                    Text(note.text)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                if !note.labels.isEmpty || note.hasCheckboxes {
                    HStack(spacing: 4) {
                        if note.hasCheckboxes {
                            Text("\(note.checkboxChecked)/\(note.checkboxTotal)")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                        if !note.labels.isEmpty {
                            Text(note.labels)
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.vertical, 6)
        }
        .padding(.horizontal, 12)
    }
}

struct NoteListWidget: Widget {
    let kind: String = "NoteListWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NoteListWidgetProvider()) { entry in
            NoteListWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Better Keep Notes")
        .description("Shows your recent notes at a glance.")
        .supportedFamilies([.systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}
