import XCTest
import SwiftData
@testable import MacMoney

@MainActor
final class BankImportTests: XCTestCase {
    private var ctx: ModelContext!
    private var dir: URL!

    override func setUpWithError() throws {
        let container = try ModelContainer(for: Schema(Schema1.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        ctx = ModelContext(container)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("BankImportTests-\(UUID().uuidString)/Sample Card")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

    private func file(_ name: String, _ text: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private let bofa = """
    Posted Date,Reference Number,Payee,Address,Amount
    10/15/2026,111,"COFFEE HOUSE #12 SPRINGFIELD IL","SPRINGFIELD   IL ",-4.50
    10/14/2026,222,"AMAZON MKTPL*AB12CD SEATTLE WA","SEATTLE       WA ",-23.31
    10/14/2026,222,"AMAZON MKTPL*AB12CD SEATTLE WA","SEATTLE       WA ",23.31
    10/10/2026,333,"PAYMENT - THANK YOU","",500.00
    """

    private func account(_ name: String = "Sample Card", kind: AccountKind = .creditCard) -> Account {
        let a = Account(name: name, kind: kind)
        ctx.insert(a)
        return a
    }

    private func importFiles(_ urls: [URL], into a: Account, balance: BankImporter.BalanceCheck? = nil) throws -> BankImportBatch {
        let importer = BankImporter(context: ctx)
        let files = try urls.map { ($0, try BankFormats.read($0)) }
        return try importer.apply(importer.plan(files, into: a), to: a, balance: balance)
    }

    private func entries(_ a: Account) -> [Entry] { (a.entries ?? []).sorted { $0.date < $1.date } }

    // MARK: Formats

    func testReadsBankOfAmericaCard() throws {
        let s = try BankFormats.read(try file("October2026_1234.csv", bofa))
        XCTAssertEqual(s.format, .bofaCard)
        XCTAssertEqual(s.rows.count, 4)
        XCTAssertEqual(s.rows[0].description, "COFFEE HOUSE #12", "city and state removed")
        XCTAssertEqual(s.rows[0].amountCents, -450)
        XCTAssertTrue(s.hints.contains("last4:1234"))
        XCTAssertTrue(s.hints.contains("folder:sample card"))
    }

    func testReadsChaseAmexAndSavings() throws {
        let chase = try BankFormats.read(try file("Chase1234_Activity_20261030.csv", """
        Transaction Date,Post Date,Description,Category,Type,Amount,Memo
        10/21/2026,10/21/2026,GOOGLE *YouTube TV,Bills & Utilities,Sale,-10.59,
        10/21/2026,10/21/2026,GOOGLE *YouTube TV,Bills & Utilities,Sale,-10.59,
        10/26/2026,10/26/2026,Payment Thank You - Bill,,Payment,118.16,
        """))
        XCTAssertEqual(chase.format, .chaseCard)
        XCTAssertEqual(chase.rows.first?.category, "Bills & Utilities")
        XCTAssertTrue(chase.hints.contains("chase:1234"))
        let fps = chase.fingerprinted.map(\.fingerprint)
        XCTAssertEqual(Set(fps).count, 3, "identical same-day charges stay distinct")

        let amex = try BankFormats.read(try file("activity.csv", """
        Date,Description,Amount,Extended Details,Appears On Your Statement As,Address,City/State,Zip Code,Country,Reference,Category
        09/29/2026,STREAMING SERVICE,49.99,"DIGITAL GOODS
        MORE DETAIL",STREAMING SERVICE,1 MAIN ST,"TOWN
        ST",00000,UNITED STATES,'990000000000000001',Business Services-Internet Services
        10/04/2026,ONLINE PAYMENT - THANK YOU,-49.99,,,,,,,'990000000000000002',
        """))
        XCTAssertEqual(amex.format, .amex)
        XCTAssertEqual(amex.rows.map(\.amountCents), [-4999, 4999], "Amex charges are positive in the file")
        XCTAssertEqual(amex.rows[0].reference, "990000000000000001")

        let savings = try BankFormats.read(try file("transactions.CSV", """
        2026-10-28,"Interest Payment",52.28
        2026-06-18,"Internet transfer from CHECKING",10000.0
        2026-04-14,"Internet transfer to CHECKING",-6000.0
        """))
        XCTAssertEqual(savings.format, .amexSavings)
        XCTAssertEqual(savings.rows.map(\.amountCents), [5228, 1_000_000, -600_000])
    }

    func testReadsDiscoverHTMLAndOFX() throws {
        let discover = try BankFormats.read(try file("Statement.xls", """
        <table border=1><tr><td colspan=2><strong>Discover Account Activity</strong></td></tr></table>\
        <table><tr><td colspan=2><strong>Account Ending in</strong></td><td>9876</td></tr></table>\
        <table><tr><td>Transaction Date</td><td>Transaction Type</td><td>Transaction Description</td><td>Debit</td><td>Credit</td><td>Balance</td></tr>\
        <tr><td>09/30/2026</td><td>Credit</td><td>Interest Paid</td><td></td><td>$12.34</td><td>$5,000.00</td></tr>\
        <tr><td>09/19/2025</td><td>Debit</td><td>ACH Withdrawal</td><td>$500.00</td><td></td><td>$4,000.00</td></tr></table>
        """))
        XCTAssertEqual(discover.format, .discover)
        XCTAssertEqual(discover.rows.map(\.amountCents), [1234, -50_000])
        XCTAssertEqual(discover.latestBalance?.cents, 500_000)
        XCTAssertTrue(discover.hints.contains("last4:9876"))

        let ofx = try BankFormats.read(try file("download.qfx", """
        OFXHEADER:100
        <OFX><CREDITCARDMSGSRSV1><CCSTMTTRNRS><CCSTMTRS><CCACCTFROM><ACCTID>4111222233334444</CCACCTFROM>
        <BANKTRANLIST><STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20261012120000<TRNAMT>-42.10<FITID>A1<NAME>HARDWARE STORE</STMTTRN>
        <STMTTRN><TRNTYPE>CREDIT<DTPOSTED>20261015<TRNAMT>100.00<FITID>A2<NAME>PAYMENT</STMTTRN></BANKTRANLIST></CCSTMTRS>
        """))
        XCTAssertEqual(ofx.format, .ofx)
        XCTAssertTrue(ofx.isCard)
        XCTAssertEqual(ofx.rows.map(\.amountCents), [-4210, 10000])
        XCTAssertEqual(ofx.rows.first?.reference, "A1")
        XCTAssertTrue(ofx.hints.contains("last4:4444"))
    }

    func testPayeeCleaner() {
        XCTAssertEqual(PayeeCleaner.clean("AMAZON MKTPL*1A2B3C4D5"), "Amazon")
        XCTAssertEqual(PayeeCleaner.clean("PAYPAL *NETFLIX.COM 8005551234"), "Netflix")
        XCTAssertEqual(PayeeCleaner.clean("PAYMENT - THANK YOU"), "Card Payment")
        XCTAssertEqual(PayeeCleaner.clean("IN *DOG DAYS OF SUMMER"), "Dog Days of Summer")
        XCTAssertEqual(PayeeCleaner.clean("COFFEE HOUSE #12"), "Coffee House")
        XCTAssertEqual(PayeeCleaner.clean("ZIPS CLEANERS 104"), "Zips Cleaners")
        XCTAssertEqual(PayeeCleaner.clean("Internet transfer from CHECKING account XXXXX1234"), "Transfer")
        XCTAssertEqual(PayeeCleaner.clean("AMZ*SELLER"), "Amazon")
    }

    // MARK: Importing

    func testReimportAddsNothingAndKeepsEdits() throws {
        let a = account()
        let url = try file("October2026_1234.csv", bofa)
        let first = try importFiles([url], into: a)
        XCTAssertEqual(first.added, 4)
        XCTAssertEqual(entries(a).filter { $0.payee?.name == "Amazon" }.count, 2, "charge and refund share a reference but differ in amount")

        // Tag one, delete another, then import the same file again.
        let coffee = entries(a).first { $0.amountCents == -450 }!
        coffee.memo = "Client meeting"
        coffee.isPersonal = false
        let payment = entries(a).first { $0.amountCents == 50000 }!
        ctx.delete(payment)
        try ctx.save()

        let again = try importFiles([url], into: a)
        XCTAssertEqual(again.added, 0)
        XCTAssertEqual(again.skipped, 4)
        XCTAssertEqual(entries(a).count, 3, "the deleted payment doesn't come back")
        XCTAssertEqual(coffee.memo, "Client meeting")
    }

    func testOverlappingFilesOnlyAddWhatsNew() throws {
        let a = account()
        let older = try file("current_1234.csv", """
        Posted Date,Reference Number,Payee,Address,Amount
        10/15/2026,111,"COFFEE HOUSE #12 SPRINGFIELD IL","SPRINGFIELD   IL ",-4.50
        """)
        try importFiles([older], into: a)
        let batch = try importFiles([try file("October2026_1234.csv", bofa)], into: a)
        XCTAssertEqual(batch.added, 3)
        XCTAssertEqual(batch.skipped, 1)
        XCTAssertEqual(entries(a).count, 4)
    }

    func testPaymentMatchesExistingEntryInsteadOfDuplicating() throws {
        let a = account()
        // A payment already in the account (e.g. a transfer from checking entered in Money).
        let existing = Entry(account: a, date: Day.date(year: 2026, month: 10, day: 8), amountCents: 50000)
        ctx.insert(existing)
        try ctx.save()
        let batch = try importFiles([try file("October2026_1234.csv", bofa)], into: a)
        XCTAssertEqual(batch.matched, 1)
        XCTAssertEqual(batch.added, 3)
        XCTAssertEqual(entries(a).filter { $0.amountCents == 50000 }.count, 1)
        XCTAssertEqual(existing.status, .cleared)
        XCTAssertEqual(existing.bankDescription, "PAYMENT - THANK YOU")
    }

    func testBalanceCorrectionAndUndo() throws {
        let a = account()
        let old = Entry(account: a, date: Day.date(year: 2020, month: 1, day: 1), amountCents: 640_000_00)   // payments only
        ctx.insert(old)
        try ctx.save()
        let check = BankImporter.BalanceCheck(date: Day.date(year: 2026, month: 10, day: 15), cents: -1_234_56)
        let batch = try importFiles([try file("October2026_1234.csv", bofa)], into: a, balance: check)
        let balance = a.openingBalanceCents + entries(a).reduce(0) { $0 + $1.balanceEffectCents }
        XCTAssertEqual(balance, -1_234_56)
        XCTAssertNotNil(batch.correctionEntryUUID)
        XCTAssertTrue(entries(a).contains { $0.payee?.name == "Balance Correction" && $0.status == .reconciled })

        try BankImporter(context: ctx).undo(batch)
        XCTAssertEqual(entries(a).map(\.amountCents), [640_000_00])
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<BankRecord>()), 0, "the files can be imported again")
    }

    func testNewAccountGetsOpeningBalanceAndClosedAccountReopens() throws {
        let a = account("Old Savings", kind: .bank)
        a.isClosed = true
        a.moneyId = 42
        let url = try file("transactions.CSV", "2026-10-28,\"Interest Payment\",52.28\n")
        let batch = try importFiles([url], into: a, balance: .init(date: Day.date(year: 2026, month: 10, day: 28), cents: 10_052_28))
        XCTAssertFalse(a.isClosed)
        XCTAssertEqual(a.closedOverride, false, "stays open after a Money re-import")
        XCTAssertEqual(a.openingBalanceCents, 10_000_00)
        XCTAssertNil(batch.correctionEntryUUID)
        try BankImporter(context: ctx).undo(batch)
        XCTAssertTrue(a.isClosed)
        XCTAssertNil(a.closedOverride)
        XCTAssertEqual(a.openingBalanceCents, 0)
    }

    func testSuggestsAccountFromHintsThenFolder() throws {
        let card = account("Sample Card")
        let other = account("Something Else")
        let s = try BankFormats.read(try file("October2026_1234.csv", bofa))
        XCTAssertEqual(BankImporter.suggestedAccount(for: s, in: [other, card]), card, "folder name matches")
        other.importHints = "last4:1234"
        XCTAssertEqual(BankImporter.suggestedAccount(for: s, in: [card, other]), other, "remembered file clues win")
    }

    /// Optional: dry-run every file in a real downloads folder (set TEST_RUNNER_MACMONEY_BANK_FOLDER).
    func testRealDownloadsFolder() throws {
        guard let path = ProcessInfo.processInfo.environment["MACMONEY_BANK_FOLDER"] else { throw XCTSkip("No bank folder set") }
        let urls = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { !$0.hasDirectoryPath && $0.lastPathComponent != ".DS_Store" }
        var byFolder: [String: [(URL, BankStatement)]] = [:]
        for u in urls {
            let s = try BankFormats.read(u)
            byFolder[u.deletingLastPathComponent().lastPathComponent, default: []].append((u, s))
        }
        for (folder, files) in byFolder.sorted(by: { $0.key < $1.key }) {
            let plans = BankImporter(context: ctx).plan(files.map { (url: $0.0, statement: $0.1) }, into: nil)
            let new = plans.reduce(0) { $0 + $1.newRows.count }, dup = plans.reduce(0) { $0 + $1.duplicates }
            print("BANKFOLDER \(folder): \(files.map(\.1.format.rawValue).first!) files=\(files.count) new=\(new) repeats=\(dup)")
            XCTAssertGreaterThan(new, 0)
            let names = Dictionary(grouping: plans.flatMap(\.newRows).map { PayeeCleaner.clean($0.row.description) }, by: { $0 })
            print("BANKPAYEES \(folder): \(names.count) payees: " + names.sorted { $0.value.count > $1.value.count }.prefix(60).map { "\($0.key)(\($0.value.count))" }.joined(separator: ", "))
        }
    }
}
