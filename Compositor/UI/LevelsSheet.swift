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
            Picker(L10n.string("Channel"), selection: Binding(get: { settings.channel }, set: { channel in update { $0.channel = channel } })) {
                ForEach(LevelsChannel.allCases, id: \.self) { Text(L10n.string($0.rawValue)).tag($0) }
            }.frame(width: 180)
            VStack(spacing: 0) {
                histogram.frame(height: 150).background(.black.opacity(0.25))
                    .overlay(alignment: .topLeading) {
                        if edit?.histogramReady != true { Text(L10n.string("Loading histogram…")).font(.caption).padding(8) }
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
                Text(L10n.string("Sample")).font(.caption).foregroundStyle(.secondary)
                ForEach(LevelsSample.allCases, id: \.self) { mode in
                    Button {
                        edit?.sampleMode = edit?.sampleMode == mode ? nil : mode
                        session.brushRevision += 1
                    } label: {
                        Label(L10n.string("levels.sample." + mode.rawValue.lowercased()), systemImage: "eyedropper")
                    }.tint(edit?.sampleMode == mode ? .accentColor : .secondary)
                }
            }
            if let mode = edit?.sampleMode {
                Text(L10n.format("Click the original layer to set %1$@. Click the eyedropper again to stop.", L10n.string("levels.sample." + mode.rawValue.lowercased()).lowercased()))
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.string("Auto")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    ForEach(LevelsAuto.allCases, id: \.self) { mode in
                        Button(L10n.string(mode.rawValue)) { session.autoLevels(mode) }
                    }
                }.disabled(edit?.histogramReady != true)
            }
            HStack {
                Toggle(L10n.string("Preview"), isOn: Binding(get: { edit?.preview ?? true }, set: {
                    session.updateLevels(settings, preview: $0)
                })).keyboardShortcut("p", modifiers: .option)
                Spacer()
                Button(L10n.string("Reset")) { edit?.sampleMode = nil; update { $0 = LevelsSettings() } }
            }
            Text(session.adjustmentOriginal != nil ? L10n.string("Underlying pixels · alpha-weighted histogram") : session.selection == nil ? L10n.string("Original pixels · alpha-weighted histogram") : L10n.string("Original pixels · selection and alpha-weighted histogram"))
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button(L10n.string("Cancel")) { session.cancelLevels() }.keyboardShortcut(.cancelAction)
                Spacer()
                if edit?.committing == true { ProgressView().controlSize(.small) }
                Button(L10n.string("OK")) { Task { await session.commitLevels() } }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(24).frame(width: 440).fixedSize()
        .disabled(edit?.committing == true)
    }
    private func field(_ name: String, _ binding: Binding<Double>, decimals: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.string(name)).font(.caption).foregroundStyle(.secondary)
            TextField(L10n.string(name), value: binding, format: .number.precision(.fractionLength(decimals)))
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
        }.accessibilityLabel(L10n.format("Original %1$@ histogram", L10n.string(settings.channel.rawValue)))
        .help(L10n.string("Linear histogram with automatic vertical scaling. Tall spikes may extend beyond the graph; all tones from 0 to 255 remain included."))
    }
    private func handles(output: Bool) -> some View {
        GeometryReader { geometry in
            let gammaPosition = current.black + (current.white - current.black) * pow(0.5, current.gamma)
            let positions = output ? [current.outputBlack, current.outputWhite] : [current.black, gammaPosition, current.white]
            ForEach(positions.indices, id: \.self) { index in
                let names = output ? [L10n.string("Output black"), L10n.string("Output white")] : [L10n.string("Input black"), L10n.string("Gamma"), L10n.string("Input white")]
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
