import json
from pathlib import Path
from jsonschema import Draft202012Validator

root = Path(__file__).resolve().parents[1]
cases = {
    "request": {"v": 1, "id": "0123456789abcdef0123456789abcdef", "cmd": "players", "args": {}, "ts": 1793577600},
    "response": {"v": 1, "accepts": [1], "id": "0123456789abcdef0123456789abcdef", "ok": True, "data": {"players": []}, "meta": {"game_build_id": "12345678", "mod_version": "1.0.0"}},
    "receipt": {"schema_version": 1, "request_id": "0123456789abcdef0123456789abcdef", "actor": "operator", "source": "local", "command": "server.slots", "arguments": {"slots": 8}, "started_at": "2026-11-02T00:00:00Z", "completed_at": "2026-11-02T00:00:01Z", "duration_ms": 1000, "exit_code": 0, "ok": True, "state": "verified", "code": "ok", "protocol_result": {}, "message": "slot limit read back"},
}
for name, instance in cases.items():
    schema = json.loads((root / "tests" / "schema" / f"{name}.schema.json").read_text(encoding="utf-8"))
    Draft202012Validator.check_schema(schema)
    Draft202012Validator(schema).validate(instance)
print(f"{len(cases)} protocol examples validated")
