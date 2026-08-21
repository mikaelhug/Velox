#!/usr/bin/env swift
// Ed25519 signing for Velox release artifacts — pure CryptoKit, no dependencies.
//
//   swift Scripts/release-sign.swift keygen
//       Print a fresh base64 keypair. Store the PRIVATE key as the GitHub Actions
//       secret VELOX_ED25519_PRIVATE_KEY; paste the PUBLIC key into versions.env
//       (VELOX_RELEASE_PUBKEY). One-time; the private key never enters the repo.
//
//   swift Scripts/release-sign.swift sign <file>            [key in $RELEASE_KEY]
//       Write `<file>.sig` (base64 Ed25519 signature over the file bytes).
//       Run by .github/workflows/release.yml for each release .zip.
//       The private key comes from the RELEASE_KEY environment variable, NEVER argv:
//       a process's argv is world-readable via `ps -E` and is captured by crash
//       reporters, so passing a signing key there leaks it to anything running
//       concurrently on the runner.
//
//   swift Scripts/release-sign.swift verify <file> <base64-public-key> [sigfile]
//       Exit 0 iff the signature (default `<file>.sig`) matches — the same check
//       the in-app updater performs (Updater.ed25519Verify).
import CryptoKit
import Foundation

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("release-sign: " + msg + "\n").utf8))
    exit(1)
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "keygen":
    let key = Curve25519.Signing.PrivateKey()
    print("private (secret VELOX_ED25519_PRIVATE_KEY): \(key.rawRepresentation.base64EncodedString())")
    print("public  (versions.env VELOX_RELEASE_PUBKEY): \(key.publicKey.rawRepresentation.base64EncodedString())")

case "sign":
    guard args.count == 3 else { die("usage: sign <file>   (private key in $RELEASE_KEY)") }
    guard let keyText = ProcessInfo.processInfo.environment["RELEASE_KEY"], !keyText.isEmpty else {
        die("RELEASE_KEY is not set (the private key must come from the environment, not argv)")
    }
    guard let raw = Data(base64Encoded: keyText.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        die("invalid private key (want base64 of the 32-byte raw representation)")
    }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: args[2])) else {
        die("cannot read \(args[2])")
    }
    guard let sig = try? key.signature(for: data) else { die("signing failed") }
    let out = args[2] + ".sig"
    do { try (sig.base64EncodedString() + "\n").write(toFile: out, atomically: true, encoding: .utf8) }
    catch { die("cannot write \(out): \(error.localizedDescription)") }
    print("signed \(args[2]) → \(out)")

case "verify":
    guard args.count == 4 || args.count == 5 else { die("usage: verify <file> <base64-public-key> [sigfile]") }
    let sigPath = args.count == 5 ? args[4] : args[2] + ".sig"
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: args[2])),
          let sigText = try? String(contentsOfFile: sigPath, encoding: .utf8) else {
        die("cannot read \(args[2]) / \(sigPath)")
    }
    guard let sig = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)),
          let raw = Data(base64Encoded: args[3].trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
        die("invalid public key or signature encoding")
    }
    guard key.isValidSignature(sig, for: data) else { die("SIGNATURE INVALID for \(args[2])") }
    print("signature OK for \(args[2])")

default:
    die("usage: keygen | sign <file> <b64-priv> | verify <file> <b64-pub> [sigfile]")
}
