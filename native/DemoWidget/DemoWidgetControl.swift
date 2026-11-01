import AppIntents
import SwiftUI
import WidgetKit

/// Record Idea for Control Centre, the Lock Screen's bottom corners and the Action button (iOS 18 and later):
/// opens *[demo] straight into recording.
struct RecordControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.hellodemo.demo.record") {
            ControlWidgetButton(action: OpenURLIntent(Links.url("record"))) {
                Label("Record Idea", systemImage: "mic.fill")
            }
        }
        .displayName("Record Idea")
        .description("Open *[demo] and start recording an idea.")
    }
}
