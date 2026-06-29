//
//  DuplicityManagerApp.swift
//  DuplicityManager
//
//  Created by Enrico Lévesque on 2026-06-29.
//

import SwiftUI
import SwiftData

@main
struct DuplicityManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}

// MARK: - AppDelegate pour garder l'app active après fermeture de fenêtre
class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: NSWindow?
    private var windowObserver: NSObjectProtocol?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Capture la fenêtre quand elle apparaît et remplace son bouton de fermeture
        // par une action qui la cache au lieu de la détruire
        DispatchQueue.main.async { [weak self] in
            self?.captureMainWindow()
        }
    }

    private func captureMainWindow() {
        guard let window = NSApp.windows.first(where: { $0.title == "DuplicityManager" || $0.contentViewController != nil }) else {
            // Réessaie dans 1 seconde si la fenêtre n'est pas encore prête
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.captureMainWindow()
            }
            return
        }

        mainWindow = window

        // Remplace le comportement du bouton de fermeture (X) :
        // on cache la fenêtre au lieu de la détruire
        let closeButton = window.standardWindowButton(.closeButton)
        closeButton?.target = self
        closeButton?.action = #selector(hideWindow)
    }

    @objc private func hideWindow() {
        mainWindow?.orderOut(nil)
    }

    /// Réaffiche la fenêtre principale
    func reopenMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }
}
