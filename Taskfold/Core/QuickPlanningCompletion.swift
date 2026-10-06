import Foundation

/// Planning choices are previews of the real parser, not a second date grammar.
/// Selecting supplies editable text; Save/More/autosave still own task mutations.
struct QuickPlanningCompletion {
    typealias Option = QuickReferenceCompletion.Option
    private var source = ""
    var range: NSRange?
    var options: [Option] = []
    var prompt = ""
    var literalGroups = Set<String>()
    init(_ input: String, caretUTF16: Int? = nil, now: Date = Date(), calendar: Calendar = .current, task: Record = Record(), disabled: Set<String> = []) {
        source = input
        let caret = caretUTF16 ?? input.utf16.count
        guard caret >= 0, let prefixRange = Range(NSRange(location: 0, length: caret), in: input) else { return }
        let prefix = String(input[prefixRange])
        // Protection consumes complete references, quotes, escaped words and URLs first.
        let pattern = #"\\(?:[#/@%+](?:[a-z]+:)?(?:"[^"\n]*(?:"|$)|\S*)|\S*)|"[^"\n]*(?:"|$)|(?<!\S)(?:https?://|www\.)\S*|(?<!\S)[#/@%+](?:[a-z]+:)?(?:"[^"\n]*(?:"|$)|\S*)|(?<!\S)(!(?:every(?:\s+[\p{L}\p{N}:.,-]*)*|[\p{L}\p{N}:.]*(?:\s+(?:at\s+)?[\p{L}\p{N}:.]*)?)|ev(?:e(?:r(?:y!?)?)?)?(?:\s+[\p{L}\p{N}, -]*)?|end(?:\s+of(?:\s+[\p{L}]*)?)?|next(?:\s+[\p{L}]*)?|in(?:\s+\d*(?:\s+[\p{L}]*)?)?|at(?:\s+[\p{N}:.apm]*)?|[\p{L}]{2,})"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.matches(in: prefix, range: NSRange(prefix.startIndex..., in: prefix)).last,
              match.range.location + match.range.length == caret, match.range(at: 1).location != NSNotFound,
              let matched = Range(match.range(at: 1), in: prefix) else { return }
        let fragment = String(prefix[matched]).lowercased()
        if fragment.last?.isWhitespace == true && !["!every", "every", "every!", "next", "in", "at", "end", "end of"].contains(fragment.trimmingCharacters(in: .whitespaces)) { return }
        guard let start = Range(NSRange(location: match.range.location, length: 0), in: input)?.lowerBound,
              var end = Range(NSRange(location: caret, length: 0), in: input)?.lowerBound else { return }
        // Complete the current word in the middle of a title, retaining later words.
        while end < input.endIndex, !input[end].isWhitespace { end = input.index(after: end) }
        let whole = String(input[start..<end])
        guard !whole.contains("/"), !whole.contains("\\"), !whole.contains("\""), !whole.contains("@"), !whole.contains("#") else { return }
        var candidates: [String] = []
        let weekdays = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
        let group: String
        if fragment.hasPrefix("!") {
            group = "reminder_specs"; prompt = "Choose a reminder"
            candidates = ["!15m", "!30m", "!1h", "!later", "!tomorrow 9am", "!15mb", "!30mb", "!1hb", "!15ma", "!30ma", "!every day 9am", "!every weekdays 9am", "!every saturday 9am", "!every monday 9am", "!every month on last friday 9am"]
            if let number = fragment.dropFirst().split(whereSeparator: { !$0.isNumber }).first, let n = Int(number), (1...10080).contains(n) {
                candidates.insert(contentsOf: ["!\(n)m", "!\(n)mb", "!\(n)ma", "!\(n)h", "!\(n)hb", "!\(n)ha"], at: 0)
            }
        } else if "every".hasPrefix(fragment) && fragment.count >= 2 || fragment.hasPrefix("every ") || fragment.hasPrefix("every! ") || fragment == "every!" || ["daily", "weekly", "monthly", "yearly"].contains(where: { fragment.count >= 4 && $0.hasPrefix(fragment) }) {
            group = "recurrence"; prompt = "Choose a repeat rule"
            let anchor = fragment.hasPrefix("every!") ? "every! " : "every "
            candidates = ["day", "week", "month", "year", "weekdays", "weekends"] .map { anchor + $0 }
            candidates += weekdays.map { anchor + $0 }
            candidates += ["month on first monday", "month on last friday", "month on 15", "year on january 1"].map { anchor + $0 }
            if let number = fragment.split(separator: " ").dropFirst().first, let n = Int(number), (1...365).contains(n) {
                candidates += ["days", "weeks", "months", "years"].map { anchor + "\(n) " + $0 }
                candidates += weekdays.map { anchor + "\(n) weeks on " + $0 }
            }
            if ["daily", "weekly", "monthly", "yearly"].contains(where: { fragment.count >= 4 && $0.hasPrefix(fragment) }) { candidates = ["daily", "weekly", "monthly", "yearly"] }
        } else if fragment == "at" || fragment.hasPrefix("at ") {
            group = "due_time"; prompt = "Choose a planned time"
            candidates = ["at 9am", "at 12pm", "at 3pm", "at 6pm"]
            candidates += (1...12).flatMap { ["at \($0)am", "at \($0)pm"] }
            candidates += (0...23).flatMap { [String(format: "at %02d:00", $0), String(format: "at %02d:30", $0)] }
            if let h = Int(fragment.dropFirst(3)), (0...23).contains(h) { candidates.insert(String(format: "at %02d:00", h), at: 0) }
        } else {
            group = "due_date"; prompt = "Choose a planned date"
            candidates = ["today", "tomorrow", "yesterday", "next week", "next month", "next year", "end of month", "end of year"] + weekdays + weekdays.map { "next " + $0 }
            if fragment == "in" || fragment.hasPrefix("in ") {
                candidates = ["in 1 day", "in 2 days", "in 1 week", "in 1 month"]
                if let number = fragment.split(separator: " ").dropFirst().first, let n = Int(number), (1..<10000).contains(n) {
                    candidates = ["days", "weeks", "months", "hours", "minutes"].map { "in \(n) " + $0 }
                }
            }
        }
        // Never replace a fragment inside a longer already recognised phrase. In
        // particular keep an existing repeat limit or a reminder clock intact.
        let before = String(input[..<start]), after = String(input[end...])
        let full = QuickEntry(input, now: now, calendar: calendar, task: task)
        if full.tokens.contains(where: { token in
            let same = token.group == group || (group == "reminder_specs" && token.group.hasPrefix("reminder_specs:"))
            return same && token.text.lowercased().hasPrefix(whole.lowercased()) && token.text.count > whole.count
        }) { return }
        let query = fragment.trimmingCharacters(in: .whitespaces)
        var seen = Set<String>()
        for phrase in candidates where phrase.hasPrefix(query) && seen.insert(phrase).inserted {
            let parsed = QuickEntry(before + phrase + " " + after, now: now, calendar: calendar, task: task)
            guard let token = parsed.tokens.first(where: { $0.text.lowercased() == phrase && ($0.group == group || (group == "reminder_specs" && $0.group.hasPrefix("reminder_specs:"))) }) else { continue }
            let name = group == "reminder_specs" ? token.label : group == "due_date" ? token.label : group == "due_time" ? token.label : Recurrence.summary(Record(parsed.updates["recurrence_pattern"]?.object ?? [:]))
            var detail = phrase
            if group == "due_time", let day = parsed.updates["due_date"]?.text { detail += " · " + day }
            if group == "recurrence", let day = parsed.updates["due_date"]?.text { detail += " · starts " + day }
            if group == "reminder_specs", let warning = parsed.warnings.first { detail += " · " + warning }
            options.append(Option(group: group, recordID: "planning:" + phrase, name: name, detail: detail, reference: phrase))
        }
        guard !options.isEmpty else { return }
        range = NSRange(start..<end, in: input)
        literalGroups = [group]
        if group == "reminder_specs" {
            // An unfinished/invalid fragment is already literal. Do not disable
            // earlier accepted reminders when dismissing only that fragment.
            literalGroups = Set(full.tokens.filter { $0.group.hasPrefix("reminder_specs:") && $0.text.lowercased() == whole.lowercased() }.map(\.group))
        }
    }
    func choosing(_ option: Option, in input: String) -> (text: String, caretUTF16: Int)? {
        guard input == source, options.contains(option), let range, let target = Range(range, in: input) else { return nil }
        var result = input
        let separator = input[target.upperBound...].first?.isWhitespace == true ? "" : " "
        result.replaceSubrange(target, with: option.reference + separator)
        return (result, range.location + option.reference.utf16.count + separator.utf16.count)
    }
}

/// One cursor-local menu keeps planning and directory choices mutually exclusive.
struct QuickEntryCompletion {
    typealias Option = QuickReferenceCompletion.Option
    private var reference: QuickReferenceCompletion
    private var planning: QuickPlanningCompletion
    var range: NSRange? { reference.range ?? planning.range }
    var options: [Option] {
        get { reference.range != nil ? reference.options : planning.options }
        set { if reference.range != nil { reference.options = newValue } else { planning.options = newValue } }
    }
    var prompt: String { reference.range != nil ? reference.prompt : planning.prompt }
    var literalGroups: Set<String> { reference.range != nil ? reference.literalGroups : planning.literalGroups }
    init(_ input: String, caretUTF16: Int? = nil, now: Date = Date(), calendar: Calendar = .current, context: QuickEntryContext = QuickEntryContext(), task: Record = Record(), disabled: Set<String> = []) {
        reference = QuickReferenceCompletion(input, caretUTF16: caretUTF16, context: context, disabled: disabled)
        planning = QuickPlanningCompletion(input, caretUTF16: caretUTF16, now: now, calendar: calendar, task: task, disabled: disabled)
    }
    func choosing(_ option: Option, in input: String) -> (text: String, caretUTF16: Int)? {
        reference.range != nil ? reference.choosing(option, in: input) : planning.choosing(option, in: input)
    }
}
