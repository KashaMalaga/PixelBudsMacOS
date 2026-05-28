import KeyboardShortcuts

/// App-wide hotkey names. KeyboardShortcuts persists the user's chosen
/// combination under each name in UserDefaults, so adding a new shortcut is
/// purely a matter of declaring its name here and wiring the handler.
///
/// No defaults are set — the recorder UI in Settings starts blank and the
/// user opts in by picking a combination they like.
extension KeyboardShortcuts.Name {
    /// Fires the GFPS "Ring both" command. Useful when the buds are buried
    /// under a couch cushion and the Mac is across the room.
    static let ringBuds = Self("ringBuds")
}
