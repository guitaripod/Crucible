import Foundation

/// Every requirement, in the order a person meets them and grouped into the four setup steps the screen shows.
package enum SportsRequirement: String, CaseIterable, Sendable {
    case owner
    case model
    case tools
    case thinking
    case context
    case search
    case agreement
    case libraries
    case on

    package enum Group: Int, CaseIterable, Sendable, Hashable {
        case plex
        case model
        case web
        case library
    }

    package var group: Group {
        switch self {
        case .owner: .plex
        case .model, .tools, .thinking, .context: .model
        case .search, .agreement: .web
        case .libraries, .on: .library
        }
    }

    /// Whether the owner settles it from the app rather than on the server.
    package var settledInApp: Bool {
        self == .agreement || self == .libraries || self == .on
    }
}

extension SportsCheck {
    /// Whether this unmet requirement is the owner's to settle with the app's own controls: one of the choices, or one that
    /// waits on them (search is tried only once the owner agrees). Agreeing is a choice only once a search engine is set,
    /// because until then there is nothing to agree to.
    package func settledInApp(in report: SportsReport) -> Bool {
        settledInApp(owner: report.owner, settings: report.settings)
    }

    package func settledInApp(owner: Bool, settings: SportsSettings) -> Bool {
        guard owner, state != .done else { return false }
        if requirement == .agreement && settings.destination == nil {
            return false
        }
        return requirement?.settledInApp == true || fix?.contains("in Crucible") == true
    }
}

/// One of the four setup steps: the checks of one group and where they stand together.
package struct SportsSetupStep: Equatable, Hashable, Sendable {
    package let group: SportsRequirement.Group
    package let number: Int
    package let checks: [SportsCheck]

    /// Done when every check is; failed when one failed; otherwise still to do.
    package var state: SportsCheck.State {
        if checks.allSatisfy({ $0.state == .done }) { return .done }
        return checks.contains { $0.state == .failed } ? .failed : .missing
    }

    /// The unmet checks of the step, in requirement order.
    package var open: [SportsCheck] { checks.filter { $0.state != .done } }
}

/// What the screen shows, decided once from the report and who is looking.
package enum SportsMode: Equatable, Sendable {
    /// Not Crucible Pro: an example of what it does, the results read-only, and the way to Pro.
    case notPro
    /// Someone the owner shares the server with: results and progress, nothing to change.
    case viewer
    /// The owner with requirements still open: the setup steps lead.
    case setup
    /// The owner with only the switch left.
    case onlySwitch
    /// The owner with everything ready.
    case ready
}

/// The report arranged for the screen: the four setup steps, the mode, the hero result and the results to list.
package struct SportsBoard: Equatable, Sendable {
    package let report: SportsReport

    package init(report: SportsReport) {
        self.report = report
    }

    /// The checks of each group in requirement order, skipping groups the server reported nothing for.
    package var groups: [(SportsRequirement.Group, [SportsCheck])] {
        steps.map { ($0.group, $0.checks) }
    }

    /// The setup steps, numbered in order, each with its checks.
    package var steps: [SportsSetupStep] {
        let known = report.checks.compactMap { check in check.requirement.map { (check, $0) } }
            .sorted { (SportsRequirement.allCases.firstIndex(of: $0.1) ?? 0) < (SportsRequirement.allCases.firstIndex(of: $1.1) ?? 0) }
        var number = 0
        return SportsRequirement.Group.allCases.compactMap { group in
            let checks = known.filter { $0.1.group == group }.map(\.0)
            guard !checks.isEmpty else { return nil }
            number += 1
            return SportsSetupStep(group: group, number: number, checks: checks)
        }
    }

    /// The first step with something left to do.
    package var firstOpenStep: SportsSetupStep? { steps.first { $0.state != .done } }

    package static func == (lhs: SportsBoard, rhs: SportsBoard) -> Bool { lhs.report == rhs.report }

    package var doneCount: Int { report.checks.filter { $0.state == .done }.count }
    package var total: Int { report.checks.count }

    /// The requirements still open, in order.
    package var open: [SportsCheck] { steps.flatMap(\.open) }

    /// The only thing between the owner and research is the switch.
    package var onlySwitchIsOff: Bool {
        open.map(\.id) == [SportsRequirement.on.rawValue]
    }

    package func mode(isPro: Bool) -> SportsMode {
        if !isPro { return .notPro }
        guard report.owner else { return .viewer }
        if open.isEmpty { return .ready }
        return onlySwitchIsOff ? .onlySwitch : .setup
    }

    package func count(_ state: String) -> Int { report.counts[state] ?? 0 }

    /// The items to list, the ones needing a look first, then by newest change.
    package var items: [SportsItem] {
        let weight: (String) -> Int = { state in
            switch state {
            case "attention": 0
            case "failed": 1
            default: 2
            }
        }
        return report.items.sorted { weight($0.state) != weight($1.state) ? weight($0.state) < weight($1.state) : $0.updated > $1.updated }
    }

    /// The items that need the owner: ones research could not identify, and ones it will try again.
    package var needingALook: [SportsItem] { items.filter { $0.state == "attention" || $0.state == "failed" } }

    /// How many files need the owner across the library, not only among the items sent: the server's counts, or the items
    /// when an older server counts less.
    package var needingALookCount: Int { max(count("attention") + count("failed"), needingALook.count) }

    /// The newest file research matched, to show off what it did.
    package var hero: SportsItem? {
        report.items.filter { $0.state == "matched" && $0.detail != nil }.max { $0.updated < $1.updated }
    }
}

/// How a researched file is named in lists.
package enum SportsItemLabel {
    /// The title research gave it when it has one (matched, or edited by the owner since), else the file's own name.
    package static func title(_ item: SportsItem) -> String {
        switch item.state {
        case "matched" where !item.title.isEmpty, "edited" where !item.title.isEmpty: item.title
        default: item.fileName
        }
    }
}
