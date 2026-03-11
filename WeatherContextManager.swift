import Foundation
import CoreLocation
import Combine

struct WeatherContext: Codable, Equatable {
    let temperatureC: Double
    let precipitation: Double
    let weatherCode: Int
    let fetchedAt: Date

    var isBadForOutdoor: Bool {
        precipitation >= 0.2 || [61, 63, 65, 71, 73, 75, 80, 81, 82, 95, 96, 99].contains(weatherCode)
    }
}

@MainActor
final class WeatherContextManager: NSObject, ObservableObject {
    @Published private(set) var weather: WeatherContext?
    @Published private(set) var lastError: String?

    private let locationManager = CLLocationManager()
    private var pendingContinuation: CheckedContinuation<CLLocationCoordinate2D?, Never>?
    private var lastFetchTime: Date?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func refreshWeather(force: Bool = false) async {
        if !force, let lastFetchTime, Date().timeIntervalSince(lastFetchTime) < 60 * 45 {
            return
        }

        guard let coordinate = await fetchCoordinate() else {
            lastError = "Location unavailable"
            return
        }

        let lat = coordinate.latitude
        let lon = coordinate.longitude
        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,precipitation,weather_code&timezone=auto"
        guard let url = URL(string: urlString) else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
            let current = decoded.current
            weather = WeatherContext(
                temperatureC: current.temperature2m,
                precipitation: current.precipitation,
                weatherCode: current.weatherCode,
                fetchedAt: Date()
            )
            lastFetchTime = Date()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            print("[Weather] fetch failed: \(error.localizedDescription)")
        }
    }

    private func fetchCoordinate() async -> CLLocationCoordinate2D? {
        if let coordinate = locationManager.location?.coordinate {
            return coordinate
        }

        let status = locationManager.authorizationStatus
        if status == .notDetermined {
            return await withCheckedContinuation { continuation in
                pendingContinuation = continuation
                locationManager.requestWhenInUseAuthorization()
            }
        }

        guard status == .authorizedAlways || status == .authorizedWhenInUse else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            pendingContinuation = continuation
            locationManager.requestLocation()
        }
    }
}

extension WeatherContextManager: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let status = manager.authorizationStatus
            if status == .authorizedAlways || status == .authorizedWhenInUse {
                manager.requestLocation()
            } else if status == .denied || status == .restricted {
                pendingContinuation?.resume(returning: nil)
                pendingContinuation = nil
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            pendingContinuation?.resume(returning: locations.last?.coordinate)
            pendingContinuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            pendingContinuation?.resume(returning: nil)
            pendingContinuation = nil
            lastError = error.localizedDescription
        }
    }
}

private struct OpenMeteoResponse: Decodable {
    let current: Current

    struct Current: Decodable {
        let temperature2m: Double
        let precipitation: Double
        let weatherCode: Int

        enum CodingKeys: String, CodingKey {
            case temperature2m = "temperature_2m"
            case precipitation
            case weatherCode = "weather_code"
        }
    }
}
