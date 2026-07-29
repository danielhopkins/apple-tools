"""Build a .shortcut file that drives Notes' AppIntents from the CLI.

Schema learned empirically from existing shortcuts in ~/Library/Shortcuts/
Shortcuts.sqlite: an AppIntents action is

    {"WFWorkflowActionIdentifier": "<bundleID>.<intentIdentifier>",
     "WFWorkflowActionParameters": {"AppIntentDescriptor": {...}, ...params}}

and "Shortcut Input" in a text field is a WFTextTokenString whose single
object-replacement char maps to an ExtensionInput attachment.
"""
import plistlib, uuid, pathlib, sys

# ⚠️ The Create Note action is NOT com.apple.Notes.CreateNoteLinkAction, and its
# text parameter is NOT `contents`. Both were wrong on the first attempt and the
# shortcut prompted "New note…" instead of binding the input. The real
# serialization, read out of working shortcuts in Shortcuts.sqlite:
#
#   identifier            com.apple.mobilenotes.SharingExtension   (legacy name)
#   text parameter        WFCreateNoteInput
#   descriptor bundle     com.apple.mobilenotes
#
# Delete, by contrast, really is com.apple.Notes.DeleteNotesLinkAction — the
# prefix is per-action, so read a working example before trusting a guess.
BUNDLE = "com.apple.mobilenotes"


def descriptor(intent_id):
    return {
        "TeamIdentifier": "0000000000",
        "BundleIdentifier": BUNDLE,
        "AppIntentIdentifier": intent_id,
        "Name": "Notes",
    }


def shortcut_input():
    """A text parameter bound to the shortcut's input."""
    return {
        "Value": {
            "string": "￼",
            "attachmentsByRange": {"{0, 1}": {"Type": "ExtensionInput"}},
        },
        "WFSerializationType": "WFTextTokenString",
    }


def action(action_identifier, intent_id, params):
    """action_identifier is the WF action name; intent_id goes in the descriptor.

    They are not always derivable from each other — Create Note's action is
    `com.apple.mobilenotes.SharingExtension` while its intent identifier is
    `CreateNoteLinkAction`.
    """
    p = {"UUID": str(uuid.uuid4()).upper(), "AppIntentDescriptor": descriptor(intent_id)}
    p.update(params)
    return {
        "WFWorkflowActionIdentifier": action_identifier,
        "WFWorkflowActionParameters": p,
    }


def workflow(actions, *, accepts_input=True):
    return {
        "WFWorkflowActions": actions,
        "WFWorkflowClientVersion": "3100.0.4.2",
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowIcon": {
            "WFWorkflowIconStartColor": 4274264319,
            "WFWorkflowIconGlyphNumber": 61440,
        },
        "WFWorkflowImportQuestions": [],
        "WFWorkflowTypes": [],
        "WFQuickActionSurfaces": [],
        "WFWorkflowHasOutputFallback": False,
        "WFWorkflowHasShortcutInputVariables": accepts_input,
        "WFWorkflowInputContentItemClasses": [
            "WFStringContentItem",
            "WFRichTextContentItem",
        ],
        "WFWorkflowNoInputBehavior": {
            "Name": "WFWorkflowNoInputBehaviorGetClipboard",
            "Parameters": {},
        },
    }


def build_create_markdown():
    """Create a note from Markdown passed on the CLI. No entity to resolve."""
    return workflow([
        action("com.apple.mobilenotes.SharingExtension", "CreateNoteLinkAction", {
            "WFCreateNoteInput": shortcut_input(),
            "interpretAsMarkdown": True,
            "OpenWhenRun": False,   # keep it headless — the sample had this true
        })
    ])


def main():
    out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "NotesCreateMarkdown.shortcut")
    out.write_bytes(plistlib.dumps(build_create_markdown(), fmt=plistlib.FMT_BINARY))
    print(f"wrote {out} ({out.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
