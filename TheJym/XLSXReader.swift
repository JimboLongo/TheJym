//
//  XLSXReader.swift
//  TheJym
//
//  Minimal, dependency-free .xlsx reader: an .xlsx is a ZIP archive of XML
//  parts. This unzips just enough (via Apple's Compression framework for
//  DEFLATE) to read the first worksheet's cells, resolving shared-string and
//  inline-string cells to plain text, and leaving numeric/date cells as their
//  raw number (Excel stores dates as day-counts since Dec 30, 1899 — the same
//  serial numbers ImportEngine already knows how to recover from CSV).
//

import Foundation
import Compression

enum XLSXReader {
    /// Reads the first worksheet as rows of plain-text cell values, in
    /// column order (skipped/blank cells become "").
    static func readFirstSheetAsRows(data: Data) -> [[String]]? {
        guard let zip = MiniZip(data: data) else { return nil }

        var sharedStrings: [String] = []
        if let ssData = zip.data(for: "xl/sharedStrings.xml") {
            let parser = XMLParser(data: ssData)
            let delegate = SharedStringsXMLDelegate()
            parser.delegate = delegate
            parser.parse()
            sharedStrings = delegate.strings
        }

        guard let sheetName = zip.fileNames
            .filter({ $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") })
            .sorted()
            .first,
            let sheetData = zip.data(for: sheetName)
        else { return nil }

        let parser = XMLParser(data: sheetData)
        let delegate = WorksheetXMLDelegate(sharedStrings: sharedStrings)
        parser.delegate = delegate
        parser.parse()
        return delegate.rows
    }
}

// MARK: - Shared strings (xl/sharedStrings.xml)

private final class SharedStringsXMLDelegate: NSObject, XMLParserDelegate {
    var strings: [String] = []
    private var currentSI: String?
    private var insideT = false
    private var currentText = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
               qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "si" {
            currentSI = ""
        } else if elementName == "t" {
            insideT = true
            currentText = ""
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideT { currentText += string }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "t" {
            insideT = false
            currentSI = (currentSI ?? "") + currentText
        } else if elementName == "si" {
            strings.append(currentSI ?? "")
            currentSI = nil
        }
    }
}

// MARK: - Worksheet (xl/worksheets/sheetN.xml)

private final class WorksheetXMLDelegate: NSObject, XMLParserDelegate {
    let sharedStrings: [String]
    var rows: [[String]] = []

    private var currentRowCells: [Int: String] = [:]
    private var maxColInRow = -1
    private var currentCellRef: String?
    private var currentCellType: String?
    private var insideValue = false
    private var insideInlineText = false
    private var currentValueText = ""

    init(sharedStrings: [String]) { self.sharedStrings = sharedStrings }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
               qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "row":
            currentRowCells = [:]
            maxColInRow = -1
        case "c":
            currentCellRef = attributeDict["r"]
            currentCellType = attributeDict["t"]
        case "v":
            insideValue = true
            currentValueText = ""
        case "t":
            insideInlineText = true
            currentValueText = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideValue || insideInlineText { currentValueText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "v":
            insideValue = false
            recordCell(rawValue: currentValueText)
        case "t":
            if insideInlineText {
                insideInlineText = false
                recordCell(rawValue: currentValueText)
            }
        case "row":
            var rowArray = [String](repeating: "", count: max(maxColInRow + 1, 0))
            for (col, val) in currentRowCells where col < rowArray.count { rowArray[col] = val }
            rows.append(rowArray)
        default:
            break
        }
    }

    private func recordCell(rawValue: String) {
        guard let ref = currentCellRef else { return }
        let col = WorksheetXMLDelegate.columnIndex(from: ref)
        maxColInRow = max(maxColInRow, col)
        if currentCellType == "s", let idx = Int(rawValue), idx >= 0, idx < sharedStrings.count {
            currentRowCells[col] = sharedStrings[idx]
        } else {
            currentRowCells[col] = rawValue
        }
    }

    /// "C12" -> 2 (0-based column index).
    private static func columnIndex(from cellRef: String) -> Int {
        var index = 0
        for ch in cellRef {
            guard ch.isLetter, let ascii = ch.asciiValue else { break }
            index = index * 26 + Int(ascii - 64)   // 'A' = 65
        }
        return index - 1
    }
}

// MARK: - Minimal ZIP reader (just enough: list entries, extract by name)

private struct MiniZipEntry {
    let name: String
    let compressionMethod: Int
    let compressedSize: Int
    let uncompressedSize: Int
    let localHeaderOffset: Int
}

private struct MiniZip {
    let bytes: [UInt8]
    let entries: [MiniZipEntry]

    init?(data: Data) {
        let bytes = [UInt8](data)
        guard let eocdOffset = MiniZip.findEOCD(bytes), eocdOffset + 20 <= bytes.count else { return nil }
        let totalEntries = MiniZip.u16(bytes, eocdOffset + 10)
        let cdOffset = MiniZip.u32(bytes, eocdOffset + 16)

        var entries: [MiniZipEntry] = []
        var offset = cdOffset
        for _ in 0..<totalEntries {
            guard offset + 46 <= bytes.count, MiniZip.u32(bytes, offset) == 0x02014b50 else { break }
            let compressionMethod = MiniZip.u16(bytes, offset + 10)
            let compressedSize = MiniZip.u32(bytes, offset + 20)
            let uncompressedSize = MiniZip.u32(bytes, offset + 24)
            let nameLen = MiniZip.u16(bytes, offset + 28)
            let extraLen = MiniZip.u16(bytes, offset + 30)
            let commentLen = MiniZip.u16(bytes, offset + 32)
            let localHeaderOffset = MiniZip.u32(bytes, offset + 42)
            let nameStart = offset + 46
            guard nameStart + nameLen <= bytes.count else { break }
            let name = String(bytes: bytes[nameStart..<(nameStart + nameLen)], encoding: .utf8) ?? ""
            entries.append(MiniZipEntry(name: name, compressionMethod: compressionMethod,
                                        compressedSize: compressedSize, uncompressedSize: uncompressedSize,
                                        localHeaderOffset: localHeaderOffset))
            offset = nameStart + nameLen + extraLen + commentLen
        }
        guard !entries.isEmpty else { return nil }
        self.bytes = bytes
        self.entries = entries
    }

    var fileNames: [String] { entries.map(\.name) }

    func data(for name: String) -> Data? {
        guard let entry = entries.first(where: { $0.name == name }) else { return nil }
        let lh = entry.localHeaderOffset
        guard lh + 30 <= bytes.count, MiniZip.u32(bytes, lh) == 0x04034b50 else { return nil }
        let nameLen = MiniZip.u16(bytes, lh + 26)
        let extraLen = MiniZip.u16(bytes, lh + 28)
        let dataStart = lh + 30 + nameLen + extraLen
        guard dataStart + entry.compressedSize <= bytes.count else { return nil }
        let compressedBytes = Array(bytes[dataStart..<(dataStart + entry.compressedSize)])

        switch entry.compressionMethod {
        case 0: return Data(compressedBytes)
        case 8: return MiniZip.inflate(compressedBytes, expectedSize: entry.uncompressedSize)
        default: return nil
        }
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
    }
    private static func u32(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8) | (Int(bytes[offset + 2]) << 16) | (Int(bytes[offset + 3]) << 24)
    }

    /// The End Of Central Directory record's signature, searched backward
    /// from the end (it may be followed by a variable-length comment).
    private static func findEOCD(_ bytes: [UInt8]) -> Int? {
        let searchStart = max(0, bytes.count - 22 - 65536)
        var i = bytes.count - 22
        while i >= searchStart {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4B, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 {
                return i
            }
            i -= 1
        }
        return nil
    }

    /// ZIP's "deflated" method is raw DEFLATE (RFC 1951, no zlib/gzip
    /// wrapper) — which is what Apple's COMPRESSION_ZLIB algorithm expects.
    private static func inflate(_ compressed: [UInt8], expectedSize: Int) -> Data? {
        guard expectedSize > 0 else { return Data() }
        var destBuffer = [UInt8](repeating: 0, count: expectedSize)
        let decodedSize = compressed.withUnsafeBufferPointer { srcPtr -> Int in
            destBuffer.withUnsafeMutableBufferPointer { destPtr -> Int in
                compression_decode_buffer(destPtr.baseAddress!, expectedSize,
                                          srcPtr.baseAddress!, compressed.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard decodedSize == expectedSize else { return nil }
        return Data(destBuffer)
    }
}
