import AVFoundation
import ExpoModulesCore
import Photos

public class DualCameraModule: Module {
  public func definition() -> ModuleDefinition {
    Name("DualCamera")

    // true si l'iPhone sait utiliser deux caméras en même temps (iPhone XS et plus récent).
    Function("isMultiCamSupported") { () -> Bool in
      return DualCameraController.isSupported
    }

    // État actuel des permissions, sans rien demander.
    AsyncFunction("getPermissionsAsync") { () -> [String: String] in
      return [
        "camera": DualCameraModule.cameraStatus(),
        "photos": DualCameraModule.photosStatus()
      ]
    }

    // Demande caméra puis photos (affiche les pop-ups iOS si besoin).
    AsyncFunction("requestPermissionsAsync") { (promise: Promise) in
      AVCaptureDevice.requestAccess(for: .video) { _ in
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in
          promise.resolve([
            "camera": DualCameraModule.cameraStatus(),
            "photos": DualCameraModule.photosStatus()
          ])
        }
      }
    }

    // Prend la photo double, l'enregistre dans la pellicule, renvoie l'URI locale.
    AsyncFunction("takePhotoAsync") { (layout: String, promise: Promise) in
      let parsed = DualCameraLayout(rawValue: layout) ?? .stack
      DualCameraController.shared.takePhoto(layout: parsed) { result in
        switch result {
        case .success(let url):
          promise.resolve(url.absoluteString)
        case .failure(let error):
          promise.reject("ERR_DUALCAM", error.localizedDescription)
        }
      }
    }

    View(DualCameraView.self) {
      Events("onCameraReady", "onCameraError")

      Prop("layout") { (view: DualCameraView, layout: String) in
        view.layout = DualCameraLayout(rawValue: layout) ?? .stack
      }
    }
  }

  private static func cameraStatus() -> String {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
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
