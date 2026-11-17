import AVFoundation
import ExpoModulesCore
import Photos
import UIKit

/// Réglages d'une photo envoyés depuis JavaScript.
struct PhotoOptions: Record {
  @Field var flash: String = "auto"
  @Field var live: Bool = true
  /// "4:3", "16:9" ou "1:1"
  @Field var aspect: String = "4:3"
  @Field var megapixels: Int = 24
  @Field var heif: Bool = true
  /// Mode nuit : secondes de pose annoncées (0 = désactivé).
  @Field var nightSeconds: Int = 0
}

public class DualCameraModule: Module {
  public func definition() -> ModuleDefinition {
    Name("DualCamera")

    // true si l'iPhone sait utiliser deux caméras en même temps (iPhone XS et plus récent).
    Function("isMultiCamSupported") { () -> Bool in
      return DualCameraController.isSupported
    }

    // État actuel des permissions, sans rien demander.
    AsyncFunction("getPermissionsAsync") { () -> [String: String] in
      return DualCameraModule.permissions()
    }

    // Demande caméra, micro puis photos (affiche les pop-ups iOS si besoin).
    AsyncFunction("requestPermissionsAsync") { (promise: Promise) in
      AVCaptureDevice.requestAccess(for: .video) { _ in
        AVCaptureDevice.requestAccess(for: .audio) { _ in
          PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in
            promise.resolve(DualCameraModule.permissions())
          }
        }
      }
    }

    // Demande le micro (pour le son des vidéos).
    AsyncFunction("requestMicrophoneAsync") { (promise: Promise) in
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        promise.resolve(granted)
      }
    }

    // Prend une photo (mode Photo ou Duo), l'enregistre dans Photos, renvoie l'URI de la miniature.
    AsyncFunction("takePhotoAsync") { (options: PhotoOptions, promise: Promise) in
      var request = PhotoRequest()
      request.flash = options.flash == "on" ? .on : (options.flash == "off" ? .off : .auto)
      request.live = options.live
      switch options.aspect {
      case "16:9": request.aspect = 9.0 / 16.0
      case "1:1": request.aspect = 1
      default: request.aspect = 3.0 / 4.0
      }
      request.megapixels = options.megapixels
      request.heif = options.heif
      request.nightSeconds = options.nightSeconds
      DualCameraController.shared.takePhoto(request) { result in
        switch result {
        case .success(let capture):
          promise.resolve(capture.thumbnailURL.absoluteString)
        case .failure(let error):
          promise.reject("ERR_DUALCAM", error.localizedDescription)
        }
      }
    }

    // Démarre une vidéo (mode Vidéo). `torch` allume la lampe.
    AsyncFunction("startRecordingAsync") { (torch: Bool, promise: Promise) in
      DualCameraController.shared.startRecording(torch: torch) { error in
        if let error = error {
          promise.reject("ERR_DUALCAM", error.localizedDescription)
        } else {
          promise.resolve(nil)
        }
      }
    }

    // Arrête la vidéo, l'enregistre dans Photos, renvoie l'URI de la miniature.
    AsyncFunction("stopRecordingAsync") { (promise: Promise) in
      DualCameraController.shared.stopRecording { result in
        switch result {
        case .success(let capture):
          promise.resolve(capture.thumbnailURL.absoluteString)
        case .failure(let error):
          promise.reject("ERR_DUALCAM", error.localizedDescription)
        }
      }
    }

    // Règle le zoom (0,5 ; 1 ; 2…) d'une caméra. Renvoie la valeur vraiment appliquée.
    Function("setZoom") { (camera: String, zoom: Double, animated: Bool) -> Double in
      let side = DualCameraSide(rawValue: camera) ?? .back
      return Double(DualCameraController.shared.setZoom(side, display: CGFloat(zoom), animated: animated))
    }

    // Règle la luminosité (-2 … +2). Renvoie la valeur appliquée.
    Function("setExposureBias") { (value: Double) -> Double in
      return Double(DualCameraController.shared.setExposureBias(Float(value)))
    }

    // Petite vibration : "light", "medium", "selection" ou "success".
    Function("haptic") { (style: String) in
      DispatchQueue.main.async {
        switch style {
        case "light":
          UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case "selection":
          UISelectionFeedbackGenerator().selectionChanged()
        case "success":
          UINotificationFeedbackGenerator().notificationOccurred(.success)
        default:
          UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
      }
    }

    View(DualCameraView.self) {
      Events("onCameraReady", "onCameraError", "onZoomChange", "onSwipe", "onShutterButton", "onExposureChange",
             "onOrientationChange", "onDebug", "onLowLight")

      Prop("mode") { (view: DualCameraView, mode: String) in
        view.mode = mode
      }

      Prop("position") { (view: DualCameraView, position: String) in
        view.position = position
      }

      Prop("layout") { (view: DualCameraView, layout: String) in
        view.layout = DualCameraLayout(rawValue: layout) ?? .stack
      }

      Prop("swapped") { (view: DualCameraView, swapped: Bool) in
        view.swapped = swapped
      }

      Prop("videoResolution") { (view: DualCameraView, resolution: String) in
        view.videoResolution = resolution
      }

      Prop("steady") { (view: DualCameraView, steady: Bool) in
        view.steady = steady
      }

      Prop("videoFps") { (view: DualCameraView, fps: Int) in
        view.videoFps = fps
      }
    }
  }

  private static func permissions() -> [String: String] {
    return [
      "camera": status(AVCaptureDevice.authorizationStatus(for: .video)),
      "microphone": status(AVCaptureDevice.authorizationStatus(for: .audio)),
      "photos": photosStatus()
    ]
  }

  private static func status(_ value: AVAuthorizationStatus) -> String {
    switch value {
    case .authorized: return "granted"
    case .notDetermined: return "undetermined"
    default: return "denied"
    }
  }

  private static func photosStatus() -> String {
    switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
    case .authorized, .limited: return "granted"
    case .notDetermined: return "undetermined"
    default: return "denied"
    }
  }
}
