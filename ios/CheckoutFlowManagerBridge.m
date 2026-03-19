#import <Foundation/Foundation.h>
#import <React/RCTBridgeModule.h>

@interface RCT_EXTERN_MODULE(CheckoutFlowManager, NSObject)

// Declare methods exposed to JavaScript with promise support
RCT_EXTERN_METHOD(initialize:(NSDictionary *)paymentSession
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(renderFlow:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

@end
