import AppKit
import HeyEQQCore
import SwiftUI
import UniformTypeIdentifiers

/// Expert mode: fully parametric EQ with draggable graph, band table, preamp and AutoEQ import/export.
struct ExpertEQView: View {
    @Bindable var model: AppModel

    enum Tab: String, CaseIterable { case bands = "Bands", apps = "Per-App" }

    @State private var tab: Tab = .bands
    @State private var selected: Int?
    @State private var showingSave = false
    @State private var renaming: ExpertPreset?
    @State private var deleting: ExpertPreset?
    @State private var draftName = ""
    @State private var alertMessage: String?
    @State private var showingHeadphoneSearch = false

    private var curve: EQCurve { model.expertCurve }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if tab == .bands {
                InteractiveResponseView(curve: curve, selected: $selected) { index, frequency, gain in
                    model.updateExpertBand(at: index) { band in
                        band.frequency = Self.snapFrequency(frequency)
                        if let gain { band.gainDB = (gain * 10).rounded() / 10 }
                    }
                }
                .frame(minHeight: 220)
                .card()
                bandTable
                    .card()
                footer
                    .card()
            } else {
                PerAppView(model: model)
            }
        }
        .sheet(isPresented: $showingHeadphoneSearch, onDismiss: { model.headphoneSearchRequest = nil }) {
            let request = model.headphoneSearchRequest
            HeadphoneSearchSheet(model: model, catalog: model.headphones, initialQuery: request?.query ?? "") { note in
                selected = nil
                tab = .bands
                // Opened for a device: the imported curve becomes that device's preset.
                model.finishHeadphoneImport(for: request)
                alertMessage = note
            }
        }
        .onAppear { if model.headphoneSearchRequest != nil { showingHeadphoneSearch = true } }
        .onChange(of: model.headphoneSearchRequest) { _, request in
            if request != nil { showingHeadphoneSearch = true }
        }
        .alert("Save Curve", isPresented: $showingSave) {
            TextField("Name", text: $draftName)
            Button("Save") { model.saveExpertPreset(named: draftName) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Curve", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $draftName)
            Button("Rename") { if let p = renaming { model.renameExpertPreset(p, to: draftName) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let p = deleting { model.deleteExpertPreset(p) } }
        } message: {
            Text("This can't be undone.")
        }
        .alert("HeyEQQ", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if tab == .bands {
                Text("\(curve.bands.count) of \(EQCurve.maxBands) bands").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if tab == .bands { bandsHeaderControls }
        }
    }

    @ViewBuilder
    private var bandsHeaderControls: some View {
        HStack(spacing: 10) {
            Button {
                showingHeadphoneSearch = true
            } label: {
                Label("Find Headphones…", systemImage: "headphones")
            }
            .help("Search the AutoEQ list for your headphone model and import its correction curve")
            Menu("Import") {
                Button("AutoEQ / Equalizer APO File…", action: importFile)
                Button("Paste from Clipboard", action: importClipboard)
                Divider()
                Link("Open autoeq.app…", destination: URL(string: "https://autoeq.app")!)
            }
            .fixedSize()
            Button("Export…", action: exportFile)
            presetMenu
        }
    }

    private var presetMenu: some View {
        let active = model.activeExpertPreset
        return Menu {
            Section("Built-in") {
                ForEach(ExpertPreset.builtIn) { p in presetButton(p, active: active) }
            }
            if !model.userExpertPresets.isEmpty {
                Section("My Curves") {
                    ForEach(model.userExpertPresets) { p in presetButton(p, active: active) }
                }
            }
            Divider()
            Button("Save as New Curve…") {
                draftName = active.map { "\($0.name) copy" } ?? "My Curve"
                showingSave = true
            }
            if let active, !active.isBuiltIn {
                Button("Rename “\(active.name)”…") { draftName = active.name; renaming = active }
                Button("Delete “\(active.name)”…", role: .destructive) { deleting = active }
            }
        } label: {
            Text(active?.name ?? "Custom").frame(minWidth: 120)
        }
        .fixedSize()
    }

    private func presetButton(_ p: ExpertPreset, active: ExpertPreset?) -> some View {
        Button { model.applyExpert(p); selected = nil } label: {
            if p == active { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
        }
    }

    // MARK: Band table

    private var bandTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("").frame(width: 46)
                Text("Type").frame(width: 120, alignment: .leading)
                Text("Frequency").frame(width: 96, alignment: .leading)
                Text("Gain").frame(width: 86, alignment: .leading)
                Text("Q").frame(width: 70, alignment: .leading)
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(curve.bands.indices, id: \.self) { i in
                            BandRow(index: i, band: curve.bands[i], isSelected: selected == i,
                                    update: { change in model.updateExpertBand(at: i, change) },
                                    remove: {
                                        model.removeExpertBand(at: i)
                                        selected = nil
                                    })
                                .id(i)
                                .onTapGesture { selected = i }
                        }
                    }
                }
                .onChange(of: selected) { _, new in if let new { withAnimation { proxy.scrollTo(new) } } }
            }
            .frame(minHeight: 120)
            .overlay {
                if curve.bands.isEmpty {
                    Text("No bands. Click “Add Band” or import an AutoEQ file.").foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                if let i = model.addExpertBand() { selected = i }
            } label: {
                Label("Add Band", systemImage: "plus")
            }
            .disabled(curve.bands.count >= EQCurve.maxBands)

            Spacer()

            Text("Preamp").font(.callout)
            Slider(value: Binding(get: { curve.preampDB }, set: { model.setExpertPreamp($0) }), in: -24...6)
                .frame(width: 180)
            Text(String(format: "%+.1f dB", curve.preampDB))
                .font(.callout.monospacedDigit())
                .frame(width: 64, alignment: .trailing)
            Button("Auto") { model.autoExpertPreamp() }
                .help("Lower the preamp so the curve's highest boost lands at 0 dB and the limiter never engages.")
        }
    }

    // MARK: Import / export

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an AutoEQ “ParametricEQ.txt” or Equalizer APO config"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            var name = url.deletingPathExtension().lastPathComponent
            name = name.replacingOccurrences(of: " ParametricEQ", with: "")
            runImport(text, name: name)
        } catch {
            alertMessage = "Couldn't read the file: \(error.localizedDescription)"
        }
    }

    private func importClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            alertMessage = "The clipboard doesn't contain text."
            return
        }
        runImport(text, name: "Imported Curve")
    }

    private func runImport(_ text: String, name: String) {
        do {
            let result = try model.importExpert(text, name: name)
            selected = nil
            var notes: [String] = []
            if !result.skippedLines.isEmpty { notes.append("Skipped \(result.skippedLines.count) unsupported line(s).") }
            if result.truncated { notes.append("Only the first \(EQCurve.maxBands) filters were kept.") }
            if !notes.isEmpty {
                alertMessage = "Imported “\(name)” with \(result.curve.bands.count) bands. " + notes.joined(separator: " ")
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func exportFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(model.activeExpertPreset?.name ?? "HeyEQQ") ParametricEQ.txt"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.exportExpert().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            alertMessage = "Couldn't save the file: \(error.localizedDescription)"
        }
    }

    static func snapFrequency(_ f: Double) -> Double {
        let step: Double = f < 100 ? 1 : f < 1_000 ? 5 : f < 10_000 ? 10 : 100
        return (f / step).rounded() * step
    }
}

/// One editable band in the table.
private struct BandRow: View {
    let index: Int
    let band: EQBand
    let isSelected: Bool
    let update: ((inout EQBand) -> Void) -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("Enabled", isOn: Binding(get: { band.isEnabled }, set: { v in update { $0.isEnabled = v } }))
                .toggleStyle(.checkbox)
                .labelsHidden()
            ZStack {
                Circle().fill(bandColor(index)).frame(width: 18, height: 18)
                Text("\(index + 1)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
            }
            Picker("Type", selection: Binding(get: { band.type }, set: { v in update { $0.type = v } })) {
                ForEach(FilterType.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(width: 120)

            NumberField(value: band.frequency, unit: "Hz", digits: 0...1) { v in update { $0.frequency = v } }
                .frame(width: 96)
            NumberField(value: band.gainDB, unit: "dB", digits: 1...1) { v in update { $0.gainDB = v } }
                .frame(width: 86)
                .disabled(!band.type.usesGain)
                .opacity(band.type.usesGain ? 1 : 0.4)
            NumberField(value: band.q, unit: "", digits: 2...2) { v in update { $0.q = v } }
                .frame(width: 70)

            Spacer()
            Button(role: .destructive, action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove band \(index + 1)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .opacity(band.isEnabled ? 1 : 0.55)
        .contentShape(Rectangle())
    }
}

/// Numeric text field that commits on Return / focus loss.
private struct NumberField: View {
    let value: Double
    let unit: String
    let digits: ClosedRange<Int>
    let commit: (Double) -> Void

    var body: some View {
        HStack(spacing: 3) {
            TextField("", value: Binding(get: { value }, set: { if $0.isFinite { commit($0) } }),
                      format: .number.precision(.fractionLength(digits)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
            if !unit.isEmpty { Text(unit).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// Response graph with a draggable node per band (x = frequency, y = gain).
private struct InteractiveResponseView: View {
    let curve: EQCurve
    @Binding var selected: Int?
    /// (band index, new frequency, new gain or nil for gain-less filter types)
    let onMove: (Int, Double, Double?) -> Void

    private let rangeDB = 18.0

    var body: some View {
        GeometryReader { geo in
            let plot = ResponsePlot(size: geo.size, rangeDB: rangeDB, showsLabels: true)
            ZStack(alignment: .topLeading) {
                ResponseCurveView(curve: curve, rangeDB: rangeDB, showsBandCurves: true, selectedBand: selected)
                ForEach(curve.bands.indices, id: \.self) { i in
                    let band = curve.bands[i]
                    ZStack {
                        Circle().fill(bandColor(i))
                        Text("\(i + 1)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    }
                    .frame(width: 18, height: 18)
                    .overlay(Circle().stroke(Color.white, lineWidth: selected == i ? 2 : 0))
                    .shadow(color: .black.opacity(0.3), radius: selected == i ? 3 : 1)
                    .opacity(band.isEnabled ? 1 : 0.35)
                    .position(x: plot.x(band.frequency), y: plot.y(band.type.usesGain ? band.gainDB : 0))
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("graph")).onChanged { drag in
                        selected = i
                        onMove(i, plot.frequency(atX: drag.location.x),
                               band.type.usesGain ? plot.gain(atY: drag.location.y) : nil)
                    })
                    .help("Band \(i + 1): \(band.type.label) \(Int(band.frequency)) Hz")
                }
            }
            .coordinateSpace(name: "graph")
        }
    }
}
