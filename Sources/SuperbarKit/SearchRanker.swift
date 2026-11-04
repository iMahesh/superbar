import Foundation

/// Start menu search: prefix matches first, then word starts, then contains.
public enum SearchRanker {
    public enum Match: Int, Comparable, Sendable {
        case prefix = 0, wordStart = 1, contains = 2
        public static func < (a: Match, b: Match) -> Bool { a.rawValue < b.rawValue }
    }

    public static func match(name: String, query: String) -> Match? {
        let q = fold(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return nil }
        let n = fold(name)
        if n.hasPrefix(q) { return .prefix }
        if words(of: name).contains(where: { fold($0).hasPrefix(q) }) { return .wordStart }
        if n.contains(q) { return .contains }
        return nil
    }

    /// Matching items, best match first, then shorter names, then A to Z.
    public static func rank<T>(_ items: [T], query: String, name: (T) -> String) -> [T] {
        items.compactMap { item -> (T, Match, String)? in
            let n = name(item)
            return match(name: n, query: query).map { (item, $0, n) }
        }
        .sorted { a, b in
            if a.1 != b.1 { return a.1 < b.1 }
            if a.2.count != b.2.count { return a.2.count < b.2.count }
            return a.2.localizedStandardCompare(b.2) == .orderedAscending
        }
        .map(\.0)
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Words split on spaces and punctuation, and at lower-to-upper case changes ("FaceTime" -> Face, Time).
    static func words(of name: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previous: Character?
        for ch in name {
            if !(ch.isLetter || ch.isNumber) {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else if ch.isUppercase, let p = previous, p.isLowercase {
                words.append(current)
                current = String(ch)
            } else {
                current.append(ch)
            }
            previous = ch
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}
