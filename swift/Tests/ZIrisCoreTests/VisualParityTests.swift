import Foundation
import Testing
import ZIrisCore

@Suite struct VisualParity {
    private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-12 }

    @Test(arguments: Fixture.load("visual"))
    func visual(_ fixture: Fixture) {
        let input = fixture.input
        switch input["op"] as! String {
        case "color":
            let want = fixture.expected as! [Double]
            let got = parseColor(input["text"] as! String)
            #expect(close(got.red, want[0]) && close(got.green, want[1]) && close(got.blue, want[2]))
        case "frames":
            let s = (input["screen"] as! [NSNumber]).map(\.doubleValue)
            let want = fixture.expected as! [String: Any]
            let got = flashFrames(FlashRect(s[0], s[1], s[2], s[3]), mode: input["mode"] as! String)
            let frames = (want["frames"] as! [[NSNumber]]).map { $0.map(\.doubleValue) }
            #expect(got.count == frames.count)
            for (rect, f) in zip(got, frames) {
                #expect(close(rect.x, f[0]) && close(rect.y, f[1]) && close(rect.width, f[2]) && close(rect.height, f[3]))
            }
            #expect(close(startAlpha(mode: input["mode"] as! String), (want["alpha"] as! NSNumber).doubleValue))
        case "fade":
            let n = { (key: String) in (input[key] as! NSNumber).doubleValue }
            #expect(close(fadeAlpha(start: n("start"), elapsed: n("elapsed"), duration: n("duration")),
                          (fixture.expected as! NSNumber).doubleValue))
        default:
            Issue.record("unknown op")
        }
    }
}
