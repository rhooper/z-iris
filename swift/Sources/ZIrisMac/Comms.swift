import AppKit
import Intents
import Security
import UserNotifications
import ZIrisCore

// Communication notifications: the sender's face as the icon (comms.py,
// with the calls proven in docs/sender-icons-spike.md). They need the
// com.apple.developer.usernotifications.communication entitlement; without it
// macOS quietly shows a plain notification, so callers check first.

public let communicationEntitlement = "com.apple.developer.usernotifications.communication"

public struct CommsError: Error, CustomStringConvertible {
    public var description: String
}

/// Whether this process is signed with the communication entitlement.
public let hasCommunicationEntitlement: Bool = {
    guard let task = SecTaskCreateFromSelf(nil) else { return false }
    return SecTaskCopyValueForEntitlement(task, communicationEntitlement as CFString, nil) != nil
}()

public enum Urgency: Sendable {
    case passive, active, timeSensitive

    var level: UNNotificationInterruptionLevel {
        switch self {
        case .passive: .passive
        case .active: .active
        case .timeSensitive: .timeSensitive
        }
    }
}

private func person(_ handle: String, _ name: String, _ image: String?) -> INPerson {
    INPerson(
        personHandle: INPersonHandle(value: handle, type: .unknown), nameComponents: nil, displayName: name,
        image: image.flatMap { INImage(url: URL(fileURLWithPath: $0)) }, contactIdentifier: nil, customIdentifier: handle
    )
}

/// A copy macOS may move into its own store.
func attachment(_ path: String?) -> UNNotificationAttachment? {
    guard let path, FileManager.default.fileExists(atPath: path) else { return nil }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let copy = folder.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
    guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
          (try? FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: copy)) != nil
    else { return nil }
    return try? UNNotificationAttachment(identifier: "", url: copy)
}

/// Show one notification from sender. Throws CommsError before anything is
/// shown, so the caller can send a plain one instead.
public func sendCommunication(
    identifier: String, title: String, body: String, sender: Sender, urgency: Urgency = .active,
    groupImage: String? = nil, center: UNUserNotificationCenter = .current()
) async throws {
    let from = person(sender.handle, sender.name, sender.avatar)
    let recipients = sender.groupName == nil ? nil
        : sender.members.filter { $0.handle != sender.handle }.map { person($0.handle, $0.name, nil) }
    let intent = INSendMessageIntent(
        recipients: recipients, outgoingMessageType: .outgoingMessageText, content: body,
        speakableGroupName: sender.groupName.map { INSpeakableString(spokenPhrase: $0) },
        conversationIdentifier: sender.conversation, serviceName: "Zulip", sender: from, attachments: nil
    )
    if let groupImage, let image = INImage(url: URL(fileURLWithPath: groupImage)) {
        // Swift marks the key-path form unavailable on macOS; the Objective-C
        // method is there and works (docs/sender-icons-spike.md).
        _ = intent.perform(NSSelectorFromString("setImage:forParameterNamed:"), with: image, with: "speakableGroupName")
    }
    let interaction = INInteraction(intent: intent, response: nil)
    interaction.direction = .incoming
    // The update works without the donation, so a slow one is not waited for.
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        let once = Once()
        interaction.donate { _ in once.run { done.resume() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { once.run { done.resume() } }
    }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.threadIdentifier = sender.conversation
    content.interruptionLevel = urgency.level
    // The avatar is the icon now; the thumbnail is only the message's own picture.
    if let picture = attachment(sender.picture) {
        content.attachments = [picture]
    }
    let updated: UNNotificationContent
    do {
        updated = try content.updating(from: intent)
    } catch {
        throw CommsError(description: "macOS refused the sender (is the communication entitlement signed in?)")
    }
    try await center.add(UNNotificationRequest(identifier: identifier, content: updated, trigger: nil))
}

/// Runs its work the first time only.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ work: () -> Void) {
        let first = lock.withLock { () -> Bool in
            defer { done = true }
            return !done
        }
        if first { work() }
    }
}

public let groupPictures = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/z-iris/groups")

/// A PNG of the group's tiles, drawn once per set of tiles; nil on failure.
public func groupPicture(_ sender: Sender, in directory: URL = groupPictures, size: Int = 256) -> String? {
    let tiles = groupTiles(sender)
    let url = directory.appendingPathComponent(groupPictureName(tiles))
    if FileManager.default.fileExists(atPath: url.path) {
        return url.path
    }
    guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil,
          let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    let side = Double(size), half = side / 2
    // One tile fills; two sit side by side; three or four take the quadrants.
    let boxes: [(Double, Double, Double)] = switch tiles.count {
    case 1: [(0, 0, side)]
    case 2: [(0, half / 2, half), (half, half / 2, half)]
    case 3: [(0, half, half), (half, half, half), (half / 2, 0, half)]
    default: [(0, half, half), (half, half, half), (0, 0, half), (half, 0, half)]
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    for (tile, (x, y, box)) in zip(tiles, boxes) {
        let rect = NSRect(x: x + 2, y: y + 2, width: box - 4, height: box - 4)
        let circle = NSBezierPath(ovalIn: rect)
        NSGraphicsContext.saveGraphicsState()
        circle.addClip()
        if case .avatar(let path) = tile, let image = NSImage(contentsOfFile: path) {
            image.draw(in: rect)
        } else {
            let (text, color): (String, String) = switch tile {
            case let .initials(text, color): (text, color)
            case .avatar: ("?", "#8b8d98")
            }
            let rgb = parseColor(color)
            NSColor(calibratedRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1).setFill()
            circle.fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: box * 0.38), .foregroundColor: NSColor.white,
            ]
            let label = text as NSString
            let measured = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: x + (box - measured.width) / 2, y: y + (box - measured.height) / 2),
                       withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: url, options: .atomic)) != nil else {
        return nil
    }
    return url.path
}
