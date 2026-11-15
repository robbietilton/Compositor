import AppKit
import CryptoKit
import Darwin
import Testing
@testable import Compositor

@MainActor
struct BrushPerformanceTests {
    private func shouldRunBenchmark(_ name: String) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BRUSH_BENCHMARK"] == "1" || environment["TEST_RUNNER_BRUSH_BENCHMARK"] == "1" else { return false }
        return (environment["BRUSH_BENCHMARK_CASE"] ?? environment["TEST_RUNNER_BRUSH_BENCHMARK_CASE"]).map { $0 == name } ?? true
    }

    private func processCPUSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    }

    /// Pixel-level CPU/GPU parity for ordered tile-local mask deposits and all shape filters.
    @Test func generatedBristlesMetalPrototype() throws {
        let side = 128
        let origin = SIMD2<Int32>(768, 1024)
        let customMask = Data((0..<side * side).map { index in
            let x = index % side, y = index / side
            return UInt8((x > 16 && x < 112 && y > 28 && y < 96 && (x / 8 + y / 5) % 3 != 0) ? 220 : 0)
        })
        let masks: [(String, Data)] = [
            ("bristles", GeneratedBrushTip.bristles.make().mask(.luminance)),
            ("round", GeneratedBrushTip.mediumRound.make().mask(.luminance)),
            ("custom", customMask)
        ]
        let dabs = (0..<13).map { index -> MetalStampRenderer.Dab in
            let angle = Float(index) * 0.13
            let co = cos(angle), si = sin(angle), radius: Float = 96
            let centerX = Float(origin.x) + 128 + Float(index % 5 - 2) * 15
            let centerY = Float(origin.y) + 128 + Float(index / 5 - 1) * 12
            return MetalStampRenderer.Dab(
                u0: (0.5 - centerX) * co / radius + (0.5 - centerY) * si / radius,
                v0: -(0.5 - centerX) * si / radius + (0.5 - centerY) * co / radius,
                ux: co / radius, uy: si / radius, vx: -si / radius, vy: co / radius,
                flow: 0.78, strength: 0.83)
        }
        let prototype = try #require(MetalStampRenderer())
        for (maskName, tip) in masks {
            for filtering in 0...2 {
                for maximumMode in [false, true] {
                var cpu = [Float](repeating: 0, count: 256 * 256)
                var cpuCap = [Float](repeating: 0, count: 256 * 256)
                let cpuStart = CFAbsoluteTimeGetCurrent()
                tip.withUnsafeBytes { rawMask in
                    let mask = rawMask.bindMemory(to: UInt8.self).baseAddress!
                    for batchIndex in 0..<2 {
                        let startIndex = batchIndex == 0 ? 0 : 7
                        let endIndex = batchIndex == 0 ? 7 : dabs.count
                        for dabIndex in startIndex..<endIndex {
                            cpu.withUnsafeMutableBufferPointer { density in
                                cpuCap.withUnsafeMutableBufferPointer { caps in
                                    brush_render_stamp(density.baseAddress, caps.baseAddress, nil, nil, 256,
                                        0, 0, 256, 256, dabs[dabIndex].u0, dabs[dabIndex].v0,
                                        dabs[dabIndex].ux, dabs[dabIndex].uy, dabs[dabIndex].vx, dabs[dabIndex].vy,
                                        1, dabs[dabIndex].flow, dabs[dabIndex].strength, mask, side, Int32(filtering),
                                        maximumMode ? 1 : 0, 0, 0, 0, 0, nil, 0, 1, 0, nil, 0, nil)
                                }
                            }
                        }
                    }
                }
                let cpuMilliseconds = (CFAbsoluteTimeGetCurrent() - cpuStart) * 1000
                let gpuStart = CFAbsoluteTimeGetCurrent()
                let first = try prototype.render(tip: tip, side: side, width: 256, height: 256,
                    origin: origin, dabs: Array(dabs.prefix(7)), filtering: UInt32(filtering),
                    initialDensity: [Float](repeating: 0, count: 256 * 256), initialCap: [Float](repeating: 0, count: 256 * 256), maximumMode: maximumMode)
                let gpu = try prototype.render(tip: tip, side: side, width: 256, height: 256,
                    origin: origin, dabs: Array(dabs.suffix(6)), filtering: UInt32(filtering),
                    initialDensity: first.density, initialCap: first.cap, maximumMode: maximumMode)
                let gpuMilliseconds = (CFAbsoluteTimeGetCurrent() - gpuStart) * 1000
                let maximumDifference = zip(cpu, gpu.density).map { abs($0 - $1) }.max() ?? 0
                let maximumCapDifference = zip(cpuCap, gpu.cap).map { abs($0 - $1) }.max() ?? 0
                var cpuBytes = [UInt8](repeating: 0, count: cpu.count)
                var gpuBytes = [UInt8](repeating: 0, count: cpu.count)
                cpu.withUnsafeBufferPointer { source in
                    gpu.density.withUnsafeBufferPointer { gpuSource in
                        cpuBytes.withUnsafeMutableBufferPointer { destination in
                            cpuCap.withUnsafeBufferPointer { caps in
                                brush_density_bytes(destination.baseAddress, 256, source.baseAddress, caps.baseAddress, 256, 256)
                            }
                        }
                        gpuBytes.withUnsafeMutableBufferPointer { destination in
                            gpu.cap.withUnsafeBufferPointer { caps in
                                brush_density_bytes(destination.baseAddress, 256, gpuSource.baseAddress, caps.baseAddress, 256, 256)
                            }
                        }
                    }
                }
                let byteDifferences = zip(cpuBytes, gpuBytes).filter { $0 != $1 }.count
                print("STAMP GPU PROTOTYPE mask=\(maskName) filter=\(filtering) maxMode=\(maximumMode) cpu=\(cpuMilliseconds)ms gpu=\(gpuMilliseconds)ms maxDensityError=\(maximumDifference) maxCapError=\(maximumCapDifference) byteDifferences=\(byteDifferences)")
                #expect(maximumDifference < 0.0001)
                #expect(maximumCapDifference == 0)
                #expect(byteDifferences == 0)
                }
            }
        }
        #expect(prototype.cachedMaskCount == masks.count)
    }

    @Test func metalGrainMatchesCPUDabsAndTexturizedCaps() throws {
        let tipShape = GeneratedBrushTip.bristles.make()
        let side = tipShape.side
        let tip = tipShape.mask(.luminance)
        let grainSide = 32
        let grain = Data((0..<grainSide * grainSide).map { index in
            UInt8((index * 37 + index / grainSide * 19) % 256)
        })
        let renderer = try #require(MetalStampRenderer())
        let dabs = (0..<4).map { index -> (MetalStampRenderer.Dab, [Double]) in
            let x = Double(index) * 0.07
            let values: [Double] = [0.13 + x, 0.31 - x, 1.0 / 90, 1.0 / 110,
                1.0 / 120, 1.0 / 100, 0.82, 0.08, 0.24, Double(index % 4), 0, 1]
            let dab = MetalStampRenderer.Dab(u0: Float(-0.5 + Double(index) * 0.08), v0: -0.45,
                ux: 1.0 / 36, uy: 0, vx: 0, vy: 1.0 / 36, flow: 0.72, strength: 0.9, grain: values)
            return (dab, values)
        }

        for filtering in 1...2 {
          for mode in 0...4 {
            let prepared = dabs.enumerated().map { index, pair -> (MetalStampRenderer.Dab, [Double]) in
                var values = pair.1
                values[10] = Double(filtering)
                values[11] = index.isMultiple(of: 2) ? 1 : 0
                let old = pair.0
                return (MetalStampRenderer.Dab(u0: old.u0, v0: old.v0, ux: old.ux, uy: old.uy,
                    vx: old.vx, vy: old.vy, flow: old.flow, strength: old.strength, grain: values), values)
            }
            var cpu = [Float](repeating: 0, count: 96 * 96)
            var cpuCaps = [Float](repeating: 0, count: 96 * 96)
            tip.withUnsafeBytes { tipBytes in
                grain.withUnsafeBytes { grainBytes in
                    for (dab, values) in prepared {
                        values.withUnsafeBufferPointer { parameters in
                            cpu.withUnsafeMutableBufferPointer { density in
                                cpuCaps.withUnsafeMutableBufferPointer { caps in
                                    brush_render_stamp(density.baseAddress, caps.baseAddress, nil, nil, 96,
                                        0, 0, 96, 96, dab.u0, dab.v0, dab.ux, dab.uy, dab.vx, dab.vy,
                                        1, dab.flow, dab.strength, tipBytes.bindMemory(to: UInt8.self).baseAddress,
                                        side, 2, Int32(mode), 0, 0, 0, 0, nil, 0, 1, 0,
                                        grainBytes.bindMemory(to: UInt8.self).baseAddress, grainSide, parameters.baseAddress)
                                }
                            }
                        }
                    }
                }
            }
            let result = try renderer.render(tip: tip, side: side, width: 96, height: 96,
                origin: SIMD2<Int32>(512, 256), dabs: prepared.map(\.0), filtering: 2,
                initialDensity: [Float](repeating: 0, count: 96 * 96),
                initialCap: [Float](repeating: 0, count: 96 * 96), grain: grain, grainSide: grainSide,
                mode: Int32(mode))
            let densityIndex = zip(cpu, result.density).enumerated().max { abs($0.element.0 - $0.element.1) < abs($1.element.0 - $1.element.1) }?.offset ?? 0
            let capIndex = zip(cpuCaps, result.cap).enumerated().max { abs($0.element.0 - $0.element.1) < abs($1.element.0 - $1.element.1) }?.offset ?? 0
            #expect(abs(cpu[densityIndex] - result.density[densityIndex]) < 0.0001,
                "filter=\(filtering) index=\(densityIndex) cpu=\(cpu[densityIndex]) gpu=\(result.density[densityIndex])")
            #expect(abs(cpuCaps[capIndex] - result.cap[capIndex]) < 0.0001,
                "filter=\(filtering) index=\(capIndex) cpu=\(cpuCaps[capIndex]) gpu=\(result.cap[capIndex])")
          }
        }
    }

    @Test func nearestGrainFilteringStaysOnCPUForPrecision() throws {
        let session = EditorSession()
        session.createDocument(width: 128, height: 128)
        session.addBlankLayer()
        var settings = BrushSettings(diameter: 36, hardness: 1)
        settings.roundDynamics.shape = ShapeBrushSettings(source: .generated, generator: .bristles, filtering: .improved)
        settings.roundDynamics.grain = BrushGrain(scale: 18, depth: 1, filtering: .none)
        let layer = try #require(session.activeLayer)
        let nearest = try BrushStroke(layer: layer, mask: false, settings: settings,
            canvas: CGSize(width: 128, height: 128), useGPU: true)
        #expect(!nearest.usesMetalStampRenderer)
        settings.roundDynamics.grain?.filtering = .classic
        let bilinear = try BrushStroke(layer: layer, mask: false, settings: settings,
            canvas: CGSize(width: 128, height: 128), useGPU: true)
        #expect(bilinear.usesMetalStampRenderer)
    }

    @Test func metalWatercolorWetAndBurntEdgeAccumulationMatchesCPU() throws {
        let tipShape = GeneratedBrushTip.bristles.make()
        let tip = tipShape.mask(.luminance)
        let side = tipShape.side
        let grainSide = 32
        let grain = Data((0..<grainSide * grainSide).map { UInt8(($0 * 47 + $0 / grainSide * 13) % 256) })
        let renderer = try #require(MetalStampRenderer())
        let dabs = (0..<5).map { index -> MetalStampRenderer.Dab in
            let offset = Float(index) * 0.06
            let parameters: [Double] = [0.12 + Double(offset), 0.31, 1.0 / 42, 0,
                0, 1.0 / 39, 0.76, 0.04, 0.2, 2, 1, 0]
            return MetalStampRenderer.Dab(u0: -0.48 + offset, v0: -0.42,
                ux: 1.0 / 42, uy: 0, vx: 0, vy: 1.0 / 39,
                flow: 0.68, strength: 0.81, grain: parameters)
        }

        for filtering in 1...2 {
            for wet in [Float(0), 0.4, 1] {
                for mode in 0...4 {
                    var cpuDensity = [Float](repeating: 0, count: 96 * 96)
                    var cpuCaps = [Float](repeating: 0, count: 96 * 96)
                    var cpuEdges = [Float](repeating: 0, count: 96 * 96)
                    tip.withUnsafeBytes { tipBytes in
                        grain.withUnsafeBytes { grainBytes in
                            for dab in dabs {
                                dab.grainParameters.withUnsafeBufferPointer { parameters in
                                    cpuDensity.withUnsafeMutableBufferPointer { density in
                                        cpuCaps.withUnsafeMutableBufferPointer { caps in
                                            cpuEdges.withUnsafeMutableBufferPointer { edges in
                                                brush_render_stamp(density.baseAddress, caps.baseAddress, nil, edges.baseAddress,
                                                    96, 0, 0, 96, 96, dab.u0, dab.v0, dab.ux, dab.uy, dab.vx, dab.vy,
                                                    1, dab.flow, dab.strength, tipBytes.bindMemory(to: UInt8.self).baseAddress,
                                                    side, Int32(filtering), Int32(mode), wet, 0.15, 0.42, 0.8,
                                                    nil, 0, 1, 0, grainBytes.bindMemory(to: UInt8.self).baseAddress,
                                                    grainSide, parameters.baseAddress)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    let gpu = try renderer.render(tip: tip, side: side, width: 96, height: 96,
                        origin: SIMD2<Int32>(256, 128), dabs: dabs, filtering: UInt32(filtering),
                        initialDensity: [Float](repeating: 0, count: 96 * 96),
                        initialCap: [Float](repeating: 0, count: 96 * 96),
                        grain: grain, grainSide: grainSide,
                        initialEdges: [Float](repeating: 0, count: 96 * 96),
                        wetEdges: wet, accumulateEdges: true, mode: Int32(mode))
                    let densityError = zip(cpuDensity, gpu.density).map { abs($0 - $1) }.max() ?? 0
                    let capError = zip(cpuCaps, gpu.cap).map { abs($0 - $1) }.max() ?? 0
                    let edgeDifference = zip(cpuEdges, gpu.edges).enumerated().max { abs($0.element.0 - $0.element.1) < abs($1.element.0 - $1.element.1) }
                    let edgeError = edgeDifference.map { abs($0.element.0 - $0.element.1) } ?? 0
                    #expect(densityError < 0.0001, "filter=\(filtering) wet=\(wet) mode=\(mode) density=\(densityError)")
                    #expect(capError < 0.0001, "filter=\(filtering) wet=\(wet) mode=\(mode) cap=\(capError)")
                    #expect(edgeError < 0.0001, "filter=\(filtering) wet=\(wet) mode=\(mode) index=\(edgeDifference?.offset ?? 0) cpu=\(edgeDifference?.element.0 ?? 0) gpu=\(edgeDifference?.element.1 ?? 0) edge=\(edgeError)")
                }
            }
        }
    }

    @Test func metalStampRendererReusesBoundedScratchBuffers() throws {
        let renderer = try #require(MetalStampRenderer())
        let dab = MetalStampRenderer.Dab(u0: 0, v0: 0, ux: 1.0 / 16, uy: 0, vx: 0, vy: 1.0 / 16)
        let first = try renderer.render(tip: nil, side: 0, width: 16, height: 16,
            origin: .zero, dabs: [dab])
        #expect(renderer.scratchBufferAllocationCount == 3)
        let second = try renderer.render(tip: nil, side: 0, width: 16, height: 16,
            origin: .zero, dabs: [dab], initialDensity: first.density, initialCap: first.cap)
        #expect(first.edges.isEmpty && second.edges.isEmpty)
        #expect(renderer.scratchBufferAllocationCount == 3,
            "Repeating a same-sized tile render should reuse density, cap, and dab buffers")
        let edged = try renderer.render(tip: nil, side: 0, width: 16, height: 16,
            origin: .zero, dabs: [dab], initialDensity: second.density, initialCap: second.cap,
            initialEdges: [Float](repeating: 0, count: 256), accumulateEdges: true)
        #expect(renderer.scratchBufferAllocationCount == 4,
            "An edge buffer is allocated once when edge accumulation is first requested")
        _ = try renderer.render(tip: nil, side: 0, width: 16, height: 16,
            origin: .zero, dabs: [dab], initialDensity: edged.density, initialCap: edged.cap,
            initialEdges: edged.edges, accumulateEdges: true)
        #expect(renderer.scratchBufferAllocationCount == 4)
        let disabledEdges = try renderer.render(tip: nil, side: 0, width: 16, height: 16,
            origin: .zero, dabs: [dab], initialDensity: edged.density, initialCap: edged.cap)
        #expect(disabledEdges.edges.isEmpty && renderer.scratchBufferAllocationCount == 4,
            "Disabled edges still need a valid Metal binding, without allocating another buffer")
        let fullTileCount = 256 * 256
        let fullTile = try renderer.render(tip: nil, side: 0, width: 256, height: 256,
            origin: .zero, dabs: [dab], initialDensity: [Float](repeating: 0, count: fullTileCount),
            initialCap: [Float](repeating: 0, count: fullTileCount),
            initialEdges: [Float](repeating: 0, count: fullTileCount), accumulateEdges: true)
        #expect(renderer.cachedScratchBytes <= 2 << 20,
            "One maximum tile plus pooled dab data stays below the retained scratch budget")
        let retainedBytes = renderer.cachedScratchBytes
        let oversized = [MetalStampRenderer.Dab](repeating: dab, count: (1 << 20) / (5 * MemoryLayout<SIMD4<Float>>.stride) + 1)
        _ = try renderer.render(tip: nil, side: 0, width: 1, height: 1, origin: .zero,
            dabs: oversized, initialDensity: [fullTile.density[0]], initialCap: [fullTile.cap[0]])
        #expect(renderer.cachedScratchBytes == retainedBytes,
            "Oversized dab uploads must use a one-shot buffer rather than expanding the retained pool")
    }

    /// Compare live append cost for the Bristles zero-spacing case; run separately by configuration.
    @Test func zeroSpacingBristlesCPUvsMetalStrokeBenchmark() throws {
        guard shouldRunBenchmark("stamp-metal") else { return }
        for useGPU in [false, true] {
            let session = EditorSession()
            session.createDocument(width: 1024, height: 512)
            session.addBlankLayer()
            var settings = BrushSettings(diameter: 72, hardness: 1, red: 1, green: 1, blue: 1, opacity: 0.8)
            settings.roundDynamics.spacing = 0
            settings.roundDynamics.flow = 0.65
            settings.roundDynamics.count = 4
            settings.roundDynamics.scatter = 0.25
            settings.roundDynamics.shape = ShapeBrushSettings(source: .generated, generator: .bristles, filtering: .improved)
            let stroke = try BrushStroke(layer: #require(session.activeLayer), mask: false,
                settings: settings, canvas: CGSize(width: 1024, height: 512), useGPU: useGPU, seed: 42)
            if useGPU { #expect(stroke.usesMetalStampRenderer) }
            var samples: [Double] = []
            for index in 0...39 {
                let point = CGPoint(x: 192 + index * 16, y: 256)
                let start = CFAbsoluteTimeGetCurrent()
                try stroke.append(point, input: BrushInput(pressure: 0.4 + CGFloat(index) / 65))
                samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            }
            try stroke.flush()
            let sorted = samples.sorted()
            func percentile(_ fraction: Double) -> Double { sorted[min(sorted.count - 1, Int(ceil(fraction * Double(sorted.count))) - 1)] }
            print("STAMP STROKE useGPU=\(useGPU) median=\(percentile(0.5))ms p95=\(percentile(0.95))ms max=\(sorted.last ?? 0)ms total=\(samples.reduce(0,+))ms")
        }
    }

    /// Pair interactive CPU work and mouse-up cost for the same zero-spacing Bristles stroke.
    @Test func settledWatercolorEdgeCPUUsageBenchmark() throws {
        guard shouldRunBenchmark("watercolor-edge") else { return }
        for burntEdges: CGFloat in [0, 1] {
            let session = EditorSession()
            session.createDocument(width: 1024, height: 512)
            session.addBlankLayer()
            var settings = BrushSettings(diameter: 72, hardness: 1, red: 0.08, green: 0.32, blue: 0.62, opacity: 0.82)
            settings.roundDynamics.spacing = 0
            settings.roundDynamics.flow = 0.65
            settings.roundDynamics.count = 4
            settings.roundDynamics.scatter = 0.25
            settings.roundDynamics.shape = ShapeBrushSettings(source: .generated, generator: .bristles, filtering: .improved)
            settings.roundDynamics.rendering = BrushRenderingSettings(burntEdges: burntEdges)
            let stroke = try BrushStroke(layer: #require(session.activeLayer), mask: false, settings: settings,
                canvas: CGSize(width: 1024, height: 512), useGPU: true, seed: 0xA77E)
            var appendCPU = 0.0
            var appendWall: [Double] = []
            for index in 0...39 {
                let point = CGPoint(x: 192 + index * 16, y: 256)
                let cpuStart = processCPUSeconds(), wallStart = CFAbsoluteTimeGetCurrent()
                try stroke.append(point, input: BrushInput(pressure: 0.4 + CGFloat(index) / 65))
                appendCPU += processCPUSeconds() - cpuStart
                appendWall.append((CFAbsoluteTimeGetCurrent() - wallStart) * 1000)
            }
            let mouseUpCPUStart = processCPUSeconds(), mouseUpWallStart = CFAbsoluteTimeGetCurrent()
            try stroke.flush()
            let sorted = appendWall.sorted()
            func percentile(_ fraction: Double) -> Double { sorted[min(sorted.count - 1, Int(ceil(fraction * Double(sorted.count))) - 1)] }
            print("WATERCOLOR EDGE burnt=\(burntEdges) appendCPU=\(appendCPU * 1000)ms appendWallMedian=\(percentile(0.5))ms appendWallP95=\(percentile(0.95))ms appendWallMax=\(sorted.last ?? 0)ms mouseUpCPU=\((processCPUSeconds() - mouseUpCPUStart) * 1000)ms mouseUpWall=\((CFAbsoluteTimeGetCurrent() - mouseUpWallStart) * 1000)ms edgeDistanceCPU=\(stroke.edgePoolingMilliseconds)ms")
        }
    }

    /// Stress multiple tiles with dense zero-spacing input and a high stamp count.
    @Test func wideHighCountBristlesCPUvsMetalBenchmark() throws {
        guard shouldRunBenchmark("stamp-metal-stress") else { return }
        for useGPU in [false, true] {
            let session = EditorSession()
            session.createDocument(width: 1536, height: 1024)
            session.addBlankLayer()
            var settings = BrushSettings(diameter: 96, hardness: 1, red: 0.25, green: 0.7, blue: 1, opacity: 0.82)
            settings.roundDynamics.spacing = 0
            settings.roundDynamics.flow = 0.65
            settings.roundDynamics.count = 12
            settings.roundDynamics.scatter = 0.3
            settings.roundDynamics.shape = ShapeBrushSettings(source: .generated, generator: .bristles, filtering: .improved)
            let stroke = try BrushStroke(layer: #require(session.activeLayer), mask: false,
                settings: settings, canvas: CGSize(width: 1536, height: 1024), useGPU: useGPU, seed: 0x51A2)
            if useGPU { #expect(stroke.usesMetalStampRenderer) }
            var samples: [Double] = []
            for index in 0...39 {
                let point = CGPoint(x: CGFloat(192 + index * 28), y: CGFloat(512 + (index % 5 - 2) * 5))
                let start = CFAbsoluteTimeGetCurrent()
                try stroke.append(point, input: BrushInput(pressure: 0.35 + CGFloat(index) / 70))
                samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            }
            try stroke.flush()
            let sorted = samples.sorted()
            func percentile(_ fraction: Double) -> Double { sorted[min(sorted.count - 1, Int(ceil(fraction * Double(sorted.count))) - 1)] }
            print("STAMP STRESS useGPU=\(useGPU) canvas=1536x1024 samples=40 count=12 spacing=0 median=\(percentile(0.5))ms p95=\(percentile(0.95))ms max=\(sorted.last ?? 0)ms total=\(samples.reduce(0,+))ms")
        }
    }

    /// Run separately from the functional suite to avoid competing main-actor work.
    @Test func fourKInteractiveStroke() async throws {
        guard shouldRunBenchmark("interactive") else { return }
        #expect(MetalBrushCoverage.shared != nil)
        for diameter: CGFloat in [40, 800] {
            for opaque in [false, true] {
                let session = EditorSession()
                session.createDocument(width: 4000, height: 4000)
                if opaque {
                    let context = try BrushRaster.context(width: 4000, height: 4000, mask: false)
                    context.setFillColor(gray: 0, alpha: 1)
                    context.fill(CGRect(x: 0, y: 0, width: 4000, height: 4000))
                    let image = try #require(context.makeImage())
                    session.insert(ImportedImage(image: image, thumbnail: image, name: "Opaque 4K"))
                } else { session.addBlankLayer() }
                session.selectTool(.brush)
                session.brushSettings = BrushSettings(diameter: diameter, hardness: 0, red: 1, green: 1, blue: 1)
                let view = CanvasView(session: session)
                let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 1000),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = view
                window.orderFront(nil)
                session.viewport.resize(to: view.bounds.size, backingScale: 2, documentSize: session.document?.size)
                session.viewport.fit(documentSize: session.document!.size)
                if ProcessInfo.processInfo.environment["BRUSH_PROFILE_ATTACH"] == "1" {
                    Thread.sleep(forTimeInterval: 12)
                }
                var frameTimes: [Double] = []
                for pass in 0..<2 {
                    let start = CFAbsoluteTimeGetCurrent()
                    session.beginBrush(at: CGPoint(x: 700, y: 3200))
                    for i in 1...120 {
                        let t = CFAbsoluteTimeGetCurrent()
                        let point = i <= 60 ? CGPoint(x: 700, y: 3200 - i * 40) : CGPoint(x: 700 + (i - 60) * 40, y: 800)
                        session.continueBrush(at: point)
                        view.synchronizeDisplay()
                        BrushPerformanceSignpost.measure("Brush Display If Needed") { view.displayIfNeeded() }
                        frameTimes.append((CFAbsoluteTimeGetCurrent() - t) * 1000)
                    }
                    let end = CFAbsoluteTimeGetCurrent()
                    await session.finishBrush()
                    view.synchronizeDisplay()
                    BrushPerformanceSignpost.measure("Brush Display If Needed") { view.displayIfNeeded() }
                    print("BRUSH BENCH diameter=\(diameter) opaque=\(opaque) pass=\(pass) draw=\((end-start)*1000) mouseUp=\((CFAbsoluteTimeGetCurrent()-end)*1000)ms")
                    #expect(session.brushError == nil)
                }
                frameTimes.sort()
                print("BRUSH BENCH diameter=\(diameter) opaque=\(opaque) frame median=\(frameTimes[frameTimes.count/2]) p95=\(frameTimes[Int(Double(frameTimes.count)*0.95)]) max=\(frameTimes.last!)ms")
                if diameter == 800, opaque {
                    try await ImageExporter.shared.exportPNG(try #require(session.projectSnapshot()),
                        to: URL(fileURLWithPath: "/tmp/compositor-brush-benchmark.png"))
                }
                window.orderOut(nil)
            }
        }
        if ProcessInfo.processInfo.environment["BRUSH_PROFILE_ATTACH"] == "1" {
            Thread.sleep(forTimeInterval: 45)
        }
    }

    @Test func bristlesZeroSpacing4K() async throws {
        guard shouldRunBenchmark("bristles") else { return }
        let session = EditorSession()
        session.createDocument(width: 4000, height: 4000)
        session.addBlankLayer()
        session.selectTool(.brush)
        var settings = BrushSettings(diameter: 120, hardness: 1, red: 0, green: 0, blue: 0)
        settings.roundDynamics.spacing = 0
        settings.roundDynamics.shape = ShapeBrushSettings(source: .generated, generator: .bristles, filtering: .none)
        session.brushSettings = settings
        let view = CanvasView(session: session)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 1000),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        session.viewport.resize(to: view.bounds.size, backingScale: 2, documentSize: session.document?.size)
        session.viewport.fit(documentSize: session.document!.size)
        var times: [Double] = []
        session.beginBrush(at: CGPoint(x: 900, y: 2000), seed: 0xB71571E5)
        let start = CFAbsoluteTimeGetCurrent()
        session.continueBrush(at: CGPoint(x: 910, y: 2000))
        view.synchronizeDisplay()
        view.displayIfNeeded()
        times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        let end = CFAbsoluteTimeGetCurrent()
        await session.finishBrush()
        times.sort()
        print("BRUSH BENCH bristles-120px-zero-spacing updates=1 draw p50=\(times[times.count/2]) p95=\(times.last!) max=\(times.last!) mouseUp=\((CFAbsoluteTimeGetCurrent()-end)*1000)ms")
        #expect(session.brushError == nil)
        window.orderOut(nil)
    }

    @Test func deterministic4KWorkloadMatrix() async throws {
        guard shouldRunBenchmark("matrix") else { return }
        struct Workload {
            let name: String
            let diameter: CGFloat
            let opaque: Bool
            var useGPU = true
            var sampleCount = 12
            var samplesPerFrame = 1
            var sampleRate = 60.0
            let settings: (inout BrushSettings) -> Void
        }
        let asymmetricMask = Data((0..<64 * 64).map { index -> UInt8 in
            let x = index % 64, y = index / 64
            return x > y / 2 && x < 48 && y < 56 ? 255 : 0
        })
        let asymmetric = BrushShapeTip(side: 64, luminance: asymmetricMask, alpha: Data(repeating: 255, count: 64 * 64), name: "Generated benchmark L")
        let workloads: [Workload] = [
            .init(name: "generated-bristles-40-zero-spacing", diameter: 40, opaque: false, settings: {
                $0.roundDynamics.spacing = 0
                $0.roundDynamics.shape = ShapeBrushSettings(source: .generated, generator: .bristles, filtering: .none)
            }),
            .init(name: "generated-bristles-800-zero-spacing", diameter: 800, opaque: false, settings: {
                $0.roundDynamics.spacing = 0
                $0.roundDynamics.shape = ShapeBrushSettings(source: .generated, generator: .bristles, filtering: .none)
            }),
            .init(name: "frame-batch-bristles-800-240hz-single", diameter: 800, opaque: false,
                  sampleCount: 48, sampleRate: 240, settings: {
                $0.roundDynamics.spacing = 0
                $0.roundDynamics.shape = ShapeBrushSettings(source: .generated, generator: .bristles, filtering: .none)
            }),
            .init(name: "frame-batch-bristles-800-240hz-four", diameter: 800, opaque: false,
                  sampleCount: 48, samplesPerFrame: 4, sampleRate: 240, settings: {
                $0.roundDynamics.spacing = 0
                $0.roundDynamics.shape = ShapeBrushSettings(source: .generated, generator: .bristles, filtering: .none)
            }),
            .init(name: "generated-speckle-40", diameter: 40, opaque: false, settings: {
                $0.roundDynamics.shape = ShapeBrushSettings(source: .generated, generator: .speckle)
            }),
            .init(name: "generated-speckle-800", diameter: 800, opaque: false, settings: {
                $0.roundDynamics.shape = ShapeBrushSettings(source: .generated, generator: .speckle)
            }),
            .init(name: "asymmetric-improved-40", diameter: 40, opaque: false, settings: {
                $0.roundDynamics.shape = ShapeBrushSettings(source: .custom, customTip: asymmetric, filtering: .improved)
            }),
            .init(name: "asymmetric-improved-800", diameter: 800, opaque: false, settings: {
                $0.roundDynamics.shape = ShapeBrushSettings(source: .custom, customTip: asymmetric, filtering: .improved)
            }),
            .init(name: "high-count-40", diameter: 40, opaque: false, settings: {
                $0.roundDynamics.count = 8; $0.roundDynamics.scatter = 0.4; $0.roundDynamics.spacing = 0.25
            }),
            .init(name: "high-count-800", diameter: 800, opaque: false, settings: {
                $0.roundDynamics.count = 8; $0.roundDynamics.scatter = 0.4; $0.roundDynamics.spacing = 0.25
            }),
            .init(name: "textured-blending-40-opaque", diameter: 40, opaque: true, settings: {
                $0.roundDynamics.grain = BrushGrain(scale: 64, depth: 1)
                $0.roundDynamics.rendering = BrushRenderingSettings(mode: .intenseBlending, wetEdges: 0.5, burntEdges: 0.5)
            }),
            .init(name: "textured-blending-800-opaque", diameter: 800, opaque: true, settings: {
                $0.roundDynamics.grain = BrushGrain(scale: 64, depth: 1)
                $0.roundDynamics.rendering = BrushRenderingSettings(mode: .intenseBlending, wetEdges: 0.5, burntEdges: 0.5)
            }),
            .init(name: "textured-standard-800-opaque", diameter: 800, opaque: true, settings: {
                $0.roundDynamics.grain = BrushGrain(scale: 64, depth: 1)
            }),
            .init(name: "textured-standard-800-opaque-cpu", diameter: 800, opaque: true, useGPU: false, settings: {
                $0.roundDynamics.grain = BrushGrain(scale: 64, depth: 1)
            })
        ]

        let workloadFilter = ProcessInfo.processInfo.environment["BRUSH_BENCHMARK_WORKLOAD"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_BRUSH_BENCHMARK_WORKLOAD"]
        for workload in workloads where workloadFilter == nil || workload.name == workloadFilter {
            let session = EditorSession()
            session.createDocument(width: 4000, height: 4000)
            if workload.opaque {
                let context = try BrushRaster.context(width: 4000, height: 4000, mask: false)
                context.setFillColor(gray: 0.25, alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: 4000, height: 4000))
                let image = try #require(context.makeImage())
                session.insert(ImportedImage(image: image, thumbnail: image, name: "Opaque 4K"))
            } else { session.addBlankLayer() }
            session.selectTool(.brush)
            var settings = BrushSettings(diameter: workload.diameter, hardness: 0, red: 1, green: 0.25, blue: 0.1)
            workload.settings(&settings)
            session.brushSettings = settings
            let view = CanvasView(session: session)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 1000),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view; window.orderFront(nil)
            session.viewport.resize(to: view.bounds.size, backingScale: 2, documentSize: session.document?.size)
            session.viewport.fit(documentSize: session.document!.size)
            // Keep the host alive long enough for Instruments to attach before the measured workload starts.
            if ProcessInfo.processInfo.environment["BRUSH_PROFILE_ATTACH"] == "1" { Thread.sleep(forTimeInterval: 12) }
            session.beginBrush(at: CGPoint(x: 800, y: 2000), input: BrushInput(pressure: 0.35, tilt: CGPoint(x: 0.3, y: 0.7), rotation: 0.2, timestamp: 1, deviceID: 42),
                seed: 0xB71571E5, useGPU: workload.useGPU)
            var samples: [Double] = []
            var frameStart = CFAbsoluteTimeGetCurrent()
            for index in 1...workload.sampleCount {
                if (index - 1) % workload.samplesPerFrame == 0 { frameStart = CFAbsoluteTimeGetCurrent() }
                let input = BrushInput(pressure: 0.35 + CGFloat(index) * 0.008,
                    tilt: CGPoint(x: 0.3 + CGFloat(index) * 0.002, y: 0.7), rotation: 0.2 + CGFloat(index) * 0.004,
                    timestamp: 1 + Double(index) / workload.sampleRate, deviceID: 42)
                let point = CGPoint(x: 800 + index * 10, y: 2000 + (index % 3) * 2)
                if workload.samplesPerFrame == 1 {
                    session.continueBrush(at: point, input: input)
                } else {
                    session.queueBrushInput(at: point, input: input)
                }
                let frameEnd = index % workload.samplesPerFrame == 0 || index == workload.sampleCount
                if frameEnd {
                    if workload.samplesPerFrame > 1 { try session.flushQueuedBrushInputSamples() }
                    view.synchronizeDisplay(); view.displayIfNeeded()
                    samples.append((CFAbsoluteTimeGetCurrent() - frameStart) * 1000)
                }
            }
            let completedStroke = session.brushStroke
            let touchedTiles = completedStroke?.touchedTileCount ?? 0
            let mouseUp = CFAbsoluteTimeGetCurrent()
            await session.finishBrush()
            samples.sort()
            let image = try #require(session.activeLayer?.asset?.image)
            let pixels = try #require(image.dataProvider?.data) as Data
            let digest = SHA256.hash(data: pixels).map { String(format: "%02x", $0) }.joined()
            if workload.name == "textured-standard-800-opaque" || workload.name == "textured-standard-800-opaque-cpu" {
                try pixels.write(to: URL(fileURLWithPath: "/tmp/compositor-\(workload.name).rgba"))
            }
            func percentile(_ fraction: Double) -> Double { samples[min(samples.count - 1, Int(ceil(fraction * Double(samples.count))) - 1)] }
            print("BRUSH MATRIX \(workload.name) samples=\(workload.sampleCount) perFrame=\(workload.samplesPerFrame) medianFrame=\(percentile(0.5)) p95Frame=\(percentile(0.95)) maxFrame=\(samples.last!) mouseUp=\((CFAbsoluteTimeGetCurrent()-mouseUp)*1000)ms publications=\(completedStroke?.tilePublicationCount ?? 0) metalCompletion=\(completedStroke?.metalStampCompletionMilliseconds ?? 0)ms readback=\(completedStroke?.metalStampReadbackBytes ?? 0)B tiles=\(touchedTiles) pixels=\(digest)")
            #expect(session.brushError == nil)
            #expect(touchedTiles > 0)
            if workload.name == "generated-bristles-800-zero-spacing" || workload.name == "textured-blending-800-opaque" {
                try await ImageExporter.shared.exportPNG(try #require(session.projectSnapshot()),
                    to: URL(fileURLWithPath: "/tmp/compositor-brush-\(workload.name).png"))
            }
            window.orderOut(nil)
        }

        let transformed = EditorSession()
        transformed.createDocument(width: 4000, height: 4000); transformed.addBlankLayer()
        transformed.document?.layers[0].transform = LayerTransform(origin: CGPoint(x: 200, y: 200), size: CGSize(width: 3600, height: 3600), rotation: 7)
        transformed.addLayerMask(); transformed.isMaskSelected = true; transformed.selectTool(.brush)
        transformed.setSelection(DocumentSelection(path: CGPath(rect: CGRect(x: 500, y: 500, width: 3000, height: 3000), transform: nil)), name: "benchmark-selection")
        var maskSettings = BrushSettings(diameter: 40, hardness: 0, red: 1)
        maskSettings.roundDynamics.shape = ShapeBrushSettings(source: .generated, generator: .bristles, filtering: .improved)
        maskSettings.roundDynamics.spacing = 0
        transformed.brushSettings = maskSettings
        let maskView = CanvasView(session: transformed)
        let maskWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 1000), styleMask: [.borderless], backing: .buffered, defer: false)
        maskWindow.contentView = maskView; maskWindow.orderFront(nil)
        transformed.viewport.resize(to: maskView.bounds.size, backingScale: 2, documentSize: transformed.document?.size)
        transformed.viewport.fit(documentSize: transformed.document!.size)
        transformed.beginBrush(at: CGPoint(x: 1000, y: 2000), input: BrushInput(pressure: 0.5, tilt: CGPoint(x: 0.4, y: 0.5), rotation: 0.3, timestamp: 0, deviceID: 42), seed: 0xB71571E5)
        #expect(transformed.isMaskSelected && transformed.activeLayer?.mask != nil)
        #expect(transformed.brushStroke != nil)
        var maskSamples: [Double] = []
        for i in 1...12 {
            let start = CFAbsoluteTimeGetCurrent()
            transformed.continueBrush(at: CGPoint(x: 1000 + i * 10, y: 2000), input: BrushInput(pressure: 0.5, tilt: CGPoint(x: 0.4, y: 0.5), rotation: 0.3, timestamp: Double(i) / 60, deviceID: 42))
            maskView.synchronizeDisplay(); maskView.displayIfNeeded()
            maskSamples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        let maskStroke = transformed.brushStroke
        let maskDabs = maskStroke?.dabIndex ?? -1
        let maskTiles = maskStroke?.touchedTileCount ?? 0
        let maskUp = CFAbsoluteTimeGetCurrent(); await transformed.finishBrush()
        maskSamples.sort()
        let maskImage = try #require(transformed.activeLayer?.mask?.asset.image)
        let maskPixels = try #require(maskImage.dataProvider?.data) as Data
        let maskDigest = SHA256.hash(data: maskPixels).map { String(format: "%02x", $0) }.joined()
        func maskPercentile(_ fraction: Double) -> Double { maskSamples[min(maskSamples.count - 1, Int(ceil(fraction * Double(maskSamples.count))) - 1)] }
        print("BRUSH MATRIX transformed-selected-mask-40-zero-spacing dabs=\(maskDabs) tiles=\(maskTiles) median=\(maskPercentile(0.5)) p95=\(maskPercentile(0.95)) max=\(maskSamples.last!) mouseUp=\((CFAbsoluteTimeGetCurrent()-maskUp)*1000)ms pixels=\(maskDigest)")
        #expect(maskDabs > 0)
        #expect(transformed.brushError == nil)
        maskWindow.orderOut(nil)
    }
}
