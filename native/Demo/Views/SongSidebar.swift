import SwiftUI

extension EnvironmentValues {
    /// Opens a song (or Ideas) in place of the one showing: Start a Song from an idea uses it.
    @Entry var openRoute: (String) -> Void = { _ in }
}
