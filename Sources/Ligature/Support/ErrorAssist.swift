import Foundation
import FoundationModels
import LigatureCore

/// Suggests fixes for compile errors with Apple's on-device language model: the error and a few lines around
/// it go to the model on this Mac, a corrected version of those lines comes back. Nothing leaves the Mac, and
/// it works offline.
@MainActor
enum ErrorAssist {
    enum Availability: Equatable { case ready, unavailable(String) }

    static var availability: Availability {
        switch SystemLanguageModel.default.availability {
        case .available: return .ready
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .unavailable("This Mac can't run Apple Intelligence, which Suggest Fix uses.")
            case .appleIntelligenceNotEnabled: return .unavailable("Turn on Apple Intelligence in System Settings › Apple Intelligence & Siri to use Suggest Fix.")
            case .modelNotReady: return .unavailable("Apple Intelligence is still getting ready (the model may be downloading). Try again in a few minutes.")
            @unknown default: return .unavailable("Apple Intelligence isn't available right now.")
            }
        }
    }

    struct Suggestion: Equatable {
        var explanation: String
        /// 1-based lines the fix replaces, and their text before and after.
        var startLine: Int
        var endLine: Int
        var original: String
        var fixed: String
    }

    enum Failure: LocalizedError {
        case noLine, unreadable, noChange
        var errorDescription: String? {
            switch self {
            case .noLine: "TeX didn't say which line this error is on, so there's nothing to fix automatically."
            case .unreadable: "The model's answer didn't come back in a usable form. Try again."
            case .noChange: "The model didn't find a change to make here. The cause may be earlier in the file."
            }
        }
    }

    static let instructions = """
    You fix LaTeX compile errors. You are given the error and some numbered lines of the source.
    Find the smallest change that fixes the error. Do not reformat, merge or reorder lines.
    Only use packages that are already loaded unless the error says a command is undefined.
    Answer in exactly this format and nothing else:
    EXPLANATION: one or two plain-English sentences about what is wrong
    CHANGES:
    <line number>| <the complete corrected line>
    END
    List only the lines you change, one per line, each with its original line number. Usually only one line needs to change.

    Example 1
    Error on line 3: Missing $ inserted.
    Lines:
    2| We measure it.
    3| The value x_1 is small.
    Answer:
    EXPLANATION: x_1 is maths, so it has to be inside $…$.
    CHANGES:
    3| The value $x_1$ is small.
    END

    Example 2
    Error on line 8: Undefined control sequence.
    TeX showed: l.8 This is \\textbff
    Lines:
    8| This is \\textbff{very} important.
    Answer:
    EXPLANATION: \\textbff is a typo for \\textbf.
    CHANGES:
    8| This is \\textbf{very} important.
    END

    Example 3
    Error on line 6: Extra }, or forgotten $.
    Lines:
    6| See \\emph{this}} result.
    7| Next line.
    Answer:
    EXPLANATION: There is one closing brace too many after \\emph{this}.
    CHANGES:
    6| See \\emph{this} result.
    END
    """

    /// Asks for a fix to `issue` in `text` (the file's current contents).
    /// `varied`: sample instead of taking the single most likely answer (for "Try Again").
    static func suggest(for issue: CompileIssue, in text: String, packages: Set<String>, varied: Bool = false) async throws -> Suggestion {
        guard let line = issue.line else { throw Failure.noLine }
        let lines = text.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count else { throw Failure.noLine }
        let start = max(1, line - 5), end = min(lines.count, line + 3)
        let excerpt = (start...end).map { "\($0)| \(lines[$0 - 1])" }.joined(separator: "\n")
        var prompt = "Error on line \(line): \(issue.message)\n"
        if let ctx = issue.context { prompt += "TeX showed: \(ctx)\n" }
        if let advice = ErrorAdvisor.advise(issue) { prompt += "Hint: \(advice.title)\n" }
        if !packages.isEmpty { prompt += "Packages loaded: \(packages.sorted().joined(separator: ", "))\n" }
        prompt += "Lines:\n\(excerpt)"

        let session = LanguageModelSession(instructions: instructions)
        // Greedy decoding first (the same error gets the same, most likely fix); retries explore alternatives.
        let options = varied ? GenerationOptions(temperature: 0.8) : GenerationOptions(samplingMode: .greedy)
        let answer = try await session.respond(to: prompt, options: options).content
        guard let parsed = parse(answer) else { throw Failure.unreadable }
        // Apply only real changes to lines that were shown.
        var fixedLines = Array(lines[(start - 1)...(end - 1)])
        var changed = false
        for (n, newText) in parsed.changes where n >= start && n <= end {
            if fixedLines[n - start] != newText { fixedLines[n - start] = newText; changed = true }
        }
        guard changed else { throw Failure.noChange }
        // Trim unchanged lines from both ends so the diff shows just the fix with a little context.
        var a = start, b = end
        let original = Array(lines[(start - 1)...(end - 1)])
        while a < b, original[a - start] == fixedLines[a - start], a < line - 1 { a += 1 }
        while b > a, original[b - start] == fixedLines[b - start], b > line + 1 { b -= 1 }
        return Suggestion(explanation: parsed.explanation, startLine: a, endLine: b,
                          original: original[(a - start)...(b - start)].joined(separator: "\n"),
                          fixed: fixedLines[(a - start)...(b - start)].joined(separator: "\n"))
    }

    /// Reads "EXPLANATION: … CHANGES: 12| corrected line … END".
    static func parse(_ answer: String) -> (explanation: String, changes: [(Int, String)])? {
        guard let mark = answer.range(of: "CHANGES:") else { return nil }
        var explanation = String(answer[..<mark.lowerBound])
        if let e = explanation.range(of: "EXPLANATION:") { explanation = String(explanation[e.upperBound...]) }
        // Drop self-introductions ("I am a model that…").
        explanation = explanation.components(separatedBy: ". ").filter { !$0.hasPrefix("I am ") && !$0.hasPrefix("As an ") }.joined(separator: ". ")
        var changes: [(Int, String)] = []
        let re = try! NSRegularExpression(pattern: #"^\s*(\d+)\s*\|\s?(.*)$"#)
        for raw in answer[mark.upperBound...].components(separatedBy: "\n") {
            if raw.trimmingCharacters(in: .whitespaces) == "END" { break }
            let ns = raw as NSString
            guard let m = re.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)), let n = Int(ns.substring(with: m.range(at: 1))) else { continue }
            changes.append((n, ns.substring(with: m.range(at: 2))))
        }
        guard !changes.isEmpty else { return nil }
        let exp = explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        return (exp.isEmpty ? "Here's a corrected version of the line." : exp, changes)
    }
}
