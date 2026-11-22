import json


def is_ready(response: str | bytes) -> bool:
    """Parse gateway JSON, accepting only an object with a true ready field."""
    payload = json.loads(response)
    return isinstance(payload, dict) and payload.get("ready") is True
