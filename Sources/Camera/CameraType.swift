import CoreGraphics
import AVFoundation

@available(macCatalyst 14.0, *)
public enum CameraType : Int {
    case back
    case front
    
    mutating func toggle() {
        switch self {
        case .back: self = .front
        case .front: self = .back
        }
    }
    var mirrored: Bool {
        switch self {
        case .back: return false
        case .front: return true
        }
    }
    mutating func device(_ back: AVCaptureDevice?, _ front: AVCaptureDevice?) -> AVCaptureDevice? {
        switch self {
        case .back: return back
        case .front: return front
        }
    }
}

public struct VideoSpec {
    var fps: Int32?
    var size: CGSize?
}
