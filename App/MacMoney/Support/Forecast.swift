import Foundation
import SwiftData

/// Cash-flow projection for one or more accounts.
///
/// Starting point is today's balance. Added on top:
///  - register entries already dated after today (bills you've entered ahead), and
///  - bill & deposit occurrences that are not yet in the register (from each bill's next due date).
/// A bill's next due date always lies past the occurrences already entered, so nothing is counted twice.
/// Overdue bills (due before today, not yet entered) are projected on today.
struct Forecast {
    enum Source { case actual, register, bill, overdueBill }

    struct Event: Identifiable {
        let id = UUID()
        let date: Date
        let amountCents: Int
        let payee: String
        let account: String
        let source: Source
        /// The register entry behind it (actual and entered-ahead events), for jumping to the register.
        var entryID: PersistentIdentifier?
        var accountID: PersistentIdentifier?
        var balanceCents = 0
    }

    struct Point: Identifiable {
        var id: Date { date }
        let date: Date
        let balanceCents: Int
    }

    let startDate: Date
    let startBalanceCents: Int
    let events: [Event]
    /// End-of-day balances from start through horizon (one per day that has activity, plus endpoints).
    let points: [Point]
    /// Actual end-of-day balances for the lookback period before today.
    let history: [Point]
    /// Actual transactions in the lookback period, with running balances.
    let pastEvents: [Event]
    let historyStart: Date

    var endBalanceCents: Int { points.last?.balanceCents ?? startBalanceCents }
    var lowPoint: Point? { points.min { $0.balanceCents < $1.balanceCents } }

    init(accounts: [Account], bills: [Bill], today: Date = Day.today, horizon: Date, historyFrom: Date? = nil) {
        let ids = Set(accounts.map(\.persistentModelID))
        startDate = today
        startBalanceCents = accounts.reduce(0) { $0 + $1.balance(asOf: today) }

        var events: [Event] = []
        for a in accounts {
            for e in a.entries ?? [] where e.date > today && e.date <= horizon && e.balanceEffectCents != 0 {
                events.append(Event(date: e.date, amountCents: e.balanceEffectCents, payee: e.payee?.name ?? e.categoryDisplay,
                                    account: a.name, source: .register, entryID: e.persistentModelID, accountID: a.persistentModelID))
            }
        }
        for b in bills where b.isActive {
            let fromAccount = b.account.map { ids.contains($0.persistentModelID) } ?? false
            let toAccount = b.transferAccount.map { ids.contains($0.persistentModelID) } ?? false
            guard fromAccount || toAccount else { continue }
            for d in b.occurrences(through: horizon) {
                let overdue = d < today
                let date = overdue ? today : d
                if fromAccount {
                    events.append(Event(date: date, amountCents: b.amountCents, payee: b.displayName,
                                        account: b.account?.name ?? "", source: overdue ? .overdueBill : .bill))
                }
                if toAccount {
                    events.append(Event(date: date, amountCents: -b.amountCents, payee: b.displayName,
                                        account: b.transferAccount?.name ?? "", source: overdue ? .overdueBill : .bill))
                }
            }
        }
        events.sort { ($0.date, $0.amountCents < 0 ? 0 : 1) < ($1.date, $1.amountCents < 0 ? 0 : 1) }

        var balance = startBalanceCents
        var points = [Point(date: today, balanceCents: balance)]
        for i in events.indices {
            balance += events[i].amountCents
            events[i].balanceCents = balance
            if points.last?.date == events[i].date { points.removeLast() }
            points.append(Point(date: events[i].date, balanceCents: balance))
        }
        if points.last?.date != horizon { points.append(Point(date: horizon, balanceCents: balance)) }
        self.events = events
        self.points = points

        // Actual balances for context.
        let lookbackStart = min(historyFrom ?? Day.adding(.month, -3, to: today), today)
        historyStart = lookbackStart
        var past: [Point] = []
        var pastEvents: [Event] = []
        let pastEntries = accounts.flatMap { a in (a.entries ?? []).map { (a, $0) } }
            .filter { $0.1.date >= lookbackStart && $0.1.date <= today && $0.1.balanceEffectCents != 0 }
            .sorted { ($0.1.date, $0.1.amountCents < 0 ? 0 : 1) < ($1.1.date, $1.1.amountCents < 0 ? 0 : 1) }
        var running = accounts.reduce(0) { $0 + $1.balance(asOf: Day.adding(.day, -1, to: lookbackStart)) }
        past.append(Point(date: lookbackStart, balanceCents: running))
        for (a, e) in pastEntries {
            running += e.balanceEffectCents
            pastEvents.append(Event(date: e.date, amountCents: e.balanceEffectCents, payee: e.payee?.name ?? e.categoryDisplay,
                                    account: a.name, source: .actual, entryID: e.persistentModelID,
                                    accountID: a.persistentModelID, balanceCents: running))
            if past.last?.date == e.date { past.removeLast() }
            past.append(Point(date: e.date, balanceCents: running))
        }
        if past.last?.date != today { past.append(Point(date: today, balanceCents: startBalanceCents)) }
        history = past
        self.pastEvents = pastEvents
    }
}
