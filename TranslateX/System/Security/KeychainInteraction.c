#include "KeychainInteraction.h"

// Existing API keys live in the login/file-based keychain. LAContext alone
// controls the data-protection keychain and cannot suppress every legacy ACL
// prompt. Keep the compatibility call synchronous and restore the prior state;
// this changes only this process's optional UI policy, never an item's ACL.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
OSStatus TSXCopyKeychainItemWithoutInteraction(CFDictionaryRef query, CFTypeRef *result) {
    Boolean allowed = true;
    OSStatus status = SecKeychainGetUserInteractionAllowed(&allowed);
    if (status != errSecSuccess) return status;
    status = SecKeychainSetUserInteractionAllowed(false);
    if (status != errSecSuccess) return status;
    status = SecItemCopyMatching(query, result);
    OSStatus restored = SecKeychainSetUserInteractionAllowed(allowed);
    if (restored != errSecSuccess) {
        if (result && *result) { CFRelease(*result); *result = NULL; }
        return restored;
    }
    return status;
}
#pragma clang diagnostic pop
