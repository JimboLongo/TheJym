//
//  GeminiPhasePlanner.swift
//  TheJym
//
//  OPTIONAL: uses Gemini's free tier to plan the next Phase from your logs.
//  If no API key is set (or the call fails), the app silently falls back to
//  ProgressionEngine.planNextPhase — so this is never required.
//
//  Get a free key at https://aistudio.google.com and paste it in Settings.
//

import Foundation

struct GeminiPhasePlanner {
    let apiKey: String

    struct AISlot: Codable {
        var dayLetter: String
        var exerciseName: String
        var targetReps: [Int]
        var startingWeights: [Double]
        var rationale: String
    }

    func planNextPhase(previousPhase: Phase) async throws -> [AISlot] {
        // Build a compact history summary for the prompt.
        var lines: [String] = []
        for letter in previousPhase.distinctTrainingLetters {
            for planned in previousPhase.plan(for: letter) {
                let logs = previousPhase.sessions
                    .flatMap { $0.exerciseLogs }
                    .filter { $0.planKey == planned.planKey }
                    .sorted { ($0.session?.date ?? .distantPast) < ($1.session?.date ?? .distantPast) }
                let history = logs.map { log in
                    let reps = log.sortedSets.map { String($0.reps) }.joined(separator: "/")
                    let wts = log.sortedSets.map { Formatters.trim($0.weight) }.joined(separator: "/")
                    return "\(reps)@\(wts)"
                }.joined(separator: "; ")
                lines.append("Day \(letter) | \(planned.exerciseName) | target \(planned.targetReps.map(String.init).joined(separator: "/")) | logs: \(history)")
            }
        }

        let prompt = """
        You are a strength coach. Based on the athlete's completed training phase below, \
        design the NEXT phase. Keep exercises that progressed, swap or re-scheme stalled \
        ones, and set sensible starting weights (round to 2.5 lb). Sets/reps arrays must \
        match in length with startingWeights.

        Completed phase (split pattern \(previousPhase.splitPattern), \(previousPhase.totalCycles) cycles):
        \(lines.joined(separator: "\n"))

        Respond ONLY with a JSON array, no markdown, of objects with keys:
        dayLetter (string), exerciseName (string), targetReps (int array), \
        startingWeights (number array), rationale (string, one sentence).
        """

        var request = URLRequest(url: URL(string:
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=\(apiKey)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "contents": [["parts": [["text": prompt]]]]
        ])

        let (data, _) = try await URLSession.shared.data(for: request)

        // Extract candidates[0].content.parts[0].text
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = root["candidates"] as? [[String: Any]],
            let content = candidates.first?["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]],
            var text = parts.first?["text"] as? String
        else { throw URLError(.cannotParseResponse) }

        text = text.replacingOccurrences(of: "```json", with: "")
                   .replacingOccurrences(of: "```", with: "")
                   .trimmingCharacters(in: .whitespacesAndNewlines)

        return try JSONDecoder().decode([AISlot].self, from: Data(text.utf8))
    }
}
