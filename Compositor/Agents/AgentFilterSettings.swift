import CoreGraphics

/// A filter's settings as an agent writes them: JSON whose keys are `FilterSettings`' own names. Each filter takes
/// only the keys it reads, so a misspelled or misplaced one is reported instead of quietly doing nothing; ranges are
/// held as the panels hold them (`FilterSettings.normalized`).
enum AgentFilterSettings {
    /// The keys each filter reads. A nested group (`dither`, `cameraRaw`, the color adjustments') takes an object.
    static let keys: [FilterKind: [String]] = [
        .gaussianBlur: ["radius", "preserveTransparency"],
        .motionBlur: ["angle", "distance"],
        .progressiveBlur: ["progressiveFrom", "progressiveTo", "progressiveStart", "progressiveEnd", "progressiveRadial", "progressiveInverted"],
        .addNoise: ["amount", "gaussian", "monochromatic"],
        .vignette: ["vignetteAmount", "vignetteColor", "vignetteMidpoint", "vignetteRoundness", "vignetteFeather", "vignetteHighlights"],
        .bloomGlow: ["bloomAmount", "bloomRadius"],
        .dither: ["dither"],
        .scanlines: ["scanlines"],
        .rgbSplit: ["rgbSplitDistance", "rgbSplitBlur", "rgbSplitAngle", "rgbSplitRadial", "rgbSplitCenter", "rgbSplitReach"],
        .tonalContrast: ["tonalAmount", "tonalRadius", "tonalShadows", "tonalMidtones", "tonalHighlights"],
        .lensCorrection: ["distortion"],
        .cameraRaw: ["cameraRaw"],
        .removeBackground: ["backgroundQuality", "refineEdges", "matteContrast", "shiftEdge"],
        .contentAwareFill: [],
        .curves: ["curves"],
        .exposure: ["exposure"],
        .gradientMap: ["gradientMap"],
        .grain: ["grain"],
        .blackWhite: ["blackWhite"],
        .colorBalance: ["colorBalance"],
    ]

    /// The filters and their keys, for the apply_filter tool's description.
    static var reference: String {
        FilterKind.allCases.map { kind in
            let names = keys[kind] ?? []
            let nested = names.compactMap { name in groups[name].map { "\(name): {\($0.joined(separator: ", "))}" } }
            let flat = names.filter { groups[$0] == nil && !codableGroups.contains($0) }
            let described = flat + nested + names.filter(codableGroups.contains).map { "\($0): {…as in an adjustment layer}" }
            return "\(kind.rawValue): \(described.isEmpty ? "no settings" : described.joined(separator: ", "))"
        }.joined(separator: "; ")
    }

    static func apply(_ patch: JSONValue, for kind: FilterKind, to settings: inout FilterSettings) throws {
        guard let changes = patch.object else { throw AgentError("`settings` must be a JSON object.") }
        let allowed = keys[kind] ?? []
        for (key, value) in changes.sorted(by: { $0.key < $1.key }) {
            guard allowed.contains(key) else {
                throw AgentError("\(kind.rawValue) takes no setting “\(key)”." + (allowed.isEmpty ? " It has none." : " It takes: \(allowed.joined(separator: ", ")).")
                )
            }
            switch key {
            case "curves": settings.curves = try AgentTools.patched(settings.curves, with: value)
            case "exposure": settings.exposure = try AgentTools.patched(settings.exposure, with: value)
            case "gradientMap": settings.gradientMap = try AgentTools.patched(settings.gradientMap, with: value)
            case "grain": settings.grain = try AgentTools.patched(settings.grain, with: value)
            case "blackWhite": settings.blackWhite = try AgentTools.patched(settings.blackWhite, with: value)
            case "colorBalance": settings.colorBalance = try AgentTools.patched(settings.colorBalance, with: value)
            case "dither": try dither.apply(value, to: &settings.dither, in: key)
            case "scanlines": try scanlines.apply(value, to: &settings.scanlines, in: key)
            case "cameraRaw": try cameraRaw.apply(value, to: &settings.cameraRaw, in: key)
            default: try filter.apply(.object([key: value]), to: &settings, in: nil)
            }
        }
    }

    /// Settings that take an object of their own fields.
    private static let groups: [String: [String]] = ["dither": dither.names, "scanlines": scanlines.names, "cameraRaw": cameraRaw.names]
    /// Settings that are an adjustment layer's own, written as its manifest writes them.
    private static let codableGroups: Set<String> = ["curves", "exposure", "gradientMap", "grain", "blackWhite", "colorBalance"]

    private static let filter = Fields<FilterSettings>(
        numbers: ["radius": \.radius, "angle": \.angle, "distance": \.distance, "progressiveFrom": \.progressiveFrom,
                  "progressiveTo": \.progressiveTo, "amount": \.amount, "vignetteAmount": \.vignetteAmount,
                  "vignetteMidpoint": \.vignetteMidpoint, "vignetteRoundness": \.vignetteRoundness,
                  "vignetteFeather": \.vignetteFeather, "vignetteHighlights": \.vignetteHighlights, "bloomAmount": \.bloomAmount,
                  "bloomRadius": \.bloomRadius, "tonalAmount": \.tonalAmount, "tonalRadius": \.tonalRadius,
                  "tonalShadows": \.tonalShadows, "tonalMidtones": \.tonalMidtones, "tonalHighlights": \.tonalHighlights,
                  "rgbSplitDistance": \.rgbSplitDistance, "rgbSplitBlur": \.rgbSplitBlur, "rgbSplitAngle": \.rgbSplitAngle,
                  "rgbSplitReach": \.rgbSplitReach, "distortion": \.distortion, "refineEdges": \.refineEdges,
                  "matteContrast": \.matteContrast, "shiftEdge": \.shiftEdge],
        flags: ["preserveTransparency": \.preserveTransparency, "progressiveRadial": \.progressiveRadial,
                "progressiveInverted": \.progressiveInverted, "gaussian": \.gaussian, "monochromatic": \.monochromatic,
                "rgbSplitRadial": \.rgbSplitRadial],
        points: ["progressiveStart": \.progressiveStart, "progressiveEnd": \.progressiveEnd, "rgbSplitCenter": \.rgbSplitCenter],
        colors: ["vignetteColor": \.vignetteColor],
        choices: ["backgroundQuality": .init(BackgroundQuality.self, \.backgroundQuality)])

    private static let dither = Fields<DitherSettings>(
        numbers: ["pixelSize": \.pixelSize, "cellSize": \.cellSize, "textSize": \.textSize, "angle": \.angle, "levels": \.levels,
                  "diffusion": \.diffusion, "density": \.density, "contrast": \.contrast],
        flags: ["lightOnDark": \.lightOnDark],
        colors: ["dark": \.dark, "light": \.light],
        choices: ["style": .init(DitherStyle.self, \.style), "pixelShape": .init(DitherPixelShape.self, \.pixelShape),
                  "colors": .init(DitherColors.self, \.colors)],
        strings: ["characters": \.characters])

    private static let scanlines = Fields<ScanlinesSettings>(
        numbers: ["lineSpacing": \.lineSpacing, "thickness": \.thickness, "glow": \.glow, "dots": \.dots, "wobble": \.wobble,
                  "displace": \.displace, "smoothness": \.smoothness, "threshold": \.threshold, "split": \.split,
                  "density": \.density, "contrast": \.contrast, "blackLevel": \.blackLevel],
        colors: ["dark": \.dark, "light": \.light],
        choices: ["colors": .init(DitherColors.self, \.colors)])

    /// Every Camera Raw panel's sliders, switches and menus, the Point Color picks and Upright guides included.
    private static let cameraRaw = Fields<CameraRawSettings>(
        numbers: ["temperature": \.temperature, "tint": \.tint, "exposure": \.exposure, "contrast": \.contrast,
                  "highlights": \.highlights, "shadows": \.shadows, "whites": \.whites, "blacks": \.blacks,
                  "vibrance": \.vibrance, "saturation": \.saturation, "texture": \.texture, "clarity": \.clarity,
                  "dehaze": \.dehaze, "glow": \.glow, "glowRange": \.glowRange, "glowSpread": \.glowSpread,
                  "glowWarmth": \.glowWarmth, "vignetteAmount": \.vignetteAmount, "vignetteMidpoint": \.vignetteMidpoint,
                  "vignetteRoundness": \.vignetteRoundness, "vignetteFeather": \.vignetteFeather,
                  "vignetteHighlights": \.vignetteHighlights, "grainAmount": \.grainAmount, "grainSize": \.grainSize,
                  "grainRoughness": \.grainRoughness],
        choices: ["whiteBalance": .init(CameraRawWhiteBalance.self, \.whiteBalance), "glowStyle": .init(CameraRawGlowStyle.self, \.glowStyle),
                  "vignetteStyle": .init(CameraRawVignetteStyle.self, \.vignetteStyle)],
        nested: [
            "curve": .group(\.curve, Fields<CameraRawCurveSettings>(
                numbers: ["shadows": \.shadows, "darks": \.darks, "lights": \.lights, "highlights": \.highlights,
                          "shadowSplit": \.shadowSplit, "darkSplit": \.darkSplit, "lightSplit": \.lightSplit,
                          "refineSaturation": \.refineSaturation],
                nested: ["rgb": .replaced(\.rgb), "red": .replaced(\.red), "green": .replaced(\.green), "blue": .replaced(\.blue)])),
            "mixer": .group(\.mixer, Fields<CameraRawMixerSettings>(
                nested: ["hue": .families(\.hue), "saturation": .families(\.saturation), "luminance": .families(\.luminance),
                         "points": pointColors])),
            "grading": .group(\.grading, Fields<CameraRawGradingSettings>(
                numbers: ["blending": \.blending, "balance": \.balance],
                nested: ["shadows": .group(\.shadows, wheel), "midtones": .group(\.midtones, wheel),
                         "highlights": .group(\.highlights, wheel), "global": .group(\.global, wheel)])),
            "detail": .group(\.detail, Fields<CameraRawDetailSettings>(
                numbers: ["sharpenAmount": \.sharpenAmount, "sharpenRadius": \.sharpenRadius, "sharpenDetail": \.sharpenDetail,
                          "sharpenMasking": \.sharpenMasking, "noiseLuminance": \.noiseLuminance,
                          "noiseLuminanceDetail": \.noiseLuminanceDetail, "noiseLuminanceContrast": \.noiseLuminanceContrast,
                          "noiseColor": \.noiseColor, "noiseColorDetail": \.noiseColorDetail,
                          "noiseColorSmoothness": \.noiseColorSmoothness])),
            "optics": .group(\.optics, Fields<CameraRawOpticsSettings>(
                numbers: ["profileDistortion": \.profileDistortion, "profileVignetting": \.profileVignetting,
                          "distortion": \.distortion, "purpleAmount": \.purpleAmount, "purpleHueLow": \.purpleHueLow,
                          "purpleHueHigh": \.purpleHueHigh, "greenAmount": \.greenAmount, "greenHueLow": \.greenHueLow,
                          "greenHueHigh": \.greenHueHigh, "vignetteAmount": \.vignetteAmount, "vignetteMidpoint": \.vignetteMidpoint],
                flags: ["removeChromaticAberration": \.removeChromaticAberration, "enableLensProfile": \.enableLensProfile])),
            "geometry": .group(\.geometry, Fields<CameraRawGeometrySettings>(
                numbers: ["vertical": \.vertical, "horizontal": \.horizontal, "rotate": \.rotate, "aspect": \.aspect,
                          "scale": \.scale, "offsetX": \.offsetX, "offsetY": \.offsetY],
                flags: ["constrainCrop": \.constrainCrop],
                choices: ["upright": .init(CameraRawUprightMode.self, \.upright), "projection": .init(CameraRawProjection.self, \.projection)],
                nested: ["guides": guides])),
            "calibration": .group(\.calibration, Fields<CameraRawCalibrationSettings>(
                numbers: ["shadowTint": \.shadowTint, "redHue": \.redHue, "redSaturation": \.redSaturation,
                          "greenHue": \.greenHue, "greenSaturation": \.greenSaturation, "blueHue": \.blueHue,
                          "blueSaturation": \.blueSaturation],
                choices: ["process": .init(CameraRawProcessVersion.self, \.process)])),
        ])

    /// The Color Mixer's Point Color list, up to eight: each picks a `color` ("#RRGGBB", as the eyedropper would) or
    /// gives its hue (degrees), saturation and luminance (0–1) outright, then shifts it.
    private static let pointColors = Fields<CameraRawMixerSettings>.Nested { mixer, value, name in
        guard let list = value.array, list.count <= 8 else { throw AgentError("“\(name)” is a list of up to 8 picked colors.") }
        mixer.points = try list.enumerated().map { index, item in
            guard var fields = item.object else { throw AgentError("Each of “\(name)” is an object.") }
            var point = CameraRawPointColor()
            if let picked = fields.removeValue(forKey: "color") {
                guard let color = picked.string.flatMap({ PaletteColor(hex: $0) }) else { throw AgentError("“\(name)[\(index)].color” is #RRGGBB.") }
                point = CameraRawPointColor(red: Double(color.red), green: Double(color.green), blue: Double(color.blue))
            }
            try pointColor.apply(.object(fields), to: &point, in: "\(name)[\(index)]")
            return point
        }
    }

    private static let pointColor = Fields<CameraRawPointColor>(
        numbers: ["hue": \.hue, "saturation": \.saturation, "luminance": \.luminance, "hueShift": \.hueShift,
                  "saturationShift": \.saturationShift, "luminanceShift": \.luminanceShift, "hueRange": \.hueRange,
                  "saturationRange": \.saturationRange, "luminanceRange": \.luminanceRange])

    /// Upright's guides, at most two, each {"start": [x, y], "end": [x, y]} as fractions of the layer from its top-left:
    /// the first straightens, the second corrects perspective too. Giving them turns Upright to Guided.
    private static let guides = Fields<CameraRawGeometrySettings>.Nested { geometry, value, name in
        guard let list = value.array, list.count <= 2 else { throw AgentError("“\(name)” is a list of one or two guides.") }
        func fraction(_ value: JSONValue?) -> CGPoint? {
            guard let pair = value?.array, pair.count == 2, let x = pair[0].number, let y = pair[1].number,
                  (0...1).contains(x), (0...1).contains(y) else { return nil }
            return CGPoint(x: x, y: y)
        }
        geometry.guides = try list.map { item in
            guard let start = fraction(item["start"]), let end = fraction(item["end"]) else {
                throw AgentError("Each of “\(name)” is {\"start\": [x, y], \"end\": [x, y]}, fractions 0–1 of the layer from its top-left.")
            }
            // The filter keeps them from the pixel grid's lower-left.
            return CameraRawGeometryGuide(startX: start.x, startY: 1 - start.y, endX: end.x, endY: 1 - end.y)
        }
        geometry.upright = list.isEmpty ? .off : .guided
    }

    private static let wheel = Fields<CameraRawGradeWheel>(numbers: ["hue": \.hue, "saturation": \.saturation, "luminance": \.luminance])
}

/// A settings struct's fields by name, for writing them from JSON.
struct Fields<Root> {
    /// An enum field, set from its raw value.
    struct Choice {
        let options: [String]
        let set: (inout Root, String) -> Void
        init<Value: RawRepresentable & CaseIterable>(_ type: Value.Type, _ path: WritableKeyPath<Root, Value>) where Value.RawValue == String {
            options = Value.allCases.map(\.rawValue)
            set = { root, raw in if let value = Value(rawValue: raw) { root[keyPath: path] = value } }
        }
    }
    var numbers: [String: WritableKeyPath<Root, Double>] = [:]
    var flags: [String: WritableKeyPath<Root, Bool>] = [:]
    var points: [String: WritableKeyPath<Root, CGPoint?>] = [:]
    var colors: [String: WritableKeyPath<Root, AdjustmentColor>] = [:]
    var choices: [String: Choice] = [:]
    var strings: [String: WritableKeyPath<Root, String>] = [:]
    /// Fields that take an object or a list of their own.
    var nested: [String: Nested] = [:]

    /// A field holding more than one value, written from JSON by `write`; `name` is its full name, for messages.
    struct Nested {
        let write: (inout Root, JSONValue, String) throws -> Void

        /// A group of fields of its own, written field by field.
        static func group<Value>(_ path: WritableKeyPath<Root, Value>, _ fields: Fields<Value>) -> Nested {
            Nested { root, value, name in try fields.apply(value, to: &root[keyPath: path], in: name) }
        }
        /// A value replaced whole, as its JSON says: a curve's points, [{"x": 0, "y": 0}, …] from 0 to 1.
        static func replaced<Value: Decodable>(_ path: WritableKeyPath<Root, Value>) -> Nested {
            Nested { root, value, name in
                do { root[keyPath: path] = try value.decoded(as: Value.self) }
                catch { throw AgentError("“\(name)” doesn't fit: \(AgentTools.describe(error)).") }
            }
        }
        /// The Color Mixer's eight color families: a list of eight numbers, or some of them by name ({"Oranges": 10}).
        static func families(_ path: WritableKeyPath<Root, [Double]>) -> Nested {
            Nested { root, value, name in
                let names = CameraRawMixerSettings.names
                if let list = value.array {
                    let numbers = list.compactMap(\.number)
                    guard numbers.count == names.count, list.count == names.count else { throw AgentError("“\(name)” lists \(names.count) numbers: \(names.joined(separator: ", ")).") }
                    root[keyPath: path] = numbers
                } else if let byName = value.object {
                    for (family, amount) in byName {
                        guard let index = names.firstIndex(where: { $0.lowercased() == family.lowercased() }), let number = amount.number else {
                            throw AgentError("“\(name)” takes numbers for: \(names.joined(separator: ", ")).")
                        }
                        root[keyPath: path][index] = number
                    }
                } else {
                    throw AgentError("“\(name)” is a list of \(names.count) numbers, or an object of them by color.")
                }
            }
        }
    }

    var names: [String] {
        (Array(numbers.keys) + Array(flags.keys) + Array(points.keys) + Array(colors.keys) + Array(choices.keys) + Array(strings.keys)
            + Array(nested.keys)).sorted()
    }

    /// Writes `patch`'s fields into `value`. `group` names the object they came in, for messages.
    func apply(_ patch: JSONValue, to value: inout Root, in group: String?) throws {
        guard let changes = patch.object else { throw AgentError("“\(group ?? "settings")” must be a JSON object.") }
        for (key, item) in changes {
            let name = group.map { "\($0).\(key)" } ?? key
            if let path = numbers[key] {
                guard let number = item.number, number.isFinite else { throw AgentError("“\(name)” must be a number.") }
                value[keyPath: path] = number
            } else if let path = flags[key] {
                guard let flag = item.bool else { throw AgentError("“\(name)” must be true or false.") }
                value[keyPath: path] = flag
            } else if let path = points[key] {
                guard let pair = item.array, pair.count == 2, let x = pair[0].number, let y = pair[1].number else {
                    throw AgentError("“\(name)” must be [x, y] in document pixels.")
                }
                value[keyPath: path] = CGPoint(x: x, y: y)
            } else if let path = colors[key] {
                value[keyPath: path] = try AgentTools.patched(value[keyPath: path], with: item)
            } else if let choice = choices[key] {
                guard let raw = item.string, choice.options.contains(raw) else {
                    throw AgentError("“\(name)” is one of: \(choice.options.joined(separator: ", ")).")
                }
                choice.set(&value, raw)
            } else if let path = strings[key] {
                guard let string = item.string else { throw AgentError("“\(name)” must be a string.") }
                value[keyPath: path] = string
            } else if let field = nested[key] {
                try field.write(&value, item, name)
            } else {
                throw AgentError("There's no setting “\(name)”. \(group.map { "\($0) takes" } ?? "These are"): \(names.joined(separator: ", ")).")
            }
        }
    }
}
