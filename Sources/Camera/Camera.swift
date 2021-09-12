import Foundation
import AVFoundation
import UIKit

@available(macCatalyst 14.0, *)
public protocol CameraProtocol: AnyObject {
    func image(image: UIImage)
}

@available(macCatalyst 14.0, *)
public class Camera: NSObject {
    var session: AVCaptureSession!
    var preview: AVCaptureVideoPreviewLayer!
    var output: AVCaptureVideoDataOutput!
    
    var backCamera: AVCaptureDevice!
    var frontCamera: AVCaptureDevice!
    var backInput: AVCaptureInput!
    var frontInput: AVCaptureInput!
    
    var state: State = .none
    var type: CameraType = .back
    var takePicture = false
    weak var delegate: CameraProtocol?
    var view: UIView?
    var zoomScale: CGFloat = 1
    var beginZoomScale: CGFloat = 1
    var maxZoomScale: CGFloat = 1
    var device: AVCaptureDevice? { type.device(backCamera, frontCamera) }
    var sessionQueue: DispatchQueue { DispatchQueue(label: "sessionQueue", attributes: []) }
    
    func access(completion: @escaping () -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { [self] _ in
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                state = .authorized
                completion()
            case .notDetermined: state = .denied
            case .restricted: state = .restricted
            case .denied: state = .denied
            default: state = .none
            }
        }
    }
    
    public func capture(_ view: UIView) {
        access { [weak self] in
            guard let self = self else { return }
            self.sessionQueue.async {
                self.view = view
                self.sessions()
                self.configure()
                self.layer()
                DispatchQueue.main.async {
                    self.preview.frame = view.layer.bounds
                    view.layer.addSublayer(self.preview)
                }
                self.attachZoom(view)
                self.attachFocus(view)
                self.outputs()
                self.start()
            }
        }
    }
    
    @discardableResult
    public func delegate(_ delegate: CameraProtocol?) -> Self {
        self.delegate = delegate
        return self
    }
    
    public func rotate() {
        guard let frame = preview?.superlayer?.bounds,
              let connection = preview?.connection else { return }
        let orientation: UIDeviceOrientation = UIDevice.current.orientation
        if connection.isVideoOrientationSupported {
            switch orientation {
            case .portrait: connection.videoOrientation = .portrait
            case .landscapeLeft: connection.videoOrientation = .landscapeRight
            case .landscapeRight: connection.videoOrientation = .landscapeLeft
            case .portraitUpsideDown: connection.videoOrientation = .portraitUpsideDown
            default: connection.videoOrientation = .portrait
            }
        }
        preview?.frame = frame
    }
    
    public func image() {
        takePicture = true
    }
    
    func configure() {
        guard let backCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return }
        guard let frontCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else { return }
        guard let backInput = try? AVCaptureDeviceInput(device: backCamera) else { return }
        guard let frontInput = try? AVCaptureDeviceInput(device: frontCamera) else { return }
        
        self.backCamera = backCamera
        self.frontCamera = frontCamera
        self.backInput = backInput
        self.frontInput = frontInput
        if session.canAddInput(frontInput) { session.addInput(backInput) }
    }
    
    func sessions() {
        session = AVCaptureSession()
        session.beginConfiguration()
        if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
        session.automaticallyConfiguresCaptureDeviceForWideColor = true
    }
    
    func layer() {
        preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.contentsGravity = CALayerContentsGravity.resizeAspectFill
    }
    
    func outputs() {
        let queue = DispatchQueue(label: "videoQueue", qos: .userInteractive)
        output = AVCaptureVideoDataOutput()
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        output.connections.first?.videoOrientation = .portrait
        session.commitConfiguration()
    }
    
    func start() {
        if session.isRunning { return }
        session.startRunning()
    }
    
    func stop() {
        if !session.isRunning { return }
        session.stopRunning()
    }
    
    public func switchCamera(_ view: UIView?) {
        view?.isUserInteractionEnabled = false
        switchCamera()
        view?.isUserInteractionEnabled = true
    }
    
    public func switchCamera() {
        session.beginConfiguration()
        type.toggle()
        switch type {
        case .back:
            session.removeInput(frontInput)
            session.addInput(backInput)
        case .front:
            session.removeInput(backInput)
            session.addInput(frontInput)
        }
        output.connections.first?.videoOrientation = .portrait
        output.connections.first?.isVideoMirrored = type.mirrored
        session.commitConfiguration()
    }
    
    lazy var zoomGesture = UIPinchGestureRecognizer()
    lazy var focusGesture = UITapGestureRecognizer()
    lazy var focusMode: AVCaptureDevice.FocusMode = .continuousAutoFocus
    lazy var exposureMode: AVCaptureDevice.ExposureMode = .continuousAutoExposure
    
    func zoom(_ scale: CGFloat) {
        guard let device = device,
              let _ = try? device.lockForConfiguration() else { return }
        zoomScale = max(1.0, min(beginZoomScale * scale, maxZoomScale))
        device.videoZoomFactor = zoomScale
        device.unlockForConfiguration()
    }
    
    private func attachZoom(_ view: UIView) {
        DispatchQueue.main.async {
            self.zoomGesture.addTarget(self, action: #selector(self.configureZoom))
            view.addGestureRecognizer(self.zoomGesture)
            self.zoomGesture.delegate = self
        }
        configureZoomScale()
    }
    
    private func attachFocus(_ view: UIView) {
        DispatchQueue.main.async {
            self.focusGesture.addTarget(self, action: #selector(self.configureFocus))
            view.addGestureRecognizer(self.focusGesture)
            self.focusGesture.delegate = self
        }
    }
    
    @objc private func configureZoom(_ recognizer: UIPinchGestureRecognizer) {
        guard let preview = preview,
              let view = recognizer.view else { return }
        
        var allTouchesOnPreviewLayer = true
        let numTouch = recognizer.numberOfTouches
        
        for i in 0 ..< numTouch {
            let location = recognizer.location(ofTouch: i, in: view)
            let convertedTouch = preview.convert(location, from: preview.superlayer)
            if !preview.contains(convertedTouch) {
                allTouchesOnPreviewLayer = false
                break
            }
        }
        if allTouchesOnPreviewLayer {
            zoom(recognizer.scale)
        }
    }
    
    private func configureZoomScale() {
        var maxZoom = CGFloat(1.0)
        beginZoomScale = CGFloat(1.0)
        
        if type == .back, let backCamera = backCamera {
            maxZoom = backCamera.activeFormat.videoMaxZoomFactor
        } else if type == .front, let frontCamera = frontCamera {
            maxZoom = frontCamera.activeFormat.videoMaxZoomFactor
        }
        
        maxZoomScale = maxZoom
    }
    
    @objc private func configureFocus(_ recognizer: UITapGestureRecognizer) {
        guard let device = device, let preview = preview,
              let view = recognizer.view,
              let _ = try? device.lockForConfiguration() else { return }
        let previewPoint = view.layer.convert(recognizer.location(in: view), to: preview)
        let point = preview.captureDevicePointConverted(fromLayerPoint: previewPoint)
        
        if device.isFocusPointOfInterestSupported {
            device.focusPointOfInterest = point
        }
        
        if device.isExposurePointOfInterestSupported {
            device.exposurePointOfInterest = point
        }
        
        if device.isFocusModeSupported(focusMode) {
            device.focusMode = focusMode
        }
        
        if device.isExposureModeSupported(exposureMode) {
            device.exposureMode = exposureMode
        }
        
        device.unlockForConfiguration()
    }
    
    enum State {
        case authorized, denied, restricted, none
    }
}

@available(macCatalyst 14.0, *)
extension Camera: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if !takePicture { return }
        guard let cvBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        let uiImage = UIImage(ciImage: CIImage(cvImageBuffer: cvBuffer))
        DispatchQueue.main.async { [self] in
            delegate?.image(image: uiImage)
        }
        takePicture = false
    }
}

@available(macCatalyst 14.0, *)
extension Camera: UIGestureRecognizerDelegate {
    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer.isKind(of: UIPinchGestureRecognizer.self) {
            beginZoomScale = zoomScale
        }
        
        return true
    }
}
