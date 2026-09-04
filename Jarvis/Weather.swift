import Foundation
import CoreLocation

/// Current conditions from Open-Meteo — no API key, no account.
/// Location comes from CoreLocation, or a manual lat/lon you set in the menu.
final class Weather: NSObject, CLLocationManagerDelegate {

    static let shared = Weather()

    private let manager = CLLocationManager()
    private var pending: [(Result<String, Error>) -> Void] = []
    private var fetching = false
    private var watchdog: DispatchWorkItem?

    /// Nothing here is guaranteed to call back. Location can sit on an
    /// unanswered permission prompt, and a hung request would leave `fetching`
    /// set for good — every later "what's the weather" appending to `pending`
    /// and never being answered, with the HUD stuck on "Checking the weather".
    /// This turns that into an honest failure.
    private static let overallTimeout: TimeInterval = 12

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    enum WeatherError: LocalizedError {
        case noLocation
        case badResponse

        var errorDescription: String? {
            switch self {
            case .noLocation:
                return "Location unavailable — allow Location Services, or set coordinates in the menu"
            case .badResponse:
                return "Weather service didn't respond"
            }
        }
    }

    func requestAuthorizationIfNeeded() {
        guard Prefs.manualLatitude == nil else { return }
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    /// The last answer to each question, and when it was given.
    ///
    /// Conditions do not change minute to minute, and asking twice in a row
    /// used to mean a location fix and a network round trip twice — seconds of
    /// "Checking the weather" for a number that was already known. The unit is
    /// part of the key so switching to Celsius re-asks rather than converting
    /// nothing.
    ///
    /// One slot per question, because there are two of them now. A single slot
    /// keyed on which question it answered would mean today and tomorrow evict
    /// each other every time, so anyone who asked both got no caching at all.
    private var cachedToday: (summary: String, celsius: Bool, at: Date)?
    private var cachedTomorrow: (summary: String, celsius: Bool, at: Date)?
    private static let freshFor: TimeInterval = 180

    private func cached(tomorrow: Bool) -> String? {
        guard let entry = tomorrow ? cachedTomorrow : cachedToday,
              entry.celsius == Prefs.useCelsius,
              Date().timeIntervalSince(entry.at) < Self.freshFor
        else { return nil }
        return entry.summary
    }

    /// Which of the two questions is in flight. Only one fetch runs at a time,
    /// so a request for the other one has to wait rather than join it — asking
    /// for the forecast while "what's it like outside" was still in the air
    /// would otherwise be answered with today's conditions.
    private var fetchingTomorrow = false

    /// Short line for the HUD, e.g. "71°F · Clear sky".
    func current(completion: @escaping (Result<String, Error>) -> Void) {
        report(tomorrow: false, completion: completion)
    }

    /// Today's conditions, or tomorrow's forecast.
    func report(tomorrow: Bool, completion: @escaping (Result<String, Error>) -> Void) {
        if let summary = cached(tomorrow: tomorrow) {
            DispatchQueue.main.async { completion(.success(summary)) }
            return
        }

        // A fetch already running for the *other* question can't answer this
        // one. Queue behind it rather than joining it.
        if fetching, fetchingTomorrow != tomorrow {
            let deferred = completion
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.report(tomorrow: tomorrow, completion: deferred)
            }
            return
        }

        pending.append(completion)
        guard !fetching else { return }
        fetching = true
        fetchingTomorrow = tomorrow

        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, self.fetching else { return }
            self.finish(.failure(WeatherError.noLocation))
        }
        self.watchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.overallTimeout, execute: watchdog)

        if let lat = Prefs.manualLatitude, let lon = Prefs.manualLongitude {
            fetch(latitude: lat, longitude: lon)
            return
        }

        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            if let loc = manager.location {
                fetch(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude)
            } else {
                manager.requestLocation()
            }
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            manager.requestLocation()
        default:
            finish(.failure(WeatherError.noLocation))
        }
    }

    // MARK: - CoreLocation

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard fetching else { return }
        guard let loc = locations.last else { finish(.failure(WeatherError.noLocation)); return }
        fetch(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard fetching else { return }
        finish(.failure(WeatherError.noLocation))
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard fetching else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
        case .notDetermined: break
        default: finish(.failure(WeatherError.noLocation))
        }
    }

    // MARK: - Fetch

    private func fetch(latitude: Double, longitude: Double) {
        let tomorrow = fetchingTomorrow
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        var items = [
            URLQueryItem(name: "latitude", value: String(format: "%.3f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.3f", longitude)),
            URLQueryItem(name: "temperature_unit", value: Prefs.useCelsius ? "celsius" : "fahrenheit"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        if tomorrow {
            // Two days, because "daily" starts at today — tomorrow is index 1.
            items.append(URLQueryItem(
                name: "daily",
                value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"))
            items.append(URLQueryItem(name: "forecast_days", value: "2"))
        } else {
            items.append(URLQueryItem(name: "current",
                                      value: "temperature_2m,weather_code,apparent_temperature"))
        }
        components.queryItems = items
        guard let url = components.url else { finish(.failure(WeatherError.badResponse)); return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self else { return }
            guard let data,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let summary = tomorrow ? Self.readTomorrow(root) : Self.readCurrent(root)
            else {
                DispatchQueue.main.async { self.finish(.failure(error ?? WeatherError.badResponse)) }
                return
            }
            DispatchQueue.main.async { self.finish(.success(summary)) }
        }.resume()
    }

    private static var unit: String { Prefs.useCelsius ? "C" : "F" }

    /// "71°F · Clear sky", with "feels like" only when it disagrees.
    ///
    /// Adding it unconditionally would put "feels like 71" next to "71°F" on
    /// most days, which is noise. Three degrees is roughly where the difference
    /// stops being a rounding artefact and starts being worth knowing.
    private static func readCurrent(_ root: [String: Any]) -> String? {
        guard let current = root["current"] as? [String: Any],
              let temperature = current["temperature_2m"] as? Double
        else { return nil }
        let code = (current["weather_code"] as? Int) ?? -1
        var summary = "\(Int(temperature.rounded()))°\(unit) · \(describe(code))"
        if let feels = current["apparent_temperature"] as? Double,
           abs(feels - temperature) >= 3 {
            summary += " · feels \(Int(feels.rounded()))°"
        }
        return summary
    }

    /// "Tomorrow: 64–78°F · Rain showers · 70% chance"
    private static func readTomorrow(_ root: [String: Any]) -> String? {
        guard let daily = root["daily"] as? [String: Any],
              let highs = daily["temperature_2m_max"] as? [Double],
              let lows = daily["temperature_2m_min"] as? [Double],
              highs.count > 1, lows.count > 1
        else { return nil }

        let codes = (daily["weather_code"] as? [Int]) ?? []
        let code = codes.count > 1 ? codes[1] : -1
        var summary = "Tomorrow: \(Int(lows[1].rounded()))–\(Int(highs[1].rounded()))°\(unit)"
        summary += " · \(describe(code))"
        if let rain = (daily["precipitation_probability_max"] as? [Int]), rain.count > 1,
           rain[1] >= 20 {
            summary += " · \(rain[1])% chance of rain"
        }
        return summary
    }

    private func finish(_ result: Result<String, Error>) {
        watchdog?.cancel()
        watchdog = nil
        let wasTomorrow = fetchingTomorrow
        fetching = false
        if case .success(let summary) = result {
            let entry = (summary: summary, celsius: Prefs.useCelsius, at: Date())
            if wasTomorrow { cachedTomorrow = entry } else { cachedToday = entry }
        }
        let callbacks = pending
        pending.removeAll()
        DispatchQueue.main.async { callbacks.forEach { $0(result) } }
    }

    /// WMO weather interpretation codes.
    static func describe(_ code: Int) -> String {
        switch code {
        case 0: return "Clear sky"
        case 1: return "Mainly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51, 53, 55: return "Drizzle"
        case 56, 57: return "Freezing drizzle"
        case 61, 63, 65: return "Rain"
        case 66, 67: return "Freezing rain"
        case 71, 73, 75: return "Snow"
        case 77: return "Snow grains"
        case 80, 81, 82: return "Rain showers"
        case 85, 86: return "Snow showers"
        case 95: return "Thunderstorm"
        case 96, 99: return "Thunderstorm with hail"
        default: return "Conditions unknown"
        }
    }
}
