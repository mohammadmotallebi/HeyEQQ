import HeyEQQCore
import SwiftUI

/// Downloads and caches the AutoEQ headphone list, and fetches a headphone's correction curve.
/// Nothing is sent anywhere except the plain download requests to GitHub.
@MainActor
@Observable
final class HeadphoneCatalog {
    enum State: Equatable { case idle, loading, loaded, failed(String) }

    private(set) var state: State = .idle
    private(set) var entries: [AutoEQIndex.Entry] = []

    private static let cacheName = "autoeq-index.md"
    private static let maxCacheAge: TimeInterval = 7 * 24 * 3600

    /// Loads the list: from the cache if it is under a week old, otherwise from GitHub
    /// (falling back to an older cache when offline).
    func load() async {
        guard state != .loading, entries.isEmpty else { return }
        state = .loading
        let cache = JSONFileStore.url(Self.cacheName)
        let cached = try? String(contentsOf: cache, encoding: .utf8)
        let modified = (try? FileManager.default.attributesOfItem(atPath: cache.path))?[.modificationDate] as? Date
        if let cached, let modified, Date().timeIntervalSince(modified) < Self.maxCacheAge,
           await use(cached) { return }
        do {
            let text = try await Self.download(AutoEQIndex.indexURL)
            guard await use(text) else { throw URLError(.cannotParseResponse) }
            try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: cache, atomically: true, encoding: .utf8)
        } catch {
            if let cached, await use(cached) { return }
            state = .failed(error.localizedDescription)
        }
    }

    /// The headphone's Equalizer APO parametric text.
    func curveText(for entry: AutoEQIndex.Entry) async throws -> String {
        guard let url = entry.parametricEQURL else { throw URLError(.badURL) }
        return try await Self.download(url)
    }

    private func use(_ text: String) async -> Bool {
        let parsed = await Task.detached { AutoEQIndex.parse(text) }.value
        guard !parsed.isEmpty else { return false }
        entries = parsed
        state = .loaded
        return true
    }

    private static func download(_ url: URL) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("HeyEQQ", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Sheet: search the AutoEQ list by headphone model and import the chosen correction curve.
struct HeadphoneSearchSheet: View {
    @Bindable var model: AppModel
    let catalog: HeadphoneCatalog
    /// Called with a note to show (or nil) after a successful import.
    let onImported: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query: String

    init(model: AppModel, catalog: HeadphoneCatalog, initialQuery: String = "", onImported: @escaping (String?) -> Void) {
        self.model = model
        self.catalog = catalog
        self.onImported = onImported
        _query = State(initialValue: initialQuery)
    }
    @State private var selection: AutoEQIndex.Entry.ID?
    @State private var importing = false
    @State private var errorText: String?
    @FocusState private var searchFocused: Bool

    private var results: [AutoEQIndex.Entry] { AutoEQIndex.search(catalog.entries, query: query, limit: 150) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find Your Headphones").font(.title3.weight(.semibold))
            Text("Correction curves from the AutoEQ project, which tunes each measured headphone toward a neutral target. The list and the curve you pick are downloaded from GitHub.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Model name, for example “HD 650” or “AirPods Pro”", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .disabled(catalog.state != .loaded)
                .onSubmit { if results.count == 1 { selection = results[0].id; importSelected() } }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                if let errorText {
                    Text(errorText).font(.caption).foregroundStyle(.red).lineLimit(2)
                } else if importing {
                    ProgressView().controlSize(.small)
                    Text("Downloading curve…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") { importSelected() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil || importing)
            }
        }
        .padding(20)
        .frame(width: 540, height: 480)
        .task {
            await catalog.load()
            searchFocused = true
        }
    }

    @ViewBuilder
    private var content: some View {
        switch catalog.state {
        case .idle, .loading:
            VStack(spacing: 8) {
                ProgressView()
                Text("Loading the headphone list…").foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(spacing: 8) {
                Text("Couldn't load the headphone list.").font(.headline)
                Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try Again") { Task { await catalog.load() } }
            }
            .padding()
        case .loaded:
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("\(catalog.entries.count.formatted()) measurements. Type a model name to search.")
                    .foregroundStyle(.secondary)
            } else if results.isEmpty {
                Text("No headphones match “\(query)”.").foregroundStyle(.secondary)
            } else {
                List(results, selection: $selection) { entry in
                    HStack {
                        Text(entry.name)
                        Spacer()
                        Text(entry.rig.map { "\(entry.source) · \($0)" } ?? entry.source)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(entry.id)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func importSelected() {
        guard let entry = catalog.entries.first(where: { $0.id == selection }), !importing else { return }
        importing = true
        errorText = nil
        Task {
            defer { importing = false }
            do {
                let text = try await catalog.curveText(for: entry)
                let name = "\(entry.name) (\(entry.source))"
                let result = try model.importExpert(text, name: name)
                var notes: [String] = []
                if !result.skippedLines.isEmpty { notes.append("Skipped \(result.skippedLines.count) unsupported line(s).") }
                if result.truncated { notes.append("Only the first \(EQCurve.maxBands) filters were kept.") }
                onImported(notes.isEmpty ? nil : "Imported “\(name)”. " + notes.joined(separator: " "))
                dismiss()
            } catch {
                errorText = "Couldn't import \(entry.name): \(error.localizedDescription)"
            }
        }
    }
}
