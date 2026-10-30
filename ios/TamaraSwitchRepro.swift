//
//  TamaraSwitchRepro.swift
//  DemoFlowApp
//
//  Temporary diagnostic: reproduces Card -> Tamara -> Card natively, bypassing React Native.
//  Runs only when the app is launched with `-TamaraRepro`. Keys come from the environment
//  (CKO_PK / CKO_SK), never from source.
//

import Foundation
import SwiftUI
import UIKit
import CheckoutComponentsSDK
import CheckoutPaymentMethods

@objc(TamaraSwitchRepro)
@MainActor
final class TamaraSwitchRepro: NSObject {
  private static var window: UIWindow?

  @objc static func runIfRequested() {
    guard ProcessInfo.processInfo.arguments.contains("-TamaraRepro") else { return }
    let env = ProcessInfo.processInfo.environment
    guard let pk = env["CKO_PK"], let sk = env["CKO_SK"] else {
      log("missing CKO_PK / CKO_SK"); return
    }
    let mode = env["CKO_MODE"] ?? "fresh"   // "fresh" = new session + instance per step, "shared" = one instance
    Task { @MainActor in await run(pk: pk, sk: sk, mode: mode) }
  }

  private static func run(pk: String, sk: String, mode: String) async {
    log("start mode=\(mode)")
    var shared: CheckoutComponents?
    for (i, step) in ["card", "tamara", "card"].enumerated() {
      do {
        let cc: CheckoutComponents
        if mode == "shared", let shared { cc = shared } else {
          let session = try await createSession(sk: sk)
          log("step \(i) \(step): session \(session.id)")
          let config = try await CheckoutComponents.Configuration(
            paymentSession: session, publicKey: pk, environment: .sandbox,
            callbacks: CheckoutComponents.Callbacks(
              onReady: { _ in log("step \(i) \(step): onReady") },
              onError: { e in log("step \(i) \(step): onError \(describe(e))") }))
          cc = CheckoutComponents(configuration: config)
          shared = cc
        }
        let component: CheckoutComponents.Actionable = step == "card"
          ? try cc.create(.card(showPayButton: true))
          : try cc.create(CheckoutPaymentOptions.Provider.tamara, showPayButton: true)
        log("step \(i) \(step): created, isAvailable=\(component.isAvailable)")
        guard component.isAvailable else { continue }
        mount(component.render())
        try await Task.sleep(nanoseconds: 5_000_000_000)
        unmount()
        log("step \(i) \(step): OK")
      } catch let e as CheckoutComponents.Error {
        log("step \(i) \(step): FAILED \(describe(e)) | NSError code=\((e as NSError).code)")
      } catch {
        log("step \(i) \(step): FAILED non-SDK \(error)")
      }
    }
    log("done")
  }

  nonisolated private static func describe(_ e: CheckoutComponents.Error) -> String {
    "type=\(e.type.rawValue) errorCode=\(e.errorCode) component=\(e.details.type.rawValue) " +
    "paymentSessionID=\(e.details.paymentSessionID ?? "-") mobileSessionID=\(e.details.mobileSessionID)"
  }

  private static func mount(_ view: some View) {
    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
    let w = UIWindow(windowScene: scene)
    w.rootViewController = UIHostingController(rootView: AnyView(view))
    w.windowLevel = .alert
    w.makeKeyAndVisible()
    window = w
  }

  private static func unmount() {
    window?.isHidden = true
    window?.rootViewController = nil
    window = nil
  }

  private static func createSession(sk: String) async throws -> PaymentSession {
    var req = URLRequest(url: URL(string: "https://api.sandbox.checkout.com/payment-sessions")!)
    req.httpMethod = "POST"
    req.setValue("Bearer \(sk)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let address: [String: Any] = ["address_line1": "123 Main St", "city": "Riyadh", "zip": "12345", "country": "SA"]
    let phone: [String: Any] = ["country_code": "966", "number": "551234567"]
    let body: [String: Any] = [
      "amount": 25000, "currency": "SAR", "reference": "REPRO-\(Int(Date().timeIntervalSince1970))",
      "processing_channel_id": ProcessInfo.processInfo.environment["CKO_PC"] ?? "pc_ticd6t2rrmnujacakafvukhbwu",
      "billing": ["address": address, "phone": phone], "shipping": ["address": address, "phone": phone],
      "customer": ["email": "repro@example.com", "phone": phone],
      "3ds": ["enabled": true],
      "success_url": "https://example.com/success", "failure_url": "https://example.com/failure",
      "items": [["name": "Test item", "quantity": 1, "unit_price": 25000, "reference": "858818ac"]],
    ]
    req.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, _) = try await URLSession.shared.data(for: req)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    guard let id = json["id"] as? String, let secret = json["payment_session_secret"] as? String else {
      throw NSError(domain: "Repro", code: 0, userInfo: [NSLocalizedDescriptionKey: "session failed: \(json)"])
    }
    return PaymentSession(id: id, paymentSessionSecret: secret)
  }

  nonisolated private static func log(_ s: String) { NSLog("[TamaraRepro] %@", s) }
}
