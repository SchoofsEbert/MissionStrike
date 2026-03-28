import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Run as an accessory app (no Dock icon)
app.setActivationPolicy(.accessory)

app.run()

