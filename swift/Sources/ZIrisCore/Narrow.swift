// Build zulip:// links that Zulip Desktop opens in the right chat.

/// Encode text the way Zulip does in narrow hashes: percent-encode everything
/// but the unreserved characters, then write "." instead of "%", so a real "."
/// must be encoded first.
public func encodeComponent(_ text: String) -> String {
    var out = ""
    for byte in text.utf8 {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), UInt8(ascii: "-"),
             UInt8(ascii: "~"):
            out.unicodeScalars.append(Unicode.Scalar(byte))
        default:
            out += "." + hex(byte)
        }
    }
    return out
}

private func hex(_ byte: UInt8) -> String {
    let digits = Array("0123456789ABCDEF")
    return String([digits[Int(byte >> 4)], digits[Int(byte & 0xF)]])
}

/// The message's conversation, opened at the message. Uses the forms Zulip's
/// own message links use (Zulip 9 and later): channel/ and with/<id>. The older
/// near/<id> sent Zulip 12's web app into an endless loading loop on some
/// topics, and with/ also follows a message that was moved.
public func narrowURL(_ message: Message) -> String {
    let base = "zulip://\(message.host)/#narrow"
    switch message.kind {
    case .channel:
        let channel = "\(message.channelID ?? 0)-\(encodeComponent(message.channelName ?? ""))"
        let topic = encodeComponent(message.topic ?? "")
        return "\(base)/channel/\(channel)/topic/\(topic)/with/\(message.id)"
    case .dm:
        let ids = message.dmUserIDs.map(String.init).joined(separator: ",")
        let suffix = message.dmUserIDs.count > 1 ? "group" : "pm"
        return "\(base)/dm/\(ids)-\(suffix)/with/\(message.id)"
    }
}
