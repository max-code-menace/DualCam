import { NativeModule, requireNativeModule } from 'expo';

import type { DualCameraPermissions, DualCameraSide, HapticStyle, PhotoOptions } from './DualCamera.types';

declare class DualCameraModule extends NativeModule<{}> {
  /** true si l'iPhone peut filmer avec les deux caméras en même temps. */
  isMultiCamSupported(): boolean;
  getPermissionsAsync(): Promise<DualCameraPermissions>;
  requestPermissionsAsync(): Promise<DualCameraPermissions>;
  requestMicrophoneAsync(): Promise<boolean>;
  /** Prend une photo (mode Photo ou Duo), l'enregistre dans Photos et renvoie l'URI de la miniature. */
  takePhotoAsync(options: PhotoOptions): Promise<string>;
  /** Démarre une vidéo (mode Vidéo). */
  startRecordingAsync(torch: boolean): Promise<void>;
  /** Arrête la vidéo, l'enregistre dans Photos et renvoie l'URI de la miniature. */
  stopRecordingAsync(): Promise<string>;
  /** Règle le zoom affiché (0,5 ; 1 ; 2…). Renvoie la valeur vraiment appliquée. */
  setZoom(camera: DualCameraSide, zoom: number, animated: boolean): number;
  /** Règle la luminosité (-2 … +2). Renvoie la valeur appliquée. */
  setExposureBias(value: number): number;
  /** Petite vibration. */
  haptic(style: HapticStyle): void;
}

export default requireNativeModule<DualCameraModule>('DualCamera');
