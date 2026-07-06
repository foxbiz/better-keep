import WidgetKit
import SwiftUI
import AppIntents

struct ConfiguredNoteWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Note"
    static var description = IntentDescription("Choose the note shown by this widget.")

    @Parameter(title: "Note")
    var note: WidgetNoteEntity?

    init() {}

    init(note: WidgetNoteEntity?) {
        self.note = note
    }
}

struct WidgetNoteEntity: AppEntity, Identifiable {
    let id: String
    let title: String
    let text: String

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Note")
    static var defaultQuery = WidgetNoteQuery()

    var displayRepresentation: DisplayRepresentation {
        let displayTitle = title.isEmpty ? "Untitled" : title
        let displayText = text.isEmpty ? "No text" : text
        return DisplayRepresentation(title: "\(displayTitle)", subtitle: "\(displayText)")
    }
}

struct WidgetNoteQuery: EntityQuery {
    func entities(for identifiers: [WidgetNoteEntity.ID]) async throws -> [WidgetNoteEntity] {
        let identifierSet = Set(identifiers)
        return noteEntities().filter { identifierSet.contains($0.id) }
    }

    func suggestedEntities() async throws -> [WidgetNoteEntity] {
        noteEntities()
    }

    func defaultResult() async -> WidgetNoteEntity? {
        nil
    }

    private func noteEntities() -> [WidgetNoteEntity] {
        readNoteWidgetOptionsData().map { note in
            WidgetNoteEntity(
                id: String(note.noteId),
                title: note.title,
                text: note.text
            )
        }
    }
}

struct ConfiguredNoteWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> NoteWidgetEntry {
        NoteWidgetEntry(date: Date(), noteData: nil, slot: nil, usesSystemConfiguration: true)
    }

    func snapshot(for configuration: ConfiguredNoteWidgetIntent, in context: Context) async -> NoteWidgetEntry {
        NoteWidgetEntry(
            date: Date(),
            noteData: noteData(for: configuration),
            slot: nil,
            usesSystemConfiguration: true
        )
    }

    func timeline(for configuration: ConfiguredNoteWidgetIntent, in context: Context) async -> Timeline<NoteWidgetEntry> {
        let entry = NoteWidgetEntry(
            date: Date(),
            noteData: noteData(for: configuration),
            slot: nil,
            usesSystemConfiguration: true
        )
        return Timeline(entries: [entry], policy: .never)
    }

    private func noteData(for configuration: ConfiguredNoteWidgetIntent) -> NoteWidgetData? {
        guard let noteIdString = configuration.note?.id,
              let noteId = Int(noteIdString) else {
            return nil
        }
        return readNoteWidgetData(noteId: noteId)
    }
}

struct ConfiguredNoteWidget: Widget {
    let kind: String = "ConfiguredNoteWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: ConfiguredNoteWidgetIntent.self, provider: ConfiguredNoteWidgetProvider()) { entry in
            NoteWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Better Keep Configured Note")
        .description("Use Edit Widget to choose an independent note.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}
