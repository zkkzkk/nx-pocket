// Adapted from NX Play (github.com/varyform/nx-native-wrapper, Packages/NXPlayKit/Sources/NXPlayKit/Model/BuildProgress.swift).
// MIT License, Copyright (c) 2026 Oleh Khomei: Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
// documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish,
// distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS",
// WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED.
//
// Changes for NX Pocket: the stages already finished are kept (the pipeline lists them), and ANSI and beat lines are left out (a game pack's build log is short).
import Foundation

/// Where a build is: the stage it is in and how far that stage has come, from the scripts' `--progress json` events (scripts/build_ipa_from_nsp.py and
/// dm/ios/tools/build_pack.py; docs/frontends.md, "Building: the NSP script")
struct BuildProgress: Equatable {
    let stage: Int
    let stages: Int
    let name: String
    let step: String               // the step within the stage ("splitting"), empty when it has none
    let stageFraction: Double?     // the stage's own share done, 0 to 0.99 while it runs, nil when its work can't be counted
    let eta: Double?               // seconds left in the stage, while the script can tell
    var count: String? = nil       // "211,200/304,243 files", "1.9/~5.0 GB"
    let finished: Bool

    var percent: Int? { finished ? 100 : stageFraction.map { Int(($0 * 100).rounded()) } }
    /// The whole run done so far, counting the current stage's share
    var fraction: Double {
        let within = finished ? 1 : stageFraction ?? 0
        return min(1, max(0, (Double(stage - 1) + within) / Double(max(stages, 1))))
    }

    /// "0:42", "1:02:03"
    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// A stage that has ended: its place, name, how long it took and whether it went well
struct FinishedStage: Equatable, Identifiable {
    let k: Int
    let name: String
    let elapsed: Double?
    let ok: Bool
    let summary: String
    var id: Int { k }
}

/// Reads a script's output line by line: its JSON events become the progress and log lines; anything else (a traceback, a tool's own line) is shown as it is.
/// The events are another program's output: every field is read on its own and checked, so a change shows less, never garbage
struct BuildOutputReader {
    private(set) var progress: BuildProgress?
    private(set) var finished: [FinishedStage] = []
    private(set) var problems: [String] = []   // "[RED] " messages: why a build stopped
    private var stage = 0, stages = 0
    private var name = "", step = ""
    private var stageFraction: Double?, eta: Double?, count: String?

    /// The log lines a line of output shows; updates `progress` from an event
    mutating func read(_ line: String) -> [String] {
        guard line.hasPrefix(#"{"ev": "#), let data = line.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let kind = event["ev"] as? String else { return [line] }
        let k = Self.integer(event["k"]) ?? stage
        switch kind {
        case "stage":
            stage = k; stages = Self.integer(event["n"]) ?? stages
            name = Self.text(event["name"]) ?? ""; step = Self.text(event["step"]) ?? ""
            restartStep(); publish(finished: false)
            return ["[\(stage)/\(stages)] \(title) …"]
        case "step":
            step = Self.text(event["step"]) ?? ""
            restartStep(); publish(finished: false)
            return []
        case "progress":
            step = Self.text(event["step"]) ?? step
            stageFraction = Self.number(event["frac"], max: 1)
            eta = Self.number(event["eta"], max: 1e7)
            count = Self.count(done: Self.number(event["done"], max: 1e18), total: Self.number(event["total"], max: 1e18),
                               unit: Self.text(event["unit"]) ?? "", estimate: event["est"] as? Bool ?? false)
            publish(finished: false)
            return []
        case "stage_end":
            let ok = event["ok"] as? Bool ?? true
            let elapsed = Self.number(event["elapsed"], max: 1e7)
            let summary = Self.text(event["summary"]) ?? ""
            let ended = Self.text(event["name"]) ?? name
            finished.removeAll { $0.k == k }
            finished.append(FinishedStage(k: k, name: ended, elapsed: elapsed, ok: ok, summary: summary))
            step = ""; restartStep(); publish(finished: ok)
            return ["\(ok ? "✓" : "✗") [\(k)/\(stages)] \(ended)\(elapsed.map { " (\(BuildProgress.duration($0)))" } ?? "")\(summary.isEmpty ? "" : ": \(summary)")"]
        case "say":
            guard let message = event["msg"] as? String else { return [] }
            if message.hasPrefix("[RED] ") { problems.append(String(message.dropFirst(6))) }
            return message.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        default:
            return []
        }
    }

    private var title: String { step.isEmpty ? name : "\(name) · \(step)" }
    private mutating func restartStep() { stageFraction = nil; eta = nil; count = nil }
    private mutating func publish(finished: Bool) {
        guard stage > 0 else { return }
        progress = BuildProgress(stage: stage, stages: max(stages, stage), name: name, step: step, stageFraction: stageFraction, eta: eta, count: count, finished: finished)
    }

    // MARK: - Checked fields

    static func number(_ value: Any?, max: Double) -> Double? {
        // a JSON true/false is a CFBoolean; `is Bool` would also take the numbers 0 and 1 (stage 1 read as no stage)
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), case let n = value.doubleValue, n.isFinite, n >= 0, n <= max else { return nil }
        return n
    }
    static func integer(_ value: Any?) -> Int? { number(value, max: 10_000).flatMap { $0 == $0.rounded() ? Int($0) : nil } }
    /// Text for one line: no line breaks or control characters, at most 120 characters
    static func text(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let line = String(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) }).trimmingCharacters(in: .whitespaces)
        return line.count > 120 ? String(line.prefix(119)) + "…" : line
    }
    /// The count as the script words it: "1,203/19,592 shaders", "1.9/~5.0 GB"; nil without one
    static func count(done: Double?, total: Double?, unit: String, estimate: Bool) -> String? {
        guard let done else { return nil }
        let tilde = estimate ? "~" : ""
        if unit == "B" {
            let scale = (total ?? done) >= 1_073_741_824 ? ("GB", 1_073_741_824.0) : (total ?? done) >= 1_048_576 ? ("MB", 1_048_576.0) : ("KB", 1024.0)
            let d = String(format: "%.1f", done / scale.1)
            guard let total, total > 0 else { return "\(d) \(scale.0)" }
            return "\(d)/\(tilde)\(String(format: "%.1f", total / scale.1)) \(scale.0)"
        }
        let suffix = unit.isEmpty ? "" : " \(unit)"
        let g = { (v: Double) in Int(v.rounded()).formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US"))) }
        guard let total, total > 0 else { return g(done) + suffix }
        return "\(g(done))/\(tilde)\(g(total))\(suffix)"
    }
}
