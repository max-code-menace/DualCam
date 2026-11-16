import AVFoundation
import ExpoModulesCore
import UIKit

/// Vue native affichée dans React Native : deux aperçus caméra en direct.
class DualCameraView: ExpoView {
  let onCameraReady = EventDispatcher()
  let onCameraError = EventDispatcher()

  private let backLayer = AVCaptureVideoPreviewLayer()
  private let frontLayer = AVCaptureVideoPreviewLayer()
  private let frontBorder = CAShapeLayer()
  private var started = false

  var layout: DualCameraLayout = .stack {
    didSet { setNeedsLayout() }
  }

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    clipsToBounds = true
    backgroundColor = .black

    backLayer.videoGravity = .resizeAspectFill
    frontLayer.videoGravity = .resizeAspectFill
    frontLayer.masksToBounds = true

    frontBorder.fillColor = UIColor.clear.cgColor
    frontBorder.strokeColor = UIColor.white.cgColor
    frontBorder.lineWidth = 2

    layer.addSublayer(backLayer)
    layer.addSublayer(frontLayer)
    layer.addSublayer(frontBorder)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    CATransaction.begin()
    CATransaction.setDisableActions(true)

    backLayer.frame = DualCameraGeometry.backRect(in: bounds, layout: layout)
    let frontRect = DualCameraGeometry.frontRect(in: bounds, layout: layout)
    frontLayer.frame = frontRect

    if layout == .pip {
      let radius = DualCameraGeometry.pipCornerRadius(for: frontRect)
      frontLayer.cornerRadius = radius
      frontBorder.path = UIBezierPath(roundedRect: frontRect, cornerRadius: radius).cgPath
      frontBorder.isHidden = false
    } else {
      frontLayer.cornerRadius = 0
      frontBorder.isHidden = true
    }
    CATransaction.commit()
  }

  // Démarre les caméras quand la vue apparaît, les arrête quand elle disparaît.
  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil {
      guard !started else { return }
      started = true
      DualCameraController.shared.start(backLayer: backLayer, frontLayer: frontLayer) { [weak self] error in
        guard let self = self else { return }
        if let error = error {
          self.started = false
          self.onCameraError(["message": error.localizedDescription])
        } else {
          self.onCameraReady([:])
        }
      }
    } else if started {
      started = false
      DualCameraController.shared.stop()
    }
  }
}
