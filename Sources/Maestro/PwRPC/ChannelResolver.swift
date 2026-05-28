import Foundation
import SwiftProtobuf

/// Probes the candidate Maestro channels in parallel by sending GetSoftwareInfo
/// on each. The first to respond with a valid SoftwareInfo is the active channel
/// for this RFCOMM session.
public enum ChannelResolver {
    /// Probes candidate Maestro channels sequentially, returning the first that responds
    /// and matches write-capability if multiple bud channels are active.
    /// Sequential probing avoids the buds rejecting concurrent in-flight requests on
    /// distinct channels.
    public static func resolve(
        on connection: RpcConnection,
        perCandidateTimeout seconds: TimeInterval = 0.5,
        logger: ((String) -> Void)? = nil
    ) async throws -> UInt32 {
        let path = RpcPath("maestro_pw.Maestro/GetSoftwareInfo")
        
        // Interleaved probing order prioritizing bud channels:
        // buds left/right A/B interleaved, then case A/B
        let interleavedOrder: [UInt32] = [19, 24, 21, 26, 18, 23]
        
        for channel in interleavedOrder {
            try Task.checkCancellation()
            logger?("trying candidate channel \(channel)…")
            let start = Date()
            do {
                try await probe(connection: connection, channel: channel, path: path, timeout: seconds)
                logger?("channel \(channel) responded in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
                
                // If it's a bud channel, check if the alternative bud is also responsive
                if let altChannel = MaestroChannel.alternativeBudChannel(for: channel) {
                    logger?("checking alternative bud channel \(altChannel)…")
                    do {
                        try await probe(connection: connection, channel: altChannel, path: path, timeout: seconds)
                        logger?("alternative bud channel \(altChannel) is also responsive")
                        
                        // We have both buds responsive! Test write-capability to select the primary/in-ear bud.
                        logger?("both buds responsive: testing write capability to select the active primary bud")
                        if await isWriteCapable(connection: connection, channel: channel) {
                            logger?("bud channel \(channel) accepts writes successfully: returning \(channel)")
                            return channel
                        } else if await isWriteCapable(connection: connection, channel: altChannel) {
                            logger?("bud channel \(channel) rejected writes, but alternative bud channel \(altChannel) accepts them: returning \(altChannel)")
                            return altChannel
                        } else {
                            logger?("both bud channels rejected writes: defaulting to channel \(channel)")
                            return channel
                        }
                    } catch {
                        logger?("alternative bud channel \(altChannel) is silent: returning active bud channel \(channel)")
                        return channel
                    }
                }
                
                return channel
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger?("channel \(channel) failed: \(error)")
                continue
            }
        }
        throw RpcError.channelResolutionFailed
    }

    private static func probe(
        connection: RpcConnection,
        channel: UInt32,
        path: RpcPath,
        timeout: TimeInterval
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try await connection.unary(
                    channel: channel,
                    path: path,
                    request: SwiftProtobuf.Google_Protobuf_Empty()
                )
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw RpcError.channelResolutionFailed
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    /// Harmlessly tests if a channel is write-capable by reading and writing back `gestureEnabled`.
    private static func isWriteCapable(connection: RpcConnection, channel: UInt32) async -> Bool {
        let pathGet = RpcPath("maestro_pw.Maestro/ReadSetting")
        let pathSet = RpcPath("maestro_pw.Maestro/WriteSetting")
        
        do {
            var readReq = MaestroPw_ReadSettingMsg()
            readReq.settingsID = .allegroGestureEnable
            let readPayload = try await connection.unary(
                channel: channel,
                path: pathGet,
                request: readReq
            )
            let rsp = try MaestroPw_SettingsRsp(serializedBytes: readPayload)
            let enabled = rsp.value.gestureEnable
            
            var writeValue = MaestroPw_SettingValue()
            writeValue.gestureEnable = enabled
            var writeReq = MaestroPw_WriteSettingMsg()
            writeReq.setting = writeValue
            
            _ = try await connection.unary(
                channel: channel,
                path: pathSet,
                request: writeReq
            )
            return true
        } catch {
            return false
        }
    }
}
