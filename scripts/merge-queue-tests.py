#!/usr/bin/env python3
"""Synthetic, offline proof for the merge queue; shipped so installed copies prove it too."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import unittest

spec = importlib.util.spec_from_file_location("merge_queue", Path(__file__).with_name("merge-queue.py"))
mq = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mq)
REPO, BASE = "fixture/project", "trunk"


def candidate(number=1, **changes):
    head = str(number) * 40
    result = dict(number=number, head=head, branch="ticket/AA-%s" % number,
                  state="OPEN", draft=False, mergeable="MERGEABLE", ticket="AA-%s" % number,
                  claimed=True, criteria_hash="c" * 64, review_head=head,
                  review_evidence="review:10", unresolved=0, changes_requested=False,
                  acceptance_head=head, acceptance_criteria_hash="c" * 64,
                  acceptance_evidence="criterion 1: fixture assertion", dependencies=[])
    result.update(changes)
    return result


def snapshot(*prs, observed_at=100, base_sha="a" * 40):
    return dict(repository=REPO, base_branch=BASE, base_sha=base_sha,
                observed_at=observed_at, candidates=list(prs))


class QueueTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="merge-queue-test-")
        self.db = Path(self.tmp.name) / "queue.sqlite"
        self.now = 100
        self.q = mq.Store(self.db, clock=lambda: self.now)

    def tearDown(self):
        self.q.close()
        self.tmp.cleanup()

    def populate(self, *prs):
        self.q.observe(snapshot(*prs))
        for pr in prs:
            if pr["state"] == "OPEN":
                self.q.enqueue(REPO, BASE, pr["number"], pr["head"])

    def plan(self):
        return self.q.plan(REPO, BASE)

    def test_three_prs_only_one_candidate_and_restart(self):
        self.populate(candidate(1), candidate(2), candidate(3))
        lease = self.q.claim(REPO, BASE, "worker-a", 60)
        self.assertEqual(lease["number"], 1)
        self.assertIsNone(self.q.claim(REPO, BASE, "worker-b", 60))
        self.q.close()
        self.q = mq.Store(self.db, clock=lambda: self.now)
        self.assertEqual(self.plan()["active"]["token"], lease["token"])
        self.q.observe(snapshot(candidate(1, state="MERGED"), candidate(2), candidate(3), observed_at=101))
        self.assertIsNone(self.plan()["next"])
        self.q.release(REPO, BASE, "worker-a", lease["token"], "verified closed shadow attempt")
        self.assertEqual(self.plan()["next"], 2)

    def test_fifo_is_request_order_not_pr_number(self):
        self.q.observe(snapshot(candidate(1), candidate(2)))
        self.q.enqueue(REPO, BASE, 2, "2" * 40)
        self.q.enqueue(REPO, BASE, 1, "1" * 40)
        self.assertEqual(self.plan()["next"], 2)

    def test_duplicate_observe_enqueue_and_out_of_order(self):
        self.populate(candidate(1))
        first = self.plan()
        self.q.observe(snapshot(candidate(1)))
        self.q.enqueue(REPO, BASE, 1, "1" * 40)
        self.assertEqual(self.plan(), first)
        self.q.observe(snapshot(candidate(1, head="b" * 40), observed_at=99))
        self.assertEqual(self.plan(), first)
        with self.assertRaises(mq.QueueError):
            self.q.observe(snapshot(candidate(1, head="b" * 40)))

    def test_stale_requested_head_is_refused(self):
        self.q.observe(snapshot(candidate(1)))
        with self.assertRaises(mq.QueueError):
            self.q.enqueue(REPO, BASE, 1, "a" * 40)

    def test_every_admission_gate_blocks_independently(self):
        gates = [dict(draft=True), dict(mergeable="UNKNOWN"), dict(mergeable="CONFLICTING"),
                 dict(claimed=False), dict(criteria_hash=None), dict(review_head=None),
                 dict(review_evidence=None), dict(unresolved=1), dict(changes_requested=True),
                 dict(acceptance_head=None), dict(acceptance_evidence=None),
                 dict(acceptance_criteria_hash="d" * 64), dict(ticket=None)]
        self.populate(candidate(1))
        for index, change in enumerate(gates):
            with self.subTest(change=change):
                self.q.observe(snapshot(candidate(1, **change), observed_at=101 + index))
                self.assertIsNone(self.plan()["next"])
                self.assertTrue(self.plan()["candidates"][0]["blockers"])

    def test_head_change_invalidates_review_and_acceptance(self):
        self.populate(candidate(1))
        self.q.observe(snapshot(candidate(1, head="b" * 40), observed_at=101))
        self.assertIsNone(self.plan()["next"])
        self.assertIn("review missing for head", self.plan()["candidates"][0]["blockers"])

    def test_blocked_dependency_waits_for_verified_merge(self):
        self.populate(candidate(1, dependencies=[2]), candidate(2))
        self.assertEqual(self.plan()["next"], 2)
        self.q.observe(snapshot(candidate(1, dependencies=[2]), candidate(2, state="CLOSED"), observed_at=101))
        self.assertIsNone(self.plan()["next"])
        self.q.observe(snapshot(candidate(1, dependencies=[2]), candidate(2, state="MERGED"), observed_at=102))
        self.assertEqual(self.plan()["next"], 1)

    def test_missing_dependency_and_cycle_do_not_pass(self):
        self.populate(candidate(1, dependencies=[2]))
        self.assertIsNone(self.plan()["next"])
        self.q.observe(snapshot(candidate(1, dependencies=[2]), candidate(2, dependencies=[1]), observed_at=101))
        self.q.enqueue(REPO, BASE, 2, "2" * 40)
        self.assertIsNone(self.plan()["next"])

    def test_expired_lease_is_not_stolen(self):
        self.populate(candidate(1), candidate(2))
        lease = self.q.claim(REPO, BASE, "worker-a", 10)
        self.now = 111
        self.assertTrue(self.plan()["active"]["expired"])
        self.assertIsNone(self.q.claim(REPO, BASE, "worker-b", 60))
        with self.assertRaises(mq.QueueError):
            self.q.renew(REPO, BASE, "worker-a", lease["token"], 60)
        self.q.release(REPO, BASE, "worker-a", lease["token"], "reconciled stopped worker")
        newer = self.q.claim(REPO, BASE, "worker-b", 60)
        self.assertGreater(newer["token"], lease["token"])
        with self.assertRaises(mq.QueueError):
            self.q.release(REPO, BASE, "worker-a", lease["token"], "late old worker")

    def test_live_observation_change_fences_worker_but_holds_slot(self):
        for change in ("head", "base", "threads", "criteria"):
            with self.subTest(change=change):
                self.q.observe(snapshot(candidate(1), candidate(2), observed_at=self.now))
                self.q.enqueue(REPO, BASE, 1, "1" * 40)
                lease = self.q.claim(REPO, BASE, "worker", 60)
                self.now += 1
                changed = candidate(1)
                base = "a" * 40
                if change == "head": changed["head"] = "b" * 40
                if change == "base": base = "b" * 40
                if change == "threads": changed["unresolved"] = 1
                if change == "criteria": changed["criteria_hash"] = "d" * 64
                self.q.observe(snapshot(changed, candidate(2), observed_at=self.now, base_sha=base))
                self.assertFalse(self.plan()["active"]["valid"])
                self.assertIsNone(self.plan()["next"])
                with self.assertRaises(mq.QueueError):
                    self.q.renew(REPO, BASE, "worker", lease["token"], 60)
                self.q.release(REPO, BASE, "worker", lease["token"], "reconciled invalid attempt")
                self.now += 1

    def test_stale_scan_and_error_fail_closed(self):
        self.populate(candidate(1))
        self.q.scan_failed(REPO, BASE, 101, "provider unavailable")
        self.assertIsNone(self.plan()["next"])
        self.q.observe(snapshot(candidate(1), observed_at=100.5))
        self.assertIsNone(self.plan()["next"])
        self.q.observe(snapshot(candidate(1), observed_at=102))
        self.assertEqual(self.plan()["next"], 1)
        self.now = 300
        self.assertIsNone(self.plan()["next"])

    def test_base_return_or_provider_recovery_cannot_resurrect_token(self):
        self.populate(candidate(1))
        lease = self.q.claim(REPO, BASE, "worker", 60)
        self.q.observe(snapshot(candidate(1), observed_at=101, base_sha="b" * 40))
        self.q.observe(snapshot(candidate(1), observed_at=102))
        self.assertFalse(self.plan()["active"]["valid"])
        self.q.release(REPO, BASE, "worker", lease["token"], "reconciled old base attempt")
        lease = self.q.claim(REPO, BASE, "worker", 60)
        self.q.scan_failed(REPO, BASE, 103, "provider unavailable")
        self.q.observe(snapshot(candidate(1), observed_at=104))
        self.assertFalse(self.plan()["active"]["valid"])
        with self.assertRaises(mq.QueueError):
            self.q.renew(REPO, BASE, "worker", lease["token"])

    def test_missing_candidate_is_not_inferred_merged(self):
        self.populate(candidate(1), candidate(2, dependencies=[1]))
        self.q.observe(snapshot(candidate(2, dependencies=[1]), observed_at=101))
        self.assertIsNone(self.plan()["next"])

    def test_invalid_snapshot_rolls_back_all_rows(self):
        self.populate(candidate(1))
        bad = candidate(2, unresolved="0")
        with self.assertRaises(mq.QueueError):
            self.q.observe(snapshot(candidate(1, head="b" * 40), bad, observed_at=101))
        self.assertEqual(self.plan()["next"], 1)
        with self.assertRaises(mq.QueueError):
            self.q.observe(snapshot(candidate(1), candidate(1), observed_at=101))

    def test_competing_connections_only_one_claim_wins(self):
        self.populate(candidate(1), candidate(2))
        barrier, leases, errors = threading.Barrier(2), [], []
        def run(owner):
            q = mq.Store(self.db, clock=lambda: 100)
            try:
                barrier.wait(timeout=5)
                leases.append(q.claim(REPO, BASE, owner, 60))
            except Exception as exc:
                errors.append(exc)
            finally:
                q.close()
        workers = [threading.Thread(target=run, args=(owner,)) for owner in ("a", "b")]
        for worker in workers: worker.start()
        for worker in workers: worker.join(timeout=10)
        self.assertFalse(errors)
        self.assertFalse(any(worker.is_alive() for worker in workers))
        self.assertEqual(sum(lease is not None for lease in leases), 1)

    def test_release_needs_owner_and_reason(self):
        self.populate(candidate(1))
        lease = self.q.claim(REPO, BASE, "a", 60)
        for owner, reason in (("b", "done"), ("a", "")):
            with self.assertRaises(mq.QueueError):
                self.q.release(REPO, BASE, owner, lease["token"], reason)
        self.assertTrue(self.plan()["active"])

    def test_audit_events_are_preserved(self):
        self.populate(candidate(1))
        lease = self.q.claim(REPO, BASE, "a", 60)
        self.q.renew(REPO, BASE, "a", lease["token"], 90)
        self.q.release(REPO, BASE, "a", lease["token"], "stopped shadow attempt")
        kinds = [event["kind"] for event in self.q.events(REPO, BASE)]
        self.assertEqual(kinds, ["observed", "enqueued", "claimed", "renewed", "released"])


class GitHubTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="merge-queue-gh-")
        self.root = Path(self.tmp.name)
        # Executable CLI fixture, not a mock that accidentally permits a write command.
        stub = self.root / "gh"
        stub.write_text('''#!/usr/bin/env python3
import json, os, sys
args=sys.argv[1:]
with open(os.environ["MQ_LOG"],"a") as f: f.write(json.dumps(args)+"\\n")
key=json.dumps(args)
fixtures=json.load(open(os.environ["MQ_FIXTURES"]))
if key not in fixtures: sys.exit("unexpected or mutating gh command: "+key)
result=fixtures[key]
if result == "ERROR": sys.exit("synthetic provider failure")
print(json.dumps(result))
''')
        stub.chmod(0o755)
        self.log = self.root / "calls.jsonl"
        self.fixture = self.root / "responses.json"
        self.env = dict(os.environ, PATH=str(self.root) + os.pathsep + os.environ["PATH"],
                        MQ_LOG=str(self.log), MQ_FIXTURES=str(self.fixture))
        self.responses = {}
        self.api = mq.GitHub(self.root, env=self.env)

    def tearDown(self):
        self.tmp.cleanup()

    def rest(self, endpoint, result, pages=False):
        args = ["api", "--method", "GET", endpoint]
        if pages: args += ["--paginate", "--slurp"]
        self.responses[json.dumps(args)] = result

    def flush(self):
        self.fixture.write_text(json.dumps(self.responses))

    def test_rest_pagination_and_mutation_refusal(self):
        self.rest("repos/fixture/project/pulls?state=open&per_page=100", [[{"number": 1}], [{"number": 2}]], True)
        self.flush()
        self.assertEqual(len(self.api.pages("repos/fixture/project/pulls?state=open&per_page=100")), 2)
        with self.assertRaises(mq.QueueError):
            self.api.get("repos/fixture/project/pulls/1/merge")

    def test_review_evidence_requires_completed_exact_bot_head(self):
        head = "a" * 40
        rows = [dict(id=1, user=dict(login=mq.REVIEWER), commit_id=head,
                     state="PENDING", submitted_at=None)]
        self.assertIsNone(mq.review_evidence(rows, head))
        rows[0].update(state="COMMENTED", submitted_at="2026-09-20T10:00:00Z")
        self.assertEqual(mq.review_evidence(rows, head), "review:1")
        self.assertIsNone(mq.review_evidence(rows, "b" * 40))
        rows[0]["user"]["login"] += "-lookalike"
        self.assertIsNone(mq.review_evidence(rows, head))

    def test_changes_request_not_cleared_by_comment(self):
        rows = [dict(user=dict(login="reviewer"), state="CHANGES_REQUESTED"),
                dict(user=dict(login="reviewer"), state="COMMENTED")]
        self.assertTrue(mq.changes_requested(rows))
        rows.append(dict(user=dict(login="reviewer"), state="APPROVED"))
        self.assertFalse(mq.changes_requested(rows))

    def test_unresolved_second_thread_page_and_graphql_errors(self):
        for cursor, resolved, more in ((None, True, True), ("cursor1", False, False)):
            args = mq.thread_args("NODE", cursor)
            self.responses[json.dumps(args)] = {"data": {"node": {"reviewThreads": {
                "nodes": [{"isResolved": resolved}],
                "pageInfo": {"hasNextPage": more, "endCursor": "cursor1" if more else None}}}}}
        self.flush()
        self.assertEqual(self.api.unresolved("NODE"), 1)
        self.responses[json.dumps(mq.thread_args("NODE", None))] = {"errors": [{"message": "denied"}], "data": None}
        self.flush()
        with self.assertRaises(mq.QueueError): self.api.unresolved("NODE")

    def test_full_scan_rechecks_head_and_never_invents_acceptance(self):
        base_endpoint = "repos/fixture/project/commits/trunk"
        self.rest(base_endpoint, {"sha": "a" * 40})
        self.rest("repos/fixture/project/pulls?state=open&base=trunk&per_page=100", [[{"number": 1}]], True)
        pull = dict(number=1, head=dict(sha="1" * 40, ref="ticket/AA-1", repo=dict(full_name=REPO)),
                    base=dict(ref=BASE), draft=False, state="open", merged=False, mergeable=True,
                    node_id="NODE")
        self.rest("repos/fixture/project/pulls/1", pull)
        self.rest("repos/fixture/project/pulls/1/reviews?per_page=100", [[]], True)
        self.responses[json.dumps(mq.thread_args("NODE", None))] = {"data": {"node": {"reviewThreads": {
            "nodes": [], "pageInfo": {"hasNextPage": False, "endCursor": None}}}}}
        self.flush()
        snap = self.api.scan(REPO, BASE, [], lambda _: dict(status="in_progress", assignee="author", acceptance_criteria="proof"))
        self.assertIsNone(snap["candidates"][0]["acceptance_head"])
        self.assertTrue(snap["candidates"][0]["claimed"])
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertEqual(sum("repos/fixture/project/pulls/1" in call for call in calls), 2)
        self.assertTrue(all(call[:3] == ["api", "--method", "GET"] or
                            (call[:2] == ["api", "graphql"] and "mutation" not in " ".join(call)) for call in calls))


if __name__ == "__main__":
    if sys.argv[1:] != ["--self-test"]:
        sys.exit("usage: merge-queue-tests.py --self-test")
    suite = unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__])
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if not result.wasSuccessful(): sys.exit(1)
    print("merge-queue self-test passed")
