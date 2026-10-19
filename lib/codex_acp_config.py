import json
import sys
import tomllib


def main():
    with open(sys.argv[1], "rb") as stream:
        config = tomllib.load(stream)
    with open(sys.argv[2], encoding="utf-8") as stream:
        hooks = json.load(stream)["hooks"]
    if not isinstance(hooks, dict):
        raise ValueError("invalid Codex hooks")
    enabled = config.get("features", {}).get("codex_hooks") is True
    if enabled != ("PreToolUse" in hooks):
        raise ValueError("Codex profile and hooks gate disagree")
    config["hooks"] = hooks
    print(json.dumps(config, ensure_ascii=True, separators=(",", ":")))


if __name__ == "__main__":
    main()
