import AppKit
import NszCore

// MARK: - Localization

/// Localized string lookup (en.lproj / zh-Hans.lproj Localizable.strings in the bundle).
func L(_ key: String, _ args: CVarArg...) -> String {
    let fmt = NSLocalizedString(key, comment: "")
    return args.isEmpty ? fmt : String(format: fmt, arguments: args)
}

// MARK: - Task model

final class DecompressTask: NSObject {
    enum State { case queued, running, done, failed }

    let url: URL
    var state: State = .queued
    var status: String = L("task.queued")
    var progress: Double = 0
    /// true if the output was renamed because of a name conflict
    var renamed = false
    var outputPath: String?

    init(url: URL) { self.url = url }
}

// MARK: - Background view (behind the task list / progress area)

final class BackgroundView: NSView {
    /// Optional background image loaded from the app bundle (Background.png/jpg/jpeg/svg)
    private let backgroundImage: NSImage? = {
        for name in ["Background", "background"] {
            for ext in ["png", "jpg", "jpeg", "svg"] {
                if let url = Bundle.main.url(forResource: name, withExtension: ext),
                   let img = NSImage(contentsOf: url) {
                    return img
                }
            }
        }
        return nil
    }()

    override func draw(_ dirtyRect: NSRect) {
        guard let img = backgroundImage else { return }
        let box = bounds

        // aspect-fill the whole area with the image
        let imgSize = img.size
        guard imgSize.width > 0, imgSize.height > 0 else { return }
        let scale = max(box.width / imgSize.width, box.height / imgSize.height)
        let drawRect = NSRect(x: box.midX - imgSize.width * scale / 2,
                              y: box.midY - imgSize.height * scale / 2,
                              width: imgSize.width * scale,
                              height: imgSize.height * scale)
        img.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)

        // scrim so task rows stay readable on busy images
        NSColor.windowBackgroundColor.withAlphaComponent(0.55).setFill()
        box.fill()
    }
}

// MARK: - Drag & drop view

final class DropView: NSView {
    var onFiles: ([URL]) -> Void = { _ in }
    var isHighlighted = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return [] }
        isHighlighted = true
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { isHighlighted = false }
    override func draggingEnded(_ sender: NSDraggingInfo) { isHighlighted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isHighlighted = false
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                               options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        onFiles(urls)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 14, dy: 12)
        let path = NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12)
        NSColor.controlBackgroundColor.withAlphaComponent(0.6).setFill()
        path.fill()
        if isHighlighted {
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 3
        } else {
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1.5
        }
        path.stroke()
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var tasks: [DecompressTask] = []
    private let workerQueue = DispatchQueue(label: "nsz.worker")
    private var tableView: NSTableView!
    private var statusFooter: NSTextField!
    private var emptyHint: NSTextField!

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: window setup

    func createWindow() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        win.title = L("window.title")
        win.titlebarAppearsTransparent = false
        win.minSize = NSSize(width: 460, height: 360)

        let content = NSView(frame: win.contentLayoutRect)

        // --- drop zone ---
        let drop = DropView(frame: NSRect(x: 0, y: 370, width: 560, height: 90))
        drop.autoresizingMask = [.width]
        drop.onFiles = { [weak self] urls in self?.addFiles(urls) }

        let dropTitle = NSTextField(labelWithString: L("drop.title"))
        dropTitle.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        dropTitle.alignment = .center
        dropTitle.frame = NSRect(x: 0, y: 46, width: 560, height: 22)
        dropTitle.autoresizingMask = [.width]

        let dropSub = NSTextField(labelWithString: L("drop.sub"))
        dropSub.font = NSFont.systemFont(ofSize: 11)
        dropSub.textColor = .secondaryLabelColor
        dropSub.alignment = .center
        dropSub.frame = NSRect(x: 0, y: 26, width: 560, height: 16)
        dropSub.autoresizingMask = [.width]

        drop.addSubview(dropTitle)
        drop.addSubview(dropSub)

        // --- task table (with optional background image behind it) ---
        let tableContainer = NSView(frame: NSRect(x: 0, y: 32, width: 560, height: 338))
        tableContainer.autoresizingMask = [.width, .height]
        tableContainer.wantsLayer = true
        tableContainer.layer?.cornerRadius = 12
        tableContainer.layer?.masksToBounds = true

        let background = BackgroundView(frame: tableContainer.bounds)
        background.autoresizingMask = [.width, .height]
        tableContainer.addSubview(background)

        let scroll = NSScrollView(frame: tableContainer.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let table = NSTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 56
        table.gridStyleMask = []
        table.allowsColumnReordering = false
        table.allowsMultipleSelection = false

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("task"))
        // default column width is 50pt which squashes the cell's layout —
        // make the single column track the scroll view width instead
        col.resizingMask = .autoresizingMask
        col.minWidth = 200
        table.addTableColumn(col)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.delegate = self
        table.dataSource = self

        scroll.documentView = table
        table.sizeLastColumnToFit()
        col.width = max(scroll.bounds.width, 200)
        table.sizeLastColumnToFit()
        tableContainer.addSubview(scroll)
        tableView = table

        // --- empty hint ---
        emptyHint = NSTextField(wrappingLabelWithString: L("empty.hint"))
        emptyHint.font = NSFont.systemFont(ofSize: 12)
        emptyHint.textColor = .tertiaryLabelColor
        emptyHint.alignment = .center
        emptyHint.isSelectable = false
        emptyHint.frame = NSRect(x: 0, y: 170, width: 560, height: 40)
        emptyHint.autoresizingMask = [.width]

        // --- footer ---
        statusFooter = NSTextField(labelWithString: L("footer.ready"))
        statusFooter.font = NSFont.systemFont(ofSize: 11)
        statusFooter.textColor = .secondaryLabelColor
        statusFooter.lineBreakMode = .byTruncatingMiddle
        statusFooter.frame = NSRect(x: 12, y: 8, width: 536, height: 16)
        statusFooter.autoresizingMask = [.width]

        content.addSubview(drop)
        content.addSubview(tableContainer)
        content.addSubview(emptyHint)
        content.addSubview(statusFooter)

        win.contentView = content
        win.center()
        window = win
        window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Files delivered via Open With / Dock drop / `open -a` while running.
    func application(_ application: NSApplication, open urls: [URL]) {
        addFiles(urls)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: task management

    func addFiles(_ urls: [URL]) {
        var added = false
        for u in urls {
            let ext = u.pathExtension.lowercased()
            guard ext == "nsz" || ext == "ncz" else {
                setFooter(L("skip.unsupported", u.lastPathComponent))
                continue
            }
            guard !tasks.contains(where: { $0.url.standardizedFileURL == u.standardizedFileURL }) else { continue }
            let t = DecompressTask(url: u)
            tasks.append(t)
            // process serially: each block runs one at a time on the worker queue
            workerQueue.async { [weak self] in self?.process(t) }
            added = true
        }
        if added {
            emptyHint.isHidden = true
            reload()
        }
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    private func reload() {
        onMain { [weak self] in self?.tableView.reloadData() }
    }

    private func setFooter(_ s: String) {
        onMain { [weak self] in self?.statusFooter.stringValue = s }
    }

    // MARK: worker

    private func process(_ task: DecompressTask) {
        onMain {
            task.state = .running
            task.status = L("task.scanning")
            self.reload()
        }

        do {
            let target = try NszOutput.outputPathBeside(input: task.url.path)
            let targetName = (target as NSString).lastPathComponent
            let defaultName = try NszOutput.defaultOutputPath(forInput: task.url.path)
            let conflict = targetName != defaultName
            onMain {
                task.renamed = conflict
                task.outputPath = target
                task.status = conflict ? L("task.renamed", targetName) : L("task.extracting")
                self.reload()
                if conflict { self.setFooter(L("footer.renamed", targetName)) }
            }

            try decompressContainer(inputPath: task.url.path, outputPath: target, skipScan: false) { [weak self] event in
                guard let self = self else { return }
                switch event {
                case .scanWarning(let name, let runs):
                    let totalMB = Double(runs.reduce(0) { $0 + $1.length }) / 1048576
                    self.onMain {
                        task.status = L("warn.zeroholes", runs.count, totalMB)
                        self.setFooter(L("footer.zeroholes", name, runs.count))
                        self.reload()
                    }
                case .progress(_, let written, let total):
                    let frac = total > 0 ? Double(written) / Double(total) : 0
                    self.onMain {
                        task.progress = frac
                        task.status = L("task.progress", frac * 100,
                                        Double(written) / 1048576, Double(total) / 1048576)
                        self.reload()
                    }
                case .entryDone(let name, let hash, let verified):
                    self.onMain {
                        self.setFooter(L("footer.verified", name, String(hash.prefix(16)),
                                         verified ? L("verify.ok") : L("verify.mismatch")))
                    }
                case .entryCopied(let name):
                    self.onMain { self.setFooter(L("footer.copied", name)) }
                case .done(let summary):
                    self.onMain {
                        task.progress = 1
                        task.state = .done
                        let outName = ((task.outputPath ?? "") as NSString).lastPathComponent
                        task.status = outName.isEmpty ? L("task.done") : L("task.done.arrow", outName)
                        self.setFooter(summary)
                        self.reload()
                    }
                case .entryStart:
                    break
                }
            }
        } catch {
            onMain {
                task.state = .failed
                task.status = L("task.failed", String(describing: error))
                self.reload()
                self.setFooter(L("footer.failed", task.url.lastPathComponent, String(describing: error)))
            }
        }
    }
}

// MARK: - Table view

extension AppDelegate: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { tasks.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let task = tasks[row]
        let cellID = NSUserInterfaceItemIdentifier("taskCell")
        let cell: NSView

        if let reused = tableView.makeView(withIdentifier: cellID, owner: self) {
            cell = reused
        } else {
            let v = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 56))
            v.identifier = cellID

            let icon = NSTextField(labelWithString: "📦")
            icon.font = NSFont.systemFont(ofSize: 18)
            icon.frame = NSRect(x: 14, y: 16, width: 26, height: 24)
            icon.autoresizingMask = [.maxYMargin, .minYMargin]
            v.addSubview(icon)

            let name = NSTextField(labelWithString: "")
            name.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            name.lineBreakMode = .byTruncatingMiddle
            name.frame = NSRect(x: 48, y: 30, width: 340, height: 18)
            name.autoresizingMask = [.width]
            name.identifier = NSUserInterfaceItemIdentifier("name")
            v.addSubview(name)

            let status = NSTextField(labelWithString: "")
            status.font = NSFont.systemFont(ofSize: 11)
            status.textColor = .secondaryLabelColor
            status.lineBreakMode = .byTruncatingMiddle
            status.frame = NSRect(x: 48, y: 10, width: 340, height: 15)
            status.autoresizingMask = [.width]
            status.identifier = NSUserInterfaceItemIdentifier("status")
            v.addSubview(status)

            let bar = NSProgressIndicator(frame: NSRect(x: 400, y: 20, width: 104, height: 14))
            bar.isIndeterminate = false
            bar.minValue = 0
            bar.maxValue = 1
            bar.autoresizingMask = [.minXMargin]
            bar.identifier = NSUserInterfaceItemIdentifier("bar")
            v.addSubview(bar)

            cell = v
        }

        let name = cell.subviews.first { $0.identifier?.rawValue == "name" } as? NSTextField
        let status = cell.subviews.first { $0.identifier?.rawValue == "status" } as? NSTextField
        let bar = cell.subviews.first { $0.identifier?.rawValue == "bar" } as? NSProgressIndicator

        name?.stringValue = task.url.lastPathComponent
        name?.toolTip = task.url.path
        status?.stringValue = task.status
        switch task.state {
        case .queued:   status?.textColor = .secondaryLabelColor
        case .running:  status?.textColor = .controlAccentColor
        case .done:     status?.textColor = .systemGreen
        case .failed:   status?.textColor = .systemRed
        }
        bar?.doubleValue = task.progress
        bar?.isIndeterminate = (task.state == .running && task.progress == 0)
        if bar?.isIndeterminate == true { bar?.startAnimation(nil) }
        return cell
    }
}

// MARK: - Quick Action self-install

/// Keeps the Finder Quick Action (右键 → 快速操作 → 解压 NSZ) in sync with this app.
/// Runs on every launch: creates or updates ~/Library/Services/解压 NSZ.workflow
/// so it always points at the running app bundle.
enum QuickActionInstaller {
    static func install() {
        let appPath = Bundle.main.bundlePath
        // only meaningful when running from a real .app bundle
        guard appPath.hasSuffix(".app") else { return }

        let name = L("quickaction.name")
        let fm = FileManager.default
        let wfContents = NSHomeDirectory() + "/Library/Services/\(name).workflow/Contents"
        let infoPath = wfContents + "/Info.plist"
        let wflowPath = wfContents + "/document.wflow"

        // skip if already installed and pointing at this app
        if let data = try? Data(contentsOf: URL(fileURLWithPath: infoPath)),
           let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           (info["NSServices"] as? [[String: Any]])?.isEmpty == false,
           fm.fileExists(atPath: wflowPath) {
            if let wdata = try? Data(contentsOf: URL(fileURLWithPath: wflowPath)),
               let wflow = try? PropertyListSerialization.propertyList(from: wdata, format: nil) as? [String: Any],
               let actions = wflow["actions"] as? [[String: Any]],
               let action = actions.first?["action"] as? [String: Any],
               let params = action["ActionParameters"] as? [String: Any],
               let cmd = params["COMMAND_STRING"] as? String,
               cmd.contains("\"\(appPath)\"") {
                return // up to date
            }
        }

        let infoPlist: [String: Any] = [
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundleIdentifier": "com.biu.nszapp.quickaction",
            "CFBundleVersion": "1.0",
            "CFBundleInfoDictionaryVersion": "6.0",
            "NSServices": [[
                "NSMenuItem": ["default": name],
                "NSMessage": "runWorkflowAsService",
                "NSSendFileTypes": ["public.item"],
            ]],
        ]

        let script = "open -a \"\(appPath)\" \"$@\"\n"
        let wflow: [String: Any] = [
            "AMApplicationBuild": "528",
            "AMApplicationVersion": "2.10",
            "AMDocumentVersion": "2",
            "actions": [[
                "action": [
                    "AMAccepts": ["Container": "List", "Optional": true, "Types": ["com.apple.cocoa.path"]],
                    "AMActionVersion": "2.0.3",
                    "AMApplication": ["Automator"],
                    "AMParameterProperties": ["COMMAND_STRING": [String: Any](), "inputMethod": [String: Any](), "shell": [String: Any]()],
                    "AMProvides": ["Container": "List", "Optional": true, "Types": ["com.apple.cocoa.path"]],
                    "ActionBundlePath": "/System/Library/Automator/Run Shell Script.action",
                    "ActionName": "Run Shell Script",
                    "ActionParameters": [
                        "COMMAND_STRING": script,
                        "CheckedForUser": true,
                        "inputMethod": 1, // pass input as arguments ($@)
                        "shell": "/bin/zsh",
                    ],
                    "BundleIdentifier": "com.apple.RunShellScript",
                    "CFBundleVersion": "2.0.3",
                    "CanShowSelectedItemsWhenRun": false,
                    "CanShowWhenRun": true,
                    "Category": [String](),
                    "Class Name": "RunShellScriptAction",
                    "InputUUID": "NSZ-INPUT-UUID",
                    "Keywords": ["Shell"],
                    "OutputUUID": "NSZ-OUTPUT-UUID",
                    "UUID": "NSZ-ACTION-UUID",
                    "UnlocalizedApplications": ["Automator"],
                    "arguments": [
                        "0": ["default value": 0, "name": "inputMethod", "required": "0", "type": "0"],
                        "1": ["default value": "", "name": "COMMAND_STRING", "required": "0", "type": "0"],
                        "2": ["default value": "/bin/zsh", "name": "shell", "required": "0", "type": "0"],
                    ],
                    "isViewVisible": 1,
                    "location": "309.000000:253.000000",
                    "nibPath": "/System/Library/Automator/Run Shell Script.action/Contents/Resources/Base.lproj/main.nib",
                ],
                "isViewVisible": 1,
            ]],
            "connectors": [String: Any](),
            "workflowMetaData": [
                "applicationBundleIDsByPath": [String: Any](),
                "applicationPaths": [String: Any](),
                "inputTypeIdentifier": "com.apple.Automator.fileSystemObject",
                "outputTypeIdentifier": "com.apple.Automator.nothing",
                "presentationMode": 11,
                "processesInput": 0,
                "serviceApplicationBundleID": "com.apple.finder",
                "serviceApplicationPath": "/System/Library/CoreServices/Finder.app",
                "serviceInputTypeIdentifier": "com.apple.Automator.fileSystemObject",
                "serviceOutputTypeIdentifier": "com.apple.Automator.nothing",
                "serviceProcessesInput": 0,
                "systemImageName": "NSActionTemplate",
                "useAutomaticInputType": 1,
                "workflowTypeIdentifier": "com.apple.Automator.servicesMenu",
            ],
        ]

        do {
            try fm.createDirectory(atPath: wfContents, withIntermediateDirectories: true)
            try writePlist(infoPlist, to: infoPath)
            try writePlist(wflow, to: wflowPath)
            // refresh the services cache
            let pbs = Process()
            pbs.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/pbs")
            pbs.arguments = ["-flush"]
            try? pbs.run()
            pbs.waitUntilExit()
            NSLog("[Nsz] Quick Action installed/updated -> %@ (app: %@)", wfContents, appPath)
        } catch {
            NSLog("[Nsz] Quick Action install failed: %@", String(describing: error))
        }
    }

    private static func writePlist(_ obj: [String: Any], to path: String) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: obj, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - App entry point

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
appDelegate.createWindow()

// keep the Finder Quick Action pointing at this app (no-op if already up to date)
DispatchQueue.global(qos: .utility).async {
    QuickActionInstaller.install()
}

// Files passed as launch arguments (Finder "Open With", Quick Action, `open -a`)
let argvURLs = CommandLine.arguments.dropFirst().map {
    URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
}
if !argvURLs.isEmpty {
    appDelegate.addFiles(argvURLs)
}

app.activate(ignoringOtherApps: true)
app.run()
