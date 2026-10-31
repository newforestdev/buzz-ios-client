import BuzzKit
import SwiftUI

struct AddChannelMembersSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.entityNames) private var names
    @State private var query = ""
    @State private var selected: Set<String> = []
    @State private var added: Set<String> = []
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    let channelID: String
    let existingMembers: Set<String>
    let selfPubkey: String?
    let engine: SyncEngine

    private var candidates: [DirectMessagePerson] {
        names.identities
            .filter { !existingMembers.contains($0) && !added.contains($0) && $0 != selfPubkey }
            .map { pubkey in
                DirectMessagePerson(
                    pubkey: pubkey,
                    name: names.name(for: pubkey),
                    secondary: names.secondaryLabel(for: pubkey),
                    picture: names.picture(for: pubkey),
                    initials: names.initials(for: pubkey),
                    isAgent: names.isAgent(pubkey),
                    isNamed: names.humanName(for: pubkey) != nil
                )
            }
            .filter { person in
                query.isEmpty
                    || person.name.localizedCaseInsensitiveContains(query)
                    || person.secondary?.localizedCaseInsensitiveContains(query) == true
            }
            .sorted(by: DirectMessagePicker.precedes)
    }

    var body: some View {
        NavigationStack {
            List {
                if candidates.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? "No People to Add" : "No Matches",
                        systemImage: "person.2",
                        description: Text(query.isEmpty
                            ? "Everyone in your directory is already in this channel."
                            : "Try another name.")
                    )
                } else {
                    Section {
                        ForEach(candidates) { person in
                            Button { toggle(person.pubkey) } label: {
                                HStack(spacing: 12) {
                                    AvatarView(
                                        url: person.picture,
                                        seed: person.pubkey,
                                        monogram: person.initials,
                                        size: 36
                                    )
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(person.name)
                                            .font(.hive(.body, weight: .medium))
                                            .foregroundStyle(.primary)
                                        if let secondary = person.secondary {
                                            Text(secondary)
                                                .font(.hive(.caption))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: selected.contains(person.pubkey)
                                        ? "checkmark.circle.fill"
                                        : "circle")
                                        .foregroundStyle(selected.contains(person.pubkey)
                                            ? Color.accentColor
                                            : Color.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search people and agents")
            .navigationTitle("Add People")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add \(selected.count)", systemImage: "person.badge.plus") {
                        addSelected()
                    }
                    .disabled(selected.isEmpty || isSubmitting)
                }
            }
            .overlay {
                if isSubmitting {
                    ProgressView("Adding people…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .alert(
                "Couldn’t Add Everyone",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func toggle(_ pubkey: String) {
        if selected.contains(pubkey) {
            selected.remove(pubkey)
        } else {
            selected.insert(pubkey)
        }
    }

    private func addSelected() {
        guard !isSubmitting else { return }
        isSubmitting = true
        let requested = candidates.filter { selected.contains($0.pubkey) }
        Task {
            var failures: [String] = []
            for person in requested {
                do {
                    try await engine.addChannelMember(
                        channelID: channelID,
                        pubkey: person.pubkey,
                        isAgent: person.isAgent
                    )
                    added.insert(person.pubkey)
                    selected.remove(person.pubkey)
                } catch {
                    failures.append(person.name)
                }
            }
            isSubmitting = false
            if failures.isEmpty {
                dismiss()
            } else {
                errorMessage = "Couldn’t add: \(failures.joined(separator: ", ")). You can retry."
            }
        }
    }
}
