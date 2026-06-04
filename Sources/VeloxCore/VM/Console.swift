import Foundation
import Virtualization

/// Serial console wiring for the guest.
enum Console {
    /// A virtio console serial port that bridges the guest console to this
    /// process's stdin/stdout — enough to watch boot logs and (with a raw
    /// terminal) interact with a guest shell. Pair with `console=hvc0`.
    static func makeSerialPort() -> VZVirtioConsoleDeviceSerialPortConfiguration {
        let port = VZVirtioConsoleDeviceSerialPortConfiguration()
        port.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: FileHandle.standardInput,
            fileHandleForWriting: FileHandle.standardOutput
        )
        return port
    }
}
