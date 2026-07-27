"""Live write-path tests for apple-contacts.

Covers the surface that had never been exercised against real data: relations,
the two native date models plus arbitrary labelled dates, multi-value replace
semantics, and group membership.

Every fixture is created with TEST_PREFIX as its first name and swept after
each test. See contacts_harness for the safety rules.
"""

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


class Groups(LiveContactsTest):
    def group_name(self, suffix):
        return f"{TEST_PREFIX} {suffix}"

    def create_group(self, suffix):
        run("groups", "create", self.group_name(suffix), check=True)
        matches = [g for g in find_test_groups()
                   if g["name"] == self.group_name(suffix)]
        self.assertEqual(len(matches), 1, f"group {suffix!r} not created")
        return matches[0]

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

    def test_get_reports_group_membership(self):
        group = self.create_group("Reported")
        contact = self.add("Reportee")
        run("groups", "add", group["id"], contact["id"])
        fetched = self.get(contact["id"])
        # `groups` is a list of names; Contacts has no reverse lookup, so only
        # `get` populates it.
        self.assertIn(self.group_name("Reported"), fetched.get("groups", []))


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
