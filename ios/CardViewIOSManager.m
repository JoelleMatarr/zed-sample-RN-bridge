#import <React/RCTViewManager.h>

@interface RCT_EXTERN_MODULE(CardViewIOSManager, RCTViewManager)

// These bridge the JavaScript props to the Swift class variables
RCT_EXPORT_VIEW_PROPERTY(paymentSessionID, NSString)
RCT_EXPORT_VIEW_PROPERTY(paymentSessionSecret, NSString)
RCT_EXPORT_VIEW_PROPERTY(publicKey, NSString)
RCT_EXPORT_VIEW_PROPERTY(environment, NSString)
RCT_EXPORT_VIEW_PROPERTY(hasHandleSubmitListener, BOOL)
RCT_EXPORT_VIEW_PROPERTY(paymentMethod, NSString)
RCT_EXPORT_VIEW_PROPERTY(showPayButton, BOOL)

RCT_EXPORT_VIEW_PROPERTY(onHeightChange, RCTBubblingEventBlock)

@end
