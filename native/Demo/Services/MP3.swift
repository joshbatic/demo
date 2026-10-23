import Foundation
import AVFoundation
#if canImport(LAME)
import LAME
#endif

/// MP3 encoding with LAME (the native twin of the web's lamejs). WAV / AIFF / FLAC uploads become
/// 256 kbps stereo or 160 kbps mono MP3 (resampled to 44.1 or 48 kHz when higher), and lyric sync sends
/// 48 kbps mono pieces. Without the LAME package the app falls back to AAC and WAV.
nonisolated enum MP3 {
    #if canImport(LAME)
    static let available = true
    #else
    static let available = false
    #endif

    enum MP3Error: Error { case unavailable, read, encode }

    /// A file → an .mp3 in the temporary folder.
    static func encode(_ src: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) { try encodeSync(src) }.value
    }

    private static func encodeSync(_ src: URL) throws -> URL {
        #if canImport(LAME)
        let file = try AVAudioFile(forReading: src)
        let inFmt = file.processingFormat
        let channels = min(2, Int(inFmt.channelCount))
        let inRate = inFmt.sampleRate
        let outRate: Double = inRate > 48000 ? (Int(inRate) % 44100 == 0 ? 44100 : 48000) : inRate
        guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outRate, channels: AVAudioChannelCount(channels), interleaved: false),
              let conv = AVAudioConverter(from: inFmt, to: outFmt) else { throw MP3Error.read }

        guard let lame = lame_init() else { throw MP3Error.encode }
        defer { lame_close(lame) }
        lame_set_in_samplerate(lame, Int32(outRate))
        lame_set_out_samplerate(lame, Int32(outRate))
        lame_set_num_channels(lame, Int32(channels))
        lame_set_mode(lame, channels == 1 ? MONO : JOINT_STEREO)
        lame_set_brate(lame, channels == 1 ? 160 : 256)
        lame_set_quality(lame, 2)
        guard lame_init_params(lame) >= 0 else { throw MP3Error.encode }

        let dest = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mp3")
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: dest) else { throw MP3Error.encode }
        defer { try? out.close() }

        let frames: AVAudioFrameCount = 8192
        var mp3 = [UInt8](repeating: 0, count: Int(Double(frames) * 1.25) + 7200)
        var done = false
        while !done {
            guard let buf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: frames) else { throw MP3Error.read }
            var err: NSError?
            let status = conv.convert(to: buf, error: &err) { _, st in
                guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: 32768) else { st.pointee = .endOfStream; return nil }
                do {
                    try file.read(into: inBuf)
                    if inBuf.frameLength == 0 { st.pointee = .endOfStream; return nil }
                    st.pointee = .haveData
                    return inBuf
                } catch { st.pointee = .endOfStream; return nil }
            }
            let n = Int32(buf.frameLength)
            if n > 0, let ch = buf.floatChannelData {
                let l = ch[0], r = channels > 1 ? ch[1] : ch[0]
                let w = mp3.withUnsafeMutableBufferPointer { p in
                    lame_encode_buffer_ieee_float(lame, l, r, n, p.baseAddress, Int32(p.count))
                }
                guard w >= 0 else { throw MP3Error.encode }
                if w > 0 { out.write(Data(mp3[0..<Int(w)])) }
            }
            if status == .endOfStream || status == .error || n == 0 { done = true }
        }
        let w = mp3.withUnsafeMutableBufferPointer { p in lame_encode_flush(lame, p.baseAddress, Int32(p.count)) }
        if w > 0 { out.write(Data(mp3[0..<Int(w)])) }
        return dest
        #else
        throw MP3Error.unavailable
        #endif
    }

    /// Mono samples (lyric sync's 16 kHz pieces) → a small MP3, or nil without LAME.
    static func encodeMono(_ samples: [Float], sampleRate: Int, kbps: Int) -> Data? {
        #if canImport(LAME)
        guard let lame = lame_init() else { return nil }
        defer { lame_close(lame) }
        lame_set_in_samplerate(lame, Int32(sampleRate))
        lame_set_out_samplerate(lame, Int32(sampleRate))
        lame_set_num_channels(lame, 1)
        lame_set_mode(lame, MONO)
        lame_set_brate(lame, Int32(kbps))
        lame_set_quality(lame, 5)
        guard lame_init_params(lame) >= 0 else { return nil }
        var out = Data()
        let chunk = 16384
        var mp3 = [UInt8](repeating: 0, count: Int(Double(chunk) * 1.25) + 7200)
        var i = 0
        while i < samples.count {
            let n = min(chunk, samples.count - i)
            let w = samples.withUnsafeBufferPointer { s in
                mp3.withUnsafeMutableBufferPointer { p in
                    lame_encode_buffer_ieee_float(lame, s.baseAddress! + i, s.baseAddress! + i, Int32(n), p.baseAddress, Int32(p.count))
                }
            }
            guard w >= 0 else { return nil }
            out.append(contentsOf: mp3[0..<Int(w)])
            i += n
        }
        let w = mp3.withUnsafeMutableBufferPointer { p in lame_encode_flush(lame, p.baseAddress, Int32(p.count)) }
        if w > 0 { out.append(contentsOf: mp3[0..<Int(w)]) }
        return out
        #else
        return nil
        #endif
    }
}
