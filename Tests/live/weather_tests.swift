import Foundation

var done = false
var failures = 0
func check(_ l: String, _ p: Bool, _ d: String = "") {
    print("\(p ? "PASS" : "FAIL")  \(l)\(d.isEmpty ? "" : "  [\(d)]")"); if !p { failures += 1 }
}

print("=== WMO code mapping ===")
check("0 -> Clear sky", Weather.describe(0) == "Clear sky")
check("61 -> Rain", Weather.describe(61) == "Rain")
check("95 -> Thunderstorm", Weather.describe(95) == "Thunderstorm")
check("unknown code is handled", Weather.describe(1234) == "Conditions unknown")

// Fixed coordinates so this test never needs Location Services.
Prefs.manualLatitude = 51.507
Prefs.manualLongitude = -0.128
Prefs.registerDefaults()

print("\n=== live Open-Meteo fetch (fixed coords) ===")
let start = Date()
Weather.shared.current { result in
    switch result {
    case .success(let summary):
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        print("  \(summary)   [\(ms) ms]")
        check("summary has a temperature and a condition",
              summary.contains("°") && summary.contains("·"), summary)
    case .failure(let error):
        check("fetch succeeded", false, error.localizedDescription)
    }
    done = true
}
while !done && Date().timeIntervalSince(start) < 15 {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
}
check("completed before timeout", done)
// Leave no manual location behind.
Prefs.manualLatitude = nil
Prefs.manualLongitude = nil
print("\n\(failures == 0 ? "ALL WEATHER TESTS PASSED" : "\(failures) FAILURE(S)")")
exit(failures == 0 ? 0 : 1)
