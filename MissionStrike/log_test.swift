import Foundation
func redirectLogs() {
    let logPath = "/tmp/missionstrike.log"
    freopen(logPath, "a", stdout)
    freopen(logPath, "a", stderr)
    print("\n--- APP STARTED ---")
}
