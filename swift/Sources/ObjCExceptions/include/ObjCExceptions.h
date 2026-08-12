#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Run `block`, converting any Objective-C exception it raises into an error.
///
/// Swift cannot catch an `NSException`. `try`/`catch` handles Swift errors and
/// bridged `NSError`s; an exception thrown by Objective-C or C++ unwinds
/// straight past Swift frames and terminates the process.
///
/// That is not a theoretical concern for this package. `apple contacts move`
/// calls private AddressBook API, and one of those calls —
/// `-[ABAddressBook importPeople:intoAccount:createNewUIDs:]` — copies the
/// contact's note, which faults the note attribute, which needs the
/// `com.apple.developer.contacts.notes` entitlement no command-line tool can
/// hold. Core Data does not return that failure, it **throws**:
///
///     *** Terminating app due to uncaught exception
///     'NSInternalInconsistencyException', reason: 'Unhandled error
///     (NSCocoaErrorDomain, 134092) occurred during faulting and was thrown'
///
/// A crash there is worse than an error, because the move is a two-step
/// import-then-delete: dying partway through is exactly how a contact ends up
/// existing twice, or not at all. So the private calls run inside this, and a
/// raised exception becomes a refusal that still leaves the store consistent.
///
/// Returns YES on success. On failure returns NO and, if `error` is non-NULL,
/// populates it with the exception's name and reason, plus the underlying
/// `NSError` from `userInfo` when the exception carries one — which is where
/// the Core Data code (134092) actually lives.
BOOL AppleToolsRunCatchingExceptions(void (NS_NOESCAPE ^block)(void),
                                     NSError *_Nullable *_Nullable error);

/// Domain for errors synthesised from a caught `NSException`.
extern NSErrorDomain const AppleToolsObjCExceptionDomain;

/// `userInfo` key holding the exception's name, e.g.
/// `NSInternalInconsistencyException`.
extern NSErrorUserInfoKey const AppleToolsObjCExceptionNameKey;

NS_ASSUME_NONNULL_END
