import Foundation

/// Reads the first worksheet of an .xlsx file as rows of strings. Uses the system `unzip`, so no
/// third-party code is needed.
enum XLSX {
    struct Failure: LocalizedError { var errorDescription: String? }

    static func rows(_ url: URL) throws -> [[String]] {
        let strings = (try? unzip(url, "xl/sharedStrings.xml")).map(sharedStrings) ?? []
        let sheet = try unzip(url, "xl/worksheets/sheet1.xml")
        let parser = SheetParser(strings: strings)
        let xml = XMLParser(data: sheet)
        xml.delegate = parser
        guard xml.parse() else { throw Failure(errorDescription: "The spreadsheet couldn't be read.") }
        return parser.rows
    }

    private static func unzip(_ url: URL, _ member: String) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-p", url.path, member]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, !data.isEmpty else { throw Failure(errorDescription: "Not a readable .xlsx file.") }
        return data
    }

    private static func sharedStrings(_ data: Data) -> [String] {
        let p = StringsParser()
        let xml = XMLParser(data: data)
        xml.delegate = p
        xml.parse()
        return p.strings
    }

    private final class StringsParser: NSObject, XMLParserDelegate {
        var strings: [String] = []
        private var current = ""
        private var inText = false
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "si" { current = "" }
            if name == "t" { inText = true }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if inText { current += string } }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "t" { inText = false }
            if name == "si" { strings.append(current) }
        }
    }

    private final class SheetParser: NSObject, XMLParserDelegate {
        let strings: [String]
        var rows: [[String]] = []
        private var row: [String] = []
        private var column = 0
        private var type = ""
        private var value = ""
        private var capture = false
        init(strings: [String]) { self.strings = strings }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch name {
            case "row": row = []
            case "c":
                type = attributes["t"] ?? ""
                value = ""
                column = attributes["r"].map(Self.columnIndex) ?? row.count
            case "v", "t": capture = true
            default: break
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if capture { value += string } }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "v", "t": capture = false
            case "c":
                while row.count < column { row.append("") }
                row.append(type == "s" ? (Int(value).flatMap { strings.indices.contains($0) ? strings[$0] : nil } ?? "") : value)
            case "row": rows.append(row)
            default: break
            }
        }

        /// "C8" → 2
        static func columnIndex(_ ref: String) -> Int {
            ref.unicodeScalars.prefix { $0.properties.isAlphabetic }.reduce(0) { $0 * 26 + Int($1.value) - 64 } - 1
        }
    }
}
