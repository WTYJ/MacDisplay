import Foundation

enum UpdateCheck {
    enum Result: Equatable {
        case noRelease
        case upToDate
        case available(String)
    }

    private static let releasesPage = URL(string: "https://github.com/WTYJ/MacDisplay/releases")!
    static let latestReleasePage = releasesPage.appendingPathComponent("latest")

    static func check(installedVersion: String) async throws -> Result {
        // GitHub redirects the public latest-release URL to the tagged release,
        // or to the releases page when there is no full release yet.
        var request = URLRequest(url: latestReleasePage, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, let url = response.url else {
            throw URLError(.badServerResponse)
        }
        return try result(url: url, statusCode: response.statusCode, installedVersion: installedVersion)
    }

    static func result(url: URL, statusCode: Int, installedVersion: String) throws -> Result {
        guard statusCode == 200, url.scheme == "https", url.host == releasesPage.host else {
            throw URLError(.badServerResponse)
        }
        let base = releasesPage.pathComponents.map { $0.lowercased() }
        let path = url.pathComponents
        guard path.prefix(base.count).map({ $0.lowercased() }) == base else {
            throw URLError(.cannotParseResponse)
        }
        if path.count == base.count { return .noRelease }
        guard path.count == base.count + 2, path[base.count] == "tag",
              let installed = versionComponents(installedVersion),
              let published = versionComponents(path[base.count + 1]) else {
            throw URLError(.cannotParseResponse)
        }
        return installed.lexicographicallyPrecedes(published)
            ? .available(published.map(String.init).joined(separator: "."))
            : .upToDate
    }

    private static func versionComponents(_ string: String) -> [Int]? {
        let version = string.first?.lowercased() == "v" ? string.dropFirst() : string[...]
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(part)
        }
        guard (1...3).contains(parts.count), numbers.count == parts.count else { return nil }
        return numbers + Array(repeating: 0, count: 3 - numbers.count)
    }

}
