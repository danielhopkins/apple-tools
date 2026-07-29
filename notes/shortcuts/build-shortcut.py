"""Build a .shortcut file that drives Notes' AppIntents from the CLI.

Schema learned empirically from existing shortcuts in ~/Library/Shortcuts/
Shortcuts.sqlite: an AppIntents action is

    {"WFWorkflowActionIdentifier": "<bundleID>.<intentIdentifier>",
     "WFWorkflowActionParameters": {"AppIntentDescriptor": {...}, ...params}}

and "Shortcut Input" in a text field is a WFTextTokenString whose single
object-replacement char maps to an ExtensionInput attachment.
"""
import plistlib, uuid, pathlib, sys

BUNDLE = "com.apple.Notes"


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


def action(intent_id, params):
    p = {"UUID": str(uuid.uuid4()).upper(), "AppIntentDescriptor": descriptor(intent_id)}
    p.update(params)
    return {
        "WFWorkflowActionIdentifier": f"{BUNDLE}.{intent_id}",
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
    """v1: create a note from Markdown passed on the CLI. No entity to resolve."""
    return workflow([
        action("CreateNoteLinkAction", {
            "contents": shortcut_input(),
            "interpretAsMarkdown": True,
        })
    ])


def main():
    out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "NotesCreateMarkdown.shortcut")
    out.write_bytes(plistlib.dumps(build_create_markdown(), fmt=plistlib.FMT_BINARY))
    print(f"wrote {out} ({out.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
