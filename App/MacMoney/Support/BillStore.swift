import Foundation
import SwiftData

enum Recurrence {
    /// The occurrence after `day`. Monthly/yearly bills keep their anchor day (e.g. the 31st falls
    /// back to the 30th/28th in short months, then returns to the 31st).
    static func next(after day: Date, unit: RecurrenceUnit, every: Int, anchorDay: Int) -> Date? {
        let n = max(1, every)
        switch unit {
        case .once: return nil
        case .week: return Day.adding(.day, 7 * n, to: day)
        case .semimonth: return Day.adding(.day, 15, to: day)
        case .month: return clamp(Day.adding(.month, n, to: Day.startOfMonth(day)), anchorDay)
        case .year: return clamp(Day.adding(.year, n, to: Day.startOfMonth(day)), anchorDay)
        }
    }

    private static func clamp(_ firstOfMonth: Date, _ anchorDay: Int) -> Date {
        let days = Day.calendar.range(of: .day, in: .month, for: firstOfMonth)!.count
        let c = Day.calendar.dateComponents([.year, .month], from: firstOfMonth)
        return Day.date(year: c.year!, month: c.month!, day: min(max(1, anchorDay), days))
    }
}

extension Bill {
    var anchor: Int { anchorDay > 0 ? anchorDay : Day.calendar.component(.day, from: nextDue) }

    /// Upcoming occurrence dates from `nextDue` through `horizon`, honoring end date and count.
    func occurrences(through horizon: Date) -> [Date] {
        guard isActive else { return [] }
        var out: [Date] = []
        var d: Date? = nextDue
        var left = remainingOccurrences ?? Int.max
        while let day = d, day <= horizon, left > 0 {
            if let endDate, day > endDate { break }
            out.append(day)
            left -= 1
            d = Recurrence.next(after: day, unit: unit, every: every, anchorDay: anchor)
            if out.count > 2000 { break }
        }
        return out
    }

    /// Money-style "Pay to" label.
    var displayName: String {
        payee?.name ?? transferAccount.map { "Transfer to \($0.name)" } ?? "(no payee)"
    }

    var isDeposit: Bool { amountCents > 0 }
}

@MainActor
struct BillStore {
    let context: ModelContext

    /// A transaction-form draft pre-filled from the bill's next occurrence.
    func draft(for bill: Bill, date: Date? = nil) -> EntryDraft {
        var d = EntryDraft()
        if let t = bill.transferAccount {
            d.kind = .transfer
            d.transferAccountID = t.persistentModelID
            d.transferIncoming = bill.amountCents > 0
        } else {
            d.kind = bill.amountCents > 0 ? .deposit : .withdrawal
        }
        d.date = date ?? bill.nextDue
        d.payeeName = bill.payee?.name ?? ""
        d.categoryName = bill.category?.fullName ?? ""
        d.amount = Cents.plain(bill.amountCents)
        d.number = bill.number ?? ""
        d.memo = bill.memo ?? ""
        d.isFlagged = bill.flagOnEnter
        return d
    }

    /// Records the bill's next occurrence in its account register and advances the schedule.
    @discardableResult
    func enter(_ bill: Bill, as draft: EntryDraft) throws -> Entry {
        guard let account = bill.account else {
            throw CocoaError(.validationMissingMandatoryProperty, userInfo: [NSLocalizedDescriptionKey: "This bill has no account."])
        }
        let e = try EntryStore(context: context).save(draft, into: account, editing: nil)
        e.billUUID = bill.uuid
        e.billSeriesMoneyId = bill.moneySeriesId
        advance(bill)
        try context.save()
        return e
    }

    /// Moves the bill to its following occurrence without recording anything.
    func skip(_ bill: Bill) {
        advance(bill)
        try? context.save()
    }

    private func advance(_ bill: Bill) {
        if let left = bill.remainingOccurrences {
            bill.remainingOccurrences = max(0, left - 1)
            if left - 1 <= 0 { bill.isActive = false; return }
        }
        guard let next = Recurrence.next(after: bill.nextDue, unit: bill.unit, every: bill.every, anchorDay: bill.anchor) else {
            bill.isActive = false
            return
        }
        if let end = bill.endDate, next > end { bill.isActive = false; return }
        bill.nextDue = next
    }
}
