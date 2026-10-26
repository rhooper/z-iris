# Swift port, macOS layer spikes (2026-10-26)

Phase 3 of the Swift port (`~/.claude/plans/starry-petting-crescent.md`).
Code: `scripts/claude/spikes/` (`build_helper_identity.sh`, `audio_engine.swift`).

## a. A helper nested in Contents/Helpers

An app at `z-iris-spike.app/Contents/Helpers/z-iris-spike-helper.app`, ad hoc
signed with its own identifier and opened with `NSWorkspace.openApplication`,
gets its **own notification identity**: its own permission prompt, granted
separately from the outer app's, in `~/Applications`.

`NSUserNotificationAlertStyle = alert` did not make it Persistent: it came up
as banner (Temporary), nested or copied out as a sibling alike. That matches
`docs/priority-spike.md`: the user sets Persistent in System Settings, as the
README already says for z-iris priority. Nesting changes nothing there.

A prompt that is closed unanswered (the app quit while it showed) is recorded
as "not allowed": later runs are refused without a prompt. A new bundle id
(`SPIKE_ID=...`) gets a fresh prompt.

Not yet checked: that the nested helper honours Persistent once the user sets
it, and that it keeps time-sensitive when signed with the priority profile
(time-sensitive needs the entitlement, which needs the paid team's profile;
ad hoc with the entitlement is killed at launch). Both before relying on
`Contents/Helpers`; otherwise keep the sibling app.

## b. AVAudioEngine through Audio Hijack

AVAudioEngine playing `chime.wav` on the default output was heard, as `sox
play` is. Pinning `kAudioOutputUnitProperty_CurrentDevice` to a named device
works (status 0); the loopback devices tried (`Zulip`, `828es 7,8 Chat`) were
not routed anywhere at the time, so they were silent, as expected. A short
silent lead-in is kept, as `attention` does, for an output that is asleep.

On the macOS 27 SDK, `AVAudioEngine.connect`, `AVAudioPlayerNode.play` and
`AVAudioIONode.audioUnit` are deprecated (`withAudioUnit` replaces the last);
the app targets macOS 26, so these need `#available` paths.
