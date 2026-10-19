"""Diagnose a missing menubar icon: create one NSStatusItem with z-iris's
template image and report what AppKit says about it, then quit.
2026-10-19. Usage (runs under the bundle's identity):
  PYTHONPATH=src:.venv/lib/python3.13/site-packages \
    ~/Applications/z-iris.app/Contents/MacOS/Python scripts/claude/statusitem_probe.py
"""
from pathlib import Path

from AppKit import (NSApplication, NSApplicationActivationPolicyAccessory, NSImage,
                    NSStatusBar, NSVariableStatusItemLength)
from Foundation import NSBundle, NSTimer
from PyObjCTools import AppHelper

app = NSApplication.sharedApplication()
app.setActivationPolicy_(NSApplicationActivationPolicyAccessory)
print("bundle id:", NSBundle.mainBundle().bundleIdentifier())
icon = Path(__file__).resolve().parents[2] / "src/z_iris/static/z-iris-menubarTemplate.png"
image = NSImage.alloc().initWithContentsOfFile_(str(icon))
print("image:", image and image.size())
item = NSStatusBar.systemStatusBar().statusItemWithLength_(NSVariableStatusItemLength)
image.setTemplate_(True)
item.button().setImage_(image)


def report(_timer=None):
    window = item.button().window()
    print("visible:", item.isVisible(), "length:", item.length(),
          "autosave:", item.autosaveName(), "behavior:", item.behavior())
    print("window:", window and window.frame(), "onscreen:", window and window.isVisible(),
          "occlusion:", window and window.occlusionState())
    AppHelper.stopEventLoop()


NSTimer.scheduledTimerWithTimeInterval_repeats_block_(2.0, False, report)
AppHelper.runEventLoop()
