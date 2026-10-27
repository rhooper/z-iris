# Conversations you are in, and reactions to you: design

Date: 2026-10-27. Status: agreed in chat; calls marked "(my call)" are the
builder's and open to change.

## Why

A topic you have joined, such as `#python > onboarding kristy`, matters more
to you than the rest of its channel until it is over, but today z-iris
treats its replies like any other channel message (often: not at all). You
also never hear that someone reacted to something you wrote.

## Goals

1. **Joined conversations.** Posting in a channel topic joins it. A personal
   @-mention of you can join it too, rule-configurable. A joined topic stays
   joined until it has been quiet for quite a while, then drops back to
   normal.
2. **Prioritized, grouped alerts** for new messages in joined topics: they
   stack per conversation, and once several pile up they collapse into one
   summary alert for that conversation, kept up to date. Reading the topic
   anywhere clears them (as sticky alerts do today).
3. **Reactions to your messages** notify, with their own sound and settings
   through rules.
4. **Sub-rules**: a rule can carry a reaction sub-rule, applying to reactions
   on your messages that the parent rule covers (for example only in
   `#python`), inheriting what it does not set.

## Non-goals

- DMs: they already notify; group DMs are not "joined" separately.
- Joining by reading, or by reacting yourself (only posting, and mentions).
- General sub-rules for anything but reactions (my call: the user asked for
  reaction sub-rules; the config shape below leaves room for more later).
- Syncing joined state between Macs.

## Anti-goals

- A joined topic should never be louder than a direct message (a guide for
  the built-ins, not a clamp in code, my call), and must never keep
  alerting after the user has read it.
- Reactions must not become noise: a burst of reactions is one alert, and
  your own reactions never notify.
- No behaviour change for configs that do not use the new settings, apart
  from joined topics (on by default) and reactions (on, quiet, by default);
  both can be turned off.

## How it behaves

### Joining and leaving

- A message you send to a channel topic joins `(server, channel id, topic)`.
  Topic names compare as Zulip compares them (case-insensitive), and a topic
  that is renamed or moved follows its messages (my call: on an
  `update_message` event that moves your own message, the joined entry moves
  with it).
- A personal @-mention joins its topic when `[defaults] join_on_mention` is
  true (the default) or the matching rule says `join = true`. `join = true`
  on any rule makes the topics of the messages it matches joined; `join` is
  only ever set per rule and does not inherit from `[defaults]` (my call:
  otherwise every rule would join every topic it matches).
- A joined topic leaves after `[defaults] joined_hours` (default 48, my
  call for "quite a while") without any message in it.
- Joined topics survive restarts: kept in
  `~/Library/Application Support/z-iris/joined.json` (server, channel id,
  topic, last activity).
- On start (and each re-register) z-iris fetches your own recent channel
  messages (the last 200, my call) to rebuild joined topics and to know which
  messages are yours for reactions.

### What a joined-topic message gets (user's decision: rule settings plus conversation)

- Rules match as today. A message in a joined topic keeps whatever its
  matching rule gives it (sound, volume, flash, repeat...), or `[defaults]`
  when no rule matches, and the conversation behaviour is layered on top:
  the banner is shown even if that rule turns it off or silences the
  channel, the alert is sticky (stays until read, through z-iris priority)
  and it groups as below. So joined topics notify out of the box, even with
  `notify_channel_messages = false` or a rule that silences the channel.
- New rule kind `match = "conversation"` lets the user set the conversation
  layer itself: its settings apply on top of the matched rule's for joined
  topics (for example `sticky = false`, or its own `sound`). It never
  competes with other rules for a message; it is the layer. With
  `channel`/`topic`/`server` it applies only to joined topics there.
- The conversation layer's built-ins (shown, sticky) sit above `[defaults]`
  (my call): `[defaults] sticky = false` does not unstick joined topics;
  only a conversation rule does.
- A personal mention or a DM is unaffected (they already notify).
- Muted topics stay silent even when joined (a mute is a stronger wish).
- Focus (user's decision): joined topics count as personal, so they come
  through "only DMs and mentions" focus and quiet hours; reactions do not.

### Grouped alerts and the summary

- Every alert for a joined topic carries the conversation as its thread, so
  macOS stacks them in Notification Center.
- The first 3 messages (since the topic was last read) show as separate
  alerts. From the 4th, those are removed and replaced by one alert for the
  conversation, which is updated in place as more arrive (my call for the
  threshold; `group_after = 3` in a rule or `[defaults]`).
- The summary alert's text is the on-device model's sentence about the
  unread messages (Phase 6) when `summarize = true` and the model is
  available; otherwise "N new in #python > onboarding kristy" with the
  latest sender and text.
- Sound plays for the first alert and then follows `min_gap` and `repeat`
  as today, so a busy joined topic does not ring for every message.
- Reading the topic (any message in it, or the whole topic) clears its
  alerts and resets the count.

### Reactions

- A `reaction` event adding an emoji to one of your messages, by someone
  else, notifies. Removing a reaction never does.
- Reactions to your direct messages notify too (my call); place filters
  then do not match them.
- New rule kind `match = "reaction"`, optionally with `channel`, `topic` and
  `server` like other rules (the message reacted to supplies them), and
  `emoji = ["tada", "+1"]` to limit it (my call). Reaction rules only match
  reactions, and reactions only match reaction rules.
- Built-in behaviour without a reaction rule: a banner, no sound, "Ada
  reacted 👍 to your message in #python > onboarding kristy" with the start
  of your message as the body (my call). These built-ins sit above
  `[defaults]`: a `[defaults] sound` does not make reactions ring; a
  reaction rule's `sound` does.
- Reactions to the same message within 60 s are one alert, updated in place
  ("Ada and 2 others reacted 👍🎉") (my call).
- `[defaults] reactions = false` turns reaction notifications off.

### Sub-rules

- A rule may contain one reaction sub-rule as a TOML sub-table:

      [[rule]]
      match = "channel"
      channel = "python"
      sound = "ping"

      [rule.reaction]
      sound = "soft"
      volume = 40

  It applies to reactions on your messages that the parent rule's place
  conditions cover (its `channel`, `topic`, `server`). It inherits every
  setting it does not set from the parent rule, then from the reaction
  built-ins and `[defaults]`. It is allowed only under `channel`, `topic`
  and `conversation` rules; elsewhere it is a config error (my call).
- Precedence between reaction rules: a sub-rule counts as a `reaction` rule
  with its parent's priority; among reaction rules the usual order applies.
- The editor shows a rule's reaction sub-rule as a section of that rule with
  an "Add reaction settings" button.

## Constraints

- Swift only (the Python version is retired); existing behaviour stays as
  the frozen fixtures describe it, so new kinds and keys must not change any
  fixture's result.
- The config editor must keep writing comments and layout as now; the new
  keys and the `[rule.reaction]` sub-table go through `TOMLSpans`.
- New config keys must be validated with clear messages, like the others.
- Zulip API: own messages via `GET /messages` with
  `narrow=[{"operator":"sender","operand":"me"}]`; reaction events
  (`type: reaction`, `op: add/remove`, `message_id`, `user_id`, `emoji_name`,
  `emoji_code`); `update_message` for moves. `EVENT_TYPES` gains `reaction`
  and `update_message`.

## Left to the builder

- Where joined-state and own-message tracking live (likely a `Conversations`
  store in ZIrisCore, fed by the stream, read by the pipeline).
- How group collapsing maps onto the existing banner and priority paths.
- Emoji rendering for reaction text (Zulip emoji codes to characters).
- Tests: unit tests for joining, expiry, ranking, grouping, reaction
  matching and sub-rule inheritance; editing tests for the new keys and
  sub-table.
