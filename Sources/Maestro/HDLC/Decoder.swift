import Foundation

/// Stateful streaming HDLC decoder.
///
/// Feed inbound bytes via `process(_:)`. The closure is invoked for every
/// completed frame found, in order. Partial frames are buffered across calls.
/// Errors do not terminate the decoder — it resyncs on the next frame flag.
public final class HDLCDecoder {
    public enum DecodeError: Error, Equatable {
        case unexpectedData
        case unexpectedEndOfFrame
        case invalidChecksum
        case invalidEncoding
        case invalidFrame
        case invalidAddress
        case bufferOverflow
    }

    private enum State {
        case discard
        case frame
    }

    private enum EscState {
        case normal
        case escape
    }

    private var buf: [UInt8] = []
    private var state: State = .discard
    private var escState: EscState = .normal
    private let capacity: Int

    public init(capacity: Int = 4096) {
        self.capacity = capacity
        self.buf.reserveCapacity(capacity)
    }

    /// Feed bytes into the decoder. `onFrame` is invoked for each completed frame.
    /// Any decode errors are surfaced via `onError`. Returns the number of bytes consumed.
    @discardableResult
    public func process(
        _ bytes: Data,
        onFrame: (HDLCFrame) -> Void,
        onError: (DecodeError) -> Void
    ) -> Int {
        var i = 0
        let n = bytes.count
        while i < n {
            switch state {
            case .discard:
                let consumed = consumeUntilFlag(bytes, startingAt: i, onError: onError)
                i += consumed
            case .frame:
                let consumed = consumeFrame(bytes, startingAt: i, onFrame: onFrame, onError: onError)
                i += consumed
            }
        }
        return n
    }

    private func consumeUntilFlag(
        _ bytes: Data,
        startingAt start: Int,
        onError: (DecodeError) -> Void
    ) -> Int {
        let n = bytes.count
        var i = start
        var sawJunk = false
        let base = bytes.startIndex
        while i < n {
            let b = bytes[base + i]
            if b == HDLCConsts.frameFlag {
                i += 1
                state = .frame
                escState = .normal
                buf.removeAll(keepingCapacity: true)
                if sawJunk {
                    onError(.unexpectedData)
                }
                return i - start
            }
            sawJunk = true
            i += 1
        }
        if sawJunk {
            onError(.unexpectedData)
        }
        return i - start
    }

    private func consumeFrame(
        _ bytes: Data,
        startingAt start: Int,
        onFrame: (HDLCFrame) -> Void,
        onError: (DecodeError) -> Void
    ) -> Int {
        let n = bytes.count
        var i = start
        let base = bytes.startIndex
        while i < n {
            let b = bytes[base + i]
            switch (b, escState) {
            case (HDLCConsts.escapeFlag, .normal):
                escState = .escape
                i += 1
            case (HDLCConsts.escapeFlag, .escape):
                i += 1
                resetAfterError(onError: onError, error: .invalidEncoding)
                return i - start
            case (HDLCConsts.frameFlag, .normal):
                i += 1
                finalizeFrame(onFrame: onFrame, onError: onError)
                return i - start
            case (HDLCConsts.frameFlag, .escape):
                // closing flag where we expected an escaped byte
                resetAfterError(onError: onError, error: .unexpectedEndOfFrame)
                // do not consume the flag — the next loop will pick it up as a frame start
                return i - start
            case (let value, .normal):
                pushByte(value)
                i += 1
            case (let value, .escape):
                pushByte(value ^ HDLCConsts.escapeMask)
                escState = .normal
                i += 1
            }
        }
        return i - start
    }

    private func finalizeFrame(
        onFrame: (HDLCFrame) -> Void,
        onError: (DecodeError) -> Void
    ) {
        defer {
            buf.removeAll(keepingCapacity: true)
            state = .frame
            escState = .normal
        }

        // Consecutive frame flags (close-of-N immediately followed by open-of-N+1) yield
        // an empty buf between them — that's just a flag boundary, not a malformed frame.
        if buf.isEmpty {
            return
        }

        guard buf.count >= 6 else {
            onError(.invalidFrame)
            return
        }

        let crcStart = buf.count - 4
        let computed = CRC32.compute(buf[0..<crcStart])
        let expected =
            UInt32(buf[crcStart]) |
            (UInt32(buf[crcStart + 1]) << 8) |
            (UInt32(buf[crcStart + 2]) << 16) |
            (UInt32(buf[crcStart + 3]) << 24)
        if expected != computed {
            onError(.invalidChecksum)
            return
        }

        let address: UInt32
        let varintLen: Int
        do {
            (address, varintLen) = try Varint.decode(buf)
        } catch Varint.DecodeError.overflow {
            onError(.invalidAddress)
            return
        } catch {
            onError(.invalidFrame)
            return
        }

        guard buf.count >= varintLen + 5 else {
            onError(.invalidFrame)
            return
        }

        let control = buf[varintLen]
        let dataStart = varintLen + 1
        let data = Data(buf[dataStart..<crcStart])
        onFrame(HDLCFrame(address: address, control: control, data: data))
    }

    private func resetAfterError(onError: (DecodeError) -> Void, error: DecodeError) {
        buf.removeAll(keepingCapacity: true)
        state = .frame
        escState = .normal
        onError(error)
    }

    private func pushByte(_ byte: UInt8) {
        if buf.count < capacity {
            buf.append(byte)
        }
    }
}
