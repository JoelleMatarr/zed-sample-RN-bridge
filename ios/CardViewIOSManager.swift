import Foundation
import React

@objc(CardViewIOSManager)
class CardViewIOSManager: RCTViewManager {
  
  override func view() -> UIView! {
    return CardPayView()
  }

  override static func requiresMainQueueSetup() -> Bool {
    return true
  }
}
