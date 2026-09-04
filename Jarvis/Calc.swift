import Foundation

/// Sums and conversions, worked out rather than asked about.
///
/// This exists for the same reason the clock does. Asked "what's fifteen
/// percent of two hundred and forty", a language model produces a confident,
/// fluent, frequently wrong number — and unlike a wrong opinion, a wrong
/// number is one you act on. Anything with an exact answer gets one here, and
/// only what genuinely needs judgement reaches the model.
///
/// The evaluator is hand-written on purpose. `NSExpression(format:)` would be
/// four lines, but it raises an Objective-C exception on malformed input —
/// which Swift cannot catch, so "what's five plus" would take the whole app
/// down. This parser returns nil instead, and nil simply falls through to the
/// model like any other sentence it couldn't place.
enum Calc {

    // MARK: - Reading a sum out of a sentence

    /// Spoken operators, longest first so "divided by" beats "by".
    private static let operatorWords: [(String, String)] = [
        ("multiplied by", "*"), ("divided by", "/"), ("to the power of", "^"),
        ("plus", "+"), ("minus", "-"), ("times", "*"), ("over", "/"),
        ("add", "+"), ("subtract", "-"), ("x", "*"),
    ]

    /// Number words, so "what's twelve times eight" works spoken as well as
    /// dictated. Only the ones a recogniser actually returns as words — it
    /// writes anything above twenty as digits.
    static let numberWords: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
        "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
        "seventy": 70, "eighty": 80, "ninety": 90, "hundred": 100,
        // Deliberately no "half" or "quarter": they are fractions of something
        // rather than counts, and "half of twenty" needs a reading of "of" that
        // this grammar hasn't got. It falls through to the model, which is fine
        // at it.
    ]

    /// Openers that mean "compute this", stripped before parsing.
    private static let openers = [
        "whats", "what is", "what", "calculate", "compute", "work out",
        "tell me", "how much is", "how much", "figure out", "evaluate",
    ]

    /// Lowercased and tidied, but with the characters arithmetic is made of
    /// left alone.
    ///
    /// `PhraseMatcher.normalize` cannot be used here and it is worth saying
    /// why: it keeps letters and digits and turns everything else into a space,
    /// so "3.5 plus 1.25" arrives as "3 5 plus 1 25" and evaluates to a
    /// hundred and sixty. Brackets vanish the same way. Everything else in the
    /// app wants that fold; a sum is the one thing that doesn't.
    static func clean(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var pendingSpace = false
        for character in text.lowercased() {
            if character.isLetter || character.isNumber || ".%()+-*/^".contains(character) {
                if pendingSpace { out.append(" "); pendingSpace = false }
                out.append(character)
            } else if character == "'" || character == "\u{2019}" || character == "," {
                // Apostrophes must not split "what's"; commas must not split
                // "1,000" — dropping both outright is what keeps each whole.
                continue
            } else if !out.isEmpty {
                pendingSpace = true
            }
        }
        return out
    }

    /// The answer to a spoken sum, or nil if it isn't one.
    ///
    /// Returns nil freely. This runs on the question path, where nil just means
    /// "not a sum" and the sentence carries on to the model — so it can afford
    /// to refuse anything it isn't certain about rather than guess.
    static func answer(for question: String) -> String? {
        let text = clean(question)
        guard !text.isEmpty else { return nil }

        if let percent = percentAnswer(text) { return percent }

        var body = text
        for opener in openers.sorted(by: { $0.count > $1.count })
        where body == opener || body.hasPrefix(opener + " ") {
            body = String(body.dropFirst(opener.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        // A trailing "equal"/"equals" is how people finish a dictated sum.
        for tail in [" equals", " equal", " is"] where body.hasSuffix(tail) {
            body = String(body.dropLast(tail.count))
        }
        guard let value = evaluate(body) else { return nil }
        return "\(format(value)), sir."
    }

    /// "15 percent of 240", "20 percent off 50", "add 8 percent to 25".
    ///
    /// Percentages get their own pass because "of" is not multiplication
    /// anywhere else, and because "off" — a discount — is the one people
    /// actually want and the one a plain evaluator gets backwards.
    private static func percentAnswer(_ text: String) -> String? {
        guard let regex = percentRegex,
              let match = regex.firstMatch(in: text, options: [],
                                           range: NSRange(text.startIndex..., in: text)),
              let rateRange = Range(match.range(at: 1), in: text),
              let wordRange = Range(match.range(at: 2), in: text),
              let baseRange = Range(match.range(at: 3), in: text),
              let rate = Double(text[rateRange]), let base = Double(text[baseRange])
        else { return nil }

        let portion = base * rate / 100
        switch text[wordRange] {
        case "of":  return "\(format(portion)), sir."
        case "off": return "\(format(base - portion)), sir. A saving of \(format(portion))."
        default:    return "\(format(base + portion)), sir."   // "on" — a markup
        }
    }

    private static let percentRegex = try? NSRegularExpression(
        pattern: #"([0-9]+(?:\.[0-9]+)?)\s*(?:percent|%)\s*(of|off|on)\s+([0-9]+(?:\.[0-9]+)?)"#)

    // MARK: - Evaluating

    /// Turns a normalized phrase into a value, or nil if it isn't arithmetic.
    static func evaluate(_ phrase: String) -> Double? {
        var text = phrase

        // Spoken operators become symbols. Longest first, and word-bounded, so
        // "x" as multiplication can't eat the x of "max".
        for (word, symbol) in operatorWords.sorted(by: { $0.0.count > $1.0.count }) {
            text = replaceWords(word, with: " \(symbol) ", in: text)
        }
        for (word, value) in numberWords where value > 0 || word == "zero" {
            text = replaceWords(word, with: " \(value) ", in: text)
        }

        // Anything outside the grammar means this was never a sum.
        guard text.allSatisfy({ c in
            c.isNumber || c == "." || c == " " || "+-*/^()".contains(c)
        }) else { return nil }
        // At least one operator, or it's a bare number and there is nothing to
        // work out — "what's 7" is not a sum.
        guard text.contains(where: { "+-*/^".contains($0) }),
              text.contains(where: { $0.isNumber })
        else { return nil }

        // Spaces are kept rather than stripped, and that is load-bearing: with
        // them gone "12 8 plus 3" collapses into "128+3" and answers a question
        // nobody asked. The parser skips them *between* tokens and refuses to
        // read a number across one, so two numbers with no operator between
        // them fail the parse instead of being silently glued together.
        var parser = Parser(Array(text))
        guard let value = parser.expression(), parser.atEnd, value.isFinite else { return nil }
        return value
    }

    /// Replaces `word` only where it stands alone, so "one" doesn't rewrite
    /// the middle of "money".
    private static func replaceWords(_ word: String, with replacement: String,
                                     in text: String) -> String {
        var out: [String] = []
        var changed = false
        // The spoken operators can be two words ("divided by"), so this walks
        // the token stream rather than mapping words one at a time.
        let needle = word.split(separator: " ").map(String.init)
        let tokens = text.split(separator: " ").map(String.init)
        var index = 0
        while index < tokens.count {
            if index + needle.count <= tokens.count,
               Array(tokens[index..<(index + needle.count)]) == needle {
                out.append(replacement.trimmingCharacters(in: .whitespaces))
                index += needle.count
                changed = true
            } else {
                out.append(tokens[index])
                index += 1
            }
        }
        return changed ? out.joined(separator: " ") : text
    }

    /// Recursive descent over a whitespace-free character array.
    ///
    /// Every step can fail by returning nil, and a nil anywhere aborts the
    /// whole parse — there is no error state to get wrong and no exception to
    /// escape. Precedence is the ordinary one: `^` binds tightest and is
    /// right-associative, then `*` and `/`, then `+` and `-`.
    private struct Parser {
        let characters: [Character]
        var position = 0

        init(_ characters: [Character]) { self.characters = characters }

        /// Whitespace only ever separates tokens, so every read steps over it
        /// first — except the digit walk in `primary`, which must not, or two
        /// numbers side by side would read as one.
        private mutating func skipSpaces() {
            while position < characters.count, characters[position] == " " { position += 1 }
        }

        var atEnd: Bool {
            var index = position
            while index < characters.count, characters[index] == " " { index += 1 }
            return index >= characters.count
        }

        private mutating func peek() -> Character? {
            skipSpaces()
            return position < characters.count ? characters[position] : nil
        }

        mutating func expression() -> Double? {
            guard var left = term() else { return nil }
            while let c = peek(), c == "+" || c == "-" {
                position += 1
                guard let right = term() else { return nil }
                left = c == "+" ? left + right : left - right
            }
            return left
        }

        private mutating func term() -> Double? {
            guard var left = power() else { return nil }
            while let c = peek(), c == "*" || c == "/" {
                position += 1
                guard let right = power() else { return nil }
                // Dividing by zero yields infinity, which `evaluate` rejects —
                // better a sentence that falls through to the model than a
                // spoken "inf".
                left = c == "*" ? left * right : left / right
            }
            return left
        }

        private mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            guard peek() == "^" else { return base }
            position += 1
            guard let exponent = power() else { return nil }
            return pow(base, exponent)
        }

        private mutating func unary() -> Double? {
            if let c = peek(), c == "-" || c == "+" {
                position += 1
                guard let value = unary() else { return nil }
                return c == "-" ? -value : value
            }
            return primary()
        }

        private mutating func primary() -> Double? {
            if peek() == "(" {
                position += 1
                guard let value = expression(), peek() == ")" else { return nil }
                position += 1
                return value
            }
            skipSpaces()
            var digits = ""
            var sawDot = false
            // No `peek` here: a space ends the number rather than being stepped
            // over, which is what keeps "12 8" from becoming 128.
            while position < characters.count {
                let c = characters[position]
                guard c.isNumber || (c == "." && !sawDot) else { break }
                if c == "." { sawDot = true }
                digits.append(c)
                position += 1
            }
            // A sentence's full stop can end up glued to its last number.
            if digits.hasSuffix(".") { digits.removeLast() }
            guard !digits.isEmpty else { return nil }
            return Double(digits)
        }
    }

    /// Numbers as you'd say them: no trailing zeros, and no fifteen decimal
    /// places of binary floating point either.
    static func format(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < 1e15 {
            return String(Int(value))
        }
        let rounded = (value * 1_000_000).rounded() / 1_000_000
        var text = String(format: "%.6f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    // MARK: - Converting between units

    /// The units worth knowing, keyed by every word a recogniser might return.
    ///
    /// Deliberately a flat table rather than `Measurement`'s type hierarchy:
    /// the two sides of a spoken conversion arrive as bare words with no clue
    /// which dimension they belong to, so the lookup has to say what kind of
    /// thing each one is before anything can be converted. Values are in the
    /// dimension's base unit — metres, grams, litres, seconds.
    private struct Unit {
        let dimension: String
        let toBase: Double
        /// Singular and plural, for the spoken answer.
        let name: String
    }

    private static let units: [String: Unit] = {
        var table: [String: Unit] = [:]
        func add(_ names: [String], _ dimension: String, _ toBase: Double, _ display: String) {
            for name in names { table[name] = Unit(dimension: dimension, toBase: toBase, name: display) }
        }
        add(["mm", "millimeter", "millimeters", "millimetre", "millimetres"], "length", 0.001, "millimetres")
        add(["cm", "centimeter", "centimeters", "centimetre", "centimetres"], "length", 0.01, "centimetres")
        add(["m", "meter", "meters", "metre", "metres"], "length", 1, "metres")
        add(["km", "kilometer", "kilometers", "kilometre", "kilometres"], "length", 1000, "kilometres")
        add(["in", "inch", "inches"], "length", 0.0254, "inches")
        add(["ft", "foot", "feet"], "length", 0.3048, "feet")
        add(["yd", "yard", "yards"], "length", 0.9144, "yards")
        add(["mi", "mile", "miles"], "length", 1609.344, "miles")

        add(["mg", "milligram", "milligrams"], "mass", 0.001, "milligrams")
        add(["g", "gram", "grams"], "mass", 1, "grams")
        add(["kg", "kilogram", "kilograms", "kilo", "kilos"], "mass", 1000, "kilograms")
        add(["oz", "ounce", "ounces"], "mass", 28.349523125, "ounces")
        add(["lb", "lbs", "pound", "pounds"], "mass", 453.59237, "pounds")
        add(["stone", "stones"], "mass", 6350.29318, "stone")

        add(["ml", "milliliter", "milliliters", "millilitre", "millilitres"], "volume", 0.001, "millilitres")
        add(["l", "liter", "liters", "litre", "litres"], "volume", 1, "litres")
        add(["cup", "cups"], "volume", 0.2365882365, "cups")
        add(["pint", "pints"], "volume", 0.473176473, "pints")
        add(["quart", "quarts"], "volume", 0.946352946, "quarts")
        add(["gallon", "gallons"], "volume", 3.785411784, "gallons")

        add(["second", "seconds", "sec", "secs"], "time", 1, "seconds")
        add(["minute", "minutes", "min", "mins"], "time", 60, "minutes")
        add(["hour", "hours", "hr", "hrs"], "time", 3600, "hours")
        add(["day", "days"], "time", 86400, "days")
        add(["week", "weeks"], "time", 604800, "weeks")
        return table
    }()

    /// Temperature is affine rather than scaled, so it can't live in the table
    /// above — a conversion needs an offset as well as a factor.
    private static let temperatures: Set<String> = [
        "c", "celsius", "centigrade", "f", "fahrenheit", "k", "kelvin",
    ]

    private static func toCelsius(_ value: Double, from unit: String) -> Double? {
        switch unit {
        case "c", "celsius", "centigrade": return value
        case "f", "fahrenheit": return (value - 32) * 5 / 9
        case "k", "kelvin": return value - 273.15
        default: return nil
        }
    }

    private static func fromCelsius(_ value: Double, to unit: String) -> (Double, String)? {
        switch unit {
        case "c", "celsius", "centigrade": return (value, "degrees Celsius")
        case "f", "fahrenheit": return (value * 9 / 5 + 32, "degrees Fahrenheit")
        case "k", "kelvin": return (value + 273.15, "Kelvin")
        default: return nil
        }
    }

    private static let conversionRegex = try? NSRegularExpression(
        pattern: #"(-?[0-9]+(?:\.[0-9]+)?)\s*([a-z]+)\s+(?:into|in|to|as)\s+([a-z]+)"#)
    /// "how many kilometres in five miles" — the units the other way round.
    ///
    /// The amount is optional because the commonest form of this question
    /// doesn't have one: "how many ounces in a pound" is asking about a single
    /// pound, and requiring a digit there answered nothing.
    private static let howManyRegex = try? NSRegularExpression(
        pattern: #"how many ([a-z]+)\s+(?:are\s+)?(?:in|is|are)\s+(?:(-?[0-9]+(?:\.[0-9]+)?)\s*|an\s+|a\s+|one\s+)([a-z]+)"#)

    /// "convert 20 celsius to fahrenheit", "how many km in 5 miles".
    static func conversion(for question: String) -> String? {
        let text = clean(question)
        guard !text.isEmpty else { return nil }
        let range = NSRange(text.startIndex..., in: text)

        if let regex = howManyRegex,
           let match = regex.firstMatch(in: text, options: [], range: range),
           let toRange = Range(match.range(at: 1), in: text),
           let fromRange = Range(match.range(at: 3), in: text) {
            // An absent amount is one of the thing, which is exactly what
            // "how many ounces in a pound" means.
            let amount = Range(match.range(at: 2), in: text)
                .flatMap { Double(text[$0]) } ?? 1
            return convert(amount, from: String(text[fromRange]), to: String(text[toRange]))
        }
        guard let regex = conversionRegex,
              let match = regex.firstMatch(in: text, options: [], range: range),
              let amountRange = Range(match.range(at: 1), in: text),
              let fromRange = Range(match.range(at: 2), in: text),
              let toRange = Range(match.range(at: 3), in: text),
              let amount = Double(text[amountRange])
        else { return nil }
        return convert(amount, from: String(text[fromRange]), to: String(text[toRange]))
    }

    static func convert(_ amount: Double, from: String, to: String) -> String? {
        if temperatures.contains(from), temperatures.contains(to) {
            guard let celsius = toCelsius(amount, from: from),
                  let (value, name) = fromCelsius(celsius, to: to)
            else { return nil }
            return "\(format((value * 10).rounded() / 10)) \(name), sir."
        }
        guard let source = units[from], let target = units[to],
              source.dimension == target.dimension, target.toBase != 0
        else { return nil }
        let value = amount * source.toBase / target.toBase
        return "\(format((value * 10000).rounded() / 10000)) \(target.name), sir."
    }
}
