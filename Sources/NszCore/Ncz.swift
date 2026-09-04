import Foundation
import Czstd
import CommonCrypto

// MARK: - Errors

public enum NczError: Error, CustomStringConvertible {
    case badMagic(String)
    case corruptedHeader(String)
    case zstdFailure(String)
    case unsupportedCrypto(String)

    public var description: String {
        switch self {
        case .badMagic(let m): return "Bad magic, expected \(m) - is this really a .ncz file?"
        case .corruptedHeader(let m): return "Corrupted NCZ header: \(m)"
        case .zstdFailure(let m): return "zstd failure: \(m)"
        case .unsupportedCrypto(let m): return "Unsupported crypto: \(m)"
        }
    }
}

// MARK: - Binary reading helpers

enum LE {
    static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        let b = [UInt8](data.subdata(in: offset..<offset+4))
        return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    }
    static func u64(_ data: Data, _ offset: Int) -> UInt64 {
        var v: UInt64 = 0
        let b = [UInt8](data.subdata(in: offset..<offset+8))
        for i in (0..<8).reversed() { v = (v << 8) | UInt64(b[i]) }
        return v
    }
    static func bytes(_ data: Data, _ offset: Int, _ count: Int) -> [UInt8] {
        [UInt8](data.subdata(in: offset..<(offset+count)))
    }
}

extension FileHandle {
    func readExactly(_ count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        guard let d = try read(upToCount: count), d.count == count else {
            throw NczError.corruptedHeader("unexpected EOF (wanted \(count) bytes)")
        }
        return d
    }
}

// MARK: - SHA-256 (incremental, CommonCrypto)

final class SHA256Context {
    private var ctx = CC_SHA256_CTX()
    init() { CC_SHA256_Init(&ctx) }
    func update(_ data: Data) {
        data.withUnsafeBytes { raw in
            _ = CC_SHA256_Update(&ctx, raw.baseAddress, CC_LONG(raw.count))
        }
    }
    func finalHex() -> String {
        var digest = [UInt8](repeating: 0, count: 32)
        CC_SHA256_Final(&digest, &ctx)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - AES-CTR re-encryption (replicates nsz's nut.AESCTR semantics)
//
// nsz (pycryptodome): Counter.new(64, prefix=nonce[0:8], initial_value=(absoluteOffset >> 4))
// => counter block = nonce[0..<8] || bigEndian(absoluteOffset >> 4)
// The counter is addressed by the ABSOLUTE offset inside the NCA, not relative to the section.

func ctrEncrypt(key: [UInt8], counter: [UInt8], absoluteOffset: UInt64, data: Data) throws -> Data {
    guard key.count == kCCKeySizeAES128 else {
        throw NczError.unsupportedCrypto("AES-128 key expected, got \(key.count) bytes")
    }
    var iv = [UInt8](counter.prefix(8))
    var value = (absoluteOffset >> 4).bigEndian
    withUnsafeBytes(of: &value) { iv.append(contentsOf: $0) }

    var cryptor: CCCryptorRef?
    let status = CCCryptorCreateWithMode(
        					CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
        iv, key, key.count, nil, 0, 0, 0, &cryptor)
    guard status == kCCSuccess, let cryptor = cryptor else {
        throw NczError.unsupportedCrypto("CCCryptorCreateWithMode failed: \(status)")
    }
    defer { CCCryptorRelease(cryptor) }

    var out = Data(count: data.count)
    try data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
        try out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            var moved = 0
            let s = CCCryptorUpdate(cryptor, src.baseAddress, data.count,
                                    dst.baseAddress, dst.count, &moved)
            guard s == kCCSuccess else {
                throw NczError.unsupportedCrypto("CCCryptorUpdate failed: \(s)")
            }
        }
    }
    return out
}

// MARK: - NCZ header structures
//
// Layout at NCA offset 0x4000:
//   [8]  "NCZSECTN"
//   [8]  sectionCount (u64)
//   sectionCount * 64 bytes:
//     [8]  offset      (u64, absolute NCA offset of section start)
//     [8]  size       (u64)
//     [8]  cryptoType  (u64; 3 or 4 => re-encrypt with AES-CTR, else plain copy)
//     [8]  padding
//     [16] cryptoKey
//     [16] cryptoCounter
//   optional "NCZBLOCK" header, then zstd stream to EOF.

struct NczSection {
    var offset: UInt64
    var size: UInt64
    var cryptoType: UInt64
    var cryptoKey: [UInt8]
    var cryptoCounter: [UInt8]

    static let byteSize = 64

    init(offset: UInt64, size: UInt64, cryptoType: UInt64, key: [UInt8] = [], counter: [UInt8] = []) {
        self.offset = offset
        self.size = size
        self.cryptoType = cryptoType
        self.cryptoKey = key
        self.cryptoCounter = counter
    }

    init(data: Data, at index: Int) {
        let base = index * NczSection.byteSize
        offset = LE.u64(data, base)
        size = LE.u64(data, base + 8)
        cryptoType = LE.u64(data, base + 16)
        cryptoKey = LE.bytes(data, base + 32, 16)
        cryptoCounter = LE.bytes(data, base + 48, 16)
    }

    var needsCrypto: Bool { cryptoType == 3 || cryptoType == 4 }
}

struct NczBlockHeader {
    let blockSizeExponent: UInt8
    let decompressedSize: UInt64
    let compressedBlockSizeList: [Int32]

    init(data: Data) throws {
        // data = magic(8) + version(1) + type(1) + unused(1) + exponent(1)
        //        + numberOfBlocks(4) + decompressedSize(8) + n*4
        let exponent = data[11]
        guard (14...32).contains(exponent) else {
            throw NczError.corruptedHeader("block size exponent must be 14..32, got \(exponent)")
        }
        let numberOfBlocks = Int(Int32(bitPattern: LE.u32(data, 12)))
        guard numberOfBlocks >= 0 else {
            throw NczError.corruptedHeader("negative block count")
        }
        decompressedSize = LE.u64(data, 16)
        var sizes: [Int32] = []
        sizes.reserveCapacity(numberOfBlocks)
        for i in 0..<numberOfBlocks {
            sizes.append(Int32(bitPattern: LE.u32(data, 24 + i * 4)))
        }
        blockSizeExponent = exponent
        compressedBlockSizeList = sizes
    }

    var blockSize: Int { 1 << Int(blockSizeExponent) }
}

// MARK: - Solid zstd stream reader (zstd C library via Czstd target)

final class ZstdStreamReader {
    private let ds: OpaquePointer?
    private let file: FileHandle
    private var readPos: UInt64
    private let endPos: UInt64
    private var src: [UInt8] = []
    private var srcConsumed = 0
    private var inputDone = false
    private var finished = false
    private var pending = Data()   // decoded bytes beyond the last read's maxLength
    private let dstCapacity = 1 << 18
    private let srcChunk = 1 << 20

    init?(file: FileHandle, start: UInt64, end: UInt64) {
        self.file = file
        self.readPos = start
        self.endPos = end
        ds = ZSTD_createDStream()
        guard let ds = ds, ZSTD_isError(ZSTD_initDStream(ds)) == 0 else { return nil }
    }

    deinit {
        if let ds = ds { _ = ZSTD_freeDStream(ds) }
    }

    private func refillSource() {
        if readPos >= endPos {
            inputDone = true
            src = []
            srcConsumed = 0
            return
        }
        let want = Int(min(UInt64(srcChunk), endPos - readPos))
        file.seek(toFileOffset: readPos)
        let chunk = (try? file.readExactly(want)) ?? Data()
        readPos += UInt64(chunk.count)
        if chunk.isEmpty { inputDone = true }
        src = [UInt8](chunk)
        srcConsumed = 0
    }

    /// Feed one chunk to the decoder, drain produced output.
    /// Returns (output, consumedInput, frameComplete).
    private func pump(inBase: UnsafeRawPointer?, inSize: Int) throws -> (Data, Int, Bool) {
        var inBuf = ZSTD_inBuffer(src: inBase, size: inSize, pos: 0)
        var out = Data()
        var lastIn = -1
        var lastOut = -1
        while true {
            var dstBuf = [UInt8](repeating: 0, count: dstCapacity)
            var produced = 0
            var ret: Int = 0
            try dstBuf.withUnsafeMutableBufferPointer { dstBP in
                var outBuf = ZSTD_outBuffer(dst: dstBP.baseAddress, size: dstCapacity, pos: 0)
                ret = ZSTD_decompressStream(ds, &outBuf, &inBuf)
                if ZSTD_isError(ret) != 0 {
                    throw NczError.zstdFailure(String(cString: ZSTD_getErrorName(ret)))
                }
                produced = outBuf.pos
            }
            if produced > 0 {
                out.append(contentsOf: dstBuf[0..<produced])
            }
            if ret == 0 { return (out, inBuf.pos, true) }          // frame complete
            if produced == 0 && inBuf.pos >= inBuf.size {
                return (out, inBuf.pos, false)                     // need more input
            }
            // stall guard: no progress at all means a decoder bug
            if Int(inBuf.pos) == lastIn && produced == lastOut {
                throw NczError.zstdFailure("decoder stalled")
            }
            lastIn = Int(inBuf.pos)
            lastOut = produced
        }
    }

    /// Sequential read; returns at most `maxLength` bytes (empty Data at end of stream).
    /// Decoded output beyond `maxLength` is buffered in `pending` for subsequent reads.
    func read(_ maxLength: Int) throws -> Data {
        var out = Data()
        out.reserveCapacity(maxLength)

        // serve buffered overflow first
        if !pending.isEmpty {
            let n = min(maxLength, pending.count)
            out = Data(pending.prefix(n))
            pending.removeFirst(n)
            if out.count == maxLength { return out }
        }
        if finished { return out }

        while out.count < maxLength {
            if srcConsumed >= src.count && !inputDone {
                refillSource()
            }
            let hasInput = srcConsumed < src.count

            if hasInput {
                var result: (Data, Int, Bool)!
                var caught: Error? = nil
                src.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    do {
                        result = try pump(inBase: raw.baseAddress?.advanced(by: srcConsumed),
                                          inSize: src.count - srcConsumed)
                    } catch { caught = error }
                }
                if let e = caught { throw e }
                out.append(result.0)
                srcConsumed += result.1
                if result.2 { finished = true; break }   // zstd frame complete
            } else if inputDone {
                // flush decoder with empty input to surface any buffered output / detect truncation
                let (chunk, _, frameDone) = try pump(inBase: nil, inSize: 0)
                out.append(chunk)
                finished = true
                _ = frameDone
                break
            }
            // else: refill will happen on next loop iteration
        }
        // stash any decoded surplus beyond maxLength
        if out.count > maxLength {
            pending = out.subdata(in: maxLength..<out.count)
            out = out.subdata(in: 0..<maxLength)
        }
        return out
    }
}

// MARK: - Block decompressor (replicates nsz BlockDecompressorReader, sequential mode)

final class BlockDecompressor {
    private let file: FileHandle
    private let blockSize: Int
    private let decompressedSize: UInt64
    private let compressedSizes: [Int]
    private let blockOffsets: [UInt64]
    private var position: UInt64 = 0
    private var currentBlockID = -1
    private var currentBlock = Data()

    init(file: FileHandle, header: NczBlockHeader, streamStart: UInt64) {
        self.file = file
        self.blockSize = header.blockSize
        self.decompressedSize = header.decompressedSize
        self.compressedSizes = header.compressedBlockSizeList.map(Int.init)
        var offsets: [UInt64] = [streamStart]
        for s in header.compressedBlockSizeList.dropLast() {
            offsets.append(offsets.last! + UInt64(s))
        }
        self.blockOffsets = offsets
    }

    private func loadBlock(_ id: Int) throws -> Data {
        // decompressed size: full block, except possibly the last one
        var dSize = blockSize
        if id == compressedSizes.count - 1 {
            let remainder = decompressedSize % UInt64(blockSize)
            if remainder > 0 { dSize = Int(remainder) }
        }
        let cbs = compressedSizes[id]
        file.seek(toFileOffset: blockOffsets[id])
        let raw = try file.readExactly(cbs)

        if cbs < dSize {
            // independent zstd frame (one-shot decode)
            var dst = [UInt8](repeating: 0, count: dSize)
            let n = try raw.withUnsafeBytes { (srcRaw: UnsafeRawBufferPointer) -> Int in
                try dst.withUnsafeMutableBytes { (dstRaw: UnsafeMutableRawBufferPointer) -> Int in
                    guard let srcBase = srcRaw.bindMemory(to: UInt8.self).baseAddress,
                          let dstBase = dstRaw.bindMemory(to: UInt8.self).baseAddress else {
                        throw NczError.zstdFailure("null buffer")
                    }
                    let dctx = ZSTD_createDCtx()
                    defer { if let dctx = dctx { _ = ZSTD_freeDCtx(dctx) } }
                    let r = ZSTD_decompressDCtx(dctx, dstBase, dSize, srcBase, cbs)
                    if ZSTD_isError(r) != 0 {
                        throw NczError.zstdFailure("block \(id): \(String(cString: ZSTD_getErrorName(r)))")
                    }
                    return r
                }
            }
            guard n == dSize else {
                throw NczError.zstdFailure("block \(id): decoded \(n) bytes, expected \(dSize)")
            }
            return Data(dst)
        } else {
            // stored in plain text
            return raw.prefix(dSize)
        }
    }

    /// Sequential read of exactly `n` decompressed bytes (or fewer at EOF).
    func read(_ n: Int) throws -> Data {
        var out = Data()
        out.reserveCapacity(n)
        while out.count < n {
            let blockID = Int(position / UInt64(blockSize))
            guard blockID < compressedSizes.count else { break }
            if blockID != currentBlockID {
                currentBlock = try loadBlock(blockID)
                currentBlockID = blockID
            }
            let off = Int(position % UInt64(blockSize))
            guard off < currentBlock.count else { break }
            let take = min(n - out.count, currentBlock.count - off)
            out.append(currentBlock.subdata(in: off..<(off + take)))
            position += UInt64(take)
        }
        return out
    }
}

// MARK: - NCZ decompression core (mirrors nsz IndependentNczDecompressor / Decompressor.__decompressNcz)

let INCOMPRESSIBLE_HEADER_SIZE = 0x4000
let SECTION_MAGIC: [UInt8] = Array("NCZSECTN".utf8)
let BLOCK_MAGIC: [UInt8] = Array("NCZBLOCK".utf8)

/// Parses only the header to compute the decompressed NCA size.
func nczDecompressedSize(file: FileHandle, entryOffset: UInt64) throws -> UInt64 {
    file.seek(toFileOffset: entryOffset + UInt64(INCOMPRESSIBLE_HEADER_SIZE))
    let magic = try file.readExactly(8)
    guard [UInt8](magic) == SECTION_MAGIC else { throw NczError.badMagic("NCZSECTN") }
    let count = LE.u64(try file.readExactly(8), 0)
    let sectionBytes = try file.readExactly(Int(count) * NczSection.byteSize)
    var sections = (0..<Int(count)).map { NczSection(data: sectionBytes, at: $0) }
    // official: FakeSection when the first section starts beyond 0x4000
    if let first = sections.first, first.offset > UInt64(INCOMPRESSIBLE_HEADER_SIZE) {
        sections.insert(NczSection(offset: UInt64(INCOMPRESSIBLE_HEADER_SIZE),
                                   size: first.offset - UInt64(INCOMPRESSIBLE_HEADER_SIZE),
                                   cryptoType: 1), at: 0)
    }
    var ncaSize = UInt64(INCOMPRESSIBLE_HEADER_SIZE)
    for s in sections { ncaSize += s.size }
    return ncaSize
}

// MARK: - Corruption pre-scan (zero-run detection inside compressed data)

public struct ZeroRun {
    public let start: UInt64
    public let end: UInt64
    public var length: UInt64 { end - start }
}

/// Scans `range` for runs of zero bytes >= `threshold` (streaming, 4 MB chunks).
/// Valid zstd streams never contain multi-KB zero runs, so a hit is a strong
/// corruption signature (e.g. zero-filled hole from an interrupted download).
func scanZeroRuns(file: FileHandle, range: Range<UInt64>, threshold: UInt64 = 4096) throws -> [ZeroRun] {
    file.seek(toFileOffset: range.lowerBound)
    var runs: [ZeroRun] = []
    var zeroStart: UInt64? = nil
    var pos = range.lowerBound
    let chunkSize = 4 << 20
    while pos < range.upperBound {
        let want = Int(min(UInt64(chunkSize), range.upperBound - pos))
        let chunk = try file.readExactly(want)
        var i = 0
        while i < want {
            if chunk[i] == 0 {
                let endIdx = chunk[i...].firstIndex(where: { $0 != 0 }) ?? want
                if zeroStart == nil { zeroStart = pos + UInt64(i) }
                i = endIdx
            } else {
                let endIdx = chunk[i...].firstIndex(of: 0) ?? want
                if let zs = zeroStart, pos + UInt64(i) - zs >= threshold {
                    runs.append(ZeroRun(start: zs, end: pos + UInt64(i)))
                }
                zeroStart = nil
                i = endIdx
            }
        }
        pos += UInt64(want)
    }
    if let zs = zeroStart, range.upperBound - zs >= threshold {
        runs.append(ZeroRun(start: zs, end: range.upperBound))
    }
    return runs
}

/// Byte ranges of an NCZ entry that hold zstd-compressed data — the corruption
/// scan target. Stored-plain blocks and the NCA header are excluded because
/// their legitimate content may contain long zero runs.
func nczCompressedRanges(file: FileHandle, entryOffset: UInt64, entrySize: UInt64) throws -> [Range<UInt64>] {
    let entryEnd = entryOffset + entrySize
    file.seek(toFileOffset: entryOffset + UInt64(INCOMPRESSIBLE_HEADER_SIZE))
    let magic = try file.readExactly(8)
    guard [UInt8](magic) == SECTION_MAGIC else { throw NczError.badMagic("NCZSECTN") }
    let count = Int(LE.u64(try file.readExactly(8), 0))
    _ = try file.readExactly(count * NczSection.byteSize)
    let headerEnd = file.offsetInFile

    let peek = try file.readExactly(8)
    if [UInt8](peek) == BLOCK_MAGIC {
        // block mode: read the block table and scan only zstd-compressed blocks
        file.seek(toFileOffset: headerEnd)
        let head24 = try file.readExactly(24)
        let nBlocks = Int(Int32(bitPattern: LE.u32(head24, 12)))
        var headerData = head24
        if nBlocks > 0 { headerData += try file.readExactly(nBlocks * 4) }
        let blockHeader = try NczBlockHeader(data: headerData)

        var ranges: [Range<UInt64>] = []
        let bs = UInt64(blockHeader.blockSize)
        var off = headerEnd + UInt64(headerData.count)
        let ids = blockHeader.compressedBlockSizeList.indices
        for id in ids {
            let cbs = UInt64(blockHeader.compressedBlockSizeList[id])
            var dSize = bs
            if id == ids.upperBound - 1 {
                let rem = blockHeader.decompressedSize % bs
                if rem > 0 { dSize = rem }
            }
            if cbs > 0 && cbs < dSize {
                ranges.append(off..<(off + cbs))
            }
            off += cbs
        }
        return ranges
    } else {
        // solid mode: everything after the section table is one zstd frame
        return [headerEnd..<entryEnd]
    }
}

/// Convenience: scan all compressed ranges of an NCZ entry, returns merged runs.
func scanNczForCorruption(file: FileHandle, entryOffset: UInt64, entrySize: UInt64) throws -> [ZeroRun] {
    var runs: [ZeroRun] = []
    for r in try nczCompressedRanges(file: file, entryOffset: entryOffset, entrySize: entrySize) {
        runs += try scanZeroRuns(file: file, range: r)
    }
    return runs
}

/// Decompresses one NCZ entry into `write`, returns the SHA-256 hex of the produced NCA.
func decompressNcz(file: FileHandle, entryOffset: UInt64, entrySize: UInt64,
                   write: (Data) throws -> Void) throws -> String {
    let hash = SHA256Context()

    file.seek(toFileOffset: entryOffset)
    let header = try file.readExactly(INCOMPRESSIBLE_HEADER_SIZE)
    try write(header)
    hash.update(header)

    let magic = try file.readExactly(8)
    guard [UInt8](magic) == SECTION_MAGIC else { throw NczError.badMagic("NCZSECTN") }
    let count = LE.u64(try file.readExactly(8), 0)
    let sectionBytes = try file.readExactly(Int(count) * NczSection.byteSize)
    var sections = (0..<Int(count)).map { NczSection(data: sectionBytes, at: $0) }

    if let first = sections.first, first.offset > UInt64(INCOMPRESSIBLE_HEADER_SIZE) {
        // official FakeSection: plain-copy the gap between header end and first section
        sections.insert(NczSection(offset: UInt64(INCOMPRESSIBLE_HEADER_SIZE),
                                   size: first.offset - UInt64(INCOMPRESSIBLE_HEADER_SIZE),
                                   cryptoType: 1), at: 0)
    }

    // block compression or solid zstd?
    let headerEnd = file.offsetInFile
    let blockPeek = try file.readExactly(8)
    file.seek(toFileOffset: headerEnd)
    let useBlock = [UInt8](blockPeek) == BLOCK_MAGIC

    var blockReader: BlockDecompressor? = nil
    var zstdReader: ZstdStreamReader? = nil
    if useBlock {
        // block header: magic(8) + version(1) + type(1) + unused(1) + exponent(1)
        //             + numberOfBlocks(4) + decompressedSize(8) + numberOfBlocks*4
        file.seek(toFileOffset: headerEnd + 12)
        let numberOfBlocks = Int(Int32(bitPattern: LE.u32(try file.readExactly(4), 0)))
        file.seek(toFileOffset: headerEnd)
        let blockData = try file.readExactly(24 + numberOfBlocks * 4)
        let blockHeader = try NczBlockHeader(data: blockData)
        blockReader = BlockDecompressor(file: file, header: blockHeader,
                                        streamStart: headerEnd + UInt64(blockData.count))
    } else {
        zstdReader = ZstdStreamReader(file: file, start: headerEnd, end: entryOffset + entrySize)
    }

    var firstSection = true
    for s in sections {
        var i = s.offset
        let end = s.offset + s.size
        let useCrypto = s.needsCrypto

        if firstSection {
            firstSection = false
            // official quirk: when the first real section starts *inside* the header
            // region (offset < 0x4000, no FakeSection inserted), the compressed stream
            // begins at 0x4000, so skip the already-written part of the section.
            let uncompressed = UInt64(INCOMPRESSIBLE_HEADER_SIZE) - sections[0].offset
            if uncompressed > 0 { i += uncompressed }
        }

        while i < end {
            let chunkSz = min(UInt64(0x10000), end - i)
            var chunk: Data
            if let br = blockReader {
                chunk = try br.read(Int(chunkSz))
            } else {
                chunk = try zstdReader!.read(Int(chunkSz))
            }
            if chunk.isEmpty { break }
            if useCrypto {
                chunk = try ctrEncrypt(key: s.cryptoKey, counter: s.cryptoCounter,
                                       absoluteOffset: i, data: chunk)
            }
            try write(chunk)
            hash.update(chunk)
            i += UInt64(chunk.count)
        }
    }
    return hash.finalHex()
}
