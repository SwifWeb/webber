//
//  BundleCommand.swift
//  Webber
//
//  Created by Mihael Isaev on 21.02.2021.
//

import ConsoleKit
import Vapor
import NIOSSL
import WasmTransformer
import WebberTools

class BundleCommand: Command {
    var server: Server!
    lazy var dir = DirectoryConfiguration.detect()
    var context: WebberContext!
    lazy var toolchain = Toolchain(context)
    var swift: Swift!
    var serviceWorkerTarget: String?
    var productTarget: String!
    var webber: Webber!
    var debug: Bool { false }
    var serve: Bool { false }
    var appType: AppType = .spa
    var products: [String] = []
    
    enum CommandError: Error, CustomStringConvertible {
        case error(String)
        
        var description: String {
            switch self {
            case .error(let description): return description
            }
        }
    }
    
    struct Signature: CommandSignature {
        @Option(
            name: "toolchain",
            help: "Toolchain tag name from official swift-wasm/swift repo https://github.com/swiftwasm/swift/tags"
        )
        var toolchain: String?
        
        @Option(
            name: "type",
            short: "t",
            help: "App type. It is `spa` by default. Could also be `pwa`.",
            completion: .values(AppType.all)
        )
        var type: AppType?
        
        @Option(
            name: "service-worker-target",
            short: "s",
            help: "Name of service worker target."
        )
        var serviceWorkerTarget: String?
        
        @Option(
            name: "app-target",
            short: "a",
            help: "Name of app target."
        )
        var appTarget: String?
        
        @Option(
            name: "verbose",
            short: "v",
            help: "Prints more info in console."
        )
        var verbose: Bool?
        
        @Option(
            name: "debug-verbose",
            short: "d",
            help: "Prints a lot of info in console."
        )
        var debugVerbose: Bool?
        
        @Option(
            name: "port",
            short: "p",
            help: "Port for webber server. Default is 8888."
        )
        var port: Int?
        
        @Option(
            name: "browser",
            help: "Destination browser name to automatically launch in.",
            completion: .values(BrowserType.all)
        )
        var browserType: BrowserType?
        
        @Option(
            name: "browser-self-signed",
            help: "Opens additional instance of browser with allowed self-signed SSL setting to debug service-workers."
        )
        var browserSelfSigned: Bool?
        
        @Option(
            name: "browser-incognito",
            help: "Opens additional instance of browser in incognito mode."
        )
        var browserIncognito: Bool?

        init() {}
    }
    
    var help: String { "" }

    func run(using context: CommandContext, signature: Signature) throws {
        appType = signature.type ?? .spa
        serviceWorkerTarget = signature.serviceWorkerTarget
        context.console.output([
            ConsoleTextFragment(string: String.swifWebASCIILogo, style: .init(color: .green, isBold: false))
        ])
//        context.console.output([
//            ConsoleTextFragment(string: String.swifWebASCIILogo2, style: .init(color: .green, isBold: false))
//        ])
//        context.console.output([
//            ConsoleTextFragment(string: String.swifWebASCIILogo3, style: .init(color: .green, isBold: false))
//        ])
        if appType == .pwa && serviceWorkerTarget == nil {
            throw CommandError.error("You have to provide service target name for PWA. Use: -s ServiceTargetName")
        } else if appType != .pwa && serviceWorkerTarget != nil {
            context.console.output([
                ConsoleTextFragment(string: "You provided service target name but forgot to set app type to PWA.", style: .init(color: .magenta, isBold: true)),
                ConsoleTextFragment(string: " Use: -t pwa", style: .init(color: .yellow, isBold: true))
            ])
        }
        
        // Instantiate webber context
        self.context = WebberContext(
            customToolchain: signature.toolchain,
            dir: dir,
            command: context,
            verbose: signature.$verbose.isPresent,
            debugVerbose: signature.$debugVerbose.isPresent,
            port: signature.port ?? 8888,
            browserType: signature.browserType,
            browserSelfSigned: signature.$browserSelfSigned.isPresent,
            browserIncognito: signature.$browserIncognito.isPresent,
            console: context.console
        )
        
        self.context.debugVerbose("Instantiate swift started")
        // Instantiate swift
        swift = Swift(try toolchain.pathToSwift(), self.context.dir.workingDirectory)
        self.context.debugVerbose("Instantiate swift finished")
        
        // Printing swift version
        self.context.debugVerbose("Printing swift version started")
        context.console.output("\n\(try swift.version())")
        self.context.debugVerbose("Printing swift version finished")

        // Lookup product target
        self.context.debugVerbose("Lookup product target started")
        if let appTarget = signature.appTarget {
            productTarget = signature.appTarget
            try swift.checkIfAppProductPresent(appTarget)
        } else {
            productTarget = try swift.lookupExecutableName(excluding: serviceWorkerTarget)
        }
        self.context.debugVerbose("Lookup product target finished")
        
        // Check for service worker target
        self.context.debugVerbose("Check for service worker target started")
        if appType == .pwa {
            if let sw = serviceWorkerTarget {
                try swift.checkIfServiceWorkerProductPresent(sw)
            }
        }
        self.context.debugVerbose("Check for service worker target finished")
        
        // Fill products array
        self.context.debugVerbose("Fill products array started")
        products.append(productTarget)
        if let product = serviceWorkerTarget {
            products.append(product)
        }
        self.context.debugVerbose("Fill products array finished")
        
        // Instantiate webber
        self.context.debugVerbose("Instantiate webber object started")
        webber = try Webber(self.context)
        self.context.debugVerbose("Instantiate webber object finished")
        
        self.context.debugVerbose("Execute method started")
        try execute()
        self.context.debugVerbose("Execute method finished")
        
        if serve {
            self.context.debugVerbose("Watching for file changes")
            try watchForFileChanges()
            self.context.debugVerbose("Spinning up the local server")
            try spinup()
        }
    }
    
    func execute() throws {
        self.context.debugVerbose("Execute method: iterating products started (products.count: \(products.count)")
        try products.forEach { product in
            try build(product, alsoNative: serviceWorkerTarget == product)
        }
        self.context.debugVerbose("Execute method: iterating products finished")
		
        self.context.debugVerbose("Execute method: dependencies installation started")
		try webber.installDependencies()
        self.context.debugVerbose("Execute method: dependencies installation finished")
		
		if !debug {
            self.context.debugVerbose("Execute method: optimization started")
			try products.forEach { product in
				try optimize(product)
			}
            self.context.debugVerbose("Execute method: optimization finished")
		}
        
        self.context.debugVerbose("Execute method: cooking web files started")
        try cook()
        self.context.debugVerbose("Execute method: cooking web files finished")
        self.context.debugVerbose("Execute method: moving wasm files started")
        try moveWasmFiles()
        self.context.debugVerbose("Execute method: moving wasm files finished")
        self.context.debugVerbose("Execute method: moving resources started")
        try webber.moveResources(dev: debug)
        self.context.debugVerbose("Execute method: moving resources finished")
    }
    
    /// Build swift into wasm (sync)
    private func build(_ targetName: String, alsoNative: Bool = false) throws {
        context.command.console.output([
            ConsoleTextFragment(string: "Started building product ", style: .init(color: .brightGreen, isBold: true)),
            ConsoleTextFragment(string: targetName, style: .init(color: .brightYellow))
        ])
        
        let buildingStartedAt = Date()
//        let buildingBar = context.command.console.loadingBar(title: "Building")
//        buildingBar.start()
        try swiftBuild(targetName, release: !debug, tripleWasm: true)
        if alsoNative {
            // building non-wasi executable (usually for service worker to grab manifest json)
            // should be built in debug cause of compile error in JavaScriptKit in release mode
//            buildingBar.activity.title = "Grabbing info"
            try swiftBuild(targetName, release: false, tripleWasm: false)
        }
//        buildingBar.succeed()

        context.command.console.clear(.line)
        context.command.console.output([
            ConsoleTextFragment(string: "Finished building ", style: .init(color: .brightGreen, isBold: true)),
            ConsoleTextFragment(string: targetName, style: .init(color: .brightYellow)),
            ConsoleTextFragment(string: " in ", style: .init(color: .brightGreen, isBold: true)),
            ConsoleTextFragment(string: String(format: "%.2fs", Date().timeIntervalSince(buildingStartedAt)), style: .init(color: .brightMagenta))
        ])
    }
    
    private func _printBuildErrors(_ compilationProblem: Swift.SwiftError) throws {
        switch compilationProblem {
        case .errors(let errors):
            context.command.console.output(" ")
            for error in errors {
                context.command.console.output([
                    ConsoleTextFragment(string: " " + error.file.lastPathComponent + " ", style: .init(color: .green, background: .custom(r: 68, g: 68, b: 68)))
                ] + " " + [
                    ConsoleTextFragment(string: error.file.path, style: .init(color: .custom(r: 168, g: 168, b: 168)))
                ])
                context.command.console.output(" ")
                for place in error.places {
                    let lineNumberString = "\(place.line) |"
                    let errorTitle = " ERROR "
                    let errorTitlePrefix = "   "
                    context.command.console.output([
                        ConsoleTextFragment(string: errorTitlePrefix, style: .init(color: .none)),
                        ConsoleTextFragment(string: errorTitle, style: .init(color: .brightWhite, background: .red, isBold: true))
                    ] + " " + [
                        ConsoleTextFragment(string: place.reason, style: .init(color: .none))
                    ])
                    let _len = (errorTitle.count + 5) - lineNumberString.count
                    let errorLinePrefix = _len > 0 ? (0..._len).map { _ in " " }.joined(separator: "") : ""
                    context.command.console.output([
                        ConsoleTextFragment(string: errorLinePrefix + lineNumberString, style: .init(color: .brightCyan))
                    ] + " " + [
                        ConsoleTextFragment(string: place.code, style: .init(color: .none))
                    ])
                    let linePointerBeginning = (0...lineNumberString.count - 2).map { _ in " " }.joined(separator: "") + "|"
                    context.command.console.output([
                        ConsoleTextFragment(string: errorLinePrefix + linePointerBeginning, style: .init(color: .brightCyan))
                    ] + " " + [
                        ConsoleTextFragment(string: place.pointer, style: .init(color: .brightRed))
                    ])
                    context.command.console.output(" ")
                }
            }
        case .raw(let raw):
            context.command.console.output([
                ConsoleTextFragment(string: "Compilation failed\n", style: .init(color: .brightMagenta)),
                ConsoleTextFragment(string: raw, style: .init(color: .brightRed))
            ])
            throw Swift.SwiftError.text("Unable to continue cause of failed compilation 🥺\n")
        default:
            throw compilationProblem
        }
    }
    
    private func swiftBuild(_ productName: String, release: Bool = false, tripleWasm: Bool) throws {
        if webber.context.verbose {
            context.command.console.output([
                ConsoleTextFragment(string: swift.launchPath, style: .init(color: .brightBlue, isBold: true)),
                ConsoleTextFragment(string: " " + Swift.Command.build(release: release, productName: productName).arguments(tripleWasm: tripleWasm).joined(separator: " ") + "\n", style: .init(color: .brightMagenta))
            ])
        }
        do {
            try swift.build(productName, release: release, tripleWasm: tripleWasm)
        } catch let error as Swift.SwiftError {
            try _printBuildErrors(error)
            throw error
        } catch {
            throw error
        }
    }
    
    private func optimize(_ targetName: String) throws {
        // Optimization for old Safari
        try Optimizer.optimizeForOldSafari(debug: debug, targetName, context: context)
        // Stripping debug info
        try Optimizer.stripDebugInfo(targetName, context: context)
        // Optimize using `wasm-opt`
        try WasmOpt.optimize(targetName, context: context)
    }
    
    /// Cook web files
    private func cook() throws {
		try webber.cook(
            dev: debug,
            appTarget: productTarget,
            serviceWorkerTarget: serviceWorkerTarget ?? "sw",
            type: appType
        )
    }
    
    /// Moves wasm files into public dev/release folder
    private func moveWasmFiles() throws {
        try products.forEach { product in
            try webber.moveWasmFile(dev: debug, productName: product)
        }
    }
    
    lazy var rebuildQueue = DispatchQueue(label: "webber.rebuilder")
    private var lastRebuildRequestedAt: Date?
    
    func watchForFileChanges() throws {
        var isRebuilding = false
        var needOneMoreRebuilding = false
        func rebuildWasm() {
            guard !isRebuilding else {
                if let lastRebuildRequestedAt = lastRebuildRequestedAt {
                    if Date().timeIntervalSince(lastRebuildRequestedAt) < 2 {
                        return
                    }
                }
                needOneMoreRebuilding = true
                return
            }
            lastRebuildRequestedAt = Date()
            isRebuilding = true
            let buildingStartedAt = Date()
			context.command.console.output([
				ConsoleTextFragment(string: "Rebuilding, please wait...", style: .init(color: .brightYellow))
			])
			
            let finishRebuilding = {
                isRebuilding = false
                if needOneMoreRebuilding {
                    needOneMoreRebuilding = false
                    rebuildWasm()
                }
            }
            let handleError: (Error) -> Void = { error in
                self.context.command.console.clear(.line)
                self.context.command.console.output([
                    ConsoleTextFragment(string: "Rebuilding error: \(error)", style: .init(color: .brightRed))
                ])
                finishRebuilding()
            }
            var productsToRebuild: [String] = []
            productsToRebuild.append(contentsOf: products)
            func rebuild() {
                guard productsToRebuild.count > 0 else {
                    try? self.webber.recookManifestWithIndex(
                        dev:  self.debug,
                        appTarget: self.productTarget,
                        serviceWorkerTarget: self.serviceWorkerTarget ?? "sw",
                        type: self.appType
                    )
                    self.context.command.console.clear(.line)
                    do {
                        try self.moveWasmFiles()
                        try self.webber.moveResources(dev: debug)
                    } catch {
                        handleError(error)
                    }
                    // notify ws clients
                    self.server.notify(.wasmRecompiled)
                    let df = DateFormatter()
                    df.dateFormat = "hh:mm:ss"
                    // notify console
                    self.context.command.console.output([
                        ConsoleTextFragment(string: "[\(df.string(from: Date()))] Rebuilt in ", style: .init(color: .brightGreen, isBold: true)),
                        ConsoleTextFragment(string: String(format: "%.2fs", Date().timeIntervalSince(buildingStartedAt)), style: .init(color: .brightMagenta))
                    ])
                    finishRebuilding()
                    return
                }
				let product = productsToRebuild.removeFirst()
				do {
					try swift.build(product)
					if self.serviceWorkerTarget == product {
						try self.swift.build(product, tripleWasm: false)
						DispatchQueue.global(qos: .userInteractive).async {
							rebuild()
						}
					} else {
						DispatchQueue.global(qos: .userInteractive).async {
							rebuild()
						}
					}
				} catch let error as Swift.SwiftError {
                    try? _printBuildErrors(error)
                    handleError(error)
                } catch {
					handleError(error)
				}
            }
            DispatchQueue.global(qos: .userInteractive).async {
                rebuild()
            }
        }
        
        // Recooking
        var isRecooking = false
        var needOneMoreRecook = false
        func recookEntrypoint() {
            guard !isRecooking else {
//                needOneMoreRecook = true
                return
            }
            isRecooking = true
            DispatchQueue.global(qos: .userInteractive).async {
                do {
                    // cook web files
                    try self.cook()
                    // notify ws clients
                    self.server.notify(.entrypointRecooked)
                } catch {
                    self.context.command.console.output([
                        ConsoleTextFragment(string: "Recooking error: \(error)", style: .init(color: .brightRed))
                    ])
                }
                isRecooking = false
                if needOneMoreRecook {
                    needOneMoreRecook = false
                    recookEntrypoint()
                }
            }
        }
        FS.watch(URL(fileURLWithPath: dir.workingDirectory).appendingPathComponent("Package.swift")) { url in
            try? self.swift.lookupLocalDependencies().forEach {
                guard !FS.contains(path: $0) else { return }
                FS.watch($0) { url in
                    self.rebuildQueue.sync {
                        rebuildWasm()
                    }
                }
            }
            self.rebuildQueue.sync {
                rebuildWasm()
            }
        }
        FS.watch(URL(fileURLWithPath: dir.workingDirectory).appendingPathComponent(".swift-version")) { url in
            self.rebuildQueue.sync {
                rebuildWasm()
            }
        }
        FS.watch(URL(fileURLWithPath: dir.workingDirectory).appendingPathComponent("Sources")) { url in
            self.rebuildQueue.sync {
                rebuildWasm()
            }
        }
        try swift.lookupLocalDependencies().forEach {
            FS.watch($0) { url in
                self.rebuildQueue.sync {
                    rebuildWasm()
                }
            }
        }
        FS.watch(webber.entrypoint) { url in
            self.rebuildQueue.sync {
                recookEntrypoint()
            }
        }
    }
    
    private var isSpinnedUp = false
    
    /// Spin up Vapor server
    func spinup() throws {
        guard !isSpinnedUp else { return }
        isSpinnedUp = true
        server = Server(webber)
        try server.spinup()
    }
}
