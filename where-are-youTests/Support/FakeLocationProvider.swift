//
//  FakeLocationProvider.swift
//  where-are-youTests
//

@testable import where_are_you

/// A location provider tests drive by hand.
@MainActor
final class FakeLocationProvider: LocationProvider {
    private(set) var authorization: LocationAuthorization
    private(set) var isAccuracyReduced = false
    var onAuthorizationChange: (() -> Void)?

    private(set) var whenInUseRequests = 0
    private(set) var alwaysRequests = 0
    /// Streams handed out and not yet terminated.
    private(set) var activeStreams = 0

    private var continuation: AsyncStream<LocationReading>.Continuation?

    init(authorization: LocationAuthorization) {
        self.authorization = authorization
    }

    func requestWhenInUseAuthorization() {
        whenInUseRequests += 1
    }

    func requestAlwaysAuthorization() {
        alwaysRequests += 1
    }

    func readings() -> AsyncStream<LocationReading> {
        let (stream, continuation) = AsyncStream.makeStream(of: LocationReading.self)
        self.continuation = continuation
        activeStreams += 1
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.activeStreams -= 1 }
        }
        return stream
    }

    func send(_ reading: LocationReading) {
        continuation?.yield(reading)
    }

    /// Simulates Core Location finishing the stream on its own, as it does after an error.
    func finishStream() {
        continuation?.finish()
    }

    func simulateAuthorizationChange(to authorization: LocationAuthorization, accuracyReduced: Bool = false) {
        self.authorization = authorization
        isAccuracyReduced = accuracyReduced
        onAuthorizationChange?()
    }
}
