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
} from 'react-native';
import CardView from './CardView';

// Constants
const { ApplePayModule, CardModule } = NativeModules;
const PUBLIC_KEY = 'pk_sbox_xxx';
const SECRET_KEY = 'sk_sbox_xxx'; // Replace with your real Secret Key (should be handled by backend in prod)
const API_BASE_URL = 'https://api.sandbox.checkout.com';

interface CapturedCard {
  last4: string;
  scheme: string;
  expiryMonth: number;
  expiryYear: number;
}

const App = () => {
  // UI State
  const [modalVisible, setModalVisible] = useState(false);
  const [isLoadingSession, setIsLoadingSession] = useState(false);

  // Data State
  const [session, setSession] = useState({ id: '', secret: '' });
  const [capturedCard, setCapturedCard] = useState<CapturedCard | null>(null);

  /**
   * 1. Setup Native Listeners
   * We listen for the 'onFlowPaymentSuccess' event emitted by the Swift CardPayView
   */
useEffect(() => {
  const module = Platform.OS === 'ios' ? ApplePayModule : CardModule;
  if (!module) return;

  const emitter = new NativeEventEmitter(module);

  // Fix: Only add this listener on Android to avoid the iOS "not a supported event" crash
  let submitSub: any;
  if (Platform.OS === 'android') {
    submitSub = emitter.addListener('onCardSubmitted', () => {
      setModalVisible(false);
    });
  }

  const successSub = emitter.addListener('onFlowPaymentSuccess', async (event) => {
    setModalVisible(false); 
    await verifyAndFetchCardDetails(event.paymentId);
  });

  return () => {
    submitSub?.remove(); // Use optional chaining here
    successSub.remove();
  };
}, []);

  /**
   * 2. Fetch Payment Details
   * Calls Checkout API to verify status and get card metadata (last4, scheme)
   */
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

  /**
   * 3. Start Payment Session
   * Fetches a fresh session ID/Secret from Checkout.com
   */
  const handleAddCardPress = async () => {
    setIsLoadingSession(true);
    try {
      // Clear old session to force native re-mount
      setSession({ id: '', secret: '' });

      const response = await fetch(`${API_BASE_URL}/payment-sessions`, {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${SECRET_KEY}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          amount: 2500, // 25.00 AED
          currency: 'AED',
          reference: `REF-${Date.now()}`,
          processing_channel_id: 'pc_ticd6t2rrmnujacakafvukhbwu',
          billing: { address: { country: 'AE' }, phone: {
              country_code: "966",
              number: "551234567"
            } },
          customer: {
            email: "naveed@yopmail.com",
            phone: {
              country_code: "966",
              number: "551234567"
            }
          },
          "3ds": { enabled: true },
          success_url: 'https://example.com/success', // Not used in this flow but required by API
          failure_url: 'https://example.com/failure', // Not used in this flow but required by API
          payment_method_configuration: {
            card: {
              store_payment_details: "enabled"
            }
          }
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

  return (
    <SafeAreaView style={styles.container}>
      <View style={styles.content}>
        <Text style={styles.header}>Payment methods</Text>

        <ScrollView style={styles.list} showsVerticalScrollIndicator={false}>
          {/* Default Options */}
          <View style={styles.methodItem}>
            <Text style={styles.methodText}>💵 Cash</Text>
          </View>

          <View style={styles.methodItem}>
            <Text style={styles.methodText}> Apple Pay</Text>
          </View>

          {/* Captured Card Row */}
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
          <View style={styles.bottomSheet}>
            <View style={styles.sheetHeader}>
              <Text style={styles.sheetTitle}>Add card</Text>
              <TouchableOpacity onPress={() => setModalVisible(false)} style={styles.closeArea}>
                <Text style={styles.closeIcon}>✕</Text>
              </TouchableOpacity>
            </View>

            <View style={styles.nativeComponentContainer}>
              {session.id ? (
                <CardView
                  style={styles.nativeCard}
                  paymentSessionID={session.id}
                  paymentSessionSecret={session.secret}
                  publicKey={PUBLIC_KEY}
                // paymentMethod="card"
                />
              ) : (
                <View style={styles.loadingCenter}>
                  <ActivityIndicator size="large" color="#FF6B6B" />
                  <Text style={styles.loadingText}>Initializing secure form...</Text>
                </View>
              )}
            </View>
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
    height: '85%',
    padding: 24,
  },
  sheetHeader: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    marginBottom: 24,
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
  nativeComponentContainer: {
    flex: 1,
  },
  nativeCard: {
    flex: 1,
    width: '100%',
    minHeight: 450,
  },
  loadingCenter: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
  },
  loadingText: {
    marginTop: 16,
    color: '#727272',
    fontSize: 14,
  },
});

export default App;