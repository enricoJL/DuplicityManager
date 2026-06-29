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
class BackupManager: ObservableObject {
    @Published var config: AppConfig = AppConfig()
    @Published var isRunning = false
    @Published var isListing = false
    @Published var backupLog: String = "En attente de lancement..."
    @Published var fileList: String = "Cliquez sur 'Rafraîchir' pour charger la liste."
    @Published var lastBackupStatus: String = "Inconnu"
    @Published var lastBackupDate: String = "Jamais"
    @Published var showAlert = false
    @Published var alertMessage = ""
    @Published var nextAutoBackupDate: String = "Désactivé"
    
    private let configURL: URL
    private var autoBackupTimer: Timer?
    
    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("DuplicityManager", isDirectory: true)
        try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)
        configURL = appFolder.appendingPathComponent("config.json")
        
        loadConfig()
        checkStatus()
        setupAutoBackup()
    }
    
    deinit {
        autoBackupTimer?.invalidate()
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
        fileList = "Chargement..."
        
        let args = ["list-current-files", "ftp://\(config.ftpUser)@\(config.ftpHost)\(config.ftpPath)"]
        
        runDuplicity(args: args) { output, _ in
            self.fileList = output
            self.isListing = false
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
                    Button(action: {
                        manager.refreshFiles()
                    }) {
                        Label("Rafraîchir", systemImage: "arrow.clockwise")
                    }
                    .disabled(manager.isListing)
                }
                .padding()
                
                ScrollView {
                    Text(manager.fileList)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(8)
                .padding(.horizontal)
            }
            .tabItem {
                Label("Fichiers", systemImage: "doc.on.doc")
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
