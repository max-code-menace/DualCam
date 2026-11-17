import type { StyleProp, ViewStyle } from 'react-native';

/** "stack" = haut / bas. "side" = côte à côte. "pip" = une caméra en petite incrustation sur l'autre. */
export type DualCameraLayout = 'stack' | 'side' | 'pip';

/** "photo", "video" et "slowmo" (ralenti) = une seule caméra (pleine qualité). "dual" = les deux en même temps. */
export type CaptureModeName = 'photo' | 'video' | 'slowmo' | 'dual';

export type DualCameraSide = 'back' | 'front';

export type FlashMode = 'auto' | 'on' | 'off';

export type AspectRatio = '4:3' | '16:9' | '1:1';

export type HapticStyle = 'light' | 'medium' | 'selection' | 'success';

export type PermissionState = 'granted' | 'denied' | 'undetermined';

export type DualCameraPermissions = {
  camera: PermissionState;
  microphone: PermissionState;
  photos: PermissionState;
};

export type PhotoOptions = {
  flash: FlashMode;
  live: boolean;
  aspect: AspectRatio;
  megapixels: number;
  heif: boolean;
  /** Mode nuit : secondes de pose annoncées (0 ou absent = désactivé). */
  nightSeconds?: number;
};

export type CameraReadyEvent = {
  mode: CaptureModeName;
  position: DualCameraSide;
  /** true si la caméra descend à 0,5×. */
  hasUltraWide: boolean;
  hasFlash: boolean;
  liveSupported: boolean;
  /** Résolutions possibles en mégapixels (12, 24, 48). */
  resolutions: number[];
  zoom: number;
  minZoom: number;
  maxZoom: number;
  minBias: number;
  maxBias: number;
  /** Mode Vidéo : choix possibles (HD / 4K et images par seconde). */
  videoOptions?: VideoOption[];
  videoResolution?: VideoResolution;
  videoFps?: number;
};

export type VideoResolution = 'HD' | '4K';

export type VideoOption = { resolution: VideoResolution; fps: number[] };

export type DualCameraViewProps = {
  mode?: CaptureModeName;
  position?: DualCameraSide;
  layout?: DualCameraLayout;
  /** Mode Duo : inverse les deux caméras (laquelle est en haut / en grand). */
  swapped?: boolean;
  /** Mode Vidéo : "HD" ou "4K". */
  videoResolution?: VideoResolution;
  /** Mode Vidéo : images par seconde. Mode Ralenti : 120 ou 240. */
  videoFps?: number;
  onCameraReady?: (event: { nativeEvent: CameraReadyEvent }) => void;
  onCameraError?: (event: { nativeEvent: { message: string } }) => void;
  onZoomChange?: (event: { nativeEvent: { camera: DualCameraSide; zoom: number } }) => void;
  onSwipe?: (event: { nativeEvent: { direction: 'left' | 'right' } }) => void;
  /** Bouton de volume pressé. */
  onShutterButton?: () => void;
  onExposureChange?: (event: { nativeEvent: { bias: number } }) => void;
  /** Sens de l'iPhone : 0 (portrait), 90 ou -90 (paysage). Sert à tourner les icônes. */
  onOrientationChange?: (event: { nativeEvent: { rotation: number } }) => void;
  /** Mode nuit : true pendant la photo, affiche la croix pour ne pas bouger. */
  steady?: boolean;
  /** Il fait sombre : le mode nuit est conseillé, avec la durée de pose. */
  onLowLight?: (event: { nativeEvent: { active: boolean; seconds: number } }) => void;
  style?: StyleProp<ViewStyle>;
};
