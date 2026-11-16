import AVFoundation
import Photos
import UIKit

/// Erreurs renvoyées à JavaScript (le message est affiché tel quel à l'utilisateur).
enum DualCameraError: LocalizedError {
  case notSupported
  case cameraUnavailable(String)
  case configurationFailed(String)
  case notRunning
  case captureFailed(String)
  case photoLibraryDenied
  case saveFailed(String)

  var errorDescription: String? {
    switch self {
    case .notSupported:
      return "Cet iPhone ne permet pas d'utiliser les deux caméras en même temps."
    case .cameraUnavailable(let which):
      return "La caméra \(which) est introuvable."
    case .configurationFailed(let detail):
      return "Impossible de démarrer les caméras : \(detail)"
    case .notRunning:
      return "Les caméras ne sont pas encore prêtes."
    case .captureFailed(let detail):
      return "La photo a échoué : \(detail)"
    case .photoLibraryDenied:
      return "L'accès aux Photos est refusé. Autorisez-le dans Réglages > DualCam."
    case .saveFailed(let detail):
      return "Impossible d'enregistrer la photo : \(detail)"
    }
  }
}

/// Disposition de la photo finale (et de l'aperçu).
enum DualCameraLayout: String {
  case stack  // avant en haut, arrière en bas
  case pip    // arrière en plein écran, avant en petite incrustation
}

/// Géométrie partagée entre l'aperçu et la photo finale, pour que la photo
/// ressemble exactement à ce qu'on voit à l'écran.
enum DualCameraGeometry {
  /// Rapport largeur / hauteur de la zone caméra (portrait 3:4).
  static let canvasAspect: CGFloat = 3.0 / 4.0

  static func frontRect(in bounds: CGRect, layout: DualCameraLayout) -> CGRect {
    switch layout {
    case .stack:
      return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height / 2)
    case .pip:
      let margin = bounds.width * 0.04
      let width = bounds.width * 0.32
      return CGRect(x: bounds.minX + margin, y: bounds.minY + margin, width: width, height: width * 4.0 / 3.0)
    }
  }

  static func backRect(in bounds: CGRect, layout: DualCameraLayout) -> CGRect {
    switch layout {
    case .stack:
      return CGRect(x: bounds.minX, y: bounds.midY, width: bounds.width, height: bounds.height / 2)
    case .pip:
      return bounds
    }
  }

  static func pipCornerRadius(for rect: CGRect) -> CGFloat {
    return rect.width * 0.08
  }
}

/// Gère une seule AVCaptureMultiCamSession partagée par l'app :
/// caméra arrière + caméra avant, deux aperçus, deux sorties photo.
final class DualCameraController: NSObject {
  static let shared = DualCameraController()

  private let session = AVCaptureMultiCamSession()
  private let sessionQueue = DispatchQueue(label: "dualcam.session")

  private let backPhotoOutput = AVCapturePhotoOutput()
  private let frontPhotoOutput = AVCapturePhotoOutput()
  private var isConfigured = false
  private var inFlightDelegates: [PhotoCaptureDelegate] = []
  private var isCapturing = false

  static var isSupported: Bool {
    return AVCaptureMultiCamSession.isMultiCamSupported
  }

  // MARK: - Démarrage / arrêt

  /// Branche les deux calques d'aperçu sur la session puis la démarre.
  /// `completion` est appelé sur le thread principal.
  func start(backLayer: AVCaptureVideoPreviewLayer,
             frontLayer: AVCaptureVideoPreviewLayer,
             completion: @escaping (Error?) -> Void) {
    guard DualCameraController.isSupported else {
      completion(DualCameraError.notSupported)
      return
    }
    sessionQueue.async {
      do {
        try self.configure(backLayer: backLayer, frontLayer: frontLayer)
        if !self.session.isRunning {
          self.session.startRunning()
        }
        DispatchQueue.main.async { completion(nil) }
      } catch {
        DispatchQueue.main.async { completion(error) }
      }
    }
  }

  func stop() {
    sessionQueue.async {
      if self.session.isRunning {
        self.session.stopRunning()
      }
    }
  }

  // MARK: - Configuration

  private func configure(backLayer: AVCaptureVideoPreviewLayer,
                         frontLayer: AVCaptureVideoPreviewLayer) throws {
    // On repart de zéro à chaque fois (ex. la vue a été recréée).
    session.beginConfiguration()
    for connection in session.connections { session.removeConnection(connection) }
    for input in session.inputs { session.removeInput(input) }
    for output in session.outputs { session.removeOutput(output) }
    isConfigured = false

    do {
      try addCamera(position: .back, photoOutput: backPhotoOutput, previewLayer: backLayer, mirrored: false)
      try addCamera(position: .front, photoOutput: frontPhotoOutput, previewLayer: frontLayer, mirrored: true)
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
    isConfigured = true
  }

  private func addCamera(position: AVCaptureDevice.Position,
                         photoOutput: AVCapturePhotoOutput,
                         previewLayer: AVCaptureVideoPreviewLayer,
                         mirrored: Bool) throws {
    let label = position == .front ? "avant" : "arrière"
    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
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
    setPortrait(photoConnection)
    // Le miroir de la photo avant est appliqué au moment de la fusion (côté dessin),
    // donc on laisse la photo brute non inversée ici.
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
    setPortrait(previewConnection)
    if previewConnection.isVideoMirroringSupported {
      previewConnection.automaticallyAdjustsVideoMirroring = false
      previewConnection.isVideoMirrored = mirrored
    }
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
    device.unlockForConfiguration()
  }

  private func setPortrait(_ connection: AVCaptureConnection) {
    if #available(iOS 17.0, *) {
      if connection.isVideoRotationAngleSupported(90) {
        connection.videoRotationAngle = 90
      }
    } else if connection.isVideoOrientationSupported {
      connection.videoOrientation = .portrait
    }
  }

  // MARK: - Capture

  /// Prend les deux photos, les fusionne, enregistre dans la pellicule
  /// et renvoie l'URL d'un fichier JPEG local (pour la miniature).
  func takePhoto(layout: DualCameraLayout, completion: @escaping (Result<URL, Error>) -> Void) {
    sessionQueue.async {
      guard self.isConfigured, self.session.isRunning else {
        completion(.failure(DualCameraError.notRunning))
        return
      }
      guard !self.isCapturing else {
        completion(.failure(DualCameraError.captureFailed("une photo est déjà en cours.")))
        return
      }
      self.isCapturing = true

      let group = DispatchGroup()
      var backImage: UIImage?
      var frontImage: UIImage?
      var captureError: Error?
      let lock = NSLock()

      func capture(_ output: AVCapturePhotoOutput, store: @escaping (UIImage) -> Void) {
        group.enter()
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        let delegate = PhotoCaptureDelegate { result in
          lock.lock()
          switch result {
          case .success(let image): store(image)
          case .failure(let error): captureError = error
          }
          lock.unlock()
          group.leave()
        }
        self.inFlightDelegates.append(delegate)
        output.capturePhoto(with: settings, delegate: delegate)
      }

      capture(self.backPhotoOutput) { backImage = $0 }
      capture(self.frontPhotoOutput) { frontImage = $0 }

      group.notify(queue: self.sessionQueue) {
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
        let merged = DualCameraController.merge(back: back, front: front, layout: layout)
        guard let jpeg = merged.jpegData(compressionQuality: 0.92) else {
          completion(.failure(DualCameraError.captureFailed("encodage JPEG impossible.")))
          return
        }
        DualCameraController.saveToPhotoLibrary(jpeg) { saveError in
          if let saveError = saveError {
            completion(.failure(saveError))
            return
          }
          do {
            let url = FileManager.default.temporaryDirectory
              .appendingPathComponent("dualcam-\(Int(Date().timeIntervalSince1970 * 1000)).jpg")
            try jpeg.write(to: url)
            completion(.success(url))
          } catch {
            completion(.failure(DualCameraError.saveFailed(error.localizedDescription)))
          }
        }
      }
    }
  }

  // MARK: - Fusion des deux images

  static func merge(back: UIImage, front: UIImage, layout: DualCameraLayout) -> UIImage {
    // Taille finale : 3:4 portrait, basée sur la largeur de l'image arrière.
    let width = min(back.size.width, back.size.height)
    let canvas = CGSize(width: width, height: (width / DualCameraGeometry.canvasAspect).rounded())
    let bounds = CGRect(origin: .zero, size: canvas)

    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(size: canvas, format: format)

    return renderer.image { context in
      UIColor.black.setFill()
      context.fill(bounds)

      let backRect = DualCameraGeometry.backRect(in: bounds, layout: layout)
      drawAspectFill(back, in: backRect, mirrored: false, cornerRadius: 0, context: context.cgContext)

      let frontRect = DualCameraGeometry.frontRect(in: bounds, layout: layout)
      let radius = layout == .pip ? DualCameraGeometry.pipCornerRadius(for: frontRect) : 0
      drawAspectFill(front, in: frontRect, mirrored: true, cornerRadius: radius, context: context.cgContext)

      if layout == .pip {
        let border = UIBezierPath(roundedRect: frontRect, cornerRadius: radius)
        border.lineWidth = max(2, canvas.width * 0.006)
        UIColor.white.setStroke()
        border.stroke()
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

  private static func saveToPhotoLibrary(_ data: Data, completion: @escaping (Error?) -> Void) {
    let save = {
      PHPhotoLibrary.shared().performChanges({
        let request = PHAssetCreationRequest.forAsset()
        request.addResource(with: .photo, data: data, options: nil)
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

/// Délégué d'une capture photo : transforme le résultat en UIImage.
private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
  private let completion: (Result<UIImage, Error>) -> Void

  init(completion: @escaping (Result<UIImage, Error>) -> Void) {
    self.completion = completion
  }

  func photoOutput(_ output: AVCapturePhotoOutput,
                   didFinishProcessingPhoto photo: AVCapturePhoto,
                   error: Error?) {
    if let error = error {
      completion(.failure(error))
      return
    }
    guard let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else {
      completion(.failure(DualCameraError.captureFailed("données photo vides.")))
      return
    }
    completion(.success(image))
  }
}
