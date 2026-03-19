import Foundation
import React

@objc(ApplePayViewManager)
class ApplePayViewManager: RCTViewManager {
  override static func requiresMainQueueSetup() -> Bool { true }

  override func view() -> UIView! {
    return ApplePayView()
  }
}

// @objc(CardViewIOSManager)
// class CardViewIOSManager: RCTViewManager {
  
//   override func view() -> UIView! {
//     return CardPayView()
//   }

//   override static func requiresMainQueueSetup() -> Bool {
//     return true
//   }

//   // CRITICAL: These must match the props you pass in React Native
//   @objc override var methodQueue: DispatchQueue {
//     return .main
//   }

//   RCT_EXPORT_VIEW_PROPERTY(paymentSessionID, NSString)
//   RCT_EXPORT_VIEW_PROPERTY(paymentSessionSecret, NSString)
//   RCT_EXPORT_VIEW_PROPERTY(publicKey, NSString)
//   RCT_EXPORT_VIEW_PROPERTY(environment, NSString)
//   RCT_EXPORT_VIEW_PROPERTY(hasHandleSubmitListener, Bool)
// }
