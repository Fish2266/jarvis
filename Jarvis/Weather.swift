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

    /// Short line for the HUD, e.g. "71°F · Clear sky".
    func current(completion: @escaping (Result<String, Error>) -> Void) {
        pending.append(completion)
        guard !fetching else { return }
        fetching = true

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
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.3f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.3f", longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "temperature_unit", value: Prefs.useCelsius ? "celsius" : "fahrenheit"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        guard let url = components.url else { finish(.failure(WeatherError.badResponse)); return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self else { return }
            guard let data,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let current = root["current"] as? [String: Any],
                  let temperature = current["temperature_2m"] as? Double
            else {
                DispatchQueue.main.async { self.finish(.failure(error ?? WeatherError.badResponse)) }
                return
            }
            let code = (current["weather_code"] as? Int) ?? -1
            let unit = Prefs.useCelsius ? "C" : "F"
            let summary = "\(Int(temperature.rounded()))°\(unit) · \(Self.describe(code))"
            DispatchQueue.main.async { self.finish(.success(summary)) }
        }.resume()
    }

    private func finish(_ result: Result<String, Error>) {
        watchdog?.cancel()
        watchdog = nil
        fetching = false
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
