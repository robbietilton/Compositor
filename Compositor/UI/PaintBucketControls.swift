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

/// A tipped bucket and falling drop, matching the tool rail's monochrome line icons.
struct PaintBucketToolIcon: View {
    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 20, y: size.height / 20)
            var bucket = Path()
            bucket.move(to: CGPoint(x: 2, y: 9))
            bucket.addLine(to: CGPoint(x: 8, y: 3))
            bucket.addLine(to: CGPoint(x: 15, y: 10))
            bucket.addLine(to: CGPoint(x: 9, y: 16))
            bucket.closeSubpath()
            context.stroke(bucket, with: .foreground, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            var handle = Path()
            handle.move(to: CGPoint(x: 4, y: 7))
            handle.addQuadCurve(to: CGPoint(x: 10, y: 5), control: CGPoint(x: 2, y: -1))
            context.stroke(handle, with: .foreground, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            var paint = Path()
            paint.move(to: CGPoint(x: 3, y: 10))
            paint.addLine(to: CGPoint(x: 14, y: 10))
            paint.addLine(to: CGPoint(x: 9, y: 15))
            paint.closeSubpath()
            context.fill(paint, with: .foreground)
            var drop = Path()
            drop.move(to: CGPoint(x: 17, y: 12))
            drop.addCurve(to: CGPoint(x: 17, y: 19), control1: CGPoint(x: 12, y: 17), control2: CGPoint(x: 15, y: 19))
            drop.addCurve(to: CGPoint(x: 17, y: 12), control1: CGPoint(x: 20, y: 19), control2: CGPoint(x: 21, y: 17))
            context.fill(drop, with: .foreground)
        }.accessibilityHidden(true)
    }
}
