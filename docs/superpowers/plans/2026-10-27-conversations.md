# Joined Conversations, Reactions and Sub-rules Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Topics you post in (or are @-mentioned in) become "joined" and get sticky, grouped alerts that collapse into a summary; reactions to your messages notify, configurable by rules and `[rule.reaction]` sub-rules.

**Architecture:** A `Conversations` store in ZIrisCore (joined topics with expiry, your own messages) is fed by the event stream and read by the `Pipeline`, which layers the conversation behaviour onto the matched rule's action and turns reaction events into notifications. The `Engine` groups a conversation's unread alerts and, past `group_after`, asks the output for one summary alert updated in place. Config, editing and the editor gain the new keys, kinds and the sub-table.

**Tech Stack:** Swift 6.2 package `swift/` (ZIrisCore, ZulipKit, ZIrisMac), Swift Testing, TOMLDecoder, UserNotifications.

**Spec:** `docs/superpowers/specs/2026-10-27-conversations-design.md`

## Global Constraints

- Every existing fixture in `swift/Tests/ZIrisCoreTests/Fixtures` must still pass unchanged (`cd swift && swift test`).
- New `RuleKind` cases go after `.dm` so existing kinds keep their rank.
- Defaults: `joined_hours = 48` (1–720), `group_after = 3` (1–20), `join_on_mention = true`, `reactions = true`; reaction grouping window 60 s; own-message fetch 200.
- `join` and `emoji` are per-rule keys and never inherit from `[defaults]`.
- Conversation-layer built-ins (banner shown, `sticky = true`) and reaction built-ins (`sound = "none"`) sit above `[defaults]`; only a `conversation` / `reaction` rule (or sub-rule) overrides them.
- `[rule.reaction]` is allowed only under `channel`, `topic` and `conversation` rules; elsewhere: `"<label>: reaction settings only apply to channel, topic and conversation rules"`.
- Joined topics count as personal for focus; reactions do not. Muted topics stay silent even when joined.
- Every feature commit carries the trailer `Semver: minor`.

## Review Focus

1. A topic renamed or moved while joined: the joined entry follows (`update_message` with `subject`/`stream_id` for a message id in the joined set) — test in Task 6.
2. Reading a joined topic in another client clears both its single alerts and its summary alert and resets the count — test in Task 7.
3. A reaction by you, a reaction removed, or a reaction on someone else's message never notifies — test in Task 5.
4. Restart: joined topics and their last activity survive (file round trip; a corrupt file starts empty) — test in Task 1.
5. A rule that silences a channel (`sound = "none"`, `banner = "off"`) still lets a joined topic in that channel alert, with no sound — test in Task 4.

---

### Task 1: Conversations store

**Files:**
- Create: `swift/Sources/ZIrisCore/Conversations.swift`
- Test: `swift/Tests/ZIrisCoreTests/ConversationsTests.swift`

**Interfaces:**
- Produces:
  - `public struct TopicKey: Hashable, Codable, Sendable { server: String; channelID: Int; topic: String }` (topic stored `pythonLowercased`; `init(server:channelID:topic:)` lowercases).
  - `public struct OwnMessage: Sendable, Equatable { id: Int; kind: Message.Kind; place: TopicKey?; snippet: String }`.
  - `public final class Conversations: @unchecked Sendable` with
    `init(file: URL?, hours: @escaping @Sendable () -> Int, now: @escaping @Sendable () -> Date = Date.init)`,
    `func join(_ key: TopicKey)`, `func touch(_ key: TopicKey)` (activity only if joined),
    `func isJoined(_ key: TopicKey) -> Bool` (false and forgotten once `now - lastActivity >= hours`),
    `func move(messageID: Int, to key: TopicKey)` (moves a joined entry whose own message moved),
    `func recordOwn(_ message: OwnMessage)` (keeps the newest 500), `func own(_ id: Int) -> OwnMessage?`,
    `public static let defaultFile: URL` = `~/Library/Application Support/z-iris/joined.json`.
  - Persistence: JSON array of `{server, channel_id, topic, last_activity}` written atomically on change; unreadable file → empty.

- [ ] **Step 1: Write the failing tests** `joiningAndExpiry` (join → joined; touch extends; after 48 h of quiet `isJoined` false), `caseInsensitiveTopics` (`"Onboarding Kristy"` == `"onboarding kristy"`), `ownMessagesAndMoves` (recordOwn then `move(messageID:to:)` moves the joined key), `survivesRestartAndCorruption` (second instance on the same file sees the join; `"{"` in the file → empty, no throw).
- [ ] **Step 2: Run `cd swift && swift test --filter ConversationsTests`** — expect compile failure.
- [ ] **Step 3: Implement** (a lock-guarded dictionary `[TopicKey: Date]` plus own-message ring and map `messageID -> TopicKey` for moves).
- [ ] **Step 4: Run the tests** — PASS.
- [ ] **Step 5: Commit** `swift: A store of joined conversations and your own messages.` with `Semver: minor`.

### Task 2: Config keys, rule kinds and the reaction sub-rule

**Files:**
- Modify: `swift/Sources/ZIrisCore/Rules.swift` (RuleKind, Rule fields), `swift/Sources/ZIrisCore/Config.swift` (keys, parsing, validation)
- Test: `swift/Tests/ZIrisCoreTests/ConversationConfigTests.swift`

**Interfaces:**
- Produces:
  - `RuleKind` gains `.conversation` (`"conversation"`, label `"Conversation you're in"`) and `.reaction` (`"reaction"`, label `"Reaction to your message"`), appended after `.dm`.
  - `Rule` gains `join: Bool` (default false), `emoji: [String]` (default []), `reaction: Rule?` boxed as `indirect`-safe `ReactionSubRule` (a `final class ReactionSubRule: Sendable { let rule: Rule }`) exposed as `public var reactionRule: Rule?`.
  - `Config` gains `joinOnMention: Bool = true`, `joinedHours: Int = 48`, `reactions: Bool = true`.
  - Behaviour setting `"group_after"`: `integer(1, 20)`, built-in 3; `Action.groupAfter: Int = 3`.
  - Validation messages: `"<label>: join must be true or false"`, `"<label>: emoji must be an emoji name or a list of them"`, `"<label>: emoji only applies to reaction rules"`, the sub-rule message from Global Constraints, `"joined_hours must be an integer from 1 to 720"`, `"join_on_mention must be true or false"`, `"reactions must be true or false"`. A `[rule.reaction]` table is validated like a rule's settings (sound, volume, banner, behaviour keys); `match`/`channel`/`topic`/`keyword` inside it are errors: `"<label>: reaction settings cannot set match, channel, topic or keyword"`.

- [ ] **Step 1: Write the failing tests** `newKindsAndKeysParse` (a config with a conversation rule, a reaction rule with `emoji = ["tada"]`, a channel rule with `[rule.reaction] sound = "soft"`, `[defaults] joined_hours = 24`, `group_after = 5` → the fields above), `refusals` (each message above, exact text), `existingFixturesUnchanged` (no code: the whole `swift test` stays green).
- [ ] **Step 2: Run the new tests** — FAIL.
- [ ] **Step 3: Implement** in `rules(...)`/`parseConfig` following the existing check order; the sub-table is `raw["reaction"] as? [String: Any]`.
- [ ] **Step 4: Run `cd swift && swift test`** — all PASS, including every fixture.
- [ ] **Step 5: Commit** `swift: Config for joined conversations, reactions and reaction sub-rules.` with `Semver: minor`.

### Task 3: Matching — the conversation layer and reaction rules

**Files:**
- Modify: `swift/Sources/ZIrisCore/Rules.swift`, `swift/Sources/ZIrisCore/Config.swift` (resolveAction)
- Test: `swift/Tests/ZIrisCoreTests/ConversationMatchingTests.swift`

**Interfaces:**
- Consumes: Task 2's kinds and fields.
- Produces:
  - `pickRule` ignores `.conversation` and `.reaction` rules (they never compete for messages).
  - `public func conversationRule(_ rules: [Rule], _ message: Message) -> Rule?`: the first enabled `.conversation` rule (by the usual sort) whose `server`/`channel` patterns/`pattern` (topic) accept the message.
  - `public struct ReactionPlace: Sendable { server: String; channelName: String?; topic: String?; isDM: Bool }`.
  - `public func pickReactionRule(_ rules: [Rule], place: ReactionPlace, emoji: String) -> Rule?`: candidates are enabled `.reaction` rules and the `reactionRule` of enabled `.channel`/`.topic`/`.conversation` rules (with the parent's priority, server and place conditions; DMs match only rules without place conditions); `emoji` lists filter; usual ordering.
  - `public func resolveAction(_ config: Config, server: String, rule: Rule?, layer: Rule?, layerBuiltIns: Behaviour, layerSound: String? = nil) -> Action`: as today, then `layerBuiltIns` (overriding `[defaults]` and the rule for those keys), then `layerSound` replaces the sound, then the layer rule's own settings (its `sound`, `volume`, `banner` and behaviour) win; for a sub-rule `rule` is the parent and `layer` the sub-rule. Existing `resolveAction(_:server:rule:)` stays and calls this with no layer.
  - `public let conversationBuiltIns: Behaviour = ["sticky": .flag(true)]`; reactions call it with `layerBuiltIns: [:]` and `layerSound: "none"`.

- [ ] **Step 1: Write the failing tests** `conversationRulesNeverCompete`, `conversationRuleFiltersByPlace`, `reactionRuleAndSubRule` (a `#python` channel rule's sub-rule wins for a reaction in #python, a plain reaction rule elsewhere, emoji filter), `layering` (rule `sound = "ping"` + conversation layer → ping, sticky; `[defaults] sticky = false` stays sticky; conversation rule `sticky = false` → not sticky; reaction with `[defaults] sound = "bell"` → sound none; reaction rule `sound = "soft"` → soft; sub-rule inherits parent volume).
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run all tests** — PASS.
- [ ] **Step 5: Commit** `swift: Conversation layer and reaction rule matching.` with `Semver: minor`.

### Task 4: Pipeline — joining and joined-topic notifications

**Files:**
- Modify: `swift/Sources/ZIrisCore/Pipeline.swift`, `swift/Sources/ZIrisCore/Engine.swift` (`personal`)
- Test: `swift/Tests/ZIrisCoreTests/ConversationPipelineTests.swift`

**Interfaces:**
- Consumes: `Conversations` (Task 1), `conversationRule`/`resolveAction(layer:)` (Task 3).
- Produces:
  - `Pipeline.init(server:host:selfID:mutes:config:conversations:)` (`conversations: Conversations?`, nil keeps today's behaviour).
  - `Notification` gains `conversation: TopicKey?` (set for joined-topic notifications).
  - Behaviour in `handle`: your own channel message → `recordOwn` + `join` + `touch`, returns nil; a personal mention in a channel → join when `config.joinOnMention` or its rule's `join`; any message matched by a rule with `join = true` → join; every message in a joined topic → `touch`.
  - `evaluate` for a joined, unmuted topic message not from you: base verdict as today (a silenced rule or "channel messages not enabled" no longer drops it); action = `resolveAction(config, server, rule: matched, layer: conversationRule(...), layerBuiltIns: conversationBuiltIns)` with `banner` forced to `"full"` when it resolved to `"off"`; `reason = "conversation"`; `conversation` set.
  - `Engine.personal` returns true for `notification.conversation != nil`.

- [ ] **Step 1: Write the failing tests** `postingJoinsAndRepliesAlert` (own message then a reply in that topic → notification, reason "conversation", sticky, conversation set; before posting → nil with `notify_channel_messages = false`), `mentionJoinsWhenConfigured` (`join_on_mention = false` → no join), `ruleJoin`, `silencedChannelStillAlertsWithoutSound` (Review Focus 5), `mutedTopicStaysSilent`, `focusLetsConversationsThrough` (engine with `mode = "mentions_and_dms"` delivers a conversation notification), `noConversationsMeansToday` (pipeline with `conversations: nil` → existing pipeline fixture still passes).
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run all tests** — PASS.
- [ ] **Step 5: Commit** `swift: Joined topics alert, layered on their rule.` with `Semver: minor`.

### Task 5: Reactions

**Files:**
- Create: `swift/Sources/ZIrisCore/Reactions.swift`
- Modify: `swift/Sources/ZIrisCore/Pipeline.swift`
- Test: `swift/Tests/ZIrisCoreTests/ReactionTests.swift`

**Interfaces:**
- Consumes: `Conversations.own`, `pickReactionRule`, `resolveAction(layer:)`.
- Produces:
  - `public struct ReactionEvent: Sendable { messageID: Int; userID: Int; userName: String; emojiName: String; emoji: String; added: Bool }` with `init?(_ event: [String: Any])` (type `reaction`; `emoji` from `emoji_code` hex code points joined by `-` for `unicode_emoji`, else `":\(emoji_name):"`; `userName` from `user.full_name`, else "Someone").
  - `Pipeline.handleReaction(_ event: ReactionEvent, now: Date) -> Notification?`: nil when `!config.reactions`, `!added`, `userID == selfID`, or the message is not yours; otherwise a notification whose `message` is your message (content = its snippet), title via `summary` = `"Ada reacted 👍 to your message in #python > onboarding kristy"` (DM: `"in a direct message"`), group per message `"z-iris-reaction-<server>-<id>"`, action from the reaction rule layer. Reactions to the same message within 60 s accumulate: `"Ada and 2 others reacted 👍🎉 …"` (names in order, emojis deduplicated), same group so the alert updates in place.
  - `Notification` gains `group: String?` (overrides `bannerGroup` when set); `notificationTitle` already prefers `summary`.

- [ ] **Step 1: Write the failing tests** `parsesReactionEvents` (unicode `1f44d` → 👍, `1f468-200d-1f4bb` → 👨‍💻, realm emoji → `:party_parrot:`), `notifiesOnlyForOthersAddingToYours` (Review Focus 3: by you, removed, someone else's message → nil), `titleAndGrouping` (two reactors within 60 s → second title "Ada and Bob reacted 👍🎉 to your message in #python > onboarding kristy", same group; after 61 s a fresh one), `silentByDefaultRuleRings`, `reactionsOff`.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run all tests** — PASS.
- [ ] **Step 5: Commit** `swift: Notify reactions to your messages.` with `Semver: minor`.

### Task 6: Event stream wiring

**Files:**
- Modify: `swift/Sources/ZulipKit/EventStream.swift`, `swift/Sources/ZIrisApp/main.swift`
- Test: `swift/Tests/ZulipKitTests/EventStreamTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 4, 5.
- Produces:
  - `eventTypes` gains `"reaction"` and `"update_message"`.
  - `EventStream.init(..., conversations: Conversations?)`; after each register, fetch `messages(["anchor": "newest", "num_before": 200, "num_after": 0, "apply_markdown": false, "narrow": [["operator": "sender", "operand": "me"]]])` and `recordOwn` each (channel ones also `join` with their message time as activity if within `joinedHours`).
  - Reaction events → `pipeline.handleReaction(ReactionEvent, now:)` → `sink.submit`. `update_message` with `stream_id`/`subject` for a message id you own → `conversations.move`.
  - main.swift creates one `Conversations(file: Conversations.defaultFile, hours: { settings.config.joinedHours })` shared by all streams.

- [ ] **Step 1: Write the failing tests** `ownMessagesAreFetchedAndJoined` (FakeAPI returns two own messages; a later reply in one topic is submitted), `reactionEventsReachTheSink`, `movesFollowTheTopic` (Review Focus 1).
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement** (FakeAPI's `messages` gains a scripted reply). **Step 4: Run all tests** — PASS.
- [ ] **Step 5: Commit** `swift: Stream reactions, moves and your own messages.` with `Semver: minor`.

### Task 7: Grouped alerts and the conversation summary

**Files:**
- Modify: `swift/Sources/ZIrisCore/Engine.swift`, `swift/Sources/ZIrisMac/Output.swift`, `swift/Sources/ZIrisMac/PriorityLink.swift`, `swift/Sources/ZIrisMac/PriorityService.swift`, `swift/Sources/ZIrisMac/BannerNotifier.swift`
- Test: `swift/Tests/ZIrisCoreTests/ConversationGroupingTests.swift`, `swift/Tests/ZIrisMacTests/OutputTests.swift`

**Interfaces:**
- Consumes: `Notification.conversation`, `Action.groupAfter`, `Summarizer`.
- Produces:
  - `EngineOutput` gains `func conversationSummary(_ key: TopicKey, _ unread: [Notification])` and `func clearConversation(_ key: TopicKey)` (default no-op implementations in an extension for test outputs).
  - Engine keeps `unread: [TopicKey: [Notification]]`: a conversation notification is added; while `count <= groupAfter` it is delivered as today; from `groupAfter + 1` sound/flash follow today's rules but the banner goes to `conversationSummary(key, unread)`. Read/delete events remove ids; an emptied conversation calls `clearConversation`. `reconcileUnread` and `stop` do the same.
  - Output: every banner for a conversation carries `thread: "<server>:channel:<id>:<topic>"`; `conversationSummary` clears the single alerts' groups and shows one alert with group `"z-iris-conversation-<server>-<channelID>-<sha1(topic) prefix 12>"`, title `"N new in #<channel> > <topic>"`, body the latest message's text, then (when `summarize` and a summarizer) the model's sentence in place; `clearConversation` clears that group. `Notifying.show` gains `thread: String?` (BannerNotifier sets `threadIdentifier`; PriorityLink sends `"thread"`; PriorityService sets it).

- [ ] **Step 1: Write the failing tests** `firstThreeSeparateThenSummary` (group_after 3: messages 1–3 → three `banner`/`deliver` calls, 4 → `conversationSummary` with 4 notifications, 5 → with 5), `readingClearsAndResets` (Review Focus 2: a read of all ids → `clearConversation`; the next message is single again), Output `summaryReplacesSingles` (fake notifier sees clears for z-iris-w-1..3 and one show with the conversation group).
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run all tests** — PASS.
- [ ] **Step 5: Commit** `swift: Group a conversation's alerts into one summary.` with `Semver: minor`.

### Task 8: Editing and the editor

**Files:**
- Modify: `swift/Sources/ZIrisCore/TOMLSpans.swift`, `swift/Sources/ZIrisCore/Editing.swift`, `swift/Sources/ZIrisMac/EditorView.swift`
- Test: `swift/Tests/ZIrisCoreTests/ConversationEditingTests.swift`

**Interfaces:**
- Consumes: Task 2's keys.
- Produces:
  - `TOMLValue` gains `.table([(String, TOMLValue)])` (ordered); `ruleFields` gains `"join"`, `"emoji"`, `"group_after"`, `"reaction"`; `defaultFields` gains `"join_on_mention"`, `"joined_hours"`, `"reactions"`, `"group_after"`.
  - `readEditable` puts a rule's `[rule.reaction]` in its `"reaction"` field; `applyEdit` writes it as a `[rule.reaction]` section right after its rule (keys in `ruleFields` order). Configs without these keys keep producing today's bytes.
  - Editor: kinds list gains Conversation and Reaction; rule form gains "Join this rule's topics" (Toggle → `join`), Emoji field (reaction rules), and a "Reactions to your messages here" section (channel/topic/conversation rules) with Add/Remove and sound, volume, banner; Volume and focus pane gains "Join topics where you're mentioned", "Stay joined for (hours)", "Notify reactions to your messages"; behaviour sections gain "Group after (alerts)".

- [ ] **Step 1: Write the failing tests** `subRuleRoundTrips` (a config with `[rule.reaction]` read then applied unchanged → identical bytes; adding `reaction: [("sound", "soft")]` to a rule writes `[rule.reaction]\nsound = "soft"\n` after it), `newDefaultsWrite`, `editingFixturesUnchanged` (the whole suite).
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run all tests** — PASS; `swift build` for the editor.
- [ ] **Step 5: Commit** `swift: Edit joined-conversation, reaction and sub-rule settings.` with `Semver: minor`.

### Task 9: Documentation and install

**Files:**
- Modify: `README.md`, `config.example.toml`

- [ ] **Step 1:** README: a "Conversations you're in" section (joining, expiry, layering, grouping, focus) and a "Reactions" section (built-ins, rules, `[rule.reaction]`, emoji filter); example config: a commented conversation rule, reaction rule and sub-rule.
- [ ] **Step 2:** `cd swift && swift test` — PASS; `swift run z-iris --config ../config.example.toml --dry-run` prints no config error.
- [ ] **Step 3: Commit** `docs: Joined conversations and reactions.`
