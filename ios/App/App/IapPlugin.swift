import Foundation
import Capacitor
import StoreKit

/// Native StoreKit 2 in-app purchase for the 147 Pro Capacitor shell.
///
/// Replaces the old Appilix IAP bridge. The web app calls `purchase({ productId,
/// appAccountToken })`; we run the StoreKit 2 purchase and return the signed
/// transaction (`jwsRepresentation`) — the SAME JWS the backend already verifies
/// in `/_api/iap/apple/verify` (helpers/appleIap.ts). So no server change is
/// needed: the existing local JWS verification (x5c chain + Apple Root G3 pin +
/// ES256) validates it exactly as it did for Appilix.
@available(iOS 15.0, *)
@objc(IapPlugin)
public class IapPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "IapPlugin"
    public let jsName = "Iap"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "purchase", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "restore", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getProducts", returnType: CAPPluginReturnPromise)
    ]

    @objc func getProducts(_ call: CAPPluginCall) {
        let ids = call.getArray("productIds", String.self) ?? []
        Task {
            do {
                let products = try await Product.products(for: ids)
                let out = products.map { p in
                    return [
                        "id": p.id,
                        "displayName": p.displayName,
                        "price": p.displayPrice
                    ]
                }
                call.resolve(["products": out])
            } catch {
                call.reject("Failed to load products: \(error.localizedDescription)")
            }
        }
    }

    @objc func purchase(_ call: CAPPluginCall) {
        guard let productId = call.getString("productId") else {
            call.reject("productId is required")
            return
        }
        let appAccountToken = call.getString("appAccountToken")

        Task {
            do {
                let products = try await Product.products(for: [productId])
                guard let product = products.first else {
                    call.reject("Product not found: \(productId)")
                    return
                }

                var options: Set<Product.PurchaseOption> = []
                if let tokenStr = appAccountToken, let uuid = UUID(uuidString: tokenStr) {
                    options.insert(.appAccountToken(uuid))
                }

                let result = try await product.purchase(options: options)
                switch result {
                case .success(let verification):
                    switch verification {
                    case .verified(let transaction):
                        // The signed representation is what the backend verifies.
                        let jws = verification.jwsRepresentation
                        await transaction.finish()
                        call.resolve([
                            "status": true,
                            "transactionId": String(transaction.id),
                            "jws": jws
                        ])
                    case .unverified(_, let error):
                        call.resolve([
                            "status": false,
                            "message": "Purchase could not be verified: \(error.localizedDescription)"
                        ])
                    }
                case .userCancelled:
                    call.resolve(["status": false, "message": "cancelled"])
                case .pending:
                    call.resolve(["status": false, "message": "Purchase is pending approval."])
                @unknown default:
                    call.resolve(["status": false, "message": "Unknown purchase result."])
                }
            } catch {
                call.reject("Purchase failed: \(error.localizedDescription)")
            }
        }
    }

    @objc func restore(_ call: CAPPluginCall) {
        Task {
            do {
                try await AppStore.sync()
                var restored: [[String: Any]] = []
                for await result in Transaction.currentEntitlements {
                    if case .verified(let transaction) = result {
                        restored.append([
                            "transactionId": String(transaction.id),
                            "productId": transaction.productID,
                            "jws": result.jwsRepresentation
                        ])
                    }
                }
                call.resolve(["transactions": restored])
            } catch {
                call.reject("Restore failed: \(error.localizedDescription)")
            }
        }
    }
}
