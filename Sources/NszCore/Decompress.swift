import Foundation

// MARK: - PFS0 (NSP container)

public struct Pfs0Entry {
    public var name: String
    public var offset: UInt64   // absolute offset inside the container
    public var size: UInt64
    public var isNcz: Bool { name.hasSuffix(".ncz") }
}

public func parsePfs0(file: FileHandle) throws -> ([Pfs0Entry], UInt64) {
    let header = try file.readExactly(16)
    guard [UInt8](header.prefix(4)) == Array("PFS0".utf8) else {
        throw NczError.badMagic("PFS0")
    }
    let fileCount = Int(LE.u32(header, 4))
    let stringTableSize = Int(LE.u32(header, 8))

    let entryTableSize = fileCount * 24
    let rest = try file.readExactly(entryTableSize + stringTableSize)
    let entryTable = rest.prefix(entryTableSize)
    let stringTable = rest.suffix(stringTableSize)

    // PFS0 spec: entry offsets are relative to the end of the entry+string tables
    let dataStart = UInt64(16 + entryTableSize + stringTableSize)

    var entries: [Pfs0Entry] = []
    entries.reserveCapacity(fileCount)
    for i in 0..<fileCount {
        let base = i * 24
        let offset = LE.u64(entryTable, base)
        let size = LE.u64(entryTable, base + 8)
        let nameOffset = Int(LE.u32(entryTable, base + 16))
        // read null-terminated name from string table
        var nameEnd = nameOffset
        while nameEnd < stringTable.count && stringTable[stringTable.startIndex + nameEnd] != 0 {
            nameEnd += 1
        }
        let nameData = stringTable.subdata(in: (stringTable.startIndex + nameOffset)..<(stringTable.startIndex + nameEnd))
        let name = String(data: nameData, encoding: .utf8) ?? ""
        entries.append(Pfs0Entry(name: name, offset: offset + dataStart, size: size))
    }
    let firstFileOffset = entries.map(\.offset).min() ?? dataStart
    return (entries, firstFileOffset)
}

// MARK: - Progress events (used by both CLI and GUI)

public enum DecompressEvent {
    /// Corruption pre-scan warning for one NCZ entry.
    case scanWarning(name: String, runs: [ZeroRun])
    /// A new entry starts being written.
    case entryStart(name: String)
    /// Overall progress across the whole output file.
    case progress(currentName: String, written: UInt64, total: UInt64)
    /// An NCZ entry finished with SHA-256 verification against its hash-named file.
    case entryDone(name: String, hash: String, verified: Bool)
    /// A plain (non-NCZ) entry was copied.
    case entryCopied(name: String)
    /// Everything finished.
    case done(summary: String)
}

// MARK: - Output path conflict resolution
//
// "同名文件按时间重新命名": if the target exists, insert a timestamp
// before the extension, e.g. Game.nsp -> "Game 2026-09-04 22.46.40.nsp".

public func resolveOutputPath(_ path: String) -> String {
    let fm = FileManager.default
    guard fm.fileExists(atPath: path) else { return path }
    let ns = path as NSString
    let dir = ns.deletingLastPathComponent
    // NOTE: deletingPathExtension operates on the whole string, so apply it
    // to the file name only — not to the full path.
    let base = (ns.lastPathComponent as NSString).deletingPathExtension
    let ext = ns.pathExtension

    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd HH.mm.ss"
    let stamp = fmt.string(from: Date())

    var candidate = dir + "/" + base + " " + stamp + "." + ext
    var n = 2
    while fm.fileExists(atPath: candidate) {
        candidate = dir + "/" + base + " " + stamp + " (\(n))." + ext
        n += 1
    }
    return candidate
}

// MARK: - NSZ -> NSP decompression (shared core)

public func decompressContainer(inputPath: String, outputPath: String, skipScan: Bool = false,
                                onEvent: @escaping (DecompressEvent) -> Void = { _ in }) throws {
    let inputFile = try FileHandle(forReadingFrom: URL(fileURLWithPath: inputPath))
    defer { try? inputFile.close() }

    let (entries, firstFileOffset) = try parsePfs0(file: inputFile)
    _ = firstFileOffset

    // ---- pass 1: register output entries (ncz renamed + resized) ----
    struct OutEntry { var name: String; var size: UInt64 }
    var outEntries: [OutEntry] = []
    outEntries.reserveCapacity(entries.count)

    for e in entries {
        if e.name.hasSuffix(".xcz") || e.name.hasSuffix(".xci") {
            throw NczError.unsupportedCrypto("XCZ/XCI (HFS0 container) is not supported yet - only NSP/NSZ")
        }
        if e.isNcz {
            let ncaSize = try nczDecompressedSize(file: inputFile, entryOffset: e.offset)
            let newName = String(e.name.dropLast(4)) + ".nca"
            outEntries.append(OutEntry(name: newName, size: ncaSize))
        } else {
            outEntries.append(OutEntry(name: e.name, size: e.size))
        }
    }

    // ---- corruption pre-scan: long zero runs inside compressed data = damage signature ----
    var scanWarnings = 0
    if !skipScan {
        for e in entries where e.isNcz {
            let runs = try scanNczForCorruption(file: inputFile, entryOffset: e.offset, entrySize: e.size)
            if runs.isEmpty { continue }
            scanWarnings += runs.count
            onEvent(.scanWarning(name: e.name, runs: runs))
        }
    }

    // ---- rebuild PFS0 header (names keep the same length: .ncz -> .nca) ----
    var stringTable = Data()
    var nameOffsets: [UInt32] = []
    for e in outEntries {
        nameOffsets.append(UInt32(stringTable.count))
        stringTable.append(Data(e.name.utf8))
        stringTable.append(0)
    }
    let headerSize = UInt64(16 + 24 * outEntries.count + stringTable.count)
    // output data starts right after the header; entry offsets are relative to it (PFS0 spec)
    let dataStart = headerSize

    var hdr = Data()
    func appendLE32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { hdr.append(contentsOf: $0) } }
    func appendLE64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { hdr.append(contentsOf: $0) } }
    hdr.append(contentsOf: Array("PFS0".utf8))
    appendLE32(UInt32(outEntries.count))
    appendLE32(UInt32(stringTable.count))
    appendLE32(0) // reserved

    var runningOffset = dataStart
    var outOffsets: [UInt64] = []
    for e in outEntries {
        outOffsets.append(runningOffset)
        appendLE64(runningOffset - dataStart)   // relative to data start (PFS0 spec)
        appendLE64(e.size)
        appendLE32(nameOffsets[outOffsets.count - 1])
        appendLE32(0)
        runningOffset += e.size
    }
    hdr.append(stringTable)

    FileManager.default.createFile(atPath: outputPath, contents: nil)
    let outFile = try FileHandle(forWritingTo: URL(fileURLWithPath: outputPath))
    defer { try? outFile.close() }
    outFile.write(hdr)

    // ---- pass 2: write content ----
    let totalBytes = runningOffset - dataStart
    var writtenBytes: UInt64 = 0
    var verified = 0
    var mismatched = 0

    func verifyName(_ name: String, _ hash: String) -> Bool {
        let stem = (name as NSString).deletingPathExtension.lowercased()
        if stem.count == 32 { return stem == String(hash.prefix(32)) } // IndependentNczDecompressor semantics
        if stem.count == 64 { return stem == hash }                    // full NCA hash name
        return true // not hash-named: skip verification
    }

    for (i, e) in entries.enumerated() {
        let outName = outEntries[i].name
        onEvent(.entryStart(name: outName))
        if e.isNcz {
            var accumulated = Data()
            let hash = try decompressNcz(file: inputFile, entryOffset: e.offset, entrySize: e.size) { chunk in
                accumulated.append(chunk)
                // stream out in 4 MB pieces to bound memory
                if accumulated.count >= 4 << 20 {
                    outFile.write(accumulated)
                    writtenBytes += UInt64(accumulated.count)
                    onEvent(.progress(currentName: outName, written: writtenBytes, total: totalBytes))
                    accumulated.removeAll(keepingCapacity: true)
                }
            }
            if !accumulated.isEmpty {
                outFile.write(accumulated)
                writtenBytes += UInt64(accumulated.count)
                onEvent(.progress(currentName: outName, written: writtenBytes, total: totalBytes))
            }
            let ok = verifyName(outName, hash)
            if ok { verified += 1 } else { mismatched += 1 }
            onEvent(.entryDone(name: outName, hash: hash, verified: ok))
        } else {
            // plain entry: chunked copy + optional hash check
            let hash = SHA256Context()
            inputFile.seek(toFileOffset: e.offset)
            var remaining = e.size
            while remaining > 0 {
                let want = Int(min(UInt64(4 << 20), remaining))
                let chunk = try inputFile.readExactly(want)
                hash.update(chunk)
                outFile.write(chunk)
                writtenBytes += UInt64(chunk.count)
                onEvent(.progress(currentName: outName, written: writtenBytes, total: totalBytes))
                remaining -= UInt64(chunk.count)
            }
            let hex = hash.finalHex()
            // Only .nca entries are hash-named by content; .cert/.tik carry the
            // title id in their hex name, so a hash check there is meaningless.
            let ext = (e.name as NSString).pathExtension.lowercased()
            let isHashNamed = ext == "nca" && { () -> Bool in
                let stem = (e.name as NSString).deletingPathExtension.lowercased()
                return (stem.count == 32 || stem.count == 64) && stem.allSatisfy({ $0.isHexDigit })
            }()
            if isHashNamed {
                let ok = verifyName(e.name, hex)
                if ok { verified += 1 } else { mismatched += 1 }
                onEvent(.entryDone(name: outName, hash: hex, verified: ok))
            } else {
                onEvent(.entryCopied(name: outName))
            }
        }
    }
    var doneMsg = "Done: \(outputPath) — \(outEntries.count) files, \(verified) verified, \(mismatched) mismatched"
    if scanWarnings > 0 { doneMsg += ", ⚠️ \(scanWarnings) corruption warning(s) — re-download recommended" }
    onEvent(.done(summary: doneMsg))
}

// MARK: - Shared convenience for CLI & GUI

public enum NszOutput {
    /// Expected output file name for a given .nsz/.ncz input path (no conflict handling).
    public static func defaultOutputPath(forInput inputPath: String) throws -> String {
        let ext = (inputPath as NSString).pathExtension.lowercased()
        let baseName = (inputPath as NSString).lastPathComponent
        switch ext {
        case "nsz":  return String(baseName.dropLast(4)) + ".nsp"
        case "ncz":  return String(baseName.dropLast(4)) + ".nca"
        default:
            throw NczError.unsupportedCrypto("Unsupported input extension: .\(ext) (expected .nsz or .ncz)")
        }
    }

    /// Output path next to the input file, renaming by timestamp on conflict.
    public static func outputPathBeside(input inputPath: String) throws -> String {
        let dir = (inputPath as NSString).deletingLastPathComponent
        let name = try defaultOutputPath(forInput: inputPath)
        return resolveOutputPath(dir + "/" + name)
    }
}
