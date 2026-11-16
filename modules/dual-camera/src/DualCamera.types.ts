import type { StyleProp, ViewStyle } from 'react-native';

/** "stack" = avant en haut / arrière en bas. "pip" = avant en petite incrustation sur l'arrière. */
export type DualCameraLayout = 'stack' | 'pip';

export type PermissionState = 'granted' | 'denied' | 'undetermined';

export type DualCameraPermissions = {
  camera: PermissionState;
  photos: PermissionState;
};

export type DualCameraViewProps = {
  layout?: DualCameraLayout;
  onCameraReady?: () => void;
  onCameraError?: (event: { nativeEvent: { message: string } }) => void;
  style?: StyleProp<ViewStyle>;
};
