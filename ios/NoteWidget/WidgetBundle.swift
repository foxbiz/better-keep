import WidgetKit
import SwiftUI

extension View {
    @ViewBuilder
    func widgetContainerBackground(_ color: Color) -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            frame(maxWidth: .infinity, maxHeight: .infinity)
                .containerBackground(color, for: .widget)
        } else {
            frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(color)
        }
    }
}

@main
struct BetterKeepWidgetBundle: WidgetBundle {
    var body: some Widget {
        ConfiguredNoteWidget()
        NoteWidget()
        NoteWidget2()
        NoteWidget3()
        NoteWidget4()
        NoteListWidget()
        QuickActionsWidget()
    }
}
