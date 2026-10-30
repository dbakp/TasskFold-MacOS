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
            sources: ["WearableReceipts.swift", "EmailCapture.swift", "WebhookAccess.swift", "AutomationAccess.swift", "TeamProjectAccess.swift", "TeamWorkspace.swift", "TeamTaskRecipients.swift", "TeamTaskLabels.swift", "TeamTaskReminders.swift", "TeamTaskRecurrence.swift", "TeamOrganization.swift", "TeamOrganizationCommand.swift", "TeamProjectManagement.swift", "TeamTemplateLibrary.swift", "TeamTemplateCommands.swift", "TeamWorkflowRunCommands.swift", "TeamTaskMove.swift", "TeamProjectAdoption.swift", "TeamChecklist.swift", "TeamCompletion.swift", "TeamCompletionDraft.swift", "TeamTaskBatch.swift", "AccountRemoval.swift", "LocationPlaceStore.swift", "LocationReminders.swift", "HolidayCalendar.swift", "ReminderIntervalSchedule.swift", "VoiceDraft.swift", "RowGesture.swift", "PrintDocument.swift", "ReviewedTaskOutput.swift", "TaskPrintRenderer.swift", "NoteMarkup.swift", "NoteFormatting.swift", "SharedCapture.swift", "SharedCapturePlan.swift", "SubtaskTree.swift", "ChildTaskFieldCommands.swift", "ChildTaskCompletionDraft.swift", "ChildTaskCompletionCommands.swift", "ChildTaskStructureCommands.swift", "ChildTaskStructureRecovery.swift", "ChildTaskTransfers.swift", "ChildTaskAdoption.swift", "ChildTaskStructureDraft.swift", "ChildTaskStructurePresentation.swift", "ProjectWorkflows.swift", "CapturePresentation.swift", "TodoistImport.swift", "ReminderDevices.swift", "ProjectPulseWidget.swift", "TaskActivity.swift", "SharedComments.swift", "AudioComments.swift", "AudioCommentDecoding.swift", "AudioCommentPending.swift", "AudioCommentPublishing.swift", "AudioCommentVault.swift", "FocusWidget.swift", "FocusSession.swift", "QuickPlanningCompletion.swift", "QuickReferenceCompletion.swift", "Recurrence.swift", "PinnedNotes.swift", "InboxReview.swift", "Models.swift", "WidgetActions.swift", "WidgetCompletion.swift", "Backend.swift", "Filters.swift", "Planner.swift", "CalendarEvents.swift", "CloudCalendars.swift", "CalendarCredentials.swift", "CalendarLinksFixture.swift", "Backups.swift", "Reminders.swift"]
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
