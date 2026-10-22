// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TaskfoldCore",
    platforms: [.macOS("15.0")],
    products: [.library(name: "TaskfoldCore", targets: ["TaskfoldCore"])],
    targets: [
        .target(
            name: "TaskfoldCore",
            path: "Taskfold/Core",
            exclude: ["Store.swift", "Intents.swift", "WidgetActionTestPanel.swift"],
            sources: ["AccountRemoval.swift", "LocationPlaceStore.swift", "LocationReminders.swift", "HolidayCalendar.swift", "ReminderIntervalSchedule.swift", "VoiceDraft.swift", "RowGesture.swift", "PrintDocument.swift", "TaskPrintRenderer.swift", "NoteMarkup.swift", "NoteFormatting.swift", "SharedCapture.swift", "SharedCapturePlan.swift", "SubtaskTree.swift", "ProjectWorkflows.swift", "CapturePresentation.swift", "TodoistImport.swift", "ReminderDevices.swift", "ProjectPulseWidget.swift", "TaskActivity.swift", "SharedComments.swift", "FocusWidget.swift", "FocusSession.swift", "QuickPlanningCompletion.swift", "QuickReferenceCompletion.swift", "Recurrence.swift", "PinnedNotes.swift", "InboxReview.swift", "Models.swift", "WidgetActions.swift", "WidgetCompletion.swift", "Backend.swift", "Filters.swift", "Planner.swift", "CalendarEvents.swift", "CloudCalendars.swift", "CalendarCredentials.swift", "CalendarLinksFixture.swift", "Backups.swift", "Reminders.swift"]
        ),
        .target(
            name: "WidgetModel",
            dependencies: ["TaskfoldCore"],
            path: "TaskfoldWidgets",
            exclude: ["Info.plist", "TaskfoldWidgets.entitlements"],
            sources: ["TaskfoldWidgets.swift"],
            swiftSettings: [.define("WIDGET_MODEL_TESTING")]
        ),
        .testTarget(name: "TaskfoldCoreTests", dependencies: ["TaskfoldCore", "WidgetModel"], path: "TaskfoldTests", resources: [.copy("Fixtures")])
    ]
)
