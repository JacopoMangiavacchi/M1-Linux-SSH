//
//  VM.swift
//  M1-Linux-SSH
//
//  Created by Jacopo Mangiavacchi on 11/22/20.
//

import Foundation
import Virtualization

class VM: NSObject, VZVirtualMachineDelegate {
    let kernelURL: URL
    let initialRamdiskURL: URL
    let bootableImageURL: URL
    let queue: DispatchQueue

    var virtualMachine: VZVirtualMachine?
    
    let readPipe = Pipe()
    let writePipe = Pipe()
    
    init(kernelURL: URL, initialRamdiskURL: URL, bootableImageURL: URL, queue: DispatchQueue) {
        self.kernelURL = kernelURL
        self.initialRamdiskURL = initialRamdiskURL
        self.bootableImageURL = bootableImageURL
        self.queue = queue
    }
    
    func start() {
        let bootloader = VZLinuxBootLoader(kernelURL: kernelURL)
        bootloader.initialRamdiskURL = initialRamdiskURL
        bootloader.commandLine = "console=hvc0"
        
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        
        serial.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: writePipe.fileHandleForReading,
            fileHandleForWriting: readPipe.fileHandleForWriting
        )

        let entropy = VZVirtioEntropyDeviceConfiguration()
        
        let memoryBalloon = VZVirtioTraditionalMemoryBalloonDeviceConfiguration()
        
        let blockAttachment: VZDiskImageStorageDeviceAttachment
        
        do {
            blockAttachment = try VZDiskImageStorageDeviceAttachment(
                url: bootableImageURL,
                readOnly: true
            )
        } catch {
            print("Failed to load bootableImage: \(error)")
            return
        }
        
        let blockDevice = VZVirtioBlockDeviceConfiguration(attachment: blockAttachment)
        
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()
        
        let config = VZVirtualMachineConfiguration()
        config.bootLoader = bootloader
        config.cpuCount = 4
        config.memorySize = 2 * 1024 * 1024 * 1024
        config.entropyDevices = [entropy]
        config.memoryBalloonDevices = [memoryBalloon]
        config.serialPorts = [serial]
        config.storageDevices = [blockDevice]
        config.networkDevices = [networkDevice]
                
        do {
            try config.validate()
            
            let vm = VZVirtualMachine(configuration: config, queue: queue)
            vm.delegate = self
            self.virtualMachine = vm
        }
        catch {
            print("Error: \(error)")
            return
        }

        print("VM Starting")
        queue.async {
            self.virtualMachine?.start { result in
                switch result {
                case .success:
                    print("VM Started succesfully")
                    break
                case .failure(let error):
                    print("VM Failed: \(error)")
                }
            }
        }
    }
    
    func stop() {
        queue.async {
            if let virtualMachine = self.virtualMachine {
                do {
                    try virtualMachine.requestStop()
                } catch {
                    print("Failed to stop: \(error)")
                }
                self.virtualMachine = nil
            }
        }
    }
    
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        print("Stopped")
    }
    
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        print("Stopped with error: \(error)")
    }
}

