#import "include/ObjCExceptions.h"

NSErrorDomain const AppleToolsObjCExceptionDomain = @"AppleToolsObjCExceptionDomain";
NSErrorUserInfoKey const AppleToolsObjCExceptionNameKey = @"AppleToolsObjCExceptionName";

BOOL AppleToolsRunCatchingExceptions(void (NS_NOESCAPE ^block)(void),
                                     NSError *_Nullable *_Nullable error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error == NULL) { return NO; }

        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        info[NSLocalizedDescriptionKey] =
            exception.reason ?: @"an Objective-C exception was raised";
        info[AppleToolsObjCExceptionNameKey] = exception.name ?: @"(unnamed)";

        // Core Data's faulting exceptions carry the real NSError here, and its
        // code is the only way to tell the note-entitlement wall (134092) from
        // any other failure. Losing it would reduce a diagnosable refusal to
        // "something threw".
        id underlying = exception.userInfo[NSUnderlyingErrorKey];
        if ([underlying isKindOfClass:[NSError class]]) {
            info[NSUnderlyingErrorKey] = underlying;
        }

        *error = [NSError errorWithDomain:AppleToolsObjCExceptionDomain
                                     code:0
                                 userInfo:info];
        return NO;
    }
}
