import SwiftUI

struct AboutView: View {
    private let appVersion: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0.0"
    }()

    private let buildNumber: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "2.0.0"
    }()

    private let repoURL = URL(string: "https://github.com/SchoofsEbert/MissionStrike")!

    var body: some View {
        VStack(spacing: 12) {
            if let nsImage = NSApplication.shared.applicationIconImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
            }

            Text("MissionStrike")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Version \(appVersion) (\(buildNumber))")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Close windows and Spaces directly\nfrom Mission Control with a single click.")
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(.secondary)

            Link(destination: repoURL) {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                    Text("GitHub Repository")
                }
                .font(.caption)
            }

            Text("© 2026 Ebert Schoofs")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(width: 280, height: 300)
    }
}
