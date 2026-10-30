import Foundation
import UIKit
import SwiftUI
import React
import CheckoutComponentsSDK
import CheckoutPaymentMethods

// One CheckoutComponents instance per payment session, shared by every CardPayView
// mounted for that session. Switching Card <-> Tamara re-creates only the component
// from this instance (the same setup as the merchant's bridge), not the SDK itself.
private enum SharedCheckoutComponents {
    // A Task so that views mounting for the same session at once share one setup.
    static var instances: [String: Task<CheckoutComponents, Error>] = [:]
    // The view currently showing a component per session. The SDK callbacks belong to
    // the shared instance, so they are routed to whichever view is active.
    private static var activeViews: [String: WeakCardPayView] = [:]

    static func setActive(_ view: CardPayView, for sessionID: String) {
        activeViews[sessionID] = WeakCardPayView(value: view)
    }

    static func activeView(for sessionID: String) -> CardPayView? {
        activeViews[sessionID]?.value
    }

    // A session is used up once a payment succeeds; drop its instance.
    static func remove(_ sessionID: String) {
        instances[sessionID] = nil
        activeViews[sessionID] = nil
    }
}

private struct WeakCardPayView {
    weak var value: CardPayView?
}

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
    // "card" (default) or "tamara". Read once at initialization; JS remounts the
    // view (via `key`) to switch methods, so each method gets a fresh component.
    @objc var paymentMethod: NSString?

    private var hasInitialized = false
    private var hostingController: UIHostingController<AnyView>?
    private var lastReportedHeight: CGFloat = 0
    private var boundsObservation: NSKeyValueObservation?

    // Kept so the JS "Pay" button can trigger submission programmatically.
    fileprivate var submittableComponent: (any CheckoutComponents.Submittable)?

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

    // When React unmounts us (e.g. switching Card <-> Tamara), fully release the SDK
    // component and detach its hosting controller from the parent view controller,
    // so nothing from the previous payment method outlives this view.
    override func willMove(toSuperview newSuperview: UIView?) {
        super.willMove(toSuperview: newSuperview)
        if newSuperview == nil { teardown() }
    }

    private func teardown() {
        boundsObservation?.invalidate()
        boundsObservation = nil
        if let hostingController {
            hostingController.willMove(toParent: nil)
            hostingController.view.removeFromSuperview()
            hostingController.removeFromParent()
        }
        hostingController = nil
        submittableComponent = nil
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
            let checkoutComponents = try await sharedCheckoutComponents(id: id, secret: secret, key: key).value
            SharedCheckoutComponents.setActive(self, for: id)

            let component: CheckoutComponents.Actionable
            if (paymentMethod as String?) == "tamara" {
                component = try checkoutComponents.create(
                    CheckoutPaymentOptions.Provider.tamara,
                    showPayButton: showPayButton
                )
            } else {
                let cardConfigs = CheckoutComponents.CardConfigurations(
                    displayCardHolderName: .bottom
                )
                component = try checkoutComponents.create(
                    .card(showPayButton: showPayButton, paymentButtonAction: .tokenization, cardConfiguration: cardConfigs)
                )
            }
            guard component.isAvailable else {
                print("DEBUG: \(paymentMethod ?? "card") is not available for this payment session")
                return
            }
            // Hold onto the component so the external Pay button can submit it.
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
        } catch let error as CheckoutComponents.Error {
            print("DEBUG: SDK Error type=\(error.type) code=\(error.errorCode) mobileSessionID=\(error.details.mobileSessionID)")
        } catch {
            print("DEBUG: SDK Error: \(error)")
        }
    }

    // Returns the session's shared CheckoutComponents, creating it on first use.
    @MainActor
    private func sharedCheckoutComponents(id: String, secret: String, key: String) -> Task<CheckoutComponents, Error> {
        if let existing = SharedCheckoutComponents.instances[id] { return existing }

        let task = Task<CheckoutComponents, Error> { @MainActor in
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
                onChange: { component in
                    SharedCheckoutComponents.activeView(for: id)?.submittableComponent = component
                },
                onSuccess: { _, payId in
                    SharedCheckoutComponents.activeView(for: id)?.submittableComponent = nil
                    SharedCheckoutComponents.remove(id)
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
            return CheckoutComponents(configuration: config)
        }
        SharedCheckoutComponents.instances[id] = task
        // Don't cache a failed setup; the next mount retries.
        Task { @MainActor in
            if case .failure = await task.result { SharedCheckoutComponents.instances[id] = nil }
        }
        return task
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
