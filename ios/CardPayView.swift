import Foundation
import UIKit
import SwiftUI
import React
import CheckoutComponentsSDK

@objc(CardPayView)
class CardPayView: UIView, HandleSubmitResponseTarget {
    // Event block mapping across the React Native bridge module
    @objc var onHeightChange: RCTBubblingEventBlock?
    @objc var hasHandleSubmitListener: Bool = false

    // When false the SDK hides its own pay button so we can drive submit()
    // from our own React Native "Pay" button.
    @objc var showPayButton: Bool = false

    @objc var paymentSessionID: NSString? { didSet { ApplePayViewRegistry.update(self); maybeInitialize() } }
    @objc var paymentSessionSecret: NSString? { didSet { maybeInitialize() } }
    @objc var publicKey: NSString? { didSet { maybeInitialize() } }
    @objc var paymentMethod: NSString?

    private var hasInitialized = false
    private var hostingController: UIHostingController<AnyView>?
    private var lastReportedHeight: CGFloat = 0
    private var boundsObservation: NSKeyValueObservation?

    // Kept so the JS "Pay" button can trigger submission programmatically.
    private var submittableComponent: (any CheckoutComponents.Submittable)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        ApplePayViewRegistry.register(self)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        ApplePayViewRegistry.register(self)
    }

    deinit {
        boundsObservation?.invalidate()
        ApplePayViewRegistry.unregister(self)
    }

    private func maybeInitialize() {
        guard !hasInitialized,
              let id = paymentSessionID as? String, !id.isEmpty,
              let secret = paymentSessionSecret as? String, !secret.isEmpty,
              let key = publicKey as? String, !key.isEmpty else { return }

        Task { @MainActor in
            await initialize(id: id, secret: secret, key: key)
        }
    }

    @MainActor
    private func initialize(id: String, secret: String, key: String) async {
        guard !hasInitialized else { return }

        do {
            let session = PaymentSession(id: id, paymentSessionSecret: secret)

            let colorTokens = CheckoutComponents.ColorTokens(
                action: Color(hex: "#FF6B6B"),
                background: .white,
                formBackground: Color(hex: "#F5F5F7"),
                primary: Color(hex: "#00083D")
            )
            let designTokens = CheckoutComponents.DesignTokens(
                colorTokensMain: colorTokens,
                borderButtonRadius: .init(radius: 25),
                borderFormRadius: .init(radius: 8)
            )

            let callbacks = CheckoutComponents.Callbacks(
                // Keep the latest submittable component so our external Pay button
                // always submits the current form state.
                onChange: { [weak self] component in
                    self?.submittableComponent = component
                },
                onSuccess: { [weak self] _, payId in
                    self?.submittableComponent = nil
                    ApplePayModule.shared?.sendEvent(withName: "onFlowPaymentSuccess", body: ["paymentId": payId])
                },
                onError: { error in
                    ApplePayModule.shared?.sendEvent(withName: "onFlowPaymentError", body: ["errorMessage": error.localizedDescription])
                }
            )

            let config = try await CheckoutComponents.Configuration(
                paymentSession: session,
                publicKey: key,
                environment: .sandbox,
                appearance: designTokens,
                callbacks: callbacks
            )

            let cardConfigs = CheckoutComponents.CardConfigurations(
                displayCardHolderName: .bottom
            )

            let component = try CheckoutComponents(configuration: config).create(
                .card(showPayButton: showPayButton, paymentButtonAction: .tokenization, cardConfiguration: cardConfigs)
            )
            // Card component is submittable; hold onto it for the external Pay button.
            self.submittableComponent = component

            // We use a clean, root SwiftUI wrapper container with zero forced constraints
            let swiftUIView = AnyView(
                VStack(alignment: .leading, spacing: 0) {
                    component.render()
                }
            )

            let hostingController = UIHostingController(rootView: swiftUIView)
            hostingController.view.backgroundColor = .clear
            // Driven by Auto Layout, not the autoresizing mask, so the view can size
            // itself to the SwiftUI content instead of to a frame we impose.
            hostingController.view.translatesAutoresizingMaskIntoConstraints = false

            // Ask the hosting controller to keep its intrinsic content size in sync with
            // the SwiftUI layout. Every time the form grows/shrinks internally this
            // invalidates the intrinsic size, which resizes the view (see the KVO below).
            if #available(iOS 16.0, *) {
                hostingController.sizingOptions = .intrinsicContentSize
            }

            self.hostingController = hostingController

            if let parentVC = self.reactViewController() {
                parentVC.addChild(hostingController)
                self.addSubview(hostingController.view)
                hostingController.didMove(toParent: parentVC)

                // Pin top/leading/trailing only. Leaving the bottom free lets the
                // hosting view's height follow its intrinsic (content) height, so the
                // width is driven by React Native while the height tracks the form.
                NSLayoutConstraint.activate([
                    hostingController.view.topAnchor.constraint(equalTo: self.topAnchor),
                    hostingController.view.leadingAnchor.constraint(equalTo: self.leadingAnchor),
                    hostingController.view.trailingAnchor.constraint(equalTo: self.trailingAnchor),
                ])

                // Observe the content view's bounds so we catch *any* height change the
                // SwiftUI form makes on its own — even when React Native keeps our frame
                // fixed. This is what makes the bottom sheet track "random" resizes.
                boundsObservation = hostingController.view.observe(\.bounds, options: [.new]) { [weak self] view, _ in
                    self?.reportHeight(view.bounds.height)
                }

                hasInitialized = true
                self.setNeedsLayout()
            }
        } catch {
            print("DEBUG: SDK Error: \(error)")
        }
    }

    // Backup trigger: also re-check on our own layout passes (covers the very first
    // measurement and any width changes that reflow the form).
    override func layoutSubviews() {
        super.layoutSubviews()
        if let hostingView = hostingController?.view {
            reportHeight(hostingView.bounds.height)
        }
    }

    // Forward the pixel-accurate content height over the bridge, de-duplicating
    // sub-pixel noise so we don't spam React Native with redundant events.
    private func reportHeight(_ height: CGFloat) {
        guard height > 0, abs(height - lastReportedHeight) > 0.5 else { return }
        lastReportedHeight = height

        DispatchQueue.main.async { [weak self] in
            self?.onHeightChange?(["height": height])
        }
    }

    // MARK: - HandleSubmitResponseTarget

    // Called by ApplePayModule.submit(sessionID:) — routed here through
    // ApplePayViewRegistry when JS taps our custom "Pay" button.
    @MainActor
    func submitFromJS() -> Bool {
        guard let component = submittableComponent else {
            NSLog("CardPayView submitFromJS: no submittable component available yet")
            return false
        }
        // Submitting an invalid form makes the SDK surface inline field errors
        // (and grow — which the bottom sheet now follows), so we submit directly.
        NSLog("CardPayView submitFromJS: calling component.submit()")
        component.submit()
        return true
    }

    // Card flow reports success/error via callbacks above rather than the
    // handleSubmit bridge, so this is a required-protocol no-op.
    func handleSubmitResponse(requestId: String, success: Bool, data: NSDictionary?) {}
}
