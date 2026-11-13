import Foundation

/// Pure, fuzzy-ish ranking for the command bar. No UI, store or clock dependencies, so it is unit-tested on its own.
/// Every whitespace-separated term of the query must match the title, a keyword, or the detail line. Per term the
/// best of: exact title, title prefix, word prefix, substring, initials/subsequence, keyword, detail. Higher is better.
enum CommandRanking {
    struct Candidate: Equatable, Sendable {
        var id: String
        var title: String
        var detail: String = ""
        var keywords: [String] = []
        /// Added to the score, e.g. to prefer commands over a long tail of tasks, or recent items over old ones.
        var boost: Int = 0
    }
    struct Match: Equatable, Sendable { var id: String; var score: Int }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    static func terms(_ query: String) -> [String] { normalize(query).split(whereSeparator: \.isWhitespace).map(String.init) }

    /// Ranked matches, best first. Ties keep the input order. An empty query keeps every candidate, ordered by boost.
    static func rank(_ candidates: [Candidate], query: String, limit: Int? = nil) -> [Match] {
        let words = terms(query)
        var matches: [(match: Match, order: Int)] = []
        for (order, candidate) in candidates.enumerated() {
            guard let value = score(words, candidate) else { continue }
            matches.append((Match(id: candidate.id, score: value), order))
        }
        matches.sort { $0.match.score != $1.match.score ? $0.match.score > $1.match.score : $0.order < $1.order }
        let result = matches.map(\.match)
        return limit.map { Array(result.prefix(max(0, $0))) } ?? result
    }

    static func score(query: String, candidate: Candidate) -> Int? { score(terms(query), candidate) }

    private static func score(_ words: [String], _ candidate: Candidate) -> Int? {
        if words.isEmpty { return candidate.boost }
        let title = normalize(candidate.title), detail = normalize(candidate.detail), keywords = candidate.keywords.map(normalize)
        var total = 0
        for word in words {
            guard let value = termScore(word, title: title, keywords: keywords, detail: detail) else { return nil }
            total += value
        }
        // A short title that matches beats a long one that merely contains the same letters.
        total -= min(40, title.count / 4)
        return total + candidate.boost
    }

    private static func termScore(_ word: String, title: String, keywords: [String], detail: String) -> Int? {
        var best: Int?
        func offer(_ value: Int) { best = max(best ?? Int.min, value) }
        if title == word { offer(1000) }
        else if title.hasPrefix(word) { offer(800) }
        else if let range = title.range(of: word) {
            let atWordStart = range.lowerBound == title.startIndex || !title[title.index(before: range.lowerBound)].isLetterOrNumber
            offer(atWordStart ? 600 : 400)
        } else if word.count >= 2, let value = subsequence(word, in: title) { offer(value) }
        for keyword in keywords {
            if keyword == word { offer(500) } else if keyword.hasPrefix(word) { offer(350) } else if keyword.contains(word) { offer(200) }
        }
        if !detail.isEmpty, detail.contains(word) { offer(100) }
        return best
    }

    /// Letters in order, e.g. "pt" in "Plan today" (initials) or "wrpt" in "Write report". Initials score above scattered hits.
    private static func subsequence(_ word: String, in title: String) -> Int? {
        let text = Array(title), letters = Array(word)
        var position = 0, first: Int?, last = 0, initials = 0
        for letter in letters {
            guard let found = text[position...].firstIndex(of: letter) else { return nil }
            if first == nil { first = found }
            if found == 0 || !text[found - 1].isLetterOrNumber { initials += 1 }
            last = found; position = found + 1
        }
        let span = last - (first ?? 0) + 1, gaps = span - letters.count
        let base = initials == letters.count ? 330 : 150
        return max(20, base - gaps * 8 + initials * 4)
    }
}

private extension Character {
    var isLetterOrNumber: Bool { isLetter || isNumber }
}
