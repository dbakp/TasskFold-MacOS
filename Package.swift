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
            sources: ["TaskActivity.swift", "FocusWidget.swift", "FocusSession.swift", "QuickPlanningCompletion.swift", "QuickReferenceCompletion.swift", "Recurrence.swift", "PinnedNotes.swift", "InboxReview.swift", "Models.swift", "WidgetActions.swift", "WidgetCompletion.swift", "Backend.swift", "Filters.swift", "Planner.swift", "CalendarEvents.swift", "Backups.swift", "Reminders.swift"]
        ),
        .target(
            name: "WidgetModel",
            dependencies: ["TaskfoldCore"],
            path: "TaskfoldWidgets",
            exclude: ["Info.plist", "TaskfoldWidgets.entitlements"],
            sources: ["TaskfoldWidgets.swift"],
            swiftSettings: [.define("WIDGET_MODEL_TESTING")]
        ),
        .testTarget(name: "TaskfoldCoreTests", dependencies: ["TaskfoldCore", "WidgetModel"], path: "TaskfoldTests")
    ]
)
