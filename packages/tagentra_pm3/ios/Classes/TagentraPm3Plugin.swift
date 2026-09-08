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
        case "switchToChameleon": fail(result, "unsupported", "PM3 to Chameleon command awaits hardware confirmation")
        case "execute":
            guard let command = args?["command"] as? String, !command.isEmpty else { return fail(result, "argument", "Command is empty") }
            transport.execute(command, completion: result)
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
    @objc private func backgrounded() { transport.cancel(); transport.disconnect(reason: "background") }
}

private enum DeviceMode: String { case unknown, pm3, chameleon }

#if canImport(TagentraPM3Core)
private func receiveCoreOutput(_ utf8: UnsafePointer<CChar>?, _ length: Int, _ context: UnsafeMutableRawPointer?) {
    guard let utf8, let context, length > 0 else { return }
    let owner = Unmanaged<PM3Transport>.fromOpaque(context).takeUnretainedValue()
    owner.receiveCoreOutput(Data(bytes: utf8, count: length))
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
    private var connectCompletion: FlutterResult?
    private var lastDeviceID: UUID?
    private var discoveredMode: DeviceMode = .unknown
    private let coreQueue = DispatchQueue(label: "org.tagentra.pm3.core")
    private let logQueue = DispatchQueue(label: "org.tagentra.pm3.diagnostics")
    private var logs: [String] = []
    private(set) var mode: DeviceMode = .unknown
    private var connected = false

    var status: [String: Any] { ["bluetooth": central.state.description, "connected": connected, "deviceId": peripheral?.identifier.uuidString ?? NSNull(), "mode": mode.rawValue, "tcpReady": tcp != nil] }

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
        connectCompletion?(FlutterError(code: "cancelled", message: "Connection cancelled: \(reason)", details: nil))
        connectCompletion = nil
        cancel()
        tcp?.cancel(); tcp = nil
        listener?.cancel(); listener = nil
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        connected = false; rx = nil; tx = nil; mode = .unknown; pendingWrites.removeAll()
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
        guard connected, mode == .chameleon else { completion(FlutterError(code: "mode", message: "Connected device is not in Chameleon mode", details: nil)); return }
        enqueue(Data("REBOOTPM3\r\n".utf8))
        record("mode command REBOOTPM3 sent")
        completion(nil)
    }

    func execute(_ command: String, completion: @escaping FlutterResult) {
        guard connected, mode == .pm3 else { completion(FlutterError(code: "notReady", message: "PM3 transport is not ready", details: nil)); return }
        coreQueue.async {
            #if canImport(TagentraPM3Core)
            let code = command.withCString { tagentra_pm3_execute($0) }
            DispatchQueue.main.async { completion(Int(code)) }
            #else
            DispatchQueue.main.async { completion(FlutterError(code: "coreMissing", message: "TagentraPM3Core binary is not linked", details: nil)) }
            #endif
        }
    }

    func cancel() {
        #if canImport(TagentraPM3Core)
        tagentra_pm3_cancel()
        #endif
        record("cancel requested")
    }

    func exportDiagnostics() throws -> URL {
        let header = "Tagentra diagnostics\nGenerated: \(ISO8601DateFormatter().string(from: Date()))\n"
        let body = logQueue.sync { logs.joined(separator: "\n") }
            .replacingOccurrences(of: #"(?i)\b[0-9a-f]{12,}\b"#, with: "<redacted-hex>", options: .regularExpression)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tagentra-diagnostics-\(UUID().uuidString).txt")
        try (header + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func startTCP() {
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                guard case .ready = state, let port = listener.port else { return }
                self?.record("tcp listener ready port=\(port.rawValue)")
                self?.initializeCore(port: port.rawValue)
            }
            listener.start(queue: .main)
        } catch { failConnection("TCP listener: \(error.localizedDescription)") }
    }

    private func accept(_ connection: NWConnection) {
        guard tcp == nil else { connection.cancel(); return }
        tcp = connection
        connection.stateUpdateHandler = { [weak self] state in self?.record("tcp state \(state)") }
        connection.start(queue: .main)
        receiveTCP(connection)
    }

    private func receiveTCP(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            if let data, !data.isEmpty { self?.enqueue(data) }
            if complete || error != nil {
                if self?.connected == true { self?.disconnect(reason: "tcpClosed") }
            } else { self?.receiveTCP(connection) }
        }
    }

    private func initializeCore(port: UInt16) {
        #if canImport(TagentraPM3Core)
        guard let resource = Bundle.allFrameworks.compactMap({ $0.resourceURL?.appendingPathComponent("pm3") }).first(where: { FileManager.default.fileExists(atPath: $0.path) })?.path else { failConnection("PM3 resources are missing"); return }
        coreQueue.async { [weak self] in
            guard let self else { return }
            guard tagentra_pm3_abi_major() == 2 else { DispatchQueue.main.async { self.failConnection("PM3 Core ABI major mismatch") }; return }
            _ = resource.withCString { tagentra_pm3_set_resource_root($0) }
            tagentra_pm3_set_output_callback(receiveCoreOutput, Unmanaged.passUnretained(self).toOpaque())
            let endpoint = "tcp:127.0.0.1:\(port)"
            let code = endpoint.withCString { tagentra_pm3_initialize_endpoint($0) }
            DispatchQueue.main.async {
                guard code == 0 else { self.failConnection("PM3 Core initialization failed: \(code)"); return }
                guard self.listener != nil else {
                    self.coreQueue.async { tagentra_pm3_set_output_callback(nil, nil); tagentra_pm3_shutdown() }
                    return
                }
                self.finishPM3Connection()
            }
        }
        #else
        finishPM3Connection()
        #endif
    }

    private func finishPM3Connection() {
        connected = true; mode = .pm3
        connectCompletion?(nil); connectCompletion = nil
        event("connection", ["state": "ready", "mode": mode.rawValue])
    }

    private func enqueue(_ data: Data) {
        guard let peripheral, let rx else { return }
        let size = max(1, peripheral.maximumWriteValueLength(for: .withoutResponse))
        var offset = 0
        while offset < data.count {
            let end = min(offset + size, data.count)
            pendingWrites.append(data.subdata(in: offset..<end)); offset = end
        }
        flushWrites()
    }

    private func flushWrites() {
        guard let peripheral, let rx else { return }
        while peripheral.canSendWriteWithoutResponse, !pendingWrites.isEmpty {
            peripheral.writeValue(pendingWrites.removeFirst(), for: rx, type: .withoutResponse)
        }
    }

    private func event(_ type: String, _ values: [String: Any]) { emit?(["type": type].merging(values) { _, new in new }) }
    func receiveCoreOutput(_ data: Data) {
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
        if value.contains("pm3") || value.contains("proxmark") || value.contains("hub") { return .pm3 }
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
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) { if connected { disconnect(reason: error?.localizedDescription ?? "linkLost") } }
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
        if discoveredMode == .chameleon {
            connected = true; mode = .chameleon
            connectCompletion?(nil); connectCompletion = nil
            event("connection", ["state": "ready", "mode": mode.rawValue])
        } else {
            startTCP()
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value, !data.isEmpty else { return }
        tcp?.send(content: data, completion: .contentProcessed { [weak self] error in if let error { self?.record("tcp send error \(error)") } })
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) { flushWrites() }
}

private extension CBManagerState {
    var description: String { switch self { case .unknown: "unknown"; case .resetting: "resetting"; case .unsupported: "unsupported"; case .unauthorized: "unauthorized"; case .poweredOff: "poweredOff"; case .poweredOn: "poweredOn"; @unknown default: "future" } }
}
