import SwiftUI

/// Floats over the top of the canvas while a layer is out in another app. It doesn't block anything: the rest of the
/// document stays editable while the app works.
struct ExternalEditBanner: View {
    let session: EditorSession
    let job: ExternalEditJob

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.isImporting ? "Bringing back \(job.app.name)’s result…" : "Waiting for \(job.app.name)…")
                    .font(.system(size: 12, weight: .semibold))
                Text("Save the result to “\(job.folder.lastPathComponent)” and it comes back to this layer.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button("Import File…") { Task { await session.importExternalResultManually() } }
                .help("Choose the result yourself, if it was saved somewhere else")
            Button("Cancel") { session.cancelExternalEdit() }
        }
        .disabled(job.isImporting)
        .controlSize(.small)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.12)) }
        .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
        .padding(.top, 12)
        .accessibilityIdentifier("externalEditBanner")
    }
}

/// Tells the person when an external edit couldn't start or come back. Attached to the canvas rather than added to
/// the editor's long modifier chain, which is already at the type checker's limit.
struct ExternalEditAlert: ViewModifier {
    let session: EditorSession

    func body(content: Content) -> some View {
        content.alert("Couldn’t edit in the other app", isPresented: Binding(get: { session.externalEditError != nil },
            set: { if !$0 { session.externalEditError = nil } })) {
                Button("OK") { session.externalEditError = nil }
            } message: { Text(session.externalEditError ?? "") }
    }
}
