import Foundation

/// Sun position for a point and instant, following the NOAA solar calculator
/// (the published spreadsheet algorithm). Accurate to well under a degree over
/// the years this app cares about, and dependency-free.
public struct SolarPosition: Sendable, Equatable {
    /// Degrees above the horizon, corrected for atmospheric refraction.
    public let elevation: Double
    /// Degrees clockwise from true north.
    public let azimuth: Double
    /// Solar declination, degrees.
    public let declination: Double
    /// Equation of time, minutes.
    public let equationOfTime: Double

    public var isUp: Bool { elevation > 0 }

    public init(elevation: Double, azimuth: Double, declination: Double, equationOfTime: Double) {
        self.elevation = elevation; self.azimuth = azimuth
        self.declination = declination; self.equationOfTime = equationOfTime
    }
}

public enum Solar {

    @inline(__always) static func rad(_ d: Double) -> Double { d * .pi / 180 }
    @inline(__always) static func deg(_ r: Double) -> Double { r * 180 / .pi }

    /// Julian day from a Foundation date (which is already UTC-based).
    public static func julianDay(_ date: Date) -> Double {
        2_440_587.5 + date.timeIntervalSince1970 / 86_400
    }

    public static func position(latitude: Double, longitude: Double, date: Date) -> SolarPosition {
        let jd = julianDay(date)
        let jc = (jd - 2_451_545.0) / 36_525.0

        let meanLong = (280.46646 + jc * (36_000.76983 + jc * 0.0003032))
            .truncatingRemainder(dividingBy: 360)
        let meanAnom = 357.52911 + jc * (35_999.05029 - 0.0001537 * jc)
        let eccentricity = 0.016708634 - jc * (0.000042037 + 0.0000001267 * jc)

        let centre = sin(rad(meanAnom)) * (1.914602 - jc * (0.004817 + 0.000014 * jc))
            + sin(rad(2 * meanAnom)) * (0.019993 - 0.000101 * jc)
            + sin(rad(3 * meanAnom)) * 0.000289

        let trueLong = meanLong + centre
        let appLong = trueLong - 0.00569 - 0.00478 * sin(rad(125.04 - 1_934.136 * jc))

        let meanObliquity = 23 + (26 + ((21.448 - jc * (46.815 + jc * (0.00059 - jc * 0.001813)))) / 60) / 60
        let obliquity = meanObliquity + 0.00256 * cos(rad(125.04 - 1_934.136 * jc))

        let declination = deg(asin(sin(rad(obliquity)) * sin(rad(appLong))))

        let y = pow(tan(rad(obliquity / 2)), 2)
        let equationOfTime = 4 * deg(
            y * sin(2 * rad(meanLong))
            - 2 * eccentricity * sin(rad(meanAnom))
            + 4 * eccentricity * y * sin(rad(meanAnom)) * cos(2 * rad(meanLong))
            - 0.5 * y * y * sin(4 * rad(meanLong))
            - 1.25 * eccentricity * eccentricity * sin(2 * rad(meanAnom)))

        // Minutes past UTC midnight.
        let secondsOfDay = date.timeIntervalSince1970 - (date.timeIntervalSince1970 / 86_400).rounded(.down) * 86_400
        let minutesUTC = secondsOfDay / 60

        var trueSolarTime = (minutesUTC + equationOfTime + 4 * longitude)
            .truncatingRemainder(dividingBy: 1_440)
        if trueSolarTime < 0 { trueSolarTime += 1_440 }

        let hourAngle = trueSolarTime / 4 < 0 ? trueSolarTime / 4 + 180 : trueSolarTime / 4 - 180

        let cosZenith = sin(rad(latitude)) * sin(rad(declination))
            + cos(rad(latitude)) * cos(rad(declination)) * cos(rad(hourAngle))
        let zenith = deg(acos(min(1, max(-1, cosZenith))))
        let rawElevation = 90 - zenith

        let elevation = rawElevation + refraction(rawElevation) / 3_600

        // Azimuth, degrees clockwise from north.
        var azimuth: Double
        let denominator = cos(rad(latitude)) * sin(rad(zenith))
        if abs(denominator) < 1e-9 {
            azimuth = declination > latitude ? 0 : 180
        } else {
            let value = (sin(rad(latitude)) * cos(rad(zenith)) - sin(rad(declination))) / denominator
            let base = deg(acos(min(1, max(-1, value))))
            azimuth = hourAngle > 0 ? (base + 180).truncatingRemainder(dividingBy: 360)
                                    : (540 - base).truncatingRemainder(dividingBy: 360)
        }
        if azimuth < 0 { azimuth += 360 }

        return SolarPosition(elevation: elevation, azimuth: azimuth,
                             declination: declination, equationOfTime: equationOfTime)
    }

    /// NOAA's atmospheric refraction correction, in arc-seconds.
    private static func refraction(_ elevation: Double) -> Double {
        if elevation > 85 { return 0 }
        let te = tan(rad(elevation))
        if elevation > 5 {
            return 58.1 / te - 0.07 / pow(te, 3) + 0.000086 / pow(te, 5)
        }
        if elevation > -0.575 {
            return 1_735 + elevation * (-518.2 + elevation * (103.4 + elevation * (-12.79 + elevation * 0.711)))
        }
        return -20.772 / te
    }

    /// The daylight window that actually brackets `instant`, or the next one if the
    /// instant falls at night. `sunriseSunset` works off UTC midnight, which straddles
    /// two local days away from Greenwich, so the raw window can sit entirely before or
    /// after the instant you asked about; this walks a day either way to fix that.
    public static func daylightWindow(latitude: Double, longitude: Double,
                                      containing instant: Date) -> (sunrise: Date, sunset: Date)? {
        for dayOffset in [0.0, -1.0, 1.0] {
            guard let window = sunriseSunset(latitude: latitude, longitude: longitude,
                                             on: instant.addingTimeInterval(dayOffset * 86_400)) else { continue }
            if instant >= window.sunrise && instant <= window.sunset { return window }
        }
        // Night: return the next window that starts after the instant.
        var best: (sunrise: Date, sunset: Date)?
        for dayOffset in [0.0, 1.0] {
            guard let window = sunriseSunset(latitude: latitude, longitude: longitude,
                                             on: instant.addingTimeInterval(dayOffset * 86_400)) else { continue }
            if window.sunrise > instant, best == nil || window.sunrise < best!.sunrise { best = window }
        }
        return best ?? sunriseSunset(latitude: latitude, longitude: longitude, on: instant)
    }

    /// Sunrise and sunset for a date, as instants. Nil at high latitudes when the
    /// sun does not cross the horizon that day.
    public static func sunriseSunset(latitude: Double, longitude: Double,
                                     on date: Date) -> (sunrise: Date, sunset: Date)? {
        let midnight = Date(timeIntervalSince1970:
            (date.timeIntervalSince1970 / 86_400).rounded(.down) * 86_400)
        let noonGuess = midnight.addingTimeInterval(43_200)
        let p = position(latitude: latitude, longitude: longitude, date: noonGuess)

        let cosHA = cos(rad(90.833)) / (cos(rad(latitude)) * cos(rad(p.declination)))
            - tan(rad(latitude)) * tan(rad(p.declination))
        guard cosHA >= -1, cosHA <= 1 else { return nil }
        let haMinutes = deg(acos(cosHA)) * 4

        let solarNoonMinutes = 720 - 4 * longitude - p.equationOfTime
        return (midnight.addingTimeInterval((solarNoonMinutes - haMinutes) * 60),
                midnight.addingTimeInterval((solarNoonMinutes + haMinutes) * 60))
    }
}
