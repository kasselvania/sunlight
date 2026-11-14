import AppKit
print("hid", CGEventSource.buttonState(.hidSystemState, button: .left), "combined", CGEventSource.buttonState(.combinedSessionState, button: .left), "pressed", NSEvent.pressedMouseButtons)
