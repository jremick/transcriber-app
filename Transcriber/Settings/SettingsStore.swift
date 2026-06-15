import AppKit
import Foundation
import Observation

enum ASREngineChoice: String, CaseIterable, Identifiable {
    case local
    case openAI

    var id: String { rawValue }
    var label: String {
        switch self {
        case .local: "On-device (Apple)"
        case .openAI: "OpenAI (cloud)"
        }
    }
}

enum NotesEngineChoice: String, CaseIterable, Identifiable {
    /// Prefer on-device Foundation Models, then OpenAI when a key exists, then local extractive notes.
    case automatic
    case appleOnDevice
    case localExtractive
    case openAI

    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .appleOnDevice: "On-device (Apple)"
        case .localExtractive: "Local extractive"
        case .openAI: "OpenAI (cloud)"
        }
    }
}

enum MeetingDetectionAction: String, CaseIterable, Identifiable {
    case prompt
    case autoStart

    var id: String { rawValue }
    var label: String {
        switch self {
        case .prompt: "Ask before transcribing"
        case .autoStart: "Start automatically"
        }
    }
}

/// Central, observable, UserDefaults-backed settings.
@MainActor
@Observable
final class SettingsStore {
    @ObservationIgnored private let defaults: UserDefaults

    var autoDetectMeetings: Bool { didSet { defaults.set(autoDetectMeetings, forKey: "autoDetectMeetings") } }
    var detectionAction: MeetingDetectionAction { didSet { defaults.set(detectionAction.rawValue, forKey: "detectionAction") } }
    var autoStopWhenMeetingEnds: Bool { didSet { defaults.set(autoStopWhenMeetingEnds, forKey: "autoStopWhenMeetingEnds") } }
    var monitoredBundleIDs: [String] { didSet { defaults.set(monitoredBundleIDs, forKey: "monitoredBundleIDs") } }

    var asrEngine: ASREngineChoice { didSet { defaults.set(asrEngine.rawValue, forKey: "asrEngine") } }
    var transcriptionLocaleID: String { didSet { defaults.set(transcriptionLocaleID, forKey: "transcriptionLocaleID") } }
    var openAITranscriptionModel: String { didSet { defaults.set(openAITranscriptionModel, forKey: "openAITranscriptionModel") } }

    var notesEngine: NotesEngineChoice { didSet { defaults.set(notesEngine.rawValue, forKey: "notesEngine") } }
    var notesPrompt: String { didSet { defaults.set(notesPrompt, forKey: "notesPrompt") } }
    var notesCadenceSeconds: Int { didSet { defaults.set(notesCadenceSeconds, forKey: "notesCadenceSeconds") } }
    var openAINotesModel: String { didSet { defaults.set(openAINotesModel, forKey: "openAINotesModel") } }

    var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.autoDetectMeetings = defaults.object(forKey: "autoDetectMeetings") as? Bool ?? true
        self.detectionAction = MeetingDetectionAction(rawValue: defaults.string(forKey: "detectionAction") ?? "") ?? .prompt
        self.autoStopWhenMeetingEnds = defaults.object(forKey: "autoStopWhenMeetingEnds") as? Bool ?? true
        self.monitoredBundleIDs = defaults.stringArray(forKey: "monitoredBundleIDs") ?? MeetingApps.defaultBundleIDs
        self.asrEngine = ASREngineChoice(rawValue: defaults.string(forKey: "asrEngine") ?? "") ?? .local
        self.transcriptionLocaleID = defaults.string(forKey: "transcriptionLocaleID") ?? Locale.current.identifier
        self.openAITranscriptionModel = defaults.string(forKey: "openAITranscriptionModel")
            ?? OpenAIRealtimeEngine.defaultTranscriptionModel
        self.notesEngine = NotesEngineChoice(rawValue: defaults.string(forKey: "notesEngine") ?? "") ?? .automatic
        self.notesPrompt = defaults.string(forKey: "notesPrompt") ?? DefaultPrompts.notes
        self.notesCadenceSeconds = defaults.object(forKey: "notesCadenceSeconds") as? Int ?? 30
        self.openAINotesModel = defaults.string(forKey: "openAINotesModel") ?? "gpt-5-mini"
        self.hasCompletedOnboarding = defaults.object(forKey: "hasCompletedOnboarding") as? Bool ?? false
    }

    func resetNotesPrompt() {
        notesPrompt = DefaultPrompts.notes
    }
}

/// Known meeting apps for detection. Bundle ID → display name.
enum MeetingApps {
    static let known: [(bundleID: String, name: String)] = [
        ("us.zoom.xos", "Zoom"),
        ("com.microsoft.teams2", "Microsoft Teams"),
        ("com.microsoft.teams", "Microsoft Teams (classic)"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.hnc.Discord", "Discord"),
        ("com.cisco.webexmeetingsapp", "Webex"),
        ("Cisco-Systems.Spark", "Webex App"),
        ("com.apple.FaceTime", "FaceTime"),
        ("com.amazon.Amazon-Chime", "Amazon Chime"),
        ("com.google.Chrome", "Chrome (Meet?)"),
        ("com.apple.Safari", "Safari (Meet?)"),
        ("com.microsoft.edgemac", "Edge (Meet?)"),
        ("company.thebrowser.Browser", "Arc (Meet?)"),
        ("org.mozilla.firefox", "Firefox (Meet?)"),
    ]

    static var defaultBundleIDs: [String] { known.map(\.bundleID) }

    @MainActor
    static func displayName(forBundleID bundleID: String) -> String {
        let canonical = canonicalBundleID(for: bundleID)
        if let name = known.first(where: { $0.bundleID == canonical })?.name {
            return name
        }
        if let app = NSWorkspace.shared.runningApplications.first(
            where: { $0.bundleIdentifier == canonical }), let name = app.localizedName {
            return name
        }
        return canonical
    }

    static func canonicalBundleID(for bundleID: String) -> String {
        helperBundleAliases[bundleID] ?? bundleID
    }

    /// Browsers give a weaker "possible meeting" signal (could be any mic use).
    static let browserBundleIDs: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "org.mozilla.firefox",
    ]

    /// Core Audio can report the input-owning helper process rather than the
    /// top-level browser app bundle. Keep settings user-facing while matching
    /// those helper processes internally.
    private static let helperBundleAliases: [String: String] = [
        "com.google.Chrome.helper": "com.google.Chrome",
        "com.microsoft.edgemac.helper": "com.microsoft.edgemac",
        "company.thebrowser.Browser.helper": "company.thebrowser.Browser",
    ]
}
