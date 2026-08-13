#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Reminders **tags** through the private `ReminderKit` framework.
///
/// There is no public API for this, and it is not an oversight in the search:
///
///   * EventKit has no tag surface at all. Every "tag" symbol on `EKReminder`,
///     `EKCalendarItem`, `EKCalendar` and `EKSource` is
///     `externalModificationTag` / `externalIDTag` — HTTP ETags for sync.
///   * Reminders.app's AppleScript dictionary defines three classes and twelve
///     reminder properties, and the string "tag" appears in it zero times.
///   * The App Intents metadata *does* describe an `AddOrRemoveTagsAppIntent`
///     with a plain `[String]` tags parameter, but its action identifiers do
///     not resolve: a shortcut built around one is rejected by Shortcuts with
///     "not supported on this device".
///
/// What does work is Shortcuts' *legacy* content-item setter
/// (`is.workflow.actions.setters.reminders`, `WFContentItemPropertyName:
/// "Tags"`), and that is the fallback if this file ever stops working — but it
/// costs a one-time shortcut install, and it can only find a reminder **by
/// title**, so it tags the wrong one whenever two share a name.
///
/// `ReminderKit` has neither problem. It resolves a reminder by the same
/// identifier EventKit already reports as `calendarItemExternalIdentifier`, so
/// there is no ambiguity, and it needs no install and no extra grant — the
/// Reminders TCC grant the tool already holds is enough. Verified from an
/// unsigned binary: `REMStore` instantiates, reads, and saves.
///
/// 🛑 Everything here is resolved at runtime. If a future macOS renames or
/// removes a symbol, each function fails cleanly with `unavailable` rather than
/// crashing, and reading a reminder still works — only tags go missing.
///
/// ⚠️ A tag is **invisible to EventKit**. Setting one does not change the
/// reminder's title (measured: the title came back byte-identical), so nothing
/// in the EventKit-backed half of this tool can see it. That is why tags are
/// read here rather than off `EKReminder`.

/// Error domain for every failure raised by this bridge.
extern NSErrorDomain const AppleToolsReminderKitErrorDomain;

typedef NS_ENUM(NSInteger, AppleToolsReminderKitError) {
    /// A required `ReminderKit` symbol could not be resolved. The framework
    /// moved, or the private API changed shape.
    AppleToolsReminderKitErrorUnavailable = 1,
    /// No reminder carries that external identifier.
    AppleToolsReminderKitErrorNotFound = 2,
    /// `saveSynchronouslyWithError:` reported a failure.
    AppleToolsReminderKitErrorSaveFailed = 3,
    /// The save reported success but a fresh read did not corroborate it.
    AppleToolsReminderKitErrorNotConfirmed = 4,
};

/// Whether the private API is reachable. False means every other call here
/// will fail with `unavailable`; callers should degrade to "tags unsupported"
/// rather than treating it as an error on the user's data.
BOOL AppleToolsReminderKitAvailable(void);

/// Tags for each of `externalIds`, keyed by identifier.
///
/// Identifiers with no tags are omitted rather than mapped to an empty array,
/// so the common case (a store with no tags at all) returns an empty
/// dictionary. Opens the store once for the whole batch — this is called for
/// every reminder in a listing, and one store per reminder was too slow.
///
/// An identifier that does not resolve is skipped, not an error: a listing
/// should not fail because one reminder was deleted mid-run.
NSDictionary<NSString *, NSArray<NSString *> *> *_Nullable
AppleToolsReadReminderTags(NSArray<NSString *> *externalIds,
                           NSError *_Nullable *_Nullable error);

/// Add and/or remove tags on one reminder, returning the tags it carries
/// afterwards as read back from a **fresh** store.
///
/// `replaceAll` clears every existing tag first, making `add` the complete new
/// set — that is what `--tag` on `edit` means, and it matches Shortcuts' own
/// `Mode: "Set"`. With `replaceAll` false, `add` and `remove` are applied to
/// what is already there.
///
/// 🛑 The read-back is not optional. `saveSynchronouslyWithError:` returning
/// YES is not evidence anything persisted — three separate Apple APIs in this
/// repo report success for writes that never happened — so this re-opens the
/// store, compares, and fails with `notConfirmed` naming the tags that did not
/// land rather than reporting the request back as if it were the result.
///
/// Matching is case-insensitive, because Reminders stores a lowercased
/// `canonicalName` alongside the display name and treats `PTA` and `pta` as one
/// tag. The display case of an existing tag is preserved.
NSArray<NSString *> *_Nullable
AppleToolsApplyReminderTags(NSString *externalId,
                            NSArray<NSString *> *add,
                            NSArray<NSString *> *remove,
                            BOOL replaceAll,
                            NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
