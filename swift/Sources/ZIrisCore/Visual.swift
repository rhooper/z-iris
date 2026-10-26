// Screen flash geometry and timing (visual.py); AppKit stays in ZIrisMac.

public let barFraction = 0.06
public let screenAlpha = 0.35
public let fallbackColor = "#ff3b30"

/// x, y, width, height; origin bottom-left, as NSScreen frames are.
public struct FlashRect: Sendable, Equatable {
    public var x: Double, y: Double, width: Double, height: Double

    public init(_ x: Double, _ y: Double, _ width: Double, _ height: Double) {
        (self.x, self.y, self.width, self.height) = (x, y, width, height)
    }
}

/// "#rrggbb" as sRGB components from 0 to 1; anything else is the fallback red.
public func parseColor(_ text: String) -> (red: Double, green: Double, blue: Double) {
    let digits = Array(text.utf8)
    guard digits.count == 7, digits[0] == UInt8(ascii: "#"),
          let value = UInt32(String(decoding: digits[1...], as: UTF8.self), radix: 16),
          digits[1...].allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 | 0x20 >= 97 && $0 | 0x20 <= 102) })
    else { return parseColor(fallbackColor) }
    return (Double(value >> 16) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
}

public func flashFrames(_ screen: FlashRect, mode: String) -> [FlashRect] {
    let (x, y, w, h) = (screen.x, screen.y, screen.width, screen.height)
    switch mode {
    case "screen": return [screen]
    case "top": return [FlashRect(x, y + h - h * barFraction, w, h * barFraction)]
    case "bottom": return [FlashRect(x, y, w, h * barFraction)]
    case "left": return [FlashRect(x, y, w * barFraction, h)]
    case "right": return [FlashRect(x + w - w * barFraction, y, w * barFraction, h)]
    default: return []
    }
}

public func startAlpha(mode: String) -> Double {
    mode == "screen" ? screenAlpha : 1
}

/// Quadratic ease-out from start to 0 over duration seconds.
public func fadeAlpha(start: Double, elapsed: Double, duration: Double) -> Double {
    if duration <= 0 || elapsed >= duration {
        return 0
    }
    let remaining = 1 - max(elapsed, 0) / duration
    return start * remaining * remaining
}
