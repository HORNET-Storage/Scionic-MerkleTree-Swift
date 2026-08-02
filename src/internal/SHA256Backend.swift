// SHA256Backend.swift — one hashing seam for the whole library
//
// Why this exists: on Apple platforms swift-crypto re-exports CryptoKit, and on
// Linux its vendored BoringSSL carries ELF assembly — hardware SHA-256 either
// way. On Windows that same BoringSSL ships only __ELF__/__APPLE__-guarded .S
// files, so every one of them compiles to an empty object and SHA-256 silently
// runs portable C. Measured on the benchmark machine: 449 MB/s through
// swift-crypto against 4,199 MB/s through the OS's own CNG implementation, with
// BCrypt ahead at EVERY input size down to 64-byte merkle pairs (287 vs 515 ns).
//
// So: Windows hashes through CNG/BCrypt, every other platform keeps the exact
// swift-crypto path it always had. Digests are identical by definition —
// SHA-256 is SHA-256 — and enforced by the full suite plus the committed
// spec-vector corpus, where every CID would move if a digest changed.

import Foundation

#if os(Windows)
import WinSDK

/// Cached CNG algorithm provider. CNG algorithm handles are documented
/// thread-safe for concurrent BCryptCreateHash calls, and Swift initializes
/// global `let`s lazily and thread-safely, so one provider serves the process.
private let sha256Algorithm: BCRYPT_ALG_HANDLE? = {
    var algorithm: BCRYPT_ALG_HANDLE? = nil
    let status = "SHA256".withCString(encodedAs: UTF16.self) { algId in
        BCryptOpenAlgorithmProvider(&algorithm, algId, nil, 0)
    }
    precondition(status == 0, "BCryptOpenAlgorithmProvider(SHA256) failed: NTSTATUS \(status)")
    return algorithm
}()
#else
import Crypto
#endif

#if os(Windows)

/// Hashes `data` with SHA-256 and returns the 32-byte digest (CNG/BCrypt).
@inline(__always)
func sha256Digest(_ data: Data) -> Data {
    var hasher = SHA256Hasher()
    hasher.update(data)
    return hasher.finalize()
}

/// Streaming SHA-256 for callers that hash several buffers as one message —
/// the classic-merkle pair hash streams both halves instead of allocating a
/// concatenated copy per pair.
///
/// Single-use by design: create, update, finalize, drop. Do not copy a value
/// between updates (the copy would alias one CNG hash handle), and do not
/// reuse after finalize.
struct SHA256Hasher {
    private var handle: BCRYPT_HASH_HANDLE?

    init() {
        var hash: BCRYPT_HASH_HANDLE? = nil
        let status = BCryptCreateHash(sha256Algorithm, &hash, nil, 0, nil, 0, 0)
        precondition(status == 0, "BCryptCreateHash failed: NTSTATUS \(status)")
        handle = hash
    }

    mutating func update(_ data: Data) {
        guard !data.isEmpty else { return }
        let status = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> NTSTATUS in
            let base = UnsafeMutablePointer(mutating: raw.bindMemory(to: UInt8.self).baseAddress!)
            return BCryptHashData(handle, base, ULONG(raw.count), 0)
        }
        precondition(status == 0, "BCryptHashData failed: NTSTATUS \(status)")
    }

    mutating func finalize() -> Data {
        var digest = [UInt8](repeating: 0, count: 32)
        var status = BCryptFinishHash(handle, &digest, ULONG(digest.count), 0)
        precondition(status == 0, "BCryptFinishHash failed: NTSTATUS \(status)")
        status = BCryptDestroyHash(handle)
        precondition(status == 0, "BCryptDestroyHash failed: NTSTATUS \(status)")
        handle = nil
        return Data(digest)
    }
}

#else

/// Hashes `data` with SHA-256 and returns the 32-byte digest (swift-crypto —
/// CryptoKit on Apple platforms, BoringSSL with ELF assembly on Linux).
@inline(__always)
func sha256Digest(_ data: Data) -> Data {
    return Data(SHA256.hash(data: data))
}

/// Streaming SHA-256; see the Windows declaration above for the contract.
/// Single-use: create, update, finalize, drop.
struct SHA256Hasher {
    private var hasher = SHA256()

    init() {}

    mutating func update(_ data: Data) {
        hasher.update(data: data)
    }

    mutating func finalize() -> Data {
        Data(hasher.finalize())
    }
}

#endif
