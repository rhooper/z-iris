# z-iris-priority spikes (2026-10-20)

Throwaway tests run before building sticky alerts. Plan:
`docs/superpowers/plans/2026-10-19-sticky-alerts.md`, Task 1.

## 1. Does a child process get its own notification identity?

Yes. z-iris-priority.app (`ca.toybox.z-iris.priority`, ad hoc signed `-i`),
started with `subprocess` as a child of another program, reports its own bundle
id, gets its own permission and its own entry in System Settings, Notifications,
and honours the Persistent (Alerts) style: test alerts stayed until closed.

Catch: macOS refused the first authorisation request without any prompt
("Notifications are not allowed for this application", status not determined)
while the bundle lived in `/private/tmp`, whether started as a child or with
`open`, registered with LaunchServices or not. Copied to `~/Applications`, the
same bundle got the prompt. `NSUserNotificationAlertStyle = alert` in
Info.plist did not make Persistent the starting style; the user set it.

A click on an alert after the app had quit relaunched it and opened the url
(stored on disk by group id).

## 2. Time-sensitive with ad hoc signing

No. Signed ad hoc with `com.apple.developer.usernotifications.time-sensitive`,
the app is killed at launch (exit -9): a restricted entitlement needs a
provisioning profile. Without the entitlement, a notification sent with
`Urgency.Critical` (time-sensitive) is still delivered, as an ordinary alert;
`timeSensitiveSetting` reports not supported. So z-iris-priority always asks
for time-sensitive and nothing breaks without it.

## 3. Time-sensitive with a free Personal Team profile

Not with the free Personal Team: Xcode hides Time Sensitive Notifications and
Communication Notifications for it. With the user's paid team (R9MHS94TL4)
selected, both are offered; Xcode made "Mac Team Provisioning Profile:
ca.toybox.z-iris.priority" (expires 2027-10-20).

Signed with that profile, the app launches only when the signature also
carries the profile's `com.apple.application-identifier` and
`com.apple.developer.team-identifier` (build_app.sh copies them from the
profile). Then macOS reports `timeSensitiveSetting` enabled. Two identities
share the name "Apple Development: Rose  Hooper", so sign by SHA-1.
Signing mode: `profile`.

## Do I need to renew my Apple developer account?

No: sticky alerts work ad hoc, and time-sensitive works with the existing
paid membership, using the paid team rather than the Personal Team.
