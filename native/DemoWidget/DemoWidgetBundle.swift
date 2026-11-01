import SwiftUI
import WidgetKit

/// *[demo]'s widgets: Record Idea (Home Screen and Lock Screen), Recent Songs (Home Screen),
/// and the Record Idea button for Control Centre, the Lock Screen and the Action button.
@main
struct DemoWidgetBundle: WidgetBundle {
    var body: some Widget {
        RecordWidget()
        SongsWidget()
        // RecordControl() (Control Centre) is off while the Home Screen widgets are checked: if it fails to load,
        // iOS drops the whole extension, and none of the widgets show in the gallery.
    }
}
