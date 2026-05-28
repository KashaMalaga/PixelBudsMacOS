import Foundation

enum HexDump {
    static func print(_ data: Data, columns: Int = 16) {
        var offset = 0
        while offset < data.count {
            let end = Swift.min(offset + columns, data.count)
            let slice = data[offset..<end]
            let hex = slice
                .map { String(format: "%02x", $0) }
                .joined(separator: " ")
                .padding(toLength: columns * 3 - 1, withPad: " ", startingAt: 0)
            let ascii = slice
                .map { (0x20...0x7e).contains($0) ? String(UnicodeScalar($0)) : "." }
                .joined()
            Swift.print(String(format: "  %04x  %@  %@", offset, hex, ascii))
            offset = end
        }
    }
}
