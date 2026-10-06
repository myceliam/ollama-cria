#!/usr/bin/env python3
"""Import Open WebUI's functional seed into a fresh install (RESTORE.md Stage 7d).

The other half of tools/Export-OwuiSeed.py. It runs inside a container of the
new OWUI image, with OWUI stopped and its data volume mounted, so OWUI's own
code re-encrypts Valves with this install's WEBUI_SECRET_KEY. In one
transaction it:

  * checks the database's Alembic revision and the OWUI version against the
    seed's provenance (C-40), and that the database is a fresh install: one
    admin account, nothing in the seeded tables;
  * fills every secret reference {"$bundle": ref} from the secrets file in
    bundle folder 03, puts each secret the exporter found inside other text
    back where the seed has {{BUNDLE:embedded/<ref>}}, and then puts the
    new tailnet addresses back where the seed has {{PC_TS_IP}} and the like;
  * points every owner and member reference ({{OWNER}}) at the new admin
    (C-38);
  * writes the config keys, the tools, functions, models, skills, prompts,
    groups, members and grants, and merges the user-settings projection into
    the new admin's settings;
  * checks, before it commits, that the row counts match the seed, no
    {{OWNER}} or {{BUNDLE:...}} is left, and SQLite's foreign-key check is
    clean.

Anything wrong stops the import before the commit, so the database is left
as it was. Problems and warnings name tables, ids, keys and references.
They never print a value.

Placeholders. Only the names the seed's provenance lists (and OWNER) are
replaced. Text such as {{CLIPBOARD}} in a prompt is OWUI's own template
syntax and is left alone.

Modes:
  --seed DIR --secrets FILE   read the files (the tests, and a manual run).
  main(argv, seed_files=..., secrets_text=..., schema_text=...)
                              for a wrapper that sends everything on stdin
                              through `docker compose run -i`, the way the
                              collector runs the exporter.

Exit codes: 0 imported, 1 stopped (problems listed), 2 bad arguments.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import sys
import time
import traceback
from pathlib import Path

SEED_FORMAT = 1
OWNER = 'OWNER'
SECRET_KEY = '$bundle'
DEFAULT_DB = '/app/backend/data/webui.db'
SEEDED_ORDER = ['tool', 'function', 'model', 'skill', 'prompt', 'group', 'group_member', 'access_grant']
SEED_FILES = sorted(['config', 'provenance', 'secret_refs', 'user_settings'] + SEEDED_ORDER)
PLACEHOLDER = re.compile(r'\{\{([A-Z][A-Z0-9_]*)\}\}')
BUNDLE = re.compile(r'\{\{BUNDLE:([^{}]+)\}\}')


class Stop(Exception):
    """The import cannot continue; the message lists every problem."""


class Import:
    def __init__(self, schema: dict, seed: dict, secrets: dict, endpoints: dict[str, str], encrypt=None):
        self.schema = schema
        self.seed = seed
        self.secrets = secrets
        self.endpoints = dict(endpoints)
        self.encrypt = encrypt or (lambda valves: valves)
        self.problems: list[str] = []
        self.warnings: list[str] = []
        self.used: set[str] = set()
        self.admin_id: str | None = None
        self.listed: set[str] = set()

    # ---- values ---------------------------------------------------------

    def render(self, text: str, ref: str) -> str:
        # Embedded secrets first: their text can hold an address placeholder,
        # which the step below then renders like any other.
        def put(m):
            name = m.group(1)
            value = self.secrets.get(name)
            if not isinstance(value, str):
                self.problems.append(f'{ref}: {{{{BUNDLE:{name}}}}} has no text value in the secrets file')
                return m.group(0)
            self.used.add(name)
            return value
        if '{{BUNDLE:' in text:
            text = BUNDLE.sub(put, text)

        def swap(m):
            name = m.group(1)
            if name == OWNER:
                return self.admin_id
            if name in self.listed:
                if name not in self.endpoints:
                    self.problems.append(f'{ref}: no value given for {{{{{name}}}}}')
                    return m.group(0)
                return self.endpoints[name]
            return m.group(0)  # OWUI's own template variables stay
        return PLACEHOLDER.sub(swap, text)

    def fill(self, value, ref: str):
        """Secret references become their values; strings are rendered."""
        if isinstance(value, str):
            return self.render(value, ref)
        if isinstance(value, list):
            return [self.fill(v, f'{ref}/{i}') for i, v in enumerate(value)]
        if isinstance(value, dict):
            if set(value) == {SECRET_KEY}:
                name = value[SECRET_KEY]
                if not isinstance(name, str) or name not in self.secrets:
                    self.problems.append(f'{ref}: secret reference {name} is not in the secrets file')
                    return None
                self.used.add(name)
                return self.render_all(self.secrets[name], ref)
            if SECRET_KEY in value:
                self.problems.append(f'{ref}: a secret reference must be alone in its object')
            return {k: self.fill(v, f'{ref}/{k}') for k, v in value.items()}
        return value

    def render_all(self, value, ref: str):
        """A secret value as kept in the secrets file, with its address and
        owner placeholders rendered for this install."""
        if isinstance(value, str):
            return self.render(value, ref)
        if isinstance(value, list):
            return [self.render_all(v, f'{ref}/{i}') for i, v in enumerate(value)]
        if isinstance(value, dict):
            return {k: self.render_all(v, f'{ref}/{k}') for k, v in value.items()}
        return value

    def column(self, table: str, col: str, cls: str, value, ref: str):
        """The value as OWUI stores it: JSON columns as JSON text."""
        if cls == 'owner':
            if value not in (None, '', '{{OWNER}}'):
                self.problems.append(f'{ref}: owner is not the {{{{OWNER}}}} placeholder')
            return self.admin_id if value == '{{OWNER}}' else value
        if cls == 'safe':
            return self.render(value, ref) if isinstance(value, str) else value
        if cls == 'json':
            return None if value is None else json.dumps(self.fill(value, ref), ensure_ascii=False)
        if cls == 'valves':
            if value in (None, ''):
                return None if value is None else json.dumps(value)
            filled = self.fill(value, ref)
            return json.dumps(self.encrypt(filled), ensure_ascii=False)
        self.problems.append(f'schema: column {table}.{col} has class {cls}, which the seed cannot hold')
        return None

    # ---- the run --------------------------------------------------------

    def run(self, db: sqlite3.Connection, version: str) -> dict:
        seed, schema = self.seed, self.schema
        prov = seed['provenance']
        if prov.get('seed_format') != SEED_FORMAT:
            raise Stop(f'seed format {prov.get("seed_format")} is not {SEED_FORMAT}')
        if version != prov.get('owui_version'):
            raise Stop(f'OWUI version is {version}, the seed is from {prov.get("owui_version")} (C-40)')
        if schema.get('owui_version') != prov.get('owui_version') or schema.get('alembic_revision') != prov.get('alembic_revision'):
            raise Stop('schema.json and the seed are for different OWUI versions')
        self.listed = set(prov.get('endpoints') or [])
        missing = sorted(self.listed - set(self.endpoints))
        if missing:
            self.warnings.append('no value given for ' + ', '.join(missing) + '; the import stops only where the seed uses one')
        listed_refs = set(seed['secret_refs'])
        if listed_refs != set(self.secrets):
            for ref in sorted(listed_refs - set(self.secrets)):
                self.problems.append(f'secret reference {ref} is listed by the seed but not in the secrets file')
            for ref in sorted(set(self.secrets) - listed_refs):
                self.warnings.append(f'secret reference {ref} is in the secrets file but the seed does not list it')

        db.execute('BEGIN IMMEDIATE')  # one write transaction: all of it or none of it
        try:
            names = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
            revision = None
            if 'alembic_version' in names:
                revision = (db.execute('SELECT version_num FROM alembic_version').fetchone() or [None])[0]
            if revision != prov.get('alembic_revision'):
                raise Stop(f'Alembic revision is {revision}, the seed is from {prov.get("alembic_revision")} (C-40)')

            admins = [r[0] for r in db.execute('SELECT id FROM "user" WHERE role = \'admin\'')]
            if len(admins) != 1:
                raise Stop(f'expected exactly one admin user (the new account), found {len(admins)}')
            self.admin_id = admins[0]

            tables = schema['tables']
            for table in SEEDED_ORDER:
                if table not in names:
                    self.problems.append(f'table {table} is not in the database')
                    continue
                have = db.execute(f'SELECT COUNT(*) FROM "{table}"').fetchone()[0]
                if have:
                    self.problems.append(f'table {table} already has {have} row(s); the seed goes into a fresh install only')
            if self.problems:
                raise Stop('')

            counts = {}
            for table in SEEDED_ORDER:
                spec = tables[table]
                cols = {r[1] for r in db.execute(f'PRAGMA table_info("{table}")')}
                rows = seed[table]
                for row in rows:
                    rid = str(row.get('id'))
                    out = {}
                    for col, value in row.items():
                        cls = spec['columns'].get(col)
                        ref = f'{table}/{rid}/{col}'
                        if cls is None or cls == 'excluded':
                            self.problems.append(f'{ref}: column is not seeded in schema.json')
                            continue
                        if col not in cols:
                            self.problems.append(f'{ref}: column is not in the database')
                            continue
                        out[col] = self.column(table, col, cls, value, ref)
                    if table == 'access_grant' and out.get('principal_type') == 'user' and out.get('principal_id') != self.admin_id:
                        self.problems.append(f'access_grant/{rid}: granted to a user other than the owner')
                    if self.problems:
                        continue
                    names_sql = ', '.join(f'"{c}"' for c in out)
                    marks = ', '.join('?' for _ in out)
                    db.execute(f'INSERT INTO "{table}" ({names_sql}) VALUES ({marks})', list(out.values()))
                counts[table] = len(rows)

            classes = schema['config']
            now = int(time.time())
            for key, value in seed['config'].items():
                if classes.get(key) not in ('safe', 'secret'):
                    self.problems.append(f'config key {key} is not seeded in schema.json')
                    continue
                db.execute('INSERT INTO config (key, value, updated_at) VALUES (?, ?, ?) '
                           'ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at',
                           (key, json.dumps(self.fill(value, f'config/{key}'), ensure_ascii=False), now))
            counts['config'] = len(seed['config'])

            raw = db.execute('SELECT settings FROM "user" WHERE id = ?', (self.admin_id,)).fetchone()[0]
            settings = json.loads(raw) if isinstance(raw, str) and raw else (raw or {})
            if not isinstance(settings, dict):
                self.problems.append('user/settings: the new admin\'s settings are not an object')
                settings = {}
            for top, section in seed['user_settings'].items():
                if isinstance(section, dict):
                    target = settings.setdefault(top, {})
                    if not isinstance(target, dict):
                        self.problems.append(f'user_settings/{top}: is not an object in the new install')
                        continue
                    for key, value in section.items():
                        ref = f'user_settings/{top}.{key}'
                        if top in ('tools', 'functions') and key == 'valves' and isinstance(value, dict):
                            target[key] = {vid: self.encrypt(self.fill(v, f'{ref}/{vid}')) if v not in (None, '', {}) else v
                                           for vid, v in value.items()}
                        else:
                            target[key] = self.fill(value, ref)
                else:
                    settings[top] = self.fill(section, f'user_settings/{top}')
            db.execute('UPDATE "user" SET settings = ? WHERE id = ?', (json.dumps(settings, ensure_ascii=False), self.admin_id))

            for ref in sorted(set(self.secrets) - self.used):
                self.warnings.append(f'secret reference {ref} was not used')
            self.check(db, counts, prov.get('counts') or {})
            if self.problems:
                raise Stop('')
            db.execute('COMMIT')
        except BaseException:
            db.execute('ROLLBACK')
            raise
        ok = db.execute('PRAGMA integrity_check').fetchone()[0]
        if ok != 'ok':
            raise Stop('PRAGMA integrity_check is not ok after the import')
        return counts

    def check(self, db: sqlite3.Connection, counts: dict, expected: dict) -> None:
        for table, n in sorted(expected.items()):
            if counts.get(table) != n:
                self.problems.append(f'{table}: the seed promises {n} row(s), {counts.get(table)} were imported')
        for table in SEEDED_ORDER + ['config']:
            cols = [r[1] for r in db.execute(f'PRAGMA table_info("{table}")')]
            for row in db.execute(f'SELECT {", ".join(chr(34) + c + chr(34) for c in cols)} FROM "{table}"'):
                for col, value in zip(cols, row):
                    for mark in ('{{OWNER}}', '{{BUNDLE:'):
                        if isinstance(value, str) and mark in value:
                            self.problems.append(f'{table}/{row[0]}/{col}: still holds {mark}' + ('...}}' if mark == '{{BUNDLE:' else ''))
        settings = db.execute('SELECT settings FROM "user" WHERE id = ?', (self.admin_id,)).fetchone()[0]
        for mark in ('{{OWNER}}', '{{BUNDLE:'):
            if isinstance(settings, str) and mark in settings:
                self.problems.append(f'user/settings: still holds {mark}' + ('...}}' if mark == '{{BUNDLE:' else ''))
        for fk in db.execute('PRAGMA foreign_key_check'):
            self.problems.append(f'foreign key check: table {fk[0]} row {fk[1]} points at a missing {fk[2]}')


# ---- outside world ------------------------------------------------------

def secret_key_from_file() -> None:
    """Find WEBUI_SECRET_KEY the way OWUI's start.sh does (see Export-OwuiSeed.py)."""
    if os.environ.get('WEBUI_SECRET_KEY') or os.environ.get('WEBUI_JWT_SECRET_KEY'):
        return
    key_file = Path.cwd() / '.webui_secret_key'
    if key_file.is_file():
        os.environ['WEBUI_SECRET_KEY'] = key_file.read_text(encoding='utf-8').rstrip('\n')


def load_owui():
    """OWUI's version and its own encrypt_valves, which encrypts only when
    this install has ENABLE_VALVE_ENCRYPTION on, exactly as OWUI would."""
    try:
        from open_webui.env import VERSION
        from open_webui.utils.valves import encrypt_valves
    except SystemExit:
        raise Stop('open_webui stopped while it was imported; is WEBUI_SECRET_KEY set in the container?') from None
    except Exception:
        return None, None
    return VERSION, encrypt_valves


def open_db(path: str) -> sqlite3.Connection:
    url = os.environ.get('DATABASE_URL', '')
    if url and not url.startswith('sqlite'):
        raise Stop('DATABASE_URL is not SQLite; only SQLite is supported')
    p = Path(path)
    if not p.is_file():
        raise Stop(f'database not found: {path}')
    db = sqlite3.connect(str(p), isolation_level=None)
    db.execute('PRAGMA foreign_keys = OFF')  # checked explicitly before the commit
    db.execute('PRAGMA busy_timeout = 5000')
    return db


def read_seed(seed_files: dict[str, str]) -> dict:
    names = sorted(n[:-5] for n in seed_files if n.endswith('.json'))
    if names != SEED_FILES:
        raise Stop('the seed does not have the expected files: ' + ', '.join(sorted(set(SEED_FILES) ^ set(names))))
    try:
        return {name[:-5]: json.loads(text) for name, text in seed_files.items()}
    except ValueError as err:
        raise Stop(f'a seed file is not valid JSON (line {getattr(err, "lineno", "?")})') from None


def read_secrets(text: str) -> dict:
    try:
        doc = json.loads(text)
    except ValueError:
        raise Stop('the secrets file is not valid JSON') from None
    if not isinstance(doc, dict) or doc.get('owui_seed_secrets') != SEED_FORMAT or not isinstance(doc.get('refs'), dict):
        raise Stop('the secrets file is not an OWUI seed secrets file')
    return doc['refs']


def main(argv: list[str] | None = None, seed_files: dict | None = None, secrets_text: str | None = None,
         schema_text: str | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--schema', help='manifests/owui-seed/schema.json')
    ap.add_argument('--seed', help='the seed folder (manifests/owui-seed/seed)')
    ap.add_argument('--secrets', help='the folder-03 secrets file from the bundle')
    ap.add_argument('--db', default=DEFAULT_DB)
    ap.add_argument('--endpoint', action='append', default=[], metavar='NAME=VALUE',
                    help='the new value for {{NAME}}, e.g. PC_TS_IP=<the new PC tailnet IP>')
    ap.add_argument('--owui-version', help='only when open_webui cannot be imported (tests)')
    args = ap.parse_args(argv)

    if bool(args.schema) == (schema_text is not None):
        ap.error('give the schema once: --schema, or schema_text from the caller')
    if bool(args.seed) == (seed_files is not None) or bool(args.secrets) == (secrets_text is not None):
        ap.error('give the seed and the secrets once each: as files, or from the caller')
    endpoints = {}
    for item in args.endpoint:
        name, sep, value = item.partition('=')
        if not sep or not re.fullmatch(r'[A-Z][A-Z0-9_]*', name) or name == OWNER or not value:
            ap.error(f'--endpoint must be NAME=VALUE with an upper-case NAME other than OWNER: {name or item[:20]}')
        endpoints[name] = value

    try:
        schema = json.loads(schema_text if schema_text is not None else Path(args.schema).read_text(encoding='utf-8'))
        if seed_files is None:
            seed_files = {p.name: p.read_text(encoding='utf-8') for p in Path(args.seed).glob('*.json')}
        if secrets_text is None:
            secrets_text = Path(args.secrets).read_text(encoding='utf-8')
        seed = read_seed(seed_files)
        secrets = read_secrets(secrets_text)
        secret_key_from_file()
        version, encrypt = load_owui()
        version = version or args.owui_version
        if not version:
            raise Stop('OWUI version unknown: open_webui is not importable and --owui-version was not given')
        job = Import(schema, seed, secrets, endpoints, encrypt)
        try:
            counts = job.run(open_db(args.db), version)
        except Stop as stop:
            if str(stop):
                job.problems.insert(0, str(stop))
            raise Stop('\n'.join(f'PROBLEM {p}' for p in job.problems)) from None
        finally:
            for w in job.warnings:
                print(f'WARN    {w}')
        print('OK      seed imported: ' + ', '.join(f'{k} {v}' for k, v in counts.items())
              + f'; {len(job.used)} secret reference(s) filled; owner is the new admin')
        return 0
    except sqlite3.Error as err:
        print(f'PROBLEM database: {type(err).__name__}: {err}')
        print('STOPPED nothing was written')
        return 1
    except Stop as stop:
        text = str(stop)
        print(text if text.startswith('PROBLEM') else f'PROBLEM {text}')
        print('STOPPED nothing was written')
        return 1
    except Exception as err:
        frame = traceback.extract_tb(err.__traceback__)[-1]
        print(f'PROBLEM unexpected {type(err).__name__} at {Path(frame.filename).name} line {frame.lineno}')
        print('STOPPED nothing was written')
        return 1


if __name__ == '__main__':
    sys.exit(main())
