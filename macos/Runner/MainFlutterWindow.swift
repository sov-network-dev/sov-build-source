import Cocoa
import FlutterMacOS
import Security
import LocalAuthentication

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // SOV Hardware Lock (Tier A) — Secure Enclave sealing of the wallet seed.
    SecureEnclaveHandler.register(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}

// ── SOV Secure Enclave (Tier A) ───────────────────────────────────────────────
// Seals the Ed25519 wallet seed with a P-256 key GENERATED INSIDE the Secure
// Enclave (non-extractable). Sealing uses the enclave PUBLIC key (ECIES), so a
// copied blob is useless on any other Mac. Unsealing uses the enclave PRIVATE key
// which never leaves the chip; with `hello: true` the key carries a biometry
// access-control flag so macOS demands Touch ID on every unseal (A2).
//
// Dart channel: `network.sov.node/secure_enclave`
//   probe()                -> "OK Secure Enclave" | "NO"
//   seal(seedHex, hello)   -> base64 ECIES blob
//   unseal(blob, hello)    -> seedHex   (Touch ID prompt if hello)
//
// VERIFY ON REAL HARDWARE: Secure Enclave needs a code signature — ad-hoc ("-")
// usually works for local runs. A sandboxed app uses its default keychain-access
// group; if key creation returns errSecMissingEntitlement, add a
// keychain-access-groups entitlement. Touch ID needs a Mac with an enrolled
// finger + a logged-in session (never works in headless CI).
enum SEError: Error, CustomStringConvertible {
  case msg(String)
  var description: String { switch self { case .msg(let m): return m } }
}

final class SecureEnclaveHandler {
  static let channelName = "network.sov.node/secure_enclave"
  static let tagPlain = "network.sov.wallet.se.v1".data(using: .utf8)!
  static let tagBio   = "network.sov.wallet.se.bio.v1".data(using: .utf8)!
  static let algo: SecKeyAlgorithm = .eciesEncryptionCofactorX963SHA256AESGCM

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      // Off the main thread — a Touch ID prompt blocks until the user responds.
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let args = call.arguments as? [String: Any] ?? [:]
          switch call.method {
          case "probe":
            let r = probe()
            DispatchQueue.main.async { result(r) }
          case "seal":
            let hex = args["seedHex"] as? String ?? ""
            let bio = args["hello"] as? Bool ?? false
            let blob = try seal(seedHex: hex, biometry: bio)
            DispatchQueue.main.async { result(blob) }
          case "unseal":
            let blob = args["blob"] as? String ?? ""
            let bio = args["hello"] as? Bool ?? false
            let hex = try unseal(blobB64: blob, biometry: bio)
            DispatchQueue.main.async { result(hex) }
          default:
            DispatchQueue.main.async { result(FlutterMethodNotImplemented) }
          }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "SE_ERROR", message: "\(error)", details: nil))
          }
        }
      }
    }
  }

  /// Ephemeral create+discard to confirm a usable Secure Enclave.
  static func probe() -> String {
    guard let ac = SecAccessControlCreateWithFlags(
      nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage], nil) else { return "NO" }
    let attrs: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
      kSecAttrKeySizeInBits as String: 256,
      kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
      kSecPrivateKeyAttrs as String: [
        kSecAttrIsPermanent as String: false,
        kSecAttrAccessControl as String: ac,
      ],
    ]
    var err: Unmanaged<CFError>?
    guard SecKeyCreateRandomKey(attrs as CFDictionary, &err) != nil else { return "NO" }
    return "OK Secure Enclave"
  }

  /// Load the persistent SE key for [biometry]; create it when [create] is true.
  static func getKey(biometry: Bool, create: Bool) throws -> SecKey {
    let tag = biometry ? tagBio : tagPlain
    let query: [String: Any] = [
      kSecClass as String: kSecClassKey,
      kSecAttrApplicationTag as String: tag,
      kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
      kSecReturnRef as String: true,
    ]
    var item: CFTypeRef?
    let st = SecItemCopyMatching(query as CFDictionary, &item)
    if st == errSecSuccess, let it = item { return (it as! SecKey) }
    if !create { throw SEError.msg("key not found (status \(st))") }

    var flags: SecAccessControlCreateFlags = [.privateKeyUsage]
    if biometry { flags.insert(.biometryCurrentSet) }
    guard let ac = SecAccessControlCreateWithFlags(
      nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, nil) else {
      throw SEError.msg("access control create failed")
    }
    let attrs: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
      kSecAttrKeySizeInBits as String: 256,
      kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
      kSecPrivateKeyAttrs as String: [
        kSecAttrIsPermanent as String: true,
        kSecAttrApplicationTag as String: tag,
        kSecAttrAccessControl as String: ac,
      ],
    ]
    var err: Unmanaged<CFError>?
    guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &err) else {
      throw SEError.msg("create key: \(err!.takeRetainedValue())")
    }
    return key
  }

  static func seal(seedHex: String, biometry: Bool) throws -> String {
    let priv = try getKey(biometry: biometry, create: true)
    guard let pub = SecKeyCopyPublicKey(priv) else { throw SEError.msg("no public key") }
    guard SecKeyIsAlgorithmSupported(pub, .encrypt, algo) else { throw SEError.msg("ECIES unsupported") }
    guard let data = seedHex.data(using: .utf8) else { throw SEError.msg("bad seed") }
    var err: Unmanaged<CFError>?
    guard let ct = SecKeyCreateEncryptedData(pub, algo, data as CFData, &err) as Data? else {
      throw SEError.msg("encrypt: \(err!.takeRetainedValue())")
    }
    return ct.base64EncodedString()
  }

  static func unseal(blobB64: String, biometry: Bool) throws -> String {
    let priv = try getKey(biometry: biometry, create: false)
    guard let ct = Data(base64Encoded: blobB64) else { throw SEError.msg("bad blob") }
    guard SecKeyIsAlgorithmSupported(priv, .decrypt, algo) else { throw SEError.msg("ECIES unsupported") }
    var err: Unmanaged<CFError>?
    guard let pt = SecKeyCreateDecryptedData(priv, algo, ct as CFData, &err) as Data? else {
      throw SEError.msg("decrypt: \(err!.takeRetainedValue())")
    }
    return String(data: pt, encoding: .utf8) ?? ""
  }
}
