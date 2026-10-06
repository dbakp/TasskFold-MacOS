import Foundation

/// A cursor-local draft choice. The ID is revalidated against the current directory
/// when parsing; choices are never credentials or a second persisted task model.
struct QuickReferenceCompletion {
    struct Option: Identifiable, Equatable {
        var group: String
        var recordID: String
        var name: String
        var detail: String
        var reference: String
        var id: String { group + ":" + recordID }
    }
    private var source = ""
    var range: NSRange?
    var options: [Option] = []
    var prompt = ""
    var literalGroups = Set<String>()
    init(_ input: String, caretUTF16: Int? = nil, context: QuickEntryContext = QuickEntryContext(), disabled: Set<String> = []) {
        source = input
        let caret = caretUTF16 ?? input.utf16.count
        guard caret >= 0, let prefixRange = Range(NSRange(location: 0, length: caret), in: input) else { return }
        let prefix = String(input[prefixRange])
        // Skip escaped tokens and quoted prose before considering an unfinished reference.
        let pattern = #"\\(?:[#/@%+](?:"[^"\n]*(?:"|$)|[^\s]*)|[^\s]*)|"[^"\n]*(?:"|$)|(?<!\S)([#/@%+])(?:(project|label|section|person):)?(?:"([^"\n]*)"?|([\p{L}\p{N}_@.\-]*))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.matches(in: prefix, range: NSRange(prefix.startIndex..., in: prefix)).last,
              match.range.location + match.range.length == caret, match.range(at: 1).location != NSNotFound else { return }
        func capture(_ n: Int) -> String { Range(match.range(at: n), in: prefix).map { String(prefix[$0]) } ?? "" }
        if let tokenRange = Range(match.range, in: prefix) {
            let raw = String(prefix[tokenRange])
            if let opening = raw.firstIndex(of: "\""), raw.lastIndex(of: "\"") != opening { return }
        }
        let symbol = capture(1), qualifier = capture(2).lowercased(), query = capture(3).isEmpty ? capture(4) : capture(3)
        // Replacing the whole token also preserves text after a cursor in its middle.
        guard let start = Range(NSRange(location: match.range.location, length: 0), in: input)?.lowerBound,
              var end = Range(NSRange(location: caret, length: 0), in: input)?.lowerBound else { return }
        let quoted = match.range(at: 3).location != NSNotFound
        while end < input.endIndex {
            let c = input[end]
            if quoted && c == "\"" { end = input.index(after: end); break }
            if c.isNewline || (!quoted && c.isWhitespace) { break }
            end = input.index(after: end)
        }
        let whole = input[start..<end].dropFirst()
        guard quoted || (!whole.contains("/") && !whole.contains("\\")) else { return }
        range = NSRange(start..<end, in: input)
        var base = context
        // Partial fragments must not select a project/label while choosing their completion.
        let before = String(input[..<start]) + " " + String(input[end...])
        let parsed = QuickEntry(before, disabled: disabled, context: base)
        let project = parsed.updates["project_id"]?.text ?? context.currentProject
        if parsed.referenceProjectBlocked { base.currentProject = "" }
        else { base.currentProject = project }
        func reference(_ prefix: String, _ name: String) -> String? {
            guard !name.isEmpty, !name.contains("\""), !name.contains(where: \.isNewline) else { return nil }
            return prefix + "\"" + name + "\""
        }
        func add(_ rows: [Record], group: String, prefix: String, kind: String, name: (Record) -> String = { $0.name }) {
            for row in rows where !row.id.isEmpty {
                let title = name(row)
                let key = QuickEntryContext.key(title), needle = QuickEntryContext.key(query)
                guard (needle.isEmpty || key.contains(needle)), let raw = reference(prefix, title) else { continue }
                let detail = row.string("description").trimmingCharacters(in: .whitespacesAndNewlines)
                let value = Option(group: group, recordID: row.id, name: title, detail: detail.isEmpty ? kind : kind + " · " + String(detail.prefix(120)), reference: raw)
                if !options.contains(where: { $0.id == value.id }) { options.append(value) }
            }
        }
        switch (symbol, qualifier) {
        case ("#", ""), ("#", "project"):
            literalGroups = qualifier.isEmpty ? ["project_id", "labels"] : ["project_id"]
            prompt = "Choose a project"
            add(context.projects.filter { !$0["is_archived"].flag }, group: "project_id", prefix: "#project:", kind: "Project")
            if qualifier.isEmpty { prompt = "Projects and labels"; add(context.labels, group: "labels", prefix: "@", kind: "Label") }
        case ("@", ""), ("%", ""), ("#", "label"), ("@", "label"), ("%", "label"):
            literalGroups = ["labels"]
            prompt = "Choose a label"; add(context.labels, group: "labels", prefix: "@", kind: "Label")
        case ("/", ""), ("/", "section"):
            literalGroups = ["section_id"]
            prompt = base.currentProject.isEmpty ? "Choose a project before a section" : "Sections in the selected project"
            if !base.currentProject.isEmpty { add(context.sections.filter { $0.string("project_id") == base.currentProject }, group: "section_id", prefix: "/", kind: "Section") }
        case ("+", ""), ("+", "person"):
            literalGroups = ["assigned_to"]
            prompt = base.currentProject.isEmpty ? "Choose a project before assigning" : "Current project members"
            if !base.currentProject.isEmpty {
                add((context.members[base.currentProject] ?? []).filter { !["pending", "declined", "revoked"].contains($0.string("status")) }, group: "assigned_to", prefix: "+", kind: "Project member", name: { $0.string("display_name").isEmpty ? $0.string("email") : $0.string("display_name") })
            }
        default: range = nil; return
        }
        let needle = QuickEntryContext.key(query)
        options.sort {
            let a = QuickEntryContext.key($0.name), b = QuickEntryContext.key($1.name)
            let ap = a.hasPrefix(needle), bp = b.hasPrefix(needle)
            if ap != bp { return ap }
            if a != b { return a < b }
            if $0.detail != $1.detail { return $0.detail < $1.detail }
            return $0.id < $1.id
        }
    }
    /// Multi-line native fields can insert a newline for Done rather than emit onSubmit.
    /// Recognize only one inserted return, so pasting multiline work stays a draft.
    static func returnInsertion(before: String, after: String) -> Int? {
        let old = Array(before.utf16), new = Array(after.utf16)
        guard new.count == old.count + 1 else { return nil }
        var position = 0
        while position < old.count, old[position] == new[position] { position += 1 }
        guard [10, 13].contains(new[position]), Array(new[(position + 1)...]) == Array(old[position...]), Range(NSRange(location: position, length: 0), in: before) != nil else { return nil }
        return position
    }
    func choosing(_ option: Option, in input: String) -> (text: String, caretUTF16: Int)? {
        guard input == source, options.contains(option), let range, let target = Range(range, in: input) else { return nil }
        var output = input
        let suffix = input[target.upperBound...]
        let separator = suffix.first?.isWhitespace == true ? "" : " "
        output.replaceSubrange(target, with: option.reference + separator)
        return (output, range.location + option.reference.utf16.count + separator.utf16.count)
    }
}
