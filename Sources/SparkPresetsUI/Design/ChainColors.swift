import SparkControl
import SparkDesign
import SwiftUI

/// The seven chain colors of `ChainPlace.accent`, as design colors. They appear only on a pedal's nameplate, its
/// lamp, the ring of a knob and the stripe on top of the control field.
extension ChainPlace {
    var swatch: Swatch { Swatch(red: accent.red, green: accent.green, blue: accent.blue) }
    var color: Color { swatch.color }
}
