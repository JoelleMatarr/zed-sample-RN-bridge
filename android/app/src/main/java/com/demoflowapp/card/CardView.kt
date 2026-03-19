package com.demoflowapp.card

import android.content.Context
import android.util.Log
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import androidx.compose.ui.text.font.Font
import com.checkout.components.interfaces.uicustomisation.font.FontStyle
import androidx.lifecycle.setViewTreeLifecycleOwner
import androidx.lifecycle.setViewTreeViewModelStoreOwner
import androidx.savedstate.setViewTreeSavedStateRegistryOwner
import com.checkout.components.core.CheckoutComponentsFactory
import com.checkout.components.interfaces.Environment
import com.checkout.components.interfaces.api.CheckoutComponents
import com.checkout.components.interfaces.component.CardConfiguration
import com.checkout.components.interfaces.component.CheckoutComponentConfiguration
import com.checkout.components.interfaces.component.ComponentCallback
import com.checkout.components.interfaces.component.ComponentOption
import com.checkout.components.interfaces.component.ComponentOptions
import com.checkout.components.interfaces.model.CardholderNamePosition
import com.checkout.components.interfaces.model.PaymentMethodName
import com.checkout.components.interfaces.model.PaymentSessionResponse
import com.checkout.components.interfaces.uicustomisation.font.FontName
import com.checkout.components.interfaces.uicustomisation.BorderRadius
import com.checkout.components.interfaces.uicustomisation.designtoken.ColorTokens
import com.checkout.components.interfaces.uicustomisation.font.*
import com.checkout.components.interfaces.uicustomisation.designtoken.DesignTokens
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.WritableMap
import com.facebook.react.modules.core.DeviceEventManagerModule
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

class CardView(context: Context, private val reactApplicationContext: ReactApplicationContext) : FrameLayout(context) {
    private var checkoutComponents: CheckoutComponents? = null
    private var hasInitialized = false
    var environment: Environment = Environment.SANDBOX
    var hasHandleSubmitListener: Boolean = false

    private val mLayoutRunnable = Runnable {
        if (!isAttachedToWindow) return@Runnable
        measure(MeasureSpec.makeMeasureSpec(width, MeasureSpec.EXACTLY),
            MeasureSpec.makeMeasureSpec(height, MeasureSpec.EXACTLY))
        layout(left, top, right, bottom)
    }

    override fun requestLayout() {
        super.requestLayout()
        post(mLayoutRunnable)
    }

    private fun sendEvent(eventName: String, params: WritableMap?) {
        val eventData = params ?: Arguments.createMap()
        reactApplicationContext
            .getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
            .emit(eventName, eventData)
    }

    fun initialize(paymentSessionID: String, paymentSessionSecret: String, publicKey: String) {
        if (hasInitialized) return

        val activity = reactApplicationContext.currentActivity as? ComponentActivity ?: return
        hasInitialized = true

        val colors = ColorTokens(
            // Action color (Button) - #FF6B6B
            colorAction = 0xFFFF6B6B,

            // Background of the view - .white
            colorBackground = 0xFFFFFFFF,

            // Form field background - #F5F5F7
            colorFormBackground = 0xFFF5F5F7,

            // Primary text/headers - #00083D
            colorPrimary = 0xFF00083D,

            // Supporting colors to maintain the clean look
//            colorInverse = 0xFFFFFFFF,    // Button text (White)
//            colorSecondary = 0xFF727272,  // Label text (Gray)
//            colorFormBorder = 0xFFF0F0F2, // Subtle border for inputs
//            colorError = 0xFFFF0000,
//            colorSuccess = 0xFF2E7D32
        )

// 2. Clean Typography (No italics or monospace)
        val standardFont = Font(
            fontStyle = FontStyle.Normal,
            fontWeight = FontWeight.Normal,
            fontFamily = FontFamily.SansSerif,
            letterSpacing = 0,
            lineHeight = 1
        )

        val designTokens = DesignTokens(
            colorTokens = colors,
            // iOS standard: subtle rounding for inputs (8), fully rounded for button (25)
            borderFormRadius = BorderRadius(all = 8),
            borderButtonRadius = BorderRadius(all = 25),
            fonts = mapOf(
                FontName.Subheading to standardFont.copy(fontWeight = FontWeight.Bold),
                FontName.Input to standardFont,
                FontName.Button to standardFont.copy(fontWeight = FontWeight.Bold),
                FontName.Label to standardFont.copy(fontWeight = FontWeight.Light)
            )
        )

        val customComponentCallback = ComponentCallback(
            onReady = { component ->
                Log.d("CardView", "onReady: ${component.name}")
            },
            // THE FIX FOR 3DS BEHIND BOTTOM SHEET
            onSubmit = {
                Log.d("CardView", "onSubmit triggered")
                // We notify JS to setModalVisible(false)
                sendEvent("onCardSubmitted", null)
            },
            onSuccess = { component, paymentID ->
                val map = Arguments.createMap().apply {
                    putString("paymentId", paymentID)
                }
                sendEvent("onFlowPaymentSuccess", map)
            },
            onError = { component, checkoutError ->
                val map = Arguments.createMap().apply {
                    putString("errorMessage", checkoutError.message)
                    putString("errorCode", checkoutError.code.toString())
                }
                sendEvent("onFlowPaymentError", map)
            }
        )


        val configuration = CheckoutComponentConfiguration(
            context = activity,
            paymentSession = PaymentSessionResponse(id = paymentSessionID, secret = paymentSessionSecret),
            componentCallback = customComponentCallback,
            publicKey = publicKey,
            appearance = designTokens,
            environment = environment
        )

        val componentOptions = ComponentOption(
            cardConfiguration = CardConfiguration(
                displayCardholderName = CardholderNamePosition.BOTTOM,
            ),
        )

        CoroutineScope(Dispatchers.Main).launch {
            try {

                // Use the factory as per your import
                checkoutComponents = CheckoutComponentsFactory(config = configuration).create()
                val cardComponent = checkoutComponents!!.create(PaymentMethodName.Card, componentOptions)
                val view = cardComponent.provideView(this@CardView)

                view.setViewTreeLifecycleOwner(activity)
                view.setViewTreeViewModelStoreOwner(activity)
                view.setViewTreeSavedStateRegistryOwner(activity)

                removeAllViews()
                addView(view)
                view.requestLayout()
            } catch (e: Exception) {
                Log.e("CardView", "Error: ${e.message}")
            }
        }
    }
}