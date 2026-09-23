import SwiftUI

struct FillToolModePicker: View {
    @Bindable var session: EditorSession
    var body: some View {
        Picker("Fill tool", selection: Binding(get: { session.fillToolMode }, set: { session.changeFillToolMode($0) })) {
            ForEach(FillToolMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden().fixedSize().disabled(session.gradientEdit != nil)
        .help("Press Tab to switch between Gradient and Paint Bucket; apply or cancel a pending gradient first")
    }
}

struct PaintBucketControls: View {
    @Bindable var session: EditorSession
    var body: some View {
        HStack(spacing: 12) {
            FillToolModePicker(session: session)
            Text("Tolerance")
            TextField("Tolerance", value: Binding(get: { session.bucketSettings.tolerance },
                set: { session.bucketSettings.tolerance = min(255, max(0, $0)) }), format: .number)
                .frame(width: 44).textFieldStyle(.roundedBorder)
                .help("Maximum difference per color channel, from 0 to 255")
            Toggle("Contiguous", isOn: $session.bucketSettings.contiguous)
            Toggle("Sample All Layers", isOn: $session.bucketSettings.sampleAllLayers)
                .help("Use visible layers to find the region; paint only on the active layer")
            Text("Opacity")
            Slider(value: $session.gradientSettings.opacity, in: 0.01...1).frame(width: 100)
            Text("\(Int(session.gradientSettings.opacity * 100))%").monospacedDigit().frame(width: 38)
            Spacer(minLength: 0)
            if !session.canPaintBucket { Text("Select a visible pixel or blank layer").foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 18).toolHeaderBar().releasesFocusOnCommit(session)
        .disabled(session.showsBusy || session.document == nil)
    }
}
