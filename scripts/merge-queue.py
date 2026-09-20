#!/usr/bin/env python3
"""Durable shadow queue. No code path rebases, dispatches CI, posts a check, or merges.

The observation and lease APIs are the foundation for later trusted worker adapters.
Imported observations are simulation data, never an authorization to act on GitHub.
Python 3.9+; standard library only; SQLite state stays outside the checkout.
"""
import argparse
from contextlib import contextmanager
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import time
from urllib.parse import quote

REVIEWER = "chatgpt-codex-connector[bot]"
SCHEMA = 1


class QueueError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise QueueError(message)


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)


def digest(value):
    return hashlib.sha256(encoded(value).encode()).hexdigest()


def sha(value):
    return isinstance(value, str) and re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", value)


def integer(value):
    return type(value) is int and value > 0


def identity(repo, base):
    require(isinstance(repo, str) and re.fullmatch(r"[\w.-]+/[\w.-]+", repo), "repository must be owner/name")
    require(isinstance(base, str) and base and not any(ord(c) < 32 for c in base), "base branch is required")


def validate_snapshot(value):
    try:
        identity(value["repository"], value["base_branch"])
        require(sha(value["base_sha"]), "snapshot needs a full base SHA")
        observed = value["observed_at"]
        require(type(observed) in (int, float) and math.isfinite(observed) and observed > 0,
                "observed_at must be a finite positive Unix timestamp")
        require(isinstance(value["candidates"], list), "candidates must be a complete list")
        numbers = set()
        for p in value["candidates"]:
            require(integer(p["number"]) and p["number"] not in numbers, "duplicate or invalid PR number")
            numbers.add(p["number"])
            require(sha(p["head"]), "candidate needs a full head SHA")
            require(p["state"] in ("OPEN", "CLOSED", "MERGED", "UNKNOWN"), "unknown PR state")
            require(p["mergeable"] in ("MERGEABLE", "CONFLICTING", "UNKNOWN"), "unknown mergeability")
            for name in ("draft", "claimed", "changes_requested"):
                require(type(p[name]) is bool, name + " must be a boolean")
            require(type(p["unresolved"]) is int and p["unresolved"] >= 0, "unresolved must be a nonnegative integer")
            require(isinstance(p["branch"], str) and p["branch"], "branch is required")
            require(p["ticket"] is None or (isinstance(p["ticket"], str) and
                    re.fullmatch(r"[A-Z][A-Z0-9]*-[a-z0-9]+", p["ticket"])), "invalid ticket")
            for name in ("criteria_hash", "acceptance_criteria_hash"):
                require(p[name] is None or (isinstance(p[name], str) and
                        re.fullmatch(r"[0-9a-f]{64}", p[name])), name + " must be a SHA256 hash or null")
            for name in ("review_head", "acceptance_head"):
                require(p[name] is None or sha(p[name]), name + " must be a full SHA or null")
            for name in ("review_evidence", "acceptance_evidence"):
                require(p[name] is None or (isinstance(p[name], str) and p[name].strip()), name + " must be evidence or null")
            require(isinstance(p["dependencies"], list) and all(integer(n) and n != p["number"]
                    for n in p["dependencies"]), "dependencies must name other PR numbers")
        # Reject unserializable extras before starting any transaction.
        encoded(value)
    except (KeyError, TypeError, ValueError) as exc:
        raise QueueError("invalid observation: " + str(exc)) from exc


class Store:
    def __init__(self, path, clock=time.time):
        self.clock = clock
        path = Path(path).expanduser()
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        # This is always a shadow journal. Never silently open a future live controller DB.
        self.db = sqlite3.connect(str(path), timeout=30, isolation_level=None)
        os.chmod(path, 0o600)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA foreign_keys=ON")
        self.db.execute("PRAGMA busy_timeout=30000")
        with self.transaction():
            self.db.execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            version = self.db.execute("SELECT value FROM metadata WHERE key='schema'").fetchone()
            require(version is None or version[0] == str(SCHEMA), "unsupported queue schema")
            mode = self.db.execute("SELECT value FROM metadata WHERE key='mode'").fetchone()
            require(mode is None or mode[0] == "shadow", "refusing a non-shadow database")
            self.db.execute("INSERT OR IGNORE INTO metadata VALUES ('schema', ?)", (str(SCHEMA),))
            self.db.execute("INSERT OR IGNORE INTO metadata VALUES ('mode', 'shadow')")
            for sql in (
                """CREATE TABLE IF NOT EXISTS sources (
                    repo TEXT, base TEXT, observed REAL NOT NULL, base_sha TEXT,
                    fingerprint TEXT, error TEXT, PRIMARY KEY(repo, base))""",
                """CREATE TABLE IF NOT EXISTS candidates (
                    repo TEXT, base TEXT, number INTEGER, data TEXT NOT NULL,
                    revision INTEGER NOT NULL, PRIMARY KEY(repo, base, number))""",
                """CREATE TABLE IF NOT EXISTS requests (
                    position INTEGER PRIMARY KEY AUTOINCREMENT, repo TEXT, base TEXT,
                    number INTEGER, UNIQUE(repo, base, number))""",
                """CREATE TABLE IF NOT EXISTS attempts (
                    token INTEGER PRIMARY KEY AUTOINCREMENT, repo TEXT, base TEXT,
                    number INTEGER, revision INTEGER, head TEXT, base_sha TEXT,
                    owner TEXT, expires REAL, released INTEGER NOT NULL DEFAULT 0,
                    invalidated INTEGER NOT NULL DEFAULT 0)""",
                "CREATE UNIQUE INDEX IF NOT EXISTS one_active ON attempts(repo,base) WHERE released=0",
                """CREATE TABLE IF NOT EXISTS events (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT, repo TEXT, base TEXT,
                    at REAL, kind TEXT, details TEXT)""",
            ):
                self.db.execute(sql)

    @contextmanager
    def transaction(self):
        self.db.execute("BEGIN IMMEDIATE")
        try:
            yield
            self.db.execute("COMMIT")
        except BaseException:
            self.db.execute("ROLLBACK")
            raise

    def close(self):
        self.db.close()

    def event(self, repo, base, kind, details):
        self.db.execute("INSERT INTO events(repo,base,at,kind,details) VALUES (?,?,?,?,?)",
                        (repo, base, self.clock(), kind, encoded(details)))

    def events(self, repo, base):
        return [dict(row, details=json.loads(row["details"])) for row in self.db.execute(
            "SELECT * FROM events WHERE repo=? AND base=? ORDER BY sequence", (repo, base))]

    def observe(self, value):
        validate_snapshot(value)
        repo, base, stamp = value["repository"], value["base_branch"], value["observed_at"]
        content = dict(value)
        del content["observed_at"]
        content["candidates"] = sorted(value["candidates"], key=lambda p: p["number"])
        fingerprint = digest(content)
        with self.transaction():
            old = self.db.execute("SELECT * FROM sources WHERE repo=? AND base=?", (repo, base)).fetchone()
            if old and stamp < old["observed"]:
                return False
            if old and stamp == old["observed"]:
                require(old["fingerprint"] == fingerprint and old["error"] is None,
                        "conflicting observations at the same timestamp")
                return False
            rows = {row["number"]: row for row in self.db.execute(
                "SELECT * FROM candidates WHERE repo=? AND base=?", (repo, base))}
            incoming = {p["number"]: p for p in value["candidates"]}
            # Absence is unknown, never a fabricated merge. Live scan explicitly reads tracked PRs.
            for number, row in rows.items():
                if number not in incoming:
                    incoming[number] = dict(json.loads(row["data"]), state="UNKNOWN")
            for number, p in incoming.items():
                data = encoded(p)
                if number not in rows:
                    self.db.execute("INSERT INTO candidates VALUES (?,?,?,?,1)", (repo, base, number, data))
                elif rows[number]["data"] != data:
                    self.db.execute("UPDATE candidates SET data=?, revision=revision+1 WHERE repo=? AND base=? AND number=?",
                                    (data, repo, base, number))
            self.db.execute("INSERT OR REPLACE INTO sources VALUES (?,?,?,?,?,NULL)",
                            (repo, base, stamp, value["base_sha"], fingerprint))
            # Invalidation is sticky: a base moving away and back cannot resurrect an old
            # worker's authority. Reconciliation and a new token are required.
            self.db.execute("""UPDATE attempts SET invalidated=1 WHERE repo=? AND base=? AND released=0
                AND (base_sha != ? OR revision != (SELECT revision FROM candidates c
                     WHERE c.repo=attempts.repo AND c.base=attempts.base AND c.number=attempts.number))""",
                            (repo, base, value["base_sha"]))
            if not old or old["fingerprint"] != fingerprint or old["error"]:
                self.event(repo, base, "observed", {"base_sha": value["base_sha"], "count": len(incoming)})
        return True

    def scan_failed(self, repo, base, observed, reason):
        identity(repo, base)
        with self.transaction():
            old = self.db.execute("SELECT * FROM sources WHERE repo=? AND base=?", (repo, base)).fetchone()
            if old and observed < old["observed"]:
                return
            self.db.execute("INSERT OR REPLACE INTO sources VALUES (?,?,?,?,?,?)",
                            (repo, base, observed, old["base_sha"] if old else None, None, reason))
            self.db.execute("UPDATE attempts SET invalidated=1 WHERE repo=? AND base=? AND released=0", (repo, base))
            self.event(repo, base, "scan_failed", {"reason": reason})

    def tracked(self, repo, base):
        return [r[0] for r in self.db.execute("SELECT number FROM candidates WHERE repo=? AND base=?", (repo, base))]

    def enqueue(self, repo, base, number, head):
        identity(repo, base)
        require(integer(number) and sha(head), "enqueue needs PR number and full expected head")
        with self.transaction():
            row = self.db.execute("SELECT data FROM candidates WHERE repo=? AND base=? AND number=?", (repo, base, number)).fetchone()
            require(row is not None, "PR must be observed before enqueue")
            p = json.loads(row["data"])
            require(p["state"] == "OPEN" and p["head"] == head, "enqueue head is stale or PR is not open")
            cursor = self.db.execute("INSERT OR IGNORE INTO requests(repo,base,number) VALUES (?,?,?)", (repo, base, number))
            if cursor.rowcount:
                self.event(repo, base, "enqueued", {"number": number, "head": head})

    def _plan(self, repo, base, max_age):
        require(type(max_age) in (float, int) and math.isfinite(max_age) and max_age > 0, "max_age must be positive")
        source = self.db.execute("SELECT * FROM sources WHERE repo=? AND base=?", (repo, base)).fetchone()
        problem = None
        if not source: problem = "not observed"
        elif source["error"]: problem = "scan failed: " + source["error"]
        elif self.clock() - source["observed"] > max_age: problem = "observation expired"
        elif source["observed"] - self.clock() > 30: problem = "observation clock is ahead"
        rows = list(self.db.execute("""SELECT c.*, r.position FROM candidates c LEFT JOIN requests r
                     ON c.repo=r.repo AND c.base=r.base AND c.number=r.number
                     WHERE c.repo=? AND c.base=? ORDER BY r.position IS NULL, r.position, c.number""", (repo, base)))
        states = {r["number"]: json.loads(r["data"])["state"] for r in rows}
        candidates = []
        for row in rows:
            p = json.loads(row["data"])
            blockers = []
            if problem: blockers.append(problem)
            if row["position"] is None: blockers.append("not enqueued")
            if p["state"] != "OPEN": blockers.append("PR is " + p["state"].lower())
            if p["draft"]: blockers.append("draft")
            if p["mergeable"] != "MERGEABLE": blockers.append("mergeability " + p["mergeable"].lower())
            if not p["ticket"] or p["branch"] != "ticket/" + p["ticket"]: blockers.append("ticket branch mismatch")
            if not p["claimed"]: blockers.append("ticket unclaimed or unavailable")
            if not p["criteria_hash"]: blockers.append("acceptance criteria unavailable")
            if p["review_head"] != p["head"] or not p["review_evidence"]: blockers.append("review missing for head")
            if p["unresolved"]: blockers.append("unresolved review threads")
            if p["changes_requested"]: blockers.append("changes requested")
            if (p["acceptance_head"] != p["head"] or not p["acceptance_evidence"] or
                    not p["criteria_hash"] or p["acceptance_criteria_hash"] != p["criteria_hash"]):
                blockers.append("acceptance missing for head or criteria")
            for dep in p["dependencies"]:
                if states.get(dep) != "MERGED": blockers.append("dependency #%s has not merged" % dep)
            candidates.append(dict(number=p["number"], head=p["head"], state=p["state"],
                                   revision=row["revision"], position=row["position"], blockers=blockers))
        lease = self.db.execute("SELECT * FROM attempts WHERE repo=? AND base=? AND released=0", (repo, base)).fetchone()
        active = None
        if lease:
            active = dict(lease)
            candidate = next((p for p in candidates if p["number"] == active["number"]), None)
            active["expired"] = self.clock() >= active["expires"]
            active["valid"] = bool(candidate and not candidate["blockers"] and
                                   candidate["revision"] == active["revision"] and source and
                                   source["base_sha"] == active["base_sha"] and not active["expired"] and
                                   not active["invalidated"])
        ready = next((p["number"] for p in candidates if not p["blockers"]), None)
        return dict(mode="shadow", repository=repo, base_branch=base,
                    base_sha=source["base_sha"] if source else None, source_problem=problem,
                    candidates=candidates, active=active, next=None if active else ready)

    def plan(self, repo, base, max_age=120):
        identity(repo, base)
        with self.transaction():
            return self._plan(repo, base, max_age)

    def claim(self, repo, base, owner, ttl=60):
        require(isinstance(owner, str) and owner.strip(), "worker owner is required")
        require(type(ttl) in (int, float) and math.isfinite(ttl) and ttl > 0, "positive lease TTL required")
        with self.transaction():
            plan = self._plan(repo, base, 120)
            if plan["next"] is None: return None
            p = next(p for p in plan["candidates"] if p["number"] == plan["next"])
            cursor = self.db.execute("""INSERT INTO attempts(repo,base,number,revision,head,base_sha,owner,expires)
                                      VALUES (?,?,?,?,?,?,?,?)""",
                                     (repo, base, p["number"], p["revision"], p["head"], plan["base_sha"], owner, self.clock() + ttl))
            self.event(repo, base, "claimed", {"number": p["number"], "token": cursor.lastrowid, "owner": owner})
            return dict(self.db.execute("SELECT * FROM attempts WHERE token=?", (cursor.lastrowid,)).fetchone())

    def _owned(self, repo, base, owner, token):
        lease = self.db.execute("SELECT * FROM attempts WHERE repo=? AND base=? AND token=? AND released=0",
                                (repo, base, token)).fetchone()
        require(lease is not None and lease["owner"] == owner, "stale token or wrong worker")
        return lease

    def renew(self, repo, base, owner, token, ttl=60):
        require(type(ttl) in (int, float) and math.isfinite(ttl) and ttl > 0, "positive lease TTL required")
        with self.transaction():
            self._owned(repo, base, owner, token)
            require(self._plan(repo, base, 120)["active"]["valid"], "attempt invalidated or expired; reconcile before release")
            self.db.execute("UPDATE attempts SET expires=? WHERE token=?", (self.clock() + ttl, token))
            self.event(repo, base, "renewed", {"token": token, "owner": owner})

    def release(self, repo, base, owner, token, reason):
        require(isinstance(reason, str) and reason.strip(), "reconciliation reason required")
        with self.transaction():
            self._owned(repo, base, owner, token)
            self.db.execute("UPDATE attempts SET released=1 WHERE token=?", (token,))
            self.event(repo, base, "released", {"token": token, "owner": owner, "reason": reason})


def review_evidence(reviews, head):
    for r in reversed(reviews):
        if (r["user"]["login"] == REVIEWER and r.get("commit_id") == head and
                r.get("submitted_at") and r["state"] in ("COMMENTED", "APPROVED", "CHANGES_REQUESTED")):
            return "review:" + str(r["id"])
    # A shortened SHA in a mutable summary is deliberately not treated as full-head proof.
    return None


def changes_requested(reviews):
    verdicts = {}
    for r in reviews:
        if r["state"] in ("APPROVED", "CHANGES_REQUESTED", "DISMISSED"):
            verdicts[r["user"]["login"]] = r["state"]
    return "CHANGES_REQUESTED" in verdicts.values()


def thread_args(node, cursor):
    query = """query($id:ID!,$after:String){node(id:$id){... on PullRequest{
        reviewThreads(first:100,after:$after){nodes{isResolved} pageInfo{hasNextPage endCursor}}}}}"""
    args = ["api", "graphql", "-f", "query=" + query, "-f", "id=" + node]
    if cursor is not None: args += ["-f", "after=" + cursor]
    return args


class GitHub:
    def __init__(self, root, env=None):
        self.root, self.env = root, env

    def command(self, args):
        try:
            result = subprocess.run(["gh"] + args, cwd=self.root, env=self.env,
                                    capture_output=True, text=True, check=True, timeout=60)
            value = json.loads(result.stdout)
            require(not isinstance(value, dict) or not value.get("errors"), "GitHub query returned errors")
            return value
        except (subprocess.SubprocessError, OSError, ValueError) as exc:
            # Do not persist CLI stderr, which can include authentication details.
            raise QueueError("GitHub read failed (" + type(exc).__name__ + ")") from exc

    def get(self, endpoint):
        return self.command(["api", "--method", "GET", endpoint])

    def pages(self, endpoint):
        pages = self.command(["api", "--method", "GET", endpoint, "--paginate", "--slurp"])
        require(isinstance(pages, list) and all(isinstance(p, list) for p in pages), "invalid paginated response")
        return [item for page in pages for item in page]

    def unresolved(self, node):
        cursor, seen, total = None, set(), 0
        for _ in range(100):
            try:
                page = self.command(thread_args(node, cursor))["data"]["node"]["reviewThreads"]
                for thread in page["nodes"]:
                    require(type(thread["isResolved"]) is bool, "unknown thread resolution")
                    total += not thread["isResolved"]
                more = page["pageInfo"]["hasNextPage"]
                require(type(more) is bool, "unknown thread pagination")
                if not more: return total
                cursor = page["pageInfo"]["endCursor"]
                require(isinstance(cursor, str) and cursor and cursor not in seen, "invalid thread cursor")
                seen.add(cursor)
            except (KeyError, TypeError) as exc:
                raise QueueError("incomplete review thread response") from exc
        raise QueueError("thread page limit reached; refusing partial observation")

    def scan(self, repo, base, tracked, ticket_reader):
        identity(repo, base)
        observed = time.time()
        endpoint = "repos/" + repo
        base_path = endpoint + "/commits/" + quote(base, safe="")
        base_sha = self.get(base_path)["sha"]
        listing = self.pages(endpoint + "/pulls?state=open&base=" + quote(base, safe="") + "&per_page=100")
        numbers = sorted(set(tracked) | {p["number"] for p in listing})
        candidates = []
        for number in numbers:
            path = endpoint + "/pulls/" + str(number)
            pr = self.get(path)
            head, branch = pr["head"]["sha"], pr["head"]["ref"]
            reviews = self.pages(path + "/reviews?per_page=100")
            unresolved = self.unresolved(pr["node_id"])
            match = re.fullmatch(r"ticket/([A-Z][A-Z0-9]*-[a-z0-9]+)", branch)
            ticket = match[1] if match else None
            bead = ticket_reader(ticket) if ticket else {}
            criteria = bead.get("acceptance_criteria")
            evidence = review_evidence(reviews, head)
            state = "MERGED" if pr["merged"] else pr["state"].upper()
            # Retargeted/fork PRs are visible but cannot enter the local ticket lane.
            same_repo = pr["head"].get("repo") and pr["head"]["repo"]["full_name"].lower() == repo.lower()
            if pr["base"]["ref"] != base: state = "UNKNOWN"
            candidates.append(dict(number=number, head=head, branch=branch, state=state,
                draft=pr["draft"], mergeable={True: "MERGEABLE", False: "CONFLICTING", None: "UNKNOWN"}[pr["mergeable"]],
                ticket=ticket, claimed=bool(same_repo and bead.get("status") == "in_progress" and bead.get("assignee")),
                criteria_hash=digest(criteria) if isinstance(criteria, str) and criteria.strip() else None,
                review_head=head if evidence else None, review_evidence=evidence,
                unresolved=unresolved, changes_requested=changes_requested(reviews),
                acceptance_head=None, acceptance_criteria_hash=None, acceptance_evidence=None, dependencies=[]))
            final = self.get(path)
            require((final["head"]["sha"], final["base"]["ref"], final["state"], final["draft"]) ==
                    (head, pr["base"]["ref"], pr["state"], pr["draft"]), "PR changed during scan; retry")
        require(self.get(base_path)["sha"] == base_sha, "base changed during scan; retry")
        result = dict(repository=repo, base_branch=base, base_sha=base_sha,
                      observed_at=observed, candidates=candidates)
        validate_snapshot(result)
        return result


def read_ticket(root, ticket):
    try:
        p = subprocess.run(["bd", "show", ticket, "--json", "--readonly"], cwd=root,
                           text=True, capture_output=True, check=True, timeout=30)
        rows = json.loads(p.stdout)
        require(isinstance(rows, list) and len(rows) == 1 and rows[0]["id"] == ticket, "ticket identity mismatch")
        return rows[0]
    except (subprocess.SubprocessError, OSError, ValueError, KeyError) as exc:
        raise QueueError("ticket read failed for " + ticket) from exc


def main():
    root = Path(os.environ.get("LOOP_ROOT", Path(__file__).resolve().parent.parent)).resolve()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--db", type=Path, help="explicit shadow SQLite journal outside the checkout")
    parser.add_argument("--repo", help="owner/name, required except for observe/self-test; scan verifies the checkout")
    parser.add_argument("--base", help="defaults to default_branch in .loop.toml")
    subs = parser.add_subparsers(dest="command")
    observe = subs.add_parser("observe", help="import a complete synthetic observation; cannot authorize live work")
    observe.add_argument("snapshot", type=Path)
    subs.add_parser("scan", help="read GitHub and Beads; never publish or execute work")
    subs.add_parser("status")
    subs.add_parser("plan")
    subs.add_parser("events")
    enqueue = subs.add_parser("enqueue", help="request a place in the shadow queue")
    enqueue.add_argument("number", type=int)
    enqueue.add_argument("--head", required=True)
    for name in ("claim", "renew", "release"):
        command = subs.add_parser(name, help="simulate a fenced shadow worker " + name)
        command.add_argument("--owner", required=True)
        if name != "claim": command.add_argument("--token", type=int, required=True)
        if name == "release": command.add_argument("--reason", required=True)
        else: command.add_argument("--ttl", type=float, default=60)
    args = parser.parse_args()
    if args.self_test:
        return subprocess.call([sys.executable, str(Path(__file__).with_name("merge-queue-tests.py")), "--self-test"])
    require(args.command is not None and args.db is not None, "choose a command and --db outside the checkout")
    db = args.db.expanduser().resolve()
    require(root != db and root not in db.parents, "queue state must live outside the checkout")
    store = Store(db)
    try:
        if args.command == "observe":
            value = json.loads(args.snapshot.read_text())
            store.observe(value)
            repo, base = value["repository"], value["base_branch"]
        else:
            base = args.base
            if not base:
                base = subprocess.check_output([str(Path(__file__).with_name("loop-config.sh")), "default_branch"],
                                               env=dict(os.environ, LOOP_ROOT=str(root)), text=True).strip()
            api = GitHub(root)
            repo = args.repo
            require(repo is not None, "--repo is required so failed discovery can hold the identified queue")
            identity(repo, base)
            if args.command == "scan":
                started = time.time()
                try:
                    actual = api.command(["repo", "view", "--json", "nameWithOwner"])["nameWithOwner"]
                    require(repo.lower() == actual.lower(), "scan repository must match the checkout and Beads database")
                    store.observe(api.scan(repo, base, store.tracked(repo, base), lambda t: read_ticket(root, t)))
                except (QueueError, KeyError, TypeError) as exc:
                    # Discovery itself is a provider read. --repo identifies the lane to hold
                    # even when authentication or connectivity prevents verifying the checkout.
                    store.scan_failed(repo, base, started, str(exc))
                    raise QueueError("scan failed; queue held: " + str(exc)) from exc
            else:
                if args.command == "enqueue": store.enqueue(repo, base, args.number, args.head)
                elif args.command == "claim": store.claim(repo, base, args.owner, args.ttl)
                elif args.command == "renew": store.renew(repo, base, args.owner, args.token, args.ttl)
                elif args.command == "release": store.release(repo, base, args.owner, args.token, args.reason)
        result = store.events(repo, base) if args.command == "events" else store.plan(repo, base)
        print(json.dumps(result, indent=2))
    finally:
        store.close()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (QueueError, sqlite3.Error, OSError, ValueError, subprocess.SubprocessError) as exc:
        print("merge-queue: " + str(exc), file=sys.stderr)
        sys.exit(1)
