"""Tests for tools/Import-OwuiSeed.py: export from the fake old install, import
into a fake fresh install, and check what OWUI would read.

Run: python -m unittest discover -s tests/python -v

Secrets and addresses are built at run time, as in test_export_owui_seed.py.
"""

import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import test_export_owui_seed as base
from test_export_owui_seed import ADMIN, BRAVE, FAKE, KEY, OPENAI, PC_IP, SCHEMA, SUBAGENT_KEY, TOOLSERVER, GROQ

IMPORTER = base.REPO / 'tools' / 'Import-OwuiSeed.py'
NEW_ADMIN = 'admin-new-0042'
NEW_PC_IP = '.'.join(['100', '64', '0', '99'])
SEEDED = ['tool', 'function', 'model', 'skill', 'prompt', 'group', 'group_member', 'access_grant']
# Secrets inside other text: the key as a Valve default in a tool's source,
# and a proxy URL with a password and the PC's address.
BRAVE_SOURCE = 'class Valves:\n    BRAVE_API_KEY: str = "' + BRAVE + '"\n'


def proxy(ip):
    return 'http://proxy-user:' + SUBAGENT_KEY + '@' + ip + ':3128'


def fresh_install(db):
    """What a new OWUI looks like after the admin signs up: the same tables,
    a few default config rows, one admin with settings of its own."""
    for table in SEEDED:
        db.execute(f'DELETE FROM "{table}"')
    db.execute('DELETE FROM "user"')
    db.execute('DELETE FROM chat')
    db.execute('DELETE FROM api_key')
    db.execute("UPDATE config SET value = '[]' WHERE key = 'openai.api_keys'")
    db.execute('INSERT INTO "user" (id, email, role, name, settings) VALUES (?, ?, ?, ?, ?)',
               (NEW_ADMIN, 'new@example.invalid', 'admin', 'New', json.dumps({'ui': {'theme': 'dark'}})))


def decrypt(token):
    from open_webui.utils.valves import _fernet
    return json.loads(_fernet().decrypt(token.encode()).decode())


class ImportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.old = self.dir / 'old.db'
        self.new = self.dir / 'new.db'
        self.seed = self.dir / 'seed'
        self.secrets = self.dir / 'out' / 'values.json'
        self.secrets.parent.mkdir()
        base.build_db(self.old, base.load_schema(), self.old_mutate)
        self.export(self.old, self.seed, self.secrets, PC_IP)
        base.build_db(self.new, base.load_schema(), fresh_install)

    def tearDown(self):
        self.tmp.cleanup()

    @staticmethod
    def old_mutate(db):
        db.execute("UPDATE prompt SET content = ? WHERE id = 'p1'", ('Tidy this: {{CLIPBOARD}}',))
        db.execute("UPDATE tool SET content = ? WHERE id = 'brave_search'", (BRAVE_SOURCE,))
        db.execute("INSERT INTO config VALUES ('rag.youtube_loader_proxy_url', ?, 1)", (json.dumps(proxy(PC_IP)),))
        db.execute("UPDATE skill SET content = ? WHERE id = 's1'", ('fetch through ' + proxy(PC_IP),))

    def env(self, **extra):
        e = dict(os.environ, PYTHONPATH=str(FAKE), FAKE_OWUI_KEY=KEY, ENABLE_VALVE_ENCRYPTION='true')
        e.pop('DATABASE_URL', None)
        e.update(extra)
        return e

    def export(self, db, seed_dir, secrets_file, ip):
        # --stdout, as the collector runs it, with the files written here:
        # the exporter refuses its own file mode on Windows.
        p = subprocess.run([sys.executable, str(base.SCRIPT), '--schema', str(SCHEMA), '--db', str(db),
                            '--image-digest', 'sha256:' + 'd' * 64, '--endpoint', f'PC_TS_IP={ip}', '--stdout'],
                           capture_output=True, text=True, env=self.env(), timeout=60)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        doc = json.loads(p.stdout)
        seed_dir.mkdir()
        for name, text in doc['seed'].items():
            (seed_dir / name).write_text(text, encoding='utf-8', newline='\n')
        secrets_file.write_text(doc['secrets_file'], encoding='utf-8', newline='\n')

    def run_import(self, endpoints=None, env=None, seed=None, secrets=None):
        args = [sys.executable, str(IMPORTER), '--schema', str(SCHEMA), '--db', str(self.new),
                '--seed', str(seed or self.seed), '--secrets', str(secrets or self.secrets)]
        for item in (endpoints if endpoints is not None else [f'PC_TS_IP={NEW_PC_IP}']):
            args += ['--endpoint', item]
        p = subprocess.run(args, capture_output=True, text=True, env=self.env(**(env or {})), timeout=60)
        for value in (OPENAI, BRAVE, GROQ, TOOLSERVER, SUBAGENT_KEY):
            self.assertNotIn(value, p.stdout + p.stderr)
        return p

    def rows(self, table):
        db = sqlite3.connect(self.new)
        db.row_factory = sqlite3.Row
        try:
            return {r['id'] if 'id' in r.keys() else r['key']: dict(r) for r in db.execute(f'SELECT * FROM "{table}"')}
        finally:
            db.close()

    def config(self, key):
        return json.loads(self.rows('config')[key]['value'])

    def assert_untouched(self):
        for table in SEEDED:
            self.assertEqual(self.rows(table), {}, f'{table} was written')
        self.assertEqual(self.config('openai.api_keys'), [])

    # ---- the good path ----------------------------------------------------

    def test_imports_the_seed_with_secrets_addresses_and_owner_restored(self):
        p = self.run_import()
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assertIn('OK      seed imported: tool 2, function 1', p.stdout)

        tools = self.rows('tool')
        self.assertEqual(sorted(tools), ['brave_search', 'local_subagent'])
        self.assertEqual({t['user_id'] for t in tools.values()}, {NEW_ADMIN})
        valves = decrypt(json.loads(tools['brave_search']['valves']))
        self.assertEqual(valves, {'BRAVE_API_KEY': BRAVE, 'MAX_RESULTS': 5, 'max_tokens': 2000})
        self.assertEqual(decrypt(json.loads(tools['local_subagent']['valves']))['BASE_URL'], f'http://{NEW_PC_IP}:11434')

        ntfy = decrypt(json.loads(self.rows('function')['ntfy_push']['valves']))
        self.assertEqual(ntfy['only_user_ids'], [NEW_ADMIN])
        self.assertEqual(ntfy['ntfy_token'], 'tk_' + 'n' * 29)

        self.assertEqual(self.config('openai.api_keys'), [OPENAI, ''])
        self.assertEqual(self.config('ollama.base_urls'), [f'http://{NEW_PC_IP}:11434'])
        self.assertEqual(self.config('tool_server.connections')[0]['key'], TOOLSERVER)
        self.assertEqual(self.config('audio.stt.openai.api_key'), GROQ)

        model = self.rows('model')['qwen-helper']
        self.assertEqual(json.loads(model['meta'])['headers'], {'Authorization': 'Bearer ' + 'x' * 30})

        grants = self.rows('access_grant')
        self.assertEqual(grants['a2']['principal_id'], NEW_ADMIN)
        self.assertEqual(grants['a1']['principal_id'], 'g1')
        self.assertEqual(self.rows('group_member')['gm1']['user_id'], NEW_ADMIN)

        settings = json.loads(self.rows('user')[NEW_ADMIN]['settings'])
        self.assertEqual(settings['ui']['theme'], 'dark')
        self.assertEqual(settings['ui']['pinnedModels'], ['qwen3:14b'])
        sub = decrypt(settings['tools']['valves']['local_subagent'])
        self.assertEqual(sub, {'SYSTEM_PROMPT': 'You are a careful sub-agent.', 'API_KEY': SUBAGENT_KEY})

    def test_puts_secrets_back_inside_other_text_with_the_new_address(self):
        self.assertIn('{{BUNDLE:embedded/', (self.seed / 'tool.json').read_text(encoding='utf-8'))
        p = self.run_import()
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assertNotIn('was not used', p.stdout)
        self.assertEqual(self.rows('tool')['brave_search']['content'], BRAVE_SOURCE)
        self.assertEqual(self.rows('skill')['s1']['content'], 'fetch through ' + proxy(NEW_PC_IP))
        self.assertEqual(self.config('rag.youtube_loader_proxy_url'), proxy(NEW_PC_IP))

    def test_leaves_owuis_own_template_variables_alone(self):
        self.assertEqual(self.run_import().returncode, 0)
        self.assertEqual(self.rows('prompt')['p1']['content'], 'Tidy this: {{CLIPBOARD}}')

    def test_writes_plain_valves_when_this_install_does_not_encrypt_them(self):
        p = self.run_import(env={'ENABLE_VALVE_ENCRYPTION': 'false'})
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assertEqual(json.loads(self.rows('tool')['brave_search']['valves'])['BRAVE_API_KEY'], BRAVE)

    def test_values_moved_by_the_newer_rules_come_back_exactly(self):
        # Review round 3 (AICL-0143): a URL token, a credential-named field,
        # JSON text holding a key and a generated-looking token all travel as
        # references, and the import puts back exactly what was there.
        token = 'Q' * 48
        url = 'https://hooks.example.invalid/notify?token=' + token
        prompt = json.dumps({'note': 'call the API', 'auth': {'api_key': 'R' * 40}})
        opaque = 'aZ7' * 12

        def mutate(db):
            self.old_mutate(db)
            db.execute("UPDATE tool SET valves = ? WHERE id = 'local_subagent'",
                       (json.dumps({'BASE_URL': f'http://{PC_IP}:11434', 'ENDPOINT': url, 'SYSTEM_PROMPT': prompt}),))
            db.execute("UPDATE model SET meta = ?, params = ? WHERE id = 'qwen-helper'",
                       (json.dumps({'toolIds': ['brave_search'], 'future_auth_blob': token}),
                        json.dumps({'temperature': 0.2, 'x_opaque': opaque})))
        old, seed, secrets = self.dir / 'old-r3.db', self.dir / 'seed-r3', self.dir / 'out' / 'values-r3.json'
        base.build_db(old, base.load_schema(), mutate)
        self.export(old, seed, secrets, PC_IP)
        seed_text = ''.join(f.read_text(encoding='utf-8') for f in seed.iterdir())
        for value in (token, 'R' * 40, opaque):
            self.assertNotIn(value, seed_text)

        p = self.run_import(seed=seed, secrets=secrets)
        self.assertEqual(p.returncode, 0, p.stdout)
        valves = decrypt(json.loads(self.rows('tool')['local_subagent']['valves']))
        self.assertEqual(valves, {'BASE_URL': f'http://{NEW_PC_IP}:11434', 'ENDPOINT': url, 'SYSTEM_PROMPT': prompt})
        model = self.rows('model')['qwen-helper']
        self.assertEqual(json.loads(model['meta'])['future_auth_blob'], token)
        self.assertEqual(json.loads(model['params']), {'temperature': 0.2, 'x_opaque': opaque})

    def test_an_address_that_matches_no_node_comes_back_unchanged(self):
        # Liam's choice (8 October 2026): an old tailnet address in a
        # function's code travels in the bundle and comes back exactly.
        stray = '.'.join(['100', '90', '1', '2'])
        code = f'URL = "http://{stray}:80"\nPC = "http://{PC_IP}:8090"\n'

        def mutate(db):
            self.old_mutate(db)
            db.execute("UPDATE function SET content = ? WHERE id = 'ntfy_push'", (code,))
        old, seed, secrets = self.dir / 'old-stray.db', self.dir / 'seed-stray', self.dir / 'out' / 'values-stray.json'
        base.build_db(old, base.load_schema(), mutate)
        self.export(old, seed, secrets, PC_IP)
        self.assertNotIn(stray, ''.join(f.read_text(encoding='utf-8') for f in seed.iterdir()))

        p = self.run_import(seed=seed, secrets=secrets)
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assertNotIn(stray, p.stdout + p.stderr)
        self.assertEqual(self.rows('function')['ntfy_push']['content'], code.replace(PC_IP, NEW_PC_IP))

    def test_exporting_the_imported_install_gives_the_same_seed(self):
        self.assertEqual(self.run_import().returncode, 0)
        again, again_secrets = self.dir / 'again', self.dir / 'out' / 'again.json'
        self.export(self.new, again, again_secrets, NEW_PC_IP)
        for f in sorted(self.seed.iterdir()):
            self.assertEqual((again / f.name).read_text(encoding='utf-8'), f.read_text(encoding='utf-8'), f.name)
        self.assertEqual(json.loads(again_secrets.read_text(encoding='utf-8')), json.loads(self.secrets.read_text(encoding='utf-8')))

    def test_runs_from_the_caller_with_everything_passed_in(self):
        spec = base.importlib.util.spec_from_file_location('import_owui_seed', IMPORTER)
        boot = ("import json,sys;e=json.loads(sys.stdin.read());g={'__name__':'owui_seed_import'};"
                "exec(compile(e['script'],'Import-OwuiSeed.py','exec'),g);"
                "sys.exit(g['main'](e['argv'],seed_files=e['seed'],secrets_text=e['secrets'],schema_text=e['schema']))")
        values = self.secrets.read_text(encoding='utf-8')
        envelope = json.dumps({
            'argv': ['--db', str(self.new), '--endpoint', f'PC_TS_IP={NEW_PC_IP}'],
            'seed': {p.name: p.read_text(encoding='utf-8') for p in self.seed.iterdir()},
            'secrets': values,
            'schema': SCHEMA.read_text(encoding='utf-8'),
            'script': IMPORTER.read_text(encoding='utf-8'),
        })
        self.assertIsNotNone(spec)
        p = subprocess.run([sys.executable, '-c', boot], input=envelope, capture_output=True, text=True, env=self.env(), timeout=60)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(self.rows('tool')['brave_search']['user_id'], NEW_ADMIN)

    # ---- stops, with the database left as it was --------------------------

    def assert_stopped(self, p, phrase):
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        self.assertIn('STOPPED nothing was written', p.stdout)
        self.assertIn(phrase, p.stdout)
        self.assert_untouched()

    def test_stops_on_another_owui_version(self):
        self.assert_stopped(self.run_import(env={'FAKE_OWUI_VERSION': '0.12.0'}), 'OWUI version is 0.12.0, the seed is from 0.11.4 (C-40)')

    def test_stops_on_another_alembic_revision(self):
        db = sqlite3.connect(self.new)
        db.execute("UPDATE alembic_version SET version_num = 'ffffffffffff'")
        db.commit()
        db.close()
        self.assert_stopped(self.run_import(), 'Alembic revision is ffffffffffff')

    def test_stops_unless_there_is_exactly_one_admin(self):
        db = sqlite3.connect(self.new)
        db.execute('INSERT INTO "user" (id, role) VALUES (?, ?)', ('second-admin', 'admin'))
        db.commit()
        db.close()
        self.assert_stopped(self.run_import(), 'expected exactly one admin user (the new account), found 2')

    def test_stops_when_the_install_is_not_fresh(self):
        db = sqlite3.connect(self.new)
        db.execute('INSERT INTO skill (id, user_id, name) VALUES (?, ?, ?)', ('s9', NEW_ADMIN, 'mine'))
        db.commit()
        db.close()
        p = self.run_import()
        self.assertEqual(p.returncode, 1)
        self.assertIn('table skill already has 1 row(s); the seed goes into a fresh install only', p.stdout)
        self.assertEqual(sorted(self.rows('skill')), ['s9'])

    def test_stops_when_a_secret_reference_has_no_value(self):
        doc = json.loads(self.secrets.read_text(encoding='utf-8'))
        del doc['refs']['config/openai.api_keys']
        self.secrets.write_text(json.dumps(doc), encoding='utf-8')
        self.assert_stopped(self.run_import(), 'secret reference config/openai.api_keys is listed by the seed but not in the secrets file')

    def test_stops_when_an_address_the_seed_uses_has_no_value(self):
        self.assert_stopped(self.run_import(endpoints=[]), 'no value given for {{PC_TS_IP}}')

    def test_stops_on_a_grant_to_another_user(self):
        grants = json.loads((self.seed / 'access_grant.json').read_text(encoding='utf-8'))
        for g in grants:
            if g['principal_type'] == 'user':
                g['principal_id'] = 'someone-else'
        (self.seed / 'access_grant.json').write_text(json.dumps(grants), encoding='utf-8')
        self.assert_stopped(self.run_import(), 'granted to a user other than the owner')

    def test_stops_on_a_marker_with_no_value(self):
        tools = json.loads((self.seed / 'tool.json').read_text(encoding='utf-8'))
        for t in tools:
            if t['id'] == 'local_subagent':
                t['content'] = 'KEY = "{{BUNDLE:embedded/nothing/here}}"'
        (self.seed / 'tool.json').write_text(json.dumps(tools), encoding='utf-8')
        self.assert_stopped(self.run_import(), 'tool/local_subagent/content: {{BUNDLE:embedded/nothing/here}} has no text value in the secrets file')

    def test_stops_on_a_seed_with_files_missing(self):
        (self.seed / 'skill.json').unlink()
        self.assert_stopped(self.run_import(), 'the seed does not have the expected files: skill')

    def test_stops_on_a_row_count_that_does_not_match_the_provenance(self):
        prov = json.loads((self.seed / 'provenance.json').read_text(encoding='utf-8'))
        prov['counts']['tool'] = 3
        (self.seed / 'provenance.json').write_text(json.dumps(prov), encoding='utf-8')
        self.assert_stopped(self.run_import(), 'tool: the seed promises 3 row(s), 2 were imported')

    def test_stops_when_owui_will_not_start_without_a_key(self):
        p = self.run_import(env={'FAKE_OWUI_KEY': ''})
        self.assert_stopped(p, 'is WEBUI_SECRET_KEY set in the container?')


if __name__ == '__main__':
    unittest.main()
