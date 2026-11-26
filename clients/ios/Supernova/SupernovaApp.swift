import SwiftUI
import MultipeerConnectivity
import CryptoKit
import Security

@main
struct SupernovaApp: App {
    @StateObject private var service = MeshService()

    var body: some Scene {
        WindowGroup {
            TabView {
                RustNetworkView()
                    .tabItem { Label("P2P", systemImage: "point.3.connected.trianglepath.dotted") }
                DirectView()
                    .tabItem { Label("Подключение", systemImage: "link") }
                ContentView(service: service)
                    .tabItem { Label("Рядом · Apple", systemImage: "dot.radiowaves.left.and.right") }
            }
            .preferredColorScheme(.dark)
        }
    }
}
