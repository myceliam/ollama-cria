#!/usr/bin/env python3
"""Export Open WebUI's functional seed (RESTORE.md Stage 7d, R-17).

Runs inside the OWUI container, where OWUI's own Valve codec can be imported.
It reads webui.db in one read-only transaction and produces:

  * the seed: repo-safe JSON, one file per table, with no secrets and no
    ciphertext. Owner ids become "{{OWNER}}", tailnet addresses become the
    placeholders given with --endpoint, and every secret becomes a reference
    {"$bundle": "<ref>"}. A secret value that also turns up inside other
    text (a tool's source code with the key as a Valve default, a ComfyUI
    workflow) is swapped there for {{BUNDLE:embedded/<ref>}}, so the
    importer can put the exact text back.
  * the secrets: {ref: value} for bundle folder 03, with tailnet addresses
    and the admin id templated the same way. Never commit these.

The export stops, and writes nothing, when:

  * the OWUI version or Alembic revision differs from schema.json (C-40);
  * a table, a column or a config key is not classified in schema.json (C-41);
  * an encrypted Valve cannot be decrypted with OWUI's own codec (C-39);
  * a seeded row belongs to a user other than the single admin (an access
    grant to another account is left out with a warning instead: that
    account will not exist on the new install);
  * a string already holds placeholder text the seed uses ({{OWNER}},
    {{BUNDLE:...}} or an --endpoint name), so it could not come back exactly;
  * anything secret-shaped, any ciphertext, any secret value (or its base64,
    hex or URL-encoded form), a credential in a URL, or any tailnet address
    is left in the seed after classification.

Inside JSON columns, Valves, config and user settings, a value also becomes a
reference when its name holds a credential word (api_key, future_auth_blob),
when it is a URL with a password or a credential in its query, when it is one
opaque token that looks generated (mixed case and digits), or when it is JSON
text holding any of these. Moving a harmless value is cheap (the importer puts
it back); leaving a credential is not. No rule can prove that free text (tool
code, prompts) holds no encoded credential, so the seed is still reviewed
before it is committed.

Problems and warnings name tables, ids, keys and paths, and never a value. A
name read from the database is shown only when it looks like an ordinary name;
otherwise it is shown as #<12 hex characters of its SHA-256>, since a key or
an id could itself be a credential.

Modes:
  --stdout                 one line of JSON on stdout,
                           {"seed": {file name: text}, "secrets_file": text},
                           for tools/Collect-StackSecrets.ps1, which runs this
                           with `docker exec -i` so nothing is written inside
                           the container. "secrets_file" is the exact text of
                           the folder-03 secrets file. The line is pure ASCII
                           (JSON unicode escapes), so no code page can change it.
                           Everything else, OWUI's own log lines included, goes
                           to stderr. The collector passes the script and the
                           schema on stdin and calls main(argv, schema_text=...)
                           so neither has to exist inside the container.
  --seed-out DIR --secrets-out FILE
                           write files. DIR must not exist or be empty; FILE
                           must not exist; the folders holding both must
                           exist. The seed is written in full in a staging
                           folder beside DIR and renamed into place last, and
                           a failure removes everything this run made. FILE
                           is created owner-only (mode 0600), so this mode is
                           refused on Windows, where that mode would not make
                           an owner-only file. Used by the tests on Linux and
                           macOS.

Exit codes: 0 exported, 1 stopped (problems listed), 2 bad arguments.

Uses only the standard library, plus open_webui.utils.valves when a Valve is
encrypted.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import shutil
import sqlite3
import sys
import tempfile
import traceback
import urllib.parse
from pathlib import Path

SEED_FORMAT = 1
OWNER = '{{OWNER}}'
SECRET_KEY = '$bundle'
BUNDLE_MARK = '{{BUNDLE:%s}}'
EMBEDDED = 'embedded/'
PLACEHOLDER = re.compile(r'\{\{(BUNDLE:[^{}]*|[A-Z][A-Z0-9_]*)\}\}')
IPV4 = re.compile(r'[0-9]{1,3}(\.[0-9]{1,3}){3}')
DEFAULT_DB = '/app/backend/data/webui.db'

# A name that holds a credential. Only a non-empty string, list or object
# under such a name is treated as a secret; numbers and booleans never are
# (max_tokens, enable_api_keys).
SECRET_NAME = re.compile(
    r'(?i)(^|[._\-])'
    r'(api_?keys?|keys?|tokens?|auth_?token|secrets?|client_?secret|passwords?|'
    r'passwd|passphrase|credentials?|cookies?|bearer|private_?key|access_?key|'
    r'secret_?key|subscription_?key|app_?password|webhook_?url|headers|authorization)$'
)


# A credential word anywhere in a name (future_auth_blob, keyMaterial) makes
# it secret, unless the last word says the value is about the credential, not
# the credential itself (auth_type, api_key_header, max_tokens_hint).
SECRET_WORDS = {
    'key', 'keys', 'apikey', 'apikeys', 'token', 'tokens', 'secret', 'secrets', 'password', 'passwords',
    'passwd', 'pwd', 'passphrase', 'credential', 'credentials', 'cookie', 'cookies', 'bearer', 'auth',
    'authorization', 'headers', 'webhook', 'pat', 'sk',
}
LOCATOR_WORDS = {
    'type', 'types', 'mode', 'method', 'methods', 'enabled', 'enable', 'disabled', 'name', 'names', 'id', 'ids',
    'url', 'urls', 'uri', 'endpoint', 'header', 'count', 'limit', 'length', 'size', 'hint', 'prefix', 'format',
    'provider', 'scope', 'scopes', 'version', 'path', 'file', 'dir', 'env', 'var', 'required', 'configured',
    'present', 'expires', 'expiry', 'ttl', 'timeout', 'location', 'field', 'label', 'placeholder',
    'description', 'title', 'help',
}


# max_tokens, num_keys: a number of something, not the thing.
COUNT_WORDS = {'max', 'min', 'num', 'total', 'n'}


def secret_name(name: str) -> bool:
    """True for apiKey, API_KEY, auth.token, future_auth_blob; false for
    monkeys, max_tokens_hint or auth_type."""
    snake = re.sub(r'(?<=[a-z0-9])(?=[A-Z])', '_', str(name))
    words = [w for w in re.split(r'[^a-z0-9]+', snake.lower()) if w]
    if len(words) > 1 and words[0] in COUNT_WORDS:
        return False
    if SECRET_NAME.search(snake) or 'webhook' in words:
        return True
    return bool(words) and any(w in SECRET_WORDS for w in words) and words[-1] not in LOCATOR_WORDS


UUID = re.compile(r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
FILE_NAME = re.compile(r'(?i).*\.(safetensors|ckpt|pt|pth|bin|gguf|onnx|json|ya?ml|py|txt|md|png|jpe?g|webp|gif|svg|html?|js|css)')


def name_part(part: str) -> bool:
    """A word or a short code, as in DeepSeek-R1-Distill-Qwen-14B: a number
    with a unit (14B), a code (R1, Q4), up to three characters, or letters
    whose lower-case runs are all two or more long (DeepSeek, GGUF), with up
    to three digits after them (Qwen2). Generated text rarely splits this way."""
    if len(part) <= 3 or re.fullmatch(r'[0-9]+[A-Za-z]{0,2}|[A-Za-z]{1,2}[0-9]{1,3}[A-Za-z]?', part):
        return True
    m = re.fullmatch(r'([A-Za-z]+)[0-9]{0,3}', part)
    return bool(m) and all(len(run) >= 2 for run in re.findall(r'[a-z]+', m.group(1)))


def opaque(text: str) -> bool:
    """One token that looks generated: 24 or more characters of a key
    alphabet with mixed case and digits, and not an id, a hex digest, a file
    name or a name made of words and short codes (a model name). Bare hex and
    lower-case-only tokens are not caught."""
    if len(text) < 24 or not re.fullmatch(r'[A-Za-z0-9_\-+/=.~]+', text):
        return False
    if UUID.fullmatch(text) or re.fullmatch(r'[0-9a-fA-F]+', text) or FILE_NAME.fullmatch(text):
        return False
    if all(name_part(p) for p in re.split(r'[-_.~+/=]+', text) if p):
        return False
    return (sum(c.isdigit() for c in text) >= 2 and sum(c.isupper() for c in text) >= 2
            and sum(c.islower() for c in text) >= 2)


# A URL query parameter that carries a credential (?token=..., &sig=...).
# The value must look real: {name}, ${VAR}, ALL_CAPS and "your..." are
# placeholders in code or docs.
QUERY_PARAM = re.compile(r'[?&;]([A-Za-z0-9_.\-]{1,40})=([^&#\s"\'<>]{8,})')
PLACEHOLDER_VALUE = re.compile(r'^(\{[^{}]*\}|\$\{?[A-Za-z_][A-Za-z0-9_]*\}?|%7[Bb].*%7[Dd]|[A-Z][A-Z0-9]*(_[A-Z0-9]+)+|[A-Z]{1,20})$'
                               r'|(?i:your|xxx|example|placeholder|\.\.\.)')
URL_LOGIN = re.compile(r'[a-z][a-z0-9+.-]{0,31}://[^/\s:@\'"]+:[^/\s@\'"]+@')


def credential_url(text: str) -> bool:
    if URL_LOGIN.search(text):
        return True
    for m in QUERY_PARAM.finditer(text):
        name, value = m.group(1), m.group(2)
        if (secret_name(name) or name.lower() in ('sig', 'signature')) and not PLACEHOLDER_VALUE.search(value):
            return True
    return False


# Secret shapes, in step with tools/Test-NoSecrets.ps1, plus OWUI's own
# Fernet ciphertext (encrypted Valves start with gAAAAA).
SHAPES = [
    ('private key block', r'-----BEGIN [A-Z ]*PRIVATE KEY-----'),
    ('API key (sk-)', r'\bsk-[A-Za-z0-9_-]{20,}'),
    ('Groq key', r'\bgsk_[A-Za-z0-9]{20,}'),
    ('GitHub token', r'\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}|\bgithub_pat_[A-Za-z0-9_]{30,}'),
    ('Google API key', r'\bAIza[0-9A-Za-z_-]{35}'),
    ('Google OAuth token', r'\bya29\.[0-9A-Za-z_-]{20,}|\b1//0[0-9A-Za-z_-]{20,}'),
    ('Google OAuth client secret', r'\bGOCSPX-[0-9A-Za-z_-]{20,}'),
    ('Hugging Face token', r'\bhf_[A-Za-z0-9]{30,}'),
    ('ntfy access token', r'\btk_[A-Za-z0-9]{24,}'),
    ('Brave Search key', r'\bBSA[0-9A-Za-z_-]{20,}'),
    ('AWS access key', r'\bAKIA[0-9A-Z]{16}\b'),
    ('Slack token', r'\bxox[abprs]-[0-9A-Za-z-]{10,}'),
    ('JWT', r'\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'),
    ('Discord webhook URL', r'discord(app)?\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]{20,}'),
    ('password in a URL', r'[a-z][a-z0-9+.-]{0,31}://[^/\s:@\'"]+:[^/\s@\'"]+@'),
    ('bearer token', r'(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{20,}'),
    ('Fernet ciphertext (encrypted Valves)', r'\bgAAAAA[A-Za-z0-9_-]{40,}'),
    # 100.100.100.100 and fd7a:115c:a1e0::53 are Tailscale's own service
    # address (the MagicDNS resolver), the same in every tailnet, so they pass.
    ('tailnet IP', r'\b(?!100\.100\.100\.100\b)100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}\b'),
    ('tailnet IPv6 address', r'(?i)\b(?!fd7a:115c:a1e0::53\b)fd7a:115c:a1e0:[0-9a-f]{0,4}:'),
    ('MagicDNS name', r'(?i)\b[a-z0-9-]{1,63}\.[a-z0-9-]{1,63}\.ts\.net\b'),
]
SHAPES = [(name, re.compile(rx)) for name, rx in SHAPES]

# A home-network or Docker address is not a secret, but AGENTS.md keeps
# private addresses out of the repo, so each one is named in a warning.
LAN_ADDRESS = re.compile(r'\b(10\.[0-9]{1,3}|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}\b')

COLUMN_CLASSES = {'safe', 'json', 'owner', 'valves', 'excluded'}
SEEDED_ORDER = ['tool', 'function', 'model', 'skill', 'prompt', 'group', 'group_member', 'access_grant']
GRANT_RESOURCES = {'tool', 'function', 'model', 'skill', 'prompt'}


class Stop(Exception):
    """The export cannot continue; the message lists every problem."""

    def __init__(self, message: str = '', left: bool = False):
        super().__init__(message)
        self.left = left  # True when some output may remain on disk


class Export:
    def __init__(self, schema: dict, endpoints: dict[str, str], codec=None):
        self.schema = schema
        self.endpoints = sorted(endpoints.items(), key=lambda kv: -len(kv[1]))
        self.codec = codec
        self.problems: list[str] = []
        self.warnings: list[str] = []
        self.secrets: dict[str, object] = {}
        self.raw_secrets: dict[str, object] = {}
        self.admin_id: str | None = None
        self.patterns: dict[str, re.Pattern] = {}

    # ---- names in messages ----------------------------------------------

    def name(self, text) -> str:
        """A name read from the database, as it may be printed: itself when it
        looks like an ordinary name, else #<hash>. A key, an id or a revision
        could itself be a credential."""
        s = str(text)
        if (re.fullmatch(r'[A-Za-z0-9_.:@+-]{1,64}', s)
                and all(len(p) <= 24 for p in re.split(r'[._:@+-]', s))
                and not any(rx.search(s) for _, rx in SHAPES)
                and not opaque(s)
                and not any(v in s for v in self.known_values())):
            return s
        return '#' + hashlib.sha256(s.encode('utf-8', 'surrogatepass')).hexdigest()[:12]

    def where(self, ref: str) -> str:
        """A path such as tool/<id>/valves/<key>, each part shown by name()."""
        return '/'.join(p if p == '' else self.name(p) for p in str(ref).split('/'))

    def known_values(self) -> list[str]:
        return [v for _, v in self.secret_texts(self.raw_secrets)]

    # ---- values ---------------------------------------------------------

    def template(self, text: str, ref: str) -> str:
        if '{{' in text:
            names = {name for name, _ in self.endpoints} | {'OWNER'}
            for m in PLACEHOLDER.finditer(text):
                name = m.group(1)
                if name in names or name.startswith('BUNDLE:'):
                    shown = '{{BUNDLE:...}}' if name.startswith('BUNDLE:') else '{{%s}}' % name
                    self.problems.append(f'{self.where(ref)}: already holds the placeholder text {shown}, so it could not be restored exactly')
                    break
        for name, value in self.endpoints:
            if value in text:
                text = self.pattern(value).sub(lambda _m, n=name: '{{%s}}' % n, text)
        return text

    def pattern(self, value: str) -> re.Pattern:
        """Where a value counts as itself: an address ending .1 is not the
        start of one ending .15, and pc.<tailnet> is not the end of
        mypc.<tailnet>, so a neighbouring address is never half-replaced (and
        is still caught by the final scan). A name may follow a dot:
        x.{{TS_DOMAIN}}."""
        rx = self.patterns.get(value)
        if rx is None:
            v = re.escape(value)
            if IPV4.fullmatch(value):
                rx = re.compile(r'(?<![0-9.])' + v + r'(?![0-9]|\.[0-9])')
            elif ':' in value:
                rx = re.compile(r'(?<![0-9A-Fa-f:])' + v + r'(?![0-9A-Fa-f:])')
            else:
                rx = re.compile(r'(?<![A-Za-z0-9_-])' + v + r'(?![A-Za-z0-9_-])')
            self.patterns[value] = rx
        return rx

    def add_secret(self, ref: str, value) -> dict:
        """The secrets file keeps the value with its addresses templated too
        (a token in a URL to the PC), so a restore onto new addresses renders
        it like the seed. The value as found is kept for the final scan."""
        if ref in self.secrets:
            self.problems.append(f'secret reference {self.where(ref)} is produced twice')
        self.raw_secrets[ref] = value
        self.secrets[ref] = self.template_all(value, ref)
        return {SECRET_KEY: ref}

    def template_all(self, value, ref: str):
        if isinstance(value, str):
            return self.template(value, ref)
        if isinstance(value, list):
            return [self.template_all(v, f'{ref}/{i}') for i, v in enumerate(value)]
        if isinstance(value, dict):
            return {k: self.template_all(v, f'{ref}/{k}') for k, v in value.items()}
        return value

    @staticmethod
    def is_empty(value) -> bool:
        if value is None or value == '' or value == [] or value == {}:
            return True
        if isinstance(value, list):
            return all(v in (None, '') for v in value)
        return False

    @staticmethod
    def secret_shaped(value) -> bool:
        return isinstance(value, (str, list, dict)) and not Export.is_empty(value)

    def credential_like(self, text: str, depth: int = 0) -> bool:
        """A string that is, or holds, a credential by the rules in the module
        notes: a URL with a login or a credential query, one opaque token, or
        JSON text with a secret-named field or any of these inside."""
        if credential_url(text) or opaque(text.strip()):
            return True
        stripped = text.lstrip()
        if stripped[:1] in ('{', '[') and len(text) <= 1_000_000:
            try:
                parsed = json.loads(text)
            except (ValueError, RecursionError):
                return False
            return self.holds_secret(parsed, depth + 1)
        return False

    def holds_secret(self, value, depth: int = 0) -> bool:
        if depth > 32:
            return True  # too deep to judge: treat it as a secret
        if isinstance(value, dict):
            return any((secret_name(k) and self.secret_shaped(v)) or self.holds_secret(v, depth + 1)
                       for k, v in value.items())
        if isinstance(value, list):
            return any(self.holds_secret(v, depth + 1) for v in value)
        if isinstance(value, str):
            return self.credential_like(value, depth + 1)
        return False

    def string(self, text: str, ref: str):
        """A string inside JSON, Valves, config or user settings: a reference
        when it is credential-like, else the text with addresses templated."""
        if self.credential_like(text):
            return self.add_secret(ref, text)
        return self.template(text, ref)

    def clean(self, value, ref: str, overrides: dict | None = None):
        """Template strings and move secret-named fields and credential-like
        strings to references."""
        if isinstance(value, str):
            return self.string(value, ref)
        if isinstance(value, list):
            return [self.clean(v, f'{ref}/{i}') for i, v in enumerate(value)]
        if isinstance(value, dict):
            if SECRET_KEY in value:
                self.problems.append(f'{self.where(ref)}: holds the reserved key "{SECRET_KEY}"')
            out = {}
            for key in sorted(value):
                item = value[key]
                child = f'{ref}/{key}'
                rule = (overrides or {}).get(key)
                if rule not in (None, 'safe', 'secret'):
                    self.problems.append(f'schema: override for {self.where(child)} must be "safe" or "secret"')
                if rule == 'secret' or (rule is None and secret_name(key) and self.secret_shaped(item)):
                    out[key] = item if self.is_empty(item) else self.add_secret(child, item)
                elif rule == 'safe' and isinstance(item, str):
                    out[key] = self.template(item, child)  # reviewed in schema.json
                else:
                    out[key] = self.clean(item, child)
            return out
        return value

    def valves(self, raw, ref: str, overrides: dict | None):
        if raw in (None, '', {}):
            return raw
        if isinstance(raw, str):
            try:
                parsed = json.loads(raw)
            except ValueError:
                parsed = None
            if isinstance(parsed, dict):
                raw = parsed
            elif self.codec is None:
                self.problems.append(f'{self.where(ref)}: encrypted, and OWUI\'s Valve codec could not be loaded')
                return None
            else:
                try:
                    raw = self.codec(raw)
                except Exception as err:  # any codec failure stops the export (C-39)
                    self.problems.append(f'{self.where(ref)}: could not be decrypted with OWUI\'s codec ({type(err).__name__})')
                    return None
                if not isinstance(raw, dict):
                    self.problems.append(f'{self.where(ref)}: decrypted to {type(raw).__name__}, not an object')
                    return None
        if not isinstance(raw, dict):
            self.problems.append(f'{self.where(ref)}: is {type(raw).__name__}, not an object')
            return None
        return self.clean(raw, ref, overrides or {})

    # ---- tables ---------------------------------------------------------

    def owner(self, value, ref: str):
        if value in (None, ''):
            return value
        if value != self.admin_id:
            self.problems.append(f'{self.where(ref)}: belongs to a user other than the admin')
            return value
        return OWNER

    def row(self, table: str, spec: dict, row: dict) -> dict:
        rid = str(row.get('id'))
        out = {}
        for col, cls in spec['columns'].items():
            if cls == 'excluded' or col not in row:
                continue
            value = row[col]
            ref = f'{table}/{rid}/{col}'
            if cls == 'owner':
                out[col] = self.owner(value, ref)
            elif cls == 'safe':
                out[col] = self.template(value, ref) if isinstance(value, str) else value
            elif cls == 'json':
                out[col] = self.clean(self.parse(value, ref), ref)
            elif cls == 'valves':
                key = f'{table}:{rid}'
                out[col] = self.valves(self.parse(value, ref, keep_text=True), f'{table}/{rid}/valves',
                                       self.schema.get('valves', {}).get(key))
        return out

    def parse(self, value, ref: str, keep_text: bool = False):
        if not isinstance(value, str):
            return value
        try:
            return json.loads(value)
        except ValueError:
            if keep_text:
                return value
            self.problems.append(f'{self.where(ref)}: is not valid JSON')
            return None

    def user_settings(self, raw) -> dict:
        settings = self.parse(raw, 'user/settings') or {}
        if not isinstance(settings, dict):
            self.problems.append('user/settings: is not an object')
            return {}
        allow = self.schema['user_settings']
        out: dict = {}
        dropped = []
        for top in sorted(settings):
            section = settings[top]
            if top in ('tools', 'functions') and isinstance(section, dict):
                for key in sorted(section):
                    path = f'{top}.{key}'
                    cls = allow.get(path)
                    if cls == 'valves' and isinstance(section[key], dict):
                        kind = top[:-1]
                        out.setdefault(top, {})[key] = {
                            vid: self.valves(v, f'user_settings/{path}/{vid}',
                                             self.schema.get('valves', {}).get(f'user:{kind}:{vid}'))
                            for vid, v in sorted(section[key].items())
                        }
                    elif cls in ('safe', 'valves'):
                        out.setdefault(top, {})[key] = self.clean(section[key], f'user_settings/{path}')
                    else:
                        dropped.append(f'{top}.{self.name(key)}')
            elif isinstance(section, dict):
                for key in sorted(section):
                    path = f'{top}.{key}'
                    if allow.get(path) == 'safe':
                        out.setdefault(top, {})[key] = self.clean(section[key], f'user_settings/{path}')
                    else:
                        dropped.append(f'{self.name(top)}.{self.name(key)}')
            elif allow.get(top) == 'safe':
                out[top] = self.clean(section, f'user_settings/{top}')
            else:
                dropped.append(self.name(top))
        if dropped:
            self.warnings.append('user settings not in the projection, left out: ' + ', '.join(dropped))
        return out

    def config(self, rows: list[dict]) -> dict:
        classes = self.schema['config']
        out = {}
        for r in rows:
            key = r['key']
            cls = classes.get(key)
            value = self.parse(r['value'], f'config/{key}')
            if cls is None:
                self.problems.append(f'config key {self.name(key)} is not classified in schema.json')
            elif cls == 'secret':
                out[key] = value if not self.secret_shaped(value) else self.add_secret(f'config/{key}', value)
            elif cls == 'safe':
                out[key] = self.clean(value, f'config/{key}')
            elif cls != 'excluded':
                self.problems.append(f'schema: config key {self.name(key)} has unknown class {cls}')
        return out

    # ---- the run --------------------------------------------------------

    def run(self, db: sqlite3.Connection, version: str, image_digest: str | None) -> dict:
        schema = self.schema
        if version != schema['owui_version']:
            raise Stop(f'OWUI version is {self.name(version)}, schema.json is for {schema["owui_version"]} (C-40)')

        db.execute('BEGIN')  # one read transaction: every read below sees one snapshot
        try:
            names = [r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")]
            revision = None
            if 'alembic_version' in names:
                revision = (db.execute('SELECT version_num FROM alembic_version').fetchone() or [None])[0]
            if revision != schema['alembic_revision']:
                raise Stop(f'Alembic revision is {self.name(revision)}, schema.json is for {schema["alembic_revision"]} (C-40)')

            tables = schema['tables']
            for name in sorted(names):
                if name not in tables:
                    self.problems.append(f'table {self.name(name)} is not classified in schema.json')
            for name, spec in tables.items():
                if not isinstance(spec, dict):
                    if spec not in ('excluded', 'special'):
                        self.problems.append(f'schema: table {name} has unknown class {spec}')
                    elif spec == 'special' and name not in names:
                        self.problems.append(f'table {name} is in schema.json but not in the database')
                    continue
                if name not in names:
                    self.problems.append(f'table {name} is in schema.json but not in the database')
                    continue
                cols = [r[1] for r in db.execute(f'PRAGMA table_info("{name}")')]
                for col in cols:
                    if col not in spec['columns'] and not spec.get('other_columns') == 'excluded':
                        self.problems.append(f'column {name}.{self.name(col)} is not classified in schema.json')
                for col, cls in spec['columns'].items():
                    if cls not in COLUMN_CLASSES:
                        self.problems.append(f'schema: column {name}.{col} has unknown class {cls}')
                    elif col not in cols:
                        self.problems.append(f'column {name}.{col} is in schema.json but not in the database')
            if self.problems:
                raise Stop('')

            db.row_factory = sqlite3.Row
            admins = [dict(r) for r in db.execute('SELECT id, settings FROM "user" WHERE role = \'admin\'')]
            if len(admins) != 1:
                raise Stop(f'expected exactly one admin user, found {len(admins)}')
            self.admin_id = admins[0]['id']
            endpoint_names = sorted(name for name, _ in self.endpoints)
            # The admin's id also turns up inside data (ntfy_push's only_user_ids,
            # for one); every copy becomes the owner placeholder (C-38).
            self.endpoints = sorted(self.endpoints + [('OWNER', str(self.admin_id))], key=lambda kv: -len(kv[1]))

            seed: dict[str, object] = {}
            seed['config'] = self.config([dict(r) for r in db.execute('SELECT key, value FROM config ORDER BY key')])

            excluded = schema.get('exclude_rows', {})
            seeded_ids: dict[str, set] = {}
            for table in SEEDED_ORDER:
                if table == 'access_grant':
                    continue
                spec = tables[table]
                rows = [dict(r) for r in db.execute(f'SELECT * FROM "{table}" ORDER BY id')]
                skip = set(excluded.get(table, []))
                kept = [r for r in rows if r['id'] not in skip]
                for gone in sorted(skip - {r['id'] for r in rows}):
                    self.warnings.append(f'{table} {gone} is excluded in schema.json but not in the database')
                seeded_ids[table] = {r['id'] for r in kept}
                seed[table] = [self.row(table, spec, r) for r in kept]
                expected = schema.get('expected_ids', {}).get(table)
                if expected is not None:
                    have = seeded_ids[table]
                    for missing in sorted(set(expected) - have):
                        self.warnings.append(f'{table} {missing} is expected but not in the database')
                    for extra in sorted(have - set(expected)):
                        self.warnings.append(f'{table} {self.name(extra)} is new (not in expected_ids); it is exported')

            for m in seed['group_member']:
                if m.get('group_id') not in seeded_ids['group']:
                    self.problems.append(f'group_member/{self.name(m.get("id"))}: its group is not in the seed')

            accounts = {r[0] for r in db.execute('SELECT id FROM "user"')}
            grants, dropped, others, gone = [], 0, 0, 0
            for g in (dict(r) for r in db.execute('SELECT * FROM access_grant ORDER BY id')):
                if g['resource_type'] not in GRANT_RESOURCES or g['resource_id'] not in seeded_ids.get(g['resource_type'], set()):
                    dropped += 1
                    continue
                ref = f'access_grant/{g["id"]}'
                if g['principal_type'] == 'user' and g['principal_id'] not in (None, '', self.admin_id):
                    # Only the admin account is rebuilt; any other account
                    # signs up afresh with a new id, so its shares are redone.
                    others += 1
                    gone += g['principal_id'] not in accounts
                    continue
                if g['principal_type'] == 'user':
                    pass  # the admin's own grant: its id becomes {{OWNER}} like any other copy
                elif g['principal_type'] == 'group':
                    if g['principal_id'] not in seeded_ids['group']:
                        self.problems.append(f'{self.where(ref)}: its group is not in the seed')
                elif g['principal_type'] != 'anyone':
                    self.problems.append(f'{self.where(ref)}: unknown principal type {self.name(g["principal_type"])}')
                grants.append(self.row('access_grant', tables['access_grant'], g))
            seed['access_grant'] = grants
            if dropped:
                self.warnings.append(f'{dropped} access grant(s) left out: their resource is not in the seed')
            if others:
                self.warnings.append(f'{others} access grant(s) to accounts other than the admin left out '
                                     f'({gone} of them to accounts that no longer exist); share again by hand after a restore')

            seed['user_settings'] = self.user_settings(admins[0]['settings'])
        finally:
            db.rollback()

        self.embed_secrets(seed)

        seed['secret_refs'] = sorted(self.secrets)
        seed['provenance'] = {
            'seed_format': SEED_FORMAT,
            'owui_version': version,
            'alembic_revision': revision,
            'image_digest': image_digest,
            'endpoints': endpoint_names,
            'counts': {t: len(seed[t]) for t in ['config'] + SEEDED_ORDER},
        }
        if not image_digest:
            self.warnings.append('no --image-digest given; provenance records none')

        self.final_scan(seed)
        if self.problems:
            raise Stop('')
        return seed

    def secret_texts(self, source: dict | None = None):
        """(path, text) for every string of 8 or more characters in a secret
        value (as kept in the secrets file, unless another source is given),
        with the path inside the value; shorter ones are too common to look
        for in other text."""
        def walk(value, path):
            if isinstance(value, str):
                if len(value) >= 8:
                    yield path, value
            elif isinstance(value, list):
                for i, v in enumerate(value):
                    yield from walk(v, f'{path}/{i}')
            elif isinstance(value, dict):
                for k, v in sorted(value.items()):
                    yield from walk(v, f'{path}/{k}')
        source = self.secrets if source is None else source
        for ref in sorted(source):
            if not ref.startswith(EMBEDDED):
                yield from walk(source[ref], ref)

    def embed_secrets(self, seed: dict) -> None:
        """Swap each secret value found inside other seed text for
        {{BUNDLE:embedded/<path>}}, and put that value in the secrets file.

        Seed text and the kept secret values have their addresses templated
        alike, so a kept value is what is looked for: the importer fills the
        marker first and then renders the addresses, so the text comes back
        exactly as it was, with the new install's addresses."""
        forms: dict[str, str] = {}
        for path, form in self.secret_texts():
            forms.setdefault(form, EMBEDDED + path)
        if not forms:
            return
        ordered = sorted(forms.items(), key=lambda kv: (-len(kv[0]), kv[1]))
        used: set[str] = set()

        def swap(value):
            if isinstance(value, str):
                for form, ref in ordered:
                    if form in value:
                        value = value.replace(form, BUNDLE_MARK % ref)
                        used.add(ref)
                return value
            if isinstance(value, list):
                return [swap(v) for v in value]
            if isinstance(value, dict):
                if set(value) == {SECRET_KEY}:
                    return value
                return {k: swap(v) for k, v in value.items()}
            return value

        for name in ['config', 'user_settings'] + SEEDED_ORDER:
            if name in seed:
                seed[name] = swap(seed[name])
        for form, ref in ordered:
            if ref in used:
                self.secrets[ref] = form

    def seed_strings(self, seed: dict):
        """Every string in the seed, with rows named by their id."""
        for name, value in seed.items():
            if name in SEEDED_ORDER and isinstance(value, list):
                for i, row in enumerate(value):
                    rid = row.get('id') if isinstance(row, dict) else None
                    yield from self.strings(row, f'/{name}/{rid if isinstance(rid, (str, int)) else i}')
            else:
                yield from self.strings(value, f'/{name}')

    @staticmethod
    def encodings(value: str) -> set[str]:
        """The forms a secret value takes inside other encoded text: base64
        and URL-safe base64 at each of the three byte alignments (only the
        characters that depend on the value alone, so it is found inside a
        longer blob too), hex, and URL-encoding. Forms shorter than 12
        characters are too common to look for."""
        raw = value.encode('utf-8', 'surrogatepass')
        forms = set()
        for shift in range(3):
            n = shift + len(raw)
            start = (8 * shift + 5) // 6          # characters that also hold the bytes before
            end = 4 * (n // 3) + n % 3            # characters that also hold the bytes after
            core = base64.b64encode(b'\0' * shift + raw).decode('ascii')[start:end]
            forms.update({core, core.translate(str.maketrans('+/', '-_'))})
        forms.update({raw.hex(), raw.hex().upper(), urllib.parse.quote(value), urllib.parse.quote(value, safe=''),
                      urllib.parse.quote_plus(value)})
        forms.discard(value)
        return {f for f in forms if len(f) >= 12}

    def final_scan(self, seed: dict) -> None:
        """Nothing secret-shaped, no ciphertext, no secret value or encoded
        form of one, no credential in a URL, no opaque token left in a
        plain column, no tailnet address."""
        found = {v for _, v in self.secret_texts()} | {v for _, v in self.secret_texts(self.raw_secrets)}
        values = sorted(found, key=len, reverse=True)
        encoded = sorted({f for v in found for f in self.encodings(v)}, key=len, reverse=True)
        for path, text in self.seed_strings(seed):
            def shown():
                return 'seed ' + self.where(path)
            if self.admin_id and str(self.admin_id) in text:
                self.problems.append(f'{shown()}: still holds the old admin id')
            for name, rx in SHAPES:
                if rx.search(text):
                    self.problems.append(f'{shown()}: {name} left after classification')
            if credential_url(text) and not URL_LOGIN.search(text):
                self.problems.append(f'{shown()}: a credential in a URL query left after classification')
            if text not in self.secrets and opaque(text.strip()):  # a reference's own name is not a token
                self.problems.append(f'{shown()}: an opaque token left after classification')
            for v in values:
                if v in text:
                    self.problems.append(f'{shown()}: contains the value of a secret reference')
                    break
            else:
                for f in encoded:
                    if f in text:
                        self.problems.append(f'{shown()}: contains an encoded form (base64, hex or URL) of a secret reference\'s value')
                        break
            if LAN_ADDRESS.search(text):
                self.warnings.append(f'{shown()}: holds a private LAN or Docker address; check it belongs in the repo')

    def strings(self, value, path):
        if isinstance(value, str):
            yield path, value
        elif isinstance(value, list):
            for i, v in enumerate(value):
                yield from self.strings(v, f'{path}/{i}')
        elif isinstance(value, dict):
            for k, v in value.items():
                yield path + '/' + str(k), str(k)
                yield from self.strings(v, f'{path}/{k}')


# ---- outside world ------------------------------------------------------

def secret_key_from_file() -> None:
    """Find WEBUI_SECRET_KEY the way OWUI's start.sh does.

    `docker exec` does not run start.sh, which reads the key from
    .webui_secret_key in OWUI's working folder when the environment has none
    and exports it before OWUI starts. Without the same step, importing
    open_webui.env stops the process, or the Valve codec would use another key.
    """
    if os.environ.get('WEBUI_SECRET_KEY') or os.environ.get('WEBUI_JWT_SECRET_KEY'):
        return
    key_file = Path.cwd() / '.webui_secret_key'
    if key_file.is_file():
        # start.sh reads it with $(cat), which drops the trailing newline.
        os.environ['WEBUI_SECRET_KEY'] = key_file.read_text(encoding='utf-8').rstrip('\n')


def load_codec():
    """OWUI's own Valve decryption, with failures raised instead of hidden.

    decrypt_valves() returns {} on a bad token; the export must stop instead,
    so this uses the same key derivation (_fernet) and JSON codec directly.
    """
    try:
        from open_webui.utils import valves as owui_valves
        from open_webui.utils.json_codec import JSONCodec
    except SystemExit:
        raise Stop('open_webui stopped while it was imported; is WEBUI_SECRET_KEY set in the container?') from None
    except Exception:
        return None
    fernet = owui_valves._fernet()
    return lambda token: JSONCodec.loads(fernet.decrypt(token.encode()).decode())


def owui_version() -> str | None:
    try:
        from open_webui.env import VERSION
        return VERSION
    except SystemExit:
        raise Stop('open_webui stopped while it was imported; is WEBUI_SECRET_KEY set in the container?') from None
    except Exception:
        return None


def open_db(path: str) -> sqlite3.Connection:
    url = os.environ.get('DATABASE_URL', '')
    if url and not url.startswith('sqlite'):
        raise Stop('DATABASE_URL is not SQLite; only SQLite is supported')
    p = Path(path)
    if not p.is_file():
        raise Stop('database not found at the --db path')
    db = sqlite3.connect(f'{p.resolve().as_uri()}?mode=ro', uri=True, isolation_level=None)
    db.execute('PRAGMA query_only = ON')
    return db


def dump(value) -> str:
    return json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + '\n'


def seed_files(seed: dict) -> dict[str, str]:
    return {f'{name}.json': dump(value) for name, value in seed.items()}


def write_files(seed: dict, secrets: dict, seed_dir: str, secrets_file: str) -> None:
    """Write the seed folder and the secrets file, or neither.

    The seed is staged in a new folder beside --seed-out and renamed into
    place last; the secrets file is created owner-only with O_EXCL. Any
    failure removes what this run made, and a Stop says whether anything
    could not be removed. Neither parent folder is created here."""
    sd = Path(seed_dir)
    sf = Path(secrets_file)
    if sd.is_symlink() or (sd.exists() and (not sd.is_dir() or any(sd.iterdir()))):
        raise Stop('--seed-out must be a new or empty folder, not a link')
    if os.path.lexists(sf):
        raise Stop('--secrets-out must not exist yet')
    sd_real = os.path.realpath(sd)
    sf_real = os.path.realpath(sf.parent)
    if sf_real == sd_real or sf_real.startswith(sd_real + os.sep):
        raise Stop('--secrets-out must not be inside --seed-out')
    if not sd.parent.is_dir():
        raise Stop('the folder that should hold --seed-out does not exist')
    if not sf.parent.is_dir():
        raise Stop('the folder that should hold --secrets-out does not exist')

    stage = secrets_made = None
    try:
        stage = Path(tempfile.mkdtemp(prefix='.seed-staging-', dir=sd.parent))
        for name, text in seed_files(seed).items():
            with open(stage / name, 'x', encoding='utf-8', newline='\n') as f:
                f.write(text)
        mask = os.umask(0)
        os.umask(mask)
        os.chmod(stage, 0o777 & ~mask)
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, 'O_NOFOLLOW', 0)
        fd = os.open(sf, flags, 0o600)
        secrets_made = sf
        with os.fdopen(fd, 'w', encoding='utf-8', newline='\n') as f:
            f.write(secrets_text(secrets))
            f.flush()
            os.fsync(f.fileno())
        if sd.exists():
            sd.rmdir()  # empty, checked above; rename cannot replace it everywhere
        os.rename(stage, sd)
        stage = None
    except BaseException as err:
        left = []
        if secrets_made is not None:
            try:
                os.unlink(secrets_made)
            except OSError:
                left.append('--secrets-out')
        if stage is not None:
            shutil.rmtree(stage, ignore_errors=True)
            if stage.exists():
                left.append('a .seed-staging- folder beside --seed-out')
        what = 'could not write the output files' if isinstance(err, OSError) else 'stopped while writing the output files'
        if left:
            raise Stop(f'{what} ({type(err).__name__}); could not remove ' + ' and '.join(left), left=True) from None
        raise Stop(f'{what} ({type(err).__name__})') from None


def secrets_text(secrets: dict) -> str:
    return dump({'owui_seed_secrets': SEED_FORMAT, 'refs': secrets})


ON_WINDOWS = os.name == 'nt'


class SafeParser(argparse.ArgumentParser):
    """argparse's own errors quote the argument they could not use, which
    could be a value; this one says only that the arguments were wrong."""

    def error(self, message):
        self.exit(2, 'PROBLEM arguments: not understood; see --help (values are not shown)\nSTOPPED nothing was written\n')

    def refuse(self, message: str):
        """A refusal written here, with no value in it."""
        self.exit(2, f'PROBLEM arguments: {message}\nSTOPPED nothing was written\n')


def main(argv: list[str] | None = None, schema_text: str | None = None) -> int:
    """schema_text: the schema itself, for a caller that has no file to point
    --schema at (the collector, through docker exec)."""
    ap = SafeParser(description=__doc__.split('\n')[0])
    ap.add_argument('--schema', help='manifests/owui-seed/schema.json')
    ap.add_argument('--db', default=DEFAULT_DB)
    ap.add_argument('--endpoint', action='append', default=[], metavar='NAME=VALUE',
                    help='replace VALUE with {{NAME}} everywhere, e.g. PC_TS_IP=<the PC tailnet IP>')
    ap.add_argument('--image-digest')
    ap.add_argument('--owui-version', help='only when open_webui cannot be imported (tests)')
    ap.add_argument('--stdout', action='store_true')
    ap.add_argument('--seed-out')
    ap.add_argument('--secrets-out')
    args = ap.parse_args(argv)

    if args.stdout == bool(args.seed_out or args.secrets_out) or (not args.stdout and not (args.seed_out and args.secrets_out)):
        ap.refuse('use --stdout, or both --seed-out and --secrets-out')
    if not args.stdout and ON_WINDOWS:
        # Python cannot make the secrets file owner-only on Windows (R3-06).
        ap.refuse('--seed-out and --secrets-out are refused on Windows, where the secrets file cannot be made owner-only; use --stdout')
    if bool(args.schema) == (schema_text is not None):
        ap.refuse('give the schema once: --schema, or schema_text from the caller')
    endpoints = {}
    for item in args.endpoint:
        name, sep, value = item.partition('=')
        if not sep or not re.fullmatch(r'[A-Z][A-Z0-9_]{0,63}', name) or len(value) < 4:
            ap.refuse('every --endpoint must be NAME=VALUE with an upper-case NAME and a VALUE of 4 or more characters (not shown)')
        endpoints[name] = value

    log = sys.stderr if args.stdout else sys.stdout
    # In --stdout mode the document must be the only thing on stdout. OWUI
    # logs to sys.stdout when it is imported (load_codec, owui_version), so
    # stdout points at stderr until the document is written.
    document = sys.stdout
    if args.stdout:
        sys.stdout = sys.stderr
    try:
        schema = json.loads(schema_text if schema_text is not None else Path(args.schema).read_text(encoding='utf-8'))
        secret_key_from_file()
        version = owui_version() or args.owui_version
        if not version:
            raise Stop('OWUI version unknown: open_webui is not importable and --owui-version was not given')
        export = Export(schema, endpoints, load_codec())
        try:
            seed = export.run(open_db(args.db), version, args.image_digest)
        except Stop as stop:
            if str(stop):
                export.problems.insert(0, str(stop))
            raise Stop('\n'.join(f'PROBLEM {p}' for p in export.problems)) from None
        finally:
            for w in export.warnings:
                print(f'WARN    {w}', file=log)
        if args.stdout:
            document.write(json.dumps({'seed': seed_files(seed), 'secrets_file': secrets_text(export.secrets)},
                                      sort_keys=True, ensure_ascii=True))
            document.write('\n')
            document.flush()
        else:
            write_files(seed, export.secrets, args.seed_out, args.secrets_out)
        counts = ', '.join(f'{k} {v}' for k, v in seed['provenance']['counts'].items())
        print(f'OK      seed exported: {counts}; {len(export.secrets)} secret reference(s)', file=log)
        return 0
    except sqlite3.Error as err:
        # The message can quote a value from the database, so only its type.
        print(f'PROBLEM database: {type(err).__name__}', file=log)
        print('STOPPED nothing was written', file=log)
        return 1
    except Stop as stop:
        text = str(stop)
        print(text if text.startswith('PROBLEM') else f'PROBLEM {text}', file=log)
        print('STOPPED some output could not be removed; see above' if stop.left else 'STOPPED nothing was written', file=log)
        return 1
    except Exception as err:
        # The collector shows only these lines, so name what failed and where,
        # never the message, which could echo a value.
        frame = traceback.extract_tb(err.__traceback__)[-1]
        print(f'PROBLEM unexpected {type(err).__name__} at {Path(frame.filename).name} line {frame.lineno}', file=log)
        print('STOPPED nothing was written', file=log)
        return 1
    finally:
        sys.stdout = document


if __name__ == '__main__':
    sys.exit(main())
