import CoreGraphics
import Foundation
import os

/// How long the slow work takes: launching; opening, saving, exporting and duplicating projects; making the canvas's
/// textures. Each stretch is an interval in Instruments' Points of Interest and, once it's done, a line in the console:
/// filter it for ⏱. Work that throws or is cancelled is left out. A stretch timed in steps has an interval for each step
/// and one line for the whole, said by its owner.
nonisolated enum Timing {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "Compositor"
    private static let signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)
    private static let logger = Logger(subsystem: subsystem, category: "Timing")

    /// A stretch begun and not yet ended.
    struct Interval: @unchecked Sendable {
        fileprivate let name: StaticString
        fileprivate let state: OSSignpostIntervalState
        fileprivate let start: ContinuousClock.Instant
    }

    static func begin(_ name: StaticString) -> Interval {
        Interval(name: name, state: signposter.beginInterval(name, id: signposter.makeSignpostID()), start: .now)
    }

    /// Ends `interval`, saying how long it took and, in `detail`, what it was of.
    static func end(_ interval: Interval, _ detail: String = "") {
        signposter.endInterval(interval.name, interval.state, "\(detail, privacy: .public)")
        log(String(describing: interval.name), ContinuousClock.now - interval.start, detail)
    }

    static func measure<T>(_ name: StaticString, _ detail: String = "", _ work: () throws -> T) rethrows -> T {
        let interval = begin(name)
        let result = try work()
        end(interval, detail)
        return result
    }

    /// Times a step of a larger stretch: an interval in Points of Interest with no line of its own. Its time is added
    /// to `total`, whether or not it throws; the stretch's owner decides what to count.
    static func step<T>(_ name: StaticString, adding total: inout Duration, _ work: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        let start = ContinuousClock.now
        defer {
            total += ContinuousClock.now - start
            signposter.endInterval(name, state)
        }
        return try work()
    }

    /// Says a stretch timed in steps took `duration`.
    static func report(_ name: StaticString, took duration: Duration, _ detail: String = "") {
        log(String(describing: name), duration, detail)
    }

    /// The launch has come as far as `step`: says how long that took from the process starting, before any of the app's
    /// own code ran.
    static func launched(to step: String) {
        signposter.emitEvent("Launch", "\(step, privacy: .public)")
        var process = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var query = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&query, u_int(query.count), &process, &size, nil, 0) == 0 else { return }
        let started = process.kp_proc.p_un.__p_starttime
        let seconds = Date.now.timeIntervalSince1970 - (TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000)
        log("Launch", .seconds(seconds), "to \(step), from the process starting")
    }

    private static func log(_ name: String, _ duration: Duration, _ detail: String) {
        let about = detail.isEmpty ? "" : " — " + detail
        logger.notice("⏱ \(name, privacy: .public) \(milliseconds(duration), privacy: .public)\(about, privacy: .public)")
    }

    // MARK: Details

    /// “1 layer”, “8 layers”.
    static func counted(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }

    /// “4.2 MB”.
    static func bytes(_ count: Int) -> String { Int64(count).formatted(.byteCount(style: .file)) }

    /// “12 ms”.
    static func milliseconds(_ duration: Duration) -> String { "\(Int((duration / .milliseconds(1)).rounded())) ms" }

    /// “97.5 MP”.
    static func megapixels(_ pixels: Int) -> String {
        (Double(pixels) / 1_000_000).formatted(.number.precision(.fractionLength(1))) + " MP"
    }
}

extension ProjectSnapshot {
    /// What the project's package holds, for timing its reading and writing: “4032×3024, 8 images and 3 masks, 97.5 MP”.
    nonisolated var timingDetail: String {
        let pixels = (Array(images.values) + Array(masks.values)).reduce(0) { $0 + $1.image.width * $1.image.height }
        let files = Timing.counted(images.count, "image") + (masks.isEmpty ? "" : " and " + Timing.counted(masks.count, "mask"))
        return "\(manifest.width)×\(manifest.height), \(files), \(Timing.megapixels(pixels))"
    }
}
