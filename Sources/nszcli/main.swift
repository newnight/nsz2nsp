import Foundation
import NszCore

// MARK: - CLI entry point

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("""
    nszcli — NSZ/NCZ decompressor (Swift, macOS)

    Usage:
      nszcli <file.nsz|file.ncz> [-o outputDir] [--no-scan] [--overwrite]

    Decompresses NSZ -> NSP (or NCZ -> NCA) and verifies each NCA
    against its hash-named filename when possible.

    If the output file already exists it is NOT overwritten; the new
    output gets a timestamp suffix, e.g. "Game 2026-09-04 22.46.40.nsp"
    (use --overwrite to replace it instead).

    Before decompression, the compressed stream is scanned for long
    zero runs (a corruption signature, e.g. from interrupted
    downloads). Warnings are printed if found; use --no-scan to skip.
    """)
    exit(1)
}

let inputPath = (args[1] as NSString).expandingTildeInPath
var outputDir: String? = nil
if let oFlag = args.firstIndex(of: "-o"), args.count > oFlag + 1 {
    outputDir = (args[oFlag + 1] as NSString).expandingTildeInPath
}
let skipScan = args.contains("--no-scan")
let overwrite = args.contains("--overwrite")

var wasRenamed = false
let outputPath: String
do {
    let defaultName = try NszOutput.defaultOutputPath(forInput: inputPath)
    let dir = outputDir ?? (inputPath as NSString).deletingLastPathComponent
    let raw = dir + "/" + defaultName
    if overwrite || !FileManager.default.fileExists(atPath: raw) {
        outputPath = raw
    } else {
        outputPath = resolveOutputPath(raw)
        wasRenamed = true
    }
} catch {
    fputs("ERROR: \(error)\n", stderr)
    exit(1)
}

// auto-create the output directory when -o is given
if let dir = outputDir {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
}
if wasRenamed {
    print("Output exists — renaming to: \((outputPath as NSString).lastPathComponent)")
}

let started = Date()
var lastHadProgress = false

func render(event: DecompressEvent) {
    switch event {
    case .scanWarning(let name, let runs):
        let totalMB = Double(runs.reduce(0) { $0 + $1.length }) / 1048576
        var msg = "⚠️  WARNING: \(name): \(runs.count) zero region(s) (total \(String(format: "%.2f", totalMB)) MB) inside the compressed stream:\n"
        for r in runs {
            msg += String(format: "     @0x%llx..0x%llx  (%.2f MB)\n", r.start, r.end, Double(r.length) / 1048576)
        }
        msg += "   The file is most likely CORRUPTED (e.g. interrupted download/transfer).\n"
        msg += "   Decompression will be attempted, but expect zstd errors after the first hole.\n"
        FileHandle.standardError.write(Data(msg.utf8))
    case .progress(let name, let written, let total):
        print("\r  \(name): \(Int(Double(written) / Double(total) * 100))%", terminator: "")
        lastHadProgress = true
    case .entryDone(let name, let hash, let verified):
        print("\r\(name) [\(hash.prefix(16))…] \(verified ? "VERIFIED" : "MISMATCH")   ")
        lastHadProgress = false
    case .entryCopied(let name):
        print("\(name) [copied]")
        lastHadProgress = false
    case .done(let summary):
        print(summary)
    case .entryStart:
        break
    }
}

do {
    try decompressContainer(inputPath: inputPath, outputPath: outputPath, skipScan: skipScan) { event in
        render(event: event)
    }
    print("Elapsed: \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
} catch {
    if lastHadProgress { print() }
    fputs("ERROR: \(error)\n", stderr)
    exit(1)
}
