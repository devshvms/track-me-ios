import Foundation

enum ExportArchiveValidator {
    private static let failureEntryName = "EXPORT_FAILED.txt"
    private static let endOfCentralDirectorySignature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
    private static let centralDirectorySignature: UInt32 = 0x02014B50

    /// Reads only the ZIP central directory, so validation does not load GPX contents into memory.
    static func containsFailureMarker(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? handle.close() }

        do {
            let fileSize = try handle.seekToEnd()
            let tailSize = min(fileSize, 65_557)
            try handle.seek(toOffset: fileSize - tailSize)
            guard let tailData = try handle.read(upToCount: Int(tailSize)),
                  let endOffset = lastSignatureOffset(endOfCentralDirectorySignature, in: tailData),
                  endOffset + 22 <= tailData.count else {
                return true
            }

            let centralDirectorySize = UInt64(readUInt32LE(tailData, at: endOffset + 12))
            let centralDirectoryOffset = UInt64(readUInt32LE(tailData, at: endOffset + 16))
            guard centralDirectorySize != UInt64(UInt32.max),
                  centralDirectoryOffset != UInt64(UInt32.max),
                  centralDirectoryOffset <= fileSize,
                  centralDirectorySize <= fileSize - centralDirectoryOffset,
                  centralDirectorySize <= UInt64(Int.max) else {
                return true
            }

            try handle.seek(toOffset: centralDirectoryOffset)
            guard let centralDirectory = try handle.read(upToCount: Int(centralDirectorySize)) else {
                return true
            }
            return containsFailureEntry(in: centralDirectory)
        } catch {
            return true
        }
    }

    private static func containsFailureEntry(in data: Data) -> Bool {
        var offset = 0
        while offset + 46 <= data.count {
            guard readUInt32LE(data, at: offset) == centralDirectorySignature else {
                return true
            }

            let nameLength = Int(readUInt16LE(data, at: offset + 28))
            let extraLength = Int(readUInt16LE(data, at: offset + 30))
            let commentLength = Int(readUInt16LE(data, at: offset + 32))
            let nameStart = offset + 46
            let nextEntry = nameStart + nameLength + extraLength + commentLength
            guard nextEntry <= data.count else { return true }

            if let name = String(data: data.subdata(in: nameStart..<(nameStart + nameLength)), encoding: .utf8),
               name == failureEntryName {
                return true
            }
            offset = nextEntry
        }
        return offset == data.count
    }

    private static func lastSignatureOffset(_ signature: [UInt8], in data: Data) -> Int? {
        let bytes = Array(data)
        guard bytes.count >= signature.count else { return nil }
        for offset in stride(from: bytes.count - signature.count, through: 0, by: -1) {
            if Array(bytes[offset..<(offset + signature.count)]) == signature {
                return offset
            }
        }
        return nil
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
