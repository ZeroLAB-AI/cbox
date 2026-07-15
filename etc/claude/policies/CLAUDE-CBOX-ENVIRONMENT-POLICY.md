# cbox environment policy

You may be running inside a cbox container. When you are, the Bash tool has no controlling TTY and no docker socket - so some things you cannot verify yourself, and claiming you did is a real error.

- **No TTY.** `[ -t 0 ]`/`[ -t 1 ]` return false in your Bash calls. You cannot empirically verify anything TTY-gated: arrow-key/TUI menus, interactive prompts, raw single-key reads. Setting the TTY flag by hand in a test bypasses the very gate you are meant to check, so a passing hand-rigged test is not evidence it works for a real user on the host. Mark such things "statically checked; live TTY test is on the host", never "it works".
- **No docker socket.** Image build / container up / run / verify and real container runs do not execute here. Static gates are fine (syntax check, shellcheck, ASCII, a PTY harness that injects keys via `script`). A real docker run is always a host-side step.
- **When a host user reports "old design / plain text prompt", rule out the innocent causes before blaming the code:** copied ANSI output hides an in-place TUI redraw (bare text like `[a b]:` can be a menu mid-frame, not a legacy prompt); and a prompt that only appears on a fresh run is skipped once a config file already exists (by design). Confirm the real state by asking (does the cursor move on arrow-down?), not by guessing.
