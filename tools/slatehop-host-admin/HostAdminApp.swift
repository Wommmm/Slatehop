import Foundation
import SwiftUI

@main
@MainActor
struct HostAdminApp: App {
    private let demo = CommandLine.arguments.contains("--demo")
    private var demoRecovery: HostAdminDemo.RecoverySeed? {
        if CommandLine.arguments.contains("--demo-recovery-unknown-window") { return .unknownWindow }
        if CommandLine.arguments.contains("--demo-recovery") { return .knownWindow }
        return nil
    }

    var body: some Scene {
        WindowGroup("SlateHop 主机管理") {
            if demo || demoRecovery != nil {
                HostAdminView(
                    backend: HostAdminDemo(recovery: demoRecovery),
                    deviceName: "演示 Mac mini",
                    addresses: ["192.0.2.20:21118"],
                    demo: true
                )
            } else {
                HostAdminView(
                    backend: HostAdminAdapter(),
                    deviceName: Host.current().localizedName ?? "此 Mac",
                    addresses: HostAdminAdapter.connectionAddresses(),
                    demo: false
                )
            }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
