import SwiftUI
import Foundation
import Combine
import ServiceManagement

// MARK: - Modèle de Configuration
struct AppConfig: Codable {
    var source: String = "/Users/enrico"
    var ftpHost: String = "192.168.0.200"
    var ftpUser: String = "enrico"
    var ftpPass: String = "j0seric0"
    var ftpPath: String = "/disk1/backup/macbook-co-test"
    var fullEvery: String = "4W"
    var keep: String = "1M"
    var logFile: String = "~/Library/Logs/duplicity-backup.log"
    var excludes: [String] = [".Trash", "Library", ".cache", ".ollama/models", "GDrive", "Downloads", "Google Drive", "Applications", "bin"]
    var autoBackupEnabled: Bool = false
    var autoBackupIntervalHours: Int = 24
}

// MARK: - Gestionnaire de Backup
class BackupManager: NSObject, ObservableObject {
    @Published var config: AppConfig = AppConfig()
    @Published var isRunning = false
    @Published var isListing = false
    @Published var backupLog: String = "En attente de lancement..."
    @Published var fileLines: [String] = []
    @Published var lastBackupStatus: String = "Inconnu"
    @Published var lastBackupDate: String = "Jamais"
    @Published var showAlert = false
    @Published var alertMessage = ""
    @Published var nextAutoBackupDate: String = "Désactivé"
    @Published var isRestoring = false
    @Published var restoreLog: String = "En attente de restore..."
    @Published var restoreDestDir: String = "~/Desktop/DuplicityManager-Restore"
    @Published var restoreFile: String = ""
    @Published var fileSearchText: String = ""
    @Published var fileCount: Int = 0
    private var listProcess: Process?
    
    private let configURL: URL
    private var autoBackupTimer: Timer?
    private var statusItem: NSStatusItem?
    private var statusCancellables: Set<AnyCancellable> = []
    
    override init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("DuplicityManager", isDirectory: true)
        try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)
        configURL = appFolder.appendingPathComponent("config.json")

        super.init()

        loadConfig()
        checkStatus()
        setupAutoBackup()
        setupStatusBarItem()
    }
    
    deinit {
        autoBackupTimer?.invalidate()
    }

    // MARK: - Icône de la barre de menu

    private func setupStatusBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        let openItem = NSMenuItem(title: "Ouvrir DuplicityManager",
                                  action: #selector(showWindow),
                                  keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(NSMenuItem.separator())
        let backupItem = NSMenuItem(title: "Lancer un backup",
                                    action: #selector(menuRunBackup),
                                    keyEquivalent: "b")
        backupItem.target = self
        menu.addItem(backupItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quitter",
                                  action: #selector(quitApp),
                                  keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem?.menu = menu

        // Observe les changements d'état pour mettre à jour l'icône
        $isRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusBarIcon() }
            .store(in: &statusCancellables)
        $lastBackupStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusBarIcon() }
            .store(in: &statusCancellables)
        $config
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusBarIcon() }
            .store(in: &statusCancellables)

        // Définit l'icône initiale selon l'état réel
        updateStatusBarIcon()
    }

    private func updateStatusBarIcon() {
        let symbolName: String
        let tooltip: String

        if isRunning {
            symbolName = "arrow.clockwise.circle.fill"
            tooltip = "DuplicityManager — Backup en cours..."
        } else if lastBackupStatus == "Échec" {
            symbolName = "exclamationmark.circle.fill"
            tooltip = "DuplicityManager — Échec du dernier backup"
        } else if config.autoBackupEnabled {
            symbolName = "arrow.clockwise.circle.fill"
            tooltip = "DuplicityManager — Sauvegarde automatique activée"
        } else {
            symbolName = "arrow.clockwise.circle"
            tooltip = "DuplicityManager — En attente"
        }

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: symbolName,
                                   accessibilityDescription: tooltip)
            button.image?.isTemplate = true
            button.toolTip = tooltip
        }
    }

    @objc private func showWindow() {
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
            appDelegate.reopenMainWindow()
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func menuRunBackup() {
        runBackup()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    func loadConfig() {
        if let data = try? Data(contentsOf: configURL) {
            let decoder = JSONDecoder()
            if let loadedConfig = try? decoder.decode(AppConfig.self, from: data) {
                config = loadedConfig
                return
            }
        }
        // Garde les valeurs par défaut si rien n'est trouvé
        config = AppConfig()
    }
    
    func saveConfig() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(config) {
            try? data.write(to: configURL)
        }
        setupAutoBackup()
    }

    // MARK: - Automatisation du backup

    func setupAutoBackup() {
        autoBackupTimer?.invalidate()
        autoBackupTimer = nil

        guard config.autoBackupEnabled else {
            nextAutoBackupDate = "Désactivé"
            return
        }

        // Vérifie toutes les 10 minutes si un backup est dû.
        // Le timer est mis en pause pendant la veille et reprend au réveil,
        // ce qui couvre automatiquement le cas du retour de veille.
        autoBackupTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            DispatchQueue.main.async {
                self.checkAutoBackup()
            }
        }

        // Au démarrage, on attend 5 minutes pour laisser les applications
        // s'ouvrir avant de lancer une tâche de backup.
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
            self.checkAutoBackup()
        }
    }

    private func checkAutoBackup() {
        guard config.autoBackupEnabled, !isRunning else { return }

        let appStamp = configURL.deletingLastPathComponent().appendingPathComponent("last-backup-stamp").path
        let systemStamp = "/var/log/duplicity-last-run"

        var lastBackupTime: TimeInterval = 0
        if let content = try? String(contentsOfFile: appStamp, encoding: .utf8),
           let ts = TimeInterval(content) {
            lastBackupTime = ts
        }
        if let content = try? String(contentsOfFile: systemStamp, encoding: .utf8),
           let ts = TimeInterval(content), ts > lastBackupTime {
            lastBackupTime = ts
        }

        let interval = TimeInterval(config.autoBackupIntervalHours * 3600)
        let elapsed = Date().timeIntervalSince1970 - lastBackupTime

        if elapsed >= interval {
            runBackup()
        }

        // Met à jour l'affichage de la prochaine échéance
        let nextDate = Date(timeIntervalSince1970: lastBackupTime + interval)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        nextAutoBackupDate = formatter.string(from: nextDate)
    }
    
    func checkStatus() {
        let expandedLogPath = (config.logFile as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expandedLogPath) {
            if let content = try? String(contentsOfFile: expandedLogPath, encoding: .utf8) {
                backupLog = content

                // Cherche la dernière occurrence de "réussi" ou "ERREUR"
                // pour déterminer le statut réel du backup le plus récent
                let lines = content.components(separatedBy: "\n")
                var lastStatus: String = "Inconnu"
                for line in lines {
                    if line.contains("=== Backup réussi") {
                        lastStatus = "Réussi"
                    } else if line.contains("=== ERREUR") {
                        lastStatus = "Échec"
                    }
                }

                lastBackupStatus = lastStatus
                if lastStatus == "Échec" {
                    alertMessage = "Un problème est survenu lors du dernier backup. Consultez les logs pour plus de détails."
                    showAlert = true
                }

                // Si le stamp file n'existe pas, on essaie de parser la date
                // depuis la dernière ligne "=== Backup réussi : <date> ===" du log
                updateLastBackupDate(from: content)
            }
        }
    }

    private func updateLastBackupDate(from logContent: String) {
        // 1. Stamp file de l'app (Application Support)
        let appStamp = configURL.deletingLastPathComponent().appendingPathComponent("last-backup-stamp").path
        if let content = try? String(contentsOfFile: appStamp, encoding: .utf8),
           let timestamp = TimeInterval(content) {
            let date = Date(timeIntervalSince1970: timestamp)
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            lastBackupDate = formatter.string(from: date)
            return
        }

        // 2. Stamp file du script launchd (/var/log/)
        let systemStamp = "/var/log/duplicity-last-run"
        if let content = try? String(contentsOfFile: systemStamp, encoding: .utf8),
           let timestamp = TimeInterval(content) {
            let date = Date(timeIntervalSince1970: timestamp)
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            lastBackupDate = formatter.string(from: date)
            return
        }

        // 3. Fallback : parser la date depuis la dernière ligne "=== Backup réussi ===" du log
        let lines = logContent.components(separatedBy: "\n")
        for line in lines.reversed() {
            if line.contains("=== Backup réussi") {
                // Format : "=== Backup réussi : Jun 29, 2026 at 10:51:14 AM ==="
                let prefix = "=== Backup réussi : "
                if let startIdx = line.range(of: prefix) {
                    let dateStr = line[startIdx.upperBound...]
                        .replacingOccurrences(of: " ===", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    let formatter = DateFormatter()
                    formatter.dateStyle = .medium
                    formatter.timeStyle = .medium
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    if let date = formatter.date(from: dateStr) {
                        let displayFormatter = DateFormatter()
                        displayFormatter.dateStyle = .medium
                        displayFormatter.timeStyle = .short
                        lastBackupDate = displayFormatter.string(from: date)
                        return
                    }
                    // Si le parse échoue, on affiche la chaîne brute
                    lastBackupDate = dateStr
                    return
                }
            }
        }
    }
    
    func runBackup() {
        isRunning = true
        backupLog = "Démarrage du backup...\n"

        var args: [String] = ["--no-encryption"]
        args.append("--full-if-older-than")
        args.append(config.fullEvery)

        for ex in config.excludes {
            args.append("--exclude")
            args.append("\(config.source)/\(ex)")
        }

        args.append(config.source)
        args.append("ftp://\(config.ftpUser)@\(config.ftpHost)\(config.ftpPath)")

        runDuplicity(args: args) { output, success in
            self.backupLog += output + "\n"
            self.appendLogToDisk(output)

            if success {
                self.runCleanup()
            } else {
                // Duplicity peut échouer temporairement (ex: reprise d'un backup
                // partiel interrompu). On retente une fois.
                self.backupLog += "--- Première tentative échouée, nouvel essai...\n"
                self.appendLogToDisk("--- Nouvel essai après échec ---")
                self.runDuplicity(args: args) { retryOutput, retrySuccess in
                    self.backupLog += retryOutput + "\n"
                    self.appendLogToDisk(retryOutput)

                    if retrySuccess {
                        self.runCleanup()
                    } else {
                        self.isRunning = false
                        self.lastBackupStatus = "Échec"
                        self.alertMessage = "Le backup a échoué. Consultez les logs."
                        self.showAlert = true
                        self.appendLogToDisk("=== ERREUR : \(self.nowString()) ===")
                    }
                }
            }
        }
    }

    private func runCleanup() {
        self.backupLog += "--- Nettoyage des anciennes sauvegardes...\n"
        let cleanArgs = [
            "remove-older-than", self.config.keep,
            "--no-encryption", "--force",
            "ftp://\(self.config.ftpUser)@\(self.config.ftpHost)\(self.config.ftpPath)"
        ]

        self.runDuplicity(args: cleanArgs) { cleanOutput, cleanSuccess in
            self.backupLog += cleanOutput + "\n"
            self.appendLogToDisk(cleanOutput)
            self.isRunning = false
            self.lastBackupStatus = cleanSuccess ? "Réussi" : "Avertissement"
            if cleanSuccess {
                self.writeStampFile()
                self.appendLogToDisk("=== Backup réussi : \(self.nowString()) ===")
            }
            self.checkStatus()
        }
    }

    private func appendLogToDisk(_ text: String) {
        let expandedLogPath = (config.logFile as NSString).expandingTildeInPath
        let logLine = text + "\n"
        if let handle = FileHandle(forWritingAtPath: expandedLogPath) {
            handle.seekToEndOfFile()
            if let data = logLine.data(using: .utf8) {
                handle.write(data)
            }
            handle.closeFile()
        } else {
            // Crée le fichier s'il n'existe pas
            try? logLine.write(toFile: expandedLogPath, atomically: true, encoding: .utf8)
        }
    }

    private func writeStampFile() {
        let stampFile = configURL.deletingLastPathComponent().appendingPathComponent("last-backup-stamp").path
        let timestamp = String(Int(Date().timeIntervalSince1970))
        try? timestamp.write(toFile: stampFile, atomically: true, encoding: .utf8)
    }

    private func nowString() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: Date())
    }

    // MARK: - Login Item (démarrage au login)

    func isLoginItemEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    func toggleLoginItem(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            alertMessage = "Impossible de configurer le démarrage au login : \(error.localizedDescription)"
            showAlert = true
        }
    }
    
    func refreshFiles() {
        isListing = true
        fileLines = []
        fileCount = 0

        let args = ["list-current-files", "ftp://\(config.ftpUser)@\(config.ftpHost)\(config.ftpPath)"]

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
            env["BACKEND_PASSWORD"] = self.config.ftpPass
            process.environment = env

            process.arguments = ["duplicity"] + args

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            // Lecture ligne par ligne en streaming
            // On accumule dans un buffer local et on pousse par lots
            // pour éviter de rafraîchir l'UI à chaque ligne.
            var buffer = ""
            var batch: [String] = []
            let batchSize = 200

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    // Fin du flux : pousser le reste du buffer
                    if !buffer.isEmpty {
                        batch.append(buffer)
                        buffer = ""
                    }
                    if !batch.isEmpty {
                        let finalBatch = batch
                        DispatchQueue.main.async {
                            self.fileLines.append(contentsOf: finalBatch)
                            self.fileCount = self.fileLines.count
                        }
                    }
                    handle.readabilityHandler = nil
                    return
                }
                if let chunk = String(data: data, encoding: .utf8) {
                    buffer += chunk
                    while let nlRange = buffer.range(of: "\n") {
                        let line = String(buffer[..<nlRange.lowerBound])
                        buffer = String(buffer[nlRange.upperBound...])
                        if !line.isEmpty {
                            batch.append(line)
                            if batch.count >= batchSize {
                                let pushBatch = batch
                                batch = []
                                DispatchQueue.main.async {
                                    self.fileLines.append(contentsOf: pushBatch)
                                    self.fileCount = self.fileLines.count
                                }
                            }
                        }
                    }
                }
            }

            do {
                self.listProcess = process
                try process.run()
                process.waitUntilExit()

                DispatchQueue.main.async {
                    self.isListing = false
                    self.listProcess = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.fileLines = ["Erreur: \(error.localizedDescription)"]
                    self.isListing = false
                    self.listProcess = nil
                }
            }
        }
    }

    func cancelFileList() {
        listProcess?.terminate()
        listProcess = nil
        isListing = false
        fileLines.append("--- Liste interrompue par l'utilisateur ---")
    }

    var filteredFileLines: [String] {
        guard !fileSearchText.isEmpty else { return fileLines }
        return fileLines.filter { $0.localizedCaseInsensitiveContains(fileSearchText) }
    }

    // MARK: - Restore

    /// Vide le répertoire de destination avant un restore pour éviter la corruption
    private func cleanRestoreDest() -> Bool {
        let destPath = (restoreDestDir as NSString).expandingTildeInPath

        // Si un fichier existe à cet emplacement (et non un dossier), on le supprime
        if FileManager.default.fileExists(atPath: destPath) {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: destPath, isDirectory: &isDir)
            if !isDir.boolValue {
                // C'est un fichier, on le supprime
                do {
                    try FileManager.default.removeItem(atPath: destPath)
                    restoreLog += "--- Ancien fichier supprimé à l'emplacement de destination.\n"
                } catch {
                    restoreLog += "--- ERREUR: Impossible de supprimer l'ancien fichier : \(error.localizedDescription)\n"
                    return false
                }
            } else {
                // C'est un dossier, on vide son contenu
                do {
                    let contents = try FileManager.default.contentsOfDirectory(atPath: destPath)
                    for item in contents {
                        let itemPath = (destPath as NSString).appendingPathComponent(item)
                        try FileManager.default.removeItem(atPath: itemPath)
                    }
                    restoreLog += "--- Répertoire de destination nettoyé.\n"
                } catch {
                    restoreLog += "--- ERREUR: Impossible de nettoyer le répertoire : \(error.localizedDescription)\n"
                    return false
                }
            }
        }

        // Crée le répertoire s'il n'existe pas
        try? FileManager.default.createDirectory(atPath: destPath,
                                                  withIntermediateDirectories: true)
        return true
    }

    func runFullRestore() {
        isRestoring = true
        restoreLog = "Démarrage du restore complet...\n"

        guard cleanRestoreDest() else {
            isRestoring = false
            alertMessage = "Impossible de nettoyer le répertoire de destination."
            showAlert = true
            return
        }

        let destPath = (restoreDestDir as NSString).expandingTildeInPath
        restoreLog += "Restauration vers \(destPath)...\n"

        let args = [
            "--no-encryption",
            "restore",
            "ftp://\(config.ftpUser)@\(config.ftpHost)\(config.ftpPath)",
            destPath
        ]

        runDuplicity(args: args) { output, success in
            self.restoreLog += output + "\n"
            if success {
                self.restoreLog += "=== Restore réussi : \(self.nowString()) ===\n"
            } else {
                self.restoreLog += "=== ERREUR de restore : \(self.nowString()) ===\n"
                self.alertMessage = "Le restore a échoué. Consultez les logs."
                self.showAlert = true
            }
            self.isRestoring = false
        }
    }

    func runPartialRestore() {
        let trimmedFile = restoreFile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFile.isEmpty else {
            alertMessage = "Veuillez indiquer un fichier ou dossier à restaurer."
            showAlert = true
            return
        }

        isRestoring = true
        restoreLog = "Démarrage du restore de « \(trimmedFile) »...\n"

        guard cleanRestoreDest() else {
            isRestoring = false
            alertMessage = "Impossible de nettoyer le répertoire de destination."
            showAlert = true
            return
        }

        let destPath = (restoreDestDir as NSString).expandingTildeInPath

        // Duplicity restaure le fichier directement au chemin de destination,
        // ce qui remplace le dossier par le fichier. On utilise donc un
        // sous-dossier temporaire comme cible : duplicity créera le fichier
        // À L'INTÉRIEUR de ce sous-dossier.
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("duplicity-restore-\(Int(Date().timeIntervalSince1970))")
        // tempBase est le dossier parent qu'on garde
        // tempTarget est le sous-dossier que duplicity va utiliser comme destination
        let tempTarget = tempBase.appendingPathComponent("restore-output")
        try? FileManager.default.createDirectory(at: tempTarget,
                                                  withIntermediateDirectories: true)

        restoreLog += "Restauration vers \(destPath) (via \(tempTarget.path))...\n"

        let args = [
            "--no-encryption",
            "--path-to-restore", trimmedFile,
            "restore",
            "ftp://\(config.ftpUser)@\(config.ftpHost)\(config.ftpPath)",
            tempTarget.path
        ]

        runDuplicity(args: args) { output, success in
            self.restoreLog += output + "\n"

            if success {
                // Duplicity a remplacé le sous-dossier "restore-output" par le fichier
                // restauré. On lit donc le contenu depuis le dossier parent (tempBase).
                // On renomme le fichier avec le nom original (basename du chemin demandé).
                let originalName = (trimmedFile as NSString).lastPathComponent
                do {
                    let contents = try FileManager.default.contentsOfDirectory(atPath: tempBase.path)
                    for item in contents {
                        let srcPath = (tempBase.path as NSString).appendingPathComponent(item)
                        let dstPath = (destPath as NSString).appendingPathComponent(originalName)
                        // Supprime l'élément existant à la destination s'il y en a un
                        if FileManager.default.fileExists(atPath: dstPath) {
                            try FileManager.default.removeItem(atPath: dstPath)
                        }
                        try FileManager.default.moveItem(atPath: srcPath, toPath: dstPath)
                    }
                    try? FileManager.default.removeItem(at: tempBase)
                    self.restoreLog += "=== Restore réussi : \(originalName) → \(destPath) (\(self.nowString())) ===\n"
                } catch {
                    self.restoreLog += "=== ERREUR lors du déplacement : \(error.localizedDescription) ===\n"
                    self.alertMessage = "Le restore a réussi mais le déplacement a échoué : \(error.localizedDescription)"
                    self.showAlert = true
                }
            } else {
                self.restoreLog += "=== ERREUR de restore : \(self.nowString()) ===\n"
                self.alertMessage = "Le restore a échoué. Consultez les logs."
                self.showAlert = true
            }
            self.isRestoring = false
        }
    }

    func openRestoreDestInFinder() {
        let destPath = (restoreDestDir as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: destPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: destPath))
        } else {
            // Crée le répertoire s'il n'existe pas
            try? FileManager.default.createDirectory(atPath: destPath,
                                                      withIntermediateDirectories: true)
            NSWorkspace.shared.open(URL(fileURLWithPath: destPath))
        }
    }

    func clearRestoreDest() {
        let destPath = (restoreDestDir as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: destPath) {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: destPath, isDirectory: &isDir)
            do {
                if isDir.boolValue {
                    // Vide le contenu du dossier
                    let contents = try FileManager.default.contentsOfDirectory(atPath: destPath)
                    for item in contents {
                        let itemPath = (destPath as NSString).appendingPathComponent(item)
                        try FileManager.default.removeItem(atPath: itemPath)
                    }
                    restoreLog = "--- Répertoire vidé : \(destPath)\n"
                } else {
                    // Supprime le fichier
                    try FileManager.default.removeItem(atPath: destPath)
                    restoreLog = "--- Fichier supprimé : \(destPath)\n"
                }
            } catch {
                alertMessage = "Impossible de vider : \(error.localizedDescription)"
                showAlert = true
            }
        } else {
            restoreLog = "--- Le répertoire n'existe pas encore.\n"
        }
    }
    
    private func runDuplicity(args: [String], completion: @escaping (String, Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
            env["BACKEND_PASSWORD"] = self.config.ftpPass
            process.environment = env
            
            process.arguments = ["duplicity"] + args
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            
            do {
                try process.run()
                process.waitUntilExit()
                
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                var output = String(data: data, encoding: .utf8) ?? ""
                if output.isEmpty { output = "(Aucune sortie)" }
                
                let success = (process.terminationStatus == 0)
                
                DispatchQueue.main.async {
                    completion(output, success)
                }
            } catch {
                DispatchQueue.main.async {
                    completion("Erreur d'exécution: \(error.localizedDescription)", false)
                }
            }
        }
    }
}

// MARK: - Interface Utilisateur
struct ContentView: View {
    @StateObject private var manager = BackupManager()
    
    var body: some View {
        TabView {
            // MARK: Dashboard
            VStack {
                HStack {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Statut du système")
                            .font(.largeTitle)
                            .bold()
                        
                        HStack {
                            Text("Dernier backup :")
                                .foregroundColor(.secondary)
                            Text(manager.lastBackupDate)
                                .bold()
                        }
                        
                        HStack {
                            Text("Statut :")
                                .foregroundColor(.secondary)
                            Text(manager.lastBackupStatus)
                                .foregroundColor(statusColor(manager.lastBackupStatus))
                                .bold()
                        }

                        if manager.config.autoBackupEnabled {
                            HStack {
                                Text("Prochain backup :")
                                    .foregroundColor(.secondary)
                                Text(manager.nextAutoBackupDate)
                                    .bold()
                            }
                        }
                    }
                    Spacer()
                }
                .padding()
                
                Button(action: {
                    manager.runBackup()
                }) {
                    Label(manager.isRunning ? "Backup en cours..." : "Lancer un Backup", systemImage: "arrow.clockwise.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(manager.isRunning)
                .padding([.horizontal, .bottom])
                
                ScrollView {
                    Text(manager.backupLog)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(8)
                .padding(.horizontal)
            }
            .tabItem {
                Label("Dashboard", systemImage: "speedometer")
            }
            .alert("Problème de Backup", isPresented: $manager.showAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(manager.alertMessage)
            }
            
            // MARK: Fichiers
            VStack {
                HStack {
                    Text("Fichiers sauvegardés")
                        .font(.title2)
                        .bold()
                    Spacer()
                    if manager.isListing {
                        Button(action: {
                            manager.cancelFileList()
                        }) {
                            Label("Annuler", systemImage: "xmark.circle")
                        }
                    } else {
                        Button(action: {
                            manager.refreshFiles()
                        }) {
                            Label("Rafraîchir", systemImage: "arrow.clockwise")
                        }
                    }
                }
                .padding()

                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Rechercher un fichier...",
                              text: $manager.fileSearchText)
                        .textFieldStyle(.roundedBorder)
                    if !manager.fileSearchText.isEmpty {
                        Text("\(manager.filteredFileLines.count) / \(manager.fileCount)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if manager.fileCount > 0 {
                        Text("\(manager.fileCount) fichiers")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal)

                List(manager.filteredFileLines, id: \.self) { line in
                    Text(line)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                .listStyle(.plain)
            }
            .tabItem {
                Label("Fichiers", systemImage: "doc.on.doc")
            }
            
            // MARK: Récupération
            VStack {
                HStack {
                    Text("Récupération")
                        .font(.title2)
                        .bold()
                    Spacer()
                }
                .padding()

                VStack(alignment: .leading, spacing: 15) {
                    // Destination
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Répertoire de destination")
                            .font(.headline)
                        HStack {
                            TextField("~/Desktop/DuplicityManager-Restore",
                                      text: $manager.restoreDestDir)
                                .textFieldStyle(.roundedBorder)
                            Button(action: {
                                manager.openRestoreDestInFinder()
                            }) {
                                Label("Ouvrir", systemImage: "folder")
                            }
                            Button(action: {
                                manager.clearRestoreDest()
                            }) {
                                Label("Vider", systemImage: "trash")
                            }
                        }
                    }

                    // Restore partiel
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Fichier ou dossier à récupérer (optionnel)")
                            .font(.headline)
                        TextField("ex: Documents/monfichier.txt",
                                  text: $manager.restoreFile)
                            .textFieldStyle(.roundedBorder)
                        Text("Indiquez le chemin tel qu'affiché dans l'onglet Fichiers. Laissez vide pour une récupération complète.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // Bouton
                    Button(action: {
                        if manager.restoreFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            manager.runFullRestore()
                        } else {
                            manager.runPartialRestore()
                        }
                    }) {
                        Label(manager.isRestoring ? "Récupération en cours..." : "Lancer la récupération",
                              systemImage: "arrow.down.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(manager.isRestoring)
                }
                .padding(.horizontal)

                ScrollView {
                    Text(manager.restoreLog)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(8)
                .padding(.horizontal)
            }
            .tabItem {
                Label("Récupération", systemImage: "arrow.uturn.down.circle")
            }
            .alert("Problème de Backup", isPresented: $manager.showAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(manager.alertMessage)
            }
            
            // MARK: Configuration
            Form {
                Section("Duplicity & Source") {
                    TextField("Dossier source", text: $manager.config.source)
                    TextField("Effectuer un Full toutes les (ex: 4W)", text: $manager.config.fullEvery)
                    TextField("Conserver l'historique (ex: 1M)", text: $manager.config.keep)
                    TextField("Chemin du fichier de log", text: $manager.config.logFile)
                }
                
                Section("Destination FTP") {
                    TextField("Hôte FTP", text: $manager.config.ftpHost)
                    TextField("Utilisateur FTP", text: $manager.config.ftpUser)
                    SecureField("Mot de passe FTP", text: $manager.config.ftpPass)
                    TextField("Chemin distant", text: $manager.config.ftpPath)
                }
                
                Section("Exclusions (Noms de dossiers relatifs à la source)") {
                    Text("Entrez un dossier par ligne.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextEditor(text: Binding(
                        get: { manager.config.excludes.joined(separator: "\n") },
                        set: { newValue in
                            manager.config.excludes = newValue.components(separatedBy: "\n").filter { !$0.isEmpty }
                        }
                    ))
                    .frame(minHeight: 150)
                    .font(.system(.body, design: .monospaced))
                }
                
                Section {
                    Button("Sauvegarder la configuration") {
                        manager.saveConfig()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                Section("Automatisation") {
                    Toggle("Backup automatique", isOn: $manager.config.autoBackupEnabled)
                        .onChange(of: manager.config.autoBackupEnabled) { _, newValue in
                            if newValue {
                                manager.setupAutoBackup()
                            } else {
                                manager.setupAutoBackup()
                            }
                        }

                    if manager.config.autoBackupEnabled {
                        Stepper("Intervalle : \(manager.config.autoBackupIntervalHours) heures",
                                value: $manager.config.autoBackupIntervalHours,
                                in: 1...168,
                                step: 1)
                            .onChange(of: manager.config.autoBackupIntervalHours) { _, _ in
                                manager.setupAutoBackup()
                            }

                        Text("Prochain backup prévu : \(manager.nextAutoBackupDate)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Toggle("Lancer l'app au démarrage", isOn: Binding(
                        get: { manager.isLoginItemEnabled() },
                        set: { newValue in manager.toggleLoginItem(enabled: newValue) }
                    ))
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Configuration", systemImage: "gearshape.fill")
            }
        }
        .frame(minWidth: 700, minHeight: 500)
    }
    
    private func statusColor(_ status: String) -> Color {
        switch status {
        case "Réussi":
            return .green
        case "Échec":
            return .red
        default:
            return .orange
        }
    }

}

// MARK: - Preview
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
