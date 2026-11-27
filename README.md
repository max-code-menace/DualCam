# DualCam

App iOS (Expo / React Native) qui prend une photo avec la caméra **avant et arrière en même temps** (iPhone XS et plus récent, testé pour iPhone 15).

## Organisation du projet

| Fichier | Rôle |
|---|---|
| `App.tsx` | Les écrans : permissions, aperçu, bouton photo, miniature. |
| `modules/dual-camera/ios/DualCameraController.swift` | Le cœur : `AVCaptureMultiCamSession`, les 2 caméras, la capture, la fusion et l'enregistrement dans Photos. |
| `modules/dual-camera/ios/DualCameraView.swift` | La vue native d'aperçu (2 calques vidéo, miroir sur la caméra avant). |
| `modules/dual-camera/ios/DualCameraModule.swift` | Ce que JavaScript peut appeler (`takePhotoAsync`, permissions…). |
| `modules/dual-camera/src/*.ts` | Les types TypeScript du module. |
| `app.json` | Nom, identifiant iOS, textes des autorisations. |
| `eas.json` | Profils de build cloud `development` et `production`. |

## Commandes (PowerShell, dans le dossier du projet)

```powershell
npm install
npm install -g eas-cli
eas login
eas build:configure
eas device:create
eas build --profile development --platform ios
npx expo start --dev-client
```

Avant le premier build : dans `app.json`, remplacez `CHANGEMOI` dans `com.CHANGEMOI.dualcam` par un mot à vous (lettres sans accent, sans espace).
