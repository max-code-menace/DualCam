import AVFoundation
import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers

/// Erreurs renvoyées à JavaScript (le message est affiché tel quel à l'utilisateur).
enum DualCameraError: LocalizedError {
  case notSupported
  case cameraUnavailable(String)
  case configurationFailed(String)
  case notRunning
  case captureFailed(String)
  case photoLibraryDenied
  case saveFailed(String)
  case recordingFailed(String)

  var errorDescription: String? {
    switch self {
    case .notSupported:
      return "Cet iPhone ne permet pas d'utiliser les deux caméras en même temps."
    case .cameraUnavailable(let which):
      return "La caméra \(which) est introuvable."
    case .configurationFailed(let detail):
      return "Impossible de démarrer la caméra : \(detail)"
    case .notRunning:
      return "La caméra n'est pas encore prête."
    case .captureFailed(let detail):
      return "La photo a échoué : \(detail)"
    case .photoLibraryDenied:
      return "L'accès aux Photos est refusé. Autorisez-le dans Réglages > DualCam."
    case .saveFailed(let detail):
      return "Impossible d'enregistrer : \(detail)"
    case .recordingFailed(let detail):
      return "La vidéo a échoué : \(detail)"
    }
  }
}

/// Disposition du mode Duo (aperçu et photo finale).
enum DualCameraLayout: String {
  case stack  // une caméra en haut, l'autre en bas
  case side   // une caméra à gauche, l'autre à droite
  case pip    // une caméra en plein écran, l'autre en petite incrustation
}

/// Quelle caméra.
enum DualCameraSide: String {
  case back
  case front

  var position: AVCaptureDevice.Position { self == .back ? .back : .front }
}

/// Ce que fait la caméra en ce moment.
enum CaptureMode: Equatable {
  case dual
  case photo(DualCameraSide)
  case video(DualCameraSide)
  /// Ralenti : vidéo filmée à 120 ou 240 images par seconde.
  case slowmo(DualCameraSide)

  var isDual: Bool { self == .dual }
  /// true pour tout ce qui filme (Vidéo et Ralenti).
  var isVideo: Bool {
    switch self {
    case .video, .slowmo: return true
    case .dual, .photo: return false
    }
  }
  var isSlowMotion: Bool { if case .slowmo = self { return true } else { return false } }
  var singleSide: DualCameraSide? {
    switch self {
    case .dual: return nil
    case .photo(let side), .video(let side), .slowmo(let side): return side
    }
  }
}

/// Coin où se trouve la petite fenêtre en mode incrustation.
enum PipCorner: Int {
  case topLeft, topRight, bottomLeft, bottomRight
}

/// Réglages d'une photo, envoyés par JavaScript.
struct PhotoRequest {
  var flash: AVCaptureDevice.FlashMode = .auto
  var live = true
  /// Largeur ÷ hauteur voulue en portrait : 3/4, 9/16 ou 1.
  var aspect: CGFloat = 3.0 / 4.0
  /// Mégapixels voulus : 12, 24 ou 48.
  var megapixels: Int = 24
  var heif = true
  /// Mode nuit : durée de pose annoncée à l'écran (0 = pas de mode nuit).
  var nightSeconds = 0
  /// true une fois la pose longue réglée sur la caméra.
  var nightPrepared = false
}

/// Ce qu'on renvoie après une photo ou une vidéo.
struct CaptureResult {
  let thumbnailURL: URL
}

/// Tout ce qui décide de la mise en page du mode Duo : partagé entre l'aperçu et la photo finale.
struct DualCameraComposition {
  var layout: DualCameraLayout = .stack
  /// false : avant en haut / avant en petit. true : l'inverse.
  var swapped: Bool = false
  var pipCorner: PipCorner = .topLeft

  /// La caméra affichée en petit (mode incrustation seulement).
  var smallSide: DualCameraSide? {
    guard layout == .pip else { return nil }
    return swapped ? .back : .front
  }
}

/// Géométrie du mode Duo, partagée entre l'aperçu et la photo finale.
enum DualCameraGeometry {
  /// Rapport largeur / hauteur de la zone caméra (portrait 3:4).
  static let canvasAspect: CGFloat = 3.0 / 4.0

  static func smallRect(in bounds: CGRect, corner: PipCorner) -> CGRect {
    let margin = bounds.width * 0.04
    let width = bounds.width * 0.32
    let height = width * 4.0 / 3.0
    let left = corner == .topLeft || corner == .bottomLeft
    let top = corner == .topLeft || corner == .topRight
    let x = left ? bounds.minX + margin : bounds.maxX - margin - width
    let y = top ? bounds.minY + margin : bounds.maxY - margin - height
    return CGRect(x: x, y: y, width: width, height: height)
  }

  static func nearestCorner(to point: CGPoint, in bounds: CGRect) -> PipCorner {
    let left = point.x < bounds.midX
    let top = point.y < bounds.midY
    switch (top, left) {
    case (true, true): return .topLeft
    case (true, false): return .topRight
    case (false, true): return .bottomLeft
    case (false, false): return .bottomRight
    }
  }

  /// Rectangles de la caméra avant et de la caméra arrière.
  static func rects(in bounds: CGRect, _ c: DualCameraComposition) -> (front: CGRect, back: CGRect) {
    switch c.layout {
    case .stack:
      let top = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height / 2)
      let bottom = CGRect(x: bounds.minX, y: bounds.midY, width: bounds.width, height: bounds.height / 2)
      return c.swapped ? (front: bottom, back: top) : (front: top, back: bottom)
    case .side:
      let left = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width / 2, height: bounds.height)
      let right = CGRect(x: bounds.midX, y: bounds.minY, width: bounds.width / 2, height: bounds.height)
      return c.swapped ? (front: right, back: left) : (front: left, back: right)
    case .pip:
      let small = smallRect(in: bounds, corner: c.pipCorner)
      return c.swapped ? (front: bounds, back: small) : (front: small, back: bounds)
    }
  }

  static func pipCornerRadius(for rect: CGRect) -> CGFloat {
    return rect.width * 0.08
  }
}

/// Gère la caméra de l'app :
/// - mode Duo : une AVCaptureMultiCamSession (arrière + avant en même temps) ;
/// - modes Photo et Vidéo : une AVCaptureSession classique sur une seule caméra (pleine qualité).
final class DualCameraController: NSObject {
  static let shared = DualCameraController()

  private let sessionQueue = DispatchQueue(label: "dualcam.session")

  /// Qualité vidéo demandée par l'écran : 1080 (HD) ou 2160 (4K), et images par seconde.
  var videoHeight: Int32 = 1080
  var videoFps: Int = 30
  /// Ralenti : images par seconde demandées (120 ou 240).
  var slowMotionFps: Int = 240
  /// Qualité vidéo réellement appliquée.
  private var appliedVideo: (height: Int32, fps: Int) = (1080, 30)

  /// Appelé (thread principal) quand il fait sombre : (mode nuit conseillé, secondes de pose).
  var onLowLight: ((Bool, Int) -> Void)?
  private var nightTimer: DispatchSourceTimer?
  private var nightOn = false
  private var nightSeconds = 0

  /// Appelé (thread principal) si iOS arrête la caméra : message à afficher.
  var onRuntimeError: ((String) -> Void)?
  /// Appelé (thread principal) quand la caméra peut repartir (fin d'interruption, services média relancés).
  var onResume: (() -> Void)?

  private override init() {
    super.init()
    NotificationCenter.default.addObserver(
      forName: AVCaptureSession.runtimeErrorNotification, object: nil, queue: .main
    ) { [weak self] note in
      let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
      // Les services média d'iOS ont redémarré : on relance simplement la caméra.
      if error?.code == .mediaServicesWereReset {
        self?.onResume?()
        return
      }
      self?.onRuntimeError?("La caméra s'est arrêtée : \(error?.localizedDescription ?? "erreur inconnue.")")
    }
    NotificationCenter.default.addObserver(
      forName: AVCaptureSession.wasInterruptedNotification, object: nil, queue: .main
    ) { [weak self] note in
      let reason = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue ?? 0
      if let message = DualCameraController.interruptionMessage(reason) {
        self?.onRuntimeError?(message)
      }
    }
    NotificationCenter.default.addObserver(
      forName: AVCaptureSession.interruptionEndedNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.onResume?()
    }
    // Fichiers temporaires laissés par une session précédente (miniatures, vidéos non enregistrées).
    sessionQueue.async { DualCameraController.removeOldTemporaryFiles() }
    startNightWatch()
  }

  /// Message affiché quand iOS met la caméra en pause (nil = rien à dire).
  private static func interruptionMessage(_ reason: Int) -> String? {
    switch reason {
    case 1: return nil  // app en arrière-plan : normal
    case 2: return "Le micro est utilisé par une autre app (un appel ?). La vidéo reprendra ensuite."
    case 3: return "La caméra est utilisée par une autre app."
    case 4: return "La caméra n'est pas disponible quand plusieurs apps sont ouvertes à l'écran."
    case 5: return "L'iPhone est trop chaud : la caméra fait une pause."
    default: return "La caméra est momentanément indisponible."
    }
  }

  static func removeOldTemporaryFiles() {
    let directory = FileManager.default.temporaryDirectory
    guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
      return
    }
    for file in files where file.lastPathComponent.hasPrefix("dualcam-") {
      try? FileManager.default.removeItem(at: file)
    }
  }

  // Mode Duo
  /// La session Duo n'existe que pendant le mode Duo : hors de ce mode, elle est détruite
  /// pour ne jamais gêner la caméra simple.
  private var multiSessionStorage: AVCaptureMultiCamSession?
  private var multiSession: AVCaptureMultiCamSession {
    if let existing = multiSessionStorage { return existing }
    let created = AVCaptureMultiCamSession()
    multiSessionStorage = created
    return created
  }
  private let backPhotoOutput = AVCapturePhotoOutput()
  private let frontPhotoOutput = AVCapturePhotoOutput()
  private(set) var backDevice: AVCaptureDevice? {
    get { locked { _backDevice } }
    set { locked { _backDevice = newValue } }
  }
  private(set) var frontDevice: AVCaptureDevice? {
    get { locked { _frontDevice } }
    set { locked { _frontDevice = newValue } }
  }
  private var dualConfigured = false

  // Modes Photo / Vidéo
  private let singleSession = AVCaptureSession()
  private let singlePhotoOutput = AVCapturePhotoOutput()
  private let movieOutput = AVCaptureMovieFileOutput()
  private var singleInput: AVCaptureDeviceInput?
  private var audioInput: AVCaptureDeviceInput?
  private(set) var singleDevice: AVCaptureDevice? {
    get { locked { _singleDevice } }
    set { locked { _singleDevice = newValue } }
  }
  private var rotationCoordinator: AnyObject?

  // Lu depuis le fil principal (zoom, mise au point) et écrit par la file de la caméra.
  private let stateLock = NSLock()
  private var _mode: CaptureMode?
  private var _backDevice: AVCaptureDevice?
  private var _frontDevice: AVCaptureDevice?
  private var _singleDevice: AVCaptureDevice?
  private func locked<T>(_ body: () -> T) -> T {
    stateLock.lock()
    defer { stateLock.unlock() }
    return body()
  }

  private(set) var mode: CaptureMode? {
    get { locked { _mode } }
    set { locked { _mode = newValue } }
  }
  private var inFlightDelegates: [ObjectIdentifier: NSObject] = [:]
  /// true pendant une photo Duo ou une photo en mode nuit (une seule à la fois).
  private var isCapturing = false
  /// Photos simples en cours (on peut en enchaîner plusieurs, comme l'app Appareil photo).
  private var singleInFlight = 0
  private var movieDelegate: MovieRecordingDelegate?
  private var pendingStop: ((Result<CaptureResult, Error>) -> Void)?
  private var subjectObservers: [NSObjectProtocol] = []
  /// Dernière caméra touchée pour la mise au point (sert pour l'exposition).
  private var focusedSide: DualCameraSide = .back

  private let compositionLock = NSLock()
  private var storedComposition = DualCameraComposition()
  /// Mise en page actuelle du mode Duo (écrite par la vue, lue au moment de la photo).
  var composition: DualCameraComposition {
    get {
      compositionLock.lock()
      defer { compositionLock.unlock() }
      return storedComposition
    }
    set {
      compositionLock.lock()
      storedComposition = newValue
      compositionLock.unlock()
    }
  }

  /// Session à brancher sur l'aperçu des modes Photo / Vidéo.
  var singleCaptureSession: AVCaptureSession { singleSession }

  static var isSupported: Bool {
    return AVCaptureMultiCamSession.isMultiCamSupported
  }

  var isRecording: Bool { movieOutput.isRecording }

  // MARK: - Activation d'un mode

  /// Passe dans `mode` (configure et démarre la bonne session).
  /// `completion` est appelé sur le thread principal avec les infos de la caméra.
  func activate(_ newMode: CaptureMode,
                backLayer: AVCaptureVideoPreviewLayer,
                frontLayer: AVCaptureVideoPreviewLayer,
                singleLayer: AVCaptureVideoPreviewLayer,
                completion: @escaping (Result<[String: Any], Error>) -> Void) {
    if newMode.isDual && !DualCameraController.isSupported {
      completion(.failure(DualCameraError.notSupported))
      return
    }
    sessionQueue.async {
      do {
        if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
        switch newMode {
        case .dual:
          if self.singleSession.isRunning { self.singleSession.stopRunning() }
          if !self.dualConfigured || self.mode != .dual {
            try self.configureDual(backLayer: backLayer, frontLayer: frontLayer)
          }
          if !self.multiSession.isRunning { self.multiSession.startRunning() }
          guard self.multiSession.isRunning else {
            throw DualCameraError.configurationFailed("la caméra n'a pas démarré.")
          }
          self.observeSubjectArea([self.backDevice, self.frontDevice])
        case .photo(let side), .video(let side), .slowmo(let side):
          if let multi = self.multiSessionStorage {
            if multi.isRunning { multi.stopRunning() }
            backLayer.session = nil
            frontLayer.session = nil
            self.multiSessionStorage = nil
            self.dualConfigured = false
            self.backDevice = nil
            self.frontDevice = nil
          }
          try self.configureSingle(side: side, video: newMode.isVideo, slowMotion: newMode.isSlowMotion)
          // L'aperçu est branché maintenant que la caméra est dans la session.
          try self.connectPreview(singleLayer)
          // Changer de qualité remet le zoom à zéro : on revient à 1× une fois la configuration finie.
          if let device = self.singleDevice { self.setInitialZoom(device) }
          // Ralenti : on confirme la vitesse une fois la session réglée (iOS peut la remettre à zéro).
          if newMode.isSlowMotion, let device = self.singleDevice {
            self.lockFrameRate(device, fps: self.appliedVideo.fps)
          }
          if !self.singleSession.isRunning { self.singleSession.startRunning() }
          guard self.singleSession.isRunning else {
            throw DualCameraError.configurationFailed("la caméra n'a pas démarré.")
          }
          self.observeSubjectArea([self.singleDevice])
        }
        self.mode = newMode
        self.focusedSide = newMode.singleSide ?? .back
        let info = self.cameraInfo()
        DispatchQueue.main.async { completion(.success(info)) }
      } catch {
        DispatchQueue.main.async { completion(.failure(error)) }
      }
    }
  }

  /// Appelle `done` (fil principal) quand la caméra a fini sa mise au point et son exposition,
  /// pour que l'écran passe directement à une image nette (0,6 seconde d'attente au plus).
  func whenSettled(_ done: @escaping () -> Void) {
    let start = CACurrentMediaTime()
    func check() {
      let elapsed = CACurrentMediaTime() - start
      let devices: [AVCaptureDevice]
      if self.mode == .dual {
        devices = [self.backDevice, self.frontDevice].compactMap { $0 }
      } else {
        devices = [self.singleDevice].compactMap { $0 }
      }
      let busy = devices.contains { $0.isAdjustingFocus || $0.isAdjustingExposure }
      if elapsed >= 0.6 || (elapsed >= 0.12 && !busy) {
        DispatchQueue.main.async(execute: done)
        return
      }
      self.sessionQueue.asyncAfter(deadline: .now() + 0.04) { check() }
    }
    sessionQueue.async { check() }
  }

  func stop() {
    sessionQueue.async {
      if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
      if let multi = self.multiSessionStorage, multi.isRunning { multi.stopRunning() }
      if self.singleSession.isRunning { self.singleSession.stopRunning() }
    }
  }

  /// Infos utiles à l'écran (zoom, flash, Live, résolutions…).
  private func cameraInfo() -> [String: Any] {
    let zoomSide: DualCameraSide = mode?.singleSide ?? .back
    let range = zoomRange(for: zoomSide)
    var hasFlash = false
    var liveSupported = false
    var resolutions: [Int] = []
    switch mode {
    case .dual?:
      hasFlash = backPhotoOutput.supportedFlashModes.contains(.on)
    case .photo?:
      hasFlash = singlePhotoOutput.supportedFlashModes.contains(.on)
      liveSupported = singlePhotoOutput.isLivePhotoCaptureEnabled
      resolutions = availableMegapixels()
    case .video?, .slowmo?:
      hasFlash = singleDevice?.hasTorch ?? false
    case nil:
      break
    }
    let biasDevice = device(for: focusedSide)
    var options: [[String: Any]] = []
    if case .slowmo(let side)? = mode {
      options = slowMotionOptions(for: side)
    } else if mode?.isVideo == true {
      options = videoOptions()
    }
    return [
      "videoOptions": options,
      "videoResolution": appliedVideo.height == 2160 ? "4K" : "HD",
      "videoFps": appliedVideo.fps,
      "hasUltraWide": range.min < 0.99,
      "hasFlash": hasFlash,
      "liveSupported": liveSupported,
      "resolutions": resolutions,
      "zoom": Double(displayZoom(for: zoomSide)),
      "minZoom": Double(range.min),
      "maxZoom": Double(range.max),
      "minBias": Double(max(-2, biasDevice?.minExposureTargetBias ?? 0)),
      "maxBias": Double(min(2, biasDevice?.maxExposureTargetBias ?? 0))
    ]
  }

  // MARK: - Configuration du mode Duo

  private func configureDual(backLayer: AVCaptureVideoPreviewLayer,
                             frontLayer: AVCaptureVideoPreviewLayer) throws {
    // On essaie d'abord la caméra arrière « double » (ultra grand-angle + grand-angle,
    // pour le zoom 0,5×). Si l'iPhone refuse en multi-caméra, on prend la grand-angle seule.
    do {
      try configureDual(backLayer: backLayer, frontLayer: frontLayer, backType: .builtInDualWideCamera)
    } catch {
      try configureDual(backLayer: backLayer, frontLayer: frontLayer, backType: .builtInWideAngleCamera)
    }
    if let back = backDevice {
      setInitialZoom(back)
    }
  }

  private func configureDual(backLayer: AVCaptureVideoPreviewLayer,
                             frontLayer: AVCaptureVideoPreviewLayer,
                             backType: AVCaptureDevice.DeviceType) throws {
    let session = multiSession
    // On repart de zéro à chaque fois.
    session.beginConfiguration()
    for connection in session.connections { session.removeConnection(connection) }
    for input in session.inputs { session.removeInput(input) }
    for output in session.outputs { session.removeOutput(output) }
    dualConfigured = false
    backDevice = nil
    frontDevice = nil

    do {
      backDevice = try addDualCamera(position: .back, deviceType: backType, photoOutput: backPhotoOutput,
                                     previewLayer: backLayer, mirrored: false)
      frontDevice = try addDualCamera(position: .front, deviceType: .builtInWideAngleCamera,
                                      photoOutput: frontPhotoOutput, previewLayer: frontLayer, mirrored: true)
    } catch {
      session.commitConfiguration()
      throw error
    }
    session.commitConfiguration()

    // Si le matériel est trop sollicité, on baisse la résolution et on réessaie.
    if session.hardwareCost > 1.0 {
      session.beginConfiguration()
      for input in session.inputs {
        if let deviceInput = input as? AVCaptureDeviceInput {
          try? selectMultiCamFormat(for: deviceInput.device, maxWidth: 1280)
        }
      }
      session.commitConfiguration()
    }
    if session.hardwareCost > 1.0 {
      throw DualCameraError.configurationFailed("le matériel est trop sollicité (coût \(session.hardwareCost)).")
    }
    dualConfigured = true
  }

  private func addDualCamera(position: AVCaptureDevice.Position,
                             deviceType: AVCaptureDevice.DeviceType,
                             photoOutput: AVCapturePhotoOutput,
                             previewLayer: AVCaptureVideoPreviewLayer,
                             mirrored: Bool) throws -> AVCaptureDevice {
    let session = multiSession
    let label = position == .front ? "avant" : "arrière"
    guard let device = AVCaptureDevice.default(deviceType, for: .video, position: position) else {
      throw DualCameraError.cameraUnavailable(label)
    }

    // 1. Entrée SANS connexion automatique.
    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input) else {
      throw DualCameraError.configurationFailed("entrée \(label) refusée.")
    }
    session.addInputWithNoConnections(input)

    // 2. Format compatible multi-caméra (isMultiCamSupported).
    try selectMultiCamFormat(for: device, maxWidth: 1920)

    guard let port = input.ports(for: .video,
                                 sourceDeviceType: device.deviceType,
                                 sourceDevicePosition: device.position).first else {
      throw DualCameraError.configurationFailed("port vidéo \(label) introuvable.")
    }

    // 3. Sortie photo + connexion manuelle.
    guard session.canAddOutput(photoOutput) else {
      throw DualCameraError.configurationFailed("sortie photo \(label) refusée.")
    }
    session.addOutputWithNoConnections(photoOutput)
    let photoConnection = AVCaptureConnection(inputPorts: [port], output: photoOutput)
    guard session.canAddConnection(photoConnection) else {
      throw DualCameraError.configurationFailed("connexion photo \(label) refusée.")
    }
    session.addConnection(photoConnection)
    DualCameraController.setPortrait(photoConnection)
    // Le miroir de la photo avant est appliqué au moment de la fusion (côté dessin).
    if photoConnection.isVideoMirroringSupported {
      photoConnection.automaticallyAdjustsVideoMirroring = false
      photoConnection.isVideoMirrored = false
    }

    // 4. Aperçu + connexion manuelle vers le calque.
    previewLayer.setSessionWithNoConnection(session)
    let previewConnection = AVCaptureConnection(inputPort: port, videoPreviewLayer: previewLayer)
    guard session.canAddConnection(previewConnection) else {
      throw DualCameraError.configurationFailed("connexion aperçu \(label) refusée.")
    }
    session.addConnection(previewConnection)
    DualCameraController.setPortrait(previewConnection)
    if previewConnection.isVideoMirroringSupported {
      previewConnection.automaticallyAdjustsVideoMirroring = false
      previewConnection.isVideoMirrored = mirrored
    }
    return device
  }

  /// Choisit le plus grand format 4:3 compatible multi-caméra dont la largeur ne dépasse pas `maxWidth`.
  private func selectMultiCamFormat(for device: AVCaptureDevice, maxWidth: Int32) throws {
    let candidates = device.formats.filter { format in
      let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
      return format.isMultiCamSupported && dims.width <= maxWidth
    }
    func score(_ format: AVCaptureDevice.Format) -> (Int, Int32) {
      let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
      let isFourThree = abs(Double(dims.width) / Double(dims.height) - 4.0 / 3.0) < 0.01
      return (isFourThree ? 1 : 0, dims.width * dims.height)
    }
    guard let best = candidates.max(by: { score($0) < score($1) }) else {
      throw DualCameraError.configurationFailed("aucun format multi-caméra disponible.")
    }
    try device.lockForConfiguration()
    device.activeFormat = best
    // Quand il fait sombre : iOS peut éclaircir l'image, et ralentir à 15 images par seconde
    // pour laisser entrer deux fois plus de lumière.
    if device.isLowLightBoostSupported {
      device.automaticallyEnablesLowLightBoostWhenAvailable = true
    }
    let canSlowDown = best.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 15 && $0.maxFrameRate >= 15 }
    if canSlowDown {
      device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 15)
    }
    device.unlockForConfiguration()
  }

  static func setPortrait(_ connection: AVCaptureConnection) {
    if #available(iOS 17.0, *) {
      if connection.isVideoRotationAngleSupported(90) {
        connection.videoRotationAngle = 90
      }
    } else if connection.isVideoOrientationSupported {
      connection.videoOrientation = .portrait
    }
  }

  // MARK: - Configuration des modes Photo / Vidéo

  private func bestDevice(for side: DualCameraSide) -> AVCaptureDevice? {
    let types: [AVCaptureDevice.DeviceType] = side == .back
      ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
      : [.builtInTrueDepthCamera, .builtInWideAngleCamera]
    let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: side.position)
    for type in types {
      if let device = discovery.devices.first(where: { $0.deviceType == type }) {
        return device
      }
    }
    return nil
  }

  private func configureSingle(side: DualCameraSide, video: Bool, slowMotion: Bool) throws {
    let session = singleSession
    let label = side == .front ? "avant" : "arrière"
    let found = slowMotion
      ? (slowMotionDevice(for: side, fps: slowMotionFps) ?? slowMotionDevice(for: side, fps: 120))
      : bestDevice(for: side)
    guard let device = found else {
      if slowMotion {
        throw DualCameraError.configurationFailed("le ralenti n'est pas disponible sur la caméra \(label).")
      }
      throw DualCameraError.cameraUnavailable(label)
    }

    session.beginConfiguration()
    defer { session.commitConfiguration() }

    // Après le mode Duo, la caméra garde un format réduit : on la rebranche
    // pour retrouver la pleine qualité.
    if mode == .dual, let old = singleInput {
      session.removeInput(old)
      singleInput = nil
    }

    // Caméra
    if singleInput?.device != device {
      if let old = singleInput { session.removeInput(old) }
      singleInput = nil
      let input = try AVCaptureDeviceInput(device: device)
      guard session.canAddInput(input) else {
        throw DualCameraError.configurationFailed("entrée \(label) refusée.")
      }
      session.addInput(input)
      singleInput = input
      singleDevice = device
      if #available(iOS 17.0, *) {
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
      }
    }

    // Qualité : photo pleine résolution, ou vidéo au format choisi (HD / 4K, images par seconde)
    if slowMotion {
      // Ralenti : 240 images par seconde si possible, sinon 120.
      var fps = slowMotionFps
      if slowMotionFormat(for: device, fps: fps) == nil { fps = 120 }
      guard let format = slowMotionFormat(for: device, fps: fps) else {
        throw DualCameraError.configurationFailed("le ralenti n'est pas disponible sur la caméra \(label).")
      }
      try device.lockForConfiguration()
      device.activeFormat = format
      let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
      device.activeVideoMinFrameDuration = duration
      device.activeVideoMaxFrameDuration = duration
      device.unlockForConfiguration()
      appliedVideo = (CMVideoFormatDescriptionGetDimensions(format.formatDescription).height, fps)
    } else if video {
      var height = videoHeight
      var fps = videoFps
      var format = videoFormat(for: device, height: height, fps: fps)
      if format == nil {
        height = 1080
        fps = 30
        format = videoFormat(for: device, height: height, fps: fps)
      }
      if let format = format {
        try device.lockForConfiguration()
        device.activeFormat = format
        let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()
        appliedVideo = (height, fps)
      } else {
        let preset: AVCaptureSession.Preset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
        if session.sessionPreset != preset && session.canSetSessionPreset(preset) {
          session.sessionPreset = preset
        }
        appliedVideo = (1080, 30)
      }
    } else if session.sessionPreset != .photo && session.canSetSessionPreset(.photo) {
      session.sessionPreset = .photo
    }

    // Sortie photo (Photo et Vidéo). Pas en Ralenti : elle pourrait limiter la vitesse de la caméra.
    if slowMotion {
      if session.outputs.contains(singlePhotoOutput) { session.removeOutput(singlePhotoOutput) }
    } else if !session.outputs.contains(singlePhotoOutput) {
      guard session.canAddOutput(singlePhotoOutput) else {
        throw DualCameraError.configurationFailed("sortie photo refusée.")
      }
      session.addOutput(singlePhotoOutput)
    }

    // Sortie vidéo + micro (seulement en mode Vidéo)
    if video {
      if !session.outputs.contains(movieOutput) {
        guard session.canAddOutput(movieOutput) else {
          throw DualCameraError.configurationFailed("sortie vidéo refusée.")
        }
        session.addOutput(movieOutput)
      }
      if audioInput == nil,
         AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
         let mic = AVCaptureDevice.default(for: .audio),
         let input = try? AVCaptureDeviceInput(device: mic),
         session.canAddInput(input) {
        session.addInput(input)
        audioInput = input
      }
    } else {
      if session.outputs.contains(movieOutput) { session.removeOutput(movieOutput) }
      if let mic = audioInput {
        session.removeInput(mic)
        audioInput = nil
      }
    }

    // Réglages de la sortie photo
    if session.outputs.contains(singlePhotoOutput) {
      singlePhotoOutput.isLivePhotoCaptureEnabled = !video && singlePhotoOutput.isLivePhotoCaptureSupported
      singlePhotoOutput.maxPhotoQualityPrioritization = .quality
      if let biggest = device.activeFormat.supportedMaxPhotoDimensions.max(by: { area($0) < area($1) }) {
        singlePhotoOutput.maxPhotoDimensions = biggest
      }
      // Ultra grand-angle (0,5×) : iOS redresse les bords déformés, comme l'app Appareil photo.
      if singlePhotoOutput.isContentAwareDistortionCorrectionSupported {
        singlePhotoOutput.isContentAwareDistortionCorrectionEnabled = true
      }
      // Déclenchement instantané, et photos enchaînées sans attendre la précédente.
      if #available(iOS 17.0, *) {
        if singlePhotoOutput.isZeroShutterLagSupported {
          singlePhotoOutput.isZeroShutterLagEnabled = true
        }
        if singlePhotoOutput.isResponsiveCaptureSupported {
          singlePhotoOutput.isResponsiveCaptureEnabled = true
        }
        if singlePhotoOutput.isFastCapturePrioritizationSupported {
          singlePhotoOutput.isFastCapturePrioritizationEnabled = true
        }
      }
    }

    // Portrait + miroir pour la caméra avant (comme l'app Appareil photo)
    for output in [singlePhotoOutput, movieOutput] as [AVCaptureOutput] where session.outputs.contains(output) {
      guard let connection = output.connection(with: .video) else { continue }
      DualCameraController.setPortrait(connection)
      if connection.isVideoMirroringSupported {
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = side == .front
      }
      if output === movieOutput {
        if connection.isVideoStabilizationSupported {
          connection.preferredVideoStabilizationMode = .auto
        }
        if movieOutput.availableVideoCodecTypes.contains(.hevc) {
          movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
        }
      }
    }
  }

  // MARK: - Mode nuit

  /// Calcule la pose longue adaptée à la lumière actuelle.
  /// `needed` mesure le manque de lumière (plus c'est grand, plus il fait sombre).
  private func nightPlan(for device: AVCaptureDevice) -> (needed: Double, duration: CMTime, iso: Float) {
    let format = device.activeFormat
    let nothing = (needed: 0.0, duration: format.minExposureDuration, iso: format.minISO)
    let current = CMTimeGetSeconds(device.exposureDuration) * Double(device.iso)
    let needed = current * pow(2.0, Double(-device.exposureTargetOffset))
    guard needed.isFinite, needed > 0 else { return nothing }

    // Un peu plus clair que l'aperçu, avec une sensibilité basse (moins de grain) et une pose plus longue.
    let target = needed * 1.3
    let minSeconds = CMTimeGetSeconds(format.minExposureDuration)
    let maxSeconds = min(CMTimeGetSeconds(format.maxExposureDuration), 3.0)
    guard minSeconds.isFinite, maxSeconds.isFinite, maxSeconds > minSeconds else { return nothing }
    var seconds = min(max(target / 300.0, 0.5), maxSeconds)
    var iso = target / seconds
    if iso < Double(format.minISO) {
      iso = Double(format.minISO)
      seconds = min(max(target / iso, minSeconds), maxSeconds)
    }
    let safeISO = min(max(Float(iso), format.minISO), format.maxISO)

    // La durée ne doit jamais sortir des limites de la caméra.
    var duration = CMTime(seconds: seconds, preferredTimescale: 1000)
    if CMTimeCompare(duration, format.maxExposureDuration) > 0 { duration = format.maxExposureDuration }
    if CMTimeCompare(duration, format.minExposureDuration) < 0 { duration = format.minExposureDuration }
    return (needed, duration, safeISO)
  }

  /// Surveille la lumière deux fois par seconde (mode Photo, caméra arrière).
  private func startNightWatch() {
    let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
    timer.schedule(deadline: .now() + 1, repeating: 0.5)
    timer.setEventHandler { [weak self] in self?.checkLowLight() }
    timer.resume()
    nightTimer = timer
  }

  private func checkLowLight() {
    // Pendant une photo, la caméra peut être en pose manuelle : on ne mesure rien.
    if isCapturing || singleInFlight > 0 { return }
    var on = false
    var seconds = 0
    if case .photo(let side)? = mode, side == .back, let device = singleDevice,
       singleSession.isRunning, device.exposureMode != .custom {
      let plan = nightPlan(for: device)
      // Deux seuils différents pour que la lune ne clignote pas.
      on = nightOn ? plan.needed > 14 : plan.needed > 24
      seconds = max(1, Int(CMTimeGetSeconds(plan.duration).rounded()))
    }
    if on != nightOn || (on && seconds != nightSeconds) {
      nightOn = on
      nightSeconds = seconds
      let active = on
      let pose = seconds
      DispatchQueue.main.async { self.onLowLight?(active, pose) }
    }
  }

  private func restoreAutoExposure() {
    guard let device = singleDevice else { return }
    do {
      try device.lockForConfiguration()
      if device.isExposureModeSupported(.continuousAutoExposure) {
        device.exposureMode = .continuousAutoExposure
      }
      device.unlockForConfiguration()
    } catch {}
  }

  /// Format vidéo de la caméra pour une taille (1080 ou 2160) et un nombre d'images par seconde.
  private func videoFormat(for device: AVCaptureDevice, height: Int32, fps: Int) -> AVCaptureDevice.Format? {
    let width: Int32 = height == 2160 ? 3840 : 1920
    let wanted = Double(fps)
    let candidates = device.formats.filter { format in
      let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
      guard dims.width == width && dims.height == height else { return false }
      return format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= wanted && wanted <= $0.maxFrameRate }
    }
    // On préfère le format vidéo standard, puis celui prévu pour cette vitesse (pas un format « ralenti »).
    func score(_ format: AVCaptureDevice.Format) -> (Int, Double) {
      let subType = CMFormatDescriptionGetMediaSubType(format.formatDescription)
      let standard = subType == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? 1 : 0
      let top = format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
      return (standard, -top)
    }
    return candidates.max(by: { score($0) < score($1) })
  }

  /// Choix proposés à l'écran : HD / 4K et les vitesses possibles pour chacun.
  private func videoOptions() -> [[String: Any]] {
    guard let device = singleDevice else { return [] }
    var result: [[String: Any]] = []
    let sizes: [(String, Int32)] = [("HD", 1080), ("4K", 2160)]
    for (label, height) in sizes {
      let rates = [24, 30, 60, 120].filter { videoFormat(for: device, height: height, fps: $0) != nil }
      if !rates.isEmpty {
        result.append(["resolution": label, "fps": rates])
      }
    }
    return result
  }

  // MARK: - Ralenti

  /// Format du ralenti : 1080p (sinon 720p) capable de filmer à `fps` images par seconde.
  private func slowMotionFormat(for device: AVCaptureDevice, fps: Int) -> AVCaptureDevice.Format? {
    let wanted = Double(fps)
    let candidates = device.formats.filter { format in
      let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
      let sizeOK = (dims.width == 1920 && dims.height == 1080) || (dims.width == 1280 && dims.height == 720)
      guard sizeOK else { return false }
      return format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= wanted && wanted <= $0.maxFrameRate }
    }
    // On préfère la plus grande taille, puis le format vidéo standard (8 bits).
    func score(_ format: AVCaptureDevice.Format) -> (Int, Int) {
      let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
      let subType = CMFormatDescriptionGetMediaSubType(format.formatDescription)
      let standard = subType == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? 1 : 0
      return (Int(dims.height), standard)
    }
    return candidates.max(by: { score($0) < score($1) })
  }

  /// Caméra qui sait filmer en ralenti à `fps` : la caméra habituelle si possible,
  /// sinon la grand-angle seule (certains iPhone ne proposent le 240 que sur elle).
  private func slowMotionDevice(for side: DualCameraSide, fps: Int) -> AVCaptureDevice? {
    var devices: [AVCaptureDevice] = []
    if let best = bestDevice(for: side) { devices.append(best) }
    if let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: side.position) {
      devices.append(wide)
    }
    return devices.first { slowMotionFormat(for: $0, fps: fps) != nil }
  }

  /// Choix proposés à l'écran pour le ralenti (120 et/ou 240).
  private func slowMotionOptions(for side: DualCameraSide) -> [[String: Any]] {
    let rates = [120, 240].filter { slowMotionDevice(for: side, fps: $0) != nil }
    if rates.isEmpty { return [] }
    return [["resolution": "HD", "fps": rates]]
  }

  /// Fixe la vitesse de la caméra (images par seconde).
  private func lockFrameRate(_ device: AVCaptureDevice, fps: Int) {
    let wanted = Double(fps)
    guard device.activeFormat.videoSupportedFrameRateRanges.contains(where: {
      $0.minFrameRate <= wanted && wanted <= $0.maxFrameRate
    }) else { return }
    do {
      try device.lockForConfiguration()
      let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
      device.activeVideoMinFrameDuration = duration
      device.activeVideoMaxFrameDuration = duration
      device.unlockForConfiguration()
    } catch {}
  }

  /// Relie l'aperçu des modes Photo / Vidéo à la caméra (et vérifie que c'est bien fait).
  private func connectPreview(_ previewLayer: AVCaptureVideoPreviewLayer) throws {
    let session = singleSession
    if previewLayer.session !== session {
      previewLayer.session = session
    }
    // Si iOS n'a pas fait le lien tout seul, on le crée à la main (comme en mode Duo).
    if previewLayer.connection == nil, let input = singleInput {
      let device = input.device
      if let port = input.ports(for: .video,
                                sourceDeviceType: device.deviceType,
                                sourceDevicePosition: device.position).first {
        session.beginConfiguration()
        let connection = AVCaptureConnection(inputPort: port, videoPreviewLayer: previewLayer)
        if session.canAddConnection(connection) {
          session.addConnection(connection)
        }
        session.commitConfiguration()
      }
    }
    guard previewLayer.connection != nil else {
      throw DualCameraError.configurationFailed("l'aperçu n'a pas pu être relié à la caméra.")
    }
  }

  private func area(_ dims: CMVideoDimensions) -> Int {
    return Int(dims.width) * Int(dims.height)
  }

  /// Résolutions possibles (12, 24, 48 Mpx) pour la caméra actuelle.
  private func availableMegapixels() -> [Int] {
    guard let device = singleDevice else { return [] }
    let supported = device.activeFormat.supportedMaxPhotoDimensions.map { area($0) }
    var result: [Int] = []
    for mp in [12, 24, 48] {
      if supported.contains(where: { abs($0 - mp * 1_000_000) < 4_000_000 }) {
        result.append(mp)
      }
    }
    return result
  }

  private func photoDimensions(megapixels: Int) -> CMVideoDimensions? {
    guard let device = singleDevice else { return nil }
    let maxArea = area(singlePhotoOutput.maxPhotoDimensions)
    let options = device.activeFormat.supportedMaxPhotoDimensions.filter { area($0) <= maxArea }
    let target = megapixels * 1_000_000
    return options.min(by: { abs(area($0) - target) < abs(area($1) - target) })
  }

  /// Angle pour que la photo soit droite même si on tient l'iPhone à l'horizontale.
  private func applyCaptureRotation(to connection: AVCaptureConnection?) {
    guard let connection = connection else { return }
    if #available(iOS 17.0, *), let coordinator = rotationCoordinator as? AVCaptureDevice.RotationCoordinator {
      let angle = coordinator.videoRotationAngleForHorizonLevelCapture
      if connection.isVideoRotationAngleSupported(angle) {
        connection.videoRotationAngle = angle
      }
    }
  }

  // MARK: - Zoom

  func device(for side: DualCameraSide) -> AVCaptureDevice? {
    switch mode {
    case .dual?:
      return side == .back ? backDevice : frontDevice
    case .photo(let current)?, .video(let current)?, .slowmo(let current)?:
      return current == side ? singleDevice : nil
    case nil:
      return nil
    }
  }

  /// Facteur matériel qui correspond à « 1× » (2 sur les caméras doubles/triples, sinon 1).
  private func wideFactor(for device: AVCaptureDevice) -> CGFloat {
    if let first = device.virtualDeviceSwitchOverVideoZoomFactors.first {
      return CGFloat(truncating: first)
    }
    return 1
  }

  private func setInitialZoom(_ device: AVCaptureDevice) {
    do {
      try device.lockForConfiguration()
      device.videoZoomFactor = wideFactor(for: device)
      device.unlockForConfiguration()
    } catch {}
  }

  /// Zoom affiché (0,5× ; 1× ; 2×…) minimum et maximum.
  func zoomRange(for side: DualCameraSide) -> (min: CGFloat, max: CGFloat) {
    guard let device = self.device(for: side) else { return (1, 1) }
    let wide = wideFactor(for: device)
    let maxFactor = min(device.maxAvailableVideoZoomFactor, device.activeFormat.videoMaxZoomFactor, wide * 10)
    return (device.minAvailableVideoZoomFactor / wide, maxFactor / wide)
  }

  func displayZoom(for side: DualCameraSide) -> CGFloat {
    guard let device = self.device(for: side) else { return 1 }
    return device.videoZoomFactor / wideFactor(for: device)
  }

  /// Règle le zoom (valeur affichée). Renvoie la valeur réellement appliquée.
  @discardableResult
  func setZoom(_ side: DualCameraSide, display: CGFloat, animated: Bool) -> CGFloat {
    guard let device = self.device(for: side) else { return 1 }
    let wide = wideFactor(for: device)
    let range = zoomRange(for: side)
    let clamped = max(range.min, min(display, range.max))
    do {
      try device.lockForConfiguration()
      if animated {
        device.ramp(toVideoZoomFactor: clamped * wide, withRate: 6)
      } else {
        device.cancelVideoZoomRamp()
        device.videoZoomFactor = clamped * wide
      }
      device.unlockForConfiguration()
    } catch {}
    return clamped
  }

  // MARK: - Mise au point et exposition

  /// Mise au point + exposition sur un point (coordonnées caméra 0…1).
  func focus(_ side: DualCameraSide, at devicePoint: CGPoint) {
    focusedSide = side
    guard let device = self.device(for: side) else { return }
    do {
      try device.lockForConfiguration()
      if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(.autoFocus) {
        device.focusPointOfInterest = devicePoint
        device.focusMode = .autoFocus
      }
      if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(.autoExpose) {
        device.exposurePointOfInterest = devicePoint
        device.exposureMode = .autoExpose
      }
      device.setExposureTargetBias(0, completionHandler: nil)
      // Quand la scène change, on revient en mise au point automatique.
      device.isSubjectAreaChangeMonitoringEnabled = true
      device.unlockForConfiguration()
    } catch {}
  }

  func exposureBias() -> Float {
    return device(for: focusedSide)?.exposureTargetBias ?? 0
  }

  /// Règle la luminosité (-2 … +2). Renvoie la valeur appliquée.
  @discardableResult
  func setExposureBias(_ value: Float) -> Float {
    guard let device = device(for: focusedSide) else { return 0 }
    let clamped = max(max(-2, device.minExposureTargetBias), min(value, min(2, device.maxExposureTargetBias)))
    do {
      try device.lockForConfiguration()
      device.setExposureTargetBias(clamped, completionHandler: nil)
      device.unlockForConfiguration()
    } catch {}
    return clamped
  }

  private func resetFocus(_ device: AVCaptureDevice) {
    do {
      try device.lockForConfiguration()
      let center = CGPoint(x: 0.5, y: 0.5)
      if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(.continuousAutoFocus) {
        device.focusPointOfInterest = center
        device.focusMode = .continuousAutoFocus
      }
      if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(.continuousAutoExposure) {
        device.exposurePointOfInterest = center
        device.exposureMode = .continuousAutoExposure
      }
      device.isSubjectAreaChangeMonitoringEnabled = false
      device.unlockForConfiguration()
    } catch {}
  }

  private func observeSubjectArea(_ devices: [AVCaptureDevice?]) {
    for observer in subjectObservers { NotificationCenter.default.removeObserver(observer) }
    subjectObservers = []
    for device in devices.compactMap({ $0 }) {
      let observer = NotificationCenter.default.addObserver(
        forName: AVCaptureDevice.subjectAreaDidChangeNotification,
        object: device,
        queue: nil
      ) { [weak self, weak device] _ in
        guard let self = self, let device = device else { return }
        self.resetFocus(device)
      }
      subjectObservers.append(observer)
    }
  }

  // MARK: - Photo

  func takePhoto(_ request: PhotoRequest, completion: @escaping (Result<CaptureResult, Error>) -> Void) {
    let composition = self.composition
    sessionQueue.async {
      guard let mode = self.mode, !self.isCapturing else {
        completion(.failure(self.isCapturing
          ? DualCameraError.captureFailed("une photo est déjà en cours.")
          : DualCameraError.notRunning))
        return
      }
      switch mode {
      case .dual:
        guard self.multiSessionStorage?.isRunning == true else { completion(.failure(DualCameraError.notRunning)); return }
        self.takeDualPhoto(flash: request.flash, composition: composition, completion: completion)
      case .photo:
        guard self.singleSession.isRunning else { completion(.failure(DualCameraError.notRunning)); return }
        // Au-delà de trois photos en attente, on laisse l'iPhone finir.
        guard self.singleInFlight < 3 else {
          completion(.failure(DualCameraError.captureFailed("une photo est déjà en cours.")))
          return
        }
        self.takeSinglePhoto(request, completion: completion)
      case .video, .slowmo:
        completion(.failure(DualCameraError.captureFailed("passez en mode Photo.")))
      }
    }
  }

  private func takeSinglePhoto(_ request: PhotoRequest, completion: @escaping (Result<CaptureResult, Error>) -> Void) {
    // Mode nuit : on règle d'abord une pose longue, puis on revient ici pour la photo.
    if request.nightSeconds > 0, !request.nightPrepared, let device = singleDevice,
       device.isExposureModeSupported(.custom) {
      let plan = nightPlan(for: device)
      if plan.needed > 0 {
        isCapturing = true
        var started = false
        let proceed: () -> Void = { [weak self] in
          guard let self = self, !started else { return }
          started = true
          self.isCapturing = false
          var prepared = request
          prepared.nightPrepared = true
          self.takeSinglePhoto(prepared, completion: completion)
        }
        do {
          try device.lockForConfiguration()
          device.setExposureModeCustom(duration: plan.duration, iso: plan.iso) { [weak self] _ in
            self?.sessionQueue.async(execute: proceed)
          }
          device.unlockForConfiguration()
          // Sécurité : si la caméra ne confirme pas le réglage, on prend quand même la photo.
          sessionQueue.asyncAfter(deadline: .now() + 5, execute: proceed)
          return
        } catch {
          isCapturing = false
        }
      }
    }

    let night = request.nightPrepared
    if night { isCapturing = true }
    singleInFlight += 1
    let output = singlePhotoOutput

    let useHeif = request.heif && output.availablePhotoCodecTypes.contains(.hevc)
    let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: useHeif ? AVVideoCodecType.hevc : AVVideoCodecType.jpeg])
    if request.nightPrepared {
      settings.flashMode = .off
    } else if output.supportedFlashModes.contains(request.flash) {
      settings.flashMode = request.flash
    }
    settings.photoQualityPrioritization = .quality
    if output.isContentAwareDistortionCorrectionEnabled {
      settings.isAutoContentAwareDistortionCorrectionEnabled = true
    }
    if let dims = photoDimensions(megapixels: request.megapixels) {
      settings.maxPhotoDimensions = dims
    }
    // Live Photo seulement en 4:3 (recadrer casserait le lien entre la photo et la vidéo).
    let fullFrame = abs(request.aspect - 3.0 / 4.0) < 0.01
    if request.live && !request.nightPrepared && output.isLivePhotoCaptureEnabled && fullFrame {
      settings.livePhotoMovieFileURL = DualCameraController.temporaryURL(ext: "mov")
    }
    applyCaptureRotation(to: output.connection(with: .video))

    // Tout ce qui suit s'exécute sur la file de la caméra.
    var finished = false
    var key: ObjectIdentifier?
    let done: () -> Void = { [weak self] in
      guard let self = self else { return }
      if let key = key { self.inFlightDelegates.removeValue(forKey: key) }
      self.singleInFlight = max(0, self.singleInFlight - 1)
      if night {
        self.restoreAutoExposure()
        self.isCapturing = false
      }
    }
    let delegate = SinglePhotoDelegate { [weak self] result in
      guard let self = self else { return }
      self.sessionQueue.async {
        guard !finished else { return }
        finished = true
        done()
        switch result {
        case .failure(let error):
          completion(.failure(DualCameraError.captureFailed(error.localizedDescription)))
        case .success(let capture):
          self.finishSinglePhoto(data: capture.data, liveURL: capture.liveURL, request: request,
                                 heif: useHeif, completion: completion)
        }
      }
    }
    let identifier = ObjectIdentifier(delegate)
    key = identifier
    inFlightDelegates[identifier] = delegate
    output.capturePhoto(with: settings, delegate: delegate)

    // Sécurité : si l'iPhone ne renvoie jamais la photo, on le dit au lieu d'attendre pour toujours.
    sessionQueue.asyncAfter(deadline: .now() + 15) {
      guard !finished else { return }
      finished = true
      done()
      completion(.failure(DualCameraError.captureFailed("l'appareil photo n'a renvoyé aucune image.")))
    }
  }

  private func finishSinglePhoto(data: Data, liveURL: URL?, request: PhotoRequest, heif: Bool,
                                 completion: @escaping (Result<CaptureResult, Error>) -> Void) {
    var photoData = data
    var thumbSource: UIImage?
    let fullFrame = abs(request.aspect - 3.0 / 4.0) < 0.01

    if !fullFrame, let image = UIImage(data: data) {
      // Recadrage 16:9 ou 1:1 (au centre, comme l'app Appareil photo).
      let cropped = DualCameraController.crop(image, toPortraitAspect: request.aspect)
      if let encoded = DualCameraController.encode(cropped, heif: heif) {
        photoData = encoded
      }
      thumbSource = cropped
    }

    DualCameraController.saveToPhotoLibrary { request in
      request.addResource(with: .photo, data: photoData, options: nil)
      if let liveURL = liveURL {
        let options = PHAssetResourceCreationOptions()
        options.shouldMoveFile = true
        request.addResource(with: .pairedVideo, fileURL: liveURL, options: options)
      }
    } completion: { error in
      if let error = error {
        completion(.failure(error))
        return
      }
      let thumbImage = thumbSource ?? UIImage(data: photoData)
      guard let image = thumbImage, let url = DualCameraController.writeThumbnail(image) else {
        completion(.failure(DualCameraError.saveFailed("miniature impossible.")))
        return
      }
      completion(.success(CaptureResult(thumbnailURL: url)))
    }
  }

  private func takeDualPhoto(flash: AVCaptureDevice.FlashMode, composition: DualCameraComposition,
                             completion: @escaping (Result<CaptureResult, Error>) -> Void) {
    isCapturing = true

    let group = DispatchGroup()
    var backImage: UIImage?
    var frontImage: UIImage?
    var captureError: Error?
    let lock = NSLock()

    func capture(_ output: AVCapturePhotoOutput, flash: AVCaptureDevice.FlashMode,
                 store: @escaping (UIImage) -> Void) {
      group.enter()
      let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
      if output.supportedFlashModes.contains(flash) {
        settings.flashMode = flash
      }
      let delegate = SinglePhotoDelegate { result in
        lock.lock()
        switch result {
        case .success(let capture):
          if let image = UIImage(data: capture.data) { store(image) }
        case .failure(let error):
          captureError = error
        }
        lock.unlock()
        group.leave()
      }
      inFlightDelegates[ObjectIdentifier(delegate)] = delegate
      output.capturePhoto(with: settings, delegate: delegate)
    }

    capture(backPhotoOutput, flash: flash) { backImage = $0 }
    capture(frontPhotoOutput, flash: .off) { frontImage = $0 }

    group.notify(queue: sessionQueue) {
      self.inFlightDelegates.removeAll()
      self.isCapturing = false
      if let error = captureError {
        completion(.failure(DualCameraError.captureFailed(error.localizedDescription)))
        return
      }
      guard let back = backImage, let front = frontImage else {
        completion(.failure(DualCameraError.captureFailed("image manquante.")))
        return
      }
      let merged = DualCameraController.merge(back: back, front: front, composition: composition)
      guard let jpeg = merged.jpegData(compressionQuality: 0.92) else {
        completion(.failure(DualCameraError.captureFailed("encodage JPEG impossible.")))
        return
      }
      DualCameraController.saveToPhotoLibrary { request in
        request.addResource(with: .photo, data: jpeg, options: nil)
      } completion: { error in
        if let error = error {
          completion(.failure(error))
          return
        }
        guard let url = DualCameraController.writeThumbnail(merged) else {
          completion(.failure(DualCameraError.saveFailed("miniature impossible.")))
          return
        }
        completion(.success(CaptureResult(thumbnailURL: url)))
      }
    }
  }

  // MARK: - Vidéo

  /// Démarre l'enregistrement. `completion` est appelé quand la vidéo a vraiment commencé.
  func startRecording(torch: Bool, completion: @escaping (Error?) -> Void) {
    sessionQueue.async {
      guard self.mode?.isVideo == true, self.singleSession.isRunning else {
        completion(DualCameraError.notRunning)
        return
      }
      guard !self.movieOutput.isRecording else {
        completion(DualCameraError.recordingFailed("une vidéo est déjà en cours."))
        return
      }
      self.applyCaptureRotation(to: self.movieOutput.connection(with: .video))
      self.setTorch(torch)

      let url = DualCameraController.temporaryURL(ext: "mov")
      let delegate = MovieRecordingDelegate(
        started: { completion(nil) },
        finished: { [weak self] fileURL, error in
          self?.sessionQueue.async { self?.finishRecording(fileURL: fileURL, error: error) }
        }
      )
      self.movieDelegate = delegate
      self.movieOutput.startRecording(to: url, recordingDelegate: delegate)
    }
  }

  /// Arrête l'enregistrement ; `completion` reçoit la miniature une fois la vidéo enregistrée dans Photos.
  func stopRecording(completion: @escaping (Result<CaptureResult, Error>) -> Void) {
    sessionQueue.async {
      guard self.movieOutput.isRecording else {
        completion(.failure(DualCameraError.recordingFailed("aucune vidéo en cours.")))
        return
      }
      self.pendingStop = completion
      self.movieOutput.stopRecording()
    }
  }

  private func finishRecording(fileURL: URL, error: Error?) {
    setTorch(false)
    movieDelegate = nil
    let completion = pendingStop ?? { _ in }
    pendingStop = nil

    // iOS peut signaler une « erreur » alors que la vidéo est bien enregistrée.
    if let error = error as NSError?,
       (error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) != true {
      completion(.failure(DualCameraError.recordingFailed(error.localizedDescription)))
      return
    }

    let thumbnail = DualCameraController.videoThumbnail(fileURL)
    DualCameraController.saveToPhotoLibrary { request in
      let options = PHAssetResourceCreationOptions()
      options.shouldMoveFile = true
      request.addResource(with: .video, fileURL: fileURL, options: options)
    } completion: { saveError in
      if let saveError = saveError {
        completion(.failure(saveError))
        return
      }
      guard let image = thumbnail, let url = DualCameraController.writeThumbnail(image) else {
        completion(.failure(DualCameraError.saveFailed("miniature impossible.")))
        return
      }
      completion(.success(CaptureResult(thumbnailURL: url)))
    }
  }

  private func setTorch(_ on: Bool) {
    guard let device = singleDevice, device.hasTorch else { return }
    do {
      try device.lockForConfiguration()
      if on && device.isTorchModeSupported(.on) {
        device.torchMode = .on
      } else if device.isTorchModeSupported(.off) {
        device.torchMode = .off
      }
      device.unlockForConfiguration()
    } catch {}
  }

  // MARK: - Images

  static func temporaryURL(ext: String) -> URL {
    return FileManager.default.temporaryDirectory
      .appendingPathComponent("dualcam-\(UUID().uuidString)")
      .appendingPathExtension(ext)
  }

  /// Recadre au centre pour obtenir le rapport largeur/hauteur voulu (en portrait).
  static func crop(_ image: UIImage, toPortraitAspect aspect: CGFloat) -> UIImage {
    let size = image.size
    // Si la photo est en paysage, on inverse le rapport.
    let target = size.width > size.height ? 1 / aspect : aspect
    var cropSize = size
    if size.width / size.height > target {
      cropSize.width = (size.height * target).rounded()
    } else {
      cropSize.height = (size.width / target).rounded()
    }
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(size: cropSize, format: format)
    return renderer.image { _ in
      image.draw(at: CGPoint(x: (cropSize.width - size.width) / 2, y: (cropSize.height - size.height) / 2))
    }
  }

  /// Encode en HEIF (ou JPEG).
  static func encode(_ image: UIImage, heif: Bool) -> Data? {
    guard let cgImage = image.cgImage else { return nil }
    let data = NSMutableData()
    let type = (heif ? UTType.heic : UTType.jpeg).identifier as CFString
    guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
    let options = [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
    CGImageDestinationAddImage(destination, cgImage, options)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
  }

  /// Petite image JPEG pour la miniature ronde.
  static func writeThumbnail(_ image: UIImage) -> URL? {
    let maxSide: CGFloat = 300
    let scale = min(1, maxSide / max(image.size.width, image.size.height))
    let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: size))
    }
    guard let data = small.jpegData(compressionQuality: 0.8) else { return nil }
    let url = temporaryURL(ext: "jpg")
    do {
      try data.write(to: url)
      return url
    } catch {
      return nil
    }
  }

  static func videoThumbnail(_ url: URL) -> UIImage? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
    return UIImage(cgImage: cgImage)
  }

  // MARK: - Fusion des deux images (mode Duo)

  static func merge(back: UIImage, front: UIImage, composition c: DualCameraComposition) -> UIImage {
    // Taille finale : 3:4 portrait, basée sur la largeur de l'image arrière.
    let width = min(back.size.width, back.size.height)
    let canvas = CGSize(width: width, height: (width / DualCameraGeometry.canvasAspect).rounded())
    let bounds = CGRect(origin: .zero, size: canvas)
    let rects = DualCameraGeometry.rects(in: bounds, c)

    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(size: canvas, format: format)

    // La petite fenêtre est dessinée en dernier, par-dessus.
    let backDraw = (image: back, rect: rects.back, mirrored: false, side: DualCameraSide.back)
    let frontDraw = (image: front, rect: rects.front, mirrored: true, side: DualCameraSide.front)
    let draws = c.smallSide == .back ? [frontDraw, backDraw] : [backDraw, frontDraw]

    return renderer.image { context in
      UIColor.black.setFill()
      context.fill(bounds)

      for item in draws {
        let isSmall = c.smallSide == item.side
        let radius = isSmall ? DualCameraGeometry.pipCornerRadius(for: item.rect) : 0
        drawAspectFill(item.image, in: item.rect, mirrored: item.mirrored, cornerRadius: radius,
                       context: context.cgContext)
        if isSmall {
          let border = UIBezierPath(roundedRect: item.rect, cornerRadius: radius)
          border.lineWidth = max(2, canvas.width * 0.006)
          UIColor.white.setStroke()
          border.stroke()
        }
      }
    }
  }

  /// Dessine l'image en "remplissage" (comme resizeAspectFill) dans `rect`, avec miroir optionnel.
  private static func drawAspectFill(_ image: UIImage, in rect: CGRect, mirrored: Bool,
                                     cornerRadius: CGFloat, context: CGContext) {
    context.saveGState()
    UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius).addClip()

    let imageSize = image.size  // tient déjà compte de l'orientation EXIF
    let scale = max(rect.width / imageSize.width, rect.height / imageSize.height)
    let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    let drawRect = CGRect(x: rect.midX - drawSize.width / 2,
                          y: rect.midY - drawSize.height / 2,
                          width: drawSize.width, height: drawSize.height)

    if mirrored {
      context.translateBy(x: rect.midX, y: 0)
      context.scaleBy(x: -1, y: 1)
      context.translateBy(x: -rect.midX, y: 0)
    }
    image.draw(in: drawRect)
    context.restoreGState()
  }

  // MARK: - Pellicule

  private static func saveToPhotoLibrary(_ changes: @escaping (PHAssetCreationRequest) -> Void,
                                         completion: @escaping (Error?) -> Void) {
    let save = {
      PHPhotoLibrary.shared().performChanges({
        changes(PHAssetCreationRequest.forAsset())
      }, completionHandler: { success, error in
        if success {
          completion(nil)
        } else {
          completion(DualCameraError.saveFailed(error?.localizedDescription ?? "erreur inconnue."))
        }
      })
    }

    switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
    case .authorized, .limited:
      save()
    case .notDetermined:
      PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
        if status == .authorized || status == .limited {
          save()
        } else {
          completion(DualCameraError.photoLibraryDenied)
        }
      }
    default:
      completion(DualCameraError.photoLibraryDenied)
    }
  }
}

/// Résultat brut d'une capture photo.
struct RawPhoto {
  let data: Data
  let liveURL: URL?
}

/// Délégué d'une capture photo : récupère les données (et la vidéo Live Photo).
final class SinglePhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
  private let completion: (Result<RawPhoto, Error>) -> Void
  private var photoData: Data?
  private var liveURL: URL?
  private var failure: Error?

  init(completion: @escaping (Result<RawPhoto, Error>) -> Void) {
    self.completion = completion
  }

  func photoOutput(_ output: AVCapturePhotoOutput,
                   didFinishProcessingPhoto photo: AVCapturePhoto,
                   error: Error?) {
    if let error = error {
      failure = error
      return
    }
    photoData = photo.fileDataRepresentation()
  }

  func photoOutput(_ output: AVCapturePhotoOutput,
                   didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL,
                   duration: CMTime,
                   photoDisplayTime: CMTime,
                   resolvedSettings: AVCaptureResolvedPhotoSettings,
                   error: Error?) {
    if error == nil {
      liveURL = outputFileURL
    }
  }

  func photoOutput(_ output: AVCapturePhotoOutput,
                   didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                   error: Error?) {
    if let error = error ?? failure {
      completion(.failure(error))
      return
    }
    guard let data = photoData else {
      completion(.failure(DualCameraError.captureFailed("données photo vides.")))
      return
    }
    completion(.success(RawPhoto(data: data, liveURL: liveURL)))
  }
}

/// Délégué d'un enregistrement vidéo.
final class MovieRecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {
  private let started: () -> Void
  private let finished: (URL, Error?) -> Void

  init(started: @escaping () -> Void, finished: @escaping (URL, Error?) -> Void) {
    self.started = started
    self.finished = finished
  }

  func fileOutput(_ output: AVCaptureFileOutput,
                  didStartRecordingTo fileURL: URL,
                  from connections: [AVCaptureConnection]) {
    started()
  }

  func fileOutput(_ output: AVCaptureFileOutput,
                  didFinishRecordingTo outputFileURL: URL,
                  from connections: [AVCaptureConnection],
                  error: Error?) {
    finished(outputFileURL, error)
  }
}
