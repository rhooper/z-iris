import Foundation

// Store every sound at the same loudness, so one volume means one loudness.
// Loudness is as people hear it (ITU-R BS.1770, the measure behind EBU R 128):
// K-weighted, so a high tone counts for more than a low one of the same
// level, and taken over the loudest 400 ms, so a brief blip counts for less
// than a held note. The reading and writing of files are in ZIrisMac.

/// Momentary loudness (LUFS) a stored sound has at 100% volume. Quiet files
/// are raised to it and loud ones lowered, but never so far that the peak
/// would clip.
public let targetLoudness = -13.0
/// Files already this close to the target are left alone, so normalizing
/// twice changes nothing.
public let toleranceDB = 0.5

/// One second-order filter section, run over a signal.
private struct Biquad {
    var b0, b1, b2, a1, a2: Double

    func run(_ input: [Double]) -> [Double] {
        var output = [Double](repeating: 0, count: input.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for (n, x) in input.enumerated() {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            output[n] = y
            (x2, x1, y2, y1) = (x1, x, y1, y)
        }
        return output
    }
}

/// BS.1770's K-weighting at any sample rate: a +4 dB shelf above about
/// 1.7 kHz (the head's effect), then a high-pass below about 38 Hz. These
/// are libebur128's formulas, which give the standard's 48 kHz coefficients.
private func kWeighting(rate: Double) -> [Biquad] {
    var f0 = 1681.974450955533, q = 0.7071752369554196
    var k = tan(Double.pi * f0 / rate)
    let vh = pow(10, 3.999843853973347 / 20), vb = pow(vh, 0.4996667741545416)
    var a0 = 1 + k / q + k * k
    let shelf = Biquad(
        b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0, b2: (vh - vb * k / q + k * k) / a0,
        a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0
    )
    f0 = 38.13547087602444
    q = 0.5003270373238773
    k = tan(Double.pi * f0 / rate)
    a0 = 1 + k / q + k * k
    let pass = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
    return [shelf, pass]
}

/// The loudest 400 ms of a sound, in LUFS; -infinity for silence. A sound
/// shorter than 400 ms is measured as that window with silence after it.
public func momentaryLoudness(_ channels: [[Double]], rate: Double) -> Double {
    let window = Int(0.4 * rate), hop = max(1, Int(0.01 * rate))
    let length = channels.map(\.count).max() ?? 0
    guard length > 0 else { return -.infinity }
    // Running sums of each channel's K-weighted squares, summed over channels.
    var energy = [Double](repeating: 0, count: length + 1)
    for channel in channels {
        var weighted = channel
        for filter in kWeighting(rate: rate) {
            weighted = filter.run(weighted)
        }
        var total = 0.0
        for n in 0..<length {
            total += n < weighted.count ? weighted[n] * weighted[n] : 0
            energy[n + 1] += total
        }
    }
    var loudest = 0.0
    var start = 0
    repeat {
        let end = min(start + window, length)
        loudest = max(loudest, (energy[end] - energy[start]) / Double(window))
        start += hop
    } while start + window <= length
    return loudest > 0 ? -0.691 + 10 * log10(loudest) : -.infinity
}

/// The gain that brings a sound to the target loudness, held back so its
/// largest sample magnitude stays at full scale.
public func gainFor(peak: Double, loudness: Double) -> Double {
    if peak <= 0 || !loudness.isFinite {
        return 1
    }
    return min(pow(10, (targetLoudness - loudness) / 20), 1 / peak)
}

public func withinTolerance(_ gain: Double) -> Bool {
    abs(20 * log10(gain)) < toleranceDB
}
