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

Not available. In Xcode, with the free Personal Team selected, neither Time
Sensitive Notifications nor Communication Notifications appears in the
capabilities list; Xcode hides capabilities a free team cannot use. Signing
mode: `adhoc`. The profile path in `build_app.sh` stays for a paid account.

## Do I need to renew my Apple developer account?

Not for sticky alerts: they work ad hoc. Time-sensitive alerts and sender
faces as the notification icon (communication notifications) would need the
paid Apple Developer Program. Meanwhile, turning off Summarize notifications
for z-iris priority keeps its alerts out of summaries.
