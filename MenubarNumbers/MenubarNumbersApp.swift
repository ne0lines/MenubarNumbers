import AppKit
import SwiftUI

@main
struct MenubarNumbersApp: App {
    @NSApplicationDelegateAdaptor(MenubarNumbersAppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("MenubarNumbers") {
            ContentView(state: state)
                .frame(minWidth: 980, minHeight: 680)
        }

        MenuBarExtra(state.menuBarText, systemImage: "chart.bar") {
            Button("Refresh Now") {
                Task { await state.refreshAll() }
            }
            .accessibilityLabel("Refresh all API sources now")
            Button("Open MenubarNumbers") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
            }
            .accessibilityLabel("Open MenubarNumbers")
            Divider()
            Button("Quit MenubarNumbers") {
                NSApp.terminate(nil)
            }
            .accessibilityLabel("Quit MenubarNumbers")
        }
        .menuBarExtraStyle(.menu)
    }
}

final class MenubarNumbersAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct ContentView: View {
    enum Section: String, CaseIterable, Identifiable {
        case sources = "Sources"
        case menuBar = "Menu Bar"

        var id: String { rawValue }
    }

    @ObservedObject var state: AppState
    @State private var section: Section = .sources

    var body: some View {
        VStack(spacing: 0) {
            Picker("Workspace", selection: $section) {
                ForEach(Section.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding()
            .accessibilityLabel("Workspace section")

            Divider()
            if section == .sources {
                SourcesWorkspace(state: state)
            } else {
                MenuBarBuilderView(state: state)
            }
        }
    }
}

private struct SourcesWorkspace: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            if let cleanupStatus = state.secureCleanupStatus {
                HStack {
                    Label(cleanupStatus, systemImage: "key.slash")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Secure storage cleanup status: \(cleanupStatus)")
                    Button("Retry secure cleanup") {
                        state.retrySecureValueCleanup()
                    }
                    .accessibilityLabel("Retry secure storage cleanup")
                    Spacer()
                }
            }
            NavigationSplitView {
                List(selection: $state.selectedSourceID) {
                    ForEach(state.sources) { source in
                        Label(source.name, systemImage: source.isEnabled ? "dot.radiowaves.left.and.right" : "pause.circle")
                            .tag(source.id)
                    }
                }
                .navigationTitle("API Sources")
                .toolbar {
                    Button(action: state.addSource) {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add API source")
                    Button(action: state.deleteSelectedSource) {
                        Image(systemName: "trash")
                    }
                    .disabled(state.selectedSource == nil)
                    .accessibilityLabel("Delete selected API source")
                }
            } detail: {
                if let source = state.selectedSource {
                    SourceEditorView(state: state, source: source)
                        .id(source.id)
                } else {
                    ContentUnavailableView("No API source selected", systemImage: "network", description: Text("Add a source to test an API and inspect its JSON response."))
                }
            }
        }
    }
}
