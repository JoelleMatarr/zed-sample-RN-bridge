package com.demoflowapp.card

import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.common.MapBuilder
import com.facebook.react.uimanager.SimpleViewManager
import com.facebook.react.uimanager.ThemedReactContext
import com.facebook.react.uimanager.annotations.ReactProp

class CardViewManager : SimpleViewManager<CardView>() {
    private var propId: String? = null
    private var propSecret: String? = null
    private var propKey: String? = null

    override fun getName(): String = "RNCardView"

    override fun createViewInstance(reactContext: ThemedReactContext): CardView {
        return CardView(reactContext, reactContext.reactApplicationContext)
    }

    override fun getExportedCustomDirectEventTypeConstants(): MutableMap<String, Any>? {
        return mutableMapOf(
            "onCardSubmitted" to mutableMapOf("registrationName" to "onCardSubmitted"),
            "onFlowPaymentSuccess" to mutableMapOf("registrationName" to "onFlowPaymentSuccess"),
            "onFlowPaymentError" to mutableMapOf("registrationName" to "onFlowPaymentError")
        )
    }

    @ReactProp(name = "paymentSessionID")
    fun setPaymentSessionID(view: CardView, value: String?) { propId = value }

    @ReactProp(name = "paymentSessionSecret")
    fun setPaymentSessionSecret(view: CardView, value: String?) { propSecret = value }

    @ReactProp(name = "publicKey")
    fun setPublicKey(view: CardView, value: String?) { propKey = value }

    override fun onAfterUpdateTransaction(view: CardView) {
        super.onAfterUpdateTransaction(view)
        if (!propId.isNullOrEmpty() && !propSecret.isNullOrEmpty() && !propKey.isNullOrEmpty()) {
            view.initialize(propId!!, propSecret!!, propKey!!)
        }
    }
}