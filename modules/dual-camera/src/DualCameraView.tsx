import { requireNativeView } from 'expo';
import * as React from 'react';

import { DualCameraViewProps } from './DualCamera.types';

const NativeView: React.ComponentType<DualCameraViewProps> = requireNativeView('DualCamera');

export default function DualCameraView(props: DualCameraViewProps) {
  return <NativeView {...props} />;
}
