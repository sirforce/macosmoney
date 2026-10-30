import Foundation

/// Turns a bank's description ("AMAZON MKTPL*1A2B3C4D5", "PAYPAL *NETFLIX.COM 8005551234 CA")
/// into a payee name people recognize ("Amazon", "Netflix"). The bank's text is always kept on
/// the entry as well, so nothing is lost.
enum PayeeCleaner {
    /// Well-known merchants, matched anywhere in the description.
    private static let known: [(String, String)] = [
        ("AMAZON", "Amazon"), ("AMZN", "Amazon"), ("NETFLIX", "Netflix"), ("OPENAI", "OpenAI"), ("CHATGPT", "OpenAI"),
        ("MICROSOFT", "Microsoft"), ("APPLE.COM", "Apple"), ("YOUTUBE", "YouTube"), ("GOOGLE ONE", "Google One"),
        ("SPOTIFY", "Spotify"), ("UBER EATS", "Uber Eats"), ("UBER", "Uber"), ("LYFT", "Lyft"), ("STARBUCKS", "Starbucks"),
        ("CVS", "CVS"), ("WAL-MART", "Walmart"), ("WALMART", "Walmart"), ("TARGET", "Target"), ("COSTCO", "Costco"),
        ("DELTA AIR", "Delta Air Lines"), ("PATREON", "Patreon"), ("EBAY", "eBay"), ("HOME DEPOT", "The Home Depot"),
        ("LOWES", "Lowe's"), ("LOWE'S", "Lowe's"), ("WEGMANS", "Wegmans"), ("SAFEWAY", "Safeway"), ("CHICK-FIL-A", "Chick-fil-A"),
        ("MCDONALD", "McDonald's"), ("DOORDASH", "DoorDash"), ("GRUBHUB", "Grubhub"), ("VERIZON", "Verizon"),
        ("COMCAST", "Comcast"), ("XFINITY", "Xfinity"), ("SHEETZ", "Sheetz"), ("WAWA", "Wawa"), ("EXXON", "Exxon"),
        ("SHELL OIL", "Shell"), ("DUNKIN", "Dunkin'"), ("PANERA", "Panera Bread"), ("CHIPOTLE", "Chipotle"),
        ("ADOBE", "Adobe"), ("DROPBOX", "Dropbox"), ("GITHUB", "GitHub"), ("ZOOM.US", "Zoom"), ("HULU", "Hulu"),
        ("DISNEY PLUS", "Disney+"), ("AUDIBLE", "Audible"), ("KINDLE", "Kindle"), ("LULULEMON", "Lululemon"),
    ]

    /// Payment-processor prefixes in front of the real merchant ("SQ *COFFEE SHOP").
    private static let prefixes = ["PAYPAL *", "SQ *", "SQ*", "TST* ", "TST*", "IN *", "SP * ", "SP *", "PY *", "DD *", "CKO*", "BT*", "PP*", "SP "]

    static func clean(_ raw: String) -> String {
        let upper = BankRow.normalize(raw)
        if upper.contains("PAYMENT") && (upper.contains("THANK YOU") || upper.contains("AUTOPAY")) || upper.hasPrefix("BA ELECTRONIC PAYMENT") {
            return "Card Payment"
        }
        if upper.hasPrefix("INTEREST") { return "Interest" }
        if upper.contains("TRANSFER") || upper.hasPrefix("ACH DEPOSIT") || upper.hasPrefix("ACH WITHDRAWAL") { return "Transfer" }
        if upper.hasPrefix("AMZ") { return "Amazon" }
        for (needle, name) in known where upper.contains(needle) { return name }

        var s = upper
        for p in prefixes where s.hasPrefix(p) { s = String(s.dropFirst(p.count)); break }
        // "MERCHANT*ORDER123" → "MERCHANT"
        if let star = s.firstIndex(of: "*"), s.distance(from: s.startIndex, to: star) >= 3 { s = String(s[..<star]) }
        // Drop store numbers, phone numbers, long digit runs and trailing state codes.
        s = s.replacing(/#\s*\d+.*$/, with: "")
        s = s.replacing(/\b\d{3}[-.]?\d{3}[-.]?\d{4}\b/, with: "")
        s = s.replacing(/\d{5,}/, with: "")
        s = s.replacing(/\b\d{4,}\b/, with: "")
        s = s.replacing(/\s+\d{1,3}$/, with: "")
        s = s.replacing(/\s+[A-Z]{2}$/, with: "")
        s = s.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
        guard !s.isEmpty else { return raw.trimmingCharacters(in: .whitespaces) }
        return titleCase(s)
    }

    private static func titleCase(_ s: String) -> String {
        let small: Set<String> = ["OF", "AND", "THE", "AT", "FOR", "IN", "ON"]
        return s.split(separator: " ").enumerated().map { i, w in
            let word = String(w)
            if i > 0 && small.contains(word) { return word.lowercased() }
            if word.count <= 3 && !word.contains(where: \.isLetter) { return word }
            return word.prefix(1) + word.dropFirst().lowercased()
        }.joined(separator: " ")
    }
}
