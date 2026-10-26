import Foundation

// Store every sound at the same loudness, so one volume means one loudness
// (loudness.py). The measuring and writing are in ZIrisMac.

/// RMS level a stored sound has at 100% volume. Quiet files are raised to it
/// and loud ones lowered, but never so far that the peak would clip.
public let targetRMS = 0.38
/// Files already this close to the target are left alone, so normalizing
/// twice changes nothing.
public let toleranceDB = 0.5

public func gainFor(peak: Double, rms: Double) -> Double {
    if peak <= 0 || rms <= 0 {
        return 1
    }
    return min(targetRMS / rms, 1 / peak)
}

public func withinTolerance(_ gain: Double) -> Bool {
    abs(20 * log10(gain)) < toleranceDB
}
