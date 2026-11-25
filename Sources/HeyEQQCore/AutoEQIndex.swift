import Foundation

/// The AutoEQ project's list of measured headphones (`results/INDEX.md` in its GitHub repo) and
/// where each one's ready-made "ParametricEQ.txt" lives. Parsing and search only; no networking.
public enum AutoEQIndex {
    public static let baseURL = URL(string: "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/")!
    public static let indexURL = baseURL.appendingPathComponent("INDEX.md")

    public struct Entry: Hashable, Sendable, Identifiable {
        /// Headphone model, e.g. "Sennheiser HD 650".
        public let name: String
        /// Who measured it, e.g. "oratory1990".
        public let source: String
        /// Measurement rig when the index names one, e.g. "GRAS 43AG-7".
        public let rig: String?
        /// Percent-encoded folder path relative to `baseURL`.
        public let path: String
        public var id: String { path }

        /// URL of this entry's Equalizer APO parametric file.
        public var parametricEQURL: URL? {
            guard let folder = path.split(separator: "/").last else { return nil }
            return URL(string: "\(path)/\(folder)%20ParametricEQ.txt", relativeTo: AutoEQIndex.baseURL)?.absoluteURL
        }
    }

    /// Parses lines like `- [Name](./source/rig/Name) by source on rig`. Other lines are ignored.
    public static func parse(_ markdown: String) -> [Entry] {
        var entries: [Entry] = []
        for line in markdown.split(whereSeparator: \.isNewline) {
            // Greedy matches keep names and paths that contain brackets or parentheses intact.
            guard let match = line.wholeMatch(of: #/- \[(.+)\]\(\./(.+)\) by (.+?)(?: on (.+))?/#) else { continue }
            entries.append(Entry(name: String(match.1), source: String(match.3),
                                 rig: match.4.map(String.init), path: String(match.2)))
        }
        return entries
    }

    /// Entries whose name contains every word of `query` (case- and accent-insensitive), names that
    /// start with the query first. An empty query returns nothing.
    public static func search(_ entries: [Entry], query: String, limit: Int = 200) -> [Entry] {
        let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let words = fold(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let phrase = words.joined(separator: " ")
        var prefix: [Entry] = [], rest: [Entry] = []
        for entry in entries {
            let name = fold(entry.name)
            guard words.allSatisfy({ name.contains($0) }) else { continue }
            if name.hasPrefix(phrase) { prefix.append(entry) } else { rest.append(entry) }
            if prefix.count >= limit { break }
        }
        return Array((prefix + rest).prefix(limit))
    }
}
