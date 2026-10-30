import Foundation

/// One transaction from a bank download, signed for the account it belongs to: money in is
/// positive, money out (purchases, withdrawals) negative.
struct BankRow: Equatable {
    var date: Date
    var amountCents: Int
    var description: String
    /// The bank's own id for the row, when it has one.
    var reference: String?
    var category: String?
    var memo: String?
    /// Account balance after this row, when the download includes it.
    var balanceCents: Int?

    /// Identifies the row across downloads. Uses the bank's reference when there is one, otherwise
    /// the date, amount and description. `occurrence` separates identical rows on the same day
    /// (two $10.59 charges), so they stay two.
    func fingerprint(occurrence: Int) -> String {
        let day = Self.iso.string(from: date)
        let base = reference.map { "ref:\($0)|\(day)|\(amountCents)" }
            ?? "\(day)|\(amountCents)|\(BankRow.normalize(description))"
        return occurrence == 0 ? base : "\(base)#\(occurrence)"
    }

    static func normalize(_ s: String) -> String {
        s.uppercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static let iso: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Day.calendar
        f.timeZone = Day.calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

/// A parsed bank download.
struct BankStatement {
    enum Format: String {
        case bofaCard = "Bank of America card"
        case bofaBank = "Bank of America bank"
        case chaseCard = "Chase card"
        case chaseBank = "Chase bank"
        case amex = "American Express card"
        case amexSavings = "American Express savings"
        case discover = "Discover"
        case ofx = "OFX / QFX"
        case generic = "CSV"
    }

    var format: Format
    var rows: [BankRow]
    /// Clues for matching the file to an account ("bofa:1234", "folder:chase visa").
    var hints: [String]
    var isCard: Bool

    var dateRange: ClosedRange<Date>? {
        guard let lo = rows.map(\.date).min(), let hi = rows.map(\.date).max() else { return nil }
        return lo...hi
    }

    /// The newest balance the file reports, if any.
    var latestBalance: (date: Date, cents: Int)? {
        rows.filter { $0.balanceCents != nil }.max { $0.date < $1.date }.map { ($0.date, $0.balanceCents!) }
    }

    /// Rows with their fingerprints. Identical rows get increasing occurrence numbers.
    var fingerprinted: [(row: BankRow, fingerprint: String)] {
        var seen: [String: Int] = [:]
        return rows.map { r in
            let base = r.fingerprint(occurrence: 0)
            let n = seen[base, default: 0]
            seen[base] = n + 1
            return (r, r.fingerprint(occurrence: n))
        }
    }
}

enum BankFormats {
    struct Failure: LocalizedError { var errorDescription: String? }

    static func read(_ url: URL) throws -> BankStatement {
        let ext = url.pathExtension.lowercased()
        var statement: BankStatement
        if ext == "xlsx" {
            statement = try parseTable(try XLSX.rows(url), fileName: url.lastPathComponent)
        } else {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                throw Failure(errorDescription: "The file isn't text.")
            }
            let head = text.prefix(4000).lowercased()
            if head.contains("<ofx>") || head.contains("ofxheader") {
                statement = try parseOFX(text)
            } else if head.contains("<table") && head.contains("discover") {
                statement = try parseDiscover(text)
            } else {
                statement = try parseTable(CSV.parse(text), fileName: url.lastPathComponent)
            }
        }
        statement.hints += fileHints(url)
        guard !statement.rows.isEmpty else { throw Failure(errorDescription: "No transactions found.") }
        return statement
    }

    /// Hints from the file name and the folder it's in.
    static func fileHints(_ url: URL) -> [String] {
        var hints: [String] = []
        let name = url.deletingPathExtension().lastPathComponent
        if let m = name.firstMatch(of: /^Chase(\d{4})_/) { hints.append("chase:\(m.1)") }
        if let m = name.firstMatch(of: /_(\d{4})$/) { hints.append("last4:\(m.1)") }
        let folder = url.deletingLastPathComponent().lastPathComponent
        if !folder.isEmpty { hints.append("folder:\(folder.lowercased())") }
        return hints
    }

    // MARK: Tables (CSV and XLSX)

    static func parseTable(_ table: [[String]], fileName: String = "") throws -> BankStatement {
        func norm(_ r: [String]) -> [String] { r.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } }
        // American Express savings: no header, "2026-10-28","Interest Payment",52.28
        if let first = table.first, first.count == 3, date(first[0]) != nil, Cents.parse(first[2]) != nil {
            let rows = table.compactMap { r -> BankRow? in
                guard r.count >= 3, let d = date(r[0]), let c = Cents.parse(r[2]) else { return nil }
                return BankRow(date: d, amountCents: c, description: r[1])
            }
            return BankStatement(format: .amexSavings, rows: rows, hints: [], isCard: false)
        }
        // Find the header row (downloads often start with a few summary lines).
        guard let h = table.firstIndex(where: { r in
            let n = norm(r)
            return n.contains { $0.contains("date") } && n.contains { $0 == "amount" || $0 == "debit" || $0.hasPrefix("debit") }
        }) else { throw Failure(errorDescription: "Not a recognized bank download.") }
        let header = norm(table[h])
        let body = table[(h + 1)...].filter { $0.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
        func col(_ names: String...) -> Int? { names.lazy.compactMap { n in header.firstIndex(of: n) }.first }
        func cell(_ r: [String], _ i: Int?) -> String { i.flatMap { r.indices.contains($0) ? r[$0].trimmingCharacters(in: .whitespacesAndNewlines) : nil } ?? "" }

        // Amex prints "Account Number XXXX-XXXXXX-12345" above the header in its spreadsheets.
        var hints: [String] = []
        for r in table[..<h] {
            if let i = r.firstIndex(where: { $0.lowercased().contains("account number") }), r.indices.contains(i + 1),
               let m = r[i + 1].firstMatch(of: /(\d{4,5})\s*$/) { hints.append("acct:\(m.1)") }
        }

        if header.starts(with: ["posted date", "reference number", "payee", "address", "amount"]) {
            let rows = body.compactMap { r -> BankRow? in
                guard let d = date(cell(r, 0)), let c = Cents.parse(cell(r, 4)) else { return nil }
                return BankRow(date: d, amountCents: c, description: cleanBofA(cell(r, 2), address: cell(r, 3)),
                               reference: cell(r, 1).nilIfBlank)
            }
            return BankStatement(format: .bofaCard, rows: rows, hints: hints, isCard: true)
        }
        if header.starts(with: ["transaction date", "post date", "description", "category", "type", "amount"]) {
            let rows = body.compactMap { r -> BankRow? in
                guard let d = date(cell(r, 0)), let c = Cents.parse(cell(r, 5)) else { return nil }
                return BankRow(date: d, amountCents: c, description: cell(r, 2), category: cell(r, 3).nilIfBlank, memo: cell(r, 6).nilIfBlank)
            }
            return BankStatement(format: .chaseCard, rows: rows, hints: hints, isCard: true)
        }
        if header.starts(with: ["details", "posting date", "description", "amount", "type", "balance"]) {
            let rows = body.compactMap { r -> BankRow? in
                guard let d = date(cell(r, 1)), let c = Cents.parse(cell(r, 3)) else { return nil }
                return BankRow(date: d, amountCents: c, description: cell(r, 2), reference: nil, balanceCents: Cents.parse(cell(r, 5)))
            }
            return BankStatement(format: .chaseBank, rows: rows, hints: hints, isCard: false)
        }
        if header.contains("description"), header.contains("amount"),
           header.contains("extended details") || header.contains("appears on your statement as") {
            // American Express: charges are positive in its downloads, so the sign is flipped.
            let ref = col("reference"), cat = col("category")
            let rows = body.compactMap { r -> BankRow? in
                guard let d = date(cell(r, col("date"))), let c = Cents.parse(cell(r, col("amount"))) else { return nil }
                let reference = cell(r, ref).trimmingCharacters(in: CharacterSet(charactersIn: "'")).nilIfBlank
                return BankRow(date: d, amountCents: -c, description: cell(r, col("description")),
                               reference: reference, category: cell(r, cat).nilIfBlank)
            }
            return BankStatement(format: .amex, rows: rows, hints: hints, isCard: true)
        }
        if header.starts(with: ["date", "description", "amount", "running bal."]) {
            let rows = body.compactMap { r -> BankRow? in
                guard let d = date(cell(r, 0)), let c = Cents.parse(cell(r, 2)) else { return nil }
                return BankRow(date: d, amountCents: c, description: cell(r, 1), balanceCents: Cents.parse(cell(r, 3)))
            }
            return BankStatement(format: .bofaBank, rows: rows, hints: hints, isCard: false)
        }

        // Anything else with recognizable columns.
        guard let dc = col("date", "transaction date", "posted date", "posting date", "trans. date"),
              let desc = col("description", "payee", "name", "merchant", "memo", "details") else {
            throw Failure(errorDescription: "Not a recognized bank download (no date or description column).")
        }
        let amount = col("amount", "transaction amount")
        let debit = header.firstIndex { $0.hasPrefix("debit") || $0 == "withdrawal" || $0 == "withdrawals" }
        let credit = header.firstIndex { $0.hasPrefix("credit") || $0 == "deposit" || $0 == "deposits" }
        let balance = col("balance", "running balance", "running bal.")
        let rows = body.compactMap { r -> BankRow? in
            guard let d = date(cell(r, dc)) else { return nil }
            let cents: Int?
            if let amount { cents = Cents.parse(cell(r, amount)) } else {
                let out = Cents.parse(cell(r, debit)).map { -abs($0) } ?? 0
                let into = Cents.parse(cell(r, credit)).map { abs($0) } ?? 0
                cents = (out == 0 && into == 0) ? nil : out + into
            }
            guard let cents else { return nil }
            return BankRow(date: d, amountCents: cents, description: cell(r, desc), balanceCents: Cents.parse(cell(r, balance)))
        }
        return BankStatement(format: .generic, rows: rows, hints: hints, isCard: false)
    }

    /// Bank of America repeats the city and state at the end of the payee; drop them.
    static func cleanBofA(_ payee: String, address: String) -> String {
        let parts = address.split(whereSeparator: \.isWhitespace).map(String.init)
        var p = payee.trimmingCharacters(in: .whitespaces)
        if let state = parts.last, state.count == 2 {
            let city = parts.dropLast().joined(separator: " ")
            for suffix in ["\(city) \(state)", "\(city)\(state)", "\(city.replacingOccurrences(of: " ", with: ""))\(state)", " \(state)"]
            where !suffix.trimmingCharacters(in: .whitespaces).isEmpty && p.uppercased().hasSuffix(suffix.uppercased()) {
                p = String(p.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        return p.isEmpty ? payee : p
    }

    // MARK: Discover (an HTML table saved as .xls)

    static func parseDiscover(_ html: String) throws -> BankStatement {
        let cells = htmlRows(html)
        var hints: [String] = []
        if let r = cells.first(where: { $0.first?.lowercased().contains("account ending in") == true }), r.count > 1 {
            hints.append("last4:\(r[1].suffix(4))")
        }
        // Date | Debit/Credit | Description | debit amount | credit amount | balance
        let rows = cells.compactMap { r -> BankRow? in
            guard r.count >= 6, let d = date(r[0]) else { return nil }
            let out = Cents.parse(r[3]).map { -abs($0) } ?? 0
            let into = Cents.parse(r[4]).map { abs($0) } ?? 0
            return BankRow(date: d, amountCents: out + into, description: r[2], balanceCents: Cents.parse(r[5]))
        }
        return BankStatement(format: .discover, rows: rows, hints: hints, isCard: false)
    }

    static func htmlRows(_ html: String) -> [[String]] {
        html.matches(of: /(?is)<tr[^>]*>(.*?)<\/tr>/).map { tr in
            String(tr.1).matches(of: /(?is)<t[dh][^>]*>(.*?)<\/t[dh]>/).map { td in
                decodeEntities(String(td.1).replacing(/<[^>]*>/, with: "")).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&nbsp;", with: " ")
    }

    // MARK: OFX / QFX

    static func parseOFX(_ text: String) throws -> BankStatement {
        func tag(_ name: String, in block: Substring) -> String? {
            guard let r = block.range(of: "<\(name)>", options: .caseInsensitive) else { return nil }
            let rest = block[r.upperBound...]
            let end = rest.firstIndex(where: { $0 == "<" || $0 == "\n" || $0 == "\r" }) ?? rest.endIndex
            return String(rest[..<end]).trimmingCharacters(in: .whitespaces).nilIfBlank
        }
        let whole = Substring(text)
        var hints: [String] = []
        if let id = tag("ACCTID", in: whole) { hints.append("last4:\(id.suffix(4))") }
        let isCard = text.range(of: "<CCSTMTRS>", options: .caseInsensitive) != nil
        var rows: [BankRow] = []
        var search = text.startIndex..<text.endIndex
        while let start = text.range(of: "<STMTTRN>", options: .caseInsensitive, range: search) {
            let end = text.range(of: "</STMTTRN>", options: .caseInsensitive, range: start.upperBound..<text.endIndex)?.lowerBound
                ?? text.range(of: "<STMTTRN>", options: .caseInsensitive, range: start.upperBound..<text.endIndex)?.lowerBound
                ?? text.endIndex
            let block = text[start.upperBound..<end]
            if let posted = tag("DTPOSTED", in: block), let d = date(String(posted.prefix(8))),
               let amt = tag("TRNAMT", in: block).flatMap(Cents.parse) {
                let name = tag("NAME", in: block) ?? tag("MEMO", in: block) ?? ""
                rows.append(BankRow(date: d, amountCents: amt, description: decodeEntities(name),
                                    reference: tag("FITID", in: block), memo: tag("MEMO", in: block).map(decodeEntities)))
            }
            search = end..<text.endIndex
        }
        return BankStatement(format: .ofx, rows: rows, hints: hints, isCard: isCard)
    }

    // MARK: Dates

    private static let dateFormats = ["MM/dd/yyyy", "M/d/yyyy", "yyyy-MM-dd", "MM/dd/yy", "M/d/yy", "yyyyMMdd", "MMM d, yyyy", "MMM dd, yyyy"]
    private static let formatters: [DateFormatter] = dateFormats.map { fmt in
        let f = DateFormatter()
        f.calendar = Day.calendar
        f.timeZone = Day.calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = fmt
        f.isLenient = false
        return f
    }

    /// Parses the date formats banks use, plus Excel serial day numbers. Returns a calendar day.
    static func date(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let n = Double(s), n > 20000, n < 80000 {
            // Excel serial date (days since 1899-12-30).
            return Day.adding(.day, Int(n), to: Day.date(year: 1899, month: 12, day: 30))
        }
        for f in formatters {
            if let d = f.date(from: s) {
                let c = Day.calendar.dateComponents([.year, .month, .day], from: d)
                guard let y = c.year, y > 1900 else { continue }
                return Day.date(year: y, month: c.month!, day: c.day!)
            }
        }
        return nil
    }
}
