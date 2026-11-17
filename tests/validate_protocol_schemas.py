import json
from pathlib import Path
from jsonschema import Draft202012Validator
from referencing import Registry
from referencing.jsonschema import DRAFT202012

root = Path(__file__).resolve().parents[1]
cases = {
    "request": {"v": 1, "id": "0123456789abcdef0123456789abcdef", "cmd": "players", "args": {}, "ts": 1793577600},
    "response": {"v": 1, "accepts": [1], "id": "0123456789abcdef0123456789abcdef", "ok": True, "data": {"players": []}, "meta": {"game_build_id": "12345678", "mod_version": "1.0.0"}},
}


def offline(uri):
    """The tests never download: a schema that needs a document from the network fails here, by name."""
    raise LookupError(f"not fetched (tests run offline): {uri}")


for name, instance in cases.items():
    schema = json.loads((root / "tests" / "schema" / f"{name}.schema.json").read_text(encoding="utf-8"))
    registry = Registry(retrieve=offline).with_resource(schema["$id"], DRAFT202012.create_resource(schema))
    Draft202012Validator(schema, registry=registry).validate(instance)
print(f"{len(cases)} protocol examples validated")
