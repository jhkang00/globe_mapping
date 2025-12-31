import SwiftUI

@main
struct GlobeEditorApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: GlobeDocument()) { file in
            ContentView(document: file.$document)
        }
    }
}
