import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject var model: PatcherViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDropTargeted = false
    @State private var showLogs = false
    @State private var showAbout = false
    @State private var confirmRemove = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().padding(.top, 14)

            VStack(spacing: 12) {
                targetCard
                if model.isWorking { progress }
                actions
                logs
            }
            .padding(.top, 16)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(minWidth: 520, idealWidth: 580, minHeight: 500, idealHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { model.start() }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.inspection?.state)
        .alert(item: $model.presentedError) { error in
            Alert(
                title: Text(error.title),
                message: Text(error.message),
                dismissButton: .default(Text(L10n.text(.ok)))
            )
        }
        .confirmationDialog(
            L10n.text(.removeConfirmTitle),
            isPresented: $confirmRemove,
            titleVisibility: .visible
        ) {
            Button(L10n.text(.remove), role: .destructive) {
                model.removePatchedCopy()
            }
            Button(L10n.text(.cancel), role: .cancel) {}
        } message: {
            Text(L10n.text(.removeConfirmMessage))
        }
        .sheet(isPresented: $showAbout) {
            VStack(spacing: 14) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)
                Text(L10n.text(.appTitle)).font(.title2.bold())
                Text(L10n.text(.aboutBody))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button(L10n.text(.done)) { showAbout = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(30)
            .frame(width: 360)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text(.appTitle))
                    .font(.title3.weight(.semibold))
                Text(L10n.text(.subtitle))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button { showAbout = true } label: {
                Image(systemName: "info.circle")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .help(L10n.text(.about))
            .accessibilityLabel(L10n.text(.about))
        }
    }

    private var targetCard: some View {
        let isIdle = model.inspection == nil

        return VStack(spacing: 10) {
            Image(systemName: isIdle ? "arrow.down.app" : model.stateSymbol)
                .font(.system(size: isIdle ? 38 : 40, weight: .medium))
                .foregroundStyle(toneColor)
                .symbolRenderingMode(.hierarchical)

            Text(model.stateLabel)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(isIdle ? L10n.text(.dropSubtitle) : model.stateDetail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if let original = model.originalURL {
                pathRow(L10n.text(.original), original.path)
            }
            if let patched = model.patchedURL {
                pathRow(L10n.text(.output), patched.path)
            }

            Button(L10n.text(.choose)) { model.chooseTarget() }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(model.isWorking)
        }
        .frame(maxWidth: .infinity, minHeight: 190)
        .padding(.horizontal, 18)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(toneColor.opacity(isDropTargeted ? 0.13 : 0.055))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    toneColor.opacity(isDropTargeted ? 0.9 : 0.42),
                    style: StrokeStyle(lineWidth: 1.5, dash: [7, 6])
                )
        }
        .contentShape(Rectangle())
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in model.acceptDrop(url) }
            }
            return true
        }
        .accessibilityElement(children: .contain)
    }

    private func pathRow(_ label: String, _ path: String) -> some View {
        HStack(spacing: 7) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(path)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var progress: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small)
            Text(model.operationTitle)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if model.canRemove {
                Button(L10n.text(.remove), role: .destructive) {
                    confirmRemove = true
                }
                .controlSize(.large)
            }

            Button(L10n.text(.inspect)) { model.refresh() }
                .controlSize(.large)
                .disabled(model.isWorking)

            Spacer(minLength: 8)

            if model.canRepair {
                Button(L10n.text(.repair)) { model.repair() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
                Button(L10n.text(.create)) { model.createPatchedCopy() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.canCreate)
            }
        }
    }

    private var logs: some View {
        DisclosureGroup(L10n.text(.activity), isExpanded: $showLogs) {
            ScrollView {
                Text(model.logs.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 88)
            .background(.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
        }
        .font(.callout)
    }

    private var toneColor: Color {
        switch model.tone {
        case .neutral: .secondary
        case .good: .green
        case .patched: .blue
        case .warning: .orange
        case .danger: .red
        }
    }
}
