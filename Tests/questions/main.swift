import Foundation

var failures = 0
func check(_ l: String, _ p: Bool, _ d: String = "") {
    print("\(p ? "PASS" : "FAIL")  \(l)\(d.isEmpty ? "" : "  [\(d)]")"); if !p { failures += 1 }
}

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let macros = try! JSONDecoder().decode(
    [Macro].self, from: try! Data(contentsOf: here.appendingPathComponent("macros.json")))
_ = AppIndex.shared.refresh()

print("=== recognised as questions ===")
for said in ["how are you", "jarvis how are you", "what is the capital of france",
             "who won the world series", "tell me a joke", "is it going to rain tomorrow",
             "can you explain gravity", "why is the sky blue", "how do i boil an egg",
             "if i leave now will i be late", "are you there", "when did the war end",
             "where is iceland", "whats a good name for a cat"] {
    check("\"\(said)\"", Questions.looksLikeQuestion(said))
}

print("\n=== not questions ===")
for said in ["open chrome", "start up the craft", "wake up daddys home",
             "remind me to buy milk", "open new tab on work", "launch prism",
             "what", "how", "", "netflix"] {
    check("\"\(said)\"", !Questions.looksLikeQuestion(said))
}

print("\n=== commands win over the model ===")
// These look like questions but are real commands, so they must stay on the
// instant path and never reach Apple Intelligence.
for (said, expect) in [("whats the weather", "Weather"),
                       ("tell me the weather", "Weather"),
                       ("what's it like outside", "Weather"),
                       ("can you open chrome", "Chrome")] {
    let r = Resolver.resolveFast(transcript: said, macros: macros)
    check("\"\(said)\" -> \(expect) command", r?.macro.name == expect, r?.macro.name ?? "nil")
}

print("\n=== these have no command, so they get answered ===")
for said in ["how are you", "what is the capital of france", "tell me a joke",
             "what time is it"] {
    let r = Resolver.resolveFast(transcript: said, macros: macros)
    check("\"\(said)\" is not a command but is a question",
          r == nil && Questions.looksLikeQuestion(said),
          "command=\(r?.macro.name ?? "none")")
}

print("\n=== clock questions are answered from the clock ===")
// The model has no clock and will invent a plausible wrong time.
for q in ["what time is it", "jarvis what time is it", "whats the time"] {
    let a = Questions.localAnswer(for: q)
    check("\"\(q)\" answered locally", a != nil && a!.contains(":"), a ?? "nil")
}
for q in ["what day is it", "whats todays date"] {
    check("\"\(q)\" answered locally", Questions.localAnswer(for: q) != nil)
}
for q in ["how are you", "why is the sky blue", "open chrome"] {
    check("\"\(q)\" has no local answer", Questions.localAnswer(for: q) == nil)
}

print("\n=== spoken answers are trimmed for the ear ===")
check("strips a stage direction entirely",
      Intelligence.sanitizeAnswer("I'm at 100%, sir. *smirks* How may I help?")?
        .contains("smirk") == false)
check("keeps the text inside markdown bold",
      Intelligence.sanitizeAnswer("**Paris**, sir.") == "Paris, sir.")
check("holds to two sentences",
      (Intelligence.sanitizeAnswer("One two three four five. Six seven eight. Nine ten. Eleven.")?
        .contains("Nine")) == false)
check("rejects a wall of text",
      Intelligence.sanitizeAnswer(String(repeating: "word ", count: 80)) == nil)
check("rejects empty", Intelligence.sanitizeAnswer("   ") == nil)

print("\n=== being spoken to, not commanded ===")
for greeting in ["hello", "hi", "hey", "yo", "sup", "help", "help me",
                 "whats up", "what's up", "how are you", "hows it going",
                 "good morning", "thanks", "thank you", "you there",
                 "hello jarvis", "jarvis hello", "jarvis, how are you?",
                 "jarvis", "hey jarvis", "morning"] {
    check("\"\(greeting)\" reaches the model", Questions.looksLikeQuestion(greeting))
}

print("\n=== a greeting on the front of a command is still a command ===")
// Whole-sentence matching is what keeps these out of the model's hands.
for spoken in ["hey open chrome", "hello open gmail", "hi launch claude",
               "morning open youtube", "thanks for opening chrome now open gmail"] {
    check("\"\(spoken)\" is not treated as small talk",
          !Questions.looksLikeQuestion(spoken))
}

print("\n=== help me ===")
check("\"help me with my homework\"", Questions.looksLikeQuestion("help me with my homework"))
check("\"jarvis help me\"", Questions.looksLikeQuestion("jarvis help me"))
check("\"i need help\"", Questions.looksLikeQuestion("i need help"))
check("\"can you help me\"", Questions.looksLikeQuestion("can you help me"))

print("\n=== asking for help with something, not just for help ===")
// "help me" has to carry a whole request the way "what" does, not just stand
// alone as a cry for help.
for said in ["help me think of an idea for a science project",
             "help me think of an idea for my history essay",
             "help me come up with a name for my dog",
             "help me decide what to have for dinner",
             "help me pick a colour for my room",
             "jarvis help me think of an idea for a gift",
             "help me out here"] {
    let resolved = Resolver.resolveFast(transcript: said, macros: macros)
    check("\"\(said)\"", resolved == nil && Questions.looksLikeQuestion(said),
          resolved?.macro.name ?? "-> model")
}

print("\n=== goodnight still puts the Mac to sleep ===")
// Sleep is resolved before questions are ever consulted, and "good night" is
// deliberately not in the greeting set.
for phrase in ["good night", "goodnight", "night night", "go to sleep",
               "power down", "jarvis good night"] {
    let resolved = Resolver.resolveFast(transcript: phrase, macros: macros)
    check("\"\(phrase)\" -> Sleep", resolved?.macro.kind == .sleep,
          resolved?.macro.name ?? "nothing")
}
check("\"good night\" is not in the greeting set",
      !Questions.greetings.contains("good night") && !Questions.greetings.contains("goodnight"))

print("\n=== still not everything is small talk ===")
for spoken in ["um", "uh huh okay", "no thanks", "so anyway I was telling him",
               "open chrome", "start up the craft", "remind me to call mum"] {
    let resolved = Resolver.resolveFast(transcript: spoken, macros: macros)
    let asked = resolved == nil && Questions.looksLikeQuestion(spoken)
    check("\"\(spoken)\" doesn't get sent off as chatter", !asked || resolved != nil,
          resolved?.macro.name ?? (asked ? "SENT TO MODEL" : "nothing"))
}

print("\n=== a long answer is trimmed, not thrown away ===")
// This used to come back nil, and you'd hear "I haven't an answer for that"
// instead of the answer the model had already produced.
let three = "A solar-powered greenhouse would serve nicely, sir. "
    + "You could measure how panel angle changes the yield over a fortnight. "
    + "I would suggest starting with three angles and a control group indoors."
let trimmed = Intelligence.sanitizeAnswer(three)
check("a three-sentence answer survives", trimmed != nil, trimmed ?? "nil")
check("trimmed down to something speakable",
      trimmed.map { Intelligence.fitsAloud($0) } ?? false,
      "\(trimmed?.split(separator: " ").count ?? 0) words")
check("it keeps the answer, not the tail",
      trimmed?.hasPrefix("A solar-powered greenhouse") ?? false)

let twoLong = "The Industrial Revolution reshaped global trade in ways that are still "
    + "visible in shipping routes and tariffs today, which makes it a rich subject. "
    + "You might follow a single commodity, cotton say, from field to mill to market."
check("two long sentences still get cut to one",
      Intelligence.sanitizeAnswer(twoLong).map { Intelligence.fitsAloud($0) } ?? false)

let blob = String(repeating: "rambling ", count: 80)
check("an unpunctuated wall of text is still refused",
      Intelligence.sanitizeAnswer(blob) == nil)
check("a short answer is untouched",
      Intelligence.sanitizeAnswer("Paris, sir.") == "Paris, sir.")

print("\n=== the model is told to hand over the thing itself ===")
for said in ["help me think of an idea for a science project",
             "help me come up with a name for my dog",
             "i need help with dinner", "any ideas for a gift",
             "suggest a film", "what should i have for dinner",
             "recommend a book", "pick a colour for me"] {
    check("\"\(said)\" is framed as a request", !Intelligence.framing(for: said).isEmpty)
}
for said in ["what is the capital of france", "hello", "what time is it",
             "how are you", "why is the sky blue", "is it going to rain"] {
    check("\"\(said)\" is left alone", Intelligence.framing(for: said).isEmpty)
}

print("\n=== the fast path stays fast ===")
// The question check only runs after the command resolver returns nothing, so
// opening an app must not pay for it.
func timeIt(_ label: String, _ n: Int, _ body: () -> Void) -> Double {
    let start = Date()
    for _ in 0..<n { body() }
    let micros = Date().timeIntervalSince(start) / Double(n) * 1_000_000
    print(String(format: "   %@: %.1f µs", label, micros))
    return micros
}
let resolveTime = timeIt("resolveFast(\"open chrome\")", 2000) {
    _ = Resolver.resolveFast(transcript: "open chrome", macros: macros)
}
let questionTime = timeIt("looksLikeQuestion(\"open chrome\")", 2000) {
    _ = Questions.looksLikeQuestion("open chrome")
}
check("question check is a rounding error next to resolving",
      questionTime < resolveTime * 0.25,
      String(format: "%.1f µs vs %.1f µs", questionTime, resolveTime))
check("resolving a command stays well under a millisecond",
      resolveTime < 1000, String(format: "%.1f µs", resolveTime))

print("\n\(failures == 0 ? "ALL QUESTION TESTS PASSED" : "\(failures) FAILURE(S)")")
exit(failures == 0 ? 0 : 1)
