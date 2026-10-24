import Foundation

/// A task-local review of portable schedules. Private, future and non-local rows
/// are retained byte-for-byte as JSON values and never become editable choices.
struct TeamTaskRemindersDraft: Equatable {
    let original: JSON
    private(set) var rows: [JSON]
    let supported: Bool
    init(_ value: JSON) {
        original = value
        var ids = Set<String>()
        if case .array(let rows) = value, rows.count <= ReminderSpec.maximum,
           rows.allSatisfy({ row in
               guard case .object(let fields) = row, case .string(let id)? = fields["id"], UUID(uuidString: id) != nil else { return false }
               return ids.insert(id.lowercased()).inserted
           }) { self.rows = rows; supported = true }
        else if value == .null { rows = []; supported = true }
        else { rows = []; supported = false }
    }
    var value: JSON { supported ? .array(rows) : original }
    var changed: Bool { supported && (original == .null ? !rows.isEmpty : value != original) }
    func editable(_ index: Int) -> ReminderSpec? {
        guard supported, rows.indices.contains(index), let spec = ReminderSpec(row: rows[index]), spec.locallyEditable else { return nil }
        return spec
    }
    var plannedEnabled: Bool { rows.isEmpty || rows.indices.contains { editable($0).map { $0.id == ReminderSpec.plannedID && $0.enabled } == true } }
    var plannedEditable: Bool {
        guard supported else { return false }
        if let index = rows.firstIndex(where: { $0.object["id"]?.text.lowercased() == ReminderSpec.plannedID }) { return editable(index) != nil }
        return rows.count < ReminderSpec.maximum
    }
    mutating func setPlanned(_ enabled: Bool) throws {
        guard plannedEditable else { throw Self.invalid }
        var task = Record(["reminder_specs": .array(rows)])
        guard ReminderSpec.setPlanned(enabled, task: &task) else { throw Self.duplicate }
        rows = task["reminder_specs"].list
    }
    mutating func save(_ proposed: ReminderSpec, replacing index: Int?, opening: [JSON]) throws {
        guard supported, rows == opening, proposed.locallyEditable, ReminderSpec(row: .object(proposed.raw)) != nil, UUID(uuidString: proposed.id) != nil else { throw Self.invalid }
        var spec = proposed
        if let index {
            guard let old = editable(index), old.id == proposed.id else { throw Self.invalid }
            spec = try Self.preservingExtensions(from: old, in: proposed)
            guard !ReminderSpec.duplicates(spec, in: rows, excluding: old.id) else { throw Self.duplicate }
            rows[index] = .object(spec.raw)
        } else {
            guard proposed.id != ReminderSpec.plannedID else { throw Self.invalid }
            var values = rows
            if values.isEmpty { values = [.object(ReminderSpec.relative(0, id: ReminderSpec.plannedID).raw)] }
            guard values.count < ReminderSpec.maximum, !values.contains(where: { $0.object["id"]?.text.lowercased() == spec.id }) else { throw Self.invalid }
            guard !ReminderSpec.duplicates(spec, in: values) else { throw Self.duplicate }
            values.append(.object(spec.raw)); rows = values
        }
    }
    mutating func remove(_ index: Int) throws {
        guard let spec = editable(index), spec.id != ReminderSpec.plannedID else { throw Self.invalid }
        rows.remove(at: index)
        if rows.isEmpty { rows = [.object(ReminderSpec.relative(0, id: ReminderSpec.plannedID, enabled: false).raw)] }
    }
    static var invalid: AppFailure { AppFailure(message: "These reminder settings changed or need their original app. Reopen the current choices; your draft is kept.") }
    static var duplicate: AppFailure { AppFailure(message: "A reminder is already enabled for this time. Choose another time or turn the existing reminder off.") }
    /// Match the existing service extension-preservation contract, including a
    /// kind/policy change that removes an old known schedule but keeps future data.
    static func preservingExtensions(from old: ReminderSpec, in new: ReminderSpec) throws -> ReminderSpec {
        guard old.id == new.id, old.locallyEditable, new.locallyEditable else { throw invalid }
        var raw = new.raw
        let rowKnown: Set<String> = ["version","id","kind","enabled","channels","anchor","offset_minutes","at","time_zone","start_day","time","recurrence","interval_schedule","holiday_policy","schedule_version","presentation","taskfold_default_placeholder"]
        for (key, value) in old.raw where !rowKnown.contains(key) { raw[key] = value }
        func retain(_ key: String, known: Set<String>) {
            let extras = (old.raw[key]?.object ?? [:]).filter { !known.contains($0.key) }
            guard !extras.isEmpty else { return }
            var fields = raw[key]?.object ?? [:]; for (k,v) in extras { fields[k] = v }; raw[key] = .object(fields)
        }
        retain("recurrence", known: ["type","interval","daysOfWeek","dayOfMonth","daysOfMonth","monthOfYear","weekday","weekdayOrdinal","count","endDate","fromCompletion"])
        retain("interval_schedule", known: ["start_ms","every_minutes","count","until_ms"])
        retain("holiday_policy", known: ["version","year","dates","source","region","digest","mode","avoid_weekends","origin"])
        let originExtras = (old.raw["holiday_policy"]?.object["origin"]?.object ?? [:]).filter { !["provider","country","subdivision"].contains($0.key) }
        if !originExtras.isEmpty {
            var holiday = raw["holiday_policy"]?.object ?? [:], origin = holiday["origin"]?.object ?? [:]
            for (key,value) in originExtras { origin[key] = value }; holiday["origin"] = .object(origin); raw["holiday_policy"] = .object(holiday)
        }
        guard let spec = ReminderSpec(row: .object(raw)) else { throw invalid }; return spec
    }
}
