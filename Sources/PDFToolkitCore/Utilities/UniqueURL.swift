import Foundation

extension PDFToolkit {
    /// `dir/filename`, or `dir/name 2.pdf`, `name 3.pdf`… if that already exists — so a write into a
    /// shared folder never overwrites a prior output (and, with a suffix present, never the source
    /// either).
    public static func uniqueURL(inDirectory directory: URL, filename: String, fileManager: FileManager = .default) -> URL {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = directory.appendingPathComponent(filename)
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = directory.appendingPathComponent(next)
            counter += 1
        }
        return candidate
    }
}
