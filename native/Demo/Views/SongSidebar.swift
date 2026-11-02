import SwiftUI

extension EnvironmentValues {
    /// Opens a song (or Ideas) in place of the one showing: Start a Song from an idea uses it.
    @Entry var openRoute: (String) -> Void = { _ in }
    /// Opens a song on top of the screen showing (an album's songs use it, so Back returns to the album).
    @Entry var pushRoute: (String) -> Void = { _ in }
}
