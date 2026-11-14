// SHA-256 for the whole library, on every system.
//
// Apple's systems hash with CryptoKit, and Linux with swift-crypto, whose
// BoringSSL has assembly for it there. On Windows that BoringSSL has none, and
// hashes in plain C at about a tenth of the speed, so Windows hashes with the
// system's own CNG. SHA-256 is SHA-256: the shared vectors hold every system to
// the same bytes.

#if os(Windows)
import WinSDK
#elseif canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#else
#error("this system has no SHA-256 the library knows of")
#endif

#if os(Windows)
/// One CNG provider for the process. Its handle may be used by every thread at
/// once, and Swift makes a global `let` once, on first use.
nonisolated(unsafe) private let sha256Provider: BCRYPT_ALG_HANDLE = {
    var handle: BCRYPT_ALG_HANDLE? = nil
    let status = "SHA256".withCString(encodedAs: UTF16.self) { name in
        BCryptOpenAlgorithmProvider(&handle, name, nil, 0)
    }
    guard status == 0, let handle else {
        fatalError("Windows has no SHA-256: BCryptOpenAlgorithmProvider gave \(status)")
    }
    return handle
}()
#endif

/// The SHA-256 of `bytes`.
func sha256(_ bytes: UnsafeRawBufferPointer) -> Hash {
    #if os(Windows)
    var digest: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    var spare: UInt8 = 0
    let status: NTSTATUS = withUnsafeMutablePointer(to: &spare) { spare in
        // CNG is given a place to read from even when there is nothing to read.
        let input = bytes.isEmpty
            ? spare
            : UnsafeMutablePointer(mutating: bytes.baseAddress!.assumingMemoryBound(to: UInt8.self))
        return withUnsafeMutableBytes(of: &digest) { out -> NTSTATUS in
            let output = out.baseAddress!.assumingMemoryBound(to: UInt8.self)
            if bytes.count <= Int(UInt32.max) {
                return BCryptHash(sha256Provider, nil, 0, input, ULONG(bytes.count), output, 32)
            }
            // Longer than one call takes: in parts.
            var hash: BCRYPT_HASH_HANDLE? = nil
            var status = BCryptCreateHash(sha256Provider, &hash, nil, 0, nil, 0, 0)
            var at = 0
            while status == 0 && at < bytes.count {
                let part = min(bytes.count - at, 1 << 30)
                status = BCryptHashData(hash, input + at, ULONG(part), 0)
                at += part
            }
            if status == 0 {
                status = BCryptFinishHash(hash, output, 32, 0)
            }
            if hash != nil {
                _ = BCryptDestroyHash(hash)
            }
            return status
        }
    }
    guard status == 0 else {
        fatalError("Windows could not hash with SHA-256: CNG gave \(status)")
    }
    return withUnsafeBytes(of: &digest) { Hash(rawBytes: $0) }
    #else
    // CryptoKit and swift-crypto both take a buffer through `update`.
    var hasher = SHA256()
    hasher.update(bufferPointer: bytes)
    return hasher.finalize().withUnsafeBytes { Hash(rawBytes: $0) }
    #endif
}

/// The SHA-256 of `bytes`.
@inline(__always)
func sha256(_ bytes: [UInt8]) -> Hash {
    bytes.withUnsafeBytes { sha256($0) }
}

/// The SHA-256 of `bytes`.
@inline(__always)
func sha256(_ bytes: ArraySlice<UInt8>) -> Hash {
    bytes.withUnsafeBytes { sha256($0) }
}
