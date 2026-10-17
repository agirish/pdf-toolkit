import Foundation

/// Runs Vision text recognition for a test on one serial GCD queue, and suspends the test until
/// it finishes. **Every test that reaches recognition goes through here**, which means any OCR
/// call on an input with a page that has no text.
///
/// The reason is a deadlock. `VNImageRequestHandler.perform` blocks its thread, and Vision's
/// TextRecognition then waits on a semaphore for work that needs a free thread from Swift's
/// cooperative pool. Swift Testing runs synchronous tests on that pool, and the pool has one thread
/// per core. If OCR tests block all of them, nothing can run that work, and the whole test process
/// hangs. Every other test then prints `started` and never finishes. The hosted macos-26 runner has
/// 3 cores and the suite has 4 recognizing tests, so CI hung for its full 30 minutes. A 10-core Mac
/// hangs the same way with 10 concurrent recognitions and finishes with 9.
///
/// The lane avoids that in two ways. A waiting test is suspended rather than blocked, so it holds
/// no pool thread. And recognition runs on the lane's own thread, so it never takes one. Running
/// one at a time costs the suite very little, because Vision already funnels recognition through
/// one serial detector queue: 100 recognitions took 8.4 s through the lane. Hopping to
/// `DispatchQueue.global()` alone is not enough. It moves the limit rather than removing it, and
/// 40 concurrent recognitions still hung on a 10-core Mac.
enum VisionLane {
    private static let queue = DispatchQueue(label: "PDFToolkitCoreTests.VisionLane")

    static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: body)) }
        }
    }
}
