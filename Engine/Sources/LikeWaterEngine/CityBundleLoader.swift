import Foundation

/// Finds and loads the bundled city data. Nothing is fetched at runtime.
public enum CityBundleLoader {
    public static let defaultName = "sanfrancisco"

    public static func url(named name: String = defaultName, in bundle: Bundle) -> URL? {
        bundle.url(forResource: name, withExtension: "lwbundle")
    }

    public static func load(named name: String = defaultName, in bundle: Bundle = .main) throws -> CityBundle {
        guard let url = url(named: name, in: bundle) else {
            throw BundleError.unreadable("\(name).lwbundle is missing from the app bundle")
        }
        return try CityBundle(contentsOf: url)
    }
}
