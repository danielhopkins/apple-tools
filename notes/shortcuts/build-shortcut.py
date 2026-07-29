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


APPEND_TARGET = "__claude_notes_test__append_target"


def extension_input_attachment():
    """The shortcut's own input, as a non-text (attachment) reference."""
    return {"Value": {"Type": "ExtensionInput"},
            "WFSerializationType": "WFTextTokenAttachment"}


def literal_text(s):
    return {"Value": {"string": s}, "WFSerializationType": "WFTextTokenString"}


def variable_text(uuid_str, name):
    """A text field whose whole content is one earlier action's output."""
    return {
        "Value": {"string": "￼",
                  "attachmentsByRange": {
                      "{0, 1}": {"OutputUUID": uuid_str, "Type": "ActionOutput",
                                 "OutputName": name}}},
        "WFSerializationType": "WFTextTokenString",
    }


def get_dictionary(uuid_str):
    return {
        "WFWorkflowActionIdentifier": "is.workflow.actions.detect.dictionary",
        "WFWorkflowActionParameters": {
            "UUID": uuid_str,
            "WFInput": extension_input_attachment(),
        },
    }


def value_for_key(uuid_str, dict_uuid, key):
    return {
        "WFWorkflowActionIdentifier": "is.workflow.actions.getvalueforkey",
        "WFWorkflowActionParameters": {
            "UUID": uuid_str,
            "WFInput": {"Value": {"OutputUUID": dict_uuid, "Type": "ActionOutput",
                                  "OutputName": "Dictionary"},
                        "WFSerializationType": "WFTextTokenAttachment"},
            "WFDictionaryKey": literal_text(key),
            "CustomOutputName": key,
        },
    }


def find_note_by_name(name, uuid_str):
    """`name` may be a literal str or a serialized variable dict."""
    """`is.workflow.actions.filter.notes` matching Name exactly.

    Structure copied from a working shortcut; Operator 99 is "is" and the
    calendar-unit cruft in Values is required even for a string match.
    """
    return {
        "WFWorkflowActionIdentifier": "is.workflow.actions.filter.notes",
        "WFWorkflowActionParameters": {
            "UUID": uuid_str,
            "WFContentItemFilter": {
                "Value": {
                    "WFActionParameterFilterPrefix": 1,
                    "WFActionParameterFilterTemplates": [{
                        "Operator": 99,
                        "Property": "Name",
                        "Removable": True,
                        "Values": {
                            "String": name,
                            "Unit": {"Value": 4,
                                     "WFSerializationType":
                                         "WFCalendarUnitSubstitutableState"},
                        },
                    }],
                    "WFContentPredicateBoundedDate": False,
                },
                "WFSerializationType": "WFContentPredicateTableTemplate",
            },
            "AppIntentDescriptor": {
                "TeamIdentifier": "0000000000",
                "BundleIdentifier": "com.apple.Notes",
                "AppIntentIdentifier": "NoteEntity",
                "ActionRequiresAppInstallation": True,
                "Name": "Notes",
            },
        },
    }


def action_output(uuid_str, name="Note"):
    """Reference an earlier action's output as a parameter value."""
    return {
        "Value": {"OutputUUID": uuid_str, "Type": "ActionOutput", "OutputName": name},
        "WFSerializationType": "WFTextTokenAttachment",
    }


def build_append_markdown():
    """Append Markdown to a fixed note — the smallest test of AppendToNoteIntent.

    Deliberately not generic yet: resolving an arbitrary note name would need a
    dictionary-input pipeline in front, and the question worth answering first
    is whether a real append preserves attachments and checklists at all.
    """
    find_uuid = str(uuid.uuid4()).upper()
    return workflow([
        find_note_by_name(APPEND_TARGET, find_uuid),
        # ⚠️ Append is `is.workflow.actions.appendnote` with WFNote/WFInput —
        # NOT com.apple.Notes.AppendToNoteLinkAction with entity/text, which is
        # what the intent metadata's parameter names suggest. Shortcuts silently
        # normalises the wrong action identifier to the right one on import but
        # keeps the wrong parameter names, so the action looks correct in the
        # editor and prompts for a note at run time instead of binding.
        # Verified against three working shortcuts in Shortcuts.sqlite.
        action("is.workflow.actions.appendnote", "AppendToNoteLinkAction", {
            "WFNote": action_output(find_uuid),
            "WFInput": shortcut_input(),
            "interpretAsMarkdown": True,
        }),
    ])


def build_generic_append():
    """Append Markdown to ANY note, named at call time.

    Input is JSON: {"note": "<exact title>", "text": "<markdown>"}

        shortcuts run "<name>" --input-path payload.json

    Five actions: read the dictionary, pull "note", find that note, pull "text",
    append it. The note name reaches the filter as a variable — the one piece
    with no working example to copy, since nothing in the sampled library puts a
    variable inside a filter template.
    """
    dict_uuid = str(uuid.uuid4()).upper()
    name_uuid = str(uuid.uuid4()).upper()
    find_uuid = str(uuid.uuid4()).upper()
    text_uuid = str(uuid.uuid4()).upper()
    return workflow([
        get_dictionary(dict_uuid),
        value_for_key(name_uuid, dict_uuid, "note"),
        find_note_by_name(variable_text(name_uuid, "note"), find_uuid),
        value_for_key(text_uuid, dict_uuid, "text"),
        action("is.workflow.actions.appendnote", "AppendToNoteLinkAction", {
            "WFNote": action_output(find_uuid),
            "WFInput": variable_text(text_uuid, "text"),
            "interpretAsMarkdown": True,
        }),
    ])


# The installed shortcut takes its NAME from the file name, so these are the
# user-visible names. Keep them stable — `apple notes install-shortcuts` and
# `apple notes status` both look them up by name.
SHIPPED = {
    "Apple Tools Create Note": "create",
    "Apple Tools Append Note": "generic-append",
}


def build(which):
    return {"create": build_create_markdown,
            "append": build_append_markdown,
            "generic-append": build_generic_append}[which]()


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--ship":
        # Emit both shipping shortcuts, signed, into the given directory.
        import subprocess
        outdir = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else ".")
        outdir.mkdir(parents=True, exist_ok=True)
        import tempfile
        for name, which in SHIPPED.items():
            final = outdir / f"{name}.shortcut"
            # `shortcuts sign` rejects an input that is not named *.shortcut,
            # and will not sign in place, so stage the unsigned copy elsewhere.
            with tempfile.TemporaryDirectory() as td:
                raw = pathlib.Path(td) / f"{name}.shortcut"
                raw.write_bytes(plistlib.dumps(build(which), fmt=plistlib.FMT_BINARY))
                subprocess.run(["shortcuts", "sign", "--mode", "anyone",
                                "--input", str(raw), "--output", str(final)], check=True)
            print(f"  {final}  ({final.stat().st_size} bytes)")
        return

    out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "NotesCreateMarkdown.shortcut")
    which = sys.argv[2] if len(sys.argv) > 2 else "create"
    out.write_bytes(plistlib.dumps(build(which), fmt=plistlib.FMT_BINARY))
    print(f"wrote {out} ({out.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
