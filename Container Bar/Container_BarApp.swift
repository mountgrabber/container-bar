import SwiftUI
import SwiftData
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem?

    // Настройки контейнера
    private let containerBinaryPath = "/usr/local/bin/container"

    // Кэш последнего списка контейнеров
    private var lastContainers: [PSItem] = []

    // Флаг для предотвращения параллельных обновлений меню
    private var isUpdatingMenu = false

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Попробуем запустить системные службы container
        Task { [weak self] in
            guard let self else { return }
            let result = await self.runContainerCLI(arguments: ["system", "start"])
            if result.exitCode == 0 {
                print("container system start: OK")
            } else {
                // Не критично, если уже запущено или недоступно — просто логируем
                print("container system start failed: \(result.stderr)")
            }
        }

        // Статус-иконка с меню
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: "Container Bar")
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem?.menu = menu
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Ничего не делаем
    }

    // MARK: - NSMenuDelegate (динамическое меню)

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard !isUpdatingMenu else { return }
        isUpdatingMenu = true

        Task { [weak self] in
            guard let self else { return }
            let containers = await self.listContainersWithAllIfPossible()

            await MainActor.run {
                defer { self.isUpdatingMenu = false }
                guard let currentMenu = self.statusItem?.menu, currentMenu === menu else { return }
                self.lastContainers = containers
                self.rebuildMenu(currentMenu, with: containers)
            }
        }
    }

    private func rebuildMenu(_ menu: NSMenu, with containers: [PSItem]) {
        menu.removeAllItems()

        let header = NSMenuItem()
        header.title = "Containers"
        header.isEnabled = false
        menu.addItem(header)

        if containers.isEmpty {
            let emptyItem = NSMenuItem()
            emptyItem.title = "No containers found"
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for item in containers {
                let row = NSMenuItem()
                row.image = statusDotImage(for: item)
                row.title = menuRowTitle(for: item)
                row.action = #selector(toggleContainerAction(_:))
                row.target = self
                row.representedObject = item
                menu.addItem(row)
            }
        }

        menu.addItem(NSMenuItem.separator())

        let refresh = NSMenuItem(title: "Refresh", action: #selector(refreshMenu), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func statusDotImage(for item: PSItem) -> NSImage? {
        let isRunning = isRunningStatus(item.status)
        let symbolName = isRunning ? "circle.fill" : "circle"
        let color = isRunning ? NSColor.systemGreen : NSColor.systemGray

        guard var image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else { return nil }
        let baseConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        image = image.withSymbolConfiguration(baseConfig) ?? image
        let colorConfig = NSImage.SymbolConfiguration(paletteColors: [color])
        image = image.withSymbolConfiguration(colorConfig) ?? image
        image.isTemplate = false
        return image
    }

    private func isRunningStatus(_ status: String) -> Bool {
        let s = status.lowercased()
        return s == "running" || s.contains("up") || s.contains("started")
    }

    private func menuRowTitle(for item: PSItem) -> String {
        let actionText = isRunningStatus(item.status) ? "Stop" : "Start"
        return "\(item.name) — \(item.status)  [\(actionText)]"
    }

    @objc private func toggleContainerAction(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? PSItem else { return }
        let running = isRunningStatus(item.status)

        Task { [weak self] in
            guard let self else { return }
            if running {
                let res = await self.runContainerCLI(arguments: ["stop", item.name])
                if res.exitCode != 0 {
                    print("Failed to stop \(item.name): \(res.stderr)")
                }
            } else {
                let startRes = await self.runContainerCLI(arguments: ["start", item.name])
                if startRes.exitCode != 0 {
                    print("Failed to start \(item.name): \(startRes.stderr)")
                }
            }

            await MainActor.run {
                if let menu = self.statusItem?.menu {
                    self.menuNeedsUpdate(menu)
                }
            }
        }
    }

    @objc private func refreshMenu() {
        guard let menu = statusItem?.menu else { return }
        menuNeedsUpdate(menu)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }


    private enum ContainerState {
        case running
        case existsButStopped
        case notFound
        case unknown
    }

    private struct PSItem: Equatable {
        let name: String
        let status: String
    }

    private func containerState(name: String) async -> ContainerState {
        let active = await listContainers(activeOnly: true)
        if active.contains(where: { $0.name == name }) {
            return .running
        }
        let all = await listContainers(activeOnly: false)
        if all.contains(where: { $0.name == name }) {
            return .existsButStopped
        }
        return .notFound
    }

    // Используем list/ls с табличным выводом.
    private func listContainers(activeOnly: Bool) async -> [PSItem] {
        // 1) Основная попытка: list (без/с --all)
        var args: [String] = ["list"]
        if !activeOnly {
            args.append("--all")
        }
        var result = await runContainerCLI(arguments: args)
        var parsed = parseTabularList(result.stdout)
        if result.exitCode == 0, !parsed.isEmpty {
            return parsed
        }

        // 2) Альтернатива: ls (без/с --all)
        args[0] = "ls"
        result = await runContainerCLI(arguments: args)
        parsed = parseTabularList(result.stdout)
        return parsed
    }

    // Парсим табличный вывод:
    // Первая строка — заголовки (ID IMAGE OS ARCH STATE IP CPUS MEMORY STARTED)
    // Остальные строки — значения, разделенные пробелами/табами.
    // Нам нужны только ID (колонка 1) и STATE (колонка 5).
    private func parseTabularList(_ stdout: String) -> [PSItem] {
        let lines = stdout
            .split(separator: "\n")
            .map { String($0) }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        guard lines.count >= 2 else { return [] } // только заголовок или пусто

        var items: [PSItem] = []
        for i in 1..<lines.count {
            let line = lines[i]
            let cols = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard cols.count >= 5 else { continue }
            let id = cols[0]
            let state = cols[4]
            items.append(PSItem(name: id, status: state))
        }
        return items
    }

    private func listContainersWithAllIfPossible() async -> [PSItem] {
        // Сначала попытаемся получить все (list --all). Если пусто — вернем активные (list).
        let all = await listContainers(activeOnly: false)
        if !all.isEmpty {
            let active = await listContainers(activeOnly: true)
            var byName: [String: PSItem] = [:]
            for a in all { byName[a.name] = a }
            for a in active { byName[a.name] = a }
            return byName.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } else {
            return await listContainers(activeOnly: true)
        }
    }

    // MARK: - CLI runner

    private func runContainerCLI(arguments: [String]) async -> (exitCode: Int32, stdout: String, stderr: String) {
        return await runProcess(executable: containerBinaryPath, arguments: arguments)
    }

    private func runProcess(executable: String, arguments: [String]) async -> (exitCode: Int32, stdout: String, stderr: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            var stdoutData = Data()
            var stderrData = Data()

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { stdoutData.append(data) }
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { stderrData.append(data) }
            }

            process.terminationHandler = { _ in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                continuation.resume(returning: (process.terminationStatus, stdout, stderr))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: (EXIT_FAILURE, "", "Failed to launch process: \(error)"))
            }
        }
    }
}

@main
struct Container_ManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
