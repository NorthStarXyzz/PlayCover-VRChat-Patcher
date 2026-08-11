import AppKit
import Foundation
import PCVRPatcherCore

@MainActor
final class PatcherViewModel: ObservableObject {
    @Published private(set) var originalURL: URL?
    @Published private(set) var patchedURL: URL?
    @Published private(set) var inspection: Inspection?
    @Published private(set) var isWorking = false
    @Published private(set) var operationTitle = ""
    @Published private(set) var logs: [String] = []
    @Published var presentedError: PresentedError?

    private let manifest: CompatibilityManifest?
    private let payloadURL: URL?
    private let controllerPackageURL: URL?
    private let startupError: Error?
    private var engine: PatcherEngine?

    struct PresentedError: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    init(bundle: Bundle = .main) {
        do {
            let developmentManifest = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Compatibility/manifests/pc-55638e9-vrc-2026.2.30300-1365-macos-25G70.json")
            guard let manifestURL = bundle.url(forResource: "CompatibilityManifest", withExtension: "json")
                    ?? (FileManager.default.fileExists(atPath: developmentManifest.path) ? developmentManifest : nil) else {
                throw PatcherError.invalidManifest(L10n.text(.manifestMissing))
            }
            let payload = bundle.url(forResource: "PlayCover", withExtension: "app", subdirectory: "Payload")
                ?? bundle.bundleURL.appendingPathComponent("Contents/Resources/Payload/PlayCover.app")
            let controllerPackage = bundle.url(
                forResource: "PlayCoverVRChatMemoryPolicy",
                withExtension: "pkg",
                subdirectory: "Controller"
            ) ?? bundle.bundleURL.appendingPathComponent(
                "Contents/Resources/Controller/PlayCoverVRChatMemoryPolicy.pkg"
            )
            manifest = try PatcherEngine.loadManifest(from: manifestURL)
            payloadURL = payload
            controllerPackageURL = controllerPackage
            startupError = nil
        } catch {
            manifest = nil
            payloadURL = nil
            controllerPackageURL = nil
            startupError = error
        }
    }

    func start() {
        if let startupError {
            fail(L10n.text(.startupIncomplete), startupError)
            return
        }
        let detected = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.playcover.PlayCover")
        setOriginal(
            detected ?? URL(
                fileURLWithPath: "/Applications/PlayCover.app",
                isDirectory: true
            )
        )
    }

    func chooseTarget() {
        let panel = NSOpenPanel()
        panel.title = L10n.text(.selectOfficial)
        panel.prompt = L10n.text(.selectPlayCover)
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setOriginal(url)
    }

    func acceptDrop(_ url: URL) {
        guard url.pathExtension.lowercased() == "app" else {
            fail(L10n.text(.unsupportedItem), PatcherError.invalidOperation(L10n.text(.dropOnly)))
            return
        }
        setOriginal(url)
    }

    func refresh() {
        guard !isWorking, let engine else { return }
        Task {
            do {
                inspection = try await engine.inspect()
                append(L10n.format(.inspectionLog, stateLabel))
            } catch {
                inspection = nil
                fail(L10n.text(.inspectionFailedLog), error)
            }
        }
    }

    func createPatchedCopy() {
        perform(
            L10n.text(.operationCreate),
            operation: .createPatchedCopy
        )
    }

    func repair() {
        perform(
            L10n.text(.operationRepair),
            operation: .repair
        )
    }

    func removePatchedCopy() {
        perform(
            L10n.text(.operationRemove),
            operation: .removePatchedCopy
        )
    }

    var stateLabel: String {
        guard let state = inspection?.state else { return L10n.text(.notInspected) }
        switch state {
        case .originalMissing: return L10n.text(.originalMissing)
        case .vrChatMissing: return L10n.text(.vrChatMissing)
        case .readyToCreate: return L10n.text(.ready)
        case .controllerSetupRequired: return L10n.text(.controllerRequired)
        case .fullyPatched: return L10n.text(.installed)
        case .repairRequired: return L10n.text(.repairRequired)
        case .unsupportedRuntime: return L10n.text(.unsupportedRuntime)
        case .busy: return L10n.text(.applicationsRunning)
        case .unknownModification: return L10n.text(.unknownModification)
        case .payloadUnavailable: return L10n.text(.sourceOnly)
        }
    }

    var stateDetail: String {
        guard let state = inspection?.state else { return L10n.text(.notInspectedDetail) }
        switch state {
        case .originalMissing:
            return L10n.text(.originalMissingDetail)
        case .vrChatMissing(let url):
            return L10n.format(.vrChatMissingDetail, url.path)
        case .readyToCreate:
            return L10n.text(.readyDetail)
        case .controllerSetupRequired(let reason):
            return L10n.format(.controllerRequiredDetail, reason.rawValue)
        case .fullyPatched:
            return L10n.text(.installedDetail)
        case .repairRequired(let phase):
            return L10n.format(.repairDetail, phase.rawValue)
        case .unsupportedRuntime(let reasons):
            return L10n.format(.unsupportedRuntimeDetail, reasons.joined(separator: " • "))
        case .busy(let names):
            return L10n.format(.applicationsRunningDetail, names.joined(separator: ", "))
        case .unknownModification(let reason):
            return L10n.format(.unknownModificationDetail, reason)
        case .payloadUnavailable:
            return L10n.text(.sourceOnlyDetail)
        }
    }

    var stateSymbol: String {
        guard let state = inspection?.state else { return "app.dashed" }
        switch state {
        case .readyToCreate: return "plus.app.fill"
        case .controllerSetupRequired:
            return "shippingbox.and.arrow.backward.fill"
        case .fullyPatched: return "checkmark.shield.fill"
        case .repairRequired: return "wrench.and.screwdriver.fill"
        case .busy: return "pause.circle.fill"
        case .originalMissing, .vrChatMissing: return "questionmark.folder.fill"
        case .unsupportedRuntime, .unknownModification: return "exclamationmark.triangle.fill"
        case .payloadUnavailable: return "shippingbox.fill"
        }
    }

    enum Tone { case neutral, good, patched, warning, danger }
    var tone: Tone {
        guard let state = inspection?.state else { return .neutral }
        switch state {
        case .readyToCreate: return .good
        case .fullyPatched: return .patched
        case .controllerSetupRequired, .repairRequired, .busy: return .warning
        case .unsupportedRuntime, .unknownModification: return .danger
        case .payloadUnavailable: return .neutral
        case .originalMissing, .vrChatMissing: return .neutral
        }
    }

    var canCreate: Bool { inspection?.state == .readyToCreate && !isWorking }
    var canRepair: Bool {
        guard !isWorking else { return false }
        switch inspection?.state {
        case .repairRequired, .controllerSetupRequired: return true
        default: return false
        }
    }
    var canRemove: Bool {
        inspection?.state == .fullyPatched && !isWorking
    }

    private func setOriginal(_ url: URL) {
        guard let manifest, let payloadURL, let controllerPackageURL else {
            return
        }
        originalURL = url.standardizedFileURL
        do {
            let paths = PatcherPaths.defaults(
                originalApp: originalURL!,
                payload: payloadURL,
                controllerPackage: controllerPackageURL
            )
            patchedURL = paths.patchedApp
            engine = try PatcherEngine(
                manifest: manifest,
                paths: paths,
                controllerSetupProvider: MacOSControllerSetupProvider()
            )
            append(L10n.format(.selectedLog, url.path))
            refresh()
        } catch {
            engine = nil
            fail(L10n.text(.cannotConfigure), error)
        }
    }

    private func perform(_ title: String, operation: PatcherOperation) {
        guard let engine, !isWorking else { return }
        isWorking = true
        operationTitle = title
        append(title)
        Task {
            defer { isWorking = false; operationTitle = "" }
            do {
                let result: OperationResult
                switch operation {
                case .inspect:
                    result = OperationResult(
                        operation: .inspect,
                        inspection: try await engine.inspect()
                    )
                case .createPatchedCopy:
                    result = try await engine.createPatchedCopy()
                case .repair: result = try await engine.repair()
                case .removePatchedCopy:
                    result = try await engine.removePatchedCopy()
                }
                inspection = result.inspection
                append(L10n.format(.operationCompleteLog, stateLabel))
                if let imported = result.importedVRChatURL {
                    append(L10n.format(.independentLibraryLog, imported.path))
                }
            } catch {
                append("\(L10n.text(.operationStoppedLog)): \(error.localizedDescription)")
                inspection = try? await engine.inspect()
                fail(L10n.text(.operationStoppedLog), error)
            }
        }
    }

    private func append(_ message: String) {
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"
        logs.append("[\(formatter.string(from: Date()))] \(message)")
    }

    private func fail(_ title: String, _ error: Error) {
        append("\(title): \(error.localizedDescription)")
        presentedError = PresentedError(title: title, message: error.localizedDescription)
    }
}
