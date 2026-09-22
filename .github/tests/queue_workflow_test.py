#!/usr/bin/env python3
"""Execute the rendered kit workflow's actual admission code without GitHub calls."""
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import re
import unittest
from unittest import mock


class Admission(unittest.TestCase):
    def setUp(self):
        self.text = (Path(__file__).resolve().parents[1] / 'workflows/queue.yml').read_text()
        block = self.text.split("          python3 - <<'PY'\n", 1)[1].split('          PY', 1)[0]
        self.code = '\n'.join(line[10:] for line in block.splitlines())
        self.app = re.search(r"QUEUE_APP_ID: '(\d+)'", self.text).group(1)
        self.env = dict(GITHUB_EVENT_NAME='workflow_dispatch', GITHUB_RUN_ATTEMPT='1',
            QUEUE_APP_ID=self.app, QUEUE_REQUEST_APP=self.app, QUEUE_ATTEMPT='a'*32,
            QUEUE_HEAD='b'*40, QUEUE_BASE='c'*40, GITHUB_SHA='c'*40,
            GITHUB_REPOSITORY='FueledByChai/coding-agent-loop', GITHUB_RUN_ID='8', GH_TOKEN='fixture')
        self.identity = dict(repository=self.env['GITHUB_REPOSITORY'], app_id=int(self.app),
            attempt='a'*32, head='b'*40, base_sha='c'*40, run_id=8)
        external = 'queue-admission-v1:' + hashlib.sha256(json.dumps(
            self.identity, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
        self.check = dict(name='Queue CI admission', app={'id':int(self.app)},
            status='in_progress', external_id=external)

    def execute(self, rows, overrides=None):
        env = dict(self.env, **(overrides or {}))
        with mock.patch.dict(os.environ, env, clear=True), mock.patch('time.sleep'), \
             mock.patch('urllib.request.urlopen', side_effect=lambda *a, **k:
                 io.StringIO(json.dumps({'check_runs':rows}))):
            exec(self.code, {})

    def test_only_bound_in_progress_admission_passes(self):
        self.execute([self.check])
        for field, value in [('name','Other check'), ('app',{'id':1}),
                             ('status','completed'), ('external_id','unrelated')]:
            changed = dict(self.check, **{field:value})
            with self.subTest(field=field), self.assertRaises(SystemExit):
                self.execute([changed])
        for rows in ([], [self.check, copy.deepcopy(self.check)]):
            with self.subTest(rows=rows), self.assertRaises(SystemExit):
                self.execute(rows)

    def test_foreign_replayed_or_changed_candidate_rejected(self):
        changes = [('GITHUB_EVENT_NAME','pull_request'), ('GITHUB_RUN_ATTEMPT','2'),
            ('QUEUE_REQUEST_APP','1'), ('QUEUE_ATTEMPT','d'*32), ('QUEUE_HEAD','d'*40),
            ('QUEUE_BASE','d'*40), ('GITHUB_RUN_ID','9'), ('GITHUB_REPOSITORY','other/repo'),
            ('QUEUE_HEAD','$(touch /tmp/not-executed)'), ('QUEUE_ATTEMPT','bad')]
        for field, value in changes:
            with self.subTest(field=field), self.assertRaises((AssertionError,SystemExit)):
                self.execute([self.check], {field:value})

    def test_admission_precedes_every_expensive_step(self):
        self.assertEqual(self.app, '5024825')
        self.assertNotIn('__QUEUE', self.text)
        self.assertNotIn('pull_request:', self.text)
        self.assertNotIn('  push:', self.text)
        self.assertNotIn('continue-on-error:', self.text)
        self.assertNotIn('if:', self.text)
        self.assertIn('  contents: read\n  checks: read\n', self.text)
        self.assertNotIn(': write', self.text)
        self.assertIn('ref: ${{ inputs.head }}', self.text)
        self.assertIn('persist-credentials: false', self.text)
        self.assertIn('run: ./check.sh', self.text)
        steps = re.findall(r'^      - (?:name:|uses:) (.+)$', self.text, re.M)
        self.assertEqual(steps, ['Queue admission','actions/checkout@v4','Install Beads',
                                'Bootstrap the Beads queue','Full check'])


if __name__ == '__main__':
    unittest.main()
