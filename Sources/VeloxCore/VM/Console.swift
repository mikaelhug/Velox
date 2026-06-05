import Foundation
import Virtualization

/// Serial console wiring for the guest.
enum Console {
    /// A virtio console serial port that bridges the guest console to this
    /// process. By default it uses stdin/stdout (the CLI: watch boot logs and, with
    /// a raw terminal, interact with a guest shell). The GUI passes a pipe's write
    /// end for `write` so it can capture the engine log stream into a ring buffer
    /// (`EngineLogStore`) and show it, since it has no terminal. Pair with
    /// `console=hvc0`.
    static func makeSerialPort(write: FileHandle = .standardOutput,
                               read: FileHandle = .standardInput)
        -> VZVirtioConsoleDeviceSerialPortConfiguration {
        let port = VZVirtioConsoleDeviceSerialPortConfiguration()
        port.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: read,
            fileHandleForWriting: write
        )
        return port
    }
}
