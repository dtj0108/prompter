import Foundation
import AVFoundation

/// Converts mic buffers to the analyzer's required format.
/// AVAudioConverter is not Sendable; this box is only ever touched from the
/// audio tap's serial callback context.
final class BufferConverter: @unchecked Sendable {
    enum ConversionError: Error {
        case converterCreationFailed
        case bufferAllocationFailed
        case conversionFailed(NSError?)
    }

    private var converter: AVAudioConverter?

    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format == format { return buffer }

        if converter == nil || converter!.inputFormat != buffer.format || converter!.outputFormat != format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            // .none avoids the converter swallowing leading samples for filter priming.
            converter?.primeMethod = .none
        }
        guard let converter else { throw ConversionError.converterCreationFailed }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw ConversionError.bufferAllocationFailed
        }

        // The input block is called synchronously within convert(to:error:).
        var consumed = false
        let inputBuffer = buffer
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }
        guard status != .error else { throw ConversionError.conversionFailed(conversionError) }
        return output
    }
}
