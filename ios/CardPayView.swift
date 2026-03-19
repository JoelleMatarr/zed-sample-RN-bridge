import Foundation
import UIKit
import SwiftUI
import React
import CheckoutComponentsSDK

@objc(CardPayView)
class CardPayView: UIView {
    @objc var hasHandleSubmitListener: Bool = false
    
    @objc var paymentSessionID: NSString? { didSet { maybeInitialize() } }
    @objc var paymentSessionSecret: NSString? { didSet { maybeInitialize() } }
    @objc var publicKey: NSString? { didSet { maybeInitialize() } }
    @objc var paymentMethod: NSString?

    private var hasInitialized = false

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
                onSuccess: { [weak self] _, payId in
                    ApplePayModule.shared?.sendEvent(withName: "onFlowPaymentSuccess", body: ["paymentId": payId])
                },
                onError: { error in
                    ApplePayModule.shared?.sendEvent(withName: "onFlowPaymentError", body: ["errorMessage": error.localizedDescription])
                }
            )
          
          print("id: \(id)" + "secret: \(secret)" + "key: \(key)")

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
          

          let component = try CheckoutComponents(configuration: config).create(.card(showPayButton: true, cardConfiguration: cardConfigs))
            
            // Render and Attach
            let swiftUIView = component.render()
            let hostingController = UIHostingController(rootView: swiftUIView)
            hostingController.view.backgroundColor = .clear
            
            // Ensure we attach to the React View Controller
            if let parentVC = self.reactViewController() {
                parentVC.addChild(hostingController)
                self.addSubview(hostingController.view)
                hostingController.view.frame = self.bounds
                hostingController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                hostingController.didMove(toParent: parentVC)
                
                hasInitialized = true
                print("DEBUG: Card Component Rendered Successfully")
            }
        } catch {
            print("DEBUG: SDK Error: \(error)")
        }
    }
}
