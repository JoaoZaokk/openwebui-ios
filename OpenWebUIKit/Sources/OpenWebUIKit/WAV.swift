import Foundation

/// Minimal WAV (PCM 16-bit mono) encode/decode, shared by the server upload
/// path and the pending-audio store.
public enum WAV {
    public static func encode(_ frames: [Float], sampleRate: Int) -> Data {
        let channels = 1, bits = 16
        let blockAlign = channels * bits / 8
        let byteRate = sampleRate * blockAlign
        let dataSize = frames.count * blockAlign
        func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func u16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var d = Data(capacity: 44 + dataSize)
        d.append(Data("RIFF".utf8)); d.append(u32(UInt32(36 + dataSize))); d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8)); d.append(u32(16)); d.append(u16(1)); d.append(u16(UInt16(channels)))
        d.append(u32(UInt32(sampleRate))); d.append(u32(UInt32(byteRate)))
        d.append(u16(UInt16(blockAlign))); d.append(u16(UInt16(bits)))
        d.append(Data("data".utf8)); d.append(u32(UInt32(dataSize)))
        var pcm = [Int16](repeating: 0, count: frames.count)
        for i in frames.indices { pcm[i] = Int16(max(-1, min(1, frames[i])) * 32767) }
        pcm.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        return d
    }

    /// Reads back what `encode` wrote (16-bit PCM mono). Returns nil for anything else.
    public static func decode(_ d: Data) -> (frames: [Float], sampleRate: Int)? {
        guard d.count > 44, String(data: d[0..<4], encoding: .ascii) == "RIFF",
              String(data: d[8..<12], encoding: .ascii) == "WAVE" else { return nil }
        var pos = 12
        var rate = 0, channels = 0, bits = 0
        while pos + 8 <= d.count {
            let id = String(data: d[pos..<pos + 4], encoding: .ascii) ?? ""
            let size = Int(d[pos + 4..<pos + 8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
            let body = pos + 8
            if id == "fmt ", body + 16 <= d.count {
                channels = Int(d[body + 2..<body + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian)
                rate = Int(d[body + 4..<body + 8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
                bits = Int(d[body + 14..<body + 16].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian)
            } else if id == "data" {
                guard channels == 1, bits == 16, rate > 0 else { return nil }
                let end = min(d.count, body + size)
                let n = (end - body) / 2
                var frames = [Float](repeating: 0, count: n)
                d[body..<body + n * 2].withUnsafeBytes { raw in
                    let p = raw.bindMemory(to: Int16.self)
                    for i in 0..<n { frames[i] = Float(Int16(littleEndian: p[i])) / 32767 }
                }
                return (frames, rate)
            }
            pos = body + size + (size & 1)
        }
        return nil
    }
}
