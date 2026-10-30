import Foundation

/// One foreground run owns the mouse until it finishes or stops. Background
/// runs never enter this queue. The owner releases only after its mouse-up.
@MainActor
public final class ForegroundQueue {
    public static let shared = ForegroundQueue()
    private var owner: UUID?
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []
    public init() {}
    public var isOccupied: Bool { owner != nil }
    public func acquire(_ id: UUID) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                if owner == nil { owner = id; continuation.resume() }
                else { waiters.append((id, continuation)) }
            }
        } onCancel: {
            Task { @MainActor in self.cancelWaiter(id) }
        }
    }
    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
    public func release(_ id: UUID) {
        guard owner == id else { return }
        owner = nil
        if !waiters.isEmpty {
            let next = waiters.removeFirst(); owner = next.0; next.1.resume()
        }
    }
}
