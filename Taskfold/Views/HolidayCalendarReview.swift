import SwiftUI
import Observation
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

struct HolidayCalendarReview: View {
    @Environment(\.dismiss) private var dismiss
    let initial: ReminderHolidayPolicy?
    let apply: (ReminderHolidayPolicy?) -> Void
    @State private var yearText: String
    @State private var source: String
    @State private var region: String
    @State private var mode: ReminderHolidayPolicy.Mode
    @State private var weekends: Bool
    @State private var reviewed = false
    private enum SourceKind: String, CaseIterable { case country = "Country calendar", file = "Calendar file" }
    @State private var sourceKind: SourceKind
    @State private var country: String
    @State private var countryName: String
    @State private var subdivision: String
    @State private var countryCalendar: CountryHolidayCalendar.Snapshot?
    @State private var choosingCountry = false
    @State private var sourceChanged = false
    @State private var imported: HolidayCalendarFile?
    @State private var fileUI = HolidayCalendarTransfer()
    @State private var choosing = false
    @State private var loading = false
    @State private var message: String?
    @State private var operation = UUID()
    @State private var reader: Task<Void, Never>?
    private enum Field: Hashable { case year, source, region }
    @FocusState private var focused: Field?
    init(policy: ReminderHolidayPolicy?, year: Int, apply: @escaping (ReminderHolidayPolicy?) -> Void) {
        initial = policy; self.apply = apply
        _sourceKind = State(initialValue: policy == nil || policy?.origin != nil ? .country : .file)
        _country = State(initialValue: policy?.origin?.country ?? "")
        _countryName = State(initialValue: policy?.origin == nil ? "" : (policy?.region.components(separatedBy: " · ").first ?? policy?.origin?.country ?? ""))
        _subdivision = State(initialValue: policy?.origin?.subdivision ?? "")
        _yearText = State(initialValue: String(policy?.year ?? year)); _source = State(initialValue: policy?.source ?? "")
        _region = State(initialValue: policy?.region ?? ""); _mode = State(initialValue: policy?.mode ?? .skip)
        _weekends = State(initialValue: policy?.avoidWeekends ?? false)
    }
    private var year: Int? { yearText.utf8.count <= 4 ? Int(yearText).flatMap { (1...9999).contains($0) ? $0 : nil } : nil }
    private var days: [HolidayCalendarFile.Day]? {
        if sourceKind == .country, let countryCalendar, countryCalendar.year == year, countryCalendar.country == country { return countryCalendar.days(subdivision: subdivision.isEmpty ? nil : subdivision) }
        if sourceKind == .file, let imported, imported.year == year { return imported.days }
        if !sourceChanged, let initial, initial.year == year { return initial.dates.map { .init(date: $0, names: []) } }
        return nil
    }
    private var proposal: ReminderHolidayPolicy? {
        guard let year, let days, let digest = (sourceKind == .country ? countryCalendar?.digest : imported?.digest) ?? (!sourceChanged ? initial?.digest : nil) else { return nil }
        var raw: [String: JSON] = ["version": .number(1), "year": .number(Double(year)), "source": .string(source.trimmingCharacters(in: .whitespacesAndNewlines)), "region": .string(region.trimmingCharacters(in: .whitespacesAndNewlines)), "digest": .string(digest), "dates": .array(days.map { .string($0.date) }), "mode": .string(mode.rawValue), "avoid_weekends": .bool(weekends)]
        if sourceKind == .country {
            var origin: [String: JSON] = ["provider": .string("nager-v4"), "country": .string(country)]
            if !subdivision.isEmpty { origin["subdivision"] = .string(subdivision) }
            raw["origin"] = .object(origin)
        }
        return ReminderHolidayPolicy(raw: raw)
    }
    var body: some View {
        @Bindable var fileUI = fileUI
            Form {
                Section {
                    Picker("Source", selection: $sourceKind) {
                        ForEach(SourceKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.accessibilityIdentifier("holidaySourceKind")
                    sourceInput("Year", value: $yearText, field: .year, identifier: "holidayYear")
                    if year == nil { Text("Choose a year from 1 to 9999.").foregroundStyle(.red) }
                    if sourceKind == .country {
                        Button { focused = nil; choosingCountry = true } label: {
                            LabeledContent("Country", value: country.isEmpty ? "Choose country" : countryName)
                        }.accessibilityIdentifier("holidayCountry")
                        if countryCalendar == nil, !sourceChanged, let initial, initial.origin != nil {
                            Text(initial.region).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("holidaySavedRegion")
                        }
                        if let calendar = countryCalendar, !calendar.subdivisions.isEmpty {
                            Picker("Region", selection: $subdivision) {
                                Text("Nationwide only").tag("")
                                ForEach(calendar.subdivisions, id: \.self) { Text($0).tag($0) }
                            }.accessibilityIdentifier("holidaySubdivision")
                            Text("Regional codes follow ISO 3166-2. A selected region includes nationwide holidays; nationwide only excludes regional holidays.").font(.footnote).foregroundStyle(.secondary)
                        }
                        if !country.isEmpty {
                            Button { fetchCountry() } label: { Label("Refresh holiday dates", systemImage: "arrow.clockwise") }
                                .disabled(year == nil || loading).accessibilityIdentifier("holidayRefresh")
                        }
                        if loading { ProgressView("Fetching public holidays…") }
                    } else {
                        Button { chooseFile() } label: {
                            Label("Import holiday calendar", systemImage: "calendar.badge.plus").frame(minHeight: 44)
                        }.disabled(year == nil || loading).accessibilityIdentifier("holidayImport")
                        if loading { ProgressView("Reading calendar…") }
                        sourceInput("Calendar name", value: $source, field: .source, identifier: "holidaySource")
                        sourceInput("Region or organization", value: $region, field: .region, identifier: "holidayRegion")
                    }
                } header: { Text("Holiday calendar") } footer: {
                    if sourceKind == .country {
                        Text("Public holidays from Nager.Holidays load automatically when you choose a country or year. Only that country and year are sent to the service. Review the dates before applying; the saved calendar works offline. City, company and some locally announced holidays may be missing. Refresh to review updates; next year needs a new review.")
                    } else {
                        Text("Choose an all-day .ics calendar for the selected year. No account connection or calendar access is needed. Import updates this draft only. A calendar name and region or organization are required.")
                    }
                }
                Section {
                    Picker("On an excluded date", selection: $mode) {
                        Text("Skip alert").tag(ReminderHolidayPolicy.Mode.skip)
                        Text("Move to next available day").tag(ReminderHolidayPolicy.Mode.nextDay)
                    }.accessibilityIdentifier("holidayMode")
                    Toggle("Also avoid Saturday and Sunday", isOn: $weekends).accessibilityIdentifier("holidayWeekends")
                } header: { Text("Holiday policy") } footer: {
                    Text("The saved reminder time zone defines each date. Skipped dates still use the repeat count. Moves keep the clock time, merge alerts that reach the same day, and stay within the repeat end and reviewed year. The task’s plan does not move.")
                }
                if let days {
                    Section {
                        Text("\(days.count) \(days.count == 1 ? "excluded date" : "excluded dates") in \(yearText)").font(.headline).accessibilityIdentifier("holidayDateCount")
                        ForEach(days, id: \.date) { day in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(display(day.date)).fixedSize(horizontal: false, vertical: true)
                                if !day.names.isEmpty { Text(day.names.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                            }.accessibilityIdentifier("holidayDate-" + day.date)
                        }
                        if days.isEmpty { Text("This calendar has no matching public holidays in this year. Confirm that the calendar covers the entire year before using it.").foregroundStyle(.secondary) }
                        Toggle("I reviewed this calendar’s coverage for \(yearText)", isOn: $reviewed).accessibilityIdentifier("holidayReviewed")
                    } header: { Text("Review dates") } footer: {
                        Text("Alerts are scheduled only within this reviewed year. Review a new calendar to continue beyond it. The dates, calendar name and region sync with this task; event notes, links, attendees and file contents are excluded.")
                    }
                } else {
                    Section { Text("Choose a country or import a calendar for this year to review its dates.").foregroundStyle(.secondary) }
                }
                if initial != nil { Section { Button("Use ordinary calendar dates", role: .destructive) { apply(nil); dismiss() }.accessibilityIdentifier("holidayRemove") } }
            }.formStyle(.grouped).scrollDismissesKeyboard(.interactively).navigationTitle("Holiday dates")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline).navigationBarBackButtonHidden(true)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("holidayCancel") }
                ToolbarItem(placement: .confirmationAction) { Button("Apply") { if let proposal { apply(proposal); dismiss() } }.disabled(!reviewed || proposal == nil || loading).accessibilityIdentifier("holidayApply") }
            }
        .navigationDestination(isPresented: $choosingCountry) {
            HolidayCountryChooser { choice in
                country = choice.countryCode; countryName = choice.name
                subdivision = ""; fetchCountry()
            }
        }
        .onChange(of: sourceKind) { _, _ in invalidateSource(); countryCalendar = nil; imported = nil }
        .onChange(of: yearText) { _, _ in invalidateSource(); if sourceKind == .country, !country.isEmpty { fetchCountry() } }
        .onChange(of: subdivision) { _, _ in
            reviewed = false
            if countryCalendar != nil { source = "Nager.Holidays"; region = countryName + (subdivision.isEmpty ? " · Nationwide" : " · " + subdivision); sourceChanged = true }
        }
        .onDisappear { operation = UUID(); reader?.cancel(); loading = false; fileUI.cancel() }
        #if os(iOS)
        .sheet(item: $fileUI.presented) { request in
            HolidayCalendarFilePicker { result in
                guard fileUI.session.accepts(request, workspace: fileUI.scope) else { return }
                switch result {
                case .success(let url):
                    let selection = fileUI.session.select(url, for: request, workspace: fileUI.scope)
                    fileUI.presented = nil
                    if let selection { load(selection.url) }
                case .failure(let error):
                    fileUI.session.cancel(request); fileUI.presented = nil
                    if (error as NSError).code != NSUserCancelledError { message = error.localizedDescription }
                }
            }.onDisappear {
                if let selection = fileUI.session.close(request, workspace: fileUI.scope) { load(selection.url) }
            }.presentationDetents([.large]).presentationDragIndicator(.visible)
        }
        #else
        .fileImporter(isPresented: $choosing, allowedContentTypes: [UTType(filenameExtension: "ics") ?? .data]) { result in
            switch result {
            case .success(let url): load(url)
            case .failure(let error): if (error as NSError).code != NSUserCancelledError { message = error.localizedDescription }
            }
        }
        #endif
        .alert("Calendar not changed", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK") { message = nil } } message: { Text(message ?? "") }
        #if os(macOS)
        .frame(minWidth: 540, minHeight: 570)
        #endif
    }
    private func chooseFile() {
        focused = nil
        #if os(iOS)
        fileUI.presented = fileUI.session.begin(workspace: fileUI.scope)
        #else
        choosing = true
        #endif
    }
    private func sourceInput(_ label: String, value: Binding<String>, field: Field, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("", text: value).labelsHidden().focused($focused, equals: field)
                .accessibilityLabel(label == "Year" ? "Holiday calendar year" : label == "Calendar name" ? "Holiday calendar name" : "Holiday region or organization")
                .accessibilityIdentifier(identifier)
                .onSubmit { focused = field == .source ? .region : nil }
                #if os(iOS)
                .keyboardType(field == .year ? .numbersAndPunctuation : .default)
                #endif
        }
    }
    private func load(_ url: URL) {
        guard let year else { return }
        let previousSource = source
        let token = UUID(); operation = token; reader?.cancel(); loading = true
        reader = Task { @MainActor in
            do {
                let calendar = try await Task.detached(priority: .userInitiated) { try HolidayCalendarFile(data: HolidayCalendarFile.read(url), year: year) }.value
                guard !Task.isCancelled, operation == token, self.year == year else { return }
                imported = calendar; if source == previousSource { source = String(calendar.name.prefix(160)) }; sourceChanged = true; reviewed = false; loading = false
            } catch {
                guard !Task.isCancelled, operation == token else { return }
                loading = false; message = error.localizedDescription
            }
        }
    }
    private func invalidateSource() {
        reviewed = false; sourceChanged = true; operation = UUID(); reader?.cancel(); loading = false; fileUI.cancel()
    }
    private func fetchCountry() {
        invalidateSource(); countryCalendar = nil
        guard let year, !country.isEmpty else { return }
        let code = country, token = UUID(); operation = token; loading = true
        reader = Task { @MainActor in
            do {
                let data = try await CountryHolidayCalendar.fetch(CountryHolidayCalendar.request(country: code, year: year))
                let calendar = try CountryHolidayCalendar.snapshot(data: data, year: year, country: code)
                guard !Task.isCancelled, operation == token, self.year == year, country == code, sourceKind == .country else { return }
                countryCalendar = calendar
                if !subdivision.isEmpty, !calendar.subdivisions.contains(subdivision) { subdivision = "" }
                source = "Nager.Holidays"; region = countryName + (subdivision.isEmpty ? " · Nationwide" : " · " + subdivision)
                reviewed = false; loading = false
            } catch {
                guard !Task.isCancelled, operation == token else { return }
                loading = false; message = "Couldn’t fetch public holidays. Check your connection and try again, or choose Calendar file. Your saved reminder is unchanged."
            }
        }
    }
    private func display(_ key: String) -> String {
        guard let day = ReminderCivilDay(key) else { return key }
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.gregorianStartDate = Date(timeIntervalSince1970: -62_135_596_800); formatter.dateStyle = .full
        return formatter.string(from: Date(timeIntervalSince1970: Double(day.serial * 86400 + 43200)))
    }
}

@MainActor @Observable private final class HolidayCalendarTransfer {
    let scope = UUID()
    var session = BackupPickerSession()
    var presented: BackupPickerSession.Request?
    func cancel() {
        if let request = session.request { session.cancel(request) }
        presented = nil
    }
}

#if os(iOS)
/// An app-owned cancellation control stays accessible above the system browser.
/// The selected URL is handed back only after its containing sheet dismisses.
private struct HolidayCalendarFilePicker: UIViewControllerRepresentable {
    let completion: (Result<URL, Error>) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UINavigationController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType(filenameExtension: "ics") ?? .data], asCopy: false)
        picker.delegate = context.coordinator
        let host = UIViewController(); host.title = "Choose calendar"
        host.addChild(picker); host.view.addSubview(picker.view)
        picker.view.translatesAutoresizingMaskIntoConstraints = false; picker.view.clipsToBounds = true
        NSLayoutConstraint.activate([
            picker.view.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            picker.view.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
            picker.view.topAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.topAnchor),
            picker.view.bottomAnchor.constraint(equalTo: host.view.bottomAnchor)
        ])
        picker.didMove(toParent: host)
        let cancel = UIBarButtonItem(title: "Cancel", style: .plain, target: context.coordinator, action: #selector(Coordinator.cancel))
        cancel.accessibilityIdentifier = "holidayFilePickerCancel"; host.navigationItem.rightBarButtonItem = cancel
        return UINavigationController(rootViewController: host)
    }
    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (Result<URL, Error>) -> Void
        init(completion: @escaping (Result<URL, Error>) -> Void) { self.completion = completion }
        @objc func cancel() { completion(.failure(CocoaError(.userCancelled))) }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { completion(.success(url)) } else { cancel() }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { cancel() }
    }
}
#endif

private struct HolidayCountryChooser: View {
    @Environment(\.dismiss) private var dismiss
    let choose: (CountryHolidayCalendar.Country) -> Void
    @State private var countries: [CountryHolidayCalendar.Country] = []
    @State private var query = ""
    @State private var loading = false
    @State private var failed = false
    var body: some View {
        List {
            if loading { ProgressView("Loading countries…") }
            if failed {
                Text("Couldn’t load countries. Check your connection and try again.").foregroundStyle(.secondary)
                Button("Try again") { Task { await load() } }.accessibilityIdentifier("holidayCountriesRetry")
            }
            ForEach(countries.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.countryCode.localizedCaseInsensitiveContains(query) }) { country in
                Button(country.name) { choose(country); dismiss() }.accessibilityIdentifier("holidayCountry-" + country.countryCode)
            }
        }.navigationTitle("Choose country").searchable(text: $query, prompt: "Search countries")
        .task { await load() }
    }
    @MainActor private func load() async {
        loading = true; failed = false
        do {
            let data = try await CountryHolidayCalendar.fetch(CountryHolidayCalendar.request())
            let result = try CountryHolidayCalendar.countries(data: data)
            guard !Task.isCancelled else { return }; countries = result; loading = false
        } catch { guard !Task.isCancelled else { return }; loading = false; failed = true }
    }
}
