import SwiftUI
import WidgetKit

/// *[demo]'s widgets: Record Idea (Home Screen and Lock Screen), Recent Songs (Home Screen),
/// and the Record Idea button for Control Centre, the Lock Screen and the Action button.
@main
struct DemoWidgetBundle: WidgetBundle {
    var body: some Widget {
        RecordWidget()
        SongsWidget()
        RecordControl()
    }
}
