import React, { useState, useEffect, useCallback } from 'react';
import {
  SafeAreaView,
  View,
  Text,
  TouchableOpacity,
  Modal,
  StyleSheet,
  ScrollView,
  NativeEventEmitter,
  NativeModules,
  Platform,
  ActivityIndicator,
  Alert,
  Dimensions, // Added to perform safe screen-boundary clamping math
  LayoutAnimation, // Animate the sheet smoothly as its height changes
  UIManager,
} from 'react-native';
import CardView from './CardView';

const { ApplePayModule, CardModule } = NativeModules;
const PUBLIC_KEY = ENV.PUBLIC_KEY; // Ensure this is set in your environment variables
const SECRET_KEY = ENV.SECRET_KEY; // Ensure this is set in your environment variables
const API_BASE_URL = 'https://api.sandbox.checkout.com';

// Setup explicit viewport measurements
const SCREEN_HEIGHT = Dimensions.get('window').height;
const MAX_SHEET_HEIGHT = SCREEN_HEIGHT * 0.85; // Capping layout boundaries at 85%

// Non-card chrome inside the sheet, measured from the styles below so the sheet
// hugs the card exactly (no dead space, no clipping):
//   paddingTop (24) + header height (30) + header marginBottom (24)
const SHEET_CHROME_HEIGHT = 78;
// Our own Pay button lives below the card on iOS (56 height + 16 marginTop).
// On Android the SDK renders its own button inside the card, so no extra space.
const PAY_BUTTON_AREA = Platform.OS === 'ios' ? 72 : 0;
// Breathing room below the card, above the home indicator.
const SHEET_BOTTOM_INSET = 34;
const SHEET_FOOTPRINT = SHEET_CHROME_HEIGHT + PAY_BUTTON_AREA + SHEET_BOTTOM_INSET;

// LayoutAnimation needs to be explicitly enabled on Android.
if (Platform.OS === 'android' && UIManager.setLayoutAnimationEnabledExperimental) {
  UIManager.setLayoutAnimationEnabledExperimental(true);
}

interface CapturedCard {
  last4: string;
  scheme: string;
  expiryMonth: number;
  expiryYear: number;
}

const App = () => {
  const [modalVisible, setModalVisible] = useState(false);
  const [isLoadingSession, setIsLoadingSession] = useState(false);
  
  // Track precise form pixels received via bridge events
  const [sheetHeight, setSheetHeight] = useState<number | null>(null);

  // True while a submit() has been dispatched to the native card component.
  const [isSubmitting, setIsSubmitting] = useState(false);

  const [session, setSession] = useState({ id: '', secret: '' });
  const [capturedCard, setCapturedCard] = useState<CapturedCard | null>(null);

  useEffect(() => {
    const module = Platform.OS === 'ios' ? ApplePayModule : CardModule;
    if (!module) return;

    const emitter = new NativeEventEmitter(module);

    let submitSub: any;
    if (Platform.OS === 'android') {
      // Match iOS: when the SDK's Pay button is tapped, show a processing state and
      // keep the sheet open. It closes on onFlowPaymentSuccess (or re-enables on error).
      submitSub = emitter.addListener('onCardSubmitted', () => {
        setIsSubmitting(true);
      });
    }

    const successSub = emitter.addListener('onFlowPaymentSuccess', async (event) => {
      setIsSubmitting(false);
      setModalVisible(false);
      await verifyAndFetchCardDetails(event.paymentId);
    });

    const errorSub = emitter.addListener('onFlowPaymentError', (event) => {
      setIsSubmitting(false);
      console.warn('[App] Flow payment error:', event?.errorMessage);
    });

    return () => {
      submitSub?.remove();
      successSub.remove();
      errorSub.remove();
    };
  }, []);

  const verifyAndFetchCardDetails = async (paymentId: string) => {
    try {
      const response = await fetch(`${API_BASE_URL}/payments/${paymentId}`, {
        method: 'GET',
        headers: {
          'Authorization': `Bearer ${SECRET_KEY}`,
          'Content-Type': 'application/json',
        },
      });
      const data = await response.json();
      if (data.status === 'Captured' || data.status === 'Authorized') {
        setCapturedCard({
          last4: data.source.last4,
          scheme: data.source.scheme,
          expiryMonth: data.source.expiry_month,
          expiryYear: data.source.expiry_year,
        });
      }
    } catch (error) {
      console.error('[App] Failed to fetch payment details:', error);
    }
  };

  const handleAddCardPress = async () => {
    setIsLoadingSession(true);
    setIsSubmitting(false);
    setSheetHeight(null); // Clear out historical measurements for the fresh mounting animation
    try {
      setSession({ id: '', secret: '' });
      const response = await fetch(`${API_BASE_URL}/payment-sessions`, {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${SECRET_KEY}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          amount: 2500, 
          currency: 'AED',
          reference: `REF-${Date.now()}`,
          processing_channel_id: 'pc_6qct6ules7be7ncuamo6wekciq',
          billing: { address: { country: 'AE' }, phone: { country_code: "966", number: "551234567" } },
          customer: { email: "naveed@yopmail.com", phone: { country_code: "966", number: "551234567" } },
          "3ds": { enabled: true },
          success_url: 'https://example.com/success',
          failure_url: 'https://example.com/failure',
          payment_method_configuration: { card: { store_payment_details: "enabled" } }
        }),
      });

      const data = await response.json();
      if (data.id) {
        setSession({ id: data.id, secret: data.payment_session_secret });
        setModalVisible(true);
      } else {
        Alert.alert('Error', 'Could not create payment session');
      }
    } catch (error) {
      console.error('[App] Session creation failed:', error);
      Alert.alert('Error', 'Network request failed');
    } finally {
      setIsLoadingSession(false);
    }
  };

  const handleHeightChange = useCallback((event: any) => {
    const nativeHeight = event.nativeEvent.height;
    // Ignore empty / sub-pixel-noise reports so the sheet doesn't jitter.
    if (!nativeHeight || (sheetHeight !== null && Math.abs(sheetHeight - nativeHeight) < 1)) {
      return;
    }
    // Grow/shrink the sheet with a smooth animation instead of snapping.
    LayoutAnimation.configureNext(LayoutAnimation.Presets.easeInEaseOut);
    setSheetHeight(nativeHeight);
  }, [sheetHeight]);

  // Trigger the native card component's submit() via the bridge. Submitting an
  // invalid form makes the SDK surface inline field errors (and the sheet grows
  // to fit them), so we always dispatch and let the SDK validate.
  const handlePayPress = useCallback(async () => {
    if (!session.id || isSubmitting) return;
    try {
      setIsSubmitting(true);
      await ApplePayModule.submit(session.id);
    } catch (error) {
      // submit request itself failed (e.g. component not ready) — re-enable.
      setIsSubmitting(false);
      console.warn('[App] Card submit request failed:', error);
    }
  }, [session.id, isSubmitting]);

  // Layout calculations to control the bottom sheet box dimensions explicitly.
  // The sheet always equals the measured card height plus fixed chrome, so it
  // hugs the card: no empty space and no overlap/clipping.
  const formHeight = sheetHeight || 450;
  const computedBottomSheetHeight = Math.min(formHeight + SHEET_FOOTPRINT, MAX_SHEET_HEIGHT);
  const isScrollEnabled = (formHeight + SHEET_FOOTPRINT) >= MAX_SHEET_HEIGHT;

  return (
    <SafeAreaView style={styles.container}>
      <View style={styles.content}>
        <Text style={styles.header}>Payment methods</Text>

        <ScrollView style={styles.list} showsVerticalScrollIndicator={false}>
          <View style={styles.methodItem}>
            <Text style={styles.methodText}>💵 Cash</Text>
          </View>
          <View style={styles.methodItem}>
            <Text style={styles.methodText}> Apple Pay</Text>
          </View>

          {capturedCard && (
            <View style={[styles.methodItem, styles.capturedItem]}>
              <View>
                <Text style={styles.methodText}>
                  💳 {capturedCard.scheme.toUpperCase()} •••• {capturedCard.last4}
                </Text>
                <Text style={styles.subText}>
                  Expires {capturedCard.expiryMonth}/{capturedCard.expiryYear}
                </Text>
              </View>
              <View style={styles.capturedBadge}>
                <Text style={styles.capturedBadgeText}>CAPTURED</Text>
              </View>
            </View>
          )}
        </ScrollView>

        <TouchableOpacity
          style={styles.addCardButton}
          onPress={handleAddCardPress}
          disabled={isLoadingSession}
        >
          {isLoadingSession ? (
            <ActivityIndicator color="#fff" />
          ) : (
            <Text style={styles.addCardButtonText}>Add card</Text>
          )}
        </TouchableOpacity>
      </View>

      {/* Card Entry Bottom Sheet */}
      <Modal
        visible={modalVisible}
        animationType="slide"
        transparent={true}
        onRequestClose={() => setModalVisible(false)}
      >
        <View style={styles.modalOverlay}>
          {/* Apply the computed pixel heights explicitly to this root element layout wrapper */}
          <View style={[styles.bottomSheet, { height: computedBottomSheetHeight }]}>
            <View style={styles.sheetHeader}>
              <Text style={styles.sheetTitle}>Add card</Text>
              <TouchableOpacity onPress={() => setModalVisible(false)} style={styles.closeArea}>
                <Text style={styles.closeIcon}>✕</Text>
              </TouchableOpacity>
            </View>

            {/* The scroll engine handles vertical overflow only when structural content exceeds the 85% limit */}
            <ScrollView
              style={styles.sheetScrollView}
              contentContainerStyle={styles.sheetScrollContent}
              scrollEnabled={isScrollEnabled}
              bounces={isScrollEnabled}
              showsVerticalScrollIndicator={isScrollEnabled}
            >
              <View style={styles.nativeComponentContainer}>
                {session.id ? (
                  <CardView
                    style={[styles.nativeCard, { height: formHeight }]}
                    paymentSessionID={session.id}
                    paymentSessionSecret={session.secret}
                    publicKey={PUBLIC_KEY}
                    onHeightChange={handleHeightChange}
                    // iOS: hide the SDK's button and drive submit from ours below.
                    {...(Platform.OS === 'ios' ? { showPayButton: false } : {})}
                  />
                ) : (
                  <View style={styles.loadingCenter}>
                    <ActivityIndicator size="large" color="#FF6B6B" />
                    <Text style={styles.loadingText}>Initializing secure form...</Text>
                  </View>
                )}
              </View>
            </ScrollView>

            {/* iOS: our own Pay button drives the native card component's submit() */}
            {Platform.OS === 'ios' && (
              <TouchableOpacity
                style={[styles.payButton, (!session.id || isSubmitting) && styles.payButtonDisabled]}
                onPress={handlePayPress}
                disabled={!session.id || isSubmitting}
              >
                {isSubmitting ? (
                  <ActivityIndicator color="#fff" />
                ) : (
                  <Text style={styles.payButtonText}>Pay</Text>
                )}
              </TouchableOpacity>
            )}

            {/* Android: the SDK renders its own Pay button, so we surface the
                processing state with an overlay instead of closing the sheet. */}
            {Platform.OS === 'android' && isSubmitting && (
              <View style={styles.processingOverlay}>
                <ActivityIndicator size="large" color="#FF6B6B" />
                <Text style={styles.processingText}>Processing…</Text>
              </View>
            )}
          </View>
        </View>
      </Modal>
    </SafeAreaView>
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#FFFFFF',
  },
  content: {
    flex: 1,
    padding: 24,
  },
  header: {
    fontSize: 26,
    fontWeight: '800',
    color: '#00083D',
    marginBottom: 32,
    marginTop: 20,
  },
  list: {
    flex: 1,
  },
  methodItem: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    paddingVertical: 20,
    borderBottomWidth: 1,
    borderBottomColor: '#F0F0F2',
  },
  methodText: {
    fontSize: 16,
    fontWeight: '600',
    color: '#00083D',
  },
  capturedItem: {
    backgroundColor: '#F9F9FB',
    paddingHorizontal: 12,
    borderRadius: 12,
    marginTop: 8,
    borderBottomWidth: 0,
  },
  subText: {
    fontSize: 13,
    color: '#727272',
    marginTop: 4,
  },
  capturedBadge: {
    backgroundColor: '#E8F5E9',
    paddingHorizontal: 8,
    paddingVertical: 4,
    borderRadius: 6,
  },
  capturedBadgeText: {
    color: '#2E7D32',
    fontSize: 11,
    fontWeight: '700',
  },
  addCardButton: {
    backgroundColor: '#FF6B6B',
    height: 56,
    borderRadius: 28,
    justifyContent: 'center',
    alignItems: 'center',
    shadowColor: '#FF6B6B',
    shadowOffset: { width: 0, height: 4 },
    shadowOpacity: 0.3,
    shadowRadius: 8,
    elevation: 5,
  },
  addCardButtonText: {
    color: '#FFFFFF',
    fontSize: 16,
    fontWeight: '700',
  },
  modalOverlay: {
    flex: 1,
    backgroundColor: 'rgba(0,0,0,0.45)',
    justifyContent: 'flex-end',
  },
  bottomSheet: {
    backgroundColor: '#FFFFFF',
    borderTopLeftRadius: 30,
    borderTopRightRadius: 30,
    paddingHorizontal: 24,
    paddingTop: 24,
    paddingBottom: 34, // SHEET_BOTTOM_INSET — accounted for in SHEET_FOOTPRINT
    width: '100%',
  },
  sheetHeader: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    marginBottom: 24,
    height: 30,
  },
  sheetTitle: {
    fontSize: 22,
    fontWeight: '700',
    color: '#00083D',
  },
  closeArea: {
    padding: 8,
  },
  closeIcon: {
    fontSize: 20,
    color: '#999CB3',
    fontWeight: '600',
  },
  sheetScrollView: {
    width: '100%',
    flex: 1,
  },
  sheetScrollContent: {
    flexGrow: 1,
  },
  nativeComponentContainer: {
    width: '100%',
  },
  nativeCard: {
    width: '100%',
  },
  payButton: {
    backgroundColor: '#FF6B6B',
    height: 56,
    borderRadius: 28,
    justifyContent: 'center',
    alignItems: 'center',
    marginTop: 16,
  },
  payButtonDisabled: {
    opacity: 0.5,
  },
  payButtonText: {
    color: '#FFFFFF',
    fontSize: 16,
    fontWeight: '700',
  },
  loadingCenter: {
    height: 450,
    justifyContent: 'center',
    alignItems: 'center',
  },
  loadingText: {
    marginTop: 16,
    color: '#727272',
    fontSize: 14,
  },
  processingOverlay: {
    ...StyleSheet.absoluteFillObject,
    backgroundColor: 'rgba(255,255,255,0.9)',
    justifyContent: 'center',
    alignItems: 'center',
    borderTopLeftRadius: 30,
    borderTopRightRadius: 30,
  },
  processingText: {
    marginTop: 16,
    color: '#00083D',
    fontSize: 16,
    fontWeight: '600',
  },
});

export default App;