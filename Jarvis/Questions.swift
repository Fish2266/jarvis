import Foundation

/// Spots a question so it can be answered instead of matched to a command.
///
/// Pure string work — a few microseconds — so it costs the app-opening path
/// nothing. It is also only consulted *after* the command resolver comes back
/// empty, which is why "what's the weather" still runs your Weather command
/// rather than going to the model.
enum Questions {

    /// First words that make something a question rather than an instruction.
    static let starters: Set<String> = [
        "what", "whats", "when", "whens", "where", "wheres", "why", "whys",
        "who", "whos", "whom", "whose", "how", "hows", "which",
        "is", "are", "was", "were", "am", "do", "does", "did",
        "can", "could", "should", "would", "will", "shall",
        "has", "have", "had", "if", "tell", "explain", "define",
    ]

    /// Openers that are questions even though the first word alone isn't.
    static let phrases = [
        "tell me", "do you", "can you", "could you", "what about", "how about",
        "give me", "i wonder", "any idea", "whats up", "help me", "i need help",
        "i need", "i want to know", "talk to me", "walk me through",
        "remind me what", "remind me how", "remind me who",
    ]

    /// Things you say *to* someone rather than ask *of* them.
    ///
    /// Matched against the whole sentence rather than as a prefix, and that
    /// matters: "hey" on its own is a greeting, but "hey, open chrome" is a
    /// command with a greeting bolted on the front, and a prefix match would
    /// send it to the model instead of opening Chrome. Being whole-sentence is
    /// also what lets these be one word, where the usual two-word floor applies.
    ///
    /// Deliberately absent: "good night" and its variants, which are how you put
    /// the Mac to sleep.
    static let greetings: Set<String> = [
        "hello", "hi", "hey", "yo", "howdy", "hiya", "greetings", "sup", "help",
        "hey there", "hi there", "hello there", "hello jarvis", "hi jarvis",
        "you there", "you awake", "you up", "are you there", "are you awake",
        "whats up", "whats new", "whats good", "what's happening", "whats happening",
        "how are you", "how are you doing", "how you doing", "hows it going",
        "how goes it", "how are things", "how have you been",
        "good morning", "good afternoon", "good evening", "morning", "afternoon",
        "evening", "thank you", "thanks", "thanks jarvis", "thank you jarvis",
        "cheers", "nice work", "good job", "well done", "youre the best",
    ]

    /// Questions with an exact answer the Mac already knows. The model has no
    /// clock and will invent a plausible wrong time if asked.
    static func localAnswer(for transcript: String) -> String? {
        let text = PhraseMatcher.normalize(transcript)
        let now = Date()

        let timeAsks = ["what time is it", "whats the time", "what is the time",
                        "do you have the time", "got the time", "time is it",
                        "whats the time now", "what time is it now"]
        if timeAsks.contains(where: { text.contains($0) }) {
            return "It's \(now.formatted(date: .omitted, time: .shortened)), sir."
        }

        let dateAsks = ["what day is it", "whats the date", "what is the date",
                        "whats todays date", "what is todays date", "what's the day",
                        "what day is today"]
        if dateAsks.contains(where: { text.contains($0) }) {
            return "It's \(now.formatted(date: .complete, time: .omitted)), sir."
        }
        return nil
    }

    static func looksLikeQuestion(_ transcript: String) -> Bool {
        var text = PhraseMatcher.normalize(transcript)
        guard !text.isEmpty else { return false }

        for name in Resolver.assistantNames
        where text == name || text.hasPrefix(name + " ") {
            text = String(text.dropFirst(name.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        // Just the name, nothing after it: you're addressing him, not ordering
        // anything. Worth a "Yes, sir?" rather than silence.
        if text.isEmpty { return true }

        // Whole-sentence, so this runs before the two-word floor below.
        if greetings.contains(text) { return true }

        let words = text.split(separator: " ").map(String.init)
        // One word is never enough to act on — it's still being spoken.
        guard words.count >= 2 else { return false }

        for phrase in phrases where text.hasPrefix(phrase) { return true }
        guard let first = words.first else { return false }
        return starters.contains(first)
    }
}
