import SwiftUI
import MenubarNumbersCore

struct SourceEditorView: View {
    @ObservedObject var state: AppState
    let source: APISource
    @State private var draft: SourceDraft

    init(state: AppState, source: APISource) {
        self.state = state
        self.source = source
        _draft = State(initialValue: state.draft(for: source))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Form {
                    Section("Source") {
                        TextField("Name", text: $draft.name)
                            .accessibilityLabel("API source name")
                        TextField("HTTPS endpoint", text: $draft.endpoint)
                            .accessibilityLabel("API endpoint")
                        Toggle("Enabled", isOn: $draft.isEnabled)
                            .accessibilityLabel("Enable API source")
                    }

                    Section("Request") {
                        Picker("Method", selection: $draft.method) {
                            Text("GET").tag(HTTPMethod.get)
                            Text("POST").tag(HTTPMethod.post)
                        }
                        .accessibilityLabel("HTTP method")
                        Picker("Refresh interval", selection: $draft.refreshInterval) {
                            Text("15 seconds").tag(TimeInterval(15))
                            Text("30 seconds").tag(TimeInterval(30))
                            Text("1 minute").tag(TimeInterval(60))
                            Text("5 minutes").tag(TimeInterval(300))
                        }
                        .accessibilityLabel("Refresh interval")
                        NamedSecretsEditor(title: "Headers", values: $draft.headers, addLabel: "Add header")
                        NamedSecretsEditor(title: "Query parameters", values: $draft.queryItems, addLabel: "Add query parameter")
                        TextEditor(text: $draft.jsonBody)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 100)
                            .overlay(alignment: .topLeading) {
                                if draft.jsonBody.isEmpty {
                                    Text("Optional JSON body")
                                        .foregroundStyle(.tertiary)
                                        .padding(8)
                                        .allowsHitTesting(false)
                                }
                            }
                            .accessibilityLabel("Optional JSON request body")
                    }

                    Section("Authentication") {
                        Picker("Authentication", selection: $draft.authentication) {
                            ForEach(DraftAuthentication.allCases) { item in
                                Text(item.rawValue).tag(item)
                            }
                        }
                        .accessibilityLabel("Authentication type")
                        if draft.authentication == .apiKeyHeader || draft.authentication == .apiKeyQuery {
                            TextField(draft.authentication == .apiKeyHeader ? "Header name" : "Query parameter name", text: $draft.authenticationName)
                                .accessibilityLabel("API key name")
                        }
                        if draft.authentication != .none {
                            SecureField(draft.authentication == .basic ? "username:password" : "Secret", text: $draft.authenticationValue)
                                .accessibilityLabel("Authentication secret")
                        }
                    }
                }

                HStack {
                    Button(state.loadingSourceIDs.contains(source.id) ? "Testing…" : "Save & Test Connection") {
                        Task { await state.saveAndTest(draft) }
                    }
                    .disabled(state.loadingSourceIDs.contains(source.id))
                    .accessibilityLabel("Save source and test API connection")

                    Button("Refresh Response") {
                        Task { await state.refreshSelected() }
                    }
                    .disabled(state.loadingSourceIDs.contains(source.id))
                    .accessibilityLabel("Refresh selected API response")

                    ConnectionStatusView(state: state, sourceID: source.id)
                }

                if let response = state.latestResponses[source.id] {
                    JSONInspectorView(source: source, response: response)
                } else {
                    ContentUnavailableView("Test the connection", systemImage: "curlybraces", description: Text("A successful JSON response appears here and its scalar values can be dragged to Menu Bar."))
                        .frame(maxWidth: .infinity, minHeight: 180)
                }
            }
            .padding()
        }
        .navigationTitle(source.name)
    }
}

private struct ConnectionStatusView: View {
    @ObservedObject var state: AppState
    let sourceID: UUID

    var body: some View {
        if let error = state.errors[sourceID] {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .accessibilityLabel("Connection error: \(error)")
        } else if let timestamp = state.lastSuccess[sourceID] {
            Label("Updated \(timestamp, style: .time)", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
                .accessibilityLabel("Connection succeeded at \(timestamp.formatted())")
        }
    }
}

private struct NamedSecretsEditor: View {
    let title: String
    @Binding var values: [NamedSecret]
    let addLabel: String

    var body: some View {
        VStack(alignment: .leading) {
            Text(title)
            ForEach($values) { $value in
                HStack {
                    TextField("Name", text: $value.name)
                        .accessibilityLabel("\(title) name")
                    SecureField("Value", text: $value.value)
                        .accessibilityLabel("\(title) value")
                    Button {
                        values.removeAll { $0.id == value.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .accessibilityLabel("Remove \(title.lowercased())")
                }
            }
            Button(addLabel) {
                values.append(NamedSecret())
            }
            .accessibilityLabel(addLabel)
        }
    }
}
