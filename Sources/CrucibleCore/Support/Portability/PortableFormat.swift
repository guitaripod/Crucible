import Foundation

/// The three Foundation formatters Linux lacks (`RelativeDateTimeFormatter`, `ListFormatter`, `DateComponentsFormatter`),
/// behind one surface: the formatters themselves on Apple platforms, where Crucible still supports iOS 17, and the
/// `FormatStyle` equivalents of swift-foundation on Linux.
package enum PortableFormat {
    package enum Width: Sendable { case full, short, abbreviated }

    /// `date` relative to `reference`: "Yesterday", "in 2 hours", "5 days ago".
    package static func relative(_ date: Date, to reference: Date, width: Width, named: Bool = false,
                                 beginningOfSentence: Bool = false, locale: Locale? = nil) -> String {
        #if canImport(Darwin)
        let formatter = RelativeDateTimeFormatter()
        if let locale { formatter.locale = locale }
        formatter.dateTimeStyle = named ? .named : .numeric
        formatter.unitsStyle = switch width {
        case .full: .full
        case .short: .short
        case .abbreviated: .abbreviated
        }
        if beginningOfSentence { formatter.formattingContext = .beginningOfSentence }
        return formatter.localizedString(for: date, relativeTo: reference)
        #else
        let units: Date.RelativeFormatStyle.UnitsStyle = switch width {
        case .full: .wide
        case .short: .narrow
        case .abbreviated: .abbreviated
        }
        return Date.AnchoredRelativeFormatStyle(
            anchor: date,
            presentation: named ? .named : .numeric,
            unitsStyle: units,
            locale: locale ?? Formatters.displayLocale,
            calendar: .current,
            capitalizationContext: beginningOfSentence ? .beginningOfSentence : .unknown
        ).format(reference)
        #endif
    }

    /// "Dune, Arrival and 3 more".
    package static func list(_ items: [String], locale: Locale? = nil) -> String {
        #if canImport(Darwin)
        let formatter = ListFormatter()
        if let locale { formatter.locale = locale }
        return formatter.string(from: items) ?? items.joined(separator: ", ")
        #else
        return items.formatted(.list(type: .and).locale(locale ?? Formatters.displayLocale))
        #endif
    }

    /// A length of time in hours and minutes, or minutes alone under an hour: "2 hours, 5 minutes" (full), "8h 6m"
    /// (abbreviated). Never less than a minute.
    package static func duration(_ seconds: Double, width: Width, dropZeros: Bool = false) -> String? {
        let clamped = max(60, seconds)
        let hours = clamped >= 3600
        #if canImport(Darwin)
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = hours ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = switch width {
        case .full: .full
        case .short: .short
        case .abbreviated: .abbreviated
        }
        if dropZeros { formatter.zeroFormattingBehavior = .dropAll }
        return formatter.string(from: clamped)
        #else
        let units: Set<Duration.UnitsFormatStyle.Unit> = hours ? [.hours, .minutes] : [.minutes]
        let style: Duration.UnitsFormatStyle.UnitWidth = switch width {
        case .full: .wide
        case .short: .abbreviated
        case .abbreviated: .narrow
        }
        let minutes = Int64((clamped / 60).rounded(.down))
        return Duration.seconds(minutes * 60).formatted(.units(allowed: units, width: style, zeroValueUnits: dropZeros ? .hide : .show(length: 1))
            .locale(Formatters.displayLocale))
        #endif
    }
}
