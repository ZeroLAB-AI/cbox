import os
import re
import sys

PATCH_MODULE = "run_agent"
PATCH_ATTR = "AIAgent"
PROMPT_ENV = "HERMES_EPHEMERAL_SYSTEM_PROMPT"


def _fail(message):
    sys.stderr.write(message + "\n")
    sys.stderr.flush()
    raise SystemExit(3)


def _apply_cbox_prompt(prompt):
    try:
        import run_agent
    except ImportError:
        _fail(
            "cbox: hermes ACP integration needs an update: cannot import "
            + PATCH_MODULE
            + " (expected patch point "
            + PATCH_MODULE
            + "."
            + PATCH_ATTR
            + ")"
        )
    if not hasattr(run_agent, PATCH_ATTR):
        _fail(
            "cbox: hermes ACP integration needs an update: expected patch point "
            + PATCH_MODULE
            + "."
            + PATCH_ATTR
            + " is missing"
        )
    base = getattr(run_agent, PATCH_ATTR)
    if not isinstance(base, type):
        _fail(
            "cbox: hermes ACP integration needs an update: "
            + PATCH_MODULE
            + "."
            + PATCH_ATTR
            + " is no longer a class"
        )

    class _AgentWithEphemeralPrompt(base):
        def __init__(self, *args, **kwargs):
            if "ephemeral_system_prompt" not in kwargs:
                kwargs["ephemeral_system_prompt"] = prompt
            super().__init__(*args, **kwargs)

    setattr(run_agent, PATCH_ATTR, _AgentWithEphemeralPrompt)


def main():
    prompt = os.environ.get(PROMPT_ENV)
    if prompt:
        _apply_cbox_prompt(prompt)
    from acp_adapter.entry import main as acp_main
    sys.argv[0] = re.sub(r"(-script\.pyw|\.exe)?$", "", sys.argv[0])
    sys.exit(acp_main())


if __name__ == "__main__":
    main()
