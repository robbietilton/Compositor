import AppKit
import SwiftUI

struct CameraRawGeometryControls: View {
    @Bindable var session: EditorSession
    private var settings: FilterSettings { session.filterEdit?.settings ?? FilterSettings() }
    private var raw: CameraRawSettings { settings.cameraRaw }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Upright").font(.subheadline)
            Picker("Upright", selection: uprightBinding) {
                ForEach(CameraRawUprightMode.allCases, id: \.self) { Text($0.localizedName).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .help("Off leaves the picture as it is. Guided straightens from lines you draw on the picture.")
            if raw.geometry.upright == .guided {
                Button {
                    session.filterEdit?.drawingCameraRawGeometryGuide.toggle()
                    session.brushRevision += 1
                } label: {
                    Label("Draw Guides", systemImage: "line.diagonal")
                }
                .help("Draw two or more lines on the preview that should be level or vertical.")
                .tint(session.filterEdit?.drawingCameraRawGeometryGuide == true ? Color.accentColor : Color.secondary)
                if session.filterEdit?.drawingCameraRawGeometryGuide == true {
                    Text("Drag on the layer to place a guide. Draw at least two lines.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !raw.geometry.guides.isEmpty {
                    Button("Clear Guides") {
                        update { $0.cameraRaw.geometry.guides = [] }
                    }
                    .help("Remove every guide line.")
                }
            }
            Picker("Projection", selection: binding(\.projection)) {
                ForEach(CameraRawProjection.allCases, id: \.self) { Text($0.localizedName).tag($0) }
            }
            .help("Perspective allows stronger keystone. Rectilinear keeps the warp gentler.")
            geometrySlider("Vertical", \.vertical, help: "Straightens vertical lines toward the center.")
            geometrySlider("Horizontal", \.horizontal, help: "Straightens horizontal lines toward the center.")
            geometrySlider("Rotate", \.rotate, range: CameraRawGeometrySettings.rotateRange, help: "Rotates the picture around its center.")
            geometrySlider("Aspect", \.aspect, help: "Stretches width relative to height.")
            geometrySlider("Scale", \.scale, help: "Zooms the transformed picture within the frame.")
            geometrySlider("Offset X", \.offsetX, help: "Moves the picture left or right.")
            geometrySlider("Offset Y", \.offsetY, help: "Moves the picture up or down.")
            Toggle("Constrain Crop", isOn: binding(\.constrainCrop))
                .help("Crops empty edges after the transform and fits the result back into the frame.")
        }
    }

    private var uprightBinding: Binding<CameraRawUprightMode> {
        Binding(get: { raw.geometry.upright }, set: { mode in
            update { $0.cameraRaw.geometry.upright = mode }
            if mode != .guided { session.filterEdit?.drawingCameraRawGeometryGuide = false }
        })
    }

    private func binding<T>(_ key: WritableKeyPath<CameraRawGeometrySettings, T>) -> Binding<T> {
        Binding(get: { raw.geometry[keyPath: key] }, set: { value in update { $0.cameraRaw.geometry[keyPath: key] = value } })
    }

    private func geometrySlider(_ title: String, _ key: WritableKeyPath<CameraRawGeometrySettings, Double>,
                                range: ClosedRange<Double> = CameraRawGeometrySettings.toneRange, help: String) -> some View {
        let value = raw.geometry[keyPath: key]
        return HStack(spacing: 10) {
            Text(title).frame(minWidth: CameraRawControls.labelWidth, alignment: .leading).help(help)
            CameraRawSlider(value: value, range: range, track: .plain, help: help,
                            onChange: { rawValue in update { $0.cameraRaw.geometry[keyPath: key] = rawValue.rounded() } },
                            onReset: { update { $0.cameraRaw.geometry[keyPath: key] = 0 } })
            TextField(title, value: Binding(get: { raw.geometry[keyPath: key] },
                                            set: { newValue in update { $0.cameraRaw.geometry[keyPath: key] = newValue } }),
                      format: .number.precision(.fractionLength(0)))
                .frame(width: 56).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).help(help)
        }
    }

    private func update(_ change: (inout FilterSettings) -> Void) {
        var value = settings
        change(&value)
        session.updateFilter(value, preview: session.filterEdit?.preview ?? true)
    }
}

struct CameraRawCalibrationControls: View {
    @Bindable var session: EditorSession
    private var settings: FilterSettings { session.filterEdit?.settings ?? FilterSettings() }
    private var raw: CameraRawSettings { settings.cameraRaw }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Process", selection: binding(\.process)) {
                ForEach(CameraRawProcessVersion.allCases, id: \.self) { Text($0.localizedName).tag($0) }
            }
            .help("Chooses how strongly the calibration sliders below are applied. Version 6 is the current default.")
            Text(raw.calibration.process.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .help(raw.calibration.process.summary)
            Text("Shadows").font(.subheadline)
            calibrationSlider("Tint", \.shadowTint, help: "Adds green or magenta to the darkest tones.")
            Text("Red Primary").font(.subheadline)
            calibrationSlider("Hue", \.redHue, help: "Shifts how red is interpreted.")
            calibrationSlider("Saturation", \.redSaturation, help: "Strengthens or weakens the red primary.")
            Text("Green Primary").font(.subheadline)
            calibrationSlider("Hue", \.greenHue, help: "Shifts how green is interpreted.")
            calibrationSlider("Saturation", \.greenSaturation, help: "Strengthens or weakens the green primary.")
            Text("Blue Primary").font(.subheadline)
            calibrationSlider("Hue", \.blueHue, help: "Shifts how blue is interpreted.")
            calibrationSlider("Saturation", \.blueSaturation, help: "Strengthens or weakens the blue primary.")
        }
    }

    private func binding<T>(_ key: WritableKeyPath<CameraRawCalibrationSettings, T>) -> Binding<T> {
        Binding(get: { raw.calibration[keyPath: key] }, set: { value in update { $0.cameraRaw.calibration[keyPath: key] = value } })
    }

    private func calibrationSlider(_ title: String, _ key: WritableKeyPath<CameraRawCalibrationSettings, Double>, help: String) -> some View {
        let value = raw.calibration[keyPath: key]
        return HStack(spacing: 10) {
            Text(title).frame(minWidth: CameraRawControls.labelWidth, alignment: .leading).help(help)
            CameraRawSlider(value: value, range: CameraRawCalibrationSettings.toneRange, track: .plain, help: help,
                            onChange: { rawValue in update { $0.cameraRaw.calibration[keyPath: key] = rawValue.rounded() } },
                            onReset: { update { $0.cameraRaw.calibration[keyPath: key] = 0 } })
            TextField(title, value: Binding(get: { raw.calibration[keyPath: key] },
                                            set: { newValue in update { $0.cameraRaw.calibration[keyPath: key] = newValue } }),
                      format: .number.precision(.fractionLength(0)))
                .frame(width: 56).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).help(help)
        }
    }

    private func update(_ change: (inout FilterSettings) -> Void) {
        var value = settings
        change(&value)
        session.updateFilter(value, preview: session.filterEdit?.preview ?? true)
    }
}
