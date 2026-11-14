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
            exclude: ["Store.swift", "PlanningStore.swift", "DayPlanStore.swift", "OnDeviceAIStore.swift", "HabitStore.swift", "WeeklyReviewStore.swift", "Intents.swift", "SystemIntegration.swift", "WidgetActionTestPanel.swift"],
            sources: ["PreservingJSON.swift", "Planning.swift", "DayPlan.swift", "Habits.swift", "CalendarBlocksController.swift", "CalendarBlockEventKit.swift", "CalendarBlocks.swift", "ActualTime.swift", "Pomodoro.swift", "WearableReceipts.swift", "EmailCapture.swift", "WebhookAccess.swift", "AutomationAccess.swift", "TeamProjectAccess.swift", "TeamWorkspace.swift", "TeamTaskRecipients.swift", "TeamTaskLabels.swift", "TeamTaskReminders.swift", "TeamTaskRecurrence.swift", "TeamOrganization.swift", "TeamOrganizationCommand.swift", "TeamProjectManagement.swift", "TeamTemplateLibrary.swift", "TeamTemplateCommands.swift", "TeamWorkflowRunCommands.swift", "TeamTaskMove.swift", "TeamProjectAdoption.swift", "ProjectFilePreparation.swift", "TeamChecklist.swift", "TeamCompletion.swift", "TeamCompletionDraft.swift", "TeamTaskBatch.swift", "AccountRemoval.swift", "LocationPlaceStore.swift", "LocationReminders.swift", "HolidayCalendar.swift", "ReminderIntervalSchedule.swift", "ProjectMemberReads.swift", "OnDeviceAssistance.swift", "PrivacyFacts.swift", "FilterAssistance.swift", "TaskBreakdown.swift", "BrainDump.swift", "SmartReschedule.swift", "WeeklyReview.swift", "ReviewedTaskSteps.swift", "VoiceDraft.swift", "RowGesture.swift", "PrintDocument.swift", "ReviewedTaskOutput.swift", "TaskPrintRenderer.swift", "NoteMarkup.swift", "NoteFormatting.swift", "SharedCapture.swift", "SharedCapturePlan.swift", "SubtaskTree.swift", "ChildTaskFieldCommands.swift", "ChildTaskCompletionDraft.swift", "ChildTaskCompletionCommands.swift", "ChildTaskStructureCommands.swift", "ChildTaskStructureRecovery.swift", "ChildTaskTransfers.swift", "ChildTaskAdoption.swift", "ChildTaskRepair.swift", "ChildTaskStructureDraft.swift", "ChildTaskStructurePresentation.swift", "ProjectWorkflows.swift", "CapturePresentation.swift", "TodoistImport.swift", "ReminderDevices.swift", "ProjectPulseWidget.swift", "TaskActivity.swift", "Momentum.swift", "TaskFileUpload.swift", "SharedComments.swift", "AudioComments.swift", "AudioCommentDecoding.swift", "AudioCommentPending.swift", "AudioCommentPublishing.swift", "AudioCommentVault.swift", "FocusWidget.swift", "FocusSession.swift", "CommandRanking.swift", "NowNext.swift", "HandoffActivity.swift", "QuickPlanningCompletion.swift", "QuickReferenceCompletion.swift", "Recurrence.swift", "PinnedNotes.swift", "InboxReview.swift", "Models.swift", "TaskDependencies.swift", "WidgetActions.swift", "WidgetCompletion.swift", "Backend.swift", "SyncScheduling.swift", "Filters.swift", "Planner.swift", "LayoutGrid.swift", "CalendarEvents.swift", "CloudCalendars.swift", "CalendarCredentials.swift", "CalendarLinksFixture.swift", "Backups.swift", "Reminders.swift", "SpotlightIndexing.swift", "FocusFilter.swift", "IntentLogic.swift", "SystemControls.swift"]
        ),
        .target(
            name: "WidgetModel",
            dependencies: ["TaskfoldCore"],
            path: "TaskfoldWidgets",
            exclude: ["Info.plist", "TaskfoldWidgets.entitlements"],
            sources: ["TaskfoldWidgets.swift"],
            swiftSettings: [.define("WIDGET_MODEL_TESTING")]
        ),
        .target(
            name: "QuickAddShortcutModel",
            path: "Taskfold/GlobalQuickAdd",
            sources: ["QuickAddShortcut.swift"]
        ),
        .testTarget(name: "TaskfoldCoreTests", dependencies: ["TaskfoldCore", "WidgetModel", "QuickAddShortcutModel"], path: "TaskfoldTests", resources: [.copy("Fixtures")])
    ]
)
