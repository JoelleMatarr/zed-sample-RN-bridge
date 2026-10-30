#import "AppDelegate.h"

#import <React/RCTBundleURLProvider.h>
#import "React/RCTBridgeModule.h"
#import "React/RCTBridge.h"  // Add this
#import "DemoFlowApp-Swift.h" // This will bridge your Swift class to React Native

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
  self.moduleName = @"DemoFlowApp";
  // You can add your custom initial props in the dictionary below.
  // They will be passed down to the ViewController used by React Native.
  self.initialProps = @{};

  BOOL result = [super application:application didFinishLaunchingWithOptions:launchOptions];
  [TamaraSwitchRepro runIfRequested]; // temporary diagnostic, no-op without -TamaraRepro
  return result;
}

- (NSURL *)sourceURLForBridge:(RCTBridge *)bridge
{
  return [self bundleURL];
}

- (NSURL *)bundleURL
{
#if DEBUG
  return [[RCTBundleURLProvider sharedSettings] jsBundleURLForBundleRoot:@"index"];
#else
  return [[NSBundle mainBundle] URLForResource:@"main" withExtension:@"jsbundle"];
#endif
}

@end
