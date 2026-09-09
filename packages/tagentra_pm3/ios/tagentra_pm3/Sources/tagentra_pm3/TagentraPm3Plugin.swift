// SPDX-License-Identifier: GPL-3.0-or-later
import CoreBluetooth
import Flutter
import Network
import UIKit

#if canImport(TagentraPM3Core)
import TagentraPM3Core
#endif

public final class TagentraPm3Plugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private let transport = PM3Transport()
    private var eventSink: FlutterEventSink?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = TagentraPm3Plugin()
        registrar.addMethodCallDelegate(instance, channel: FlutterMethodChannel(name: "org.tagentra/pm3", binaryMessenger: registrar.messenger()))
        FlutterEventChannel(name: "org.tagentra/pm3_events", binaryMessenger: registrar.messenger()).setStreamHandler(instance)
        instance.transport.emit = { [weak instance] event in
            DispatchQueue.main.async { instance?.eventSink?(event) }
        }
        NotificationCenter.default.addObserver(instance, selector: #selector(instance.backgrounded), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? { eventSink = events; return nil }
    public func onCancel(withArguments arguments: Any?) -> FlutterError? { eventSink = nil; return nil }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        switch call.method {
        case "startScan": transport.startScan(timeoutMs: args?["timeoutMs"] as? Int ?? 12_000); result(nil)
        case "stopScan": transport.stopScan(); result(nil)
        case "connect":
            guard let id = args?["id"] as? String else { return fail(result, "argument", "Missing device id") }
            transport.connect(id: id, completion: result)
        case "reconnect": transport.reconnect(completion: result)
        case "disconnect": transport.disconnect(reason: "user"); result(nil)
        case "status": result(transport.status)
        case "detectMode": result(transport.mode.rawValue)
        case "switchToPm3": transport.switchToPM3(completion: result)
        case "switchToChameleon": transport.switchToChameleon(completion: result)
        case "execute":
            guard let command = args?["command"] as? String, !command.isEmpty else { return fail(result, "argument", "Command is empty") }
            transport.execute(command, completion: result)
        case "listArtifacts":
            do { result(try transport.listArtifacts()) } catch { fail(result, "storage", error.localizedDescription) }
        case "shareArtifacts":
            guard let paths = args?["paths"] as? [String], !paths.isEmpty else { return fail(result, "argument", "No artifacts selected") }
            do { try share(paths: paths, result: result) } catch { fail(result, "share", error.localizedDescription) }
        case "cancel": transport.cancel(); result(nil)
        case "exportDiagnostics":
            do { result(try transport.exportDiagnostics().path) } catch { fail(result, "diagnostics", error.localizedDescription) }
        case "applicationSupportDirectory":
            do {
                let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let directory = base.appendingPathComponent("Tagentra", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                result(directory.path)
            } catch { fail(result, "storage", error.localizedDescription) }
        default: result(FlutterMethodNotImplemented)
        }
    }

    private func fail(_ result: FlutterResult, _ code: String, _ message: String) { result(FlutterError(code: code, message: message, details: nil)) }

    private func share(paths: [String], result: @escaping FlutterResult) throws {
        let manager = FileManager.default
        let support = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("Tagentra", isDirectory: true).standardizedFileURL
        let urls = try paths.map { path -> URL in
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard url.path.hasPrefix(support.path + "/"), manager.fileExists(atPath: url.path) else {
                throw NSError(domain: "org.tagentra.pm3", code: 2, userInfo: [NSLocalizedDescriptionKey: "Selected artifact is outside Tagentra storage"])
            }
            return url
        }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            throw NSError(domain: "org.tagentra.pm3", code: 3, userInfo: [NSLocalizedDescriptionKey: "Share panel is unavailable"])
        }
        var presenter = root
        while let presented = presenter.presentedViewController { presenter = presented }
        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = presenter.view
        controller.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
        presenter.present(controller, animated: true) { result(nil) }
    }
    @objc private func backgrounded() { transport.cancel(); transport.disconnect(reason: "background") }
}

private enum DeviceMode: String { case unknown, pm3, chameleon }

private struct ArtifactSnapshot: Equatable {
    let size: Int64
    let modifiedAt: Date
}

#if canImport(TagentraPM3Core)
private func tagentraPM3CoreOutputCallback(_ utf8: UnsafePointer<CChar>?, _ length: Int, _ context: UnsafeMutableRawPointer?) {
    guard let utf8, let context, length > 0 else { return }
    let owner = Unmanaged<PM3Transport>.fromOpaque(context).takeUnretainedValue()
    owner.handleCoreOutput(Data(bytes: utf8, count: length))
}
#endif

private final class PM3Transport: NSObject {
    static let uartService = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    // Nordic UART defaults. Diagnostics report properties before either is used.
    static let uartRX = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    static let uartTX = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    var emit: (([String: Any]) -> Void)?
    private lazy var central = CBCentralManager(delegate: self, queue: .main)
    private var discovered: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var tx: CBCharacteristic?
    private var listener: NWListener?
    private var tcp: NWConnection?
    private var pendingWrites: [Data] = []
    private var pendingWriteDrainCallbacks: [() -> Void] = []
    private var connectCompletion: FlutterResult?
    private var switchCompletion: FlutterResult?
    private var lastDeviceID: UUID?
    private var discoveredMode: DeviceMode = .unknown
    private var modeProbeID: UUID?
    private var modeProbeBuffer = Data()
    private var pm3StartID: UUID?
    private var pm3StartCompletion: ((FlutterError?) -> Void)?
    private var tcpGeneration = UUID()
    private var preserveBLEOnTCPClosure = false
    private let coreQueue = DispatchQueue(label: "org.tagentra.pm3.core")
    private let logQueue = DispatchQueue(label: "org.tagentra.pm3.diagnostics")
    private var logs: [String] = []
    private(set) var mode: DeviceMode = .unknown
    private var connected = false
    private var coreReady = false
    private var switching = false
    private var switchTarget: DeviceMode?
    private var switchID: UUID?

    var status: [String: Any] {
        [
            "bluetooth": central.state.description,
            "connected": connected,
            "deviceId": peripheral?.identifier.uuidString ?? NSNull(),
            "mode": mode.rawValue,
            "tcpReady": tcp != nil,
            "coreReady": coreReady,
            "switching": switching,
        ]
    }

    func startScan(timeoutMs: Int) {
        guard central.state == .poweredOn else { record("scan deferred: bluetooth \(central.state.description)"); return }
        discovered.removeAll()
        central.scanForPeripherals(withServices: [Self.uartService], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        event("state", ["value": "scanning"])
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(max(1000, timeoutMs))) { [weak self] in self?.stopScan() }
    }
    func stopScan() { central.stopScan(); event("state", ["value": "scanStopped"]) }

    func connect(id: String, completion: @escaping FlutterResult) {
        guard let uuid = UUID(uuidString: id), let target = discovered[uuid] else { completion(FlutterError(code: "notFound", message: "Scan result expired", details: nil)); return }
        disconnect(reason: "replace")
        connectCompletion = completion
        peripheral = target
        lastDeviceID = uuid
        discoveredMode = Self.modeHint(for: target.name)
        target.delegate = self
        central.connect(target)
        record("connecting device=\(redact(id))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self, weak target] in
            guard let self, self.connectCompletion != nil, self.peripheral?.identifier == target?.identifier else { return }
            self.failConnection("BLE connection timed out")
        }
    }

    func reconnect(completion: @escaping FlutterResult) {
        guard let id = lastDeviceID, let target = central.retrievePeripherals(withIdentifiers: [id]).first else {
            completion(FlutterError(code: "notFound", message: "No previous device is available", details: nil)); return
        }
        discovered[id] = target
        connect(id: id.uuidString, completion: completion)
    }

    func disconnect(reason: String) {
        let pendingConnect = connectCompletion
        let pendingSwitch = switchCompletion
        let pendingPM3Start = pm3StartCompletion
        connectCompletion = nil
        switchCompletion = nil
        pm3StartCompletion = nil
        modeProbeID = nil
        pm3StartID = nil
        switching = false
        switchTarget = nil
        switchID = nil
        preserveBLEOnTCPClosure = false
        pendingConnect?(FlutterError(code: "cancelled", message: "Connection cancelled: \(reason)", details: nil))
        pendingSwitch?(FlutterError(code: "cancelled", message: "Mode switch cancelled: \(reason)", details: nil))
        pendingPM3Start?(FlutterError(code: "cancelled", message: "PM3 startup cancelled: \(reason)", details: nil))
        cancel()
        tcpGeneration = UUID()
        tcp?.cancel(); tcp = nil
        listener?.cancel(); listener = nil
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        connected = false; coreReady = false; rx = nil; tx = nil; mode = .unknown
        pendingWrites.removeAll(); pendingWriteDrainCallbacks.removeAll()
        #if canImport(TagentraPM3Core)
        coreQueue.async {
            tagentra_pm3_set_output_callback(nil, nil)
            tagentra_pm3_shutdown()
        }
        #endif
        record("disconnected reason=\(reason)")
        event("connection", ["state": "disconnected", "reason": reason])
    }

    func switchToPM3(completion: @escaping FlutterResult) {
        guard connected, mode == .chameleon || mode == .unknown else { completion(FlutterError(code: "mode", message: "Connected device is already in PM3 mode", details: nil)); return }
        guard !switching else { completion(FlutterError(code: "busy", message: "A mode switch is already running", details: nil)); return }
        let operationID = UUID()
        switching = true
        switchTarget = .pm3
        switchID = operationID
        switchCompletion = completion
        event("connection", ["state": "switching", "mode": mode.rawValue, "targetMode": DeviceMode.pm3.rawValue])
        enqueue(Data("REBOOTPM3\r\n".utf8)) { [weak self] in
            guard let self, self.switchID == operationID else { return }
            self.record("mode command REBOOTPM3 sent")
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
                guard let self, self.switchID == operationID else { return }
                self.mode = .unknown
                self.startPM3 { [weak self] error in
                    guard let self, self.switchID == operationID else { return }
                    if let error {
                        self.finishSwitchFailure(error, fallbackMode: .unknown)
                    } else {
                        self.finishSwitchSuccess(.pm3)
                    }
                }
            }
        }
        scheduleSwitchTimeout(operationID, target: .pm3)
    }

    func switchToChameleon(completion: @escaping FlutterResult) {
        guard connected, mode == .pm3, coreReady else { completion(FlutterError(code: "notReady", message: "PM3 transport is not ready", details: nil)); return }
        guard !switching else { completion(FlutterError(code: "busy", message: "A mode switch is already running", details: nil)); return }
        let operationID = UUID()
        switching = true
        switchTarget = .chameleon
        switchID = operationID
        switchCompletion = completion
        preserveBLEOnTCPClosure = true
        event("connection", ["state": "switching", "mode": mode.rawValue, "targetMode": DeviceMode.chameleon.rawValue])
        record("mode command hw reset requested")
        coreQueue.async { [weak self] in
            guard let self else { return }
            #if canImport(TagentraPM3Core)
            let code = "hw reset".withCString { tagentra_pm3_execute($0) }
            #else
            let code: Int32 = -3
            #endif
            DispatchQueue.main.async {
                guard self.switchID == operationID else { return }
                guard code == 0 else {
                    self.preserveBLEOnTCPClosure = false
                    self.finishSwitchFailure(
                        FlutterError(code: "modeSwitch", message: "PM3 rejected hw reset: \(code)", details: nil),
                        fallbackMode: .pm3
                    )
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
                    guard let self, self.switchID == operationID else { return }
                    self.stopPM3 { [weak self] in
                        guard let self, self.switchID == operationID else { return }
                        self.finishSwitchSuccess(.chameleon)
                    }
                }
            }
        }
        scheduleSwitchTimeout(operationID, target: .chameleon)
    }

    private func scheduleSwitchTimeout(_ operationID: UUID, target: DeviceMode) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, self.switchID == operationID else { return }
            let error = FlutterError(code: "modeSwitchTimeout", message: "Timed out switching to \(target.rawValue)", details: nil)
            if target == .pm3, let startID = self.pm3StartID {
                self.failPM3Start(startID, error.message ?? "PM3 startup timed out")
                return
            }
            self.cancel()
            self.finishSwitchFailure(error, fallbackMode: target == .pm3 ? .unknown : .pm3)
        }
    }

    func execute(_ command: String, completion: @escaping FlutterResult) {
        guard connected, mode == .pm3, coreReady, !switching else { completion(FlutterError(code: "notReady", message: "PM3 transport is not ready", details: nil)); return }
        coreQueue.async {
            #if canImport(TagentraPM3Core)
            let before: [String: ArtifactSnapshot]
            do { before = try self.artifactSnapshot() } catch {
                DispatchQueue.main.async { completion(FlutterError(code: "storage", message: error.localizedDescription, details: nil)) }
                return
            }
            let code = command.withCString { tagentra_pm3_execute($0) }
            do {
                let after = try self.artifactSnapshot()
                let changed = after.keys.filter { before[$0] != after[$0] }.sorted()
                let artifacts = changed.compactMap { relative in after[relative].map { self.artifactMap(relative: relative, snapshot: $0) } }
                let revision = String(cString: tagentra_pm3_upstream_revision())
                DispatchQueue.main.async { completion(["exitCode": Int(code), "rrgRevision": revision, "artifacts": artifacts]) }
            } catch {
                DispatchQueue.main.async { completion(FlutterError(code: "storage", message: error.localizedDescription, details: nil)) }
            }
            #else
            DispatchQueue.main.async { completion(FlutterError(code: "coreMissing", message: "TagentraPM3Core binary is not linked", details: nil)) }
            #endif
        }
    }

    func listArtifacts() throws -> [[String: Any]] {
        let snapshot = try artifactSnapshot()
        return snapshot.keys.sorted().compactMap { relative in
            snapshot[relative].map { artifactMap(relative: relative, snapshot: $0) }
        }
    }

    private func pm3StorageDirectory() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("Tagentra", isDirectory: true).appendingPathComponent("PM3", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func artifactSnapshot() throws -> [String: ArtifactSnapshot] {
        let root = try pm3StorageDirectory()
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [],
            errorHandler: { _, _ in false }
        ) else { return [:] }
        var snapshot: [String: ArtifactSnapshot] = [:]
        for case let url as URL in enumerator {
            let depth = enumerator.level
            guard depth > 0, depth <= url.pathComponents.count else { continue }
            // The enumerator may canonicalize /var to /private/var on iOS.
            let relative = url.pathComponents.suffix(depth).joined(separator: "/")
            if relative == ".proxmark3" || relative.hasPrefix(".proxmark3/") {
                enumerator.skipDescendants()
                continue
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true else { continue }
            snapshot[relative] = ArtifactSnapshot(size: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate ?? .distantPast)
        }
        return snapshot
    }

    private func artifactMap(relative: String, snapshot: ArtifactSnapshot) -> [String: Any] {
        let milliseconds = Int64(snapshot.modifiedAt.timeIntervalSince1970 * 1000)
        let path = (try? pm3StorageDirectory().appendingPathComponent(relative).path) ?? relative
        return [
            "id": "\(relative)|\(snapshot.size)|\(milliseconds)",
            "path": path,
            "name": URL(fileURLWithPath: relative).lastPathComponent,
            "size": snapshot.size,
            "modifiedAt": ISO8601DateFormatter().string(from: snapshot.modifiedAt),
        ]
    }

    func cancel() {
        #if canImport(TagentraPM3Core)
        tagentra_pm3_cancel()
        #endif
        record("cancel requested")
    }

    private func beginModeDetection() {
        let probeID = UUID()
        modeProbeID = probeID
        modeProbeBuffer.removeAll(keepingCapacity: true)
        mode = .unknown
        event("connection", ["state": "detecting", "mode": mode.rawValue])
        enqueue(Data("VERSION?\r\n".utf8))
        record("mode probe VERSION? sent")
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(800)) { [weak self] in
            self?.finishModeDetection(probeID, detectedMode: .unknown)
        }
    }

    private func finishModeDetection(_ probeID: UUID, detectedMode: DeviceMode) {
        guard modeProbeID == probeID else { return }
        modeProbeID = nil
        let resolvedMode = detectedMode == .unknown ? discoveredMode : detectedMode
        mode = resolvedMode
        record("mode detected=\(resolvedMode.rawValue)")
        if resolvedMode == .pm3 {
            startPM3 { [weak self] error in
                guard let self else { return }
                if let error {
                    self.connectCompletion?(error)
                    self.connectCompletion = nil
                    self.event("connection", ["state": "error", "mode": DeviceMode.pm3.rawValue, "message": error.message ?? "PM3 startup failed"])
                } else {
                    self.finishInitialConnection(.pm3)
                }
            }
        } else {
            finishInitialConnection(resolvedMode)
        }
    }

    private func finishInitialConnection(_ detectedMode: DeviceMode) {
        mode = detectedMode
        connectCompletion?(nil)
        connectCompletion = nil
        event("connection", ["state": "ready", "mode": mode.rawValue])
    }

    private func classifyModeProbe() -> DeviceMode {
        let response = String(decoding: modeProbeBuffer, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = response.lowercased()
        if response.contains("101") || lowercased.contains("chameleon") { return .chameleon }
        if response.uppercased().hasPrefix("PM3") || lowercased.contains("proxmark3") { return .pm3 }
        return .unknown
    }

    func exportDiagnostics() throws -> URL {
        let header = "Tagentra diagnostics\nGenerated: \(ISO8601DateFormatter().string(from: Date()))\n"
        let body = logQueue.sync { logs.joined(separator: "\n") }
            .replacingOccurrences(of: #"(?i)\b[0-9a-f]{12,}\b"#, with: "<redacted-hex>", options: .regularExpression)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tagentra-diagnostics-\(UUID().uuidString).txt")
        try (header + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func startPM3(completion: @escaping (FlutterError?) -> Void) {
        #if canImport(TagentraPM3Core)
        guard pm3StartID == nil else {
            completion(FlutterError(code: "busy", message: "PM3 startup is already running", details: nil))
            return
        }
        let startID = UUID()
        let generation = UUID()
        pm3StartID = startID
        pm3StartCompletion = completion
        tcpGeneration = generation
        coreReady = false
        event("connection", ["state": "initializing", "mode": DeviceMode.pm3.rawValue])
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection, generation: generation) }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, self.pm3StartID == startID else { return }
                if case let .failed(error) = state {
                    self.failPM3Start(startID, "TCP listener failed: \(error.localizedDescription)")
                    return
                }
                guard case .ready = state, let port = listener.port else { return }
                self.record("tcp listener ready port=\(port.rawValue)")
                self.initializeCore(port: port.rawValue, startID: startID)
            }
            listener.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, self.pm3StartID == startID else { return }
                self.failPM3Start(startID, "PM3 transport initialization timed out")
            }
        } catch {
            failPM3Start(startID, "TCP listener: \(error.localizedDescription)")
        }
        #else
        completion(FlutterError(code: "coreMissing", message: "TagentraPM3Core binary is not linked", details: nil))
        #endif
    }

    private func accept(_ connection: NWConnection, generation: UUID) {
        guard tcpGeneration == generation else { connection.cancel(); return }
        guard tcp == nil else { connection.cancel(); return }
        tcp = connection
        connection.stateUpdateHandler = { [weak self] state in self?.record("tcp state \(state)") }
        connection.start(queue: .main)
        receiveTCP(connection, generation: generation)
    }

    private func receiveTCP(_ connection: NWConnection, generation: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            if let data, !data.isEmpty { self?.enqueue(data) }
            if complete || error != nil {
                guard let self else { return }
                self.record("tcp receive closed error=\(error?.localizedDescription ?? "none")")
                if self.connected, self.tcpGeneration == generation, !self.preserveBLEOnTCPClosure {
                    self.disconnect(reason: "tcpClosed")
                }
            } else {
                self?.receiveTCP(connection, generation: generation)
            }
        }
    }

    private func initializeCore(port: UInt16, startID: UUID) {
        #if canImport(TagentraPM3Core)
        guard let resource = Bundle.allFrameworks.compactMap({ $0.resourceURL?.appendingPathComponent("pm3") }).first(where: { FileManager.default.fileExists(atPath: $0.path) })?.path else { failPM3Start(startID, "PM3 resources are missing"); return }
        coreQueue.async { [weak self] in
            guard let self else { return }
            let storage: String
            do {
                storage = try self.preparePM3WorkingDirectory()
            } catch {
                DispatchQueue.main.async { self.failPM3Start(startID, "PM3 writable directory failed: \(error.localizedDescription)") }
                return
            }
            guard tagentra_pm3_abi_major() == 2, tagentra_pm3_abi_minor() >= 1 else { DispatchQueue.main.async { self.failPM3Start(startID, "PM3 Core ABI 2.1 or newer is required") }; return }
            let resourceCode = resource.withCString { tagentra_pm3_set_resource_root($0) }
            let storageCode = storage.withCString { tagentra_pm3_set_storage_root($0) }
            guard resourceCode == 0, storageCode == 0 else { DispatchQueue.main.async { self.failPM3Start(startID, "PM3 Core storage configuration failed") }; return }
            tagentra_pm3_set_output_callback(tagentraPM3CoreOutputCallback, Unmanaged.passUnretained(self).toOpaque())
            let endpoint = "tcp:127.0.0.1:\(port)"
            let code = endpoint.withCString { tagentra_pm3_initialize_endpoint($0) }
            DispatchQueue.main.async {
                guard self.pm3StartID == startID else {
                    self.coreQueue.async { tagentra_pm3_set_output_callback(nil, nil); tagentra_pm3_shutdown() }
                    return
                }
                guard code == 0 else { self.failPM3Start(startID, "PM3 Core initialization failed: \(code)"); return }
                self.finishPM3Start(startID)
            }
        }
        #endif
    }

    private func preparePM3WorkingDirectory() throws -> String {
        let directory = try pm3StorageDirectory()
        guard FileManager.default.changeCurrentDirectoryPath(directory.path) else {
            throw NSError(
                domain: "org.tagentra.pm3",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unable to use the PM3 application support directory"]
            )
        }
        return directory.path
    }

    private func finishPM3Start(_ startID: UUID) {
        guard pm3StartID == startID else { return }
        let completion = pm3StartCompletion
        pm3StartID = nil
        pm3StartCompletion = nil
        coreReady = true
        completion?(nil)
    }

    private func failPM3Start(_ startID: UUID, _ message: String) {
        guard pm3StartID == startID else { return }
        record("error \(message)")
        let completion = pm3StartCompletion
        pm3StartID = nil
        pm3StartCompletion = nil
        stopPM3 { completion?(FlutterError(code: "connection", message: message, details: nil)) }
    }

    private func stopPM3(completion: (() -> Void)? = nil) {
        pm3StartID = nil
        pm3StartCompletion = nil
        tcpGeneration = UUID()
        tcp?.cancel(); tcp = nil
        listener?.cancel(); listener = nil
        coreReady = false
        #if canImport(TagentraPM3Core)
        coreQueue.async {
            tagentra_pm3_set_output_callback(nil, nil)
            tagentra_pm3_shutdown()
            DispatchQueue.main.async { completion?() }
        }
        #else
        completion?()
        #endif
    }

    private func finishSwitchSuccess(_ newMode: DeviceMode) {
        mode = newMode
        switching = false
        switchTarget = nil
        switchID = nil
        preserveBLEOnTCPClosure = false
        let completion = switchCompletion
        switchCompletion = nil
        event("connection", ["state": "ready", "mode": newMode.rawValue])
        completion?(nil)
    }

    private func finishSwitchFailure(_ error: FlutterError, fallbackMode: DeviceMode) {
        mode = fallbackMode
        switching = false
        switchTarget = nil
        switchID = nil
        preserveBLEOnTCPClosure = false
        let completion = switchCompletion
        switchCompletion = nil
        event("connection", ["state": "ready", "mode": fallbackMode.rawValue, "message": error.message ?? "Mode switch failed"])
        completion?(error)
    }

    private func enqueue(_ data: Data, onDrained: (() -> Void)? = nil) {
        guard let peripheral, rx != nil else {
            onDrained?()
            return
        }
        let size = max(1, peripheral.maximumWriteValueLength(for: .withoutResponse))
        var offset = 0
        while offset < data.count {
            let end = min(offset + size, data.count)
            pendingWrites.append(data.subdata(in: offset..<end)); offset = end
        }
        if let onDrained { pendingWriteDrainCallbacks.append(onDrained) }
        flushWrites()
    }

    private func flushWrites() {
        guard let peripheral, let rx else { return }
        while peripheral.canSendWriteWithoutResponse, !pendingWrites.isEmpty {
            peripheral.writeValue(pendingWrites.removeFirst(), for: rx, type: .withoutResponse)
        }
        if pendingWrites.isEmpty, !pendingWriteDrainCallbacks.isEmpty {
            let callbacks = pendingWriteDrainCallbacks
            pendingWriteDrainCallbacks.removeAll()
            callbacks.forEach { $0() }
        }
    }

    private func event(_ type: String, _ values: [String: Any]) { emit?(["type": type].merging(values) { _, new in new }) }
    func handleCoreOutput(_ data: Data) {
        let message = String(decoding: data, as: UTF8.self)
        record("pm3 \(message.trimmingCharacters(in: .newlines))")
        event("output", ["text": message])
    }
    private func record(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)"
        logQueue.async { self.logs.append(line); if self.logs.count > 5000 { self.logs.removeFirst(1000) } }
        event("log", ["message": message])
    }
    private func redact(_ value: String) -> String { String(value.reversed().prefix(8)) }
    private func failConnection(_ message: String) { record("error \(message)"); connectCompletion?(FlutterError(code: "connection", message: message, details: nil)); connectCompletion = nil; disconnect(reason: "error") }
    private static func modeHint(for name: String?) -> DeviceMode {
        let value = name?.lowercased() ?? ""
        if value.contains("chameleon") { return .chameleon }
        if value.contains("pm3") || value.contains("proxmark") { return .pm3 }
        return .unknown
    }
}

extension PM3Transport: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) { record("bluetooth \(central.state.description)"); if central.state != .poweredOn { disconnect(reason: "bluetoothUnavailable") } }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        discovered[peripheral.identifier] = peripheral
        event("device", ["id": peripheral.identifier.uuidString, "name": peripheral.name ?? "PM3 SE Hub Mini", "rssi": RSSI.intValue, "modeHint": Self.modeHint(for: peripheral.name).rawValue])
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) { record("ble connected"); peripheral.discoverServices([Self.uartService]) }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) { failConnection(error?.localizedDescription ?? "BLE connection failed") }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if connected || connectCompletion != nil { disconnect(reason: error?.localizedDescription ?? "linkLost") }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.uartService }) else { failConnection(error?.localizedDescription ?? "Nordic UART service missing"); return }
        peripheral.discoverCharacteristics([Self.uartRX, Self.uartTX], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else { failConnection(error!.localizedDescription); return }
        for characteristic in service.characteristics ?? [] {
            record("characteristic \(characteristic.uuid.uuidString) properties=\(characteristic.properties.rawValue)")
            if characteristic.uuid == Self.uartRX && characteristic.properties.contains(.writeWithoutResponse) { rx = characteristic }
            if characteristic.uuid == Self.uartTX && characteristic.properties.contains(.notify) { tx = characteristic }
        }
        guard rx != nil, let tx else { failConnection("Required UART characteristics/properties missing"); return }
        peripheral.setNotifyValue(true, for: tx)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.isNotifying else { failConnection(error?.localizedDescription ?? "UART notifications unavailable"); return }
        connected = true
        beginModeDetection()
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value, !data.isEmpty else { return }
        if let probeID = modeProbeID {
            modeProbeBuffer.append(data)
            let detectedMode = classifyModeProbe()
            if detectedMode != .unknown { finishModeDetection(probeID, detectedMode: detectedMode) }
            return
        }
        tcp?.send(content: data, completion: .contentProcessed { [weak self] error in if let error { self?.record("tcp send error \(error)") } })
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) { flushWrites() }
}

private extension CBManagerState {
    var description: String { switch self { case .unknown: "unknown"; case .resetting: "resetting"; case .unsupported: "unsupported"; case .unauthorized: "unauthorized"; case .poweredOff: "poweredOff"; case .poweredOn: "poweredOn"; @unknown default: "future" } }
}
