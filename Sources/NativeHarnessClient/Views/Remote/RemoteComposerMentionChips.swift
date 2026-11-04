import SwiftUI

/// Host references use the local mention chip while keeping file upload ownership explicit.
struct RemoteComposerMentionChips<Draft: ComposerDraftEditing>: View {
    @Bindable var draft: Draft
    var body: some View {
        ForEach(draft.hostMentions) { match in
            ComposerInputChip(input: .mention(name: match.name, path: match.url)) {
                draft.hostMentions.removeAll { $0.id == match.id }
            }
        }
    }
}
