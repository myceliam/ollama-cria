import json


class JSONCodec:
    JSONDecodeError = json.JSONDecodeError
    dumps = staticmethod(json.dumps)
    loads = staticmethod(json.loads)
