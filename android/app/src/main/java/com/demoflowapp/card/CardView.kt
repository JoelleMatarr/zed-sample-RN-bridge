package com.demoflowapp.card

import android.content.Context
import android.util.Log
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
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
import com.checkout.components.interfaces.localisation.Locale
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
import com.facebook.react.uimanager.events.RCTEventEmitter
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

class CardView(context: Context, private val reactApplicationContext: ReactApplicationContext) : FrameLayout(context) {
    private var checkoutComponents: CheckoutComponents? = null
    private var hasInitialized = false
    var environment: Environment = Environment.SANDBOX
    var hasHandleSubmitListener: Boolean = false

    // The SDK card component's view, once mounted. Its content height changes as
    // the form grows/shrinks (e.g. inline validation errors) and we report those
    // changes to JS via onHeightChange so the bottom sheet can hug the card.
    private var contentView: View? = null
    // Last height reported to JS, in dp, so we can de-duplicate noisy layout passes.
    private var lastReportedHeightDp = 0.0

    // RN doesn't re-lay-out native children on its own after the SDK's async Compose
    // content changes, so we drive the measure/layout pass ourselves. We also measure
    // the child directly for reporting: when the form changed height internally (e.g.
    // the built-in "Remember me" toggle), Compose has flagged the child for layout, so
    // this returns the fresh content height even when our own measure is cached. That
    // is what lets the sheet track EVERY toggle (unlimited) rather than stopping after
    // a couple — without forcing a full re-layout that would ghost the SDK's text.
    private val mLayoutRunnable = Runnable {
        if (!isAttachedToWindow) return@Runnable
        measure(MeasureSpec.makeMeasureSpec(width, MeasureSpec.EXACTLY),
            MeasureSpec.makeMeasureSpec(height, MeasureSpec.EXACTLY))
        layout(left, top, right, bottom)

        val child = contentView
        if (child != null && width > 0) {
            val cw = MeasureSpec.makeMeasureSpec(width, MeasureSpec.EXACTLY)
            child.measure(cw, MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED))
            reportContentHeightPx(child.measuredHeight)
        }
    }

    override fun requestLayout() {
        super.requestLayout()
        removeCallbacks(mLayoutRunnable)
        post(mLayoutRunnable)
    }

    // Measure and lay out the SDK view at its TRUE content height so the bottom sheet
    // hugs it and grows/shrinks with its content. The Checkout SDK renders the card
    // into a ComposeView whose root uses fillMaxHeight, so under the bounded frame RN
    // imposes it just fills that frame. Measuring it UNSPECIFIED defeats fillMaxHeight
    // (it can't expand into infinite space) so it collapses to its true content
    // height, which we forward to JS. onLayout places it at that height so measure and
    // layout agree.
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val child = contentView
        if (child == null) {
            super.onMeasure(widthMeasureSpec, heightMeasureSpec)
            return
        }
        val w = MeasureSpec.getSize(widthMeasureSpec)
        if (w <= 0) {
            super.onMeasure(widthMeasureSpec, heightMeasureSpec)
            return
        }
        val childWidthSpec = MeasureSpec.makeMeasureSpec(w, MeasureSpec.EXACTLY)
        val childHeightSpec = MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED)
        child.measure(childWidthSpec, childHeightSpec)
        val contentPx = child.measuredHeight
        val h = if (MeasureSpec.getMode(heightMeasureSpec) == MeasureSpec.EXACTLY) {
            MeasureSpec.getSize(heightMeasureSpec)
        } else {
            contentPx
        }
        setMeasuredDimension(w, h)
        reportContentHeightPx(contentPx)
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val child = contentView ?: return
        child.layout(0, 0, r - l, child.measuredHeight)
    }

    private fun reportContentHeightPx(contentPx: Int) {
        // Needs a valid react tag to route the per-view event.
        if (contentPx <= 0 || id <= 0) return

        // React Native lays out in density-independent pixels, so convert from px.
        val density = resources.displayMetrics.density
        val heightDp = contentPx / density.toDouble()

        // Ignore sub-dp noise so we don't spam the bridge or jitter the sheet.
        if (Math.abs(heightDp - lastReportedHeightDp) < 1.0) return
        lastReportedHeightDp = heightDp

        val params = Arguments.createMap().apply { putDouble("height", heightDp) }
        reactApplicationContext
            .getJSModule(RCTEventEmitter::class.java)
            .receiveEvent(id, "onHeightChange", params)
    }

    private fun sendEvent(eventName: String, params: WritableMap?) {
        val eventData = params ?: Arguments.createMap()
        reactApplicationContext
            .getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
            .emit(eventName, eventData)
    }

//    private fun forceLtrOnInputs(view: View) {
//        if (view is EditText) {
//            // This forces the text engine to read LTR, fixing the "29 / 05" Bidi bug
//            view.textDirection = View.TEXT_DIRECTION_LTR
//        } else if (view is ViewGroup) {
//            // Recursively search through all nested layouts
//            for (i in 0 until view.childCount) {
//                forceLtrOnInputs(view.getChildAt(i))
//            }
//        }
//    }

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
            locale = Locale.En,
            appearance = designTokens,
            environment = environment
        )

        val componentOptions = ComponentOption(
            cardConfiguration = CardConfiguration(
                displayCardholderName = CardholderNamePosition.TOP,
            ),
        )

        CoroutineScope(Dispatchers.Main).launch {
            try {

                // Use the factory as per your import
                checkoutComponents = CheckoutComponentsFactory(config = configuration).create()
                val cardComponent = checkoutComponents!!.create(PaymentMethodName.Card, componentOptions)
                val view = cardComponent.provideView(this@CardView)

                this@CardView.layoutDirection = View.LAYOUT_DIRECTION_LTR
                view.layoutDirection = View.LAYOUT_DIRECTION_LTR

//                forceLtrOnInputs(view)

                view.setViewTreeLifecycleOwner(activity)
                view.setViewTreeViewModelStoreOwner(activity)
                view.setViewTreeSavedStateRegistryOwner(activity)

                removeAllViews()
                // WRAP_CONTENT so the SDK view takes its natural content height,
                // which we then report to JS (see onMeasure / reportContentHeightPx).
                addView(
                    view,
                    FrameLayout.LayoutParams(
                        FrameLayout.LayoutParams.MATCH_PARENT,
                        FrameLayout.LayoutParams.WRAP_CONTENT
                    )
                )
                contentView = view

                view.requestLayout()
                // Trigger a measure pass so onMeasure reports the initial content
                // height; subsequent form growth/shrink re-triggers onMeasure too.
                requestLayout()
            } catch (e: Exception) {
                Log.e("CardView", "Error: ${e.message}")
            }
        }
    }
}