import XCTest
@testable import TaskfoldCore

/// Places set once in Settings (design review round 9): sizes, names, contact addresses, Mac requests by name,
/// re-pointing reminders after a move (D2) and the 30-day cleanup of ended history (D7).
final class PlacesSettingsTests: XCTestCase {
    let account = "places-local"
    let device = "96000000-0000-4000-8000-000000000001"
    private func place(_ name: String, radius: Int = 250, latitude: Double = 55.676098) throws -> LocationPrivatePlace {
        try XCTUnwrap(LocationPrivatePlace.make(account: account, name: name, latitude: latitude, longitude: 12.568337, radius: radius))
    }

    // MARK: Sizes

    func testSizesAreWordsOverMetresAndExistingRadiiStayCustom() {
        XCTAssertEqual(LocationPlaceSize.allCases.map(\.metres), [100, 250, 1000])
        XCTAssertEqual(LocationPlaceSize.matching(250), .medium)
        XCTAssertNil(LocationPlaceSize.matching(500), "an existing 500 m place keeps its exact metres")
        XCTAssertEqual(LocationPlaceSize.distance(150), "150 m"); XCTAssertEqual(LocationPlaceSize.distance(1000), "1 km")
        XCTAssertEqual(LocationPlaceSize.medium.accessibilityValue, "Medium, about 250 metres")
    }

    // MARK: Names

    func testNameMatchingIgnoresCaseAccentsAndTheOrMy() throws {
        let gym = try place("Gym"), cafe = try place("Café")
        XCTAssertEqual(LocationPlaceName.match("the gym", in: [gym, cafe])?.id, gym.id)
        XCTAssertEqual(LocationPlaceName.match("my Gym", in: [gym])?.id, gym.id)
        XCTAssertEqual(LocationPlaceName.match("cafe", in: [gym, cafe])?.id, cafe.id)
        XCTAssertNil(LocationPlaceName.match("the", in: [gym]))
        XCTAssertEqual(LocationPlaceName.display("the gym"), "Gym")
        XCTAssertEqual(LocationPlaceName.glyph(for: "home"), "house"); XCTAssertEqual(LocationPlaceName.glyph(for: "Work"), "briefcase"); XCTAssertNil(LocationPlaceName.glyph(for: "Gym"))
    }

    func testQuickAddFindsSavedPlacesAfterTheOrMy() {
        let found = QuickEntry.place(in: "Stretch at the gym", names: ["Gym"])
        XCTAssertEqual(found?.choice.name, "Gym"); XCTAssertEqual(found?.title, "Stretch")
        XCTAssertEqual(QuickEntry.place(in: "Water plants at my home", names: ["Home"])?.choice.name, "Home")
    }

    func testQuickAddOffersAnUnknownPlaceOnlyForAShortPlainPhraseAtTheEnd() {
        let gym = QuickEntry.unknownPlace(in: "Stretch for ten minutes at the gym", names: ["Home"])
        XCTAssertEqual(gym?.name, "Gym"); XCTAssertEqual(gym?.raw, "at the gym")
        XCTAssertNil(QuickEntry.unknownPlace(in: "Stretch at the gym", names: ["Gym"]), "a saved place is not unknown")
        XCTAssertNil(QuickEntry.unknownPlace(in: "Call at noon", names: []))
        XCTAssertNil(QuickEntry.unknownPlace(in: "at home", names: []), "a title needs words before the place")
        XCTAssertNil(QuickEntry.unknownPlace(in: "Meet at 5 pm", names: []))
        XCTAssertNil(QuickEntry.unknownPlace(in: "Look at the long list of things", names: []), "more than two words is not a place")
        XCTAssertEqual(QuickEntry.unknownPlace(in: "Buy milk at Mum's", names: [])?.name, "Mum's")
    }

    // MARK: Place details stay on the device and never change the boundary

    func testDetailGlyphAndSourceAreOptionalAndKeepTheRevision() throws {
        let home = try place("Home")
        let described = try XCTUnwrap(home.describing(detail: "Linden Allé 14", glyph: "house"))
        XCTAssertEqual(described.detail, "Linden Allé 14"); XCTAssertEqual(described.glyph, "house"); XCTAssertEqual(described.revision, home.revision)
        var raw = described.raw; raw["source"] = .string("card")
        XCTAssertEqual(LocationPrivatePlace(raw: raw)?.source, "card")
        raw["detail"] = .number(3); XCTAssertNil(LocationPrivatePlace(raw: raw), "a malformed detail is refused")
        var archive = LocationPrivateArchive(device: device); archive.places = [described.raw]
        XCTAssertTrue(archive.valid)
        let moved = try XCTUnwrap(described.editing(name: "Home", latitude: 55.7, longitude: 12.568337, radius: 250))
        XCTAssertNotEqual(moved.revision, described.revision); XCTAssertEqual(moved.detail, "Linden Allé 14")
    }

    // MARK: Contact card addresses

    func testOwnCardHomeAndWorkBecomeThosePlacesAndOtherContactsUseTheirName() {
        let home = LocationContactAddress(label: "_$!<Home>!$_", street: "Linden Allé 14\nFloor 2", city: "Frederiksberg", postalCode: "2000", country: "Denmark")
        XCTAssertEqual(home.ownCardRole, "Home")
        XCTAssertEqual(home.placeName(contactName: "Alex Example", ownCard: true), "Home")
        XCTAssertEqual(home.placeName(contactName: "Mum", ownCard: false), "Mum")
        XCTAssertEqual(home.query, "Linden Allé 14, Floor 2, 2000 Frederiksberg, Denmark")
        XCTAssertEqual(home.firstLine, "Linden Allé 14")
        let work = LocationContactAddress(label: "_$!<Work>!$_", street: "Harbour Street 2", city: "Copenhagen")
        XCTAssertEqual(work.placeName(contactName: "", ownCard: true), "Work")
        let cabin = LocationContactAddress(label: "cabin", street: "Fjordvej 1", city: "Hornbæk")
        XCTAssertNil(cabin.ownCardRole)
        XCTAssertEqual(cabin.placeName(contactName: "Alex Example", ownCard: true), "Cabin")
        XCTAssertEqual(LocationContactAddress(label: nil, street: "Fjordvej 1").placeName(contactName: "", ownCard: false), "Fjordvej 1")
        XCTAssertNil(LocationContactAddress(label: "_$!<Home>!$_", country: "Denmark").query, "a country alone is not an address")
    }

    // MARK: Mac requests carry only a name

    func testMacRequestSyncsOnlyTheNameAndBecomesTheIPhonesOwnReminder() throws {
        let home = try place("Home")
        var archive = LocationPrivateArchive(device: device); archive.places = [home.raw]
        let workspace = WorkspaceBinding(account: account, generation: UUID())
        let request = try XCTUnwrap(LocationPlaceRequest.make(name: "home", transition: .arrive))
        var task = Record.task(user: account); task["title"] = .string("Water plants")
        task["reminder_specs"] = .array([.object(request.raw)])
        let synced = String(decoding: try JSONEncoder().encode(task), as: UTF8.self)
        for forbidden in ["latitude", "longitude", "radius", "place_id"] { XCTAssertFalse(synced.contains(forbidden), forbidden) }
        XCTAssertNil(ReminderSpec(row: .object(request.raw)), "a request is never a time reminder")
        XCTAssertEqual(LocationPlaceRequest.all(task), [request]); XCTAssertEqual(request.label, "Arrive at home")
        // The iPhone matches the name to its own place and replaces the request with a location reminder.
        let matched = try XCTUnwrap(LocationPlaceName.match(request.name, in: archive.places(for: account)))
        let without = try XCTUnwrap(request.removing(from: task))
        let review = try XCTUnwrap(LocationReminderReview(workspace: workspace, task: without, archive: archive, place: matched, transition: request.transition, repeats: request.repeats, requestedName: request.name))
        let changed = try XCTUnwrap(review.applying(to: without, archive: archive, workspace: workspace))
        XCTAssertTrue(LocationPlaceRequest.all(changed).isEmpty)
        let settings = try XCTUnwrap(ReminderSpec.rows(changed).compactMap { LocationReminderSettings(raw: $0.object) }.first)
        XCTAssertEqual(settings.placeID, home.id); XCTAssertEqual(settings.requestedName, "home")
        XCTAssertTrue(review.permitsSaved(changed, archive: archive, workspace: workspace))
        // Choosing another place drops the Mac's name.
        let work = try place("Work", latitude: 55.69)
        archive.places.append(work.raw)
        let other = try XCTUnwrap(LocationReminderReview(workspace: workspace, task: changed, archive: archive, place: work, transition: .leave, replacing: settings))
        XCTAssertNil(other.settings.requestedName)
    }

    func testMalformedRequestsAreKeptAsUnsupported() {
        var raw = LocationPlaceRequest.make(name: "Home", transition: .leave)!.raw
        raw["place_request"] = .object(["name": .string("Home"), "transition": .string("leave"), "latitude_e6": .number(1)])
        XCTAssertNil(LocationPlaceRequest(raw: raw), "a request with coordinates is refused")
        XCTAssertNil(LocationPlaceRequest.make(name: "  ", transition: .arrive))
    }

    // MARK: D2: moving a place updates every task that uses it

    func testMovingAPlaceFindsEveryReminderOnTheOldRevision() throws {
        let home = try place("Home")
        var archive = LocationPrivateArchive(device: device); archive.places = [home.raw]
        let workspace = WorkspaceBinding(account: account, generation: UUID())
        var task = Record.task(user: account); task["title"] = .string("Bring the parcel")
        let review = try XCTUnwrap(LocationReminderReview(workspace: workspace, task: task, archive: archive, place: home, transition: .arrive, repeats: true))
        task = try XCTUnwrap(review.applying(to: task, archive: archive, workspace: workspace))
        XCTAssertEqual(LocationPlaceUsage.count(placeID: home.id, device: device, tasks: [task]), 1)
        let moved = try XCTUnwrap(home.editing(name: "Home", latitude: 55.68, longitude: 12.568337, radius: 1000))
        let stale = LocationPlaceUsage.stale(place: moved, device: device, tasks: [task])
        XCTAssertEqual(stale.count, 1)
        archive.places = [moved.raw]
        let rearmed = try XCTUnwrap(LocationReminderReview(workspace: workspace, task: task, archive: archive, place: moved, transition: stale[0].settings.transition, repeats: stale[0].settings.repeats, replacing: stale[0].settings))
        let updated = try XCTUnwrap(rearmed.applying(to: task, archive: archive, workspace: workspace))
        XCTAssertEqual(rearmed.settings.id, review.settings.id, "the reminder keeps its identity")
        XCTAssertNotEqual(rearmed.settings.arm, review.settings.arm, "a fresh arm replaces the old boundary")
        XCTAssertEqual(rearmed.settings.placeRevision, moved.revision); XCTAssertTrue(rearmed.settings.repeats)
        XCTAssertTrue(LocationPlaceUsage.stale(place: moved, device: device, tasks: [updated]).isEmpty)
        // A renamed place keeps its revision, so nothing needs updating.
        let renamed = try XCTUnwrap(moved.editing(name: "Home sweet home", latitude: 55.68, longitude: 12.568337, radius: 1000))
        XCTAssertTrue(LocationPlaceUsage.stale(place: renamed, device: device, tasks: [updated]).isEmpty)
        // Removing the place removes its reminders; the task stays.
        let without = try XCTUnwrap(LocationPlaceUsage.removing(placeID: moved.id, device: device, from: updated))
        XCTAssertTrue(ReminderSpec.rows(without).allSatisfy { LocationReminderSettings(raw: $0.object) == nil })
        XCTAssertNil(LocationPlaceUsage.removing(placeID: moved.id, device: device, from: without))
        XCTAssertEqual(LocationPlaceUsage.count(placeID: moved.id, device: "96000000-0000-4000-8000-000000000002", tasks: [updated]), 0, "another device's reminders don't count")
    }

    // MARK: D7: ended history goes after 30 days

    func testEndedHistoryIsSelectedOnlyAfterThirtyDays() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = LocationEndedHistory.select(ended: ["a", "b"], seen: [:], now: start)
        XCTAssertTrue(first.expired.isEmpty); XCTAssertEqual(Set(first.seen.keys), ["a", "b"])
        let later = LocationEndedHistory.select(ended: ["a", "c"], seen: first.seen, now: start.addingTimeInterval(29 * 86_400))
        XCTAssertTrue(later.expired.isEmpty); XCTAssertNil(later.seen["b"], "a record no longer ended is forgotten"); XCTAssertNotNil(later.seen["c"])
        let month = LocationEndedHistory.select(ended: ["a", "c"], seen: later.seen, now: start.addingTimeInterval(30 * 86_400))
        XCTAssertEqual(month.expired, ["a"])
    }

    func testScopedCleanupRemovesOnlyTheNamedEndedRecords() throws {
        let home = try place("Home")
        let workspace = WorkspaceBinding(account: account, generation: UUID())
        var archive = LocationPrivateArchive(device: device); archive.places = [home.raw]
        let task = Record.task(user: account)
        let review = try XCTUnwrap(LocationReminderReview(workspace: workspace, task: task, archive: archive, place: home, transition: .arrive))
        let saved = try XCTUnwrap(review.applying(to: task, archive: archive, workspace: workspace))
        let ticket = try XCTUnwrap(LocationReminderTicket.bound(account: account, task: saved, settings: review.settings))
        archive.journal.version = 2; archive.journal.revoked = [ticket.identifier]
        archive.journal.entries[ticket.identifier] = .init(ticket: ticket, phase: .closed, reason: .cancelled)
        XCTAssertTrue(archive.valid)
        let records = ["one", "two"].map { tag -> LocationNotificationAction in
            LocationNotificationAction(source: "la1:" + LocationReminderIdentity.digest([tag]), ticket: ticket, action: .complete, fireAt: nil, phase: .closed, end: .consumed)
        }
        let ledger = Dictionary(uniqueKeysWithValues: records.map { ($0.source, $0) })
        var cleanup = try LocationActionCleanup(account: account, archive: archive)
        XCTAssertEqual(try cleanup.retaining(ledger).count, 0)
        cleanup.only = [records[0].source]
        XCTAssertEqual(Set(try cleanup.retaining(ledger).keys), [records[1].source])
    }

    // MARK: Leftovers: Mac Quick Add "at <place>", retired Mac drafts, Skip holidays as a toggle

    func testMacQuickAddRecognisesUsedNamesAnywhereAndOffersNewNamesAtTheEnd() throws {
        let known = QuickPlaceRequest.find(in: "Buy milk at home on the way", known: ["Home"])
        XCTAssertEqual(known?.name, "Home"); XCTAssertEqual(known?.title, "Buy milk on the way"); XCTAssertEqual(known?.known, true); XCTAssertEqual(known?.transition, .arrive)
        XCTAssertTrue(known?.applies(accepted: nil) == true, "a name used before applies by itself")
        let leaving = QuickPlaceRequest.find(in: "Call Sam leave work", known: ["Work"])
        XCTAssertEqual(leaving?.transition, .leave); XCTAssertEqual(leaving?.label, "Leave Work"); XCTAssertEqual(leaving?.title, "Call Sam")
        let fresh = try XCTUnwrap(QuickPlaceRequest.find(in: "Buy milk at Home", known: []))
        XCTAssertEqual(fresh.name, "Home"); XCTAssertEqual(fresh.raw, "at Home"); XCTAssertEqual(fresh.title, "Buy milk"); XCTAssertFalse(fresh.known)
        XCTAssertFalse(fresh.applies(accepted: nil), "a new name is only offered")
        XCTAssertTrue(fresh.applies(accepted: "at Home")); XCTAssertFalse(fresh.applies(accepted: "at Hom"))
        XCTAssertNil(QuickPlaceRequest.find(in: "Call Sam at 4pm", known: []))
        XCTAssertEqual(fresh.request?.name, "Home"); XCTAssertEqual(fresh.request?.transition, .arrive)
    }

    func testKnownNamesComeFromRequestsAndTheRemindersTheyBecame() throws {
        var a = Record.task(user: account), b = Record.task(user: account)
        a = try XCTUnwrap(LocationPlaceRequest.make(name: "Gym", transition: .arrive)!.adding(to: a))
        b = try XCTUnwrap(LocationPlaceRequest.make(name: "the gym", transition: .leave)!.adding(to: b))
        b = try XCTUnwrap(LocationPlaceRequest.make(name: "Home", transition: .leave)!.adding(to: b))
        XCTAssertEqual(LocationPlaceRequest.knownNames(in: [a, b]), ["Gym", "Home"], "case and a leading the fold into one name")
    }

    func testAddingARequestKeepsTheLegacyDefaultAndNeverDuplicates() throws {
        let request = try XCTUnwrap(LocationPlaceRequest.make(name: "Home", transition: .arrive))
        let task = Record.task(user: account)
        let added = try XCTUnwrap(request.adding(to: task))
        XCTAssertEqual(ReminderSpec.rows(added).count, 2, "the legacy at-planned-time default stays alongside")
        XCTAssertEqual(LocationPlaceRequest.all(added).map(\.name), ["Home"])
        XCTAssertNil(LocationPlaceRequest.make(name: "home", transition: .arrive)!.adding(to: added), "the same place and direction is asked once")
        XCTAssertNotNil(LocationPlaceRequest.make(name: "Home", transition: .leave)!.adding(to: added))
        var done = task; done["completed"] = .bool(true); done["completed_at"] = .string("2026-11-19T10:00:00Z")
        XCTAssertNil(request.adding(to: done))
    }

    func testARetiredMacDraftBecomesARequestByNameWithoutItsPin() throws {
        let owner = "96000000-0000-4000-8000-0000000000aa"
        let raw: [String: JSON] = ["version": .number(1), "id": .string("96000000-0000-4000-8000-0000000000b1"), "task_id": .string("96000000-0000-4000-8000-0000000000b2"),
                                   "task_generation": .string("96000000-0000-4000-8000-0000000000b3"), "completion_version": .number(0), "authored_at_ms": .number(1_800_000_000_000),
                                   "place_name": .string("Studio"), "latitude_e6": .number(55_676_098), "longitude_e6": .number(12_568_337), "radius_m": .number(150),
                                   "transition": .string("leave"), "repeats": .bool(true)]
        let proposal = try XCTUnwrap(LocationHandoffProposal(account: owner, raw: raw))
        let request = try XCTUnwrap(LocationPlaceRequest.converting(proposal))
        XCTAssertEqual(request.name, "Studio"); XCTAssertEqual(request.transition, .leave); XCTAssertTrue(request.repeats)
        XCTAssertEqual(Set(request.request.keys), ["name", "transition", "repeats"], "no pin or radius is kept")
    }

    func testSkipHolidaysBuildsANationwidePolicyFromTheDefaultCountry() throws {
        let data = Data(#"[{"date":"2027-01-01","name":"Nytårsdag","countryCode":"DK","nationalHoliday":true,"subdivisionCodes":null,"holidayTypes":["Public"]},{"date":"2027-06-05","name":"Regional","countryCode":"DK","nationalHoliday":false,"subdivisionCodes":["DK-84"],"holidayTypes":["Public"]},{"date":"2027-12-25","name":"Juledag","countryCode":"DK","nationalHoliday":true,"subdivisionCodes":null,"holidayTypes":["Public"]}]"#.utf8)
        let snapshot = try CountryHolidayCalendar.snapshot(data: data, year: 2027, country: "DK")
        let policy = try XCTUnwrap(CountryHolidayCalendar.policy(snapshot, countryName: "Denmark"))
        XCTAssertEqual(policy.dates, ["2027-01-01", "2027-12-25"], "regional days are left out")
        XCTAssertEqual(policy.region, "Denmark · Nationwide"); XCTAssertEqual(policy.source, "Nager.Holidays"); XCTAssertEqual(policy.mode, .skip)
        XCTAssertEqual(policy.origin?.country, "DK"); XCTAssertNil(policy.origin?.subdivision); XCTAssertEqual(policy.year, 2027)
        XCTAssertEqual(CountryHolidayCalendar.policy(snapshot, countryName: "", mode: .nextDay, avoidWeekends: true)?.region, "DK · Nationwide")
    }
}
