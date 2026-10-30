import Foundation
import SwiftData

/// One row of a bank download that has been seen, so importing the same or an overlapping file
/// again never adds it twice. Rows stay recorded even if their transaction is later deleted, so a
/// deleted transaction doesn't come back on the next import.
@Model
final class BankRecord {
    var uuid: UUID = UUID()
    var accountUUID: UUID?
    /// Identity of the bank row (see `BankRow.fingerprint`).
    var fingerprint: String = ""
    /// The register entry this row became, or was matched to.
    var entryUUID: UUID?
    /// True when the row was matched to an entry that already existed (e.g. a payment entered in
    /// checking), rather than creating a new one.
    var matched: Bool = false
    var batchUUID: UUID?
    var date: Date = Date()
    var amountCents: Int = 0
    var rawDescription: String = ""
    var bankCategory: String = ""
    var created: Date = Date()

    init(fingerprint: String) { self.fingerprint = fingerprint }
}

/// One import of bank files into an account, so it can be reviewed or undone.
@Model
final class BankImportBatch {
    var uuid: UUID = UUID()
    var date: Date = Date()
    var accountUUID: UUID?
    var accountName: String = ""
    /// File names, newline-separated.
    var fileNames: String = ""
    var added: Int = 0
    var matched: Int = 0
    var skipped: Int = 0
    var firstDate: Date?
    var lastDate: Date?
    /// A "Balance Correction" entry made with this import, if any.
    var correctionEntryUUID: UUID?
    /// Opening-balance change made with this import (for a new account), undone with it.
    var openingChangeCents: Int = 0
    /// The account was reopened by this import.
    var reopenedAccount: Bool = false

    init() {}
}
