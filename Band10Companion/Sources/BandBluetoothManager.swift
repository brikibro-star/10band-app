import Foundation
import Combine
import CoreBluetooth
import Security

struct BandDevice: Identifiable {
    let id: UUID
    let name: String
    let rssi: Int
}

@MainActor
final class BandBluetoothManager: NSObject, ObservableObject {
    @Published private(set) var devices: [BandDevice] = []
    @Published private(set) var gattDetails: [String] = []
    @Published private(set) var status = "Проверка Bluetooth…"
    @Published private(set) var isScanning = false
    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published private(set) var activePeripheralID: UUID?
    @Published private(set) var isAuthenticated = false
    @Published private(set) var batteryLevel: Int?
    @Published private(set) var logEntries: [String] = []

    private let bandService = CBUUID(string: "FE95")
    private let notifyUUID = CBUUID(string: "005E")
    private let writeUUID = CBUUID(string: "005F")
    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var connectedPeripheral: CBPeripheral?
    private var notifyCharacteristic: CBCharacteristic?
    private var writeCharacteristic: CBCharacteristic?
    private var receiveBuffer: [UInt8] = []
    private var writeQueue: [Data] = []
    private var sequence: UInt8 = 0
    private var phoneNonce = Data()
    private var sessionKeys: MiAuth.SessionKeys?
    private var candidateKeys: [Data] = []
    private var keyIndex = 0
    private var connectionTimeout: DispatchWorkItem?
    private var connectionTimedOut = false
    private var awaitingConnectionCallback = false
    private var latestRSSI: [UUID: (value: Int, date: Date)] = [:]
    private var lastDisconnectDate: Date?
    private var gattPendingServices: Set<CBUUID> = []

    private func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        logEntries.append("[\(stamp)] \(message)")
        if logEntries.count > 1500 { logEntries.removeFirst(logEntries.count - 1500) }
    }

    var diagnosticReport: String {
        let peripheralState = connectedPeripheral.map { String($0.state.rawValue) } ?? "нет"
        let activeID = activePeripheralID?.uuidString ?? "нет"
        let header = """
        Band 10 Companion BLE diagnostic report
        Device: iPhone / iOS
        Central state: \(stateDescription)
        Status: \(status)
        Connected: \(isConnected)
        Connecting: \(isConnecting)
        Peripheral state: \(peripheralState) (0=disconnected, 1=connecting, 2=connected, 3=disconnecting)
        Active peripheral: \(activeID)
        Authenticated: \(isAuthenticated)
        Auth Key available: \(!Vault.importedBandKeys.isEmpty)
        GATT characteristics: \(gattDetails.count)

        """
        return header + gattDetails.joined(separator: "\n") + (gattDetails.isEmpty ? "" : "\n\n") + logEntries.joined(separator: "\n")
    }

    func exportLog() -> URL? {
        let content = diagnosticReport
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Band10-BLE-Report-\\(Int(Date().timeIntervalSince1970)).txt")
        do { try content.write(to: url, atomically: true, encoding: .utf8); return url }
        catch { log("LOG EXPORT ERROR: \\(error.localizedDescription)"); return nil }
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func startScan() {
        log("SCAN requested; central state=\(central.state.rawValue) (\(stateDescription))")
        guard central.state == .poweredOn else {
            status = "Bluetooth недоступен: \(stateDescription)"
            return
        }
        devices.removeAll()
        peripherals = central.retrieveConnectedPeripherals(withServices: [bandService])
            .reduce(into: [:]) { $0[$1.identifier] = $1 }
        gattDetails.removeAll()
        isScanning = true
        status = "Поиск Xiaomi Smart Band 10…"
        log("SCAN started; service filter=none; mode=full BLE discovery")
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func stopScan() {
        central.stopScan()
        isScanning = false
        if central.state == .poweredOn { status = "Поиск остановлен" }
    }

    func disconnect() {
        guard let peripheral = connectedPeripheral else { return }
        status = "Отключение от браслета…"
        central.cancelPeripheralConnection(peripheral)
    }

    func clearResults() {
        devices.removeAll()
        gattDetails.removeAll()
    }

    func connect(to id: UUID) {
        guard let peripheral = peripherals[id] else { return }
        guard peripheral.state != .connected, !isConnecting, !awaitingConnectionCallback else {
            log("CONNECT blocked; id=\(id.uuidString); peripheralState=\(peripheral.state.rawValue); isConnecting=\(isConnecting); awaitingCallback=\(awaitingConnectionCallback)")
            return
        }
        if let lastDisconnectDate, Date().timeIntervalSince(lastDisconnectDate) < 4 {
            let remaining = max(1, Int(4 - Date().timeIntervalSince(lastDisconnectDate)))
            status = "Подождите \(remaining) сек. перед повторным подключением."
            log("CONNECT blocked by 4s cooldown; remaining=\(remaining)s")
            return
        }
        candidateKeys = Vault.importedBandKeys.compactMap { hex in
            guard hex.count == 32 else { return nil }
            return BandKey(hex: hex).data
        }
        stopScan()
        if let current = connectedPeripheral, current.identifier != id {
            central.cancelPeripheralConnection(current)
        }
        resetSession()
        connectionTimeout?.cancel()
        connectionTimedOut = false
        connectedPeripheral = peripheral
        activePeripheralID = id
        isConnecting = true
        isConnected = false
        awaitingConnectionCallback = true
        status = "Подключение к Xiaomi Smart Band 10…"
        let signal = latestRSSI[id]
        let signalText = signal.map { "\($0.value) dBm at \(ISO8601DateFormatter().string(from: $0.date))" } ?? "unavailable"
        log("CONNECT API call; id=\(peripheral.identifier.uuidString); name=\(peripheral.name ?? "nil"); peripheralStateBefore=\(peripheral.state.rawValue); centralState=\(central.state.rawValue); latestRSSI=\(signalText); authKeyAvailable=\(!candidateKeys.isEmpty); awaitingCallback=\(awaitingConnectionCallback)")
        central.connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                                               CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])

        let timeout = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self, let peripheral,
                  self.connectedPeripheral?.identifier == peripheral.identifier,
                  !self.isConnected else { return }
            self.log("CONNECT TIMEOUT after 90s; peripheral id=\(peripheral.identifier.uuidString); peripheralState=\(peripheral.state.rawValue); centralState=\(self.central.state.rawValue)")
            self.connectionTimedOut = true
            self.status = "Ожидание браслета: возможно, он занят Mi Fitness. Закройте Mi Fitness и подождите подключения."
            self.log("CANCEL requested by app timeout; stateBeforeCancel=\(peripheral.state.rawValue); awaiting callback remains true")
            self.central.cancelPeripheralConnection(peripheral)
        }
        connectionTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: timeout)
    }

    private var stateDescription: String {
        switch central.state {
        case .poweredOn: return "включён"
        case .poweredOff: return "выключен"
        case .unauthorized: return "нет разрешения"
        case .unsupported: return "не поддерживается"
        case .resetting: return "перезапускается"
        case .unknown: return "неизвестное состояние"
        @unknown default: return "неизвестное состояние"
        }
    }

    private func resetSession() {
        isAuthenticated = false
        batteryLevel = nil
        notifyCharacteristic = nil
        writeCharacteristic = nil
        receiveBuffer.removeAll()
        writeQueue.removeAll()
        sequence = 0
        phoneNonce = Data()
        sessionKeys = nil
        keyIndex = 0
    }

    private func startSession() {
        log("PROTOCOL session start; notify=\(notifyCharacteristic?.uuid.uuidString ?? "nil"); write=\(writeCharacteristic?.uuid.uuidString ?? "nil")")
        status = "BLE-канал открыт. Запуск протокола…"
        sendFrame(MiFrame.encode(kind: MiFrame.kindSessionConfig, seq: 0,
                                 payload: MiFrame.startSessionPayload))
    }

    private func startAuthentication() {
        guard !candidateKeys.isEmpty else {
            status = "Bluetooth подключён. Для авторизации добавьте Auth Key во вкладке «Ключ»."
            log("AUTH skipped; no Auth Key stored")
            return
        }
        var nonce = Data(count: 16)
        let result = nonce.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
        }
        guard result == errSecSuccess else {
            status = "Не удалось создать случайный ключ сеанса."
            return
        }
        phoneNonce = nonce
        log("AUTH started; candidate key count=\(candidateKeys.count); key bytes not logged")
        status = "Проверка ключа браслета…"
        sendCommand(MiAuth.nonceCommand(phoneNonce: nonce), encrypted: false)
    }

    private func sendCommand(_ protobuf: Data, encrypted: Bool) {
        var body = protobuf
        if encrypted, let sessionKeys {
            body = MiCrypto.ctr(key: sessionKeys.encryptionKey, protobuf)
        }
        let payload = Data([0x01, encrypted ? 0x02 : 0x01]) + body
        let frame = MiFrame.encode(kind: MiFrame.kindData, seq: sequence, payload: payload)
        sequence &+= 1
        sendFrame(frame)
    }

    private func sendFrame(_ frame: Data) {
        guard let peripheral = connectedPeripheral, let characteristic = writeCharacteristic else { return }
        let mtu = max(20, peripheral.maximumWriteValueLength(for: .withoutResponse))
        var offset = 0
        while offset < frame.count {
            let end = min(offset + mtu, frame.count)
            writeQueue.append(frame.subdata(in: offset..<end))
            offset = end
        }
        pumpWrites()
    }

    private func pumpWrites() {
        guard let peripheral = connectedPeripheral, let characteristic = writeCharacteristic else { return }
        while !writeQueue.isEmpty && peripheral.canSendWriteWithoutResponse {
            let data = writeQueue.removeFirst()
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
        }
    }

    private func receive(_ chunk: Data) {
        receiveBuffer.append(contentsOf: chunk)
        for packet in MiFrame.drain(&receiveBuffer) {
            switch packet.kind {
            case MiFrame.kindSessionConfig:
                if phoneNonce.isEmpty { startAuthentication() }
            case MiFrame.kindData:
                sendFrame(MiFrame.encode(kind: MiFrame.kindAck, seq: packet.seq, payload: Data()))
                decode(packet)
            case MiFrame.kindNack:
                status = "Браслет запросил повтор передачи (NACK \(packet.seq))."
            default:
                break
            }
        }
    }

    private func decode(_ packet: MiFrame.Packet) {
        guard packet.payload.count >= 2 else { return }
        let channel = packet.payload[0] & 0x0F
        let opcode = packet.payload[1]
        guard channel == 1 else { return }
        var body = Data(packet.payload.dropFirst(2))
        if opcode == 2 {
            guard let sessionKeys else { return }
            body = MiCrypto.ctr(key: sessionKeys.decryptionKey, body)
        }
        guard let command = PBMessage(body) else { return }
        handle(command)
    }

    private func handle(_ command: PBMessage) {
        let type = command.varints[1] ?? 0
        let subtype = command.varints[2] ?? 0

        if type == MiAuth.commandTypeAuth && subtype == MiAuth.subtypeNonce {
            guard let verify = command.message(3)?.message(31),
                  let watchNonce = verify.blobs[1],
                  let watchHmac = verify.blobs[2] else {
                status = "Браслет не прислал данные авторизации. Закройте Mi Fitness и повторите."
                return
            }
            while keyIndex < candidateKeys.count {
                if let result = MiAuth.confirmCommand(authKey: candidateKeys[keyIndex],
                                                      phoneNonce: phoneNonce,
                                                      watchNonce: watchNonce,
                                                      watchHmac: watchHmac,
                                                      deviceName: "Band 10 Companion") {
                    sessionKeys = result.keys
                    status = "Ключ принят. Завершение авторизации…"
                    sendCommand(result.command, encrypted: false)
                    return
                }
                keyIndex += 1
            }
            status = "Ключ не подошёл. Проверьте, что импортировали ключ именно этого браслета."
            return
        }

        if type == MiAuth.commandTypeAuth && subtype == MiAuth.subtypeAuth {
            isAuthenticated = true
            status = "Браслет авторизован. Запрашиваю заряд батареи…"
            sendCommand(MiAuth.batteryCommand(), encrypted: true)
            return
        }

        if type == 2 && subtype == 1, let level = MiAuth.batteryLevel(command) {
            batteryLevel = Int(level)
            status = "Подключено и авторизовано. Заряд: \(level)%."
        }
    }
}

extension BandBluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("CENTRAL state changed: raw=\(central.state.rawValue), description=\(stateDescription), authorization=\(CBManager.authorization.rawValue)")
        status = central.state == .poweredOn
            ? "Bluetooth готов. Можно искать браслет."
            : "Bluetooth: \(stateDescription)"
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map(\.uuidString).joined(separator: ",") ?? "none"
        let manufacturerBytes = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)?.count ?? 0
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        let serviceDataKeys = serviceData.keys.map(\.uuidString).joined(separator: ",")
        let isXiaomiCandidate = serviceData.keys.contains(bandService) || (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.contains(bandService) == true
        guard isXiaomiCandidate else { return }
        let txPower = advertisementData[CBAdvertisementDataTxPowerLevelKey] ?? "unknown"
        log("DISCOVER id=\(peripheral.identifier.uuidString); name=\(peripheral.name ?? advertisedName ?? "nil"); RSSI=\(RSSI); connectable=\(advertisementData[CBAdvertisementDataIsConnectable] ?? "unknown"); serviceUUIDs=\(serviceUUIDs); manufacturerDataBytes=\(manufacturerBytes); serviceDataUUIDs=\(serviceDataKeys); txPower=\(txPower)")
        let name = peripheral.name ?? advertisedName ?? "Xiaomi BLE device"
        peripherals[peripheral.identifier] = peripheral
        latestRSSI[peripheral.identifier] = (RSSI.intValue, Date())
        let device = BandDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else {
            devices.append(device)
            devices.sort { $0.rssi > $1.rssi }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard connectedPeripheral?.identifier == peripheral.identifier else {
            log("STALE DID CONNECT ignored; id=\(peripheral.identifier.uuidString)")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        log("DID CONNECT; id=\(peripheral.identifier.uuidString); peripheralState=\(peripheral.state.rawValue); centralState=\(central.state.rawValue); awaitingCallback=\(awaitingConnectionCallback)")
        awaitingConnectionCallback = false
        isConnecting = false
        connectionTimeout?.cancel()
        connectionTimeout = nil
        connectionTimedOut = false
        isConnected = true
        status = "Соединение установлено. Поиск BLE-сервисов…"
        peripheral.delegate = self
        log("GATT discovery requested; services=all")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("DID FAIL TO CONNECT; id=\(peripheral.identifier.uuidString); peripheralState=\(peripheral.state.rawValue); centralState=\(central.state.rawValue); error=\(error?.localizedDescription ?? "none"); details=\(String(describing: error)); awaitingCallback=\(awaitingConnectionCallback)")
        awaitingConnectionCallback = false
        guard connectedPeripheral?.identifier == peripheral.identifier else { return }
        isConnecting = false
        connectionTimeout?.cancel()
        connectionTimeout = nil
        isConnected = false
        connectedPeripheral = nil
        status = "Ошибка подключения: \(error?.localizedDescription ?? "нет подробностей")"
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("DID DISCONNECT; id=\(peripheral.identifier.uuidString); peripheralState=\(peripheral.state.rawValue); centralState=\(central.state.rawValue); error=\(error?.localizedDescription ?? "none"); details=\(String(describing: error)); wasConnecting=\(isConnecting); wasConnected=\(isConnected); awaitingCallback=\(awaitingConnectionCallback); timeoutRequested=\(connectionTimedOut)")
        guard connectedPeripheral?.identifier == peripheral.identifier else {
            log("STALE DISCONNECT ignored; active=\(connectedPeripheral?.identifier.uuidString ?? "nil")")
            return
        }
        connectionTimeout?.cancel()
        connectionTimeout = nil
        lastDisconnectDate = Date()
        awaitingConnectionCallback = false
        resetSession()
        isConnecting = false
        isConnected = false
        connectedPeripheral = nil
        if connectionTimedOut {
            status = "Тайм-аут BLE: iOS не завершила подключение за 30 секунд."
            connectionTimedOut = false
        } else {
            status = "Соединение с браслетом разорвано."
        }
    }
}

extension BandBluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        log("GATT SERVICES callback; error=\(error?.localizedDescription ?? "none"); services=\((peripheral.services ?? []).map { $0.uuid.uuidString }.joined(separator: ","))")
        if let error {
            status = "Ошибка чтения сервисов: \(error.localizedDescription)"
            return
        }
        let services = peripheral.services ?? []
        gattPendingServices = Set(services.map(\.uuid))
        for service in services {
            gattDetails.append("SERVICE  \(service.uuid.uuidString)")
            log("GATT characteristic discovery requested; service=\(service.uuid.uuidString); filter=all")
            peripheral.discoverCharacteristics(nil, for: service)
        }
        if services.isEmpty {
            status = "Устройство подключено, но GATT-сервисы не обнаружены."
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        log("GATT CHARACTERISTICS callback; service=\(service.uuid.uuidString); error=\(error?.localizedDescription ?? "none")")
        if let error {
            status = "Ошибка чтения характеристик: \(error.localizedDescription)"
            return
        }
        let characteristics = service.characteristics ?? []
        for characteristic in characteristics {
            let properties = characteristic.properties
            var flags: [String] = []
            if properties.contains(.read) { flags.append("read") }
            if properties.contains(.write) { flags.append("write") }
            if properties.contains(.writeWithoutResponse) { flags.append("write-no-response") }
            if properties.contains(.notify) { flags.append("notify") }
            if properties.contains(.indicate) { flags.append("indicate") }
            gattDetails.append("CHAR  \(characteristic.uuid.uuidString) [\(flags.joined(separator: ", "))]")
        }

        // Band 10 FE95 transport uses distinct characteristics:
        // 005E for notifications and 005F for outgoing commands.
        let notifyCandidate = characteristics.first {
            $0.uuid == notifyUUID &&
            ($0.properties.contains(.notify) || $0.properties.contains(.indicate))
        }
        let writeCandidate = characteristics.first {
            $0.uuid == writeUUID &&
            ($0.properties.contains(.writeWithoutResponse) || $0.properties.contains(.write))
        }
        if let notifyCandidate, let writeCandidate, notifyCharacteristic == nil, writeCharacteristic == nil {
            notifyCharacteristic = notifyCandidate
            writeCharacteristic = writeCandidate
            log("GATT transport selected in service \(service.uuid.uuidString); notify=\(notifyCandidate.uuid.uuidString); write=\(writeCandidate.uuid.uuidString)")
            status = "Найдены характеристики связи. Включаю уведомления…"
            peripheral.setNotifyValue(true, for: notifyCandidate)
        } else if notifyCandidate == nil || writeCandidate == nil {
            log("GATT service has no complete Notify/Write pair; service=\(service.uuid.uuidString); notify=\(notifyCandidate?.uuid.uuidString ?? "none"); write=\(writeCandidate?.uuid.uuidString ?? "none")")
        }

        gattPendingServices.remove(service.uuid)
        if gattPendingServices.isEmpty && (notifyCharacteristic == nil || writeCharacteristic == nil) {
            let summary = gattDetails.filter { $0.hasPrefix("CHAR") }.joined(separator: " | ")
            status = "GATT прочитан, но подходящая пара Notify/Write не найдена. Полный список — в отчёте."
            log("GATT discovery complete; transport pair missing; \(summary)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == notifyCharacteristic?.uuid else { return }
        if let error {
            status = "Не удалось включить уведомления: \(error.localizedDescription)"
        } else if characteristic.isNotifying {
            startSession()
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            status = "Ошибка приёма BLE: \(error.localizedDescription)"
            return
        }
        guard characteristic.uuid == notifyCharacteristic?.uuid, let value = characteristic.value else { return }
        receive(value)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        pumpWrites()
    }
}
