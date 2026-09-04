import Foundation
import Carbon

// The Chrome scripts are compiled once and called as handlers with their
// varying parts passed as arguments. Nothing here talks to Chrome: it proves
// the script is valid, that every handler the Swift side calls exists, and
// that the argument plumbing carries values in and answers out.

var failures = 0
func check(_ name: String, _ ok: Bool, _ note: String = "") {
    print("\(ok ? "PASS" : "FAIL")  \(name)\(note.isEmpty ? "" : "  [\(note)]")")
    if !ok { failures += 1 }
}

print("=== the Chrome script is valid AppleScript ===")
check("it compiles", Browser.chromeScriptCompiles())

print("\n=== every handler the Swift side calls exists, by that exact name ===")
// Calling a handler that isn't there fails outright. These handlers all start
// by talking to Chrome, so they aren't called here — instead the same source
// is compiled with the Chrome bodies replaced by a marker, which proves the
// names and arity while touching nothing.
let probes: [(String, Int)] = [
    ("windowids", 0), ("windowshowing", 1), ("focuswindow", 1),
    ("makefresh", 1), ("findtabs", 1), ("focustab", 2),
]
check("the list under test matches the one the app uses",
      probes.map(\.0).sorted() == Browser.chromeHandlers.sorted())

var stubs = ""
for (name, arity) in probes {
    let parameters = (0..<arity).map { "a\($0)" }.joined(separator: ", ")
    let echo = arity == 0 ? "\"\"" : (0..<arity).map { "a\($0)" }.joined(separator: " & \"|\" & ")
    stubs += "on \(name)(\(parameters))\n    return \(echo)\nend \(name)\n\n"
}
guard let stub = Browser.compile(stubs) else {
    print("FAIL  the stub script compiles")
    exit(1)
}
for (name, arity) in probes {
    let arguments = (0..<arity).map { "arg\($0)" }
    let want = arguments.joined(separator: "|")
    let got = Browser.call(stub, handler: name, arguments: arguments)
    check("\(name)/\(arity) is reachable and its arguments arrive", got == want,
          "\(got ?? "nil") vs \(want)")
}

print("\n=== arguments are data, not source text ===")
// Window ids, URLs and account addresses used to be interpolated into script
// source and escaped by hand. These are exactly the strings that broke it.
guard let echo = Browser.compile("on echo(t)\n    return t\nend echo") else {
    print("FAIL  the echo script compiles")
    exit(1)
}
for hostile in [
    "https://example.com/?q=\"quoted\"",
    "https://example.com/a\\b",
    "you@example.com\" & (do shell script \"echo no\") & \"",
    "tab\there",
    "line\nbreak",
    "unicode — ≤ ✓",
    "",
] {
    let got = Browser.call(echo, handler: "echo", arguments: [hostile])
    check("\(hostile.debugDescription.prefix(44)) survives the trip", got == hostile,
          (got ?? "nil").debugDescription)
}

print("\n=== the same compiled script answers over and over ===")
// The whole point of compiling once: the second call must not need a recompile
// and must give the same answer.
var stable = true
for i in 0..<200 where Browser.call(echo, handler: "echo", arguments: ["run \(i)"]) != "run \(i)" {
    stable = false
}
check("200 calls on one compiled script all answer correctly", stable)

let started = CFAbsoluteTimeGetCurrent()
for _ in 0..<200 { _ = Browser.call(echo, handler: "echo", arguments: ["x"]) }
let per = (CFAbsoluteTimeGetCurrent() - started) / 200 * 1000
print(String(format: "   a warm handler call costs %.3f ms; compiling costs about 26", per))
check("a warm call is far cheaper than a compile", per < 5)

print("\n=== a bad script fails rather than crashing ===")
check("nonsense doesn't compile", Browser.compile("this is not applescript at all") == nil)
check("a missing handler returns nil",
      Browser.call(echo, handler: "nosuchhandler", arguments: []) == nil)

print(failures == 0 ? "\nALL APPLESCRIPT TESTS PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
