#import "include/ReminderKitBridge.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

NSErrorDomain const AppleToolsReminderKitErrorDomain = @"AppleToolsReminderKitErrorDomain";

static NSString *const kFrameworkPath =
    @"/System/Library/PrivateFrameworks/ReminderKit.framework/ReminderKit";

#pragma mark - Runtime plumbing

/// `objc_msgSend` must be cast to the exact signature of the method being
/// called; calling it through a mismatched prototype is undefined and breaks on
/// arm64 for anything that is not all-pointer. Each call site below casts
/// explicitly rather than going through one generic helper.
static id msgSend0(id target, SEL sel) {
    return ((id (*)(id, SEL))objc_msgSend)(target, sel);
}

static BOOL loadFramework(void) {
    static BOOL loaded = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        loaded = dlopen(kFrameworkPath.fileSystemRepresentation, RTLD_NOW) != NULL;
    });
    return loaded;
}

static NSError *unavailable(NSString *what) {
    return [NSError errorWithDomain:AppleToolsReminderKitErrorDomain
                               code:AppleToolsReminderKitErrorUnavailable
                           userInfo:@{
                               NSLocalizedDescriptionKey: [NSString
                                   stringWithFormat:@"ReminderKit is not usable on this "
                                                    @"system: %@ could not be resolved. "
                                                    @"Reminders tags need private API and "
                                                    @"macOS appears to have changed it.",
                                                    what]
                           }];
}

/// Every class and selector this file needs, checked in one place so a macOS
/// change is reported as one clear "unavailable" rather than as a crash at
/// whichever call site happened to run first.
static BOOL resolveAll(Class *storeCls, Class *saveReqCls, NSString **missing) {
    if (!loadFramework()) {
        *missing = @"the ReminderKit framework";
        return NO;
    }
    Class store = NSClassFromString(@"REMStore");
    Class saveReq = NSClassFromString(@"REMSaveRequest");
    if (!store) { *missing = @"REMStore"; return NO; }
    if (!saveReq) { *missing = @"REMSaveRequest"; return NO; }

    struct { Class cls; const char *sel; } required[] = {
        {store, "fetchReminderWithDACalendarItemUniqueIdentifier:inList:error:"},
        {saveReq, "initWithStore:"},
        {saveReq, "updateReminder:"},
        {saveReq, "saveSynchronouslyWithError:"},
    };
    for (size_t i = 0; i < sizeof(required) / sizeof(required[0]); i++) {
        if (![required[i].cls instancesRespondToSelector:sel_registerName(required[i].sel)]) {
            *missing = [NSString stringWithFormat:@"-[%s %s]",
                                                  class_getName(required[i].cls), required[i].sel];
            return NO;
        }
    }
    if (storeCls) *storeCls = store;
    if (saveReqCls) *saveReqCls = saveReq;
    return YES;
}

BOOL AppleToolsReminderKitAvailable(void) {
    Class a = Nil, b = Nil;
    NSString *missing = nil;
    return resolveAll(&a, &b, &missing);
}

#pragma mark - Reading

/// The `REMHashtag` objects on a reminder, as display-name strings.
///
/// `hashtags` comes back as an `NSSet`, so the order is not meaningful; it is
/// sorted case-insensitively here to give callers something stable to print and
/// to compare.
static NSArray<NSString *> *tagNamesFromContext(id context) {
    id hashtags = msgSend0(context, sel_registerName("hashtags"));
    if (!hashtags) return @[];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (id tag in hashtags) {
        id name = msgSend0(tag, sel_registerName("name"));
        if ([name isKindOfClass:NSString.class]) [names addObject:name];
    }
    [names sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [a compare:b options:NSCaseInsensitiveSearch];
    }];
    return names;
}

/// Look a reminder up by the identifier EventKit calls
/// `calendarItemExternalIdentifier`. ReminderKit calls the same value the
/// "DA" (DataAccess) unique identifier, and it is what the store holds in
/// `ZREMCDREMINDER.ZDACALENDARITEMUNIQUEIDENTIFIER`.
///
/// ⚠️ `fetchReminderWithExternalIdentifier:` is a *different* identifier space
/// and returns "No such object" for these — that mistake cost an afternoon.
static id fetchReminder(id store, NSString *externalId, NSError **error) {
    SEL sel = sel_registerName("fetchReminderWithDACalendarItemUniqueIdentifier:inList:error:");
    NSError *inner = nil;
    id reminder = ((id (*)(id, SEL, id, id, NSError **))objc_msgSend)(store, sel, externalId, nil,
                                                                     &inner);
    if (!reminder && error) {
        *error = [NSError errorWithDomain:AppleToolsReminderKitErrorDomain
                                     code:AppleToolsReminderKitErrorNotFound
                                 userInfo:@{
                                     NSLocalizedDescriptionKey: [NSString
                                         stringWithFormat:@"no reminder with identifier %@",
                                                          externalId],
                                     NSUnderlyingErrorKey: inner ?: [NSNull null]
                                 }];
    }
    return reminder;
}

NSDictionary<NSString *, NSArray<NSString *> *> *_Nullable
AppleToolsReadReminderTags(NSArray<NSString *> *externalIds, NSError **error) {
    Class storeCls = Nil, saveReqCls = Nil;
    NSString *missing = nil;
    if (!resolveAll(&storeCls, &saveReqCls, &missing)) {
        if (error) *error = unavailable(missing);
        return nil;
    }
    if (externalIds.count == 0) return @{};

    // One store for the whole batch. Constructing a REMStore talks to remindd,
    // so doing it per reminder turned a listing into seconds of XPC.
    id store = [[storeCls alloc] init];
    if (!store) {
        if (error) *error = unavailable(@"an instance of REMStore");
        return nil;
    }

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *identifier in externalIds) {
        // A reminder that has gone away mid-listing is skipped, not fatal.
        id reminder = fetchReminder(store, identifier, NULL);
        if (!reminder) continue;
        id context = msgSend0(reminder, sel_registerName("hashtagContext"));
        if (!context) continue;
        NSArray *names = tagNamesFromContext(context);
        if (names.count > 0) result[identifier] = names;
    }
    return result;
}

#pragma mark - Writing

static BOOL containsCaseInsensitive(NSArray<NSString *> *haystack, NSString *needle) {
    for (NSString *candidate in haystack) {
        if ([candidate caseInsensitiveCompare:needle] == NSOrderedSame) return YES;
    }
    return NO;
}

NSArray<NSString *> *_Nullable
AppleToolsApplyReminderTags(NSString *externalId, NSArray<NSString *> *add,
                            NSArray<NSString *> *remove, BOOL replaceAll, NSError **error) {
    Class storeCls = Nil, saveReqCls = Nil;
    NSString *missing = nil;
    if (!resolveAll(&storeCls, &saveReqCls, &missing)) {
        if (error) *error = unavailable(missing);
        return nil;
    }

    id store = [[storeCls alloc] init];
    id reminder = fetchReminder(store, externalId, error);
    if (!reminder) return nil;

    id saveRequest = ((id (*)(id, SEL, id))objc_msgSend)([saveReqCls alloc],
                                                         sel_registerName("initWithStore:"), store);
    id changeItem = ((id (*)(id, SEL, id))objc_msgSend)(saveRequest,
                                                        sel_registerName("updateReminder:"),
                                                        reminder);
    if (!changeItem) {
        if (error) *error = unavailable(@"a reminder change item");
        return nil;
    }
    id context = msgSend0(changeItem, sel_registerName("hashtagContext"));
    if (!context) {
        if (error) *error = unavailable(@"the hashtag context of a change item");
        return nil;
    }

    // Remove by identity: removeHashtag: wants the REMHashtag object, not a
    // name, so the existing set has to be walked to find the match.
    //
    // ⚠️ `replaceAll` deliberately does *not* use `removeAllHashtags`. Doing so
    // destroys and recreates the tags that are staying, which tombstones a
    // CloudKit record and resets the tag's creation date for a tag that never
    // changed — measured: `--tag PTA` on a reminder already tagged `PTA` left a
    // deleted `PTA` row behind and made a new one. Only tags actually leaving
    // are removed.
    for (id tag in msgSend0(context, sel_registerName("hashtags")) ?: @[]) {
        id name = msgSend0(tag, sel_registerName("name"));
        if (![name isKindOfClass:NSString.class]) continue;
        BOOL leaving = replaceAll ? !containsCaseInsensitive(add, name)
                                  : containsCaseInsensitive(remove, name);
        if (leaving) {
            ((void (*)(id, SEL, id))objc_msgSend)(context, sel_registerName("removeHashtag:"), tag);
        }
    }

    // Re-reading after the removals matters: with replaceAll the set is now
    // empty, so everything in `add` is genuinely new, and without it we must not
    // add a duplicate of a tag that survived.
    NSArray<NSString *> *present = tagNamesFromContext(context);
    for (NSString *tag in add) {
        if (containsCaseInsensitive(present, tag)) continue;
        // type 0 is a plain user hashtag; REMHashtag carries a `type` for
        // Apple's own categorisation and 0 is what typing #foo produces.
        ((void (*)(id, SEL, long long, id))objc_msgSend)(
            context, sel_registerName("addHashtagWithType:name:"), 0LL, tag);
        present = tagNamesFromContext(context);
    }

    NSError *saveError = nil;
    BOOL saved = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(
        saveRequest, sel_registerName("saveSynchronouslyWithError:"), &saveError);
    if (!saved) {
        if (error) {
            *error = [NSError errorWithDomain:AppleToolsReminderKitErrorDomain
                                         code:AppleToolsReminderKitErrorSaveFailed
                                     userInfo:@{
                                         NSLocalizedDescriptionKey:
                                             saveError.localizedDescription
                                                 ?: @"the tag save failed",
                                         NSUnderlyingErrorKey: saveError ?: [NSNull null]
                                     }];
        }
        return nil;
    }

    // Read back from a *fresh* store. Reusing the one above would re-read the
    // same in-memory objects we just mutated and confirm nothing.
    NSError *readError = nil;
    NSDictionary *fresh = AppleToolsReadReminderTags(@[ externalId ], &readError);
    if (!fresh) {
        if (error) *error = readError;
        return nil;
    }
    NSArray<NSString *> *actual = fresh[externalId] ?: @[];

    NSMutableArray<NSString *> *unlanded = [NSMutableArray array];
    for (NSString *tag in add) {
        if (!containsCaseInsensitive(actual, tag)) [unlanded addObject:tag];
    }
    NSMutableArray<NSString *> *lingering = [NSMutableArray array];
    if (replaceAll) {
        for (NSString *tag in actual) {
            if (!containsCaseInsensitive(add, tag)) [lingering addObject:tag];
        }
    } else {
        for (NSString *tag in remove) {
            if (containsCaseInsensitive(actual, tag)) [lingering addObject:tag];
        }
    }

    if (unlanded.count > 0 || lingering.count > 0) {
        NSMutableString *detail = [NSMutableString
            stringWithString:@"the tag save reported success but the store does not agree"];
        if (unlanded.count > 0) {
            [detail appendFormat:@"; not added: %@", [unlanded componentsJoinedByString:@", "]];
        }
        if (lingering.count > 0) {
            [detail appendFormat:@"; not removed: %@", [lingering componentsJoinedByString:@", "]];
        }
        if (error) {
            *error = [NSError errorWithDomain:AppleToolsReminderKitErrorDomain
                                         code:AppleToolsReminderKitErrorNotConfirmed
                                     userInfo:@{NSLocalizedDescriptionKey: detail}];
        }
        return nil;
    }
    return actual;
}
