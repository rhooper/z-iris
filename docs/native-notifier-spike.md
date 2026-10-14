# Native notifier: feasibility spike

Question: can z-iris post native banners from Python without terminal-notifier?

Findings (macOS 26, Homebrew python@3.13 3.13.15, desktop-notifier 6.2.0):

- `desktop-notifier` uses UNUserNotificationCenter, which requires the process to be an
  app bundle. A uv-managed Python reports "can only be used from an app bundle".
- Homebrew's `.venv/bin/python` re-execs `Python.app` (id `org.python.python`), which is a
  bundle but not ours: authorisation there is a different, undetermined identity.
- Copying `Python.app/Contents/MacOS/Python` into `z-iris.app/Contents/MacOS/`, with our own
  `Info.plist` (`ca.toybox.z-iris`, `LSUIElement`), works: `NSBundle.mainBundle()` reports
  `ca.toybox.z-iris`, the binary still finds the framework (it links the Cellar path
  absolutely, so the bundle must be rebuilt after `brew upgrade python@3.13`), and
  `codesign --force --deep -s -` signs it (ad hoc) and verifies.
- A bash launcher as `CFBundleExecutable` that `exec`s the sibling `Python` keeps the bundle
  identity. `PYTHONPATH` (src + venv site-packages) and `PYTHONNOUSERSITE` are set there.
  The venv must be built with the same Homebrew 3.13 so compiled wheels match.
- `DesktopNotifier.has_authorisation()` has a duplicated `future.set_result` and prints an
  InvalidStateError traceback from its callback; z-iris never calls it. Authorisation is
  taken from `request_authorisation()`, which prompts once and then returns the saved answer.
- The user's shell sets CDPATH, which made `$(cd ...)` print twice in the build script;
  scripts use `CDPATH= cd`.
- Not verified without a human: the permission prompt itself, and a banner actually
  appearing with its attachment and click-through. Tests use a fake backend.
