// Exercises the production legacy-UI guard with fake Security calls. Never
// opens a keychain, changes system permissions, or accesses a real credential.
#include <Security/Security.h>
#include <assert.h>
#include <stdio.h>

static Boolean fixtureAllowed;
static OSStatus getStatus, disableStatus, copyStatus, restoreStatus;
static int copyCalls, setCalls;
static OSStatus fixtureGet(Boolean *allowed) { *allowed = fixtureAllowed; return getStatus; }
static OSStatus fixtureSet(Boolean allowed) {
    setCalls++;
    OSStatus status = setCalls == 1 ? disableStatus : restoreStatus;
    if (status == errSecSuccess) fixtureAllowed = allowed;
    return status;
}
static OSStatus fixtureCopy(CFDictionaryRef query, CFTypeRef *result) {
    assert(!fixtureAllowed);
    assert(query != NULL);
    copyCalls++;
    if (copyStatus == errSecSuccess && result) *result = CFRetain(CFSTR("synthetic-value"));
    return copyStatus;
}
#define SecKeychainGetUserInteractionAllowed fixtureGet
#define SecKeychainSetUserInteractionAllowed fixtureSet
#define SecItemCopyMatching fixtureCopy
#include "../../TranslateX/System/Security/KeychainInteraction.c"

static void reset(Boolean allowed) {
    fixtureAllowed = allowed;
    getStatus = disableStatus = copyStatus = restoreStatus = errSecSuccess;
    copyCalls = setCalls = 0;
}
int main(void) {
    CFDictionaryRef query = CFDictionaryCreate(NULL, NULL, NULL, 0, NULL, NULL);
    for (int prior = 0; prior < 2; prior++) {
        for (int failed = 0; failed < 2; failed++) {
            reset(prior);
            copyStatus = failed ? errSecInteractionNotAllowed : errSecSuccess;
            CFTypeRef result = NULL;
            assert(TSXCopyKeychainItemWithoutInteraction(query, &result) == copyStatus);
            assert(fixtureAllowed == prior && copyCalls == 1 && setCalls == 2);
            if (result) CFRelease(result);
        }
    }
    reset(true); getStatus = errSecNotAvailable;
    assert(TSXCopyKeychainItemWithoutInteraction(query, NULL) == getStatus);
    assert(copyCalls == 0 && setCalls == 0);
    reset(true); disableStatus = errSecNotAvailable;
    assert(TSXCopyKeychainItemWithoutInteraction(query, NULL) == disableStatus);
    assert(copyCalls == 0 && fixtureAllowed);
    reset(true); restoreStatus = errSecNotAvailable;
    CFTypeRef result = NULL;
    assert(TSXCopyKeychainItemWithoutInteraction(query, &result) == restoreStatus);
    assert(result == NULL);
    CFRelease(query);
    puts("Keychain interaction guard checks passed (synthetic calls only).");
    return 0;
}
