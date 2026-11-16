import { NativeModule, requireNativeModule } from 'expo';

import type { DualCameraLayout, DualCameraPermissions } from './DualCamera.types';

declare class DualCameraModule extends NativeModule<{}> {
  /** true si l'iPhone peut filmer avec les deux caméras en même temps. */
  isMultiCamSupported(): boolean;
  getPermissionsAsync(): Promise<DualCameraPermissions>;
  requestPermissionsAsync(): Promise<DualCameraPermissions>;
  /** Prend la photo double, l'enregistre dans la pellicule et renvoie l'URI du fichier. */
  takePhotoAsync(layout: DualCameraLayout): Promise<string>;
}

export default requireNativeModule<DualCameraModule>('DualCamera');
