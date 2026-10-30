import Foundation
import SwiftData

/// Cash-flow projection for one or more accounts.
///
/// Starting point is today's balance. Added on top:
///  - register entries already dated after today (bills you've entered ahead), and
///  - bill & deposit occurrences that are not yet in the register (from each bill's next due date).
/// A bill's next due date always lies past the occurrences already entered, so nothing is counted twice.
/// Overdue bills (due before today, not yet entered) are projected on today.
///
/// A what-if scenario's adjustments add one-time and recurring amounts, and change or stop bills
/// from a date; anything the scenario adds or changes is marked `.scenario`.
struct Forecast {
    enum Source { case actual, register, bill, overdueBill, scenario }

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

    init(accounts: [Account], bills: [Bill], today: Date = Day.today, horizon: Date, historyFrom: Date? = nil,
         adjustments: [ScenarioAdjustment] = []) {
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
        let stops = Dictionary(adjustments.filter { $0.kind == .stopBill }.compactMap { a in a.billUUID.map { ($0, a.startDate) } },
                               uniquingKeysWith: min)
        let changes = Dictionary(grouping: adjustments.filter { $0.kind == .changeBill && $0.billUUID != nil }, by: { $0.billUUID! })
            .mapValues { $0.sorted { $0.startDate < $1.startDate } }
        for b in bills where b.isActive {
            let fromAccount = b.account.map { ids.contains($0.persistentModelID) } ?? false
            let toAccount = b.transferAccount.map { ids.contains($0.persistentModelID) } ?? false
            guard fromAccount || toAccount else { continue }
            for d in b.occurrences(through: horizon) {
                if let stop = stops[b.uuid], d >= stop { break }
                let overdue = d < today
                let date = overdue ? today : d
                // The latest change that has started by this occurrence wins.
                let change = changes[b.uuid]?.last { $0.startDate <= d }
                let amount = change?.amountCents ?? b.amountCents
                let source: Source = change != nil ? .scenario : (overdue ? .overdueBill : .bill)
                if fromAccount {
                    events.append(Event(date: date, amountCents: amount, payee: b.displayName,
                                        account: b.account?.name ?? "", source: source))
                }
                if toAccount {
                    events.append(Event(date: date, amountCents: -amount, payee: b.displayName,
                                        account: b.transferAccount?.name ?? "", source: source))
                }
            }
        }
        let byUUID = Dictionary(accounts.map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        for a in adjustments where a.kind == .oneTime || a.kind == .recurring {
            guard let id = a.accountUUID, let account = byUUID[id], a.amountCents != 0 else { continue }
            for d in a.occurrences(through: horizon) where d >= today {
                events.append(Event(date: d, amountCents: a.amountCents, payee: a.name.isEmpty ? "What-if" : a.name,
                                    account: account.name, source: .scenario, accountID: account.persistentModelID))
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
