import AppIntents
import Foundation

@available(iOS 16.0, *)
struct CreateVoiceNoteIntent: AppIntent {
  static let title: LocalizedStringResource = "Create a Better Keep Note"
  static let description = IntentDescription("Creates a note in Better Keep.")
  static let openAppWhenRun = true
  static let authenticationPolicy: IntentAuthenticationPolicy =
    .requiresLocalDeviceAuthentication

  @Parameter(
    title: "Note",
    requestValueDialog: IntentDialog("What should the note say?")
  )
  var text: String

  static var parameterSummary: some ParameterSummary {
    Summary("Create a note with \(\.$text)")
  }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let result = await AssistantNotesBridge.shared.submit(
      AssistantNoteBridgeRequest(
        requestId: UUID().uuidString,
        source: "siri",
        title: nil,
        text: text
      )
    )

    switch result.status {
    case .saved:
      return .result(dialog: "Saved to Better Keep")
    case .cancelled:
      return .result(dialog: "The note was not saved")
    case .unavailable:
      return .result(dialog: "Better Keep is not ready. Open the app and try again")
    case .failed:
      return .result(dialog: "Better Keep could not save the note")
    }
  }
}

@available(iOS 16.0, *)
struct BetterKeepAppShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: CreateVoiceNoteIntent(),
      phrases: [
        "Create a note in \(.applicationName)",
        "Add a note to \(.applicationName)",
      ],
      shortTitle: "Create Note",
      systemImageName: "note.text.badge.plus"
    )
  }
}
