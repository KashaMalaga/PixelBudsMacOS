import MaestroIOBluetooth

/// A named EQ configuration that maps to a set of five band values
/// matching what the Pixel Buds companion app ships as built-in presets.
/// The wire format uses Float dB in the range -6.0…6.0 per band.
struct EqPreset: Identifiable, Hashable {
    let id: String
    let displayName: String
    let bands: MaestroPw_EqBands

    // MARK: - Built-in presets

    static let all: [EqPreset] = [
        .default_,
        .bassBoost,
        .vocalBoost,
        .trebleBoost,
        .bassReduce,
    ]

    /// Flat response — all bands at 0 dB.
    static let default_ = EqPreset(
        id: "default",
        displayName: "Default",
        bands: .make(lowBass: 0, bass: 0, mid: 0, treble: 0, upperTreble: 0)
    )

    /// Lifts low-frequency response for a fuller, punchier sound.
    static let bassBoost = EqPreset(
        id: "bassBoost",
        displayName: "Bass Boost",
        bands: .make(lowBass: 4.0, bass: 3.0, mid: 1.0, treble: 0, upperTreble: 0)
    )

    /// Emphasises the mid and upper-mid bands where speech and vocals sit.
    static let vocalBoost = EqPreset(
        id: "vocalBoost",
        displayName: "Vocal Boost",
        bands: .make(lowBass: -1.0, bass: 0, mid: 2.0, treble: 3.0, upperTreble: 1.0)
    )

    /// Adds sparkle and air in the high-frequency range.
    static let trebleBoost = EqPreset(
        id: "trebleBoost",
        displayName: "Treble Boost",
        bands: .make(lowBass: 0, bass: 0, mid: 1.0, treble: 3.0, upperTreble: 4.0)
    )

    /// Cuts low-end for environments where bass resonates uncomfortably.
    static let bassReduce = EqPreset(
        id: "bassReduce",
        displayName: "Bass Reduce",
        bands: .make(lowBass: -4.0, bass: -2.0, mid: 0, treble: 0, upperTreble: 0)
    )

    // MARK: - Matching

    /// Returns the preset whose band values all fall within `tolerance` dB of
    /// `bands`, or `nil` when the EQ is in a custom (user-adjusted) state.
    /// The tolerance handles firmware rounding on echo-back (typically < 0.01 dB).
    static func match(_ bands: MaestroPw_EqBands, tolerance: Float = 0.05) -> EqPreset? {
        all.first { preset in
            abs(preset.bands.lowBass    - bands.lowBass)    <= tolerance &&
            abs(preset.bands.bass       - bands.bass)       <= tolerance &&
            abs(preset.bands.mid        - bands.mid)        <= tolerance &&
            abs(preset.bands.treble     - bands.treble)     <= tolerance &&
            abs(preset.bands.upperTreble - bands.upperTreble) <= tolerance
        }
    }
}

// MARK: - MaestroPw_EqBands convenience

private extension MaestroPw_EqBands {
    static func make(
        lowBass: Float, bass: Float, mid: Float, treble: Float, upperTreble: Float
    ) -> MaestroPw_EqBands {
        var b = MaestroPw_EqBands()
        b.lowBass     = lowBass
        b.bass        = bass
        b.mid         = mid
        b.treble      = treble
        b.upperTreble = upperTreble
        return b
    }
}
