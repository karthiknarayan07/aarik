import AppCore
import SwiftUI
import UIKit

/// The first-launch introduction: three short screens in the style of Apple's What's New pages, shown once.
enum IOSOnboarding {
    /// The `AppStorage` key; UI tests launch with `-onboarding.completed <true/>` to skip it.
    static let completedKey = "onboarding.completed"
}

struct IOSOnboardingView: View {
    let requestPhotosAccess: () async -> Void
    let finish: () -> Void
    @State private var step = 0

    private struct Point: Identifiable {
        let symbol: String
        let heading: String
        let text: String
        var id: String { heading }
    }

    private struct Page {
        let title: String
        let systemImage: String
        let tint: Color
        let points: [Point]
        let button: String
    }

    private var pages: [Page] {
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "this iPad" : "this iPhone"
        let app = AppInfo.displayName
        return [
            Page(
                title: "Your Videos Stay on \(device)", systemImage: "lock.shield.fill", tint: .blue,
                points: [
                    Point(
                        symbol: "iphone", heading: "Everything Happens Here",
                        text: "\(app) converts on \(device). Nothing is uploaded."),
                    Point(
                        symbol: "eye.slash.fill", heading: "No Tracking",
                        text: "There are no accounts, analytics or ads. Your videos are never shared."),
                    Point(
                        symbol: "checkmark.seal.fill", heading: "Originals Stay Safe",
                        text: "A smaller copy is made and checked first. You choose what happens to the original."),
                ], button: "Continue"),
            Page(
                title: "Photos Access", systemImage: "photo.on.rectangle.angled.fill", tint: .pink,
                points: [
                    Point(
                        symbol: "list.bullet.rectangle.fill", heading: "Find the Big Ones",
                        text: "\(app) lists your videos and their sizes without downloading them."),
                    Point(
                        symbol: "hand.raised.fill", heading: "You Stay in Control",
                        text: "Nothing in Photos changes until you convert a video. You can share only some videos."),
                ], button: "Allow Access to Photos…"),
            Page(
                title: "Easy on Your Battery", systemImage: "battery.100percent.bolt", tint: .green,
                points: [
                    Point(
                        symbol: "battery.25percent", heading: "Pauses at 20 Percent",
                        text: "Conversion waits when the battery is low and carries on once it charges."),
                    Point(
                        symbol: "thermometer.high", heading: "Cools Down First",
                        text: "When \(device) gets hot, conversion pauses until it cools."),
                    Point(
                        symbol: "bolt.fill", heading: "Runs Best Plugged In",
                        text: "Long videos convert fastest while charging. You can pause any time."),
                ], button: "Get Started"),
        ]
    }

    var body: some View {
        let pages = pages
        let page = pages[step]
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Skip", action: finish)
                    .accessibilityIdentifier("onboarding.skip")
            }
            .padding([.horizontal, .top])

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Image(systemName: page.systemImage)
                        .font(.system(size: 56))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(page.tint)
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                    Text(page.title)
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(page.points) { point in
                            HStack(alignment: .top, spacing: 16) {
                                Image(systemName: point.symbol)
                                    .font(.title)
                                    .foregroundStyle(page.tint)
                                    .frame(width: 40)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(point.heading).font(.headline)
                                    Text(point.text).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                .padding(24)
                .id(step)
                .transition(.opacity)
            }
            .scrollBounceBehavior(.basedOnSize)

            Button {
                advance(count: pages.count)
            } label: {
                Text(page.button).frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .padding()
            .accessibilityIdentifier("onboarding.continue")
        }
        .animation(.smooth, value: step)
        .interactiveDismissDisabled()
        .accessibilityIdentifier("onboarding")
    }

    private func advance(count: Int) {
        if step == count - 1 {
            finish()
            return
        }
        let wasPhotos = step == 1
        step += 1
        if wasPhotos { Task { await requestPhotosAccess() } }
    }
}
