import Foundation

extension URL {
    /// Runs `body` while security-scoped access is active for this URL.
    /// Throws `PDFOperationError.fileAccessDenied` if access could not be started (typical in a sandboxed app).
    public func withSecurityScopedAccess<T>(_ body: () throws -> T) throws -> T {
        guard startAccessingSecurityScopedResource() else {
            throw PDFOperationError.fileAccessDenied(self)
        }
        defer { stopAccessingSecurityScopedResource() }
        return try body()
    }
}

public enum URLCollectionSecurityScope {
    /// Starts access for every URL (in order), then runs `body`. Stops access for all URLs that were started.
    public static func withAccess<T>(_ urls: [URL], _ body: () throws -> T) throws -> T {
        var started: [URL] = []
        defer {
            for u in started {
                u.stopAccessingSecurityScopedResource()
            }
        }
        for url in urls {
            guard url.startAccessingSecurityScopedResource() else {
                throw PDFOperationError.fileAccessDenied(url)
            }
            started.append(url)
        }
        return try body()
    }
}
