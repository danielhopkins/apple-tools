// appintents-dump — read an app's App Intents action schema, unentitled.
//
// A DEVELOPMENT-ONLY tool. It is not built, installed, or shipped by the
// `apple` CLI; it exists to make writing Notes (and other) shortcut payloads
// less of a guessing game. See README.md for why it lives outside the package
// and where its wall is.
//
// It loads the private LinkMetadata framework and parses the target app's
// Metadata.appintents bundle via -[LNBundleMetadata initWithBundle:...]. That
// path is pure read: no XPC to the app, no TCC prompt, no entitlement. It is
// the same metadata Shortcuts reads, but it exposes each action's REAL intent
// parameter names (e.g. CreateNoteLinkAction -> name/contents/folder/
// interpretAsMarkdown) rather than the WFCreateNoteInput-style aliases the
// serialized .shortcut plist uses. Combine it with reading a working shortcut
// out of ~/Library/Shortcuts/Shortcuts.sqlite to close the loop between the
// conceptual schema and the on-the-wire parameter names.
//
// Executing an action is a different story and deliberately out of scope:
// -[LNActionExecutor perform] connects to the app over XPC and fails with
// LNConnectionErrorDomain code 2700 (MissingConnectionEntitlement) unless the
// caller holds com.apple.private.appintents.connection, a restricted
// entitlement AMFI SIGKILLs any non-Apple-signed binary for carrying. So this
// tool reads; it does not run.
//
// Build:  make            (or: clang -fobjc-arc -framework Foundation \
//                                    -framework AppKit appintents-dump.m -o appintents-dump)
// Usage:  ./appintents-dump [APP] [--action NAME] [--json]
//   APP is a path to a .app, a bundle identifier, or omitted (defaults to
//   Notes.app). --action filters to one action id (substring, case-insensitive).

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// --- minimal decls for the private classes we read ------------------------

@interface LNStaticDeferredLocalizedString : NSObject
- (NSString *)localizedStringForLocaleIdentifier:(NSString *)locale;
@property (readonly) NSString *key;
@property (readonly) NSString *defaultValue;
@end

@interface LNValueType : NSObject
@end
@interface LNPrimitiveValueType : LNValueType
@property (readonly) NSString *typeIdentifierAsString;
@end
@interface LNEntityValueType : LNValueType
@property (readonly) NSString *typeName;
@end
@interface LNArrayValueType : LNValueType
@property (readonly) LNValueType *memberValueType;
@end
@interface LNLinkEnumerationValueType : LNValueType
@property (readonly) NSString *enumerationIdentifier;
@end

@interface LNActionDescriptionMetadata : NSObject
@property (readonly) LNStaticDeferredLocalizedString *descriptionText;
@end

@interface LNActionParameterMetadata : NSObject
@property (readonly) NSString *name;
@property (readonly) id valueType;                 // an LNValueType subclass
@property (readonly, getter=isOptional) BOOL optional;
@property (readonly) BOOL isInput;
@property (readonly) BOOL hasDynamicOptions;
@property (readonly) LNStaticDeferredLocalizedString *title;
@end

@interface LNActionMetadata : NSObject
@property (readonly) NSString *identifier;
@property (readonly) NSString *mangledTypeName;
@property (readonly) NSString *fullyQualifiedTypeName;
@property (readonly) LNStaticDeferredLocalizedString *title;
@property (readonly) BOOL openAppWhenRun;
@property (readonly) id outputType;                // an LNValueType subclass or nil
@property (readonly) NSArray<LNActionParameterMetadata *> *parameters;
@property (readonly) LNActionDescriptionMetadata *descriptionMetadata;
@property (readonly) NSString *iconSystemImageName;
@property (readonly) long long bundleMetadataVersion;
@end

@interface LNBundleMetadata : NSObject
- (instancetype)initWithBundle:(NSBundle *)bundle
    usingEffectiveBundleIdentifier:(NSString *)bid
                             error:(NSError **)error;
@property (readonly) NSDictionary<NSString *, LNActionMetadata *> *actions;
@end

// --- helpers ---------------------------------------------------------------

static NSString *Loc(LNStaticDeferredLocalizedString *s) {
    if (!s) return nil;
    @try {
        NSString *v = [s localizedStringForLocaleIdentifier:@"en_US"];
        if (v.length) return v;
    } @catch (__unused NSException *e) {}
    if (s.defaultValue.length) return s.defaultValue;
    return s.key;
}

// Render an LNValueType subtree as a readable type name.
static NSString *VType(id v) {
    if (!v) return @"—"; // em dash
    if ([v isKindOfClass:objc_getClass("LNPrimitiveValueType")]) {
        NSString *t = [(LNPrimitiveValueType *)v typeIdentifierAsString];
        return t.length ? t : @"Primitive";
    }
    if ([v isKindOfClass:objc_getClass("LNEntityValueType")]) {
        NSString *t = [(LNEntityValueType *)v typeName];
        return [NSString stringWithFormat:@"Entity<%@>", t.length ? t : @"?"];
    }
    if ([v isKindOfClass:objc_getClass("LNArrayValueType")]) {
        return [NSString stringWithFormat:@"[%@]",
                VType([(LNArrayValueType *)v memberValueType])];
    }
    if ([v isKindOfClass:objc_getClass("LNLinkEnumerationValueType")]) {
        NSString *e = [(LNLinkEnumerationValueType *)v enumerationIdentifier];
        return [NSString stringWithFormat:@"Enum<%@>", e.length ? e : @"?"];
    }
    return NSStringFromClass([v class]);
}

// Resolve the APP argument to a bundle URL: a path, or a bundle identifier.
static NSURL *ResolveApp(NSString *arg) {
    if ([arg hasSuffix:@".app"] || [arg containsString:@"/"]) {
        return [NSURL fileURLWithPath:arg.stringByExpandingTildeInPath];
    }
    NSURL *u = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:arg];
    return u; // nil if unknown
}

static void usage(void) {
    fprintf(stderr,
        "usage: appintents-dump [APP] [--action NAME] [--json]\n"
        "  APP        path to a .app, a bundle id, or omitted (default Notes.app)\n"
        "  --action   only actions whose identifier contains NAME (case-insensitive)\n"
        "  --json     machine-readable output\n");
}

// --- main ------------------------------------------------------------------

int main(int argc, const char *argv[]) { @autoreleasepool {
    NSString *appArg = nil, *filter = nil;
    BOOL json = NO;
    for (int i = 1; i < argc; i++) {
        NSString *a = @(argv[i]);
        if ([a isEqualToString:@"--json"]) json = YES;
        else if ([a isEqualToString:@"--action"]) {
            if (i + 1 >= argc) { usage(); return 2; }
            filter = @(argv[++i]);
        } else if ([a isEqualToString:@"-h"] || [a isEqualToString:@"--help"]) {
            usage(); return 0;
        } else if ([a hasPrefix:@"--"]) {
            fprintf(stderr, "unknown flag: %s\n", argv[i]); usage(); return 2;
        } else if (!appArg) {
            appArg = a;
        } else { usage(); return 2; }
    }
    if (!appArg) appArg = @"/System/Applications/Notes.app";

    if (!dlopen("/System/Library/PrivateFrameworks/LinkMetadata.framework/LinkMetadata",
                RTLD_NOW)) {
        fprintf(stderr, "error: cannot load LinkMetadata: %s\n", dlerror());
        return 1;
    }

    NSURL *appURL = ResolveApp(appArg);
    NSBundle *bundle = appURL ? [NSBundle bundleWithURL:appURL] : nil;
    if (!bundle) {
        fprintf(stderr, "error: no app for '%s'\n", appArg.UTF8String);
        return 1;
    }

    NSError *err = nil;
    LNBundleMetadata *md = [[NSClassFromString(@"LNBundleMetadata") alloc]
                             initWithBundle:bundle
                             usingEffectiveBundleIdentifier:nil
                             error:&err];
    if (!md) {
        fprintf(stderr, "error: %s has no readable App Intents metadata%s%s\n",
                bundle.bundleIdentifier.UTF8String ?: appArg.UTF8String,
                err ? ": " : "", err ? err.localizedDescription.UTF8String : "");
        return 1;
    }

    // The metadata version is stamped per-action; read it off any one.
    long long metaVersion = md.actions.count ? md.actions.allValues.firstObject.bundleMetadataVersion : -1;

    // Sort actions by identifier for stable output.
    NSArray *ids = [md.actions.allKeys sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
    if (filter) {
        NSString *f = filter.lowercaseString;
        ids = [ids filteredArrayUsingPredicate:
               [NSPredicate predicateWithBlock:^BOOL(NSString *k, id _) {
                   return [k.lowercaseString containsString:f];
               }]];
    }

    if (json) {
        NSMutableArray *out = [NSMutableArray array];
        for (NSString *k in ids) {
            LNActionMetadata *a = md.actions[k];
            NSMutableArray *params = [NSMutableArray array];
            for (LNActionParameterMetadata *p in a.parameters) {
                NSMutableDictionary *pd = [@{
                    @"name": p.name ?: NSNull.null,
                    @"type": VType(p.valueType),
                    @"optional": @(p.isOptional),
                    @"input": @(p.isInput),
                    @"dynamicOptions": @(p.hasDynamicOptions),
                } mutableCopy];
                NSString *pt = Loc(p.title); if (pt) pd[@"title"] = pt;
                [params addObject:pd];
            }
            NSMutableDictionary *ad = [@{
                @"identifier": k,
                @"opensApp": @(a.openAppWhenRun),
                @"parameters": params,
            } mutableCopy];
            if (a.fullyQualifiedTypeName) ad[@"typeName"] = a.fullyQualifiedTypeName;
            if (a.mangledTypeName)        ad[@"mangledTypeName"] = a.mangledTypeName;
            NSString *t = Loc(a.title);   if (t) ad[@"title"] = t;
            if (a.outputType)             ad[@"output"] = VType(a.outputType);
            if (a.iconSystemImageName)    ad[@"icon"] = a.iconSystemImageName;
            [out addObject:ad];
        }
        NSDictionary *root = @{
            @"app": bundle.bundleIdentifier ?: appArg,
            @"path": bundle.bundlePath,
            @"metadataVersion": @(metaVersion),
            @"actionCount": @(md.actions.count),
            @"actions": out,
        };
        NSData *d = [NSJSONSerialization dataWithJSONObject:root
                        options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                        error:nil];
        fwrite(d.bytes, 1, d.length, stdout);
        fputc('\n', stdout);
        return 0;
    }

    // Human output.
    printf("App: %s  (%s)\n",
           bundle.bundleURL.lastPathComponent.UTF8String,
           (bundle.bundleIdentifier ?: appArg).UTF8String);
    printf("metadata v%lld  •  %lu actions%s\n\n",
           metaVersion, (unsigned long)md.actions.count,
           filter ? [NSString stringWithFormat:@"  (%lu match '%@')",
                     (unsigned long)ids.count, filter].UTF8String : "");

    for (NSString *k in ids) {
        LNActionMetadata *a = md.actions[k];
        printf("%s\n", k.UTF8String);
        NSString *tn = a.fullyQualifiedTypeName ?: a.mangledTypeName;
        if (tn) printf("  type:    %s%s\n", tn.UTF8String,
                       a.fullyQualifiedTypeName && a.mangledTypeName
                         ? [NSString stringWithFormat:@"  (%@)", a.mangledTypeName].UTF8String : "");
        NSString *t = Loc(a.title);
        if (t) printf("  title:   %s\n", t.UTF8String);
        printf("  opens app: %s\n", a.openAppWhenRun ? "yes" : "no");
        if (a.outputType) printf("  output:  %s\n", VType(a.outputType).UTF8String);
        if (a.parameters.count == 0) {
            printf("  parameters: (none)\n");
        } else {
            printf("  parameters:\n");
            for (LNActionParameterMetadata *p in a.parameters) {
                NSMutableArray *tags = [NSMutableArray array];
                [tags addObject:p.isOptional ? @"optional" : @"required"];
                if (p.isInput) [tags addObject:@"input"];
                if (p.hasDynamicOptions) [tags addObject:@"dynamic"];
                printf("    %-22s %-20s (%s)\n",
                       (p.name ?: @"?").UTF8String,
                       VType(p.valueType).UTF8String,
                       [tags componentsJoinedByString:@", "].UTF8String);
            }
        }
        printf("\n");
    }
    return 0;
}}
