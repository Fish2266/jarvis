import AppKit

// Menu-bar-only app: no Dock icon, no main window.
let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
