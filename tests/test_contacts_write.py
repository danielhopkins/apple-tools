"""Live write-path tests for apple-contacts.

Covers the surface that had never been exercised against real data: relations,
the two native date models plus arbitrary labelled dates, multi-value replace
semantics, and group membership.

Every fixture is created with TEST_PREFIX as its first name and swept after
each test. See contacts_harness for the safety rules.
"""

import os
import tempfile
import unittest

from contacts_harness import (
    TEST_PREFIX,
    LiveContactsTest,
    find_test_contacts,
    find_test_groups,
    run,
    run_json,
)


class NameAndOrganisation(LiveContactsTest):
    def test_add_returns_the_created_contact(self):
        created = self.add("Basic", "--company", "Acme")
        self.assertEqual(created["first_name"], TEST_PREFIX)
        self.assertEqual(created["last_name"], "Basic")
        self.assertEqual(created["company"], "Acme")
        self.assertTrue(created["id"].endswith(":ABPerson"))

    def test_get_round_trips_every_name_part(self):
        created = self.add(
            "Full",
            "--middle", "Quentin",
            "--name-prefix", "Dr",
            "--name-suffix", "PhD",
            "--nickname", "Q",
            "--department", "Research",
            "--job-title", "Principal",
        )
        fetched = self.get(created["id"])
        self.assertEqual(fetched["middle_name"], "Quentin")
        # The flags are --name-prefix/--name-suffix; the JSON keys are not.
        self.assertEqual(fetched["prefix"], "Dr")
        self.assertEqual(fetched["suffix"], "PhD")
        self.assertEqual(fetched["nickname"], "Q")
        self.assertEqual(fetched["department"], "Research")
        self.assertEqual(fetched["job_title"], "Principal")

    def test_edit_changes_only_what_it_is_given(self):
        created = self.add("Narrow", "--company", "Before", "--job-title", "Keep")
        self.edit(created["id"], "--company", "After")
        fetched = self.get(created["id"])
        self.assertEqual(fetched["company"], "After")
        self.assertEqual(fetched["job_title"], "Keep")
        self.assertEqual(fetched["last_name"], "Narrow")


class Relations(LiveContactsTest):
    def test_relations_round_trip(self):
        created = self.add(
            "Kin",
            "--relation", "father:Robert Test",
            "--relation", "sister:Jane Test",
        )
        relations = self.labelled(self.get(created["id"])["relations"], "name")
        self.assertEqual(relations, {"father": "Robert Test", "sister": "Jane Test"})

    def test_label_matching_ignores_case_spaces_and_hyphens(self):
        created = self.add("Fuzzy", "--relation", "younger-sister:Amy Test")
        relations = self.labelled(self.get(created["id"])["relations"], "name")
        # "younger-sister" must resolve to the SDK's youngerSister constant
        # rather than being stored verbatim as a custom label. Reading it back
        # decodes the constant to its display form, "younger sister".
        self.assertEqual(relations, {"younger sister": "Amy Test"})

    def test_unknown_label_is_kept_as_a_custom_label(self):
        code, _, err = run(
            "add", "--first", TEST_PREFIX, "--last", "Typo",
            "--relation", "fathr:Bob Test", "--json", check=False)
        self.assertEqual(code, 0, err)
        # A typo must not be silently dropped, and should hint at the real label.
        created = run_json("search", TEST_PREFIX, "--limit", "50")
        typo = [c for c in created if c["last_name"] == "Typo"][0]
        relations = self.labelled(self.get(typo["id"])["relations"], "name")
        self.assertEqual(relations.get("fathr"), "Bob Test")
        # A typo shares no substring with the real label, so the hint has to
        # fall back to edit distance to be worth anything.
        self.assertIn("did you mean: father", err.lower())
        # And the warning must be emitted exactly once, not once per process
        # in the TCC re-exec chain.
        self.assertEqual(err.lower().count("not a standard relation"), 1)

    def test_relations_replace_rather_than_append(self):
        created = self.add(
            "Replace",
            "--relation", "father:Robert Test",
            "--relation", "mother:Mary Test",
        )
        self.edit(created["id"], "--relation", "brother:Sam Test")
        relations = self.labelled(self.get(created["id"])["relations"], "name")
        self.assertEqual(relations, {"brother": "Sam Test"})


class Dates(LiveContactsTest):
    def test_birthday_with_year(self):
        created = self.add("Bday", "--birthday", "1980-03-04")
        self.assertEqual(self.get(created["id"])["birthday"], "1980-03-04")

    def test_birthday_without_year(self):
        # The --MM-DD form has to be passed as --birthday=--MM-DD, because
        # ArgumentParser reads a leading -- as the next flag.
        created = self.add("NoYear", "--birthday=--04-13")
        self.assertEqual(self.get(created["id"])["birthday"], "--04-13")

    def test_anniversary_is_stored_as_a_labelled_date(self):
        created = self.add("Anniv", "--anniversary", "2010-06-15")
        dates = self.labelled(self.get(created["id"])["dates"], "date")
        self.assertEqual(dates["anniversary"], "2010-06-15")

    def test_custom_date_label(self):
        created = self.add("Death", "--date", "death:2020-05-01")
        dates = self.labelled(self.get(created["id"])["dates"], "date")
        self.assertEqual(dates["death"], "2020-05-01")

    def test_several_dates_coexist(self):
        created = self.add(
            "Many",
            "--birthday", "1980-03-04",
            "--anniversary", "2010-06-15",
            "--date", "death:2020-05-01",
            "--date", "graduation:--06-15",
        )
        fetched = self.get(created["id"])
        dates = self.labelled(fetched["dates"], "date")
        self.assertEqual(fetched["birthday"], "1980-03-04")
        self.assertEqual(dates["anniversary"], "2010-06-15")
        self.assertEqual(dates["death"], "2020-05-01")
        self.assertEqual(dates["graduation"], "--06-15")

    def test_dates_replace_rather_than_append(self):
        created = self.add(
            "DateReplace",
            "--date", "death:2020-05-01",
            "--date", "graduation:2000-06-15",
        )
        self.edit(created["id"], "--date", "retirement:2030-01-01")
        dates = self.labelled(self.get(created["id"])["dates"], "date")
        self.assertEqual(dates, {"retirement": "2030-01-01"})


class MultiValueFields(LiveContactsTest):
    def test_labelled_and_unlabelled_values(self):
        created = self.add(
            "Multi",
            "--email", "work:a@example.invalid",
            "--email", "b@example.invalid",
            "--phone", "mobile:+15555550123",
            "--url", "work:https://example.invalid",
        )
        fetched = self.get(created["id"])
        by_label = {e.get("label"): e["address"] for e in fetched["emails"]}
        self.assertEqual(by_label["work"], "a@example.invalid")
        # An unlabelled value omits the key entirely rather than emitting null.
        self.assertEqual(by_label[None], "b@example.invalid")
        self.assertEqual(self.labelled(fetched["phones"], "number"),
                         {"mobile": "+15555550123"})
        self.assertEqual(self.labelled(fetched["urls"], "url"),
                         {"work": "https://example.invalid"})

    def test_editing_email_replaces_every_existing_one(self):
        """The documented sharp edge: --email on edit is replace, not append."""
        created = self.add(
            "Wipe",
            "--email", "work:a@example.invalid",
            "--email", "home:b@example.invalid",
        )
        self.assertEqual(len(self.get(created["id"])["emails"]), 2)

        self.edit(created["id"], "--email", "other:c@example.invalid")
        emails = self.get(created["id"])["emails"]
        self.assertEqual(len(emails), 1)
        self.assertEqual(emails[0]["address"], "c@example.invalid")

    def test_editing_one_multivalue_leaves_the_others_alone(self):
        created = self.add(
            "Isolated",
            "--email", "work:a@example.invalid",
            "--phone", "mobile:+15555550123",
        )
        self.edit(created["id"], "--email", "home:b@example.invalid")
        fetched = self.get(created["id"])
        self.assertEqual(self.labelled(fetched["phones"], "number"),
                         {"mobile": "+15555550123"})
        self.assertEqual(self.labelled(fetched["emails"], "address"),
                         {"home": "b@example.invalid"})


class Search(LiveContactsTest):
    def test_phone_search_ignores_formatting(self):
        created = self.add("Phone", "--phone", "mobile:+1 (720) 555-9876")
        found = run_json("search", "7205559876", "--limit", "50")
        self.assertIn(created["id"], [c["id"] for c in found])

    def test_search_matches_company(self):
        created = self.add("Corp", "--company", "Zzyzx Test Industries")
        found = run_json("search", "Zzyzx", "--limit", "50")
        self.assertIn(created["id"], [c["id"] for c in found])


class Notes(LiveContactsTest):
    def test_note_is_rejected_with_an_explanation(self):
        code, _, err = run(
            "add", "--first", TEST_PREFIX, "--last", "Noted",
            "--note", "should not work", check=False)
        self.assertNotEqual(code, 0)
        self.assertIn("entitlement", err.lower())


class GroupFixtures(LiveContactsTest):
    """Group fixture helpers, shared by the group and container suites."""

    def group_name(self, suffix):
        return f"{TEST_PREFIX} {suffix}"

    def create_group(self, suffix, *extra):
        run("groups", "create", self.group_name(suffix), *extra, check=True)
        matches = [g for g in find_test_groups()
                   if g["name"] == self.group_name(suffix)]
        self.assertEqual(len(matches), 1, f"group {suffix!r} not created")
        return matches[0]


class Groups(GroupFixtures):
    def test_create_and_delete_a_group(self):
        group = self.create_group("Create")
        self.assertEqual(group["count"], 0)

        run("groups", "delete", group["id"])
        self.assertNotIn(group["id"], [g["id"] for g in find_test_groups()])

    def test_rename_a_group(self):
        group = self.create_group("Before")
        run("groups", "rename", group["id"], self.group_name("After"))
        names = [g["name"] for g in find_test_groups()]
        self.assertIn(self.group_name("After"), names)
        self.assertNotIn(self.group_name("Before"), names)

    def test_add_and_remove_a_member(self):
        group = self.create_group("Members")
        contact = self.add("Member")

        run("groups", "add", group["id"], contact["id"])
        members = run_json("groups", "members", group["id"])
        self.assertIn(contact["id"], [m["id"] for m in members])

        run("groups", "remove", group["id"], contact["id"])
        members = run_json("groups", "members", group["id"])
        self.assertEqual(members, [])

    def test_removing_a_member_keeps_the_contact(self):
        group = self.create_group("Keep")
        contact = self.add("Kept")
        run("groups", "add", group["id"], contact["id"])
        run("groups", "remove", group["id"], contact["id"])
        self.assertTrue(self.exists(contact["id"]))

    def test_deleting_a_group_keeps_its_contacts(self):
        group = self.create_group("Doomed")
        contact = self.add("Survivor")
        run("groups", "add", group["id"], contact["id"])

        run("groups", "delete", group["id"])
        self.assertTrue(self.exists(contact["id"]))

    def test_group_resolves_by_name_as_well_as_id(self):
        group = self.create_group("ByName")
        contact = self.add("Named")
        run("groups", "add", self.group_name("ByName"), contact["id"])
        members = run_json("groups", "members", self.group_name("ByName"))
        self.assertIn(contact["id"], [m["id"] for m in members])
        self.assertEqual(group["name"], self.group_name("ByName"))

    def test_adding_a_freshly_created_contact_works_repeatedly(self):
        """The reported bug: a contact from `add` could not join an iCloud group.

        `groups add` fetched its contact with `unifiedContact(withIdentifier:)`,
        and `CNSaveRequest.addMember` rejects a unified contact — it needs the
        container-backed record. The failure was
        `Save operation could not be completed.` and nothing else.

        It looked intermittent because a brand-new contact is usually unlinked,
        so its unified form is indistinguishable from its backing record and the
        add succeeds. Once macOS links it, the unified contact's identifier can
        belong to a *different* linked record and the save is refused. The
        original report saw the first contact of a session succeed and every one
        after it fail, so this runs the whole cycle twice — the second iteration
        is the one that reproduced it.
        """
        group = self.create_group("FreshMembers")

        for attempt in range(2):
            contact = self.add(f"Fresh{attempt}")

            result = run_json("groups", "add", group["id"], contact["id"], "--json")
            self.assertTrue(
                result["changed"],
                f"attempt {attempt}: add reported no change: {result}")
            self.assertTrue(result["member"], f"attempt {attempt}: {result}")

            # Confirm through a separate read, not the command's own word.
            members = run_json("groups", "members", group["id"])
            self.assertIn(
                contact["id"], [m["id"] for m in members],
                f"attempt {attempt}: contact is not in the group after a successful add")

            # The report's sequence: remove and delete before the next round,
            # since that ordering immediately preceded the first failure.
            run("groups", "remove", group["id"], contact["id"])
            run("delete", contact["id"])

    def test_membership_check_spans_both_identifier_forms(self):
        """A membership check must not compare a unified id against a backing one.

        `groups add` fetches its contact non-unified — it has to, since
        `addMember` rejects a unified contact — so it holds a backing-record id
        like `D065726A-…:ABPerson`, while a `unifiedContacts` fetch of the group
        returns `BD00169D-…` for the same person. Comparing across the two made a
        *successful* add report "the save reported success but X is not in the
        group", which makes the command unusable for any contact macOS has linked.

        Adding twice is the cheap way to catch it: the second call must see the
        first one's membership, whichever spelling each side used.
        """
        group = self.create_group("IdForms")
        contact = self.add("Linked")

        first = run_json("groups", "add", group["id"], contact["id"], "--json")
        self.assertTrue(first["changed"])

        # If the two identifier forms were compared naively, this reports
        # changed:true again — or the add path throws its "reported success but
        # is not in the group" false alarm.
        second = run_json("groups", "add", group["id"], contact["id"], "--json")
        self.assertFalse(second["changed"])
        self.assertTrue(second["member"])

        # And a removal must see it too, or it would refuse as a non-member.
        removed = run_json("groups", "remove", group["id"], contact["id"], "--json")
        self.assertTrue(removed["changed"], "remove could not see the membership")
        self.assertEqual(run_json("groups", "members", group["id"]), [])

    def test_adding_an_existing_member_reports_no_change(self):
        """Exiting 0 is not the same as having done something.

        The framework accepts a duplicate add silently, and the command used to
        print "Added ..." for it — a no-op dressed up as an action.
        """
        group = self.create_group("Duplicate")
        contact = self.add("Twice")

        first = run_json("groups", "add", group["id"], contact["id"], "--json")
        self.assertTrue(first["changed"])

        second = run_json("groups", "add", group["id"], contact["id"], "--json")
        self.assertFalse(second["changed"], f"a repeat add claimed to change something: {second}")
        self.assertTrue(second["member"])

        # And it really is in there exactly once.
        members = run_json("groups", "members", group["id"])
        self.assertEqual([m["id"] for m in members].count(contact["id"]), 1)

    def test_removing_a_non_member_reports_no_change(self):
        """The mirror of the above, which had the same flaw."""
        group = self.create_group("NeverJoined")
        contact = self.add("Outsider")

        result = run_json("groups", "remove", group["id"], contact["id"], "--json")
        self.assertFalse(result["changed"], f"removing a non-member claimed a change: {result}")
        self.assertFalse(result["member"])
        self.assertTrue(self.exists(contact["id"]))

    def test_membership_commands_accept_json(self):
        """`--json` is the documented contract for anything parsed, and these
        two commands used to reject it outright."""
        group = self.create_group("JsonShape")
        contact = self.add("Shaped")

        added = run_json("groups", "add", group["id"], contact["id"], "--json")
        self.assertEqual(
            set(added), {"group", "contact_id", "member", "changed"}, f"unexpected shape: {added}")
        self.assertEqual(added["contact_id"], contact["id"])
        self.assertEqual(added["group"], self.group_name("JsonShape"))

        removed = run_json("groups", "remove", group["id"], contact["id"], "--json")
        self.assertEqual(set(removed), {"group", "contact_id", "member", "changed"})
        self.assertFalse(removed["member"])

    def test_get_reports_group_membership(self):
        group = self.create_group("Reported")
        contact = self.add("Reportee")
        run("groups", "add", group["id"], contact["id"])
        fetched = self.get(contact["id"])
        # `groups` is a list of names; Contacts has no reverse lookup, so only
        # `get` populates it.
        self.assertIn(self.group_name("Reported"), fetched.get("groups", []))


class Containers(GroupFixtures):
    """Container handling, which is what actually broke `groups add`.

    A `CNSaveRequest` cannot span two containers: adding a contact from one
    account to a group in another fails with Core Data's
    `NSPersistentStoreIncompleteSaveError` (134040), which names neither store.
    Nothing in the Contacts API surfaces a contact's container, so the mismatch
    was invisible — the contact was simply in the wrong account, permanently, and
    no amount of retrying helped.
    """

    def containers(self):
        return run_json("containers", "--json")

    def other_container(self):
        """A container that is not the default, or skip."""
        containers = self.containers()
        others = [c for c in containers if not c["default"]]
        if not others:
            self.skipTest("only one container on this machine")
        return others[0]

    def test_containers_lists_accounts_with_exactly_one_default(self):
        containers = self.containers()
        self.assertTrue(containers, "no containers at all")
        for entry in containers:
            self.assertEqual(
                set(entry), {"id", "name", "type", "default"}, f"unexpected shape: {entry}")
            self.assertTrue(entry["name"], "a container with a blank name is unreadable")
        self.assertEqual(
            [c["default"] for c in containers].count(True), 1,
            "exactly one container must be the default")

    def test_add_reports_which_container_it_used(self):
        created = self.add("Landed")
        self.assertIn("container", created)
        default = [c["id"] for c in self.containers() if c["default"]][0]
        self.assertEqual(
            created["container"], default,
            "a plain add must land in the default container, and must say so")

    def test_add_honours_an_explicit_container_by_name(self):
        target = self.other_container()
        created = run_json(
            "add", "--first", TEST_PREFIX, "--last", "Explicit",
            "--container", target["name"], "--json")
        self.assertEqual(created["container"], target["id"])

    def test_an_unknown_container_is_rejected_not_ignored(self):
        """It used to be silently ignored.

        `add(_:toContainerWithIdentifier:)` treats an unknown identifier as nil
        and files the record in the default container, so the command reported
        success and put the contact somewhere else — which is what makes a later
        cross-container failure impossible to explain.
        """
        code, _, err = run(
            "add", "--first", TEST_PREFIX, "--last", "BadContainer",
            "--container", "___no_such_container___", "--json", check=False)
        self.assertNotEqual(code, 0, "an unknown container must not succeed")
        self.assertIn("no container", err)
        # And it must name the valid ones, or the caller still cannot proceed.
        for entry in self.containers():
            self.assertIn(entry["id"], err)
        # Nothing was created.
        self.assertEqual(
            [c for c in find_test_contacts() if c["last_name"] == "BadContainer"], [])

    def test_get_and_groups_report_their_container(self):
        group = self.create_group("Located")
        contact = self.add("Located")

        self.assertIsNotNone(self.get(contact["id"]).get("container"))
        listed = [g for g in run_json("groups", "--json") if g["id"] == group["id"]][0]
        self.assertIsNotNone(listed.get("container"), "groups must report their container")

    def test_cross_container_add_names_the_mismatch(self):
        """The reported failure, and the message that ends the investigation.

        Before, this was `Save operation could not be completed.` — or after the
        first fix, that plus `NSCocoaErrorDomain 134040`, which is Core Data's
        "one or more stores returned an error" and names neither.
        """
        target = self.other_container()
        group = self.create_group("SameAccount")  # default container
        contact = run_json(
            "add", "--first", TEST_PREFIX, "--last", "Elsewhere",
            "--container", target["id"], "--json")
        self.assertEqual(contact["container"], target["id"])

        code, out, err = run("groups", "add", group["id"], contact["id"], check=False)
        self.assertNotEqual(code, 0, "a cross-container add cannot succeed")

        # It must name both sides. That is the whole point.
        self.assertIn("different accounts", err)
        self.assertIn(target["name"], err)

        # A runtime failure is not an argument error, so no usage block and not
        # ArgumentParser's exit 64.
        self.assertNotIn("Usage:", err + out)
        self.assertEqual(code, 1)

        # And it really did not join.
        self.assertEqual(run_json("groups", "members", group["id"]), [])


class LocalContainerGroups(LiveContactsTest):
    """Group removal through the framework, which only works for some containers.

    `CNSaveRequest.removeMember` saves without error and changes nothing for a
    CardDAV-backed (iCloud) group, but does the right thing for a local one. So
    `groups remove` tries the framework first and only falls back to driving
    Contacts.app when the membership survived. This covers the framework half;
    the Groups class above covers the fallback, since the default container here
    is CardDAV.
    """

    CONTAINER = "On My Mac"

    def local_or_skip(self, *args):
        code, out, err = run(*args, check=False)
        if code != 0:
            self.skipTest(f"no usable local container: {err.strip()}")
        return out

    def test_remove_member_from_a_local_group(self):
        name = f"{TEST_PREFIX} Local"
        self.local_or_skip("groups", "create", name, "--container", self.CONTAINER)
        groups = [g for g in find_test_groups() if g["name"] == name]
        self.assertEqual(len(groups), 1)
        group = groups[0]

        self.local_or_skip(
            "add", "--first", TEST_PREFIX, "--last", "LocalMember",
            "--container", self.CONTAINER, "--json")
        contact = [c for c in find_test_contacts()
                   if c["last_name"] == "LocalMember"][0]

        run("groups", "add", group["id"], contact["id"])
        self.assertEqual(len(run_json("groups", "members", group["id"])), 1)

        run("groups", "remove", group["id"], contact["id"])
        self.assertEqual(run_json("groups", "members", group["id"]), [])
        # The contact itself survives, as for any other group removal.
        self.assertTrue(self.exists(contact["id"]))


class VCardExport(LiveContactsTest):
    """`export` is read-only, but it runs here because it needs fixtures."""

    def cards(self, text):
        """Number of vCards in a serialised blob."""
        return text.count("BEGIN:VCARD")

    def test_export_writes_a_vcard_to_stdout(self):
        created = self.add("Card", "--email", "work:card@example.invalid")
        _, out, _ = run("export", created["id"])
        self.assertEqual(self.cards(out), 1)
        self.assertIn("END:VCARD", out)
        self.assertIn("VERSION:3.0", out)
        self.assertIn("card@example.invalid", out)

    def test_export_preserves_relations_and_birthday(self):
        created = self.add(
            "Rich", "--birthday", "1980-03-04", "--relation", "father:Robert Test")
        _, out, _ = run("export", created["id"])
        self.assertIn("BDAY:1980-03-04", out)
        self.assertIn("Robert Test", out)
        # The relation label rides along as an X-ABLabel rather than being lost.
        self.assertIn("X-ABLabel", out)

    def test_export_to_a_file(self):
        created = self.add("File")
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "out.vcf")
            _, _, err = run("export", created["id"], "-o", path)
            self.assertIn("Exported 1 contact", err)
            with open(path, encoding="utf-8") as handle:
                self.assertEqual(self.cards(handle.read()), 1)

    def test_export_several_ids_into_one_file(self):
        first = self.add("One")
        second = self.add("Two")
        _, out, _ = run("export", first["id"], second["id"])
        self.assertEqual(self.cards(out), 2)

    def test_export_a_whole_group(self):
        name = f"{TEST_PREFIX} Export"
        run("groups", "create", name)
        group = [g for g in find_test_groups() if g["name"] == name][0]
        for suffix in ("GroupA", "GroupB"):
            member = self.add(suffix)
            run("groups", "add", group["id"], member["id"])

        _, out, _ = run("export", "--group", name)
        self.assertEqual(self.cards(out), 2)

    def test_a_contact_named_twice_is_exported_once(self):
        name = f"{TEST_PREFIX} Dedupe"
        run("groups", "create", name)
        group = [g for g in find_test_groups() if g["name"] == name][0]
        member = self.add("Both")
        run("groups", "add", group["id"], member["id"])

        _, out, _ = run("export", member["id"], "--group", name)
        self.assertEqual(self.cards(out), 1)

    def test_export_needs_something_to_export(self):
        code, _, err = run("export", check=False)
        self.assertNotEqual(code, 0)
        self.assertIn("--group", err)

    def test_export_rejects_an_unknown_id(self):
        code, _, err = run("export", "not-a-real-id:ABPerson", check=False)
        self.assertNotEqual(code, 0)
        self.assertIn("no contact", err.lower())


class Deletion(LiveContactsTest):
    def test_delete_removes_the_contact(self):
        created = self.add("Ephemeral")
        self.assertTrue(self.exists(created["id"]))
        run("delete", created["id"])
        self.assertFalse(self.exists(created["id"]))

    def test_deleting_an_unknown_id_fails_cleanly(self):
        code, _, err = run("delete", "not-a-real-id:ABPerson", check=False)
        self.assertNotEqual(code, 0)
        self.assertTrue(err.strip())


if __name__ == "__main__":
    unittest.main()
