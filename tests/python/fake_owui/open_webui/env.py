import os

if os.environ.get('FAKE_OWUI_NOISY'):
    print('fake OWUI log line, as the real env.py logs to stdout on import')

VERSION = os.environ.get('FAKE_OWUI_VERSION', '0.11.4')
# Like OWUI 0.11.4: the key comes from the environment, and importing env.py
# stops the process when there is none (FAKE_OWUI_KEY is the tests' shortcut).
WEBUI_SECRET_KEY = os.getenv('WEBUI_SECRET_KEY', os.getenv('WEBUI_JWT_SECRET_KEY', '')) or os.environ.get('FAKE_OWUI_KEY', '')
if not WEBUI_SECRET_KEY:
    raise SystemExit('WEBUI_SECRET_KEY is not set. It is a hard requirement when authentication is enabled.')

ENABLE_VALVE_ENCRYPTION = os.getenv('ENABLE_VALVE_ENCRYPTION', 'False').lower() == 'true'
