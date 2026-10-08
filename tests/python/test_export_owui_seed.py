"""Tests for tools/Export-OwuiSeed.py against a fake OWUI 0.11.4 database.

Run: python -m unittest discover -s tests/python -v

Every secret here is built at run time ('sk-' + 'A' * 40), and so is the
tailnet address, so no literal lands in the repo (AGENTS.md).
"""

import contextlib
import hashlib
import importlib.util
import io
import shutil
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
SCRIPT = REPO / 'tools' / 'Export-OwuiSeed.py'
SCHEMA = REPO / 'manifests' / 'owui-seed' / 'schema.json'
FAKE = HERE / 'fake_owui'

KEY = 'test-only-key-' + 'k' * 20
OPENAI = 'sk-' + 'A' * 40
BRAVE = 'BSA' + 'b' * 27
GROQ = 'gsk_' + 'G' * 30
TOOLSERVER = 'tool-server-bearer-' + 'T' * 24
SUBAGENT_KEY = 'sub-agent-key-' + 'S' * 24
PC_IP = '.'.join(['100', '64', '0', '7'])
ADMIN = 'admin-0001'
FILE_MODE = os.name != 'nt'  # the exporter refuses --seed-out/--secrets-out on Windows (R3-06)

sys.path.insert(0, str(FAKE))
os.environ['FAKE_OWUI_KEY'] = KEY
from open_webui.utils.valves import _fernet  # noqa: E402  (the stand-in codec)

spec = importlib.util.spec_from_file_location('export_owui_seed', SCRIPT)
exporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exporter)


def encrypt(valves: dict) -> str:
    return _fernet().encrypt(json.dumps(valves).encode()).decode()


def load_schema() -> dict:
    return json.loads(SCHEMA.read_text(encoding='utf-8'))


def build_db(path: Path, schema: dict, mutate=None) -> None:
    """An OWUI-shaped database: every seeded table, a few excluded ones, the
    config table and the user table, filled like Liam's install."""
    db = sqlite3.connect(path)
    db.execute('PRAGMA journal_mode = WAL')
    for name, spec_ in schema['tables'].items():
        if isinstance(spec_, dict):
            cols = ', '.join(f'"{c}"' for c in spec_['columns'])
            db.execute(f'CREATE TABLE "{name}" ({cols})')
    db.execute('CREATE TABLE config (key TEXT PRIMARY KEY, value JSON NOT NULL, updated_at BIGINT)')
    db.execute('CREATE TABLE "user" (id, email, username, role, name, profile_image_url, settings, info, oauth, created_at, updated_at)')
    db.execute('CREATE TABLE alembic_version (version_num)')
    db.execute('CREATE TABLE chat (id, user_id, title, chat)')
    db.execute('CREATE TABLE api_key (id, user_id, key)')
    db.execute('INSERT INTO alembic_version VALUES (?)', (schema['alembic_revision'],))

    settings = {
        'ui': {
            'pinnedModels': ['qwen3:14b'],
            'params': {'function_calling': 'native'},
            'highContrastMode': True,
            'userLocation': 'somewhere private',
        },
        'tools': {'valves': {'local_subagent': encrypt({'SYSTEM_PROMPT': 'You are a careful sub-agent.', 'API_KEY': SUBAGENT_KEY})}},
        'functions': {'valves': {}},
    }
    db.execute('INSERT INTO "user" (id, email, role, name, settings) VALUES (?, ?, ?, ?, ?)',
               (ADMIN, 'owner@example.invalid', 'admin', 'Owner', json.dumps(settings)))
    db.execute('INSERT INTO api_key VALUES (?, ?, ?)', ('k1', ADMIN, 'sk-' + 'Z' * 40))
    db.execute('INSERT INTO chat VALUES (?, ?, ?, ?)', ('c1', ADMIN, 'a chat', '{}'))

    config = {
        'openai.api_keys': [OPENAI, ''],
        'openai.api_base_urls': ['https://api.openai.example/v1', 'http://host.docker.internal:11434/v1'],
        'ollama.base_urls': [f'http://{PC_IP}:11434'],
        'tool_server.connections': [{'url': f'http://{PC_IP}:8000/brave', 'key': TOOLSERVER, 'auth_type': 'bearer', 'config': {'enable': True}}],
        'web.search.brave_search_api_key': BRAVE,
        'audio.stt.openai.api_key': GROQ,
        'web.search.brave_search_context_tokens': 8192,
        'auth.enable_api_keys': True,
        'code_execution.jupyter.auth_password': '',
    }
    for k, v in config.items():
        db.execute('INSERT INTO config VALUES (?, ?, ?)', (k, json.dumps(v), 1))

    def tool(tid, content, valves):
        db.execute('INSERT INTO tool VALUES (?,?,?,?,?,?,?,?,?)',
                   (tid, ADMIN, tid, content, json.dumps([{'name': tid}]), json.dumps({'description': tid}), valves, 2, 1))

    tool('brave_search', 'class Tools:\n    def search(self):\n        return f"Bearer {self.valves.BRAVE_API_KEY}"\n',
         encrypt({'BRAVE_API_KEY': BRAVE, 'MAX_RESULTS': 5, 'max_tokens': 2000}))
    tool('local_subagent', 'class Tools: pass\n', json.dumps({'BASE_URL': f'http://{PC_IP}:11434', 'TIMEOUT': 30}))

    def function(fid, ftype):
        db.execute('INSERT INTO function VALUES (?,?,?,?,?,?,?,?,?,?,?)',
                   (fid, ADMIN, fid, ftype, 'class Filter: pass\n', '{}', None, 1, 0, 2, 1))

    function('ntfy_push', 'event')
    db.execute("UPDATE function SET valves = ? WHERE id = 'ntfy_push'",
               (encrypt({'ntfy_token': 'tk_' + 'n' * 29, 'ntfy_url': f'http://{PC_IP}:8090', 'only_user_ids': [ADMIN]}),))
    function('discord_feed_curator', 'pipe')

    db.execute('INSERT INTO model VALUES (?,?,?,?,?,?,?,?,?)',
               ('qwen-helper', ADMIN, 'qwen3:14b', 'Qwen helper', json.dumps({'temperature': 0.2}),
                json.dumps({'toolIds': ['brave_search'], 'headers': {'Authorization': 'Bearer ' + 'x' * 30}}), 1, 2, 1))
    db.execute('INSERT INTO skill VALUES (?,?,?,?,?,?,?,?,?)', ('s1', ADMIN, 'summarise', 'd', 'body', '{}', 1, 2, 1))
    db.execute('INSERT INTO prompt VALUES (?,?,?,?,?,?,?,?,?,?,?,?)', ('p1', '/tidy', ADMIN, 'Tidy', 'Tidy this', None, None, '[]', 1, 'h9', 2, 1))
    db.execute('INSERT INTO "group" VALUES (?,?,?,?,?,?,?,?,?)', ('g1', ADMIN, 'Family', '', None, None, '{}', 2, 1))
    db.execute('INSERT INTO group_member VALUES (?,?,?,?,?)', ('gm1', 'g1', ADMIN, 2, 1))
    for gid, rtype, rid, ptype, pid in [
        ('a1', 'tool', 'brave_search', 'group', 'g1'),
        ('a2', 'model', 'qwen-helper', 'user', ADMIN),
        ('a3', 'function', 'discord_feed_curator', 'user', ADMIN),
        ('a4', 'note', 'n1', 'user', ADMIN),
        ('a5', 'tool', 'local_subagent', 'anyone', '*'),
    ]:
        db.execute('INSERT INTO access_grant VALUES (?,?,?,?,?,?,?)', (gid, rtype, rid, ptype, pid, 'read', 1))
    if mutate:
        mutate(db)
    db.commit()
    db.close()


class Run:
    def __init__(self, code, stdout, stderr, seed_dir, secrets_file):
        self.code, self.stdout, self.stderr = code, stdout, stderr
        self.seed_dir, self.secrets_file = seed_dir, secrets_file

    @property
    def text(self):
        return self.stdout + self.stderr

    def seed(self, name):
        return json.loads((self.seed_dir / f'{name}.json').read_text(encoding='utf-8'))

    def seed_text(self):
        return ''.join(p.read_text(encoding='utf-8') for p in sorted(self.seed_dir.glob('*.json')))


class ExportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.db = self.dir / 'webui.db'
        self.schema_path = self.dir / 'schema.json'
        self.schema_path.write_text(SCHEMA.read_text(encoding='utf-8'), encoding='utf-8')

    def tearDown(self):
        self.tmp.cleanup()

    def run_export(self, mutate=None, schema_edit=None, extra=None, endpoints=True, stdout=False, env=None):
        schema = load_schema()
        if schema_edit:
            schema_edit(schema)
            self.schema_path.write_text(json.dumps(schema), encoding='utf-8')
        if not self.db.exists():
            build_db(self.db, load_schema(), mutate)
        seed_dir = self.dir / 'seed'
        secrets_file = self.dir / 'out' / 'secrets.json'
        secrets_file.parent.mkdir(exist_ok=True)
        args = [sys.executable, str(SCRIPT), '--schema', str(self.schema_path), '--db', str(self.db),
                '--image-digest', 'sha256:' + 'd' * 64]
        if endpoints:
            args += ['--endpoint', f'PC_TS_IP={PC_IP}']
        emulate = not stdout and not FILE_MODE
        args += ['--stdout'] if stdout or emulate else ['--seed-out', str(seed_dir), '--secrets-out', str(secrets_file)]
        args += extra or []
        e = dict(os.environ, PYTHONPATH=str(FAKE), FAKE_OWUI_KEY=KEY)
        e.pop('DATABASE_URL', None)
        e.update(env or {})
        p = subprocess.run(args, capture_output=True, text=True, env=e, timeout=60)
        if emulate:
            # On Windows the files come from the --stdout document, written
            # here the way the collector writes them, and the log that file
            # mode prints on stdout is on stderr.
            if p.returncode == 0:
                doc = json.loads(p.stdout)
                seed_dir.mkdir(exist_ok=True)  # file mode accepts an empty folder too
                for name, text in doc['seed'].items():
                    (seed_dir / name).write_text(text, encoding='utf-8', newline='\n')
                secrets_file.write_text(doc['secrets_file'], encoding='utf-8', newline='\n')
            return Run(p.returncode, p.stderr, '', seed_dir, secrets_file)
        return Run(p.returncode, p.stdout, p.stderr, seed_dir, secrets_file)

    def assert_stopped(self, run, *phrases):
        self.assertEqual(run.code, 1, run.text)
        self.assertIn('STOPPED nothing was written', run.text)
        self.assertFalse(run.seed_dir.exists() and any(run.seed_dir.iterdir()), 'seed files were written')
        self.assertFalse(run.secrets_file.exists(), 'the secrets file was written')
        for phrase in phrases:
            self.assertIn(phrase, run.text)
        self.assert_no_secret_printed(run.text)

    def assert_no_secret_printed(self, text):
        for value in (OPENAI, BRAVE, GROQ, TOOLSERVER, SUBAGENT_KEY, PC_IP, 'x' * 30):
            self.assertNotIn(value, text)

    # ---- the good path ----------------------------------------------------

    def test_exports_a_seed_with_no_secret_ciphertext_or_tailnet_address(self):
        run = self.run_export()
        self.assertEqual(run.code, 0, run.text)
        text = run.seed_text()
        self.assert_no_secret_printed(text)
        self.assertNotIn('gAAAAA', text)
        self.assertNotIn(ADMIN, text)
        self.assertNotIn('owner@example.invalid', text)
        self.assertIn('{{PC_TS_IP}}', text)
        self.assertIn('OK      seed exported', run.stdout)
        self.assert_no_secret_printed(run.text)

    def test_secrets_become_references_and_land_only_in_the_secrets_file(self):
        run = self.run_export()
        config = run.seed('config')
        self.assertEqual(config['openai.api_keys'], {'$bundle': 'config/openai.api_keys'})
        self.assertEqual(config['web.search.brave_search_api_key'], {'$bundle': 'config/web.search.brave_search_api_key'})
        self.assertEqual(config['tool_server.connections'][0]['key'], {'$bundle': 'config/tool_server.connections/0/key'})
        self.assertEqual(config['tool_server.connections'][0]['auth_type'], 'bearer')
        self.assertEqual(config['code_execution.jupyter.auth_password'], '', 'an empty secret stays empty')
        self.assertEqual(config['web.search.brave_search_context_tokens'], 8192)
        self.assertIs(config['auth.enable_api_keys'], True)

        secrets = json.loads(run.secrets_file.read_text(encoding='utf-8'))['refs']
        self.assertEqual(secrets['config/openai.api_keys'], [OPENAI, ''])
        self.assertEqual(secrets['config/tool_server.connections/0/key'], TOOLSERVER)
        self.assertEqual(secrets['tool/brave_search/valves/BRAVE_API_KEY'], BRAVE)
        self.assertEqual(secrets['user_settings/tools.valves/local_subagent/API_KEY'], SUBAGENT_KEY)
        self.assertEqual(sorted(secrets), run.seed('secret_refs'))
        if os.name == 'posix':
            self.assertEqual(run.secrets_file.stat().st_mode & 0o777, 0o600)

    def test_valves_are_decrypted_with_the_owui_codec_and_written_plain(self):
        run = self.run_export()
        tools = {t['id']: t for t in run.seed('tool')}
        brave = tools['brave_search']['valves']
        self.assertEqual(brave['BRAVE_API_KEY'], {'$bundle': 'tool/brave_search/valves/BRAVE_API_KEY'})
        self.assertEqual(brave['MAX_RESULTS'], 5)
        self.assertEqual(brave['max_tokens'], 2000, 'a number under a token-like name is not a secret')
        self.assertEqual(tools['local_subagent']['valves']['BASE_URL'], 'http://{{PC_TS_IP}}:11434')
        self.assertIn('self.valves.BRAVE_API_KEY', tools['brave_search']['content'])

    def test_owner_references_become_the_owner_placeholder(self):
        run = self.run_export()
        for table in ('tool', 'function', 'model', 'skill', 'prompt', 'group', 'group_member'):
            for row in run.seed(table):
                self.assertEqual(row['user_id'], '{{OWNER}}', table)
        grants = {g['id']: g for g in run.seed('access_grant')}
        self.assertEqual(grants['a2']['principal_id'], '{{OWNER}}')

    def test_the_admin_id_inside_data_becomes_the_owner_placeholder(self):
        run = self.run_export()
        ntfy = run.seed('function')[0]['valves']
        self.assertEqual(ntfy['only_user_ids'], ['{{OWNER}}'])
        self.assertEqual(ntfy['ntfy_token'], {'$bundle': 'function/ntfy_push/valves/ntfy_token'})
        self.assertEqual(ntfy['ntfy_url'], 'http://{{PC_TS_IP}}:8090')
        self.assertEqual(run.seed('provenance')['endpoints'], ['PC_TS_IP'])

    def test_only_capability_rows_and_grants_travel(self):
        run = self.run_export()
        self.assertEqual([f['id'] for f in run.seed('function')], ['ntfy_push'])
        self.assertEqual(sorted(run.seed_dir.glob('chat*')), [])
        self.assertEqual([g['id'] for g in run.seed('access_grant')], ['a1', 'a2', 'a5'])
        self.assertIn('2 access grant(s) left out', run.text)
        self.assertNotIn('version_id', run.seed('prompt')[0])
        counts = run.seed('provenance')['counts']
        self.assertEqual((counts['tool'], counts['function'], counts['access_grant']), (2, 1, 3))

    def test_model_headers_are_moved_to_a_reference(self):
        run = self.run_export()
        meta = run.seed('model')[0]['meta']
        self.assertEqual(meta['headers'], {'$bundle': 'model/qwen-helper/meta/headers'})
        self.assertEqual(meta['toolIds'], ['brave_search'])

    def test_user_settings_are_an_allowlisted_projection(self):
        run = self.run_export()
        us = run.seed('user_settings')
        self.assertEqual(us['ui']['pinnedModels'], ['qwen3:14b'])
        self.assertEqual(us['ui']['params'], {'function_calling': 'native'})
        self.assertIs(us['ui']['highContrastMode'], True)
        self.assertNotIn('userLocation', us['ui'])
        self.assertIn('ui.userLocation', run.text)
        self.assertNotIn('somewhere private', run.seed_text())
        sub = us['tools']['valves']['local_subagent']
        self.assertEqual(sub['SYSTEM_PROMPT'], 'You are a careful sub-agent.')

    def test_provenance_records_version_revision_and_digest(self):
        prov = self.run_export().seed('provenance')
        self.assertEqual((prov['owui_version'], prov['alembic_revision']), ('0.11.4', 'd4c1a8e37b62'))
        self.assertEqual(prov['image_digest'], 'sha256:' + 'd' * 64)
        self.assertEqual(prov['endpoints'], ['PC_TS_IP'])

    def test_expected_ids_report_missing_and_new_rows(self):
        run = self.run_export()
        self.assertIn('tool brave_reader is expected but not in the database', run.text)
        self.assertNotIn('is new', run.text)

    def test_stdout_mode_writes_nothing_and_prints_one_document(self):
        run = self.run_export(stdout=True)
        self.assertEqual(run.code, 0, run.stderr)
        doc = json.loads(run.stdout)
        self.assertEqual(sorted(doc), ['secrets_file', 'seed'])
        self.assertIn('config.json', doc['seed'])
        secrets = json.loads(doc['secrets_file'])
        self.assertEqual(secrets['owui_seed_secrets'], 1)
        self.assertEqual(secrets['refs']['config/openai.api_keys'], [OPENAI, ''])
        self.assertNotIn(OPENAI, ''.join(doc['seed'].values()))
        self.assertFalse(run.seed_dir.exists())
        self.assertIn('OK      seed exported', run.stderr)

    @unittest.skipUnless(FILE_MODE, 'file mode is refused on Windows')
    def test_stdout_mode_gives_the_same_files_as_file_mode(self):
        files = self.run_export()
        self.assertEqual(files.code, 0, files.text)
        doc = json.loads(self.run_export(stdout=True).stdout)
        for name, text in doc['seed'].items():
            self.assertEqual((files.seed_dir / name).read_text(encoding='utf-8'), text, name)
        self.assertEqual(sorted(p.name for p in files.seed_dir.iterdir()), sorted(doc['seed']))
        self.assertEqual(files.secrets_file.read_text(encoding='utf-8'), doc['secrets_file'])

    def test_stdout_mode_prints_ascii_only_and_keeps_other_characters(self):
        text = 'Tidy this \u00e9 \U0001F415'
        run = self.run_export(stdout=True, mutate=lambda db: db.execute("UPDATE prompt SET content = ? WHERE id = 'p1'", (text,)))
        self.assertEqual(run.code, 0, run.stderr)
        run.stdout.encode('ascii')
        prompts = json.loads(json.loads(run.stdout)['seed']['prompt.json'])
        self.assertEqual(prompts[0]['content'], text)

    def test_stdout_mode_keeps_owui_log_lines_off_stdout(self):
        # OWUI logs to stdout when it is imported; the document must stay alone there.
        run = self.run_export(stdout=True, env={'FAKE_OWUI_NOISY': '1'})
        self.assertEqual(run.code, 0, run.stderr)
        self.assertIn('fake OWUI log line', run.stderr)
        self.assertEqual(len(run.stdout.splitlines()), 1)
        json.loads(run.stdout)

    def test_runs_from_stdin_with_the_schema_passed_in(self):
        # How the collector runs it: docker exec -i <container> python3 -c BOOT,
        # with the script, the schema and the arguments on stdin (see BOOT in
        # tools/Collect-StackSecrets.ps1), so nothing has to exist in the container.
        build_db(self.db, load_schema())
        boot = ("import json,sys;e=json.loads(sys.stdin.read());g={'__name__':'owui_seed_export'};"
                "exec(compile(e['script'],'Export-OwuiSeed.py','exec'),g);"
                "sys.exit(g['main'](e['argv'],schema_text=e['schema']))")
        envelope = json.dumps({
            'argv': ['--stdout', '--db', str(self.db), '--endpoint', f'PC_TS_IP={PC_IP}'],
            'schema': SCHEMA.read_text(encoding='utf-8'),
            'script': SCRIPT.read_text(encoding='utf-8'),
        })
        e = dict(os.environ, PYTHONPATH=str(FAKE), FAKE_OWUI_KEY=KEY)
        e.pop('DATABASE_URL', None)
        p = subprocess.run([sys.executable, '-c', boot], input=envelope, capture_output=True, text=True, env=e, timeout=60)
        self.assertEqual(p.returncode, 0, p.stderr)
        doc = json.loads(p.stdout)
        self.assertIn('tool.json', doc['seed'])
        self.assertNotIn(OPENAI, ''.join(doc['seed'].values()))
        self.assertEqual(json.loads(doc['secrets_file'])['refs']['config/openai.api_keys'], [OPENAI, ''])

    def run_in(self, cwd, env_update, drop=()):
        build_db(self.db, load_schema())
        e = dict(os.environ, PYTHONPATH=str(FAKE))
        for name in ('FAKE_OWUI_KEY', 'WEBUI_SECRET_KEY', 'WEBUI_JWT_SECRET_KEY', 'DATABASE_URL') + tuple(drop):
            e.pop(name, None)
        e.update(env_update)
        args = [sys.executable, str(SCRIPT), '--schema', str(self.schema_path), '--db', str(self.db),
                '--endpoint', f'PC_TS_IP={PC_IP}', '--stdout']
        return subprocess.run(args, capture_output=True, text=True, env=e, cwd=cwd, timeout=60)

    def test_reads_the_secret_key_file_as_owui_start_sh_does(self):
        # docker exec does not run start.sh; with no key in the environment the
        # key comes from .webui_secret_key in the working folder.
        (self.dir / '.webui_secret_key').write_text(KEY + '\n', encoding='utf-8')
        p = self.run_in(self.dir, {})
        self.assertEqual(p.returncode, 0, p.stderr)
        secrets = json.loads(json.loads(p.stdout)['secrets_file'])['refs']
        self.assertEqual(secrets['tool/brave_search/valves/BRAVE_API_KEY'], BRAVE)

    def test_a_key_in_the_environment_wins_over_the_file(self):
        (self.dir / '.webui_secret_key').write_text('another-key-' + 'z' * 20, encoding='utf-8')
        p = self.run_in(self.dir, {'WEBUI_SECRET_KEY': KEY})
        self.assertEqual(p.returncode, 0, p.stderr)

    def test_stops_when_there_is_no_secret_key_at_all(self):
        p = self.run_in(self.dir, {})
        self.assertEqual(p.returncode, 1, p.stderr)
        self.assertIn('PROBLEM open_webui stopped while it was imported; is WEBUI_SECRET_KEY set in the container?', p.stderr)
        self.assertEqual(p.stdout, '')

    def test_names_an_unexpected_failure_without_its_message(self):
        # A schema with a missing entry fails in a way no check plans for.
        run = self.run_export(stdout=True, schema_edit=lambda s: s.pop('owui_version'))
        self.assertEqual(run.code, 1, run.text)
        self.assertRegex(run.stderr, r'PROBLEM unexpected KeyError at Export-OwuiSeed\.py line [0-9]+\n')
        self.assertNotIn("'owui_version'", run.stderr)
        self.assertEqual(run.stdout, '')

    def test_warns_about_a_private_lan_address(self):
        lan = '.'.join(['192', '168', '8', '20'])
        run = self.run_export(mutate=lambda db: db.execute(
            "UPDATE config SET value = ? WHERE key = 'ollama.base_urls'", (json.dumps([f'http://{lan}:11434']),)))
        self.assertEqual(run.code, 0, run.text)
        self.assertIn('seed /config/ollama.base_urls/0: holds a private LAN or Docker address', run.text)

    def test_refuses_a_schema_given_twice_or_not_at_all(self):
        with contextlib.redirect_stderr(io.StringIO()) as err:
            with self.assertRaises(SystemExit):
                exporter.main(['--stdout'])
            with self.assertRaises(SystemExit):
                exporter.main(['--stdout', '--schema', str(self.schema_path)], schema_text='{}')
        self.assertIn('give the schema once', err.getvalue())

    @unittest.skipUnless(shutil.which('pwsh'), 'needs PowerShell 7')
    def test_the_seed_passes_the_repo_secret_scan(self):
        run = self.run_export()
        self.assertEqual(run.code, 0, run.text)
        scan = subprocess.run(['pwsh', '-NoProfile', '-File', str(REPO / 'tools' / 'Test-NoSecrets.ps1'), '-Path', str(run.seed_dir)],
                              capture_output=True, text=True, timeout=120)
        self.assertEqual(scan.returncode, 0, scan.stdout + scan.stderr)
        self.assertRegex(scan.stdout, r'clean \((1[0-9]|[2-9][0-9]) files scanned\)')

    def test_the_same_database_gives_the_same_seed(self):
        a = self.run_export()
        first = a.seed_text()
        for p in a.seed_dir.iterdir():
            p.unlink()
        a.secrets_file.unlink()
        b = self.run_export()
        self.assertEqual(first, b.seed_text())

    # ---- stops ------------------------------------------------------------

    def test_stops_on_an_unclassified_column(self):
        run = self.run_export(mutate=lambda db: db.execute('ALTER TABLE tool ADD COLUMN new_thing'))
        self.assert_stopped(run, 'column tool.new_thing is not classified')

    def test_stops_on_an_unclassified_table(self):
        run = self.run_export(mutate=lambda db: db.execute('CREATE TABLE brand_new (id)'))
        self.assert_stopped(run, 'table brand_new is not classified')

    def test_stops_on_an_unclassified_config_key(self):
        run = self.run_export(mutate=lambda db: db.execute("INSERT INTO config VALUES ('future.setting', '1', 1)"))
        self.assert_stopped(run, 'config key future.setting is not classified')

    def test_stops_on_another_owui_version(self):
        run = self.run_export(env={'FAKE_OWUI_VERSION': '0.11.5'})
        self.assert_stopped(run, 'OWUI version is 0.11.5', '(C-40)')

    def test_stops_on_another_alembic_revision(self):
        run = self.run_export(mutate=lambda db: db.execute("UPDATE alembic_version SET version_num = 'ffffffffffff'"))
        self.assert_stopped(run, 'Alembic revision is ffffffffffff')

    def test_stops_when_a_valve_cannot_be_decrypted(self):
        run = self.run_export(env={'FAKE_OWUI_KEY': 'a-different-key'})
        self.assert_stopped(run, 'tool/brave_search/valves: could not be decrypted', '(InvalidToken)')

    def test_stops_when_valves_are_encrypted_and_the_codec_is_missing(self):
        run = self.run_export(env={'PYTHONPATH': ''}, extra=['--owui-version', '0.11.4'])
        self.assert_stopped(run, "encrypted, and OWUI's Valve codec could not be loaded")

    def test_stops_on_a_secret_shaped_value_under_a_safe_name(self):
        def plant(db):
            # A key the export has no reference for, so nothing can embed it.
            db.execute("UPDATE tool SET content = ? WHERE id = 'local_subagent'", ('KEY = "sk-' + 'Q' * 40 + '"\n',))
        run = self.run_export(mutate=plant)
        self.assert_stopped(run, 'seed /tool/local_subagent/content: API key (sk-) left after classification')

    def test_a_secret_value_inside_other_text_becomes_a_bundle_marker(self):
        # Tool code with the key as a Valve default, a workflow with a key in it.
        def plant(db):
            db.execute("UPDATE skill SET content = ? WHERE id = 's1'", ('use ' + TOOLSERVER + ' and ' + OPENAI,))
            db.execute("UPDATE tool SET content = ? WHERE id = 'brave_search'",
                       ('class Valves:\n    BRAVE_API_KEY: str = "' + BRAVE + '"\n',))
        run = self.run_export(mutate=plant)
        self.assertEqual(run.code, 0, run.text)
        skill = run.seed('skill')[0]['content']
        self.assertEqual(skill, 'use {{BUNDLE:embedded/config/tool_server.connections/0/key}} and {{BUNDLE:embedded/config/openai.api_keys/0}}')
        tool = {t['id']: t for t in run.seed('tool')}['brave_search']['content']
        self.assertIn('BRAVE_API_KEY: str = "{{BUNDLE:embedded/config/web.search.brave_search_api_key}}"', tool)
        secrets = json.loads(run.secrets_file.read_text(encoding='utf-8'))['refs']
        self.assertEqual(secrets['embedded/config/tool_server.connections/0/key'], TOOLSERVER)
        self.assertEqual(secrets['embedded/config/openai.api_keys/0'], OPENAI)
        self.assertEqual(secrets['embedded/config/web.search.brave_search_api_key'], BRAVE)
        self.assertEqual(sorted(secrets), run.seed('secret_refs'))
        self.assert_no_secret_printed(run.seed_text())

    def test_a_secret_holding_an_address_is_embedded_in_its_templated_form(self):
        proxy = 'http://proxy-user:' + SUBAGENT_KEY + '@' + PC_IP + ':3128'
        def plant(db):
            db.execute("INSERT INTO config VALUES ('rag.youtube_loader_proxy_url', ?, 1)", (json.dumps(proxy),))
            db.execute("UPDATE skill SET content = ? WHERE id = 's1'", ('fetch through ' + proxy,))
        run = self.run_export(mutate=plant)
        self.assertEqual(run.code, 0, run.text)
        self.assertEqual(run.seed('skill')[0]['content'], 'fetch through {{BUNDLE:embedded/config/rag.youtube_loader_proxy_url}}')
        secrets = json.loads(run.secrets_file.read_text(encoding='utf-8'))['refs']
        templated = proxy.replace(PC_IP, '{{PC_TS_IP}}')
        self.assertEqual(secrets['config/rag.youtube_loader_proxy_url'], templated, 'a restore renders the new address')
        self.assertEqual(secrets['embedded/config/rag.youtube_loader_proxy_url'], templated)

    def test_the_final_scan_still_catches_a_secret_value_left_in_the_seed(self):
        export = exporter.Export(load_schema(), {'PC_TS_IP': PC_IP})
        export.secrets = {'config/x': TOOLSERVER}
        export.final_scan({'skill': [{'id': 's1', 'content': 'use ' + TOOLSERVER}]})
        self.assertEqual(export.problems, ['seed /skill/s1/content: contains the value of a secret reference'])

    def test_stops_on_text_that_already_holds_a_placeholder_the_seed_uses(self):
        run = self.run_export(mutate=lambda db: db.execute(
            "UPDATE skill SET content = ? WHERE id = 's1'", ('hello {{OWNER}} at {{PC_TS_IP}}, today is {{CURRENT_DATE}}',)))
        self.assert_stopped(run, 'skill/s1/content: already holds the placeholder text {{OWNER}}, so it could not be restored exactly')
        self.assertNotIn('CURRENT_DATE', run.text, "OWUI's own template variables are fine")

    def test_stops_on_a_tailnet_address_without_an_endpoint(self):
        run = self.run_export(endpoints=False)
        self.assert_stopped(run, 'tailnet IP left after classification')

    def ntfy_content(self, run):
        return next(f for f in run.seed('function') if f['id'] == 'ntfy_push')['content']

    def address_refs(self, run):
        refs = json.loads(run.secrets_file.read_text(encoding='utf-8'))['refs']
        return {k: v for k, v in refs.items() if k.startswith('embedded/address/')}

    def test_keeps_a_stray_tailnet_address_in_the_bundle(self):
        stray = '.'.join(['100', '90', '1', '2'])
        run = self.run_export(mutate=lambda db: db.execute(
            "UPDATE function SET content = ? WHERE id = 'ntfy_push'", (f'URL = "http://{stray}:80"\nAGAIN = "{stray}"\n',)))
        self.assertEqual(run.code, 0, run.text)
        self.assertEqual(self.ntfy_content(run),
                         'URL = "http://{{BUNDLE:embedded/address/1}}:80"\nAGAIN = "{{BUNDLE:embedded/address/1}}"\n')
        self.assertEqual(self.address_refs(run), {'embedded/address/1': stray})
        self.assertIn('embedded/address/1', run.seed('secret_refs'))
        self.assertIn('seed /function/ntfy_push/content: holds a tailnet address or name that matches no --endpoint', run.text)
        self.assertNotIn(stray, run.text)
        self.assertNotIn(stray, run.seed_text())

    def test_keeps_a_neighbouring_address_whole_and_never_half_replaces_it(self):
        near = PC_IP + '5'  # the PC's address with one more digit
        run = self.run_export(mutate=lambda db: db.execute(
            "UPDATE function SET content = ? WHERE id = 'ntfy_push'", (f'A = "{PC_IP}:80"\nB = "{near}:80"\n',)))
        self.assertEqual(run.code, 0, run.text)
        self.assertEqual(self.ntfy_content(run), 'A = "{{PC_TS_IP}}:80"\nB = "{{BUNDLE:embedded/address/1}}:80"\n')
        self.assertEqual(self.address_refs(run), {'embedded/address/1': near})
        self.assertNotIn(near, run.text)
        domain = 'tn' + '.ts' + '.net'
        export = exporter.Export(load_schema(), {'PC_TS_IP': PC_IP, 'PC_TS_NAME': 'pc.' + domain, 'TS_DOMAIN': domain})
        self.assertEqual(export.template(f'{PC_IP} {near} {PC_IP}.', 'x'), '{{PC_TS_IP}} ' + near + ' {{PC_TS_IP}}.')
        self.assertEqual(export.template(f'pc.{domain} mypc.{domain}', 'x'), '{{PC_TS_NAME}} mypc.{{TS_DOMAIN}}')

    def test_keeps_a_whole_ipv6_address_and_a_whole_magicdns_name(self):
        name = 'a.pc.' + 'tn' + '.ts' + '.net'
        six = ':'.join(['fd7a', '115c', 'a1e0', 'ab', '', '1'])
        run = self.run_export(mutate=lambda db: db.execute(
            "UPDATE function SET content = ? WHERE id = 'ntfy_push'", (f'H = "http://{name}:3000"\nV6 = "[{six}]:80"\n',)))
        self.assertEqual(run.code, 0, run.text)
        self.assertEqual(self.ntfy_content(run),
                         'H = "http://{{BUNDLE:embedded/address/1}}:3000"\nV6 = "[{{BUNDLE:embedded/address/2}}]:80"\n')
        self.assertEqual(self.address_refs(run), {'embedded/address/1': name, 'embedded/address/2': six})
        self.assertNotIn(name, run.text)
        self.assertNotIn(six, run.text)

    def test_an_address_in_a_key_still_stops_the_export(self):
        stray = '.'.join(['100', '90', '1', '2'])
        export = exporter.Export(load_schema(), {'PC_TS_IP': PC_IP})
        seed = {'config': {stray: 'x'}}
        export.keep_other_addresses(seed)
        export.final_scan(seed)
        self.assertEqual(export.problems, ['seed /config/#' + hashlib.sha256(stray.encode()).hexdigest()[:12]
                                           + ': tailnet IP left after classification'])

    def test_passes_tailscales_own_service_address(self):
        quad = '.'.join(['100'] * 4)
        run = self.run_export(mutate=lambda db: db.execute(
            "UPDATE function SET content = ? WHERE id = 'ntfy_push'", (f'DNS = "{quad}"\nDNS6 = "fd7a:115c:a1e0::53"\n',)))
        self.assertEqual(run.code, 0, run.text)
        self.assertIn(quad, run.seed('function')[0]['content'])

    def test_stops_on_a_row_owned_by_another_user(self):
        run = self.run_export(mutate=lambda db: db.execute("UPDATE skill SET user_id = 'someone-else'"))
        self.assert_stopped(run, 'skill/s1/user_id: belongs to a user other than the admin')

    def test_leaves_out_grants_to_other_accounts_with_a_warning(self):
        def plant(db):
            db.execute('INSERT INTO "user" (id, role, name) VALUES (?, ?, ?)', ('friend-0003', 'user', 'Friend'))
            db.execute('INSERT INTO access_grant VALUES (?,?,?,?,?,?,?)', ('a6', 'model', 'qwen-helper', 'user', 'friend-0003', 'read', 1))
            db.execute('INSERT INTO access_grant VALUES (?,?,?,?,?,?,?)', ('a7', 'tool', 'brave_search', 'user', 'deleted-0004', 'read', 1))
        run = self.run_export(mutate=plant)
        self.assertEqual(run.code, 0, run.text)
        self.assertEqual([g['id'] for g in run.seed('access_grant')], ['a1', 'a2', 'a5'])
        self.assertIn('2 access grant(s) to accounts other than the admin left out (1 of them to accounts that no longer exist)', run.text)
        self.assertNotIn('friend-0003', run.seed_text())

    def test_stops_unless_there_is_exactly_one_admin(self):
        run = self.run_export(mutate=lambda db: db.execute(
            "INSERT INTO \"user\" (id, role, name) VALUES ('admin-0002', 'admin', 'Second')"))
        self.assert_stopped(run, 'expected exactly one admin user, found 2')

    def test_stops_on_a_reserved_key_in_the_data(self):
        run = self.run_export(mutate=lambda db: db.execute(
            "UPDATE skill SET meta = ? WHERE id = 's1'", (json.dumps({'$bundle': 'x'}),)))
        self.assert_stopped(run, 'holds the reserved key "$bundle"')

    def test_stops_on_a_non_sqlite_database_url(self):
        run = self.run_export(env={'DATABASE_URL': 'postgresql://db/owui'})
        self.assert_stopped(run, 'only SQLite is supported')

    @unittest.skipUnless(FILE_MODE, 'file mode is refused on Windows')
    def test_refuses_a_secrets_file_inside_the_seed_folder(self):
        build_db(self.db, load_schema())
        e = dict(os.environ, PYTHONPATH=str(FAKE), FAKE_OWUI_KEY=KEY)
        p = subprocess.run([sys.executable, str(SCRIPT), '--schema', str(self.schema_path), '--db', str(self.db),
                            '--endpoint', f'PC_TS_IP={PC_IP}', '--seed-out', str(self.dir / 'seed'),
                            '--secrets-out', str(self.dir / 'seed' / 'secrets.json')],
                           capture_output=True, text=True, env=e, timeout=60)
        self.assertEqual(p.returncode, 1)
        self.assertIn('--secrets-out must not be inside --seed-out', p.stdout)
        self.assertFalse((self.dir / 'seed' / 'secrets.json').exists())

    @unittest.skipUnless(FILE_MODE, 'file mode is refused on Windows')
    def test_refuses_an_existing_secrets_file(self):
        out = self.dir / 'out'
        out.mkdir()
        (out / 'secrets.json').write_text('old', encoding='utf-8')
        run = self.run_export()
        self.assertEqual(run.code, 1)
        self.assertIn('--secrets-out must not exist yet', run.text)
        self.assertEqual((out / 'secrets.json').read_text(encoding='utf-8'), 'old')

    def test_never_opens_the_database_for_writing(self):
        build_db(self.db, load_schema())
        before = hashlib.sha256(self.db.read_bytes()).hexdigest()
        self.assertEqual(self.run_export().code, 0)
        self.assertEqual(hashlib.sha256(self.db.read_bytes()).hexdigest(), before)

    # ---- review round 3 (AICL-0143): values that hide, names that leak ----

    def refs(self, run):
        return json.loads(run.secrets_file.read_text(encoding='utf-8'))['refs']

    def assert_hidden(self, run, *values):
        for value in values:
            self.assertNotIn(value, run.text)
            if run.seed_dir.exists():
                self.assertNotIn(value, run.seed_text())

    @staticmethod
    def label(value):
        return '#' + hashlib.sha256(value.encode()).hexdigest()[:12]

    def test_a_token_in_a_valve_url_query_becomes_a_reference(self):
        token = 'Q' * 48
        url = 'https://hooks.example.invalid/notify?token=' + token
        run = self.run_export(mutate=lambda db: db.execute(
            "UPDATE tool SET valves = ? WHERE id = 'local_subagent'", (json.dumps({'ENDPOINT': url, 'TIMEOUT': 30}),)))
        self.assertEqual(run.code, 0, run.text)
        valves = {t['id']: t for t in run.seed('tool')}['local_subagent']['valves']
        self.assertEqual(valves['ENDPOINT'], {'$bundle': 'tool/local_subagent/valves/ENDPOINT'})
        self.assertEqual(valves['TIMEOUT'], 30)
        self.assertEqual(self.refs(run)['tool/local_subagent/valves/ENDPOINT'], url)
        self.assert_hidden(run, token)

    def test_a_field_named_for_a_credential_becomes_a_reference(self):
        blob = 'Q' * 48
        run = self.run_export(mutate=lambda db: db.execute(
            "UPDATE model SET meta = ? WHERE id = 'qwen-helper'", (json.dumps({'toolIds': ['brave_search'], 'future_auth_blob': blob}),)))
        self.assertEqual(run.code, 0, run.text)
        meta = run.seed('model')[0]['meta']
        self.assertEqual(meta['future_auth_blob'], {'$bundle': 'model/qwen-helper/meta/future_auth_blob'})
        self.assertEqual(meta['toolIds'], ['brave_search'])
        self.assert_hidden(run, blob)

    def test_json_text_holding_a_credential_becomes_a_reference(self):
        key = 'R' * 40
        prompt = json.dumps({'note': 'call the API', 'auth': {'api_key': key}})
        run = self.run_export(mutate=lambda db: db.execute(
            "UPDATE tool SET valves = ? WHERE id = 'local_subagent'", (json.dumps({'SYSTEM_PROMPT': prompt}),)))
        self.assertEqual(run.code, 0, run.text)
        self.assertEqual(self.refs(run)['tool/local_subagent/valves/SYSTEM_PROMPT'], prompt)
        self.assert_hidden(run, key)

    def test_one_generated_looking_token_becomes_a_reference(self):
        token = 'aZ7' * 12
        run = self.run_export(mutate=lambda db: db.execute(
            "UPDATE model SET params = ? WHERE id = 'qwen-helper'", (json.dumps({'temperature': 0.2, 'x_opaque': token}),)))
        self.assertEqual(run.code, 0, run.text)
        self.assertEqual(run.seed('model')[0]['params']['x_opaque'], {'$bundle': 'model/qwen-helper/params/x_opaque'})
        self.assert_hidden(run, token)

    def test_stops_on_an_encoded_copy_of_a_collected_secret(self):
        import base64
        for blob in (base64.b64encode(BRAVE.encode()).decode(),
                     base64.b64encode(b'{"k": "' + BRAVE.encode() + b'"}').decode(),
                     BRAVE.encode().hex()):
            with self.subTest(blob=blob[:8]):
                for leftover in self.dir.glob('webui.db*'):
                    leftover.unlink()
                run = self.run_export(mutate=lambda db: db.execute(
                    "UPDATE model SET params = ? WHERE id = 'qwen-helper'", (json.dumps({'temperature': 0.2, 'note': blob}),)))
                self.assert_stopped(run, 'seed /model/qwen-helper/params/note: contains an encoded form')
                self.assert_hidden(run, blob)

    def test_stops_on_a_credential_url_in_a_plain_column(self):
        token = 'Q' * 48
        content = 'class Tools:\n    URL = "https://api.example.invalid/v1?%s=%s"\n' % ('api_key', token)
        run = self.run_export(mutate=lambda db: db.execute(
            "UPDATE tool SET content = ? WHERE id = 'local_subagent'", (content,)))
        self.assert_stopped(run, 'seed /tool/local_subagent/content: a credential in a URL query left after classification')
        self.assert_hidden(run, token)

    def test_a_placeholder_in_a_url_query_is_not_a_credential(self):
        content = 'class Tools:\n    URL = "https://api.example.invalid/v1?api_key={key}&token=YOUR_TOKEN"\n'
        run = self.run_export(mutate=lambda db: db.execute(
            "UPDATE tool SET content = ? WHERE id = 'local_subagent'", (content,)))
        self.assertEqual(run.code, 0, run.text)

    def test_a_secret_shaped_key_name_is_never_printed(self):
        sk = 'sk-' + 'R' * 40
        run = self.run_export(mutate=lambda db: db.execute(
            "UPDATE model SET meta = ? WHERE id = 'qwen-helper'", (json.dumps({'toolIds': [], sk: 'v'}),)))
        self.assert_stopped(run, f'seed /model/qwen-helper/meta/{self.label(sk)}: API key (sk-) left after classification')
        self.assert_hidden(run, sk)

    def test_a_dropped_user_setting_is_named_by_label_when_it_looks_secret(self):
        sk = 'sk-' + 'R' * 40

        def mutate(db):
            settings = json.loads(db.execute('SELECT settings FROM "user"').fetchone()[0])
            settings['ui'][sk] = True
            db.execute('UPDATE "user" SET settings = ?', (json.dumps(settings),))
        run = self.run_export(mutate=mutate)
        self.assertEqual(run.code, 0, run.text)
        self.assertIn(f'ui.{self.label(sk)}', run.text)
        self.assertIn('ui.userLocation', run.text)
        self.assert_hidden(run, sk)

    def test_an_unclassified_config_key_is_named_by_label_when_it_looks_secret(self):
        sk = 'sk-' + 'R' * 40
        run = self.run_export(mutate=lambda db: db.execute('INSERT INTO config VALUES (?, ?, ?)', (sk, '1', 1)))
        self.assert_stopped(run, f'config key {self.label(sk)} is not classified')
        self.assert_hidden(run, sk)

    def test_an_unexpected_revision_is_named_by_label_when_it_looks_secret(self):
        sk = 'sk-' + 'R' * 40
        run = self.run_export(mutate=lambda db: db.execute('UPDATE alembic_version SET version_num = ?', (sk,)))
        self.assert_stopped(run, f'Alembic revision is {self.label(sk)}')
        self.assert_hidden(run, sk)

    def test_an_unclassified_table_with_a_generated_name_is_named_by_label(self):
        name = 'aZ7' * 10
        run = self.run_export(mutate=lambda db: db.execute(f'CREATE TABLE "{name}" (id)'))
        self.assert_stopped(run, f'table {self.label(name)} is not classified')
        self.assert_hidden(run, name)

    def test_argument_errors_never_echo_a_value(self):
        sk = 'sk-' + 'R' * 40
        for argv in (['--stdout', '--schema', str(self.schema_path), '--endpoint', sk],
                     ['--stdout', '--schema', str(self.schema_path), '--endpoint', 'PC_TS_IP=' + sk[:3]],
                     ['--stdout', '--schema', str(self.schema_path), '--bogus', sk],
                     ['--stdout', '--schema', str(self.schema_path), f'--bogus={sk}'],
                     ['--stdout', '--schema']):
            with self.subTest(argv=len(argv)):
                with contextlib.redirect_stderr(io.StringIO()) as err, contextlib.redirect_stdout(io.StringIO()) as out:
                    with self.assertRaises(SystemExit) as ctx:
                        exporter.main(argv)
                self.assertEqual(ctx.exception.code, 2)
                self.assertIn('PROBLEM arguments:', err.getvalue())
                self.assertIn('STOPPED nothing was written', err.getvalue())
                self.assertNotIn(sk, err.getvalue() + out.getvalue())
                self.assertNotIn(sk[:3] + '\n', err.getvalue())

    def test_a_database_error_names_only_its_type(self):
        self.db.write_bytes(b'not a database ' + BRAVE.encode())
        run = self.run_export(stdout=True)
        self.assertEqual(run.code, 1, run.text)
        self.assertIn('PROBLEM database: DatabaseError\n', run.stderr)
        self.assert_hidden(run, BRAVE)

    def test_file_mode_is_refused_on_windows(self):
        with mock.patch.object(exporter, 'ON_WINDOWS', True), \
                contextlib.redirect_stderr(io.StringIO()) as err, self.assertRaises(SystemExit) as ctx:
            exporter.main(['--schema', str(self.schema_path), '--db', str(self.db),
                           '--seed-out', str(self.dir / 'seed'), '--secrets-out', str(self.dir / 'secrets.json')])
        self.assertEqual(ctx.exception.code, 2)
        self.assertIn('refused on Windows', err.getvalue())
        self.assertFalse((self.dir / 'seed').exists())
        self.assertFalse((self.dir / 'secrets.json').exists())

    @unittest.skipUnless(FILE_MODE, 'file mode is refused on Windows')
    def test_a_missing_secrets_folder_leaves_nothing_behind(self):
        build_db(self.db, load_schema())
        e = dict(os.environ, PYTHONPATH=str(FAKE), FAKE_OWUI_KEY=KEY)
        p = subprocess.run([sys.executable, str(SCRIPT), '--schema', str(self.schema_path), '--db', str(self.db),
                            '--endpoint', f'PC_TS_IP={PC_IP}', '--seed-out', str(self.dir / 'seed'),
                            '--secrets-out', str(self.dir / 'missing' / 'secrets.json')],
                           capture_output=True, text=True, env=e, timeout=60)
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        self.assertIn('the folder that should hold --secrets-out does not exist', p.stdout)
        self.assertIn('STOPPED nothing was written', p.stdout)
        self.assertNotIn('Traceback', p.stdout + p.stderr)
        self.assertEqual(sorted(x.name for x in self.dir.iterdir() if not x.name.startswith('webui.db')), ['schema.json'])

    @unittest.skipUnless(FILE_MODE, 'file mode is refused on Windows')
    def test_a_good_run_leaves_no_staging_folder(self):
        run = self.run_export()
        self.assertEqual(run.code, 0, run.text)
        self.assertEqual([x.name for x in self.dir.iterdir() if x.name.startswith('.seed-staging-')], [])
        self.assertTrue((run.seed_dir / 'tool.json').is_file())

    @unittest.skipUnless(FILE_MODE, 'file mode is refused on Windows')
    def test_a_failure_while_publishing_removes_what_it_made(self):
        seed = {'tool': [], 'provenance': {}}
        out = self.dir / 'out'
        out.mkdir()
        with mock.patch.object(exporter.os, 'rename', side_effect=OSError('injected')):
            with self.assertRaises(exporter.Stop) as ctx:
                exporter.write_files(seed, {'a': 'b'}, str(self.dir / 'seed'), str(out / 'secrets.json'))
        self.assertIn('could not write the output files (OSError)', str(ctx.exception))
        self.assertFalse(ctx.exception.left)
        self.assertNotIn('injected', str(ctx.exception))
        self.assertEqual(sorted(x.name for x in self.dir.iterdir()), ['out', 'schema.json'])
        self.assertEqual(list(out.iterdir()), [])

    @unittest.skipUnless(FILE_MODE, 'file mode is refused on Windows')
    def test_says_what_is_left_when_it_cannot_clean_up(self):
        out = self.dir / 'out'
        out.mkdir()
        with mock.patch.object(exporter.os, 'rename', side_effect=OSError('injected')), \
                mock.patch.object(exporter.os, 'unlink', side_effect=OSError('injected')):
            with self.assertRaises(exporter.Stop) as ctx:
                exporter.write_files({'tool': []}, {'a': 'b'}, str(self.dir / 'seed'), str(out / 'secrets.json'))
        self.assertTrue(ctx.exception.left)
        self.assertIn('could not remove --secrets-out', str(ctx.exception))


class NameRuleTests(unittest.TestCase):
    def test_secret_names(self):
        for name in ('API_KEY', 'apiKey', 'BRAVE_API_KEY', 'key', 'token', 'auth_token', 'client_secret',
                     'password', 'headers', 'webhook_url', 'Authorization', 'PRIVATE_KEY'):
            self.assertTrue(exporter.secret_name(name), name)

    def test_ordinary_names(self):
        for name in ('monkeys', 'turkey', 'keyboard', 'max_tokens_hint', 'model', 'url', 'base_url', 'keep_alive', 'hotkey'):
            self.assertFalse(exporter.secret_name(name), name)

    def test_credential_urls(self):
        token = 'Q' * 48

        def url(*pairs):
            return 'https://x.example.invalid/a?' + '&'.join(f'{k}={v}' for k, v in pairs)
        for text in (url(('token', token)), url(('b', '1'), ('sig', token)), url(('api_key', token)),
                     'postgres://user:' + 'p' * 12 + '@db.example.invalid/x'):
            self.assertTrue(exporter.credential_url(text), text[:30])
        for text in (url(('q', token)), url(('api_key', '{api_key}')), url(('token', 'YOUR_API_TOKEN')),
                     url(('token', '${TOKEN}')), url(('max_tokens', '4096'))):
            self.assertFalse(exporter.credential_url(text), text[:30])

    def test_opaque_tokens(self):
        self.assertTrue(exporter.opaque('aZ7' * 10))
        for text in ('Q' * 48, 'f' * 64, '123e4567-e89b-12d3-a456-426614174000', 'sdxl_lightning_8step_lora.safetensors',
                     'a perfectly ordinary sentence of text', 'short1A',
                     # model names: words and short codes, not tokens
                     'DeepSeek-R1-Distill-Qwen-14B', 'Qwen2.5-Coder-32B-Instruct-GGUF', 'Meta-Llama-3.1-8B-Instruct',
                     'Phi3-Mini-128k-Instruct-Q4_K_M'):
            self.assertFalse(exporter.opaque(text), text[:30])
        import secrets as random_tokens
        caught = sum(exporter.opaque(random_tokens.token_urlsafe(32)) for _ in range(200))
        self.assertGreaterEqual(caught, 190, 'most generated tokens are caught')

    def test_more_secret_names(self):
        for name in ('future_auth_blob', 'session_cookie', 'bearer', 'apiKeys', 'x-api-key'):
            self.assertTrue(exporter.secret_name(name), name)
        for name in ('auth_type', 'api_key_header', 'token_count', 'max_tokens', 'cookie_name', 'password_required'):
            self.assertFalse(exporter.secret_name(name), name)

    def test_names_in_messages(self):
        export = exporter.Export(load_schema(), {}, None)
        for name in ('brave_search', 'ui.userLocation', 'config', '123e4567-e89b-12d3-a456-426614174000'):
            self.assertEqual(export.name(name), name)
        for name in ('sk-' + 'R' * 40, 'aZ7' * 10, 'x' * 30, 'has space', 'a/b'):
            self.assertRegex(export.name(name), r'^#[0-9a-f]{12}$', name[:10])
        export.add_secret('tool/t/valves/K', 'shortval9')
        self.assertRegex(export.name('pre_shortval9'), r'^#[0-9a-f]{12}$')
        self.assertEqual(export.where('tool/brave_search/valves/' + 'sk-' + 'R' * 40),
                         'tool/brave_search/valves/#' + hashlib.sha256(('sk-' + 'R' * 40).encode()).hexdigest()[:12])

    def test_schema_classifies_the_known_secret_config_keys(self):
        config = load_schema()['config']
        for key in ('openai.api_keys', 'web.search.brave_search_api_key', 'audio.stt.openai.api_key', 'webhook_url',
                    'oauth.google.client_secret', 'code_execution.jupyter.auth_token',
                    # Names the rule cannot see: a Sogou secret key, an AUTOMATIC1111
                    # user:password pair, and a proxy URL that can carry a login.
                    'web.search.sougou_api_sk', 'image_generation.automatic1111.api_auth',
                    'rag.youtube_loader_proxy_url'):
            self.assertEqual(config[key], 'secret', key)
        for key in ('openai.api_base_urls', 'ollama.base_urls', 'auth.enable_api_keys', 'tool_server.connections'):
            self.assertEqual(config[key], 'safe', key)


if __name__ == '__main__':
    unittest.main()
