#import <Security/Security.h>

/// Exact-item lookup with authentication UI disabled for both macOS keychains.
OSStatus TSXCopyKeychainItemWithoutInteraction(CFDictionaryRef _Nonnull query, CFTypeRef _Nullable * _Nullable CF_RETURNS_RETAINED result);
