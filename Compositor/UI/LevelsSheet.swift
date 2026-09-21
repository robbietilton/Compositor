import SwiftUI

struct LevelsSheet: View {
    @Bindable var session: EditorSession
    private var edit: LevelsEdit? { session.levels }
    private var settings: LevelsSettings { edit?.settings ?? LevelsSettings() }
    private var current: LevelRange { settings.current }
    private func update(_ change: (inout LevelsSettings) -> Void) {
        var value = settings; change(&value)
        session.updateLevels(value, preview: edit?.preview ?? true)
    }
    private func value(_ key: WritableKeyPath<LevelRange, Double>) -> Binding<Double> {
        Binding(get: { current[keyPath: key] }, set: { newValue in
            update { var range = $0.current; range[keyPath: key] = newValue; $0.current = range }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Channel", selection: Binding(get: { settings.channel }, set: { channel in update { $0.channel = channel } })) {
                ForEach(LevelsChannel.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }.frame(width: 180)
            VStack(spacing: 0) {
                histogram.frame(height: 150).background(.black.opacity(0.25))
                    .overlay(alignment: .topLeading) {
                        if edit?.histogramReady != true { Text("Loading histogram…").font(.caption).padding(8) }
                    }
                handles(output: false).frame(height: 20)
            }
            HStack {
                field("Input black", value(\.black), decimals: 0)
                Spacer()
                field("Gamma", value(\.gamma), decimals: 2)
                Spacer()
                field("Input white", value(\.white), decimals: 0)
            }
            VStack(spacing: 0) {
                LinearGradient(colors: [.black, .white], startPoint: .leading, endPoint: .trailing).frame(height: 14)
                handles(output: true).frame(height: 20)
            }
            HStack {
                field("Output black", value(\.outputBlack), decimals: 0)
                Spacer()
                field("Output white", value(\.outputWhite), decimals: 0)
            }
            HStack {
                Text("Sample").font(.caption).foregroundStyle(.secondary)
                ForEach(LevelsSample.allCases, id: \.self) { mode in
                    Button {
                        edit?.sampleMode = edit?.sampleMode == mode ? nil : mode
                        session.brushRevision += 1
                    } label: {
                        Label(mode.displayName, systemImage: "eyedropper")
                    }.tint(edit?.sampleMode == mode ? .accentColor : .secondary)
                }
            }
            if let mode = edit?.sampleMode {
                Text("Click the original layer to set \(mode.displayName.lowercased()). Click the eyedropper again to stop.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Auto").font(.caption).foregroundStyle(.secondary)
                HStack {
                    ForEach(LevelsAuto.allCases, id: \.self) { mode in
                        Button(mode.displayName) { session.autoLevels(mode) }
                    }
                }.disabled(edit?.histogramReady != true)
            }
            HStack {
                Toggle("Preview", isOn: Binding(get: { edit?.preview ?? true }, set: {
                    session.updateLevels(settings, preview: $0)
                })).configuredNativeShortcut("p", modifiers: .option)
                Spacer()
                Button("Reset") { edit?.sampleMode = nil; update { $0 = LevelsSettings() } }
            }
            Text(session.adjustmentOriginal != nil ? "Underlying pixels · alpha-weighted histogram" : session.selection == nil ? "Original pixels · alpha-weighted histogram" : "Original pixels · selection and alpha-weighted histogram")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button("Cancel") { session.cancelLevels() }.configuredNativeShortcut(.escape)
                Spacer()
                if edit?.committing == true { ProgressView().controlSize(.small) }
                Button("OK") { Task { await session.commitLevels() } }
                    .configuredNativeShortcut(.return).buttonStyle(.borderedProminent)
            }
        }
        .padding(24).frame(width: 440).fixedSize()
        .disabled(edit?.committing == true)
    }
    private func field(_ name: String, _ binding: Binding<Double>, decimals: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            TextField(name, value: binding, format: .number.precision(.fractionLength(decimals)))
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 80)
                .accessibilityIdentifier("levels\(name.replacingOccurrences(of: " ", with: ""))")
        }
    }
    private var histogram: some View {
        Canvas { context, size in
            let bins = edit?.histogram[settings.channel.index] ?? Array(repeating: 0, count: 256)
            let peak = LevelsHistogramDisplay.scale(for: bins)
            guard peak > 0 else { return }
            var path = Path()
            for index in 0..<256 {
                let height = size.height * min(1, max(0, bins[index] / peak))
                path.addRect(CGRect(x: CGFloat(index) * size.width / 256, y: size.height - height,
                                    width: size.width / 256 + 0.1, height: height))
            }
            let color: Color = switch settings.channel { case .rgb: .gray; case .red: .red; case .green: .green; case .blue: .blue }
            context.fill(path, with: .color(color))
        }.accessibilityLabel(String(localized: "Original \(settings.channel.rawValue) histogram"))
        .help("Linear histogram with automatic vertical scaling. Tall spikes may extend beyond the graph; all tones from 0 to 255 remain included.")
    }
    private func handles(output: Bool) -> some View {
        GeometryReader { geometry in
            let gammaPosition = current.black + (current.white - current.black) * pow(0.5, current.gamma)
            let positions = output ? [current.outputBlack, current.outputWhite] : [current.black, gammaPosition, current.white]
            ForEach(positions.indices, id: \.self) { index in
                let names = output ? ["Output black", "Output white"] : ["Input black", "Gamma", "Input white"]
                Image(systemName: "triangle.fill").font(.system(size: 12))
                    .foregroundStyle(index == 0 ? Color.black : index == positions.count - 1 ? .white : .gray)
                    .shadow(color: .gray, radius: 0.5)
                    .frame(width: 22, height: 20).contentShape(Rectangle())
                    .position(x: positions[index] / 255 * geometry.size.width, y: 9)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(output ? "levelsOutput" : "levelsInput"))
                        .onChanged { drag in
                            let x = min(255, max(0, drag.location.x / geometry.size.width * 255))
                            update {
                                var range = $0.current
                                if output {
                                    if index == 0 { range.outputBlack = x.rounded() } else { range.outputWhite = x.rounded() }
                                } else if index == 0 { range.black = min(range.white - 1, x.rounded()) }
                                else if index == 2 { range.white = max(range.black + 1, x.rounded()) }
                                else {
                                    let fraction = min(0.999, max(0.001, (x - range.black) / (range.white - range.black)))
                                    range.gamma = log(fraction) / log(0.5)
                                }
                                $0.current = range
                            }
                        })
                    .accessibilityLabel(names[index])
            }
        }.coordinateSpace(name: output ? "levelsOutput" : "levelsInput")
    }
}
