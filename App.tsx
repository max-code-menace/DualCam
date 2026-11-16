import { StatusBar } from 'expo-status-bar';
import { ReactNode, useCallback, useEffect, useState } from 'react';
import {
  ActivityIndicator,
  AppState,
  Image,
  Linking,
  Modal,
  Pressable,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaProvider, useSafeAreaInsets } from 'react-native-safe-area-context';

import DualCamera, {
  DualCameraLayout,
  DualCameraPermissions,
  DualCameraView,
} from './modules/dual-camera';

export default function App() {
  return (
    <SafeAreaProvider>
      <StatusBar style="light" />
      <Root />
    </SafeAreaProvider>
  );
}

// ─────────────────────────────────────────────────────────────
// Étape 4 : vérifie le support multi-caméra et les permissions
// ─────────────────────────────────────────────────────────────
function Root() {
  const [supported] = useState(() => DualCamera.isMultiCamSupported());
  const [perms, setPerms] = useState<DualCameraPermissions | null>(null);

  const refresh = useCallback(async () => {
    setPerms(await DualCamera.getPermissionsAsync());
  }, []);

  useEffect(() => {
    refresh();
    // Quand on revient des Réglages, on relit les permissions.
    const sub = AppState.addEventListener('change', (state) => {
      if (state === 'active') refresh();
    });
    return () => sub.remove();
  }, [refresh]);

  if (!supported) {
    return (
      <Message
        title="Appareil non compatible"
        text="Cet iPhone ne peut pas utiliser la caméra avant et arrière en même temps. Il faut un iPhone XS / XR ou plus récent."
      />
    );
  }

  if (!perms) {
    return (
      <View style={styles.center}>
        <ActivityIndicator color="#fff" />
      </View>
    );
  }

  if (perms.camera !== 'granted' || perms.photos !== 'granted') {
    return (
      <PermissionScreen
        perms={perms}
        onRequest={async () => setPerms(await DualCamera.requestPermissionsAsync())}
      />
    );
  }

  return <CameraScreen />;
}

function PermissionScreen({
  perms,
  onRequest,
}: {
  perms: DualCameraPermissions;
  onRequest: () => void;
}) {
  // iOS ne réaffiche jamais la pop-up une fois refusée : il faut passer par les Réglages.
  const refused = perms.camera === 'denied' || perms.photos === 'denied';

  return (
    <Message
      title="Autorisations nécessaires"
      text={
        refused
          ? "Vous avez refusé l'accès. Ouvrez les Réglages et activez « Appareil photo » et « Photos » pour DualCam."
          : "DualCam a besoin de la caméra pour filmer avec l'avant et l'arrière, et de l'accès aux Photos pour enregistrer vos clichés."
      }
    >
      <PermissionRow label="Caméra" state={perms.camera} />
      <PermissionRow label="Photos (ajout)" state={perms.photos} />
      <Pressable
        style={styles.primaryButton}
        onPress={refused ? () => Linking.openSettings() : onRequest}
      >
        <Text style={styles.primaryButtonText}>
          {refused ? 'Ouvrir les Réglages' : 'Autoriser'}
        </Text>
      </Pressable>
    </Message>
  );
}

function PermissionRow({ label, state }: { label: string; state: string }) {
  const icon = state === 'granted' ? '✅' : state === 'denied' ? '❌' : '⏳';
  return (
    <Text style={styles.permRow}>
      {icon} {label}
    </Text>
  );
}

// ─────────────────────────────────────────────────────────────
// Étapes 1 à 3 : aperçu, bouton photo, sauvegarde + miniature
// ─────────────────────────────────────────────────────────────
function CameraScreen() {
  const insets = useSafeAreaInsets();
  const [layout, setLayout] = useState<DualCameraLayout>('stack');
  const [ready, setReady] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [lastPhoto, setLastPhoto] = useState<string | null>(null);
  const [showPhoto, setShowPhoto] = useState(false);

  const takePhoto = async () => {
    if (!ready || busy) return;
    setBusy(true);
    setError(null);
    try {
      const uri = await DualCamera.takePhotoAsync(layout);
      setLastPhoto(uri);
    } catch (e: any) {
      setError(e?.message ?? 'La photo a échoué.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <View style={[styles.screen, { paddingTop: insets.top, paddingBottom: insets.bottom + 12 }]}>
      {/* Choix de la disposition */}
      <View style={styles.layoutSwitch}>
        <LayoutButton label="Haut / Bas" active={layout === 'stack'} onPress={() => setLayout('stack')} />
        <LayoutButton label="Incrustation" active={layout === 'pip'} onPress={() => setLayout('pip')} />
      </View>

      {/* Aperçu en direct des deux caméras (même cadrage 3:4 que la photo finale) */}
      <View style={styles.previewBox}>
        <DualCameraView
          style={StyleSheet.absoluteFill}
          layout={layout}
          onCameraReady={() => {
            setReady(true);
            setError(null);
          }}
          onCameraError={(e) => {
            setReady(false);
            setError(e.nativeEvent.message);
          }}
        />
        {!ready && !error && <ActivityIndicator style={StyleSheet.absoluteFill} color="#fff" />}
      </View>

      {error && <Text style={styles.error}>{error}</Text>}

      {/* Barre du bas : miniature + bouton rond */}
      <View style={styles.bottomBar}>
        <Pressable style={styles.thumbBox} onPress={() => lastPhoto && setShowPhoto(true)}>
          {lastPhoto && <Image source={{ uri: lastPhoto }} style={styles.thumb} />}
        </Pressable>

        <Pressable
          onPress={takePhoto}
          disabled={!ready || busy}
          style={({ pressed }) => [styles.shutterOuter, (pressed || busy) && { opacity: 0.6 }]}
        >
          {busy ? <ActivityIndicator color="#000" /> : <View style={styles.shutterInner} />}
        </Pressable>

        <View style={styles.thumbBox} />
      </View>

      {/* Affichage en grand de la dernière photo */}
      <Modal visible={showPhoto} animationType="fade" onRequestClose={() => setShowPhoto(false)}>
        <Pressable style={styles.viewer} onPress={() => setShowPhoto(false)}>
          {lastPhoto && <Image source={{ uri: lastPhoto }} style={styles.viewerImage} resizeMode="contain" />}
          <Text style={styles.viewerHint}>Enregistrée dans Photos · touchez pour fermer</Text>
        </Pressable>
      </Modal>
    </View>
  );
}

function LayoutButton({ label, active, onPress }: { label: string; active: boolean; onPress: () => void }) {
  return (
    <Pressable onPress={onPress} style={[styles.layoutButton, active && styles.layoutButtonActive]}>
      <Text style={[styles.layoutButtonText, active && styles.layoutButtonTextActive]}>{label}</Text>
    </Pressable>
  );
}

function Message({ title, text, children }: { title: string; text: string; children?: ReactNode }) {
  return (
    <View style={styles.center}>
      <Text style={styles.title}>{title}</Text>
      <Text style={styles.text}>{text}</Text>
      {children}
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: '#000' },
  center: { flex: 1, backgroundColor: '#000', alignItems: 'center', justifyContent: 'center', padding: 32 },
  title: { color: '#fff', fontSize: 24, fontWeight: '700', marginBottom: 12, textAlign: 'center' },
  text: { color: '#ccc', fontSize: 16, lineHeight: 22, textAlign: 'center', marginBottom: 24 },
  permRow: { color: '#fff', fontSize: 16, marginBottom: 8 },
  primaryButton: { backgroundColor: '#fff', borderRadius: 999, paddingHorizontal: 28, paddingVertical: 14, marginTop: 16 },
  primaryButtonText: { color: '#000', fontSize: 16, fontWeight: '600' },

  layoutSwitch: { flexDirection: 'row', alignSelf: 'center', backgroundColor: '#222', borderRadius: 999, padding: 4, marginVertical: 10 },
  layoutButton: { paddingHorizontal: 16, paddingVertical: 8, borderRadius: 999 },
  layoutButtonActive: { backgroundColor: '#fff' },
  layoutButtonText: { color: '#fff', fontSize: 14, fontWeight: '500' },
  layoutButtonTextActive: { color: '#000' },

  previewBox: { width: '100%', aspectRatio: 3 / 4, backgroundColor: '#111', justifyContent: 'center' },
  error: { color: '#ff6b6b', textAlign: 'center', marginTop: 10, paddingHorizontal: 20 },

  bottomBar: { flex: 1, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-around', minHeight: 110 },
  thumbBox: { width: 56, height: 56, borderRadius: 10, overflow: 'hidden', backgroundColor: '#1a1a1a' },
  thumb: { width: '100%', height: '100%' },
  shutterOuter: { width: 78, height: 78, borderRadius: 39, borderWidth: 4, borderColor: '#fff', alignItems: 'center', justifyContent: 'center' },
  shutterInner: { width: 62, height: 62, borderRadius: 31, backgroundColor: '#fff' },

  viewer: { flex: 1, backgroundColor: '#000', justifyContent: 'center' },
  viewerImage: { width: '100%', height: '85%' },
  viewerHint: { color: '#aaa', textAlign: 'center', marginTop: 12 },
});
