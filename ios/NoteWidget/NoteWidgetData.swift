import WidgetKit
import SwiftUI

struct NoteWidgetEntry: TimelineEntry {
    let date: Date
    let noteData: NoteWidgetData?
    let slot: Int?
    let usesSystemConfiguration: Bool

    init(
        date: Date,
        noteData: NoteWidgetData?,
        slot: Int?,
        usesSystemConfiguration: Bool = false
    ) {
        self.date = date
        self.noteData = noteData
        self.slot = slot
        self.usesSystemConfiguration = usesSystemConfiguration
    }
}

struct NoteWidgetData: Decodable {
    let noteId: Int
    let title: String
    let text: String
    let colorHex: String
    let foregroundDark: Bool
    let labels: String
    let pinned: Bool
    let hasReminder: Bool
    let checkboxChecked: Int
    let checkboxTotal: Int
    let hasCheckboxes: Bool
    let updatedAt: String
    let locked: Bool
    let hasAttachments: Bool
}

struct NoteListEntry: TimelineEntry {
    let date: Date
    let notes: [NoteWidgetData]
}

struct QuickActionsEntry: TimelineEntry {
    let date: Date
}

func colorFromHex(_ hex: String) -> Color {
    let hexClean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    var int: UInt64 = 0
    Scanner(string: hexClean).scanHexInt64(&int)
    let a = Double((int >> 24) & 0xFF) / 255.0
    let r = Double((int >> 16) & 0xFF) / 255.0
    let g = Double((int >> 8) & 0xFF) / 255.0
    let b = Double(int & 0xFF) / 255.0
    return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
}

func readNoteWidgetData(slot: Int) -> NoteWidgetData? {
    guard let shared = UserDefaults(suiteName: "group.io.foxbiz.better-keep") else {
        return nil
    }
    guard let jsonString = shared.string(forKey: "note_widget_data_ios_\(slot)"),
          !jsonString.isEmpty,
          let jsonData = jsonString.data(using: .utf8) else {
        return nil
    }
    return try? JSONDecoder().decode(NoteWidgetData.self, from: jsonData)
}

func readNoteWidgetData(noteId: Int) -> NoteWidgetData? {
    readNoteWidgetOptionsData().first { $0.noteId == noteId }
}

func readNoteWidgetOptionsData() -> [NoteWidgetData] {
    guard let shared = UserDefaults(suiteName: "group.io.foxbiz.better-keep") else {
        return []
    }
    guard let jsonString = shared.string(forKey: "note_widget_options_data"),
          !jsonString.isEmpty,
          let jsonData = jsonString.data(using: .utf8) else {
        return []
    }
    return (try? JSONDecoder().decode([NoteWidgetData].self, from: jsonData)) ?? []
}

func readNoteListData() -> [NoteWidgetData] {
    guard let shared = UserDefaults(suiteName: "group.io.foxbiz.better-keep") else {
        return []
    }
    guard let jsonString = shared.string(forKey: "note_list_widget_data"),
          !jsonString.isEmpty,
          let jsonData = jsonString.data(using: .utf8) else {
        return []
    }
    return (try? JSONDecoder().decode([NoteWidgetData].self, from: jsonData)) ?? []
}
