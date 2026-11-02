// Signing a game pack's library on the phone (NX Pocket, dm/ios/pocket; the way LiveContainer signs with zsign, without OpenSSL): the pack's Game.framework gets a code
// signature made with the developer certificate NX Pocket holds, the one that signed NX Pocket itself, so iOS loads it (library validation wants the app's team).
// What it writes is what codesign writes for a framework: a SHA-256 CodeDirectory (16 KiB pages, the __TEXT segment as the executable segment), an empty requirement set,
// the resource seal (_CodeSignature/CodeResources), and a CMS signature with Apple's CDHash attributes and the certificate chain. Only a thin arm64 library that already
// has a signature load command (the linker's ad-hoc signature) is signed; the new signature replaces the old one in place. CommonCrypto and Security.framework only.
#pragma once
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Signs the framework at `framework` (its executable is named by CFBundleExecutable in its Info.plist) with `key`; `chain` holds the DER certificates, the signer's
/// first, then its issuers (Apple's WWDR intermediate, Apple Root CA). `team` is the certificate's team (its OU). Returns 0, or -1 with a reason in `err`
int dm_pack_sign(const char *framework, SecKeyRef key, CFArrayRef chain, const char *team, char *err, size_t errlen);

/// The identity in a PKCS #12 file's data with this password (the one of team `want_team` when the file holds several; NULL: the first developer one): its key, its certificate chain (signer first, completed from `extra` DER certificates when the file lacks the
/// issuers), its team (the certificate's OU), its common name and when it expires. Returns 0, or -1 with a reason in `err`. The caller releases key and chain
int dm_pack_identity(CFDataRef p12, CFStringRef password, const char *want_team, CFArrayRef extra, SecKeyRef *key, CFArrayRef *chain, char *team, size_t teamlen,
                     char *name, size_t namelen, CFAbsoluteTime *expires, char *err, size_t errlen);

#ifdef __cplusplus
}
#endif
