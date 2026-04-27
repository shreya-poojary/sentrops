# ADR-007 — MCP Server Design Patterns

**Status:** Accepted
**Date:** 2026-04-26
**Author:** Shreya Poojary
**Applies to:** Sprint 3 — MCP servers

---

## Context

SentrOps builds three custom MCP servers: `sentrops-cost-mcp`, `sentrops-cloudwatch-mcp`, and `sentrops-terraform-mcp`. These will be published to PyPI as standalone open-source packages. Their design must be:

1. **Defensible** — each design choice can be explained to a maintainer or interviewer
2. **Consistent** — the three servers share patterns so they are learnable as a system
3. **Differentiated** — they are not thin AWS API wrappers; the three differentiators from ADR-001 Principle 7 are real and observable

This ADR defines the patterns that apply to all three servers: tool schema conventions, error shapes, pagination strategy, audit hook contract, and the IRSA boundary. Sprint 3 implementation follows these patterns; deviations require updating this ADR.

The **learn-don't-generate** rule (from CLAUDE.md) applies: Shreya writes the first tool by hand for each server, then Claude Code reviews and scaffolds subsequent tools following these patterns.

---

## Decision

### Package structure

Each server follows this layout:

```
mcp-servers/sentrops-<domain>-mcp/
  pyproject.toml
  Dockerfile
  README.md
  src/
    sentrops_<domain>_mcp/
      __init__.py
      server.py          # MCP server entry point
      tools/
        <tool_name>.py   # One file per tool
      audit.py           # Audit hook implementation
      errors.py          # Error types
  tests/
    unit/
    integration/
  helm/
    Chart.yaml
    values.yaml
    templates/
```

`server.py` registers tools and starts the MCP server. Each tool lives in its own module. This makes tools independently testable and makes the diff for adding a tool easy to review.

### Tool schema conventions

#### Naming

Tool names are `snake_case` verbs describing what the tool returns or does:

- `top_drivers_by_tag` — returns top cost drivers filtered by a tag key/value
- `detect_cost_anomaly` — returns anomaly detection result for a metric
- `logs_insights_query` — executes a CloudWatch Logs Insights query and returns results
- `get_metric_statistics` — returns CloudWatch metric datapoints for a time window
- `describe_alarm_state` — returns current alarm state and reason
- `plan_diff` — returns the diff between current Terraform state and a proposed plan
- `open_pr` — opens a GitHub Pull Request with a Terraform change

Tool names are stable identifiers. The eval harness records which tool names appear in agent traces. Renaming a tool after Sprint 4 calibration would invalidate ground truth.

#### Input schemas

All tools declare explicit input schemas with:
- Required fields listed first
- Optional fields with defaults listed second
- ISO 8601 strings for all time parameters (`start_time`, `end_time`)
- Enum types for fields with a fixed value set (e.g., `granularity: Literal["HOURLY", "DAILY", "MONTHLY"]`)
- `tag_key` + `tag_value` pairs (not a dict) for AWS tag filters — simpler for the LLM to construct

Example (cost tool):

```python
class TopDriversByTagInput(BaseModel):
    tag_key: str
    tag_value: str
    start_time: str  # ISO 8601
    end_time: str    # ISO 8601
    granularity: Literal["DAILY", "MONTHLY"] = "DAILY"
    top_n: int = Field(default=10, ge=1, le=50)
```

#### Output schemas

All tools return a `ToolResult` object with:

```python
class ToolResult(BaseModel):
    tool: str          # tool name
    success: bool
    data: dict | None  # structured result on success
    error: ToolError | None  # structured error on failure
    metadata: ToolMetadata   # audit metadata
```

The `data` field is tool-specific but always a dict (not a list at the top level — the LLM handles dicts more reliably than bare lists). Lists are nested: `{"results": [...]}`.

`metadata` is always present and feeds the audit hook (see below).

### Error shapes

All errors are structured, never bare Python exceptions:

```python
class ToolError(BaseModel):
    code: str              # machine-readable: "INVALID_TIME_RANGE", "AWS_THROTTLE", etc.
    message: str           # human-readable for the LLM to relay
    retryable: bool        # True if the LLM should retry with backoff
    context: dict = {}     # additional fields for debugging
```

Error codes follow the pattern `<DOMAIN>_<TYPE>`:
- `AWS_THROTTLE` — rate limited by AWS API
- `AWS_PERMISSION_DENIED` — IRSA role lacks required permission
- `INVALID_TIME_RANGE` — start_time > end_time or range exceeds tool limit
- `NO_DATA` — query returned no results (not an error, but flagged for the LLM)
- `GITHUB_APP_AUTH_FAILED` — GitHub App token exchange failed (terraform-mcp only)

The LLM sees `code` and `message`. `retryable` guides whether the agent should retry or escalate.

### Pagination strategy

AWS APIs are paginated. MCP tools must not expose raw pagination tokens to the LLM — managing pagination state is cognitive overhead that degrades LLM performance. Instead, tools handle pagination internally and return at most `max_results` items (default: 50, max: 500).

If results are truncated, the response includes:

```python
"metadata": {
    "truncated": True,
    "total_available": 1240,
    "returned": 50
}
```

The LLM can then decide whether to call the tool again with a narrower time range or accept the truncated result. It never manages a `NextToken`.

### Audit hook contract

Every tool call triggers an audit write **before returning the result to the caller**. The write is synchronous (not fire-and-forget) to guarantee the record exists if the agent crashes after receiving the response.

Audit record schema:

```python
class AuditRecord(BaseModel):
    record_id: str          # UUID
    timestamp: str          # ISO 8601 UTC
    server: str             # "sentrops-cost-mcp"
    tool: str               # "top_drivers_by_tag"
    tool_version: str       # semver
    irsa_role_arn: str      # from STS GetCallerIdentity
    agent_run_id: str | None  # passed as tool input metadata if provided
    input: dict             # full tool input (after pydantic validation)
    output_success: bool
    output_summary: str     # ≤ 500 chars — not the full output (avoids S3 bloat)
    output_bytes: int       # size of the full response payload
    duration_ms: int        # tool execution time
```

The `irsa_role_arn` is retrieved via `sts:GetCallerIdentity` once at server startup and cached. This confirms the server is running with the expected IRSA role.

**S3 key pattern:**
```
s3://sentrops-audit-<account_id>/tool-calls/<YYYY>/<MM>/<DD>/<record_id>.json
```

The bucket has Object Lock in Compliance mode, 90-day retention. No IAM principal can delete objects before expiry. The audit module raises a fatal error if the first write at startup fails — this prevents a server with broken audit capability from serving requests.

### IRSA boundary enforcement

Each server validates its IRSA role ARN at startup against an expected pattern (configurable via env var `EXPECTED_ROLE_ARN_PATTERN`). If the actual role ARN does not match, the server exits with a non-zero status code rather than serving requests with incorrect permissions.

This prevents accidental misconfiguration (e.g., cost-mcp pod using cloudwatch-mcp's role) from being silently accepted.

### Dockerfile and runtime

- Base image: `gcr.io/distroless/python3-debian12` (no shell, no package manager)
- Non-root user (`uid=65532`)
- No secrets baked into the image — all configuration via environment variables and IRSA
- Health endpoint: `/health` returning `{"status": "ok", "server": "<name>", "version": "<semver>"}`
- Single-process: `python -m sentrops_<domain>_mcp.server`

### Testing requirements

- **Unit tests** (moto for AWS mocks): every tool tested with success case + at least two error cases
- **Integration tests** (real AWS, sandbox account): one test per tool against real APIs
- **Audit tests**: verify that every tool call writes to S3, and that the record matches the input
- **Coverage target:** ≥ 70% line coverage (enforced by `pytest-cov` in CI)

The MCP cross-server smoke test (`tests/smoke/cross_mcp_test.py`) invokes one tool from each server and validates all three audit records appear in S3. This runs before every eval harness execution in Sprint 4.

---

## Alternatives Considered

### Alternative: FastAPI wrappers instead of MCP servers

Expose the AWS API calls as REST endpoints and let the agent call them via HTTP tool use.

**Rejected because:** The MCP protocol is the portfolio thesis. MCP tool schemas are typed, discoverable, and composable in ways that REST endpoints are not (for LLM tool use). The audit hook, error shape, and pagination contracts are defined at the MCP level. Building FastAPI wrappers would make this a "wrapper project" rather than an "MCP project."

### Alternative: Single monolithic MCP server (all tools in one package)

Combine all three servers into `sentrops-mcp` with all tools registered together.

**Rejected because:** A monolithic server requires a union IAM role (violating ADR-001 Principle 7's IRSA-per-server requirement) and cannot be published as three independent PyPI packages. The separation is the differentiator. A monolith is simpler to operate but eliminates the portfolio value.

### Alternative: AWS Lambda for tool execution (serverless)

Each tool is a Lambda function; the MCP server is a thin proxy.

**Rejected because:** Lambda cold starts add latency to every tool call that is not in cache. The agent loop in Sprint 4 chains multiple tool calls per incident — cold start latency would materially increase per-incident cost and duration. Lambda also complicates the audit hook (Lambda logs go to CloudWatch, not S3 Object Lock). A long-running pod with warm connections to AWS APIs is faster and simpler for this use case.

### Alternative: Use the MCP Python SDK's built-in error handling

Return MCP protocol-level errors (using the SDK's error types) instead of wrapping in `ToolResult`.

**Partially adopted.** Protocol-level errors (malformed request, unknown tool) use the SDK's error types. Business logic errors (AWS throttle, no data, invalid time range) use the `ToolError` type defined above. This gives the LLM structured error information it can reason about, while keeping the protocol layer clean.

### Alternative: Async S3 writes for audit (fire-and-forget)

Write audit records asynchronously to avoid blocking tool response time.

**Rejected because:** A fire-and-forget write can be lost if the process crashes between tool response and S3 write. The audit log is an Object Lock WORM store — its value depends on completeness. A 10–50ms synchronous write is an acceptable latency cost for guaranteed audit completeness.

---

## Consequences

**Positive:**
- Consistent patterns across three servers mean adding a fourth server in the future (e.g., `sentrops-ecs-mcp`) follows clear conventions
- Structured `ToolError` with `retryable` flag enables the agent loop in Sprint 4 to implement intelligent retry logic
- Synchronous audit writes guarantee completeness — every agent action has a corresponding audit record
- Distroless images reduce CVE surface and pass container security scans without additional configuration

**Negative:**
- The `ToolResult` wrapper adds a layer that the LLM must unwrap — tool outputs are never bare values
- Synchronous audit writes add 10–50ms latency per tool call (S3 PUT in the same region). For a chain of 5 tool calls, this is 50–250ms additional latency per incident diagnosis.
- IRSA role ARN validation at startup adds a server start dependency on STS. If STS is unreachable, the server will not start.

**Neutral:**
- The learn-don't-generate rule means the first tool in each server is written by Shreya before Claude Code helps scaffold the rest. This is intentional: the audit hook, error shapes, and input/output schemas need to be understood before they can be templated.

---

## Related ADRs

- **ADR-001** — Architecture principles (Principle 7: purpose-built MCPs; Principle 4: audit every tool call; Principle 2: IRSA)
- **ADR-004** — IRSA design (per-server role definitions)
- **ADR-006** — Chaos scenarios (tool schemas designed around these four scenarios)
- **ADR-009** — Eval harness (tool names in agent traces are the unit of ground-truth matching)
