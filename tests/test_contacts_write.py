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
    note_of,
    run,
    run_json,
    set_note,
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


class LabelsAndSchemes(LiveContactsTest):
    """The label and value parsing that used to damage data on write.

    All three of these exited 0 while storing something other than the input,
    which is the worst way for an address-book tool to be wrong.
    """

    def urls_of(self, contact_id):
        return [(u.get("label"), u["url"]) for u in self.get(contact_id).get("urls", [])]

    def test_a_bare_url_keeps_its_scheme(self):
        """`https` is a scheme, not a label — cutting on the first colon ate it."""
        created = self.add("Scheme", "--url", "https://www.example.invalid/in/alice")
        self.assertEqual(
            self.urls_of(created["id"]),
            [(None, "https://www.example.invalid/in/alice")])

    def test_schemes_without_slashes_survive_too(self):
        """`mailto:` and `tel:` have no `//` to give them away."""
        created = self.add(
            "Schemeless",
            "--email", "mailto:a@example.invalid",
            "--phone", "tel:+15555550123",
        )
        fetched = self.get(created["id"])
        self.assertEqual(fetched["emails"][0]["address"], "mailto:a@example.invalid")
        self.assertEqual(fetched["phones"][0]["number"], "tel:+15555550123")

    def test_a_label_that_looks_like_a_scheme_still_labels(self):
        """Only `scheme://` and the schemeless list are exempt, not every word."""
        created = self.add("Labelled", "--url", "work:https://example.invalid")
        self.assertEqual(self.urls_of(created["id"]), [("work", "https://example.invalid")])

    def test_custom_labels_are_written_not_dropped(self):
        """`work`/`home`/`other` used to be the only labels that survived."""
        created = self.add(
            "Custom",
            "--url", "url:https://a.example.invalid",
            "--url", "instagram:https://b.example.invalid",
            "--email", "newsletter:c@example.invalid",
            "--phone", "cabin:+15555550124",
        )
        fetched = self.get(created["id"])
        self.assertEqual(
            self.labelled(fetched["urls"], "url"),
            {"url": "https://a.example.invalid", "instagram": "https://b.example.invalid"})
        self.assertEqual(self.labelled(fetched["emails"], "address"),
                         {"newsletter": "c@example.invalid"})
        self.assertEqual(self.labelled(fetched["phones"], "number"),
                         {"cabin": "+15555550124"})

    def test_custom_label_case_is_preserved(self):
        """Contacts stores what the user typed; lowercasing it broke round trips."""
        created = self.add("Case", "--url", "LinkedIn:https://example.invalid/in/x")
        self.assertEqual(self.urls_of(created["id"]),
                         [("LinkedIn", "https://example.invalid/in/x")])

    def test_urls_take_homepage_rather_than_icloud(self):
        """`url()` looked up the *email* table: it had icloud and no homepage."""
        created = self.add("HomePage", "--url", "homepage:https://example.invalid")
        self.assertEqual(self.urls_of(created["id"]), [("homepage", "https://example.invalid")])

    def test_read_then_repass_is_a_no_op(self):
        """The whole class of bug in one assertion.

        The docs tell you to read a contact and re-pass what you want to keep,
        because the multi-value flags replace rather than append. That is only
        safe if re-passing exactly what `get` printed reproduces it.
        """
        created = self.add(
            "RoundTrip",
            "--url", "https://bare.example.invalid",
            "--url", "LinkedIn:https://example.invalid/in/x",
            "--url", "url:https://plain.example.invalid",
            "--email", "work:a@example.invalid",
            "--email", "Personal:b@example.invalid",
            "--email", "mailto:c@example.invalid",
            "--phone", "mobile:+15555550123",
            "--phone", "Cabin:+15555550124",
        )
        before = self.get(created["id"])

        args = []
        for entry in before["emails"]:
            args += ["--email", self.rejoin(entry, "address")]
        for entry in before["phones"]:
            args += ["--phone", self.rejoin(entry, "number")]
        for entry in before["urls"]:
            args += ["--url", self.rejoin(entry, "url")]
        self.edit(created["id"], *args)

        after = self.get(created["id"])
        for key in ("emails", "phones", "urls"):
            self.assertEqual(before[key], after[key], f"{key} did not round-trip")

    def rejoin(self, entry, key):
        """Turn one `get` entry back into the flag value that produced it."""
        label = entry.get("label")
        return f"{label}:{entry[key]}" if label else entry[key]


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


class NoteBearingContacts(GroupFixtures):
    """Writes to a contact that carries a note.

    🛑 A note makes `CNContactStore` refuse *every* save on that contact, not
    just one touching the note: the save faults the record, faulting reads the
    note, and reading it needs an entitlement no CLI can hold. 52 of 669
    contacts on the machine this was found on carry one, so ~8% of a real
    address book was uneditable and un-groupable, with a raw CoreData dump as
    the only explanation.

    Every test here needs Contacts.app automation to plant the note, and skips
    without it — see contacts_harness.set_note.
    """

    NOTE = "regression fixture note"

    def noted(self, last, *extra):
        created = self.add(last, *extra)
        if not set_note(created["id"], self.NOTE):
            self.skipTest(
                "could not set a note through Contacts.app; this suite needs "
                "Automation → Contacts for the terminal running it")
        return created

    def test_an_ordinary_edit_succeeds(self):
        created = self.noted("Noted", "--company", "Before")
        self.edit(created["id"], "--company", "After")
        self.assertEqual(self.get(created["id"])["company"], "After")

    def test_no_raw_coredata_dump_reaches_stderr(self):
        """The fault is handled, so its framework log should not be output."""
        created = self.noted("Quiet")
        _, _, err = run("edit", created["id"], "--company", "Acme")
        self.assertNotIn("CoreData", err)

    def test_every_field_survives_the_fallback(self):
        """The fallback is a different framework, so it needs the full sweep."""
        created = self.noted("Fallback")
        self.edit(
            created["id"],
            "--nickname", "Nick",
            "--job-title", "Principal",
            "--url", "LinkedIn:https://example.invalid/in/x",
            "--url", "https://bare.example.invalid",
            "--email", "work:a@example.invalid",
            "--phone", "cabin:+15555550124",
            "--relation", "father:Robert Test",
            "--birthday=--04-13",
            "--date", "death:2020-05-01",
        )
        fetched = self.get(created["id"])
        self.assertEqual(fetched["nickname"], "Nick")
        self.assertEqual(fetched["job_title"], "Principal")
        # A year-less birthday is why the fallback writes the *Components*
        # property; AddressBook's plain birthday is an NSDate and cannot hold one.
        self.assertEqual(fetched["birthday"], "--04-13")
        self.assertEqual(self.labelled(fetched["dates"], "date"), {"death": "2020-05-01"})
        self.assertEqual(self.labelled(fetched["relations"], "name"), {"father": "Robert Test"})
        self.assertEqual(self.labelled(fetched["emails"], "address"), {"work": "a@example.invalid"})
        self.assertEqual(self.labelled(fetched["phones"], "number"), {"cabin": "+15555550124"})
        self.assertEqual(
            [(u.get("label"), u["url"]) for u in fetched["urls"]],
            [("LinkedIn", "https://example.invalid/in/x"), (None, "https://bare.example.invalid")])

    def test_the_note_is_left_alone(self):
        """The fallback must not become a way to lose the note it works around."""
        created = self.noted("Kept")
        self.edit(created["id"], "--company", "Acme")
        self.assertEqual(note_of(created["id"]), self.NOTE)

    def test_group_membership_works_both_ways(self):
        """`addMember` faults the contact too, so it hit the same wall."""
        group = self.create_group("NoteGroup")
        created = self.noted("Grouped")

        added = run_json("groups", "add", group["id"], created["id"], "--json")
        self.assertTrue(added["member"])
        self.assertTrue(added["changed"])

        removed = run_json("groups", "remove", group["id"], created["id"], "--json")
        self.assertFalse(removed["member"])
        self.assertTrue(removed["changed"])

    def test_link_reaches_a_note_bearing_contact(self):
        """🛑 `link` writes relations through its own path, which had no fallback.

        `edit` and `groups add` both routed around the note wall; `writeRelations`
        did not, so every `link` touching one of the 52 note-bearing contacts here
        failed with a bare `NSCocoaErrorDomain 134092` and wrote **neither** card.
        Found while linking a real family tree, not by a test.
        """
        noted = self.noted("NoteLink")
        plain = self.add("LinkPeer")

        run("link", noted["id"], plain["id"], "--relation", "brother",
            "--inverse", "brother")

        # Both sides, since link writes the note-bearing card first and a
        # failure there used to abandon the second one too.
        self.assertEqual(
            self.labelled(self.get(noted["id"])["relations"], "name"),
            {"brother": plain["name"]})
        self.assertEqual(
            self.labelled(self.get(plain["id"])["relations"], "name"),
            {"brother": noted["name"]})

    def test_unlink_reaches_a_note_bearing_contact(self):
        """The removal goes through the same writer, so it had the same wall."""
        noted = self.noted("NoteUnlink")
        plain = self.add("UnlinkPeer")
        run("link", noted["id"], plain["id"], "--relation", "spouse")

        run("unlink", noted["id"], plain["id"], "--relation", "spouse")

        self.assertEqual(self.get(noted["id"]).get("relations"), None)
        self.assertEqual(self.get(plain["id"]).get("relations"), None)

    def test_linking_leaves_the_note_alone(self):
        """The fallback must not become a way to lose the note it works around."""
        noted = self.noted("NoteLinkKept")
        plain = self.add("LinkKeptPeer")
        run("link", noted["id"], plain["id"], "--relation", "friend")
        self.assertEqual(note_of(noted["id"]), self.NOTE)

    def test_died_reaches_a_note_bearing_contact(self):
        """🛑 This is the NORMAL path for a death, not the exception.

        All four cards recorded as deceased on the store this was built against
        carry a note — an obituary link, or the marker itself. A note blocks
        every `CNContactStore` write to the card, so `--died` reaches the
        AddressBook fallback far more often than it reaches Contacts.
        """
        noted = self.noted("NoteDied")
        self.edit(noted["id"], "--died", "2020-04-30")

        fetched = self.get(noted["id"])
        self.assertTrue(fetched["deceased"])
        self.assertEqual(fetched["died"], "2020-04-30")
        self.assertEqual(fetched["died_precision"], "date")
        self.assertEqual(note_of(noted["id"]), self.NOTE)

    def test_a_year_only_death_survives_the_fallback(self):
        """The fallback writes a different framework's date property.

        A year-only death is the one shape where the stored value and the
        reported value differ, so it has to be checked on both write paths.
        """
        noted = self.noted("NoteDiedYear")
        self.edit(noted["id"], "--died", "2020")

        fetched = self.get(noted["id"])
        self.assertEqual(fetched["died"], "2020")
        self.assertEqual(fetched["died_precision"], "year")
        # The card really does hold a January placeholder; only `died` hides it.
        self.assertEqual(
            self.labelled(fetched["dates"], "date"), {"death-year": "2020-01-01"})

    def test_a_note_bearing_contact_cannot_be_moved_and_says_why(self):
        """The one thing the note wall genuinely blocks rather than routes around.

        `importPeople:intoAccount:createNewUIDs:` copies the note, copying it
        faults it, and Core Data *raises* there rather than returning an error —
        an uncaught NSException that kills the process mid-import, which is how a
        contact ends up existing twice. So a note is checked for first and the
        move refused before anything is written.
        """
        containers = run_json("containers", "--json")
        others = [c for c in containers if not c["default"]]
        if not others:
            self.skipTest("only one container on this machine")

        created = self.noted("NoteMove")
        before = self.get(created["id"])["container"]

        code, out, err = run("move", created["id"], "--to", others[0]["id"], check=False)
        self.assertNotEqual(code, 0, "a note-bearing contact must not move")
        self.assertIn("note", err)
        self.assertIn("Contacts.app", err)
        # A runtime refusal, not an argument error: no usage block, exit 1.
        self.assertNotIn("Usage:", err + out)
        self.assertEqual(code, 1)

        # Nothing was written, and the note is still there.
        self.assertEqual(self.get(created["id"])["container"], before)
        self.assertEqual(note_of(created["id"]), self.NOTE)


class MoveBetweenContainers(GroupFixtures):
    """Moving a contact between accounts, which the public API cannot do.

    🛑 `CNSaveRequest` has no move: a contact's container is fixed at
    `add(_:toContainerWithIdentifier:)` and `update(_:)` cannot change it. The
    obvious workaround — copy into the target, delete the original — mints a
    **new identifier**, breaking every stored reference, and drops the note. So
    this goes through the legacy AddressBook framework's
    `importPeople:intoAccount:createNewUIDs:` with `createNewUIDs: false`, which
    keeps the id, followed by an account-scoped removal of the original.

    The identifier surviving is the assertion that matters; without it this
    would be `add` + `delete` wearing the word "move".
    """

    def containers(self):
        return run_json("containers", "--json")

    def two_containers(self):
        """(default, other) or skip — a move needs somewhere to go."""
        containers = self.containers()
        default = [c for c in containers if c["default"]]
        others = [c for c in containers if not c["default"]]
        if not default or not others:
            self.skipTest("need two containers to test a move")
        return default[0], others[0]

    def test_the_identifier_survives_the_move(self):
        source, target = self.two_containers()
        created = self.add("Ident")
        self.assertEqual(created["container"], source["id"])

        result = run_json("move", created["id"], "--to", target["id"], "--json")
        self.assertTrue(result["moved"])
        self.assertTrue(result["changed"])
        self.assertEqual(
            result["contact_id"], created["id"],
            "a move that renames the contact is a copy, not a move")

        fetched = self.get(created["id"])
        self.assertEqual(fetched["container"], target["id"])
        self.assertEqual(fetched["id"], created["id"])

    def test_every_field_survives_the_move(self):
        """A different framework carries the record across, so sweep the lot."""
        source, target = self.two_containers()
        created = self.add(
            "Fields",
            "--company", "Acme", "--job-title", "Engineer", "--nickname", "Nick",
            "--email", "work:move@example.invalid",
            "--phone", "mobile:+15555550199",
            "--url", "LinkedIn:https://example.invalid/in/x",
            "--relation", "father:Robert Test",
            "--birthday", "1980-04-12")
        self.assertEqual(created["container"], source["id"])

        run("move", created["id"], "--to", target["id"], "--json")
        fetched = self.get(created["id"])

        self.assertEqual(fetched["container"], target["id"])
        self.assertEqual(fetched["company"], "Acme")
        self.assertEqual(fetched["job_title"], "Engineer")
        self.assertEqual(fetched["nickname"], "Nick")
        self.assertEqual(fetched["birthday"], "1980-04-12")
        self.assertEqual(
            self.labelled(fetched["emails"], "address"), {"work": "move@example.invalid"})
        self.assertEqual(
            self.labelled(fetched["phones"], "number"), {"mobile": "+15555550199"})
        self.assertEqual(
            self.labelled(fetched["urls"], "url"), {"LinkedIn": "https://example.invalid/in/x"})
        self.assertEqual(
            self.labelled(fetched["relations"], "name"), {"father": "Robert Test"})

    def test_dry_run_writes_nothing(self):
        source, target = self.two_containers()
        created = self.add("Dry")

        result = run_json("move", created["id"], "--to", target["id"], "--dry-run", "--json")
        self.assertTrue(result["dry_run"])
        self.assertFalse(result["moved"])
        self.assertFalse(result["changed"])
        self.assertEqual(result["from"], source["id"])
        self.assertEqual(result["to"], target["id"])

        self.assertEqual(
            self.get(created["id"])["container"], source["id"],
            "--dry-run must not move anything")

    def test_it_reports_the_groups_the_move_will_empty(self):
        """The one real cost, surfaced before the write rather than discovered.

        A group belongs to one account, so moving a contact drops it out of
        every group in the account it left. Silently emptying a group is exactly
        the kind of quiet damage this tool refuses to do.
        """
        source, target = self.two_containers()
        group = self.create_group("MoveLeaves")  # default container = source
        contact = self.add("Leaver")
        run("groups", "add", group["id"], contact["id"])

        planned = run_json(
            "move", contact["id"], "--to", target["id"], "--dry-run", "--json")
        self.assertIn(group["name"], planned["groups_left"])

        result = run_json("move", contact["id"], "--to", target["id"], "--json")
        self.assertIn(group["name"], result["groups_left"])
        self.assertEqual(
            run_json("groups", "members", group["id"]), [],
            "the move really does empty the contact out of its old group")

    def test_moving_where_it_already_is_is_a_reported_no_op(self):
        source, _ = self.two_containers()
        created = self.add("Already")

        result = run_json("move", created["id"], "--to", source["id"], "--json")
        self.assertTrue(result["moved"], "it is in the requested account")
        self.assertFalse(result["changed"], "but this call did not put it there")
        self.assertEqual(self.get(created["id"])["container"], source["id"])

    def test_an_unknown_destination_is_rejected_and_names_the_valid_ones(self):
        source, _ = self.two_containers()
        created = self.add("BadTarget")

        code, _, err = run(
            "move", created["id"], "--to", "___no_such_container___", check=False)
        self.assertNotEqual(code, 0)
        self.assertIn("no container", err)
        for entry in self.containers():
            self.assertIn(entry["id"], err)
        self.assertEqual(self.get(created["id"])["container"], source["id"])

    def test_a_move_unblocks_a_cross_account_group_add(self):
        """The reason this command exists.

        A contact in the wrong account cannot join a group, `CNSaveRequest`
        cannot span two containers, and there was previously no way out of that
        from the CLI at all.
        """
        source, target = self.two_containers()
        group = self.create_group("Destination")  # default container = source
        contact = run_json(
            "add", "--first", TEST_PREFIX, "--last", "Stranded",
            "--container", target["id"], "--json")

        code, _, err = run("groups", "add", group["id"], contact["id"], check=False)
        self.assertNotEqual(code, 0)
        self.assertIn("different accounts", err)
        # The refusal must name the command that fixes it, or it is still a
        # dead end for whoever reads it.
        self.assertIn("apple contacts move", err)

        run("move", contact["id"], "--to", source["id"], "--json")
        added = run_json("groups", "add", group["id"], contact["id"], "--json")
        self.assertTrue(added["member"])
        self.assertTrue(added["changed"])
        self.assertIn(
            contact["id"], [m["id"] for m in run_json("groups", "members", group["id"])])


if __name__ == "__main__":
    unittest.main()


class DeathDates(GroupFixtures):
    """`--died`, on a card with no note, so `CNContactStore` handles it.

    🛑 The rule every test here defends: **`died` reports what is KNOWN, never
    what is stored.** Contacts refuses a date with no month or day (measured:
    `CNErrorDomain 302`, key paths `dates.value.month` and `dates.value.day`), so
    a year-only death has to occupy a real day it never had. The card holds
    `2020-01-01`; the answer must say `2020`.
    """

    def test_a_full_date(self):
        created = self.add("Died")
        self.edit(created["id"], "--died", "2020-04-30")
        fetched = self.get(created["id"])
        self.assertTrue(fetched["deceased"])
        self.assertEqual(fetched["died"], "2020-04-30")
        self.assertEqual(fetched["died_precision"], "date")
        self.assertEqual(self.labelled(fetched["dates"], "date"), {"death": "2020-04-30"})

    def test_a_year_only_death_never_leaks_its_placeholder(self):
        created = self.add("DiedYear")
        self.edit(created["id"], "--died", "2020")
        fetched = self.get(created["id"])
        self.assertEqual(fetched["died"], "2020")
        self.assertEqual(fetched["died_precision"], "year")
        self.assertNotEqual(fetched["died"], "2020-01-01")
        # The placeholder is visible in the raw dates, and declared by the label.
        self.assertEqual(
            self.labelled(fetched["dates"], "date"), {"death-year": "2020-01-01"})

    def test_a_year_with_no_known_day(self):
        created = self.add("DiedNoYear")
        # ⚠️ `--MM-DD` needs `=`. Without it ArgumentParser reads the value as
        # the next flag and reports a missing value — the same trap `--birthday`
        # and `--anniversary` have.
        self.edit(created["id"], "--died=--04-30")
        fetched = self.get(created["id"])
        self.assertEqual(fetched["died"], "--04-30")
        self.assertEqual(fetched["died_precision"], "day-only")
        # Nothing is invented here, so nothing needs declaring in the label.
        self.assertEqual(self.labelled(fetched["dates"], "date"), {"death": "--04-30"})

    def test_died_merges_and_does_not_replace_other_dates(self):
        """🛑 `--date` replaces the whole set; `--died` must not.

        Getting a death onto a card with `--date` alone means re-passing every
        other date it holds, and forgetting one deletes it silently. That trap is
        the whole reason `--died` is its own flag.
        """
        created = self.add("DiedMerge", "--date", "anniversary:1999-06-15")
        self.edit(created["id"], "--died", "2020-04-30")
        self.assertEqual(
            self.labelled(self.get(created["id"])["dates"], "date"),
            {"anniversary": "1999-06-15", "death": "2020-04-30"})

    def test_changing_the_precision_replaces_rather_than_stacks(self):
        """A card must never end up with both a `death` and a `death-year`."""
        created = self.add("DiedRestate")
        self.edit(created["id"], "--died", "2020-04-30")
        self.edit(created["id"], "--died", "2020")
        fetched = self.get(created["id"])
        self.assertEqual(len(fetched["dates"]), 1, "the old death date was left behind")
        self.assertEqual(fetched["died"], "2020")

        self.edit(created["id"], "--died", "2020-04-30")
        fetched = self.get(created["id"])
        self.assertEqual(len(fetched["dates"]), 1)
        self.assertEqual(fetched["died"], "2020-04-30")

    def test_a_living_contact_reports_no_death_keys_at_all(self):
        """Absent, never false — the rule every optional key here follows."""
        fetched = self.get(self.add("Living")["id"])
        self.assertIsNone(fetched.get("deceased"))
        self.assertIsNone(fetched.get("died"))
        self.assertIsNone(fetched.get("died_precision"))

    def test_died_is_settable_at_creation(self):
        created = self.add("DiedAtBirth", "--died", "2020")
        self.assertEqual(created["died"], "2020")
        self.assertEqual(created["died_precision"], "year")

    def test_a_partial_date_is_refused_before_any_apple_event(self):
        """🛑 `2020-04` is refused, not padded.

        Contacts rejects it outright, and inventing a day would record a month as
        though it were exact — with no label left to disclose it.
        """
        created = self.add("DiedPartial")
        code, out, err = run("edit", created["id"], "--died", "2020-04", check=False)
        self.assertNotEqual(code, 0)
        self.assertIn("day", err)
        self.assertIn("2020", err, "the refusal must offer the year as the way out")
        self.assertIsNone(self.get(created["id"]).get("deceased"))

    def test_garbage_is_refused(self):
        created = self.add("DiedGarbage")
        for bad in ["yesterday", "20-4-30", "2020-13-01", "2020-04-32"]:
            code, _, err = run("edit", created["id"], "--died", bad, check=False)
            self.assertNotEqual(code, 0, f"'{bad}' should be refused")
            self.assertIn("YYYY-MM-DD", err)
        self.assertIsNone(self.get(created["id"]).get("deceased"))

    def test_the_deceased_listing_finds_a_fixture(self):
        created = self.add("DiedListed")
        self.edit(created["id"], "--died", "2020")
        report = run_json("deceased", "--json")
        mine = [e for e in report["deceased"] if e["id"] == created["id"]]
        self.assertEqual(len(mine), 1)
        self.assertEqual(mine[0]["died"], "2020")
        self.assertEqual(mine[0]["died_precision"], "year")
        # ⚠️ Always present, `[]` when empty — never omitted.
        self.assertIsInstance(report["marked_without_date"], list)

    def test_get_edit_get_is_a_no_op_for_a_year_only_death(self):
        """The documented read-then-re-pass workflow, on the one lossy shape."""
        created = self.add("DiedRoundTrip")
        self.edit(created["id"], "--died", "2020")
        before = self.get(created["id"])["dates"]
        self.edit(created["id"], "--date", "death-year:2020-01-01")
        self.assertEqual(self.get(created["id"])["dates"], before)


class NameOnlyRelations(GroupFixtures):
    """A relation naming somebody who has no contact card.

    🛑 **A relation stores a NAME, not a reference**, so a card can legitimately
    name somebody with no card of their own — a spouse who died before the
    address book existed, a relative nobody has details for. Two such relations
    already existed on the store this was built against, and they are not
    corruption.

    Before `--name-only` the only route was `edit --relation`, which replaces
    the whole set: adding one meant re-passing every existing relation, and
    forgetting one deleted it silently. That is the exact trap `link` exists to
    close, and it stayed open for this one case.
    """

    GHOST = "Nobody McGhost"

    def test_a_name_only_relation_is_written(self):
        created = self.add("NameOnly")
        run("link", created["id"], self.GHOST, "--relation", "father", "--name-only")
        self.assertEqual(
            self.labelled(self.get(created["id"])["relations"], "name"),
            {"father": self.GHOST})

    def test_it_is_one_sided_and_says_so(self):
        """No card exists to carry an inverse, and the output must not imply one."""
        created = self.add("NameOnlySide")
        _, out, _ = run("link", created["id"], self.GHOST,
                        "--relation", "father", "--name-only")
        self.assertIn("no contact is named", out)
        self.assertEqual(out.count("added"), 1, "only one card can change")

    def test_inverse_is_refused(self):
        created = self.add("NameOnlyInverse")
        code, _, err = run("link", created["id"], self.GHOST, "--relation", "father",
                           "--name-only", "--inverse", "child", check=False)
        self.assertNotEqual(code, 0)
        self.assertIn("--inverse", err)
        self.assertIsNone(self.get(created["id"]).get("relations"))

    def test_other_relations_survive(self):
        """🛑 The whole reason this is not `edit --relation`, which replaces."""
        created = self.add("NameOnlyMerge")
        peer = self.add("NameOnlyPeer")
        run("link", created["id"], peer["id"], "--relation", "brother",
            "--inverse", "brother")
        run("link", created["id"], self.GHOST, "--relation", "father", "--name-only")
        self.assertEqual(
            self.labelled(self.get(created["id"])["relations"], "name"),
            {"brother": peer["name"], "father": self.GHOST})

    def test_relinking_is_a_reported_no_op(self):
        created = self.add("NameOnlyRepeat")
        run("link", created["id"], self.GHOST, "--relation", "father", "--name-only")
        _, out, _ = run("link", created["id"], self.GHOST,
                        "--relation", "father", "--name-only")
        self.assertIn("already had", out)
        self.assertEqual(len(self.get(created["id"])["relations"]), 1)

    def test_dry_run_writes_nothing(self):
        created = self.add("NameOnlyDry")
        _, out, _ = run("link", created["id"], self.GHOST,
                        "--relation", "father", "--name-only", "--dry-run")
        self.assertIn("would add", out)
        self.assertIsNone(self.get(created["id"]).get("relations"))

    def test_unlink_removes_it_again(self):
        created = self.add("NameOnlyUnlink")
        run("link", created["id"], self.GHOST, "--relation", "father", "--name-only")
        run("unlink", created["id"], self.GHOST, "--name-only")
        self.assertIsNone(self.get(created["id"]).get("relations"))

    def test_unlinking_something_absent_is_an_error(self):
        created = self.add("NameOnlyMissing")
        code, _, err = run("unlink", created["id"], "Not There", "--name-only",
                           check=False)
        self.assertNotEqual(code, 0)
        self.assertIn("no relation naming", err)

    def test_without_the_flag_an_unknown_name_is_still_refused(self):
        """🛑 The flag is opt-in, and that is the point.

        Falling back to a plain name whenever the second argument failed to
        resolve would turn a typo in a real contact's name into a dangling
        relation, silently — the opposite of the rule every other name lookup
        here follows.
        """
        created = self.add("NameOnlyStrict")
        code, _, err = run("link", created["id"], self.GHOST,
                           "--relation", "father", check=False)
        self.assertNotEqual(code, 0)
        self.assertIn("no contact matches", err)
        self.assertIsNone(self.get(created["id"]).get("relations"))


class ClearDates(GroupFixtures):
    """`--clear-dates`, which had no equivalent at all.

    `--date` replaces the set but cannot empty it, so a labelled date written by
    mistake could never be removed by this tool. Found on a real card carrying an
    `anniversary` that was actually the person's birth date.
    """

    def test_it_removes_every_labelled_date(self):
        created = self.add("ClearDates",
                           "--date", "anniversary:1977-09-17",
                           "--date", "graduation:1999-06-15")
        self.assertEqual(len(created["dates"]), 2)
        self.edit(created["id"], "--clear-dates")
        self.assertIsNone(self.get(created["id"]).get("dates"))

    def test_the_birthday_is_a_separate_field_and_survives(self):
        created = self.add("ClearKeepBirthday", "--birthday", "1977-09-17",
                           "--date", "anniversary:2001-01-01")
        self.edit(created["id"], "--clear-dates")
        fetched = self.get(created["id"])
        self.assertEqual(fetched["birthday"], "1977-09-17")
        self.assertIsNone(fetched.get("dates"))

    def test_it_combines_with_died(self):
        """Clear the dates and record the death means only one thing."""
        created = self.add("ClearThenDied", "--date", "anniversary:2001-01-01")
        self.edit(created["id"], "--clear-dates", "--died", "2020")
        fetched = self.get(created["id"])
        self.assertEqual(fetched["died"], "2020")
        self.assertEqual(self.labelled(fetched["dates"], "date"),
                         {"death-year": "2020-01-01"})

    def test_it_is_refused_alongside_date(self):
        """⚠️ Ambiguous, so refused rather than resolved one way."""
        created = self.add("ClearConflict", "--date", "anniversary:2001-01-01")
        code, _, err = run("edit", created["id"], "--clear-dates",
                           "--date", "death:2020-01-01", check=False)
        self.assertNotEqual(code, 0)
        self.assertIn("--clear-dates", err)
        # Nothing was touched.
        self.assertEqual(len(self.get(created["id"])["dates"]), 1)
