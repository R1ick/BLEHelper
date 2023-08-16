//
//  BLE.swift
//  BLE
//
//  Created by Yaroslav Antonovich on 09.03.2023.
//

import Foundation
import CoreBluetooth
#if canImport(Combine)
import Combine
#endif

@objc public protocol BLEOutputProtocol: AnyObject {
    @objc optional func didUpdateCentralManagerState(_ state: CBManagerState)
    @objc optional func didGetTimeoutError()
    @objc optional func didDiscover(_ peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber)
    @objc optional func didDiscoverServices(_ services: [CBService])
    @objc optional func didDiscoverCharacteristics(_ characteristics: [CBCharacteristic], for service: CBService)
    @objc optional func didWriteValue(for characteristic: CBCharacteristic, error: Error?)
    @objc optional func didUpdateValue(for characteristic: CBCharacteristic, erorr: Error?)
}

public class BLE: NSObject {
    // MARK: - Lifecycle
    override init() {
        super.init()
        self.centralManager = CBCentralManager(delegate: self, queue: queue)
    }
    
    public convenience init(output: BLEOutputProtocol, retryCount: Int = 3) {
        self.init()
        self.output = output
        self.retryCount = retryCount
    }
    
    deinit {
        guard #available(iOS 13, *) else { return }
        cancellable.forEach { $0.cancel() }
    }
    
    // MARK: - Public properties
    /// Array of writable characteristics
    public var rxCharacteristics: [CBCharacteristic] {
        self.characteristics.filter { $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse) }
    }
    /// Array of notifying characteristics
    public var txCharacteristics: [CBCharacteristic] {
        self.characteristics.filter { $0.properties.contains(.notify) }
    }
    /// Connected peripheral
    public var connectedPeripheral: CBPeripheral?
    
    private var _cancellable: Any?
    
    @available(iOS 13, *)
    private var cancellable: Set<AnyCancellable> {
        get {
            if _cancellable == nil {
                _cancellable = Set<AnyCancellable>()
            }
            return _cancellable as! Set<AnyCancellable>
        } set {
            _cancellable = (_cancellable as? Set<AnyCancellable>)?.union(newValue)
        }
    }
    
    // MARK: - Internal properties
    weak var output: BLEOutputProtocol!
    
    // MARK: - Private properties
    /// When device disconects for any reason this is count of retry connection
    private var retryCount = 3
    /// If you cannot connect to the sensor in 20 sec, it'll send error (Flag)
    private var timeout = true
    /// The central bluetooth manager
    private var centralManager: CBCentralManager?
    /// The queue, on which will compute all ble tasks
    private let queue = DispatchQueue(label: "com.ya.blehelper.bleQueue", qos: .utility)
    /// Array of all characteristics in connected peripheral
    private var characteristics: [CBCharacteristic] = []
    
    private let domain: String = "com.ya.bleHelper"
    
    // MARK: - Public functions
    /// Start scan for availible peripherals
    public func startScan(
        withServices services: [CBUUID]? = nil,
        options: [String: Any]? = nil
    ) {
        centralManager?.scanForPeripherals(withServices: services, options: options)
    }
    
    /// Stop scan
    public func stopScan() {
        centralManager?.stopScan()
    }
    
    /// Try connect to `peripheral` `retryCount` times if `retryCount` != `nil`
    ///  `Note` - if you want to set `retryCount` use `init(output: , retryCount: )`
    public func connect(
        to peripheral: CBPeripheral,
        options: [String: Any]? = nil
    ) {
        centralManager?.connect(peripheral, options: options)
        peripheral.delegate = self
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self else { return }
            if self.timeout {
                self.disconnect(from: peripheral)
                self.output.didGetTimeoutError?()
            }
        }
    }
    
    /// Call this function to disconnect from connected peripheral
    public func disconnect(from peripheral: CBPeripheral) {
        peripheral.delegate = nil
        connectedPeripheral = nil
        
        centralManager?.cancelPeripheralConnection(peripheral)
        characteristics.removeAll()
    }
    
    /// Call this function to listen characteristic
    public func setNotifying(
        _ enabled: Bool,
        for characteristic: CBCharacteristic
    ) {
        if let connectedPeripheral {
            connectedPeripheral.setNotifyValue(enabled, for: characteristic)
        }
    }
    
    public func send(
        _ command: String,
        to peripheral: CBPeripheral,
        for characteristic: CBCharacteristic
    ) {
        guard characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse),
              let data = "\(command)\n".data(using: .utf8)
        else { return }
        peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
    }
    
    public func send(
        _ command: String,
        to peripheral: CBPeripheral
    ) {
        guard let rx = rxCharacteristics.first,
              let data = "\(command)\n".data(using: .utf8)
        else {
            print("BLEHelper ", #line, " invalid command or no characteristics to write")
            return
        }
        peripheral.writeValue(data, for: rx, type: .withoutResponse)
    }
    
    public func send(_ command: String) {
        guard let rx = rxCharacteristics.first,
              let data = "\(command)\n".data(using: .utf8)
        else {
            print("BLEHelper ", #line, " invalid command or no characteristics to write")
            return
        }
        connectedPeripheral?.writeValue(data, for: rx, type: .withoutResponse)
    }
    
    public func send(
        _ data: Data,
        to characteristic: CBCharacteristic
    ) {
        guard characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse) else {
            print("BLEHelper ", #line, " no characteristics to write")
            return
        }
        connectedPeripheral?.writeValue(data, for: characteristic, type: .withoutResponse)
    }
    
    public func send(
        _ data: Data,
        to peripheral: CBPeripheral
    ) {
        guard let rx = rxCharacteristics.first else { return }
        peripheral.writeValue(data, for: rx, type: .withoutResponse)
    }
    
    public func send(_ data: Data) {
        guard let rx = rxCharacteristics.first else { return }
        connectedPeripheral?.writeValue(data, for: rx, type: .withoutResponse)
    }
    
    /// Use this method to create chains of commands that should start executing after a certain response from the peripheral
    @available(iOS 13, *)
    open func send(
        _ command: Data,
        andWait expectedResponse: Data?,
        timeout: TimeInterval,
        completion: @escaping (Result<Data?, Error>) -> Void
    ) {
        guard let tx = txCharacteristics.first else { return }
        send(command)
        let txPublisher = tx.publisher(for: \.value)
        var isCompleted = false
        var cancellable: AnyCancellable?
        cancellable = txPublisher
            .removeDuplicates()
            .sink { [weak self] value in
                guard let value,
                      let log = String(data: value, encoding: .utf8),
                      let expectedResponse,
                      let exp = String(data: expectedResponse, encoding: .utf8)
                else { return }
                if log == exp || log.contains(exp) {
                    completion(.success(value))
                    isCompleted = true
                    self?.cancellable.forEach { $0.cancel() }
                }
            }
        
        cancellable?.store(in: &self.cancellable)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, isCompleted == false else { return }
            completion(.failure(NSError(domain: domain, code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: "Timeout"])))
        }
    }
    /// `async` Use this method to create chains of commands that should start executing after a certain response from the peripheral
    @available(iOS 13, *)
    open func send(
        _ command: Data,
        andWait expectedResponse: Data?,
        timeout: TimeInterval
    ) async -> Result<Data?, Error> {
        guard let tx = txCharacteristics.first else {
            return .failure(
                NSError(
                    domain: domain,
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "No characteristic to write"])
            )
            
        }
        send(command)
        if let value = await didReceive(expectedResponse, from: tx, timeout: timeout) {
            return .success(value)
        }
        return .failure(
            NSError(
                domain: domain,
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Timeout"]
            )
        )
    }
    
    /// Use this method to create chains of commands that should start executing after a certain response from the peripheral
    @available(iOS 13, *)
    open func send(
        _ command: String,
        andWait expectedResponse: String,
        timeout: TimeInterval,
        completion: @escaping (Result<Data?, Error>) -> Void
    ) {
        guard let tx = txCharacteristics.first else { return }
        send(command)
        let txPublisher = tx.publisher(for: \.value)
        var isCompleted = false
        var cancellable: AnyCancellable?
        cancellable = txPublisher
            .removeDuplicates()
            .sink { value in
                guard let value,
                      let log = String(data: value, encoding: .utf8)
                else { return }
                if log == expectedResponse || log.contains(expectedResponse) {
                    completion(.success(value))
                    isCompleted = true
                    cancellable?.cancel()
                }
            }
        cancellable?.store(in: &self.cancellable)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, isCompleted == false else { return }
            completion(.failure(NSError(domain: domain, code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: "Timeout"])))
            cancellable?.cancel()
        }
    }
    /// `async` Use this method to create chains of commands that should start executing after a certain response from the peripheral
    @available(iOS 13, *)
    open func send(
        _ command: String,
        andWait expectedResponse: String,
        timeout: TimeInterval
    ) async -> Result<Data?, Error> {
        guard let tx = txCharacteristics.first else {
            return .failure(
                NSError(
                    domain: domain,
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "No characteristic to write"])
            )
            
        }
        send(command)
        if let value = await didReceive(expectedResponse, from: tx, timeout: timeout) {
            return .success(value)
        }
        return .failure(
            NSError(
                domain: domain,
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Timeout"]
            )
        )
    }
    
    @available(iOS 13, *)
    private func didReceive(
        _ expectedResponse: Data?,
        from tx: CBCharacteristic,
        timeout: TimeInterval
    ) async -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                continuation.resume(returning: nil)
            }
                                          
            tx.publisher(for: \.value)
                .removeDuplicates()
                .sink { value in
                    guard let value,
                          let log = String(data: value, encoding: .utf8),
                          let expectedResponse,
                          let exp = String(data: expectedResponse, encoding: .utf8)
                    else { return }
                    if log == exp || log.contains(exp) {
                        continuation.resume(returning: value)
                    }
                }
                .store(in: &cancellable)
        }
    }
    
    @available(iOS 13, *)
    private func didReceive(
        _ expectedResponse: String,
        from tx: CBCharacteristic,
        timeout: TimeInterval
    ) async -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                continuation.resume(returning: nil)
            }
                                          
            tx.publisher(for: \.value)
                .removeDuplicates()
                .sink { value in
                    guard let value,
                          let log = String(data: value, encoding: .utf8)
                    else { return }
                    if log == expectedResponse || log.contains(expectedResponse) {
                        continuation.resume(returning: value)
                    }
                }
                .store(in: &cancellable)
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension BLE: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        output.didUpdateCentralManagerState?(central.state)
        if central.state == .poweredOff, let connectedPeripheral {
            disconnect(from: connectedPeripheral)
        }
    }
    
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        output.didDiscover?(peripheral, advertisementData: advertisementData, rssi: RSSI)
    }
    
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedPeripheral = peripheral
        timeout = false
        
        peripheral.discoverServices(nil)
    }
    
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard let _ = error else { return }
        timeout = true
        let count = retryCount
        
        switch retryCount {
        case 1...count:
            centralManager?.connect(peripheral)
            retryCount -= 1
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) { [weak self] in
                guard let self else { return }
                if self.timeout {
                    self.disconnect(from: peripheral)
                    self.output.didGetTimeoutError?()
                }
            }
        case 0:
            output.didGetTimeoutError?()
        default: break
        }
    }
}

// MARK: - CBPeripheralDelegate
extension BLE: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        services.forEach { service in
            peripheral.discoverCharacteristics(nil, for: service)
        }
        output.didDiscoverServices?(services)
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics, self.characteristics.isEmpty else {
            return
        }
        self.characteristics = characteristics
        self.output.didDiscoverCharacteristics?(characteristics, for: service)
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        output.didWriteValue?(for: characteristic, error: error)
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        output.didUpdateValue?(for: characteristic, erorr: error)
    }
}
