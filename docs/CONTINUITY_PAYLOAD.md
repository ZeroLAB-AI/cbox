# Continuity session-start payload

cbox/etc/hooks/continuity_session_start.py is the single session-start loader shared by both engine integrations (Claude and Codex). It emits fenced payload sections named core, shared-memory, bounded-ledger, and progress. Each section is built from cbox/etc/hooks/session-core.txt (the session orchestration kernel) and the project brain in .cbox/ (LEDGER.md and PROGRESS_*.md files).

## Per-section invocation

The hook accepts --section SECTIONNAME (where SECTIONNAME is core, memory, ledger, or progress) and emits only that section. With no argument, it emits all sections in order - the compatibility path for callers that ingest the full payload in one stream. The Claude-side settings.json registers the hook four times, once per section, to keep each emission small. An unrecognized --section value falls back to emitting all sections and warns on stderr; this fail-open design ensures a session-start hook never fails closed.

## Why sections are emitted separately

The host CLI persists any single hook stdout larger than roughly 10 KB to a tool-results file and injects only a preview of about 2 KB into the session context. A combined payload above that threshold silently never reaches the session. Splitting per section keeps every emission safely below the threshold, ensuring the ledger and progress content actually reaches the session instead of being truncated to a stub.

## Byte caps

The hook enforces these caps on payload bodies (after removal of fence markers and format lines):
- CORE_PAYLOAD_BODY_BYTE_CAP: 7000 bytes
- REFERENCE_PAYLOAD_BODY_BYTE_CAP: 4000 bytes (for ledger and progress)
- SHARED_MEMORY_BODY_BYTE_CAP: 7000 bytes
- LEDGER_BYTE_CAP: 6000 bytes
- PROGRESS_TAIL_LINES: 40 lines

Shared-memory truncation keeps the tail (newest messages); all other payloads keep the prefix (oldest content first). Do not raise any cap back above the persist threshold without re-measuring delivery.

## Tests

cbox/lib/test_continuity_session_start.sh covers payload capping, the per-section concat-equals-no-arg invariant (all sections combined match the no-arg output), bogus-section fallback with stderr warning, and per-section emissions staying under the 8500 B persist-safety ceiling. Tests verify the tail-vs-prefix distinction (shared-memory keeps end, ledger keeps start) and graceful degradation when ledger or progress files cannot be read.
