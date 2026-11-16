/// What the compositor says about the screen a window is on (color-management-v1's preferred image description), the
/// user's desktop calibration included: how its signal is encoded and how bright its black, reference white and peak are,
/// in cd/m². Zero means the compositor did not say.
public struct DisplayColor: Equatable, Sendable {
    /// The protocol's transfer_function value (11 PQ, 13 HLG, 5 extended linear, 2 gamma 2.2, 9 sRGB).
    public var transfer: UInt32
    public var minimum: Double
    public var maximum: Double
    public var reference: Double
    public var targetMinimum: Double
    public var targetMaximum: Double
    public var targetMaxCLL: Double

    public init(transfer: UInt32, minimum: Double, maximum: Double, reference: Double, targetMinimum: Double = 0, targetMaximum: Double = 0,
                targetMaxCLL: Double = 0) {
        self.transfer = transfer
        self.minimum = minimum
        self.maximum = maximum
        self.reference = reference
        self.targetMinimum = targetMinimum
        self.targetMaximum = targetMaximum
        self.targetMaxCLL = targetMaxCLL
    }

    /// Whether the screen shows more than SDR white: its signal is PQ, HLG or extended linear.
    public var isHDR: Bool { [11, 13, 5].contains(transfer) }

    /// The brightest the screen shows, in cd/m²: the display the compositor targets, else its signal's peak.
    public var peak: Double { targetMaximum > 0 ? targetMaximum : maximum }

    /// How many times brighter than reference white the screen goes; 1 for an SDR screen or one that did not say.
    public var headroom: Double {
        guard isHDR, reference > 0, peak > reference else { return 1 }
        return peak / reference
    }
}
