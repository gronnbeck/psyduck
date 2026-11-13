import AppKit
import SwiftUI
import XCTest
@testable import Psyduck

/// Renders the window to PNGs, for looking at the UI without Screen Recording.
///   TEST_RUNNER_PSYDUCK_RENDER_DIR=/tmp/screens TEST_RUNNER_PSYDUCK_RENDER_STATE=<state.json> \
///     xcodebuild test … -only-testing:PsyduckTests/ScreenRenderTests
final class ScreenRenderTests: XCTestCase {
    @MainActor
    func testRenderScreens() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["PSYDUCK_RENDER_DIR"], let statePath = env["PSYDUCK_RENDER_STATE"] else {
            throw XCTSkip("set TEST_RUNNER_PSYDUCK_RENDER_DIR and TEST_RUNNER_PSYDUCK_RENDER_STATE")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let settings = AppSettings(defaults: UserDefaults(suiteName: "psyduck-render-\(UUID())")!)
        settings.gitPath = "/usr/bin/git"
        let store = AppStore(settings: settings, stateURL: URL(fileURLWithPath: statePath))
        let updater = UpdaterModel()
        let workspace = try XCTUnwrap(store.selectedWorkspace)
        await store.refreshChanges(workspace.id)

        func render(_ name: String, _ view: some View, width: CGFloat = 1280, height: CGFloat = 800) async throws {
            let root = view.environmentObject(settings).environmentObject(store).environmentObject(updater)
                .frame(width: width, height: height)
            let hosting = NSHostingView(rootView: root)
            hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(900))
            hosting.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }

        try await render("1-chat", ShellView())
        let file = try XCTUnwrap(store.changes[workspace.id]?.first { $0.path.hasSuffix("Theme.swift") })
        store.openDiff[workspace.id] = file
        try await render("2-diff", ShellView())
        store.openDiff[workspace.id] = nil
        try await render("3-settings", SettingsView(), width: 560, height: 560)
    }
}
