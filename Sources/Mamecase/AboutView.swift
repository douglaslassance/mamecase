import SwiftUI
import AppKit

struct AboutView: View {
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 128, height: 128)

                VStack(spacing: 4) {
                    Text("Mamecase")
                        .font(.system(size: 24, weight: .bold))

                    Text("Version \(currentVersion)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 8) {
                Button(action: {
                    NSWorkspace.shared.open(URL(string: "https://douglaslassance.me/contact")!)
                }) {
                    Label("Contact", systemImage: "envelope")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button(action: {
                    if let url = URL(string: "https://ko-fi.com/douglaslassance") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Label("Donate", systemImage: "cup.and.saucer")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            Spacer()

            HStack(spacing: 4) {
                Text("©")
                    .foregroundColor(.secondary)
                Text("2026")
                    .foregroundColor(.secondary)
                Button(action: {
                    if let url = URL(string: "https://douglaslassance.me") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Text("Douglas Lassance")
                        .underline()
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .onHover { hovering in
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
            }
            .font(.caption)
        }
        .padding(30)
        .frame(width: 320, height: 340)
    }
}
