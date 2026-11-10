import ApplicationServices
import CoreGraphics

// fork: AXError is an imported C enum and interpolates as a bare
// `__C.AXError`, which hid every AX code from the admission logs. Kept
// outside upstream's FrameSizingFailure.swift so syncs do not conflict.
extension FrameSizingFailure: CustomStringConvertible {
    var description: String {
        switch self {
        case .cleanupFailed(let id, let primary, let error):
            return "cleanupFailed(\(id), primary: \(primary.map(\.description) ?? "nil"), error: \(error.rawValue))"
        case .writeFailed(let id, let error): return "writeFailed(\(id), \(error.rawValue))"
        case .readFailed(let id, let error): return "readFailed(\(id), \(error.rawValue))"
        case .deadlineExceeded: return "deadlineExceeded"
        case .attemptsExhausted: return "attemptsExhausted"
        case .noFittingSlot(let id): return "noFittingSlot(\(id))"
        case .geometryMismatch(let id): return "geometryMismatch(\(id))"
        case .outsideUsableFrame(let id): return "outsideUsableFrame(\(id))"
        case .overlap(let a, let b): return "overlap(\(a), \(b))"
        case .gapViolation(let a, let b): return "gapViolation(\(a), \(b))"
        case .windowUnavailable(let id): return "windowUnavailable(\(id))"
        case .duplicateWindowID(let id): return "duplicateWindowID(\(id))"
        case .invalidFrame(let id): return "invalidFrame(\(id))"
        case .superseded: return "superseded"
        }
    }
}
