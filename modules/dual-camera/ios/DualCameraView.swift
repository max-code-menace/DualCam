import AVFoundation
import AVKit
import CoreMotion
import ExpoModulesCore
import UIKit

/// Vue native affichée dans React Native : l'aperçu caméra en direct,
/// avec les gestes de l'app Appareil photo (toucher, pincer, glisser, boutons de volume).
class DualCameraView: ExpoView {
  let onCameraReady = EventDispatcher()
  let onCameraError = EventDispatcher()
  let onZoomChange = EventDispatcher()
  let onSwipe = EventDispatcher()
  let onShutterButton = EventDispatcher()
  let onExposureChange = EventDispatcher()
  let onOrientationChange = EventDispatcher()
  let onLowLight = EventDispatcher()

  // Mode nuit : croix blanche fixe + croix jaune qui bouge avec l'iPhone.
  private let steadyWhite = CAShapeLayer()
  private let steadyYellow = CAShapeLayer()
  private var steadyReference: CMAttitude?

  /// true pendant une photo en mode nuit : affiche la croix pour aider à ne pas bouger.
  var steady: Bool = false {
    didSet {
      guard oldValue != steady else { return }
      if steady { startSteadyGuide() } else { stopSteadyGuide() }
    }
  }

  // Sens dans lequel on tient l'iPhone (pour tourner les icônes, comme l'app Appareil photo).
  private let motion = CMMotionManager()
  private var uiRotation = 0

  // Mode Duo : deux aperçus. Modes Photo / Vidéo : un seul.
  private let backLayer = AVCaptureVideoPreviewLayer()
  private let frontLayer = AVCaptureVideoPreviewLayer()
  private let singleLayer = AVCaptureVideoPreviewLayer()

  // Flou affiché pendant qu'on change de mode ou de caméra (comme l'app Appareil photo).
  private let blurView = UIVisualEffectView(effect: nil)

  // Carré de mise au point + soleil d'exposition.
  private let focusSquare = CAShapeLayer()
  private let sunLayer = CATextLayer()
  private let sunLine = CAShapeLayer()
  private var focusPoint: CGPoint?
  private var focusHideWork: DispatchWorkItem?

  private let gestureHelper = GestureHelper()
  private var attached = false
  private var wentToBackground = false
  private var activationScheduled = false

  private var dragRect: CGRect?
  private var pinchSide: DualCameraSide = .back
  private var pinchStartZoom: CGFloat = 1
  private var exposureStart: Float = 0

  /// "dual", "photo" ou "video".
  var mode: String = "photo" {
    didSet { if oldValue != mode { scheduleActivation() } }
  }

  /// "back" ou "front" (modes Photo / Vidéo).
  var position: String = "back" {
    didSet { if oldValue != position { scheduleActivation() } }
  }

  /// Vidéo : "HD" ou "4K".
  var videoResolution: String = "HD" {
    didSet { if oldValue != videoResolution && mode == "video" { scheduleActivation() } }
  }

  /// Vidéo : images par seconde (24, 30, 60, 120).
  var videoFps: Int = 30 {
    didSet { if oldValue != videoFps && mode == "video" { scheduleActivation() } }
  }

  var layout: DualCameraLayout = .stack {
    didSet { if oldValue != layout { updateComposition(animated: true) } }
  }

  var swapped: Bool = false {
    didSet { if oldValue != swapped { updateComposition(animated: true) } }
  }

  private var pipCorner: PipCorner = DualCameraController.shared.composition.pipCorner

  private var composition: DualCameraComposition {
    return DualCameraComposition(layout: layout, swapped: swapped, pipCorner: pipCorner)
  }

  private var captureMode: CaptureMode {
    let side: DualCameraSide = position == "front" ? .front : .back
    switch mode {
    case "dual": return .dual
    case "video": return .video(side)
    default: return .photo(side)
    }
  }

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    clipsToBounds = true
    backgroundColor = .black

    for preview in [backLayer, frontLayer, singleLayer] {
      preview.videoGravity = .resizeAspectFill
      preview.masksToBounds = true
      preview.borderColor = UIColor.white.cgColor
      layer.addSublayer(preview)
    }
    DualCameraController.shared.onRuntimeError = { [weak self] message in
      self?.onCameraError(["message": message])
    }
    DualCameraController.shared.onResume = { [weak self] in
      guard let self = self, self.attached else { return }
      self.scheduleActivation()
    }

    let yellow = UIColor(red: 1, green: 0.84, blue: 0.04, alpha: 1).cgColor
    focusSquare.fillColor = UIColor.clear.cgColor
    focusSquare.strokeColor = yellow
    focusSquare.lineWidth = 1.2
    focusSquare.opacity = 0
    focusSquare.zPosition = 10
    layer.addSublayer(focusSquare)

    sunLine.strokeColor = yellow
    sunLine.lineWidth = 1
    sunLine.opacity = 0
    sunLine.zPosition = 10
    layer.addSublayer(sunLine)

    sunLayer.string = "☀︎"
    sunLayer.fontSize = 22
    sunLayer.foregroundColor = yellow
    sunLayer.alignmentMode = .center
    sunLayer.contentsScale = UIScreen.main.scale
    sunLayer.bounds = CGRect(x: 0, y: 0, width: 26, height: 26)
    sunLayer.opacity = 0
    sunLayer.zPosition = 11
    layer.addSublayer(sunLayer)

    let crossPath = UIBezierPath()
    crossPath.move(to: CGPoint(x: 0, y: 30))
    crossPath.addLine(to: CGPoint(x: 60, y: 30))
    crossPath.move(to: CGPoint(x: 30, y: 0))
    crossPath.addLine(to: CGPoint(x: 30, y: 60))
    for cross in [steadyWhite, steadyYellow] {
      cross.bounds = CGRect(x: 0, y: 0, width: 60, height: 60)
      cross.path = crossPath.cgPath
      cross.fillColor = UIColor.clear.cgColor
      cross.lineWidth = 1.5
      cross.opacity = 0
      cross.zPosition = 12
      layer.addSublayer(cross)
    }
    steadyWhite.strokeColor = UIColor.white.cgColor
    steadyYellow.strokeColor = yellow

    DualCameraController.shared.onLowLight = { [weak self] active, seconds in
      self?.onLowLight(["active": active, "seconds": seconds])
    }

    blurView.isUserInteractionEnabled = false
    blurView.frame = bounds
    // Au-dessus des aperçus (y compris la petite fenêtre du mode Duo), sous le carré de mise au point.
    blurView.layer.zPosition = 5
    addSubview(blurView)

    setUpGestures()
    setUpHardwareButtons()

    // Au retour dans l'app (après un vrai passage en arrière-plan), on relance la caméra.
    NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground),
                                           name: UIApplication.didEnterBackgroundNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive),
                                           name: UIApplication.didBecomeActiveNotification, object: nil)
  }

  @objc private func appDidEnterBackground() {
    wentToBackground = true
  }

  @objc private func appDidBecomeActive() {
    guard wentToBackground else { return }
    wentToBackground = false
    if attached { scheduleActivation() }
  }

  // MARK: - Mise en page

  override func layoutSubviews() {
    super.layoutSubviews()
    if dragRect == nil {
      applyLayout(animated: false)
    }
  }

  // Dès que la taille de la vue change, l'aperçu suit (sinon il peut rester à une hauteur de 0).
  override var bounds: CGRect {
    didSet {
      if oldValue.size != bounds.size && dragRect == nil { applyLayout(animated: false) }
    }
  }

  override var frame: CGRect {
    didSet {
      if oldValue.size != frame.size && dragRect == nil { applyLayout(animated: false) }
    }
  }

  private func updateComposition(animated: Bool) {
    DualCameraController.shared.composition = composition
    applyLayout(animated: animated && window != nil)
  }

  private func previewLayer(for side: DualCameraSide) -> AVCaptureVideoPreviewLayer {
    if !captureMode.isDual { return singleLayer }
    return side == .front ? frontLayer : backLayer
  }

  private func applyLayout(animated: Bool) {
    CATransaction.begin()
    if animated {
      CATransaction.setAnimationDuration(0.3)
      CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
    } else {
      CATransaction.setDisableActions(true)
    }

    let dual = captureMode.isDual
    singleLayer.isHidden = dual
    backLayer.isHidden = !dual
    frontLayer.isHidden = !dual
    singleLayer.frame = bounds
    blurView.frame = bounds

    let c = composition
    let rects = DualCameraGeometry.rects(in: bounds, c)
    frontLayer.frame = rects.front
    backLayer.frame = rects.back

    for side in [DualCameraSide.front, DualCameraSide.back] {
      let preview = side == .front ? frontLayer : backLayer
      let isSmall = c.smallSide == side
      preview.zPosition = isSmall ? 1 : 0
      preview.cornerRadius = isSmall ? DualCameraGeometry.pipCornerRadius(for: preview.frame) : 0
      preview.borderWidth = isSmall ? 2 : 0
    }
    CATransaction.commit()
  }

  // MARK: - Démarrage

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil {
      guard !attached else { return }
      attached = true
      scheduleActivation()
      startMotion()
    } else if attached {
      attached = false
      motion.stopAccelerometerUpdates()
      motion.stopDeviceMotionUpdates()
      DualCameraController.shared.stop()
    }
  }

  private func startMotion() {
    guard motion.isAccelerometerAvailable, !motion.isAccelerometerActive else { return }
    motion.accelerometerUpdateInterval = 0.25
    motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
      guard let self = self, let a = data?.acceleration else { return }
      var rotation = self.uiRotation
      if abs(a.x) > 0.75 && abs(a.y) < 0.5 {
        rotation = a.x < 0 ? 90 : -90
      } else if a.y < -0.75 && abs(a.x) < 0.5 {
        rotation = 0
      }
      if rotation != self.uiRotation {
        self.uiRotation = rotation
        self.onOrientationChange(["rotation": rotation])
      }
    }
  }

  /// Regroupe les changements de mode et de caméra arrivés en même temps.
  private func scheduleActivation() {
    guard !activationScheduled else { return }
    activationScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.activationScheduled = false
      self.activate()
    }
  }

  private func activate() {
    guard attached else { return }
    hideFocus(animated: false)
    setBlur(true)
    applyLayout(animated: false)
    DualCameraController.shared.composition = composition
    DualCameraController.shared.videoHeight = videoResolution == "4K" ? 2160 : 1080
    DualCameraController.shared.videoFps = videoFps
    let requested = captureMode
    DualCameraController.shared.activate(requested, backLayer: backLayer, frontLayer: frontLayer,
                                           singleLayer: singleLayer) { [weak self] result in
      guard let self = self, self.captureMode == requested else { return }
      self.setBlur(false)
      switch result {
      case .success(var info):
        if !requested.isDual, let connection = self.singleLayer.connection {
          DualCameraController.setPortrait(connection)
        }
        self.applyLayout(animated: false)
        self.setNeedsLayout()
        info["mode"] = self.mode
        info["position"] = self.position
        self.onCameraReady(info)
      case .failure(let error):
        self.onCameraError(["message": error.localizedDescription])
      }
    }
  }

  // MARK: - Croix du mode nuit

  private func startSteadyGuide() {
    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for cross in [steadyWhite, steadyYellow] {
      cross.position = center
      cross.setAffineTransform(.identity)
      cross.opacity = 1
    }
    CATransaction.commit()

    steadyReference = nil
    guard motion.isDeviceMotionAvailable else { return }
    motion.deviceMotionUpdateInterval = 1.0 / 30.0
    motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
      guard let self = self, self.steady,
            let attitude = data?.attitude.copy() as? CMAttitude else { return }
      // La position de départ sert de repère : la croix jaune montre de combien on a bougé depuis.
      guard let reference = self.steadyReference else {
        self.steadyReference = attitude
        return
      }
      attitude.multiply(byInverseOf: reference)
      let limit: CGFloat = 60
      let dx = max(-limit, min(limit, CGFloat(attitude.roll) * 500))
      let dy = max(-limit, min(limit, CGFloat(attitude.pitch) * 500))
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      self.steadyYellow.position = CGPoint(x: self.bounds.midX + dx, y: self.bounds.midY + dy)
      self.steadyYellow.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(-attitude.yaw)))
      CATransaction.commit()
    }
  }

  private func stopSteadyGuide() {
    motion.stopDeviceMotionUpdates()
    steadyReference = nil
    CATransaction.begin()
    CATransaction.setAnimationDuration(0.25)
    steadyWhite.opacity = 0
    steadyYellow.opacity = 0
    CATransaction.commit()
  }

  private func setBlur(_ on: Bool) {
    UIView.animate(withDuration: on ? 0.15 : 0.4, delay: on ? 0 : 0.12,
                   options: [.beginFromCurrentState, .curveEaseInOut], animations: {
      self.blurView.effect = on ? UIBlurEffect(style: .systemUltraThinMaterialDark) : nil
    }, completion: nil)
  }

  // MARK: - Gestes

  private func setUpGestures() {
    let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
    let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
    let pipPan = UIPanGestureRecognizer(target: self, action: #selector(handlePipPan(_:)))
    pipPan.maximumNumberOfTouches = 1
    let exposurePan = UIPanGestureRecognizer(target: self, action: #selector(handleExposurePan(_:)))
    exposurePan.maximumNumberOfTouches = 1

    gestureHelper.shouldBegin = { [weak self] recognizer in
      guard let self = self else { return true }
      let location = recognizer.location(in: self)
      if recognizer === pipPan {
        guard self.captureMode.isDual, let small = self.composition.smallSide else { return false }
        return self.previewLayer(for: small).frame.contains(location)
      }
      if recognizer === exposurePan, let pan = recognizer as? UIPanGestureRecognizer {
        guard self.focusPoint != nil else { return false }
        let velocity = pan.velocity(in: self)
        return abs(velocity.y) > abs(velocity.x)
      }
      return true
    }
    pipPan.delegate = gestureHelper
    exposurePan.delegate = gestureHelper

    let swipeLeft = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
    swipeLeft.direction = .left
    let swipeRight = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
    swipeRight.direction = .right
    for swipe in [swipeLeft, swipeRight] {
      swipe.require(toFail: pipPan)
      swipe.require(toFail: exposurePan)
    }

    for recognizer in [tap, pinch, pipPan, exposurePan, swipeLeft, swipeRight] as [UIGestureRecognizer] {
      addGestureRecognizer(recognizer)
    }
  }

  /// Boutons de volume = déclencheur (comme l'app Appareil photo).
  private func setUpHardwareButtons() {
    if #available(iOS 17.2, *) {
      let interaction = AVCaptureEventInteraction { [weak self] event in
        if event.phase == .ended {
          self?.onShutterButton([:])
        }
      }
      addInteraction(interaction)
    }
  }

  private func side(at point: CGPoint) -> DualCameraSide {
    if let single = captureMode.singleSide { return single }
    if let small = composition.smallSide {
      if previewLayer(for: small).frame.contains(point) { return small }
      return small == .front ? .back : .front
    }
    return frontLayer.frame.contains(point) ? .front : .back
  }

  @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
    let point = recognizer.location(in: self)
    let tappedSide = side(at: point)
    let preview = previewLayer(for: tappedSide)
    let layerPoint = preview.convert(point, from: layer)
    let devicePoint = preview.captureDevicePointConverted(fromLayerPoint: layerPoint)
    DualCameraController.shared.focus(tappedSide, at: devicePoint)
    onExposureChange(["bias": 0.0])
    let small = captureMode.isDual && composition.smallSide == tappedSide
    showFocus(at: point, small: small)
    UISelectionFeedbackGenerator().selectionChanged()
  }

  private func showFocus(at point: CGPoint, small: Bool) {
    let size: CGFloat = small ? 50 : 80
    focusPoint = point
    focusSquare.removeAllAnimations()

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    focusSquare.bounds = CGRect(x: 0, y: 0, width: size, height: size)
    focusSquare.path = focusSquarePath(size: size).cgPath
    focusSquare.position = point
    focusSquare.opacity = 1
    sunLine.opacity = 0
    sunLayer.opacity = 1
    CATransaction.commit()
    positionSun(bias: 0)

    let scale = CABasicAnimation(keyPath: "transform.scale")
    scale.fromValue = 1.5
    scale.toValue = 1.0
    scale.duration = 0.25
    focusSquare.add(scale, forKey: "scale")

    scheduleFocusDim()
  }

  /// Carré avec des petits traits au milieu de chaque côté.
  private func focusSquarePath(size: CGFloat) -> UIBezierPath {
    let path = UIBezierPath(rect: CGRect(x: 0, y: 0, width: size, height: size))
    let tick: CGFloat = 6
    let mid = size / 2
    path.move(to: CGPoint(x: mid, y: 0)); path.addLine(to: CGPoint(x: mid, y: tick))
    path.move(to: CGPoint(x: mid, y: size)); path.addLine(to: CGPoint(x: mid, y: size - tick))
    path.move(to: CGPoint(x: 0, y: mid)); path.addLine(to: CGPoint(x: tick, y: mid))
    path.move(to: CGPoint(x: size, y: mid)); path.addLine(to: CGPoint(x: size - tick, y: mid))
    return path
  }

  private func positionSun(bias: Float) {
    guard let point = focusPoint else { return }
    let half = focusSquare.bounds.width / 2
    let x = min(point.x + half + 18, bounds.maxX - 14)
    let range: CGFloat = 60
    let y = point.y - CGFloat(bias / 2) * range
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    sunLayer.position = CGPoint(x: x, y: y)
    let line = UIBezierPath()
    line.move(to: CGPoint(x: x, y: point.y - range - 14))
    line.addLine(to: CGPoint(x: x, y: point.y + range + 14))
    sunLine.path = line.cgPath
    CATransaction.commit()
  }

  private func scheduleFocusDim() {
    focusHideWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self = self else { return }
      CATransaction.begin()
      CATransaction.setAnimationDuration(0.4)
      self.focusSquare.opacity = 0.4
      self.sunLayer.opacity = 0.4
      self.sunLine.opacity = 0
      CATransaction.commit()
      let hide = DispatchWorkItem { [weak self] in self?.hideFocus(animated: true) }
      self.focusHideWork = hide
      DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: hide)
    }
    focusHideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
  }

  private func hideFocus(animated: Bool) {
    focusHideWork?.cancel()
    focusPoint = nil
    CATransaction.begin()
    if animated { CATransaction.setAnimationDuration(0.4) } else { CATransaction.setDisableActions(true) }
    focusSquare.opacity = 0
    sunLayer.opacity = 0
    sunLine.opacity = 0
    CATransaction.commit()
  }

  @objc private func handleExposurePan(_ recognizer: UIPanGestureRecognizer) {
    let controller = DualCameraController.shared
    switch recognizer.state {
    case .began:
      exposureStart = controller.exposureBias()
      focusHideWork?.cancel()
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      focusSquare.opacity = 1
      sunLayer.opacity = 1
      sunLine.opacity = 1
      CATransaction.commit()
    case .changed:
      let delta = Float(-recognizer.translation(in: self).y / 75)
      let bias = controller.setExposureBias(exposureStart + delta)
      positionSun(bias: bias)
      onExposureChange(["bias": Double(bias)])
    default:
      CATransaction.begin()
      CATransaction.setAnimationDuration(0.3)
      sunLine.opacity = 0
      CATransaction.commit()
      scheduleFocusDim()
    }
  }

  @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
    let controller = DualCameraController.shared
    switch recognizer.state {
    case .began:
      pinchSide = side(at: recognizer.location(in: self))
      pinchStartZoom = controller.displayZoom(for: pinchSide)
    case .changed:
      let zoom = controller.setZoom(pinchSide, display: pinchStartZoom * recognizer.scale, animated: false)
      onZoomChange(["camera": pinchSide.rawValue, "zoom": Double(zoom)])
    default:
      break
    }
  }

  @objc private func handlePipPan(_ recognizer: UIPanGestureRecognizer) {
    guard let small = composition.smallSide else { return }
    let preview = previewLayer(for: small)

    switch recognizer.state {
    case .began:
      dragRect = preview.frame
    case .changed:
      guard var rect = dragRect else { return }
      let translation = recognizer.translation(in: self)
      recognizer.setTranslation(.zero, in: self)
      rect.origin.x = max(bounds.minX, min(rect.origin.x + translation.x, bounds.maxX - rect.width))
      rect.origin.y = max(bounds.minY, min(rect.origin.y + translation.y, bounds.maxY - rect.height))
      dragRect = rect
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      preview.frame = rect
      CATransaction.commit()
    default:
      guard let rect = dragRect else { return }
      let velocity = recognizer.velocity(in: self)
      let target = CGPoint(x: rect.midX + velocity.x * 0.15, y: rect.midY + velocity.y * 0.15)
      pipCorner = DualCameraGeometry.nearestCorner(to: target, in: bounds)
      dragRect = nil
      updateComposition(animated: true)
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
  }

  @objc private func handleSwipe(_ recognizer: UISwipeGestureRecognizer) {
    onSwipe(["direction": recognizer.direction == .left ? "left" : "right"])
  }
}

/// Petit délégué séparé : décide si un geste a le droit de commencer.
private final class GestureHelper: NSObject, UIGestureRecognizerDelegate {
  var shouldBegin: ((UIGestureRecognizer) -> Bool)?

  func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    return shouldBegin?(gestureRecognizer) ?? true
  }
}
