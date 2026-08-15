//
//  XLSXExport.swift
//  TheJym
//
//  A minimal, dependency-free .xlsx (OOXML SpreadsheetML) writer — just
//  enough to produce a multi-sheet workbook Excel/Numbers can open: a
//  hand-rolled uncompressed ("stored") ZIP container (no external
//  compression library needed, since stored entries just need a CRC-32,
//  not actual deflate) plus the handful of XML parts a workbook needs.
//  Deliberately skips styles.xml/sharedStrings.xml — every string cell is
//  written as an inline string, which every reader tested against (Excel,
//  Numbers) accepts without a styles part being present at all.
//

import Foundation

/// One spreadsheet cell's value — decides whether it's written as a real
/// numeric cell (sortable/summable in Excel) or an inline string.
enum XLSXCell {
    case string(String)
    case number(Double)
    case blank

    static func int(_ n: Int) -> XLSXCell { .number(Double(n)) }
}

enum XLSXWriter {
    /// Builds a complete .xlsx file's bytes from a list of (sheet name,
    /// rows) pairs, in order — sheet name becomes the tab label.
    static func makeWorkbook(sheets: [(name: String, rows: [[XLSXCell]])]) -> Data {
        var entries: [(path: String, data: Data)] = []
        entries.append(("[Content_Types].xml", Data(contentTypesXML(sheetCount: sheets.count).utf8)))
        entries.append(("_rels/.rels", Data(rootRelsXML.utf8)))
        entries.append(("xl/workbook.xml", Data(workbookXML(sheets: sheets).utf8)))
        entries.append(("xl/_rels/workbook.xml.rels", Data(workbookRelsXML(sheetCount: sheets.count).utf8)))
        for (i, sheet) in sheets.enumerated() {
            entries.append(("xl/worksheets/sheet\(i + 1).xml", Data(sheetXML(rows: sheet.rows).utf8)))
        }
        return ZipWriter.archive(entries)
    }

    // MARK: - XML parts

    private static func contentTypesXML(sheetCount: Int) -> String {
        let overrides = (1...sheetCount).map {
            "<Override PartName=\"/xl/worksheets/sheet\($0).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\(overrides)</Types>
        """
    }

    private static let rootRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
    """

    private static func workbookXML(sheets: [(name: String, rows: [[XLSXCell]])]) -> String {
        let sheetTags = sheets.enumerated().map { i, sheet in
            "<sheet name=\"\(xmlEscape(sheet.name))\" sheetId=\"\(i + 1)\" r:id=\"rId\(i + 1)\"/>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>\(sheetTags)</sheets></workbook>
        """
    }

    private static func workbookRelsXML(sheetCount: Int) -> String {
        let rels = (1...sheetCount).map {
            "<Relationship Id=\"rId\($0)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0).xml\"/>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(rels)</Relationships>
        """
    }

    private static func sheetXML(rows: [[XLSXCell]]) -> String {
        var body = ""
        for (r, row) in rows.enumerated() {
            let rowNum = r + 1
            var cellsXML = ""
            for (c, cell) in row.enumerated() {
                let ref = "\(columnLetters(c))\(rowNum)"
                switch cell {
                case .blank:
                    continue
                case .number(let n):
                    cellsXML += "<c r=\"\(ref)\"><v>\(formatNumber(n))</v></c>"
                case .string(let s):
                    cellsXML += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xmlEscape(s))</t></is></c>"
                }
            }
            body += "<row r=\"\(rowNum)\">\(cellsXML)</row>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\(body)</sheetData></worksheet>
        """
    }

    // MARK: - Helpers

    /// 0-based column index -> spreadsheet letters (0->A, 25->Z, 26->AA, ...).
    private static func columnLetters(_ index: Int) -> String {
        var n = index
        var letters = ""
        repeat {
            letters = String(UnicodeScalar(UInt8(65 + n % 26))) + letters
            n = n / 26 - 1
        } while n >= 0
        return letters
    }

    /// Whole numbers print without a trailing ".0" (reads cleaner for
    /// reps/weights that happen to be integers); anything else keeps its
    /// full precision.
    private static func formatNumber(_ n: Double) -> String {
        if n == n.rounded(), abs(n) < 1e15 {
            return String(Int64(n))
        }
        return String(n)
    }

    private static func xmlEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(ch)
            }
        }
        return out
    }
}

/// Hand-rolled ZIP container using the "stored" (uncompressed) method —
/// avoids needing a deflate implementation, at the cost of a somewhat
/// larger file than a real compressor would produce. Fine at this app's
/// personal-history data scale.
private enum ZipWriter {
    static func archive(_ entries: [(path: String, data: Data)]) -> Data {
        var output = Data()
        var central = Data()
        let (dosTime, dosDate) = dosDateTime(for: .now)

        for entry in entries {
            let offset = UInt32(output.count)
            let nameBytes = Array(entry.path.utf8)
            let fileBytes = [UInt8](entry.data)
            let crc = crc32(fileBytes)
            let size = UInt32(fileBytes.count)

            output.append(le32(0x0403_4b50))   // local file header signature
            output.append(le16(20))            // version needed to extract
            output.append(le16(0))             // general purpose flag
            output.append(le16(0))             // compression method: stored
            output.append(le16(dosTime))
            output.append(le16(dosDate))
            output.append(le32(crc))
            output.append(le32(size))          // compressed size
            output.append(le32(size))          // uncompressed size
            output.append(le16(UInt16(nameBytes.count)))
            output.append(le16(0))             // extra field length
            output.append(contentsOf: nameBytes)
            output.append(contentsOf: fileBytes)

            central.append(le32(0x0201_4b50))  // central directory header signature
            central.append(le16(20))           // version made by
            central.append(le16(20))           // version needed to extract
            central.append(le16(0))            // general purpose flag
            central.append(le16(0))            // compression method
            central.append(le16(dosTime))
            central.append(le16(dosDate))
            central.append(le32(crc))
            central.append(le32(size))
            central.append(le32(size))
            central.append(le16(UInt16(nameBytes.count)))
            central.append(le16(0))            // extra field length
            central.append(le16(0))            // file comment length
            central.append(le16(0))            // disk number start
            central.append(le16(0))            // internal file attributes
            central.append(le32(0))            // external file attributes
            central.append(le32(offset))
            central.append(contentsOf: nameBytes)
        }

        let centralOffset = UInt32(output.count)
        output.append(central)

        output.append(le32(0x0605_4b50))       // end of central directory signature
        output.append(le16(0))                 // disk number
        output.append(le16(0))                 // disk with central directory
        output.append(le16(UInt16(entries.count)))
        output.append(le16(UInt16(entries.count)))
        output.append(le32(UInt32(central.count)))
        output.append(le32(centralOffset))
        output.append(le16(0))                 // comment length

        return output
    }

    private static func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff)]) }
    private static func le32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)])
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1 != 0) ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// MS-DOS date/time pair ZIP local/central headers store timestamps
    /// in — 2-second resolution, years since 1980.
    private static func dosDateTime(for date: Date) -> (time: UInt16, date: UInt16) {
        let comps = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        let year: Int = max(1980, comps.year ?? 1980)
        let month: Int = comps.month ?? 1
        let day: Int = comps.day ?? 1
        let hour: Int = comps.hour ?? 0
        let minute: Int = comps.minute ?? 0
        let second: Int = comps.second ?? 0

        let dateBits: Int = ((year - 1980) << 9) | (month << 5) | day
        let timeBits: Int = (hour << 11) | (minute << 5) | (second / 2)
        return (UInt16(timeBits), UInt16(dateBits))
    }
}
