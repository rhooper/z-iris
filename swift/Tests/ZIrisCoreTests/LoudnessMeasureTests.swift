import Foundation
import Testing
@testable import ZIrisCore

private func tone(_ hz: Double, amplitude: Double = 1, seconds: Double = 1, rate: Double = 44100) -> [Double] {
    (0..<Int(seconds * rate)).map { amplitude * sin(2 * .pi * hz * Double($0) / rate) }
}

@Suite struct LoudnessMeasureTests {
    @Test func aFullScaleKilohertzToneIsMinusThreeLUFS() {
        // ITU-R BS.1770's reference: a 0 dBFS 997 Hz sine reads -3.01 LUFS.
        #expect(abs(momentaryLoudness([tone(997)], rate: 44100) - -3.01) < 0.1)
        #expect(abs(momentaryLoudness([tone(997, amplitude: 0.5)], rate: 44100) - -9.03) < 0.1)
    }

    @Test func highTonesReadLouderThanLowOnesOfTheSameLevel() {
        let high = momentaryLoudness([tone(3000, amplitude: 0.5)], rate: 44100)
        let low = momentaryLoudness([tone(200, amplitude: 0.5)], rate: 44100)
        #expect(high - low > 3)
    }

    @Test func aBriefSoundReadsQuieterThanALongOne() {
        // Momentary loudness is over 400 ms: 100 ms of tone is a quarter of the energy.
        let brief = momentaryLoudness([tone(997, seconds: 0.1)], rate: 44100)
        let long = momentaryLoudness([tone(997, seconds: 1)], rate: 44100)
        #expect(abs((long - brief) - 6.02) < 0.3)
        #expect(momentaryLoudness([[0, 0, 0]], rate: 44100) == -.infinity)
    }

    @Test func gainReachesTheTargetUnlessThePeakWouldClip() {
        #expect(gainFor(peak: 0, loudness: -20) == 1)
        #expect(gainFor(peak: 0.5, loudness: -.infinity) == 1)
        #expect(abs(gainFor(peak: 0.1, loudness: targetLoudness - 6) - pow(10, 6.0 / 20)) < 1e-9)  // the target limits it
        #expect(abs(gainFor(peak: 0.5, loudness: targetLoudness - 20) - 2) < 1e-9)  // the peak limits it
        #expect(withinTolerance(1.05) && !withinTolerance(1.1))
    }
}
