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
    /// Test hook: how many full `QuickEntry` parses this completion ran. One keystroke must stay near ten.
    private(set) var parseCount = 0
    /// Options shown by one menu. Each shown option costs one parse, so this bounds the work per keystroke.
    static let optionLimit = 8
    /// Date words are few and cheap to order; "next " alone offers eleven.
    static let dateOptionLimit = 12
    init(_ input: String, caretUTF16: Int? = nil, now: Date = Date(), calendar: Calendar = .current, task: Record = Record(), disabled: Set<String> = [], context: QuickEntryContext = QuickEntryContext()) {
        source = input
        let places = Self.placeOptions(input, caretUTF16: caretUTF16, disabled: disabled, context: context)
        plan(input, caretUTF16: caretUTF16, now: now, calendar: calendar, task: task, disabled: disabled, context: context)
        guard let places else { return }
        // Saved places go above the times when both edit the same words; otherwise only the place applies.
        if range == places.range { options = places.options + options; literalGroups.insert("place") }
        else { options = places.options; literalGroups = ["place"]; range = places.range }
        prompt = "Choose a place"
    }
    private mutating func plan(_ input: String, caretUTF16: Int?, now: Date, calendar: Calendar, task: Record, disabled: Set<String>, context: QuickEntryContext) {
        let caret = caretUTF16 ?? input.utf16.count
        guard caret >= 0, let prefixRange = Range(NSRange(location: 0, length: caret), in: input) else { return }
        let prefix = String(input[prefixRange])
        // Protection consumes complete references, quotes, escaped words and URLs first.
        let pattern = #"\\(?:[#/@%+](?:[a-z]+:)?(?:"[^"\n]*(?:"|$)|\S*)|\S*)|"[^"\n]*(?:"|$)|(?<!\S)(?:https?://|www\.)\S*|(?<!\S)[#/@%+](?:[a-z]+:)?(?:"[^"\n]*(?:"|$)|\S*)|(?<!\S)(!(?:every(?:\s+[\p{L}\p{N}:.,-]*)*|[\p{L}\p{N}:.]*(?:\s+(?:at\s+)?[\p{L}\p{N}:.]*)?)|(?:\d+|one)\s+(?:days?|weeks?)\s+(?:before|after)(?:\s+[\p{L}\p{N}, -]*)?|ev(?:e(?:r(?:y!?)?)?)?(?![\p{L}\p{N}_])(?:\s+[\p{L}\p{N}, -]*)?|end(?:\s+of(?:\s+[\p{L}]*)?)?|next(?:\s+[\p{L}]*)?|this(?:\s+[\p{L}]*)?|in(?:\s+(?:the(?:\s+[\p{L}]*)?|\d*(?:\s+[\p{L}]*)?))?|at(?:\s+[\p{L}\p{N}:.]*)?|[\p{L}]{2,})"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.matches(in: prefix, range: NSRange(prefix.startIndex..., in: prefix)).last,
              match.range.location + match.range.length == caret, match.range(at: 1).location != NSNotFound,
              let matched = Range(match.range(at: 1), in: prefix) else { return }
        let fragment = String(prefix[matched]).lowercased()
        if fragment.last?.isWhitespace == true && !["!every", "every", "every!", "next", "this", "in", "in the", "at", "end", "end of"].contains(fragment.trimmingCharacters(in: .whitespaces)) { return }
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
            candidates = ["!15m", "!30m", "!1h", "!later", "!tomorrow 9am", "!tomorrow noon", "!midnight", "!every day noon", "!tomorrow morning", "!tomorrow evening", "!every day afternoon", "!15mb", "!30mb", "!1hb", "!15ma", "!30ma", "!every day 9am", "!every weekdays 9am", "!every saturday 9am", "!every monday 9am", "!every month on last friday 9am"]
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
        } else if fragment == "in the" || fragment.hasPrefix("in the ") || ["morning", "afternoon", "evening", "night"].contains(where: { fragment.count >= 3 && $0.hasPrefix(fragment) }) {
            group = "due_time"; prompt = "Choose a planned time"
            candidates = ["morning", "afternoon", "evening", "night"] + ["morning", "afternoon", "evening", "night"].map { "in the " + $0 }
        } else if fragment == "at" || fragment.hasPrefix("at ") {
            group = "due_time"; prompt = "Choose a planned time"
            // The first few are what most people mean, because only the first matching options are parsed and shown.
            candidates = ["at 9am", "at noon", "at 3pm", "at 5pm", "at 6pm", "at 8am", "at 8pm", "at midnight", "at 12pm"]
            candidates += (1...12).flatMap { ["at \($0)am", "at \($0)pm"] }
            candidates += (0...23).flatMap { [String(format: "at %02d:00", $0), String(format: "at %02d:30", $0)] }
            if let h = Int(fragment.dropFirst(3)), (0...23).contains(h) { candidates.insert(String(format: "at %02d:00", h), at: 0) }
        } else {
            group = "due_date"; prompt = "Choose a planned date"
            candidates = ["today", "tomorrow", "yesterday", "next week", "this weekend", "next weekend", "next month", "next year", "end of month", "end of year"] + weekdays + weekdays.map { "next " + $0 }
            if let prefix = fragment.range(of: #"^(?:\d+|one)\s+(?:days?|weeks?)\s+(?:before|after)\s+"#, options: .regularExpression) {
                candidates = candidates.map { String(fragment[prefix]) + $0 }
            } else if fragment == "in" || fragment.hasPrefix("in ") {
                candidates = ["in 1 day", "in 2 days", "in 1 week", "in 1 month"]
                if let number = fragment.split(separator: " ").dropFirst().first, let n = Int(number), (1..<10000).contains(n) {
                    candidates = ["days", "weeks", "months", "hours", "minutes"].map { "in \(n) " + $0 }
                }
            }
        }
        // Never replace a fragment inside a longer already recognised phrase. In
        // particular keep an existing repeat limit or a reminder clock intact.
        let before = String(input[..<start]), after = String(input[end...])
        // Narrow by the typed prefix before any parse: most keystrokes leave a handful of candidates.
        let query = fragment.trimmingCharacters(in: .whitespaces)
        var seen = Set<String>()
        let matching = candidates.filter { $0.hasPrefix(query) && seen.insert($0).inserted }
        guard !matching.isEmpty else { return }
        parseCount += 1
        let full = QuickEntry(input, now: now, calendar: calendar, context: context, task: task)
        if full.tokens.contains(where: { token in
            let same = token.group == group || (group == "reminder_specs" && token.group.hasPrefix("reminder_specs:"))
            return same && token.text.lowercased().hasPrefix(whole.lowercased()) && token.text.count > whole.count
        }) { return }
        let limit = group == "due_date" ? Self.dateOptionLimit : Self.optionLimit
        var attempts = 0
        for phrase in matching {
            // One parse per shown option, plus one spare for a phrase the parser rejects.
            guard options.count < limit, attempts <= limit else { break }
            attempts += 1; parseCount += 1
            let parsed = QuickEntry(before + phrase + " " + after, now: now, calendar: calendar, context: context, task: task)
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
    private static let placeTrigger = try? NSRegularExpression(pattern: #"(?<!\S)(arrive\s+at|arrive|leave\s+at|leave|at)\s+"#, options: .caseInsensitive)
    private static func fold(_ text: String) -> String { text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
    /// "Arrive at <Place>" and "Leave <Place>" for saved places whose name starts with the words typed after
    /// "at ", "arrive at " or "leave ". Names come from the context and are never stored. No parse runs here.
    private static func placeOptions(_ input: String, caretUTF16: Int?, disabled: Set<String>, context: QuickEntryContext) -> (range: NSRange, options: [Option])? {
        guard !context.places.isEmpty, !disabled.contains("place"), let trigger = placeTrigger else { return nil }
        let caret = caretUTF16 ?? input.utf16.count
        guard caret > 0, let prefixRange = Range(NSRange(location: 0, length: caret), in: input) else { return nil }
        let prefix = String(input[prefixRange])
        let found = trigger.matches(in: prefix, range: NSRange(prefix.startIndex..., in: prefix))
        guard let match = found.last, let triggerRange = Range(match.range(at: 1), in: prefix), let restStart = Range(match.range, in: prefix)?.upperBound else { return nil }
        let rest = String(prefix[restStart...])
        // A place is a few plain words: no newline, quote, escape, reference or path, and nothing unfinished before it.
        guard !rest.isEmpty, rest.count <= 60, !rest.contains(where: { $0.isNewline || "\"\\/@#".contains($0) }),
              prefix[..<triggerRange.lowerBound].filter({ $0 == "\"" }).count % 2 == 0,
              let startIndex = Range(NSRange(location: match.range(at: 1).location, length: 0), in: input)?.lowerBound,
              var end = Range(NSRange(location: caret, length: 0), in: input)?.lowerBound else { return nil }
        // "at the gy" and "at my gy" still offer "Gym".
        var typed = fold(rest)
        for article in ["the ", "my "] where typed.hasPrefix(article) && typed.count > article.count { typed.removeFirst(article.count) }
        // Typing a space after a finished name closes the choice; a name with spaces may still be unfinished.
        let names = context.places.filter { fold($0).hasPrefix(typed) }.prefix(3)
        guard !names.isEmpty else { return nil }
        while end < input.endIndex, !input[end].isWhitespace { end = input.index(after: end) }
        let word = prefix[triggerRange].lowercased().split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "at"
        let phrase = String(prefix[triggerRange])
        var options: [Option] = []
        for name in names {
            if word == "at" || word == "arrive" {
                options.append(Option(group: "place", recordID: "arrive:" + name, name: "Arrive at " + name, detail: "Place reminder", reference: phrase + " " + name))
            }
            if word == "at" || word == "leave" {
                options.append(Option(group: "place", recordID: "leave:" + name, name: "Leave " + name, detail: "Place reminder", reference: (word == "leave" ? phrase : "leave") + " " + name))
            }
        }
        return (NSRange(startIndex..<end, in: input), options)
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
        planning = QuickPlanningCompletion(input, caretUTF16: caretUTF16, now: now, calendar: calendar, task: task, disabled: disabled, context: context)
    }
    func choosing(_ option: Option, in input: String) -> (text: String, caretUTF16: Int)? {
        reference.range != nil ? reference.choosing(option, in: input) : planning.choosing(option, in: input)
    }
}
