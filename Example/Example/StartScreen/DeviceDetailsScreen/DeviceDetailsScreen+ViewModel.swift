//
//  DeviceDetailsScreen+ViewModel.swift
//  Example
//
//  Created by Nick Kibysh on 29/03/2023.
//

import Foundation
import iOS_BLE_Library
import iOS_Bluetooth_Numbers_Database
import Combine

extension DeviceDetailsScreen {
    @MainActor
    class ViewModel: ObservableObject {
        let centralManager: CentralManager
        
        private var cancelable = Set<AnyCancellable>()
        private var peripheral: CBPeripheral!
        private var characteristics: [CBCharacteristic] = [] {
            didSet {
                self.discoveredServices = characteristics.reduce(into: [Attributes]()) { partialResult, ch in
                    if let i = partialResult.firstIndex(where: { $0.id == ch.service?.uuid.uuidString }) {
                        partialResult[i].inner.append(Attributes(characteristic: ch))
                    } else if let s = ch.service {
                        partialResult.append(Attributes(service: s, characteristics: [ch]))
                    }
                }
            }
        }
        private lazy var peripheralManager = PeripheralManager(peripheral: peripheral, delegate: ReactivePeripheralDelegate())
        
        // MARK: Published
        @Published var name: String = ""
        @Published var rssi: RSSI = .outOfRange
        @Published var isConnectable: Bool = false
        @Published var connectionState: CBPeripheralState = .disconnected
        
        @Published var advertisementData: AdvertisementData = AdvertisementData([:])
        
        @Published var discoveredServices: [Attributes] = []
        
        @Published var showError: Bool = false
        @Published var displayError: ReadableError? = nil {
            didSet {
                showError = displayError != nil
            }
        }
        
        init(peripheral: CBPeripheral, rssi: RSSI, centralManager: CentralManager, advertisementData: AdvertisementData) {
            self.peripheral = peripheral
            self.centralManager = centralManager
            self.rssi = rssi
            self.advertisementData = advertisementData
            
            setupDisplayValues()
        }
        
        init(scanResult: ScanResult, centralManager: CentralManager) {
            self.centralManager = centralManager
            self.peripheral = scanResult.peripheral
            self.rssi = scanResult.rssi
            self.advertisementData = scanResult.advertisementData
            
            setupDisplayValues()
        }
        
        private func setupDisplayValues() {
            name = peripheral?.name ?? "n/a"
            isConnectable = advertisementData.isConnectable ?? false
            
            peripheralManager.peripheralStateChannel
                .assign(to: &$connectionState)
        }
        
        #if DEBUG
        init() {
            self.centralManager = CentralManager()
        }
        #endif
        
        func discoverDevice() {
        }
    }
}

extension DeviceDetailsScreen.ViewModel {
    struct Attributes: NestedStringRepresentable {
        var description: String { name }
        var id: String
        var level: UInt
        let name: String
        var inner: [Attributes]
        
        init(id: String, level: UInt, name: String, inner: [Attributes]) {
            self.id = id
            self.level = level
            self.name = name
            self.inner = inner
        }
        
        init(service: CBService, characteristics: [CBCharacteristic] = []) {
            self.id = service.uuid.uuidString
            self.level = 1
            self.name = iOS_Bluetooth_Numbers_Database.Service.find(by: service.uuid)?.name ?? "New Service"
            self.inner = characteristics.map { Attributes(characteristic: $0) }
        }
        
        init(characteristic: CBCharacteristic, descriptors: [CBDescriptor] = []) {
            self.id = characteristic.uuid.uuidString
            self.level = 2
            self.name = iOS_Bluetooth_Numbers_Database.Characteristic.find(by: characteristic.uuid)?.name ?? "New Characteristic"
            self.inner = descriptors.map { Attributes(descriptor: $0) }
        }
        
        init(descriptor: CBDescriptor) {
            self.id = descriptor.uuid.uuidString
            self.level = 3
            self.name = iOS_Bluetooth_Numbers_Database.Descriptor.find(by: descriptor.uuid)?.name ?? "New Descriptor"
            self.inner = []
        }
    }
}

extension Sequence {
    func asyncMap<T>(
        _ transform: (Element) async throws -> T
    ) async rethrows -> [T] {
        var values = [T]()

        for element in self {
            try await values.append(transform(element))
        }

        return values
    }
}

extension DeviceDetailsScreen.ViewModel {
    func connect() async {
        guard let peripheral else {
            fatalError()
        }
        
        do {
            _ = try await centralManager.connect(peripheral)
                .autoconnect()
                .value
            
        } catch let e {
            displayError = ReadableError(error: e, title: "Can't connect")
            return
        }
        
        let servicePublisher = peripheralManager.discoverServices(serviceUUIDs: nil)
            .autoconnect()
            .share()
        
        let characteristicsPublisher = servicePublisher
            .flatMap { [unowned self] service in
                self.peripheralManager.discoverCharacteristics(nil, for: service).autoconnect()
            }
            .share()
        
        let descriptorPublisher = characteristicsPublisher
            .flatMap { [unowned self] characteristic in
                self.peripheralManager.discoverDescriptors(for: characteristic).autoconnect()
            }
            .share()
        
        servicePublisher
            .map { Attributes(service: $0) }
            .sink { [unowned self] completion in
                if case .failure(let e) = completion {
                    self.displayError = ReadableError(error: e, title: "Error")
                }
            } receiveValue: { service in
                self.discoveredServices.append(service)
            }
            .store(in: &cancelable)

        characteristicsPublisher
            .sink { [unowned self] completion in
                if case .failure(let e) = completion {
                    self.displayError = ReadableError(error: e, title: "Error")
                }
            } receiveValue: { characteristic in
                if let serviceIndex = self.discoveredServices.firstIndex(where: { $0.id == characteristic.service?.uuid.uuidString }) {
                    self.discoveredServices[serviceIndex].inner.append(Attributes(characteristic: characteristic))
                } else if let service = characteristic.service {
                    self.discoveredServices.append(Attributes(service: service, characteristics: [characteristic]))
                }
            }
            .store(in: &cancelable)
        
        descriptorPublisher
            .sink { completion in
                if case .failure(let e) = completion {
                    self.displayError = ReadableError(error: e, title: "Error")
                }
            } receiveValue: { descriptor in
                if let serviceIndex = self.discoveredServices.firstIndex(where: { $0.id == descriptor.characteristic?.service?.uuid.uuidString }) {
                    if let characteristicIndex = self.discoveredServices[serviceIndex].inner.firstIndex(where: { $0.id == descriptor.characteristic?.uuid.uuidString }) {
                        self.discoveredServices[serviceIndex].inner[characteristicIndex].inner.append(Attributes(descriptor: descriptor))
                    } else if let ch = descriptor.characteristic {
                        self.discoveredServices[serviceIndex].inner.append(Attributes(characteristic: ch, descriptors: [descriptor]))
                    }
                } else if let service = descriptor.characteristic?.service, let characteristic = descriptor.characteristic {
                    self.discoveredServices.append(<#T##newElement: Attributes##Attributes#>)
                }
            }


        
        
        peripheralManager.discoverServices(serviceUUIDs: nil)
            .autoconnect()
            .flatMap { self.peripheralManager.discoverCharacteristics(nil, for: $0).autoconnect() }
            .receive(on: RunLoop.main)
            .sink { completion in
                if case .failure(let e) = completion {
                    self.displayError = ReadableError(error: e, title: "Error")
                }
            } receiveValue: { ch in
                self.characteristics.append(ch)
            }
            .store(in: &cancelable)
    }
    
    func disconnect() async {
        do {
            _ = try await centralManager.cancelPeripheralConnection(peripheral)
                .autoconnect()
                .value
        } catch let e {
            displayError = ReadableError(error: e, title: "Error!")
        }
        
        for c in cancelable {
            c.cancel()
        }
        
        cancelable.removeAll()
        self.characteristics = []
    }
}
