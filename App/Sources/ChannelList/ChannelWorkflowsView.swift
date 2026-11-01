import BuzzKit
import SwiftUI
import UIKit

private enum WorkflowTriggerChoice: String, CaseIterable, Identifiable {
    case messagePosted = "message_posted"
    case reactionAdded = "reaction_added"
    case diffPosted = "diff_posted"
    case schedule
    case webhook

    var id: String { rawValue }
    var title: String {
        switch self {
        case .messagePosted: "Message posted"
        case .reactionAdded: "Reaction added"
        case .diffPosted: "Diff posted"
        case .schedule: "Schedule"
        case .webhook: "Webhook"
        }
    }
}

private enum WorkflowStepChoice: String, CaseIterable, Identifiable {
    case sendMessage = "send_message"
    case askBot = "ask_bot"
    case addReaction = "add_reaction"
    case callWebhook = "call_webhook"
    case delay

    var id: String { rawValue }
    var title: String {
        switch self {
        case .sendMessage: "Send message"
        case .askBot: "Ask bot"
        case .addReaction: "Add reaction"
        case .callWebhook: "Call webhook"
        case .delay: "Delay"
        }
    }
}

private enum WorkflowScheduleStyle: String, CaseIterable, Identifiable {
    case interval
    case daily
    case weekly
    case custom

    var id: String { rawValue }
    var title: String {
        switch self {
        case .interval: "Interval"
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .custom: "Custom (advanced)"
        }
    }
}

private enum WorkflowScheduleUnit: String, CaseIterable, Identifiable {
    case minutes = "m"
    case hours = "h"

    var id: String { rawValue }
    var title: String { self == .minutes ? "minutes" : "hours" }
    var maximum: Int { self == .minutes ? 59 : 24 }
}

private struct WorkflowStepDraft: Identifiable {
    var id = "step_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10))"
    var action: WorkflowStepChoice = .sendMessage
    var condition = ""
    var message = ""
    var botPubkey = ""
    var emoji = ""
    var url = ""
    var method = "POST"
    var headersJSON = ""
    var body = ""
    var duration = ""
}

private struct WorkflowDraft {
    var name = ""
    var description = ""
    var enabled = true
    var trigger: WorkflowTriggerChoice = .messagePosted
    var filter = ""
    var triggerEmoji = ""
    var cron = ""
    var interval = ""
    var scheduleStyle: WorkflowScheduleStyle = .interval
    var intervalAmount = 30
    var intervalUnit: WorkflowScheduleUnit = .minutes
    var scheduleTime = Self.defaultScheduleTime
    var scheduleWeekday = 1
    var customSchedule = ""
    var customScheduleIsInterval = false
    var steps: [WorkflowStepDraft] = [WorkflowStepDraft()]

    init() {}

    init?(workflow: ChannelWorkflow, agentNames: [String: String]) {
        guard let object = Self.definitionObject(workflow.content),
              let name = object["name"] as? String,
              let triggerObject = object["trigger"] as? [String: Any],
              let triggerRaw = triggerObject["on"] as? String,
              let trigger = WorkflowTriggerChoice(rawValue: triggerRaw),
              let rawSteps = object["steps"] as? [[String: Any]] else { return nil }
        self.name = name
        description = object["description"] as? String ?? ""
        enabled = object["enabled"] as? Bool ?? true
        self.trigger = trigger
        filter = triggerObject["filter"] as? String ?? ""
        triggerEmoji = triggerObject["emoji"] as? String ?? ""
        cron = triggerObject["cron"] as? String ?? ""
        interval = triggerObject["interval"] as? String ?? ""
        if !interval.isEmpty {
            if let parsed = Self.parseInterval(interval) {
                scheduleStyle = .interval
                intervalAmount = parsed.amount
                intervalUnit = parsed.unit
            } else {
                scheduleStyle = .custom
                customSchedule = interval
                customScheduleIsInterval = true
            }
        } else if !cron.isEmpty {
            if let parsed = Self.parseSimpleCron(cron) {
                scheduleStyle = parsed.weekday == nil ? .daily : .weekly
                scheduleTime = Self.date(hour: parsed.hour, minute: parsed.minute)
                scheduleWeekday = parsed.weekday ?? 1
            } else {
                scheduleStyle = .custom
                customSchedule = cron
            }
        }
        var parsedSteps: [WorkflowStepDraft] = []
        for (index, raw) in rawSteps.enumerated() {
            guard let actionRaw = raw["action"] as? String else { return nil }
            let isAskBot = (raw["name"] as? String) == "Ask bot"
            let action = isAskBot ? WorkflowStepChoice.askBot : WorkflowStepChoice(rawValue: actionRaw)
            guard let action else { return nil }
            var step = WorkflowStepDraft()
            step.id = raw["id"] as? String ?? "step_\(index + 1)"
            step.action = action
            step.condition = raw["if"] as? String ?? ""
            step.message = raw["text"] as? String ?? ""
            if action == .askBot {
                let parsed = Self.parseBotMessage(step.message, agentNames: agentNames)
                step.botPubkey = parsed.pubkey
                step.message = parsed.prompt
            }
            step.emoji = raw["emoji"] as? String ?? ""
            step.url = raw["url"] as? String ?? ""
            step.method = raw["method"] as? String ?? "POST"
            if let headers = raw["headers"] as? [String: String],
               let data = try? JSONSerialization.data(withJSONObject: headers, options: [.sortedKeys]),
               let string = String(data: data, encoding: .utf8) { step.headersJSON = string }
            step.body = raw["body"] as? String ?? ""
            step.duration = raw["duration"] as? String ?? ""
            parsedSteps.append(step)
        }
        steps = parsedSteps.isEmpty ? [WorkflowStepDraft()] : parsedSteps
    }

    func content(agentNames: [String: String]) throws -> String {
        let triggerObject: [String: Any] = {
            var result: [String: Any] = ["on": trigger.rawValue]
            if trigger == .messagePosted || trigger == .diffPosted, !filter.trimmed.isEmpty {
                result["filter"] = filter.trimmed
            }
            if trigger == .reactionAdded, !triggerEmoji.trimmed.isEmpty {
                result["emoji"] = triggerEmoji.trimmed
            }
            if trigger == .schedule {
                switch scheduleStyle {
                case .interval:
                    result["interval"] = "\(intervalAmount)\(intervalUnit.rawValue)"
                case .daily:
                    result["cron"] = Self.cronExpression(time: scheduleTime)
                case .weekly:
                    result["cron"] = Self.cronExpression(time: scheduleTime, weekday: scheduleWeekday)
                case .custom:
                    if customScheduleIsInterval {
                        result["interval"] = customSchedule.trimmed
                    } else {
                        result["cron"] = customSchedule.trimmed
                    }
                }
            }
            return result
        }()

        var encodedSteps: [[String: Any]] = []
        for step in steps {
            var object: [String: Any] = ["id": step.id, "action": step.action == .askBot ? "send_message" : step.action.rawValue]
            if !step.condition.trimmed.isEmpty { object["if"] = step.condition.trimmed }
            switch step.action {
            case .sendMessage:
                guard !step.message.trimmed.isEmpty else {
                    throw WorkflowEditorError.invalid("Enter the message this workflow should send.")
                }
                object["text"] = step.message
            case .askBot:
                guard let agentName = agentNames[step.botPubkey], !step.message.trimmed.isEmpty else {
                    throw WorkflowEditorError.invalid("Choose a channel bot and enter a prompt.")
                }
                // The relay resolves the @mention to a channel member p-tag; ACP agents
                // wake from that tag. The reply is asynchronous and is not a step output.
                object["name"] = "Ask bot"
                object["text"] = "@\(agentName) \(step.message.trimmed)"
            case .addReaction:
                guard trigger != .schedule && trigger != .webhook else {
                    throw WorkflowEditorError.invalid("Add reaction needs a message, reaction, or diff trigger.")
                }
                guard !step.emoji.trimmed.isEmpty else {
                    throw WorkflowEditorError.invalid("Enter an emoji name for the reaction step.")
                }
                object["emoji"] = step.emoji.trimmed
            case .callWebhook:
                guard step.url.trimmed.hasPrefix("https://") else {
                    throw WorkflowEditorError.invalid("Webhook URLs must start with https://.")
                }
                object["url"] = step.url.trimmed
                object["method"] = step.method
                if !step.headersJSON.trimmed.isEmpty {
                    guard let data = step.headersJSON.data(using: .utf8),
                          let headers = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                        throw WorkflowEditorError.invalid("Webhook headers must be a JSON object of string values.")
                    }
                    object["headers"] = headers
                }
                if !step.body.isEmpty { object["body"] = step.body }
            case .delay:
                guard !step.duration.trimmed.isEmpty else {
                    throw WorkflowEditorError.invalid("Enter a delay such as 5s, 1m, or 1h.")
                }
                object["duration"] = step.duration.trimmed
            }
            encodedSteps.append(object)
        }
        guard !name.trimmed.isEmpty else { throw WorkflowEditorError.invalid("Enter a workflow name.") }
        guard !encodedSteps.isEmpty else { throw WorkflowEditorError.invalid("Add at least one step.") }
        if trigger == .schedule {
            if scheduleStyle == .interval && !(1...intervalUnit.maximum).contains(intervalAmount) {
                throw WorkflowEditorError.invalid("Choose a valid interval.")
            }
            if scheduleStyle == .custom && customSchedule.trimmed.isEmpty {
                throw WorkflowEditorError.invalid("Enter a custom schedule.")
            }
        }
        var definition: [String: Any] = ["name": name.trimmed, "trigger": triggerObject, "steps": encodedSteps]
        if !description.trimmed.isEmpty { definition["description"] = description.trimmed }
        if !enabled { definition["enabled"] = false }
        let data = try JSONSerialization.data(withJSONObject: definition, options: [.sortedKeys, .withoutEscapingSlashes])
        guard let result = String(data: data, encoding: .utf8) else { throw WorkflowEditorError.invalid("Couldn’t encode this workflow.") }
        return result
    }

    private static func definitionObject(_ content: String) -> [String: Any]? {
        if let data = content.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return object }
        return parseDesktopYAML(content)
    }

    private static var defaultScheduleTime: Date { date(hour: 9, minute: 0) }

    private static func date(hour: Int, minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar.date(from: DateComponents(year: 2024, month: 1, day: 1, hour: hour, minute: minute)) ?? .distantPast
    }

    private static func cronExpression(time: Date, weekday: Int? = nil) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let components = calendar.dateComponents([.hour, .minute], from: time)
        let minute = components.minute ?? 0
        let hour = components.hour ?? 9
        if let weekday { return "\(minute) \(hour) * * \(weekday)" }
        return "\(minute) \(hour) * * *"
    }

    private static func parseSimpleCron(_ value: String) -> (minute: Int, hour: Int, weekday: Int?)? {
        let fields = value.split(whereSeparator: \.isWhitespace)
        guard fields.count == 5,
              let minute = Int(fields[0]), (0...59).contains(minute),
              let hour = Int(fields[1]), (0...23).contains(hour),
              fields[2] == "*", fields[3] == "*" else { return nil }
        if fields[4] == "*" { return (minute, hour, nil) }
        guard let weekday = Int(fields[4]), (0...6).contains(weekday) else { return nil }
        return (minute, hour, weekday)
    }

    private static func parseInterval(_ value: String) -> (amount: Int, unit: WorkflowScheduleUnit)? {
        guard let last = value.last,
              let unit = WorkflowScheduleUnit(rawValue: String(last)),
              let amount = Int(value.dropLast()),
              (1...unit.maximum).contains(amount) else { return nil }
        return (amount, unit)
    }

    private static func parseDesktopYAML(_ content: String) -> [String: Any]? {
        var root: [String: Any] = [:]
        var trigger: [String: Any] = [:]
        var steps: [[String: Any]] = []
        enum Section { case root, trigger, steps }
        var section = Section.root
        for line in content.components(separatedBy: .newlines) {
            if line.contains(": |") || line.contains(": >") { return nil }
            let indent = line.prefix(while: { $0 == " " }).count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if indent == 0 {
                if trimmed == "trigger:" { section = .trigger; continue }
                if trimmed == "steps:" { section = .steps; continue }
                guard let pair = keyValue(trimmed) else { continue }
                root[pair.0] = yamlValue(pair.1)
                section = .root
                continue
            }
            switch section {
            case .root: continue
            case .trigger:
                if let pair = keyValue(trimmed) { trigger[pair.0] = yamlValue(pair.1) }
            case .steps:
                if trimmed.hasPrefix("- ") {
                    steps.append([:])
                    let first = String(trimmed.dropFirst(2))
                    if let pair = keyValue(first) { steps[steps.count - 1][pair.0] = yamlValue(pair.1) }
                } else if !steps.isEmpty, let pair = keyValue(trimmed) {
                    steps[steps.count - 1][pair.0] = yamlValue(pair.1)
                }
            }
        }
        guard !root.isEmpty, !trigger.isEmpty, !steps.isEmpty else { return nil }
        root["trigger"] = trigger
        root["steps"] = steps
        return root
    }

    private static func keyValue(_ text: String) -> (String, String)? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let key = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        let value = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        return (key, value)
    }

    private static func yamlValue(_ raw: String) -> Any {
        if raw == "true" { return true }
        if raw == "false" { return false }
        if raw == "null" || raw == "~" { return NSNull() }
        if raw.hasPrefix("\"") {
            let wrapped = "[\(raw)]"
            if let data = wrapped.data(using: .utf8),
               let value = try? JSONSerialization.jsonObject(with: data) as? [String],
               let first = value.first { return first }
        }
        if raw.first == "'", raw.last == "'" {
            return String(raw.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return raw
    }

    private static func parseBotMessage(_ raw: String, agentNames: [String: String]) -> (pubkey: String, prompt: String) {
        for (pubkey, name) in agentNames.sorted(by: { $0.value.count > $1.value.count }) {
            let mention = "@\(name) "
            guard raw.hasPrefix(mention) else { continue }
            return (pubkey, String(raw.dropFirst(mention.count)))
        }
        return ("", raw)
    }
}

private enum WorkflowEditorError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        if case let .invalid(message) = self { return message }
        return nil
    }
}

private struct WorkflowEditorRoute: Identifiable {
    let workflow: ChannelWorkflow?
    var id: String { workflow?.id ?? "new" }
}

struct ChannelWorkflowsView: View {
    @Environment(\.entityNames) private var names
    @State private var workflows: [ChannelWorkflow] = []
    @State private var isLoading = false
    @State private var isMutating = false
    @State private var errorMessage: String?
    @State private var editorRoute: WorkflowEditorRoute?
    @State private var pendingDelete: ChannelWorkflow?

    let channelID: String
    let channelName: String
    let members: [MemberProfile]
    let selfPubkey: String?
    let engine: SyncEngine

    private var agentNames: [String: String] {
        Dictionary(uniqueKeysWithValues: members.compactMap { member in
            guard member.role == "bot" || names.isAgent(member.pubkey) else { return nil }
            return (member.pubkey, names.name(for: member.pubkey))
        })
    }

    var body: some View {
        List {
            if workflows.isEmpty && !isLoading {
                ContentUnavailableView(
                    "No Workflows",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Create a workflow that runs from events in this channel.")
                )
            } else {
                ForEach(workflows) { workflow in
                    workflowRow(workflow)
                }
            }
        }
        .overlay { if isLoading && workflows.isEmpty { ProgressView() } }
        .refreshable { await load() }
        .navigationTitle("Workflows")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Create Workflow", systemImage: "plus") {
                    editorRoute = WorkflowEditorRoute(workflow: nil)
                }
                .disabled(isMutating)
            }
        }
        .task { await load() }
        .sheet(item: $editorRoute) { route in
            WorkflowEditorSheet(
                channelID: channelID,
                channelName: channelName,
                workflow: route.workflow,
                agentNames: agentNames,
                engine: engine
            ) {
                await load()
            }
        }
        .confirmationDialog(
            "Delete Workflow?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Workflow", role: .destructive) {
                if let pendingDelete { mutate { try await engine.deleteChannelWorkflow(pendingDelete) } }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This removes the workflow from the relay.")
        }
        .alert(
            "Workflow Error",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder
    private func workflowRow(_ workflow: ChannelWorkflow) -> some View {
        let owned = workflow.ownerPubkey == selfPubkey
        let canEdit = WorkflowDraft(workflow: workflow, agentNames: agentNames) != nil
        HStack(spacing: 12) {
            Image(systemName: workflow.summary.enabled ? "point.3.connected.trianglepath.dotted" : "pause.circle")
                .foregroundStyle(workflow.summary.enabled ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(workflow.summary.name)
                    .font(.hive(.body, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("\(workflow.summary.trigger.replacingOccurrences(of: "_", with: " ").capitalized) · \(workflow.summary.enabled ? "Enabled" : "Paused")")
                    .font(.hive(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Menu {
                if owned {
                    if workflow.summary.enabled {
                        Button("Run Now", systemImage: "play.fill") {
                            mutate { try await engine.triggerChannelWorkflow(workflow) }
                        }
                    }
                    Button(workflow.summary.enabled ? "Pause" : "Enable", systemImage: workflow.summary.enabled ? "pause" : "play") {
                        mutate { try await engine.setChannelWorkflow(workflow, enabled: !workflow.summary.enabled) }
                    }
                    if canEdit {
                        Button("Edit", systemImage: "pencil") { editorRoute = WorkflowEditorRoute(workflow: workflow) }
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = workflow }
                } else {
                    Text("Created by another channel member")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.hiveSymbol(.body, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .disabled(isMutating)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard owned, canEdit else { return }
            editorRoute = WorkflowEditorRoute(workflow: workflow)
        }
        .accessibilityElement(children: .contain)
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do { workflows = try await engine.channelWorkflows(channelID) }
        catch { errorMessage = error.localizedDescription }
    }

    private func mutate(_ operation: @escaping () async throws -> Void) {
        guard !isMutating else { return }
        isMutating = true
        Task {
            defer { isMutating = false }
            do {
                try await operation()
                pendingDelete = nil
                await load()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct WorkflowEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: WorkflowDraft
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var webhookDetails: WorkflowWebhookDetails?

    let channelID: String
    let channelName: String
    let workflow: ChannelWorkflow?
    let agentNames: [String: String]
    let engine: SyncEngine
    let onSaved: () async -> Void

    init(
        channelID: String,
        channelName: String,
        workflow: ChannelWorkflow?,
        agentNames: [String: String],
        engine: SyncEngine,
        onSaved: @escaping () async -> Void
    ) {
        self.channelID = channelID
        self.channelName = channelName
        self.workflow = workflow
        self.agentNames = agentNames
        self.engine = engine
        self.onSaved = onSaved
        _draft = State(initialValue: workflow.flatMap { WorkflowDraft(workflow: $0, agentNames: agentNames) } ?? WorkflowDraft())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Workflow") {
                    TextField("Name", text: $draft.name)
                    TextField("Description", text: $draft.description, axis: .vertical)
                    Toggle("Enabled", isOn: $draft.enabled)
                    LabeledContent("Channel", value: channelName)
                }

                Section("When it runs") {
                    Picker("Trigger", selection: $draft.trigger) {
                        ForEach(WorkflowTriggerChoice.allCases) { option in Text(option.title).tag(option) }
                    }
                    switch draft.trigger {
                    case .messagePosted, .diffPosted:
                        TextField("Filter expression (optional)", text: $draft.filter)
                            .textInputAutocapitalization(.never)
                    case .reactionAdded:
                        TextField("Emoji filter (optional)", text: $draft.triggerEmoji)
                    case .schedule:
                        Picker("Repeats", selection: $draft.scheduleStyle) {
                            ForEach(WorkflowScheduleStyle.allCases) { style in
                                Text(style.title).tag(style)
                            }
                        }
                        switch draft.scheduleStyle {
                        case .interval:
                            HStack {
                                Stepper("Every \(draft.intervalAmount)", value: $draft.intervalAmount, in: 1...draft.intervalUnit.maximum)
                                Picker("Unit", selection: $draft.intervalUnit) {
                                    ForEach(WorkflowScheduleUnit.allCases) { unit in Text(unit.title).tag(unit) }
                                }
                                .labelsHidden()
                                .onChange(of: draft.intervalUnit) { _, unit in
                                    draft.intervalAmount = min(draft.intervalAmount, unit.maximum)
                                }
                            }
                        case .daily:
                            DatePicker("Time (UTC)", selection: $draft.scheduleTime, displayedComponents: .hourAndMinute)
                                .environment(\.timeZone, TimeZone(secondsFromGMT: 0) ?? .gmt)
                        case .weekly:
                            Picker("Day", selection: $draft.scheduleWeekday) {
                                ForEach(0..<7, id: \.self) { day in
                                    Text(Self.weekdayName(day)).tag(day)
                                }
                            }
                            DatePicker("Time (UTC)", selection: $draft.scheduleTime, displayedComponents: .hourAndMinute)
                                .environment(\.timeZone, TimeZone(secondsFromGMT: 0) ?? .gmt)
                        case .custom:
                            TextField(
                                draft.customScheduleIsInterval ? "Interval (e.g. 30m)" : "Cron expression (UTC)",
                                text: $draft.customSchedule
                            )
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        }
                        if draft.scheduleStyle == .daily || draft.scheduleStyle == .weekly {
                            Text("Scheduled times use UTC.")
                                .font(.hive(.caption))
                                .foregroundStyle(.secondary)
                        }
                    case .webhook:
                        Text("The relay will show the endpoint and one-time secret after you save.")
                            .font(.hive(.caption))
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    ForEach($draft.steps) { $step in
                        stepEditor(step: $step)
                    }
                    .onDelete { draft.steps.remove(atOffsets: $0) }
                    Button("Add Step", systemImage: "plus") {
                        draft.steps.append(WorkflowStepDraft())
                    }
                } header: { Text("Then") } footer: {
                    Text("Ask bot sends a channel mention and prompt. The bot responds separately; later steps cannot use its reply.")
                }
            }
            .navigationTitle(workflow == nil ? "Create Workflow" : "Edit Workflow")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(isSaving)
                }
            }
            .overlay { if isSaving { ProgressView("Saving workflow…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)) } }
            .alert("Couldn’t Save Workflow", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
            .navigationDestination(item: $webhookDetails) { details in
                WorkflowWebhookDetailsView(details: details) { dismiss() }
            }
        }
    }

    @ViewBuilder
    private func stepEditor(step: Binding<WorkflowStepDraft>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Action", selection: step.action) {
                ForEach(WorkflowStepChoice.allCases) { option in Text(option.title).tag(option) }
            }
            switch step.action.wrappedValue {
            case .sendMessage:
                TextField("Message text", text: step.message, axis: .vertical)
            case .askBot:
                Picker("Bot", selection: step.botPubkey) {
                    Text("Choose a bot").tag("")
                    ForEach(agentNames.keys.sorted(), id: \.self) { key in
                        Text(agentNames[key] ?? "Agent").tag(key)
                    }
                }
                TextField("Prompt", text: step.message, axis: .vertical)
            case .addReaction:
                TextField("Emoji (e.g. thumbsup)", text: step.emoji)
            case .callWebhook:
                TextField("HTTPS URL", text: step.url)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                Picker("Method", selection: step.method) {
                    ForEach(["POST", "GET", "PUT", "PATCH", "DELETE"], id: \.self) { Text($0).tag($0) }
                }
                TextField("Headers JSON (optional)", text: step.headersJSON, axis: .vertical)
                    .font(.hiveMono(.caption))
                TextField("Body (optional)", text: step.body, axis: .vertical)
            case .delay:
                TextField("Duration (e.g. 5s, 1m, 1h)", text: step.duration)
                    .textInputAutocapitalization(.never)
            }
            TextField("Condition (optional)", text: step.condition)
                .textInputAutocapitalization(.never)
                .font(.hive(.caption))
        }
        .padding(.vertical, 5)
    }

    private static func weekdayName(_ value: Int) -> String {
        ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][value]
    }

    private func save() {
        guard !isSaving else { return }
        do {
            let content = try draft.content(agentNames: agentNames)
            isSaving = true
            Task {
                defer { isSaving = false }
                do {
                    var secret: String?
                    var workflowID: String?
                    if let workflow {
                        secret = try await engine.updateChannelWorkflow(workflow, content: content)
                        workflowID = workflow.id
                    } else {
                        let result = try await engine.createChannelWorkflow(channelID: channelID, content: content)
                        secret = result.webhookSecret
                        workflowID = result.workflowID
                    }
                    await onSaved()
                    if let secret, let workflowID {
                        let url = await engine.workflowWebhookURL(workflowID: workflowID)?.absoluteString
                            ?? "/hooks/\(workflowID)"
                        webhookDetails = WorkflowWebhookDetails(url: url, secret: secret)
                    } else {
                        dismiss()
                    }
                } catch { errorMessage = error.localizedDescription }
            }
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct WorkflowWebhookDetails: Identifiable, Hashable {
    var id: String { url }
    let url: String
    let secret: String
}

private struct WorkflowWebhookDetailsView: View {
    let details: WorkflowWebhookDetails
    let onDone: () -> Void

    var body: some View {
        Form {
            Section("Webhook URL") {
                Text(details.url)
                    .font(.hiveMono(.caption))
                    .textSelection(.enabled)
                Button("Copy URL", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = details.url
                }
            }
            Section("Secret") {
                Text("Send this value in the X-Webhook-Secret header. It is shown only once.")
                    .font(.hive(.caption))
                    .foregroundStyle(.secondary)
                Text(details.secret)
                    .font(.hiveMono(.caption))
                    .textSelection(.enabled)
                Button("Copy Secret", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = details.secret
                }
            }
        }
        .navigationTitle("Webhook Ready")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone) }
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
