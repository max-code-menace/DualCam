import { StatusBar } from 'expo-status-bar';
import { GlassView, isLiquidGlassAvailable } from 'expo-glass-effect';
import { SymbolView } from 'expo-symbols';
import type { SFSymbol } from 'sf-symbols-typescript';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  ActivityIndicator,
  Animated,
  AppState,
  Easing,
  Image,
  Linking,
  Modal,
  PanResponder,
  Pressable,
  StyleSheet,
  Text,
  useWindowDimensions,
  View,
} from 'react-native';
import { SafeAreaProvider, useSafeAreaInsets } from 'react-native-safe-area-context';

import DualCamera, {
  AspectRatio,
  CameraReadyEvent,
  CaptureModeName,
  DualCameraLayout,
  DualCameraPermissions,
  DualCameraSide,
  DualCameraView,
  FlashMode,
  PermissionState,
  VideoOption,
  VideoResolution,
} from './modules/dual-camera';

const YELLOW = '#FFD60A';

// Liquid Glass (iOS 26). Sur un iPhone plus ancien, on garde les fonds gris d'avant.
const GLASS = isLiquidGlassAvailable();
const BUTTON_BG = GLASS ? 'rgba(40,40,42,0.5)' : '#1e1e1f';
const CAPSULE_BG = GLASS ? 'rgba(30,30,31,0.45)' : '#161617';
const ZOOM_BG = GLASS ? 'rgba(38,38,38,0.45)' : 'rgba(38,38,38,0.92)';
const PANEL_BG = GLASS ? 'rgba(31,31,32,0.55)' : 'rgba(31,31,32,0.95)';

/** Fond en verre, posé derrière le contenu d'un bouton ou d'un panneau. */
function Glass({ width, height, radius }: { width: number; height: number; radius: number }) {
  if (!GLASS) return null;
  return (
    <GlassView
      pointerEvents="none"
      glassEffectStyle="regular"
      colorScheme="dark"
      style={{ position: 'absolute', left: 0, top: 0, width, height, borderRadius: radius }}
    />
  );
}
const RED = '#F04A45';

export default function App() {
  return (
    <SafeAreaProvider>
      <StatusBar hidden />
      <Root />
    </SafeAreaProvider>
  );
}

// ─────────────────────────────────────────────────────────────
// Autorisations
// ─────────────────────────────────────────────────────────────
function Root() {
  const [perms, setPerms] = useState<DualCameraPermissions | null>(null);

  const refresh = useCallback(async () => {
    setPerms(await DualCamera.getPermissionsAsync());
  }, []);

  useEffect(() => {
    refresh();
    // Quand on revient des Réglages, on relit les autorisations.
    const sub = AppState.addEventListener('change', (state) => {
      if (state === 'active') refresh();
    });
    return () => sub.remove();
  }, [refresh]);

  if (!perms) return <View style={styles.screen} />;

  // Caméra et Photos sont obligatoires. Le micro est demandé une fois ; s'il est refusé,
  // les vidéos sont simplement sans son.
  const needsWelcome =
    perms.camera !== 'granted' || perms.photos !== 'granted' || perms.microphone === 'undetermined';

  if (needsWelcome) {
    return <WelcomeScreen perms={perms} onRequest={async () => setPerms(await DualCamera.requestPermissionsAsync())} />;
  }
  return <CameraScreen />;
}

function WelcomeScreen({ perms, onRequest }: { perms: DualCameraPermissions; onRequest: () => void }) {
  const insets = useSafeAreaInsets();
  // iOS ne réaffiche jamais sa fenêtre une fois refusée : il faut passer par les Réglages.
  const refused = perms.camera === 'denied' || perms.photos === 'denied';

  return (
    <View style={[styles.welcome, { paddingTop: insets.top + 48, paddingBottom: insets.bottom + 24 }]}>
      <Image source={require('./assets/icon.png')} style={{ width: 96, height: 96, borderRadius: 22, marginBottom: 24 }} />
      <Text style={styles.welcomeTitle}>Bienvenue dans DualCam</Text>
      <Text style={styles.welcomeSubtitle}>
        {refused
          ? "Un accès a été refusé. Ouvrez les Réglages pour l'activer."
          : 'Trois autorisations suffisent pour commencer.'}
      </Text>

      <View style={styles.welcomeCard}>
        <WelcomeRow
          icon="camera.fill"
          title="Appareil photo"
          text="Pour prendre vos photos et vos vidéos."
          state={perms.camera}
        />
        <View style={styles.welcomeSeparator} />
        <WelcomeRow
          icon="mic.fill"
          title="Micro"
          text="Pour le son de vos vidéos."
          state={perms.microphone}
        />
        <View style={styles.welcomeSeparator} />
        <WelcomeRow
          icon="photo.on.rectangle"
          title="Photos"
          text="Pour enregistrer vos clichés dans votre photothèque."
          state={perms.photos}
        />
      </View>

      <View style={{ flex: 1 }} />
      <Pressable
        style={({ pressed }) => [styles.welcomeButton, pressed && { opacity: 0.7 }]}
        onPress={refused ? () => Linking.openSettings() : onRequest}
      >
        <Text style={styles.welcomeButtonText}>{refused ? 'Ouvrir les Réglages' : 'Continuer'}</Text>
      </Pressable>
    </View>
  );
}

function WelcomeRow({ icon, title, text, state }: { icon: SFSymbol; title: string; text: string; state: PermissionState }) {
  return (
    <View style={styles.welcomeRow}>
      <View style={styles.welcomeRowIcon}>
        <Icon name={icon} color={YELLOW} size={20} />
      </View>
      <View style={{ flex: 1 }}>
        <Text style={styles.welcomeRowTitle}>{title}</Text>
        <Text style={styles.welcomeRowText}>{text}</Text>
      </View>
      {state === 'granted' && <Icon name="checkmark.circle.fill" color="#30D158" size={20} />}
      {state === 'denied' && <Icon name="xmark.circle.fill" color="#FF453A" size={20} />}
    </View>
  );
}

// ─────────────────────────────────────────────────────────────
// Petits outils
// ─────────────────────────────────────────────────────────────
const MODES: { key: CaptureModeName; label: string }[] = [
  { key: 'video', label: 'VIDÉO' },
  { key: 'photo', label: 'PHOTO' },
  { key: 'dual', label: 'DUO' },
];

const ASPECT_ORDER: AspectRatio[] = ['4:3', '16:9', '1:1'];
const TIMER_ORDER = [0, 3, 10];
const LAYOUT_ORDER: DualCameraLayout[] = ['stack', 'side', 'pip'];
const LAYOUT_ICON: Record<DualCameraLayout, SFSymbol> = {
  stack: 'rectangle.split.1x2',
  side: 'rectangle.split.2x1',
  pip: 'pip',
};

// Mesures relevées sur l'app Appareil photo (en points, iPhone 15).
const SIDE_MARGIN = 34;
const ROUND = 48;
const SHUTTER = 79;
const SHUTTER_INNER = 67;

/** 1.4 → « 1,4 » */
function formatNumber(value: number) {
  return String(Math.round(value * 10) / 10).replace('.', ',');
}

function formatDuration(seconds: number) {
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  return `${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
}

function flashSymbol(flash: FlashMode): SFSymbol {
  if (flash === 'auto') return 'bolt.badge.automatic.fill';
  if (flash === 'on') return 'bolt.fill';
  return 'bolt.slash.fill';
}

function cycle<T>(list: T[], current: T): T {
  return list[(list.indexOf(current) + 1) % list.length];
}

function Icon({ name, color = '#fff', size = 22 }: { name: SFSymbol; color?: string; size?: number }) {
  return <SymbolView name={name} tintColor={color} size={size} style={{ width: size + 4, height: size + 4 }} />;
}

// ─────────────────────────────────────────────────────────────
// Écran caméra, façon app Appareil photo
// ─────────────────────────────────────────────────────────────
function CameraScreen() {
  const insets = useSafeAreaInsets();
  const { width: screenWidth, height: screenHeight } = useWindowDimensions();

  // Mode et caméra
  const [mode, setMode] = useState<CaptureModeName>('photo');
  const [position, setPosition] = useState<DualCameraSide>('back');
  const [layout, setLayout] = useState<DualCameraLayout>('stack');
  const [swapped, setSwapped] = useState(false);
  const [info, setInfo] = useState<CameraReadyEvent | null>(null);

  // Réglages
  const [flash, setFlash] = useState<FlashMode>('auto');
  const [torch, setTorch] = useState(false);
  const [live, setLive] = useState(true);
  const [aspect, setAspect] = useState<AspectRatio>('4:3');
  const [timer, setTimer] = useState(0);
  const [megapixels, setMegapixels] = useState(24);
  const [heif, setHeif] = useState(true);
  const [showControls, setShowControls] = useState(false);

  // État de prise de vue
  const [zoom, setZoom] = useState(1);
  const [bias, setBias] = useState(0);
  const [countdown, setCountdown] = useState<number | null>(null);
  const [recording, setRecording] = useState(false);
  const [recordSeconds, setRecordSeconds] = useState(0);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [lastThumb, setLastThumb] = useState<string | null>(null);
  const [dial, setDial] = useState<'zoom' | 'exposure' | null>(null);
  // Vidéo : qualité choisie.
  const [videoRes, setVideoRes] = useState<VideoResolution>('HD');
  const [videoFps, setVideoFps] = useState(30);
  const [formatOpen, setFormatOpen] = useState(false);
  // Mode nuit : proposé par l'iPhone quand il fait sombre, on peut le couper en touchant la lune.
  const [night, setNight] = useState({ active: false, seconds: 1 });
  const [nightEnabled, setNightEnabled] = useState(true);
  const [nightCapturing, setNightCapturing] = useState(false);

  // Roulette des modes : largeur de chaque mot, mesurée à l'affichage.
  const [modeLayouts, setModeLayouts] = useState<Record<string, { x: number; w: number }>>({});
  const [capsuleWidth, setCapsuleWidth] = useState(212);
  const modeOffsetReady = useRef(false);

  const countdownRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const dialHideRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const pendingPhotos = useRef(0);
  const shutterScale = useRef(new Animated.Value(1)).current;
  const blackout = useRef(new Animated.Value(1)).current;
  const thumbScale = useRef(new Animated.Value(1)).current;
  const flipTurn = useRef(new Animated.Value(0)).current;
  const modeOffset = useRef(new Animated.Value(0)).current;
  const uiRotation = useRef(new Animated.Value(0)).current;

  const ready = info !== null && info.mode === mode;
  const modeIndex = MODES.findIndex((m) => m.key === mode);
  const zoomSide: DualCameraSide = mode === 'dual' ? 'back' : position;

  // Résolution réellement utilisée (la caméra avant ne fait que 12 Mpx).
  const resolutionList = info?.resolutions?.length ? info.resolutions : [12];
  const effectiveMegapixels = resolutionList.includes(megapixels)
    ? megapixels
    : resolutionList.reduce((a, b) => (Math.abs(b - megapixels) < Math.abs(a - megapixels) ? b : a));
  // Live Photo seulement en 4:3 (sinon la photo est recadrée).
  const liveActive = live && aspect === '4:3';
  const nightAvailable = mode === 'photo' && position === 'back' && night.active;
  // Le flash forcé remplace le mode nuit.
  const nightOn = nightAvailable && nightEnabled && flash !== 'on';

  // ── Position des éléments (mêmes distances que l'app Appareil photo) ──
  const base = Math.max(insets.bottom, 10);
  const modeRowBottom = base;
  const shutterRowBottom = base + 80;
  const zoomRowBottom = base + 190;
  const dialBottom = base + 240;

  const areaTop = insets.top + 58;
  const area43 = (screenWidth * 4) / 3;
  let previewTop = areaTop;
  let previewHeight = area43;
  if (mode === 'video' || (mode === 'photo' && aspect === '16:9')) {
    previewHeight = (screenWidth * 16) / 9;
    previewTop = Math.max(0, Math.min(insets.top - 4, screenHeight - previewHeight));
  } else if (mode === 'photo' && aspect === '1:1') {
    previewHeight = screenWidth;
    previewTop = areaTop + (area43 - screenWidth) / 2;
  }

  // L'image change de taille en glissant (Photo 4:3 ↔ Vidéo 16:9), au lieu de sauter.
  const previewTopAnim = useRef(new Animated.Value(previewTop)).current;
  const previewHeightAnim = useRef(new Animated.Value(previewHeight)).current;
  useEffect(() => {
    const options = { duration: 320, easing: Easing.inOut(Easing.cubic), useNativeDriver: false };
    Animated.parallel([
      Animated.timing(previewTopAnim, { toValue: previewTop, ...options }),
      Animated.timing(previewHeightAnim, { toValue: previewHeight, ...options }),
    ]).start();
  }, [previewTop, previewHeight, previewTopAnim, previewHeightAnim]);

  // Panneau FORMAT : les boutons montent et la rangée du bas s'efface.
  const lift = useRef(new Animated.Value(0)).current;
  const formatVisible = formatOpen && mode === 'video' && !recording;
  useEffect(() => {
    Animated.timing(lift, {
      toValue: formatVisible ? 1 : 0,
      duration: 280,
      easing: Easing.inOut(Easing.cubic),
      useNativeDriver: true,
    }).start();
  }, [formatVisible, lift]);
  // Pendant une photo en mode nuit, tout s'efface sauf le déclencheur.
  const calm = useRef(new Animated.Value(1)).current;
  useEffect(() => {
    Animated.timing(calm, { toValue: nightCapturing ? 0 : 1, duration: 200, useNativeDriver: true }).start();
  }, [nightCapturing, calm]);

  const liftUp = { transform: [{ translateY: lift.interpolate({ inputRange: [0, 1], outputRange: [0, -102] }) }] };

  // Les icônes tournent quand on tient l'iPhone à l'horizontale.
  const rotate = {
    transform: [
      { rotate: uiRotation.interpolate({ inputRange: [-90, 90], outputRange: ['-90deg', '90deg'] }) },
    ],
  };

  // ── Effets ──
  useEffect(() => {
    if (!error) return;
    const t = setTimeout(() => setError(null), 4000);
    return () => clearTimeout(t);
  }, [error]);

  useEffect(
    () => () => {
      if (countdownRef.current) clearInterval(countdownRef.current);
      if (dialHideRef.current) clearTimeout(dialHideRef.current);
    },
    []
  );

  // Roulette des modes : le mode actif est centré.
  const activeModeLayout = modeLayouts[mode];
  useEffect(() => {
    if (!activeModeLayout) return;
    const target = capsuleWidth / 2 - (activeModeLayout.x + activeModeLayout.w / 2);
    if (!modeOffsetReady.current) {
      modeOffsetReady.current = true;
      modeOffset.setValue(target);
    } else {
      Animated.spring(modeOffset, { toValue: target, friction: 9, tension: 70, useNativeDriver: true }).start();
    }
  }, [activeModeLayout, capsuleWidth, modeOffset]);

  // Si l'app passe en arrière-plan, iOS coupe la caméra : on remet l'écran à zéro.
  useEffect(() => {
    const sub = AppState.addEventListener('change', (state) => {
      if (state !== 'active') {
        if (countdownRef.current) clearInterval(countdownRef.current);
        countdownRef.current = null;
        setCountdown(null);
        setRecording(false);
        setShowControls(false);
      }
    });
    return () => sub.remove();
  }, []);

  // Chrono de la vidéo.
  useEffect(() => {
    if (!recording) return;
    setRecordSeconds(0);
    const t = setInterval(() => setRecordSeconds((s) => s + 1), 1000);
    return () => clearInterval(t);
  }, [recording]);

  // ── Changement de mode / caméra ──
  const changeMode = (next: CaptureModeName) => {
    if (next === mode || recording || countdown !== null || nightCapturing) return false;
    if (next === 'dual' && !DualCamera.isMultiCamSupported()) {
      setError('Cet iPhone ne peut pas utiliser les deux caméras en même temps.');
      return false;
    }
    DualCamera.haptic('selection');
    setDial(null);
    setBias(0);
    setFormatOpen(false);
    setMode(next);
    return true;
  };

  const onSwipe = (direction: 'left' | 'right') => {
    const nextIndex = direction === 'left' ? modeIndex + 1 : modeIndex - 1;
    if (nextIndex >= 0 && nextIndex < MODES.length) changeMode(MODES[nextIndex].key);
  };

  const wheel = useRef({ mode, modeLayouts, capsuleWidth, changeMode });
  wheel.current = { mode, modeLayouts, capsuleWidth, changeMode };
  const wheelStart = useRef(0);
  const modePan = useMemo(() => {
    // Décalage de la roulette qui place le mot `key` au centre.
    const centerOffset = (key: string) => {
      const l = wheel.current.modeLayouts[key];
      return l ? wheel.current.capsuleWidth / 2 - (l.x + l.w / 2) : 0;
    };
    const finish = (dx: number) => {
      const offset = wheelStart.current + dx;
      let best = wheel.current.mode;
      let bestDistance = Infinity;
      for (const m of MODES) {
        const distance = Math.abs(centerOffset(m.key) - offset);
        if (distance < bestDistance) {
          bestDistance = distance;
          best = m.key;
        }
      }
      if (best === wheel.current.mode || !wheel.current.changeMode(best)) {
        Animated.spring(modeOffset, {
          toValue: centerOffset(wheel.current.mode),
          friction: 9,
          tension: 70,
          useNativeDriver: true,
        }).start();
      }
    };
    return PanResponder.create({
      onMoveShouldSetPanResponderCapture: (_, g) => Math.abs(g.dx) > 6 && Math.abs(g.dx) > Math.abs(g.dy),
      onPanResponderGrant: () => {
        modeOffset.stopAnimation();
        wheelStart.current = centerOffset(wheel.current.mode);
      },
      onPanResponderMove: (_, g) => {
        const min = centerOffset(MODES[MODES.length - 1].key) - 30;
        const max = centerOffset(MODES[0].key) + 30;
        modeOffset.setValue(Math.max(min, Math.min(max, wheelStart.current + g.dx)));
      },
      // Un geste rapide va un peu plus loin, comme une vraie roulette.
      onPanResponderRelease: (_, g) => finish(g.dx + g.vx * 70),
      onPanResponderTerminate: (_, g) => finish(g.dx),
    });
  }, [modeOffset]);

  const onFlip = () => {
    if (recording || countdown !== null || nightCapturing) return;
    DualCamera.haptic('light');
    Animated.sequence([
      Animated.timing(flipTurn, { toValue: 1, duration: 300, useNativeDriver: true }),
      Animated.timing(flipTurn, { toValue: 0, duration: 0, useNativeDriver: true }),
    ]).start();
    if (mode === 'dual') {
      setSwapped((s) => !s);
      return;
    }
    setBias(0);
    setPosition((p) => (p === 'back' ? 'front' : 'back'));
  };

  // Vidéo : toucher « HD » change la taille, toucher « 30 » change les images par seconde.
  const videoOptions = info?.videoOptions ?? [];
  const currentVideoOption = videoOptions.find((o) => o.resolution === videoRes);
  const pickVideoResolution = (next: VideoOption) => {
    if (recording || next.resolution === videoRes) return;
    DualCamera.haptic('selection');
    setVideoRes(next.resolution);
    if (!next.fps.includes(videoFps)) setVideoFps(next.fps.includes(30) ? 30 : next.fps[0]);
  };
  const pickVideoFps = (fps: number) => {
    if (recording || fps === videoFps) return;
    DualCamera.haptic('selection');
    setVideoFps(fps);
  };

  const nextLayout = () => {
    DualCamera.haptic('selection');
    setLayout((l) => cycle(LAYOUT_ORDER, l));
  };

  // ── Prise de vue ──
  const showThumb = (uri: string) => {
    setLastThumb(uri);
    thumbScale.setValue(0.4);
    Animated.spring(thumbScale, { toValue: 1, friction: 5, useNativeDriver: true }).start();
  };

  const capturePhoto = async () => {
    const useNight = nightOn;
    const flashScreen = () => {
      // L'écran clignote en noir, comme l'app Appareil photo.
      blackout.setValue(1);
      Animated.timing(blackout, { toValue: 0, duration: 250, useNativeDriver: false }).start();
    };
    if (useNight) setNightCapturing(true);
    else flashScreen();
    // On peut enchaîner les photos : on compte celles en cours d'enregistrement.
    pendingPhotos.current += 1;
    setBusy(true);
    try {
      const thumb = await DualCamera.takePhotoAsync({
        flash: info?.hasFlash && !useNight ? flash : 'off',
        live: mode === 'photo' && liveActive && !useNight,
        nightSeconds: useNight ? night.seconds : 0,
        aspect: mode === 'photo' ? aspect : '4:3',
        megapixels: effectiveMegapixels,
        heif,
      });
      if (useNight) {
        flashScreen();
        DualCamera.haptic('success');
      }
      showThumb(thumb);
    } catch (e: any) {
      const message: string = e?.message ?? 'La photo a échoué.';
      // Appui trop rapide pendant la photo précédente : on ignore.
      if (!message.includes('déjà en cours')) setError(message);
    } finally {
      if (useNight) setNightCapturing(false);
      pendingPhotos.current -= 1;
      setBusy(pendingPhotos.current > 0);
    }
  };

  const toggleRecording = async () => {
    try {
      if (recording) {
        setRecording(false);
        setBusy(true);
        const thumb = await DualCamera.stopRecordingAsync();
        showThumb(thumb);
      } else {
        await DualCamera.startRecordingAsync(torch);
        setRecording(true);
      }
    } catch (e: any) {
      setRecording(false);
      setError(e?.message ?? 'La vidéo a échoué.');
    } finally {
      setBusy(false);
    }
  };

  const cancelCountdown = () => {
    if (countdownRef.current) clearInterval(countdownRef.current);
    countdownRef.current = null;
    setCountdown(null);
  };

  const fire = () => (mode === 'video' ? toggleRecording() : capturePhoto());

  const onShutter = () => {
    if (!ready || nightCapturing) return;
    if (countdown !== null) {
      cancelCountdown();
      return;
    }
    if (busy && mode === 'video') return;
    DualCamera.haptic('medium');
    // Le retardateur ne s'applique pas pour arrêter une vidéo.
    if (timer === 0 || recording) {
      fire();
      return;
    }
    let left = timer;
    setCountdown(left);
    countdownRef.current = setInterval(() => {
      left -= 1;
      if (left <= 0) {
        cancelCountdown();
        fire();
      } else {
        DualCamera.haptic('light');
        setCountdown(left);
      }
    }, 1000);
  };

  // ── Zoom ──
  const presets = useMemo(() => {
    // Caméra avant : un seul bouton, comme l'app Appareil photo.
    if (!info || zoomSide === 'front') return [1];
    const list = [info.hasUltraWide ? 0.5 : null, 1, info.maxZoom >= 2 ? 2 : null];
    return list.filter((v): v is number => v !== null);
  }, [info, zoomSide]);
  const activePreset = zoom < 0.95 ? 0.5 : zoom < 1.95 ? 1 : 2;

  const applyZoom = (value: number, animated: boolean) => {
    setZoom(DualCamera.setZoom(zoomSide, value, animated));
  };

  const keepDial = (kind: 'zoom' | 'exposure') => {
    setDial(kind);
    if (dialHideRef.current) clearTimeout(dialHideRef.current);
    dialHideRef.current = setTimeout(() => setDial(null), 2000);
  };

  // Glisser sur les boutons de zoom ouvre la molette.
  const zoomStart = useRef(1);
  const zoomRef = useRef(zoom);
  zoomRef.current = zoom;
  const zoomPan = useMemo(
    () =>
      PanResponder.create({
        onMoveShouldSetPanResponder: (_, g) => Math.abs(g.dx) > 6,
        onPanResponderGrant: () => {
          zoomStart.current = zoomRef.current;
          keepDial('zoom');
        },
        onPanResponderMove: (_, g) => {
          keepDial('zoom');
          applyZoom(zoomStart.current * Math.exp(-g.dx / 120), false);
        },
      }),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [zoomSide]
  );

  // Molette d'exposition.
  const biasStart = useRef(0);
  const biasRef = useRef(bias);
  biasRef.current = bias;
  const exposurePan = useMemo(
    () =>
      PanResponder.create({
        onStartShouldSetPanResponder: () => true,
        onPanResponderGrant: () => {
          biasStart.current = biasRef.current;
          keepDial('exposure');
        },
        onPanResponderMove: (_, g) => {
          keepDial('exposure');
          const value = Math.round((biasStart.current - g.dx / 60) * 10) / 10;
          setBias(DualCamera.setExposureBias(value));
        },
      }),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    []
  );

  // ── Panneau de réglages ──
  type Control = { key: string; label: string; icon?: SFSymbol; text?: string; active?: boolean; onPress: () => void };
  const controls: Control[] = [];
  if (mode === 'video') {
    controls.push({
      key: 'torch',
      label: 'FLASH',
      icon: torch ? 'bolt.fill' : 'bolt.slash.fill',
      active: torch,
      onPress: () => setTorch((t) => !t),
    });
  } else if (info?.hasFlash !== false) {
    controls.push({
      key: 'flash',
      label: 'FLASH',
      icon: flashSymbol(flash),
      active: flash !== 'off',
      onPress: () => setFlash((f) => cycle<FlashMode>(['auto', 'on', 'off'], f)),
    });
  }
  if (mode === 'photo' && info?.liveSupported) {
    controls.push({
      key: 'live',
      label: 'LIVE',
      icon: liveActive ? 'livephoto' : 'livephoto.slash',
      active: liveActive,
      onPress: () => setLive((l) => !l),
    });
  }
  if (mode === 'photo') {
    controls.push({ key: 'aspect', label: 'PROPORTIONS', text: aspect, onPress: () => setAspect((a) => cycle(ASPECT_ORDER, a)) });
  }
  if (mode === 'dual') {
    controls.push({ key: 'layout', label: 'AFFICHAGE', icon: LAYOUT_ICON[layout], onPress: () => setLayout((l) => cycle(LAYOUT_ORDER, l)) });
  }
  controls.push({
    key: 'timer',
    label: 'MINUTEUR',
    icon: 'timer',
    text: timer ? `${timer} s` : undefined,
    active: timer > 0,
    onPress: () => setTimer((t) => cycle(TIMER_ORDER, t)),
  });
  controls.push({
    key: 'exposure',
    label: 'EXPOSITION',
    icon: 'plusminus.circle',
    active: bias !== 0,
    onPress: () => {
      setShowControls(false);
      keepDial('exposure');
    },
  });
  if (mode === 'photo') {
    controls.push({
      key: 'resolution',
      label: 'RÉSOLUTION',
      text: `${heif ? 'HEIF' : 'JPEG'}\n${effectiveMegapixels}`,
      onPress: () => {
        // HEIF 12 → 24 → 48 → JPEG 12 → …
        const index = resolutionList.indexOf(effectiveMegapixels);
        if (heif && index < resolutionList.length - 1) {
          setMegapixels(resolutionList[index + 1]);
        } else if (heif) {
          setHeif(false);
          setMegapixels(resolutionList[0]);
        } else {
          setHeif(true);
          setMegapixels(resolutionList.includes(24) ? 24 : resolutionList[0]);
        }
      },
    });
  }

  const pillWidth = (activeModeLayout?.w ?? 79) + 9;

  // ── Rendu ──
  return (
    <View style={styles.screen}>
      {/* Aperçu */}
      <Animated.View style={[styles.previewBox, { top: previewTopAnim, height: previewHeightAnim }]}>
        <DualCameraView
          style={{ width: screenWidth, height: previewHeight }}
          mode={mode}
          position={position}
          layout={layout}
          swapped={swapped}
          videoResolution={videoRes}
          videoFps={videoFps}
          onCameraReady={(e) => {
            setInfo(e.nativeEvent);
            if (e.nativeEvent.mode === 'video') {
              if (e.nativeEvent.videoResolution) setVideoRes(e.nativeEvent.videoResolution);
              if (e.nativeEvent.videoFps) setVideoFps(e.nativeEvent.videoFps);
            }
            setZoom(e.nativeEvent.zoom);
            setError(null);
            Animated.timing(blackout, { toValue: 0, duration: 250, useNativeDriver: false }).start();
          }}
          onCameraError={(e) => {
            setInfo(null);
            setError(e.nativeEvent.message);
          }}
          steady={nightCapturing}
          onLowLight={(e) => setNight({ active: e.nativeEvent.active, seconds: Math.max(1, e.nativeEvent.seconds) })}
          onZoomChange={(e) => setZoom(e.nativeEvent.zoom)}
          onSwipe={(e) => onSwipe(e.nativeEvent.direction)}
          onShutterButton={onShutter}
          onExposureChange={(e) => setBias(e.nativeEvent.bias)}
          onOrientationChange={(e) =>
            Animated.spring(uiRotation, { toValue: e.nativeEvent.rotation, friction: 8, useNativeDriver: true }).start()
          }
        />
        <Animated.View pointerEvents="none" style={[StyleSheet.absoluteFill, styles.blackout, { opacity: blackout }]} />
        {countdown !== null && (
          <View pointerEvents="none" style={[StyleSheet.absoluteFill, styles.centered]}>
            <Animated.Text style={[styles.countdownText, rotate]}>{countdown}</Animated.Text>
          </View>
        )}
        {nightCapturing && (
          <View pointerEvents="none" style={styles.steadyBox}>
            <Text style={styles.steadyText}>
              Ne bougez plus pendant {night.seconds} seconde{night.seconds > 1 ? 's' : ''}.
            </Text>
          </View>
        )}
      </Animated.View>

      {/* Icônes du haut */}
      <Animated.View pointerEvents="box-none" style={[styles.topBar, { top: insets.top, opacity: calm }]}>
        {recording ? (
          <View style={styles.recordBadge}>
            <Text style={styles.recordText}>{formatDuration(recordSeconds)}</Text>
          </View>
        ) : (
          <View style={styles.topIcons}>
            {mode === 'video' ? (
              <>
                <Pressable hitSlop={10} onPress={() => setTorch((t) => !t)}>
                  <Animated.View style={rotate}>
                    <Icon name={torch ? 'bolt.fill' : 'bolt.slash.fill'} color={torch ? YELLOW : '#fff'} />
                  </Animated.View>
                </Pressable>
                <Pressable
                  hitSlop={12}
                  onPress={() => {
                    DualCamera.haptic('selection');
                    setFormatOpen((open) => !open);
                  }}
                >
                  <Animated.View style={[styles.hdBox, rotate]}>
                    <Text style={styles.hdText}>{videoRes}</Text>
                    <Text style={styles.hdSub}>{videoFps}</Text>
                  </Animated.View>
                </Pressable>
              </>
            ) : (
              <>
                {info?.hasFlash !== false && (
                  <Pressable hitSlop={10} onPress={() => setFlash((f) => cycle<FlashMode>(['auto', 'on', 'off'], f))}>
                    <Animated.View style={rotate}>
                      <Icon name={flashSymbol(flash)} color={flash === 'on' ? YELLOW : '#fff'} />
                    </Animated.View>
                  </Pressable>
                )}
                {mode === 'photo' && info?.liveSupported && (
                  <Pressable hitSlop={10} onPress={() => setLive((l) => !l)}>
                    <Animated.View style={rotate}>
                      <Icon name={liveActive ? 'livephoto' : 'livephoto.slash'} color={liveActive ? YELLOW : '#fff'} />
                    </Animated.View>
                  </Pressable>
                )}
                {nightAvailable && (
                  <Pressable
                    hitSlop={10}
                    onPress={() => {
                      DualCamera.haptic('selection');
                      setNightEnabled((enabled) => !enabled);
                    }}
                  >
                    <Animated.View style={rotate}>
                      <Icon name="moon.fill" color={nightOn ? YELLOW : '#fff'} />
                      {nightOn && <Text style={styles.moonBadge}>{night.seconds}</Text>}
                    </Animated.View>
                  </Pressable>
                )}
              </>
            )}
            {timer > 0 && (
              <Animated.View style={[styles.topChip, rotate]}>
                <Icon name="timer" color={YELLOW} size={16} />
                <Text style={styles.topChipText}>{timer} s</Text>
              </Animated.View>
            )}
            {bias !== 0 && (
              <Pressable onPress={() => setBias(DualCamera.setExposureBias(0))}>
                <Animated.View style={[styles.topChip, rotate]}>
                  <Icon name="plusminus.circle" color={YELLOW} size={16} />
                  <Text style={styles.topChipText}>{formatNumber(bias)}</Text>
                </Animated.View>
              </Pressable>
            )}
          </View>
        )}
      </Animated.View>

      {error && <Text style={[styles.error, { top: areaTop + 10 }]}>{error}</Text>}

      {/* Molettes : zoom ou exposition */}
      {dial === 'zoom' && info && (
        <ZoomDial zoom={zoom} min={info.minZoom} max={info.maxZoom} bottom={dialBottom} width={screenWidth} />
      )}
      {dial === 'exposure' && (
        <View {...exposurePan.panHandlers} style={[styles.dialBox, { bottom: zoomRowBottom }]}>
          <ExposureDial bias={bias} width={screenWidth} />
        </View>
      )}

      {/* Boutons de zoom */}
      {info && dial !== 'exposure' && (
        <Animated.View {...zoomPan.panHandlers} style={[styles.zoomRow, { bottom: zoomRowBottom, opacity: calm }, liftUp]}>
          {presets.map((preset) => {
            const active = preset === activePreset || presets.length === 1;
            return (
              <Pressable
                key={preset}
                hitSlop={4}
                onPress={() => {
                  DualCamera.haptic('selection');
                  applyZoom(preset, true);
                }}
                onLongPress={() => keepDial('zoom')}
                style={[styles.zoomButton, active && styles.zoomButtonActive]}
              >
                {active && <Glass width={38} height={38} radius={19} />}
                <Animated.Text style={[styles.zoomText, active && styles.zoomTextActive, rotate]}>
                  {active ? `${formatNumber(zoom)}×` : formatNumber(preset)}
                </Animated.Text>
              </Pressable>
            );
          })}
        </Animated.View>
      )}

      {/* Rangée du déclencheur */}
      <Animated.View style={[styles.shutterRow, { bottom: shutterRowBottom }, liftUp]}>
        <View style={styles.roundSlot}>
          {mode === 'dual' && !recording && !nightCapturing && (
            <Pressable style={styles.roundButton} onPress={nextLayout}>
              <Glass width={ROUND} height={ROUND} radius={ROUND / 2} />
              <Animated.View style={rotate}>
                <Icon name={LAYOUT_ICON[layout]} size={20} />
              </Animated.View>
            </Pressable>
          )}
          {mode === 'photo' && !nightCapturing && (
            <Pressable
              style={styles.roundButton}
              onPress={() => {
                DualCamera.haptic('selection');
                setAspect((a) => cycle(ASPECT_ORDER, a));
              }}
            >
              <Glass width={ROUND} height={ROUND} radius={ROUND / 2} />
              <Animated.Text style={[styles.roundButtonText, rotate]}>{aspect}</Animated.Text>
            </Pressable>
          )}
        </View>

        <Pressable
          onPress={onShutter}
          disabled={!ready}
          onPressIn={() => Animated.spring(shutterScale, { toValue: 0.9, useNativeDriver: true }).start()}
          onPressOut={() => Animated.spring(shutterScale, { toValue: 1, friction: 4, useNativeDriver: true }).start()}
          style={styles.shutterOuter}
        >
          <Animated.View
            style={[
              styles.shutterInner,
              mode === 'video' && { backgroundColor: RED },
              (recording || countdown !== null) && styles.shutterInnerStop,
              nightCapturing && { backgroundColor: '#8e8e93' },
              { transform: [{ scale: shutterScale }] },
            ]}
          />
        </Pressable>

        <View style={styles.roundSlot}>
          {!recording && !formatVisible && !nightCapturing && (
            <Pressable style={styles.roundButton} onPress={() => setShowControls(true)}>
              <Glass width={ROUND} height={ROUND} radius={ROUND / 2} />
              <Animated.View style={rotate}>
                <DotsGrid />
              </Animated.View>
            </Pressable>
          )}
        </View>
      </Animated.View>

      {/* Rangée du bas : dernière photo, roulette des modes, retourner la caméra */}
      <Animated.View
        pointerEvents={formatVisible || nightCapturing ? 'none' : 'auto'}
        style={[
          styles.modeRow,
          {
            bottom: modeRowBottom,
            opacity: Animated.multiply(calm, lift.interpolate({ inputRange: [0, 0.6], outputRange: [1, 0], extrapolate: 'clamp' })),
          },
        ]}
      >
        <Pressable style={styles.thumbBox} onPress={() => Linking.openURL('photos-redirect://')}>
          <Animated.View style={[StyleSheet.absoluteFill, rotate]}>
            <Animated.View style={[StyleSheet.absoluteFill, { transform: [{ scale: thumbScale }] }]}>
              {lastThumb && <Image source={{ uri: lastThumb }} style={{ width: '100%', height: '100%' }} />}
            </Animated.View>
          </Animated.View>
          {busy && <ActivityIndicator style={StyleSheet.absoluteFill} color="#fff" size="small" />}
        </Pressable>

        <View
          style={[styles.modeCapsule, recording && { opacity: 0 }]}
          pointerEvents={recording ? 'none' : 'auto'}
          onLayout={(e) => setCapsuleWidth(e.nativeEvent.layout.width)}
          {...modePan.panHandlers}
        >
          <Glass width={capsuleWidth} height={ROUND} radius={ROUND / 2} />
          <View style={[styles.modePill, { width: pillWidth, left: capsuleWidth / 2 - pillWidth / 2 }]} />
          <Animated.View style={[styles.modeTrack, { transform: [{ translateX: modeOffset }] }]}>
            {MODES.map((m) => (
              <Pressable
                key={m.key}
                onPress={() => changeMode(m.key)}
                style={styles.modeItem}
                onLayout={(e) => {
                  const { x, width } = e.nativeEvent.layout;
                  setModeLayouts((prev) =>
                    prev[m.key]?.x === x && prev[m.key]?.w === width ? prev : { ...prev, [m.key]: { x, w: width } }
                  );
                }}
              >
                <Text style={[styles.modeText, mode === m.key && styles.modeTextActive]}>{m.label}</Text>
              </Pressable>
            ))}
          </Animated.View>
        </View>

        <Pressable style={styles.roundButton} onPress={onFlip} disabled={recording}>
              <Glass width={ROUND} height={ROUND} radius={ROUND / 2} />
          <Animated.View style={rotate}>
            <Animated.View
              style={{
                transform: [{ rotate: flipTurn.interpolate({ inputRange: [0, 1], outputRange: ['0deg', '180deg'] }) }],
              }}
            >
              <Icon name="arrow.triangle.2.circlepath" size={22} />
            </Animated.View>
          </Animated.View>
        </Pressable>
      </Animated.View>

      {/* Panneau FORMAT du mode Vidéo */}
      <Animated.View
        pointerEvents={formatVisible ? 'auto' : 'none'}
        style={[
          styles.formatPanel,
          {
            bottom: base,
            opacity: lift,
            transform: [{ translateY: lift.interpolate({ inputRange: [0, 1], outputRange: [60, 0] }) }],
          },
        ]}
      >
        <Glass width={screenWidth - 18} height={182} radius={40} />
        <Text style={styles.formatTitle}>FORMAT</Text>
        <Pressable style={styles.formatClose} hitSlop={8} onPress={() => setFormatOpen(false)}>
          <Icon name="xmark" size={15} />
        </Pressable>
        <View style={[styles.formatRow, { top: 68 }]}>
          <Text style={styles.formatLabel}>RÉSOLUTION</Text>
          {videoOptions.map((o) => {
            const selected = o.resolution === videoRes;
            return (
              <Pressable key={o.resolution} style={styles.formatOption} onPress={() => pickVideoResolution(o)}>
                {selected && <View style={styles.formatDot} />}
                <Text style={[styles.formatValue, selected && { color: YELLOW }]}>{o.resolution}</Text>
              </Pressable>
            );
          })}
        </View>
        <View style={[styles.formatRow, { top: 112 }]}>
          <Text style={styles.formatLabel}>IPS</Text>
          {(currentVideoOption?.fps ?? []).map((fps) => {
            const selected = fps === videoFps;
            return (
              <Pressable key={fps} style={styles.formatOption} onPress={() => pickVideoFps(fps)}>
                {selected && <View style={styles.formatDot} />}
                <Text style={[styles.formatValue, selected && { color: YELLOW }]}>{fps}</Text>
              </Pressable>
            );
          })}
        </View>
      </Animated.View>

      {/* Panneau de réglages */}
      <Modal visible={showControls} transparent animationType="slide" onRequestClose={() => setShowControls(false)}>
        <Pressable style={styles.sheetBackdrop} onPress={() => setShowControls(false)}>
          <Pressable style={[styles.sheet, { paddingBottom: insets.bottom + 24 }]} onPress={() => {}}>
            <View style={styles.sheetHandle} />
            <View style={styles.sheetGrid}>
              {controls.map((c) => (
                <Pressable
                  key={c.key}
                  style={styles.sheetItem}
                  onPress={() => {
                    DualCamera.haptic('selection');
                    c.onPress();
                  }}
                >
                  <View style={styles.sheetCircle}>
                    {c.icon && <Icon name={c.icon} color={c.active ? YELLOW : '#fff'} size={26} />}
                    {c.text && !c.icon && <Text style={styles.sheetCircleText}>{c.text}</Text>}
                    {c.text && c.icon && <Text style={styles.sheetSmallText}>{c.text}</Text>}
                  </View>
                  <Text style={styles.sheetLabel}>{c.label}</Text>
                </Pressable>
              ))}
            </View>
          </Pressable>
        </Pressable>
      </Modal>
    </View>
  );
}

/** Icône « six points » du bouton de réglages, comme l'app Appareil photo. */
function DotsGrid() {
  return (
    <View style={styles.dotsGrid}>
      {[0, 1].map((row) => (
        <View key={row} style={styles.dotsRow}>
          <View style={styles.dot} />
          <View style={styles.dot} />
          <View style={styles.dot} />
        </View>
      ))}
    </View>
  );
}

/** Molette de zoom : règle graduée, valeur en jaune, équivalent en millimètres. */
function ZoomDial({ zoom, min, max, bottom, width }: { zoom: number; min: number; max: number; bottom: number; width: number }) {
  const scale = 110; // pixels par « e-fois » de zoom (échelle logarithmique)
  const center = width / 2;
  const ticks: number[] = [];
  for (let z = Math.ceil(min * 10) / 10; z <= Math.min(max, 2) + 1e-6; z += 0.1) ticks.push(Math.round(z * 10) / 10);
  for (let z = 2.5; z <= max + 1e-6; z += 0.5) ticks.push(z);
  const labels = [0.5, 1, 2, 5, 10].filter((z) => z >= min - 1e-6 && z <= max + 1e-6);
  const x = (z: number) => center + (Math.log(z) - Math.log(zoom)) * scale;

  return (
    <View pointerEvents="none" style={[styles.dialBox, { bottom }]}>
      {ticks.map((z) => {
        const major = labels.includes(z);
        return <View key={`t${z}`} style={[styles.tick, { left: x(z), height: major ? 16 : 9, opacity: major ? 1 : 0.6 }]} />;
      })}
      {labels.map((z) => (
        <View key={`l${z}`} style={[styles.dialLabel, { left: x(z) - 30 }]}>
          <Text style={styles.dialLabelText}>{formatNumber(z)}</Text>
          <Text style={styles.dialMm}>{Math.round(26 * z)} MM</Text>
        </View>
      ))}
      <View style={[styles.dialPointer, { left: center - 1 }]} />
      <Text style={[styles.dialValue, { left: center - 40 }]}>{formatNumber(zoom)}×</Text>
    </View>
  );
}

/** Molette d'exposition de -2 à +2. */
function ExposureDial({ bias, width }: { bias: number; width: number }) {
  const step = 60; // pixels par cran de 1
  const center = width / 2;
  const ticks: number[] = [];
  for (let v = -2; v <= 2 + 1e-6; v += 0.2) ticks.push(Math.round(v * 10) / 10);
  const x = (v: number) => center + (v - bias) * step;
  return (
    <View pointerEvents="none" style={StyleSheet.absoluteFill}>
      {ticks.map((v) => {
        const major = Number.isInteger(v);
        return <View key={v} style={[styles.tick, { left: x(v), height: major ? 16 : 9, opacity: major ? 1 : 0.6 }]} />;
      })}
      {[-2, -1, 0, 1, 2].map((v) => (
        <View key={`l${v}`} style={[styles.dialLabel, { left: x(v) - 30 }]}>
          <Text style={styles.dialLabelText}>{v > 0 ? `+${v}` : v}</Text>
        </View>
      ))}
      <View style={[styles.dialPointer, { left: center - 1 }]} />
      <Text style={[styles.dialValue, { left: center - 40 }]}>
        {bias > 0 ? '+' : ''}
        {formatNumber(bias)}
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: '#000' },
  centered: { alignItems: 'center', justifyContent: 'center' },

  // Écran d'accueil
  welcome: { flex: 1, backgroundColor: '#000', paddingHorizontal: 24, alignItems: 'center' },
  welcomeTitle: { color: '#fff', fontSize: 28, fontWeight: '700', textAlign: 'center' },
  welcomeSubtitle: { color: 'rgba(235,235,245,0.6)', fontSize: 16, textAlign: 'center', marginTop: 8, marginBottom: 32 },
  welcomeCard: { alignSelf: 'stretch', backgroundColor: '#1c1c1e', borderRadius: 20, paddingHorizontal: 16 },
  welcomeRow: { flexDirection: 'row', alignItems: 'center', paddingVertical: 14, gap: 14 },
  welcomeRowIcon: { width: 40, height: 40, borderRadius: 20, backgroundColor: '#2c2c2e', alignItems: 'center', justifyContent: 'center' },
  welcomeRowTitle: { color: '#fff', fontSize: 17, fontWeight: '600' },
  welcomeRowText: { color: 'rgba(235,235,245,0.6)', fontSize: 14, marginTop: 2 },
  welcomeSeparator: { height: StyleSheet.hairlineWidth, backgroundColor: '#38383a', marginLeft: 54 },
  welcomeButton: { alignSelf: 'stretch', backgroundColor: YELLOW, borderRadius: 16, paddingVertical: 16, alignItems: 'center' },
  welcomeButtonText: { color: '#000', fontSize: 17, fontWeight: '600' },

  // Aperçu
  previewBox: { position: 'absolute', left: 0, right: 0, backgroundColor: '#000', overflow: 'hidden' },
  blackout: { backgroundColor: '#000' },
  countdownText: { color: '#fff', fontSize: 120, fontWeight: '200' },

  // Haut
  topBar: { position: 'absolute', left: 0, right: 0, height: 44, alignItems: 'center', justifyContent: 'center' },
  topIcons: { flexDirection: 'row', alignItems: 'center', gap: 17 },
  topChip: { flexDirection: 'row', alignItems: 'center', gap: 4 },
  topChipText: { color: YELLOW, fontSize: 13, fontWeight: '600' },
  hdBox: { alignItems: 'center', justifyContent: 'center', height: 26 },
  hdText: { color: '#fff', fontSize: 15, fontWeight: '600', textAlign: 'center', lineHeight: 15 },
  hdSub: { color: '#fff', fontSize: 10.5, fontWeight: '500', textAlign: 'center', lineHeight: 11, fontVariant: ['tabular-nums'] },
  recordBadge: { backgroundColor: RED, borderRadius: 6, paddingHorizontal: 8, paddingVertical: 3 },
  recordText: { color: '#fff', fontSize: 17, fontWeight: '500', fontVariant: ['tabular-nums'] },
  error: { position: 'absolute', left: 20, right: 20, color: '#fff', backgroundColor: 'rgba(255,59,48,0.85)', borderRadius: 10, padding: 10, textAlign: 'center', overflow: 'hidden' },

  // Mode nuit
  steadyBox: { position: 'absolute', top: 12, alignSelf: 'center', backgroundColor: 'rgba(0,0,0,0.6)', borderRadius: 7, paddingHorizontal: 9, paddingVertical: 4 },
  steadyText: { color: '#fff', fontSize: 15, fontWeight: '400' },
  moonBadge: { position: 'absolute', right: -3, top: -2, color: YELLOW, fontSize: 9, fontWeight: '700' },

  // Zoom
  zoomRow: { position: 'absolute', alignSelf: 'center', height: 44, flexDirection: 'row', alignItems: 'center', gap: 1, paddingHorizontal: 16 },
  zoomButton: { width: 38, height: 38, borderRadius: 19, alignItems: 'center', justifyContent: 'center' },
  zoomButtonActive: { backgroundColor: ZOOM_BG },
  zoomText: { color: '#fff', fontSize: 14, fontWeight: '500', fontVariant: ['tabular-nums'] },
  zoomTextActive: { color: YELLOW },

  dialBox: { position: 'absolute', left: 0, right: 0, height: 80, backgroundColor: 'rgba(0,0,0,0.4)', overflow: 'hidden' },
  tick: { position: 'absolute', bottom: 34, width: 1.5, backgroundColor: '#fff' },
  dialLabel: { position: 'absolute', bottom: 2, width: 60, alignItems: 'center' },
  dialLabelText: { color: '#fff', fontSize: 13, fontWeight: '600' },
  dialMm: { color: 'rgba(255,255,255,0.5)', fontSize: 9, fontWeight: '600' },
  dialPointer: { position: 'absolute', bottom: 34, width: 2, height: 24, backgroundColor: YELLOW },
  dialValue: { position: 'absolute', top: 4, width: 80, textAlign: 'center', color: YELLOW, fontSize: 15, fontWeight: '600' },

  // Déclencheur
  shutterRow: { position: 'absolute', left: 0, right: 0, height: 80, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingHorizontal: SIDE_MARGIN },
  roundSlot: { width: ROUND, height: ROUND },
  roundButton: { width: ROUND, height: ROUND, borderRadius: ROUND / 2, backgroundColor: BUTTON_BG, alignItems: 'center', justifyContent: 'center' },
  roundButtonText: { color: '#fff', fontSize: 13, fontWeight: '600' },
  shutterOuter: { width: SHUTTER, height: SHUTTER, borderRadius: SHUTTER / 2, backgroundColor: '#2b2b2d', borderWidth: StyleSheet.hairlineWidth, borderColor: 'rgba(255,255,255,0.18)', alignItems: 'center', justifyContent: 'center' },
  shutterInner: { width: SHUTTER_INNER, height: SHUTTER_INNER, borderRadius: SHUTTER_INNER / 2, backgroundColor: '#fff' },
  shutterInnerStop: { backgroundColor: RED, width: 30, height: 30, borderRadius: 7 },

  dotsGrid: { width: 18, height: 11.5, justifyContent: 'space-between' },
  dotsRow: { flexDirection: 'row', justifyContent: 'space-between' },
  dot: { width: 5, height: 5, borderRadius: 2.5, backgroundColor: '#fff' },

  // Rangée du bas
  modeRow: { position: 'absolute', left: 0, right: 0, height: ROUND, flexDirection: 'row', alignItems: 'center', paddingHorizontal: SIDE_MARGIN },
  thumbBox: { width: ROUND, height: ROUND, borderRadius: ROUND / 2, overflow: 'hidden', backgroundColor: '#1e1e1f' },
  modeCapsule: { flex: 1, height: ROUND, marginHorizontal: 9, borderRadius: ROUND / 2, backgroundColor: CAPSULE_BG, overflow: 'hidden' },
  modePill: { position: 'absolute', top: 3.5, bottom: 3.5, borderRadius: 21, backgroundColor: '#242426', borderWidth: StyleSheet.hairlineWidth, borderColor: 'rgba(255,255,255,0.22)' },
  modeTrack: { position: 'absolute', left: 0, top: 0, flexDirection: 'row' },
  modeItem: { height: ROUND, paddingHorizontal: 16.5, alignItems: 'center', justifyContent: 'center' },
  modeText: { color: 'rgba(255,255,255,0.92)', fontSize: 14, fontWeight: '400', letterSpacing: 0.2 },
  modeTextActive: { color: YELLOW },

  // Panneau FORMAT (mesures relevées sur l'app Appareil photo)
  formatPanel: { position: 'absolute', left: 9, right: 9, height: 182, borderRadius: 40, backgroundColor: PANEL_BG, overflow: 'hidden', borderWidth: StyleSheet.hairlineWidth, borderColor: 'rgba(255,255,255,0.16)' },
  formatTitle: { position: 'absolute', top: 20, left: 0, right: 0, textAlign: 'center', color: '#fff', fontSize: 13.5, lineHeight: 16, fontWeight: '400', letterSpacing: 1.6 },
  formatClose: { position: 'absolute', left: 24, top: 25, width: 36, height: 36, borderRadius: 18, backgroundColor: 'rgba(255,255,255,0.08)', alignItems: 'center', justifyContent: 'center' },
  formatRow: { position: 'absolute', left: 50, right: 0, height: 30, flexDirection: 'row', alignItems: 'center' },
  formatLabel: { width: 86, color: '#fff', fontSize: 10, fontWeight: '500', letterSpacing: 1 },
  formatOption: { width: 61, height: 30, alignItems: 'center', justifyContent: 'center' },
  formatValue: { color: '#fff', fontSize: 14.5, fontWeight: '600', fontVariant: ['tabular-nums'] },
  formatDot: { position: 'absolute', left: 9, top: 12.5, width: 5, height: 5, borderRadius: 2.5, backgroundColor: YELLOW },

  // Panneau de réglages
  sheetBackdrop: { flex: 1, justifyContent: 'flex-end' },
  sheet: { backgroundColor: '#1c1c1e', borderRadius: 38, paddingTop: 10, marginHorizontal: 8, marginBottom: 8 },
  sheetHandle: { alignSelf: 'center', width: 40, height: 5, borderRadius: 3, backgroundColor: '#555', marginBottom: 18 },
  sheetGrid: { flexDirection: 'row', flexWrap: 'wrap', justifyContent: 'center' },
  sheetItem: { width: '33%', alignItems: 'center', marginBottom: 22 },
  sheetCircle: { width: 68, height: 68, borderRadius: 34, backgroundColor: '#111', alignItems: 'center', justifyContent: 'center' },
  sheetCircleText: { color: '#fff', fontSize: 16, fontWeight: '600', textAlign: 'center' },
  sheetSmallText: { color: YELLOW, fontSize: 11, fontWeight: '600', marginTop: 2 },
  sheetLabel: { color: '#fff', fontSize: 12, fontWeight: '500', letterSpacing: 1.5, marginTop: 10 },
});
