# UFW Docker Protect: Implementation Improvements & Recommendations

## Executive Summary
Your implementation plan is solid on the core logic fix (the IPv6-aware rule ordering). However, there are **five critical gaps** that will impact production reliability, operational maintainability, and user confidence. This document prioritizes improvements by business impact and implementation effort.

---

## 1. ARCHITECTURE & DESIGN GAPS

### 1.1 **Async/Task-Based State Synchronization** (Critical Path)
**Issue**: Your `sync` command is synchronous and runs on every reload. This creates race conditions when Docker spawns multiple containers or when rules change frequently.

**Current Risk**:
- Two `docker run` commands in rapid succession both invoke `sync`, potentially interleaving `iptables-save` and `iptables-restore`.
- A rule addition mid-sync could be partially applied or lost.

**Recommendation**: 
- Implement a **job queue** (e.g., `queue.Queue` in Python with a background thread or async/await).
- Buffer rule additions/removals during active syncs.
- Use a lock file (`/run/ufw-docker-protect.lock`) with timeout to prevent deadlock.
- Log all state transitions for auditability.

**Implementation sketch**:
```python
class RuleQueue:
    def __init__(self):
        self.queue = asyncio.Queue()
        self.lock = asyncio.Lock()
        self.syncing = False
    
    async def enqueue_rule(self, action, rule):
        await self.queue.put((action, rule))
        if not self.syncing:
            await self.process_queue()
    
    async def process_queue(self):
        async with self.lock:
            self.syncing = True
            try:
                while not self.queue.empty():
                    action, rule = self.queue.get_nowait()
                    await self.apply_rule(action, rule)
            finally:
                self.syncing = False
```

---

### 1.2 **Volume Mount Strategy for `/etc/ufw-docker-protect/`** (Operational)
**Issue**: Your plan stores `ports.json` in `/etc/ufw-docker-protect/`. In containerized or auto-scaling deployments, this host path isn't guaranteed persistent.

**Recommendation**:
- **Option A (Preferred)**: Mount a **named Docker volume** (e.g., `ufw-docker-state`) at `/etc/ufw-docker-protect/` on the host.
  - Ensures state survives host restarts.
  - Works with Docker Swarm and Kubernetes node affinity.
  
- **Option B (Fallback)**: Embed `ports.json` in `/var/lib/ufw-docker-protect/` and sync to Docker metadata (labels on containers).
  - More resilient but requires syncing bidirectionally.

**Recommendation**: Go with **Option A** — it's simpler and widely understood.

---

### 1.3 **IPv6 Parallel Rules Throughout** (Critical Path)
**Issue**: Your plan correctly fixes the rule ordering, but the implementation sketch doesn't show IPv6 rules explicitly.

**Current Risk**:
- A container can still receive inbound IPv6 traffic on port 443/tcp even if 443/tcp is denied for IPv4.
- Users trust the tool and don't test IPv6 separately.

**Recommendation**:
- **Every rule must be applied to both `iptables` and `ip6tables` simultaneously**.
- Use a helper function:
```python
def apply_rule(self, rule, action='insert'):
    """Apply rule to both IPv4 and IPv6 with identical logic."""
    for iptables_cmd in ['iptables', 'ip6tables']:
        subprocess.run([
            iptables_cmd, '-C', 'DOCKER-USER', ...  # Check first
        ], capture_output=True)
        # Then insert/delete/etc.
```
- Test matrix: every allow/deny rule → test on IPv4 AND IPv6 separately.
- Document: *"Rules are enforced on both IPv4 and IPv6."*

---

### 1.4 **Rule Idempotency Audit & Specification** (Critical Path)
**Issue**: You mention idempotency but don't specify how duplicate rules are detected or deduplicated.

**Current Risk**:
- Running `allow-port 443/tcp 0.0.0.0/0` twice adds the rule twice if not checked.
- `iptables -C` (check) returns nonzero if rule doesn't exist; script might interpret this as "add it anyway."

**Recommendation**:
- **Always check rule existence before insert**: `iptables -C DOCKER-UFW-PORTS -p tcp --dport 443 -s 0.0.0.0/0 -j ACCEPT` (exit 0 = exists, 1 = doesn't).
- **Deduplicate on startup**: `iptables-save | grep DOCKER-UFW-PORTS` and parse to find duplicates, delete all, rebuild from `ports.json`.
- **Document the idempotency contract**: 
  - Running the same command twice produces the same state (no double-rule).
  - Interrupted operations (e.g., power loss mid-sync) can be safely resumed.

---

## 2. RELIABILITY & SAFETY GAPS

### 2.1 **Rollback & Snapshot System** (High Impact)
**Issue**: If a `sync` operation or rule addition breaks connectivity, there's no recovery path short of manual `iptables` intervention.

**Current Risk**:
- User runs `allow-port 8080/tcp 10.0.0.5` → rule is malformed, all traffic is blocked.
- User has no way to revert without SSHing to the host and hand-editing rules.

**Recommendation**:
- **Snapshot before each operation**:
  - `iptables-save > /var/lib/ufw-docker-protect/snapshot-$(date +%s).rules`
  - Keep last 5 snapshots (rotate).
  - Snapshots are **human-readable** exports of the entire chain.

- **Provide a `rollback <timestamp>` command**:
  ```bash
  ufw-docker-protect rollback 1682423154
  # Restores the chain to the state 30 minutes ago
  ```

- **Automatic rollback on critical errors**:
  - If post-update validation fails, automatically restore the previous snapshot.
  - Log: "Rule update failed validation. Rolled back to snapshot-XXXX."

---

### 2.2 **Atomic Operations & Transaction Log** (High Impact)
**Issue**: Multi-step rule updates (e.g., removing an old rule and adding a new one) are not atomic. If the process crashes mid-operation, the rules are in a partially updated state.

**Recommendation**:
- Use a **transaction log** (`/var/lib/ufw-docker-protect/txn.log`):
  ```
  TXN_ID | ACTION | RULE_ID | STATUS | TIMESTAMP | ERROR (if any)
  TX-001 | ALLOW  | 443-tcp | BEGIN  | 2025-04-16T10:30:00 | NULL
  TX-001 | ALLOW  | 443-tcp | COMMIT | 2025-04-16T10:30:01 | NULL
  TX-002 | REVOKE | 8080-tcp| BEGIN  | 2025-04-16T10:30:02 | NULL
  TX-002 | REVOKE | 8080-tcp| ROLLBACK | 2025-04-16T10:30:02 | iptables: Invalid argument
  ```

- On startup, scan the transaction log:
  - If any transaction is in `BEGIN`, roll it back and mark as `FAILED`.
  - Prevents the tool from leaving the chain in an inconsistent state after a crash.

---

### 2.3 **Pre-Flight Validation & Dry-Run Mode** (High Impact)
**Issue**: Your plan mentions validating daemon config but doesn't cover validating new rules *before applying them*.

**Current Risk**:
- User runs `allow-port 99999/tcp 0.0.0.0/0` (invalid port).
- Script tries to apply it, `iptables` rejects it, rule is not added, but user is told "success."

**Recommendation**:
- **Dry-run mode**: `ufw-docker-protect allow-port 443/tcp 0.0.0.0/0 --dry-run`
  - Prints the exact rule that will be added without applying it.
  - User can review and confirm.

- **Validation pipeline**:
  1. Parse rule syntax (port, protocol, CIDR).
  2. Simulate rule application (check for conflicts, overlaps, redundancy).
  3. Print a clear summary.
  4. Require user confirmation (or `--force`).

- **Validation errors** are fatal and descriptive:
  ```
  Error: Port 99999/tcp is out of range (1-65535).
  Error: CIDR 192.168.1.999/24 is invalid: invalid octet.
  ```

---

### 2.4 **Daemon State Recovery & Health Checks** (High Impact)
**Issue**: The `doctor` command validates the daemon config, but there's no way to repair a broken state automatically.

**Current Risk**:
- Docker daemon was started with `iptables: false`, then a human changed it to `true`.
- The `DOCKER-USER` chain doesn't exist.
- The tool fails silently or crashes.

**Recommendation**:
- **Auto-repair mode**:
  ```bash
  ufw-docker-protect doctor --repair
  ```
  - Detects missing chains and recreates them from scratch.
  - Rebuilds `DOCKER-USER` with the correct rule order.
  - Repopulates `DOCKER-UFW-PORTS` from `ports.json`.

- **Continuous health check** (optional systemd timer):
  ```ini
  [Unit]
  Description=UFW Docker Protect Health Check
  After=ufw-docker-protect.service
  
  [Timer]
  OnBootSec=5min
  OnUnitActiveSec=30min
  
  [Install]
  WantedBy=timers.target
  ```
  - Runs `doctor --repair` every 30 minutes.
  - Logs if any repairs were needed.

---

## 3. OPERATIONAL & CLI GAPS

### 3.1 **Comprehensive Logging & Audit Trail** (Operational)
**Issue**: Your plan doesn't specify logging beyond optional `LOG` rules in iptables.

**Current Risk**:
- Users have no visibility into what the tool is doing.
- No audit trail for compliance (who added which rule, when, why).

**Recommendation**:
- **Structured logging** (JSON format):
  ```json
  {
    "timestamp": "2025-04-16T10:30:00Z",
    "action": "allow-port",
    "port": "443/tcp",
    "source": "0.0.0.0/0",
    "status": "success",
    "rule_id": "443-tcp-all",
    "user": "admin",
    "change_set_id": "CS-012345"
  }
  ```

- **Log rotation** (`/var/log/ufw-docker-protect/activity.log`):
  - Keep 30 days of logs by default.
  - Use `logrotate` or Python `logging.handlers.RotatingFileHandler`.

- **Iptables logging** (optional, controlled by `--enable-logging`):
  - Logs denied packets (not allowed traffic).
  - Format: `[DOCKER-UFW-DENY] <SRC> <DST> <PROTO> <PORT>`
  - Can be sent to syslog or a separate file.

---

### 3.2 **Rule Insights & Export** (Operational)
**Issue**: `list-rules` prints a basic text list. Users can't easily answer questions like *"which containers can accept port 22?"* or *"export rules for audit."*

**Recommendation**:
- **Enhance `list-rules`**:
  ```bash
  ufw-docker-protect list-rules --format json
  ufw-docker-protect list-rules --format table
  ufw-docker-protect list-rules --filter port=443
  ufw-docker-protect list-rules --filter protocol=tcp
  ```

- **Add `export-rules` command**:
  ```bash
  ufw-docker-protect export-rules --format iptables-save > backup.rules
  # Can be restored: iptables-restore < backup.rules
  ```

- **Add `compare` command** (compare two rule sets):
  ```bash
  ufw-docker-protect compare current snapshot-1682423154
  # Shows: Added, Removed, Changed rules between the two states
  ```

---

### 3.3 **Batch Operations API** (Operational)
**Issue**: Adding/revoking multiple rules requires multiple CLI invocations, which is inefficient and error-prone.

**Recommendation**:
- **Batch add via stdin or file**:
  ```bash
  cat > rules.txt <<EOF
  allow 443/tcp 0.0.0.0/0
  allow 80/tcp 0.0.0.0/0
  allow 22/tcp 10.0.0.0/8
  EOF
  
  ufw-docker-protect batch rules.txt
  ```

- **Or stdin streaming**:
  ```bash
  echo -e "allow 443/tcp 0.0.0.0/0\nallow 80/tcp 0.0.0.0/0" | \
    ufw-docker-protect batch --stdin
  ```

- **Batch operations are atomic**: If any rule in the batch fails, all are rolled back.

---

### 3.4 **Fix Systemd Unit (Type, Restart Semantics)** (Operational)
**Issue**: Your proposed unit uses `Type=oneshot` with `Restart=always`, which is contradictory.

**Recommendation**:
```ini
[Unit]
Description=UFW Docker Protect AWS SG Layer
After=docker.service ufw.service network.target
Requires=docker.service
PartOf=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/usr/local/bin/ufw-docker-protect doctor --repair
ExecStart=/usr/local/bin/ufw-docker-protect sync
ExecReload=/usr/local/bin/ufw-docker-protect sync
# Do NOT use Restart=always with Type=oneshot
# Instead, rely on docker restart and manual systemctl reload

StandardOutput=journal
StandardError=journal
SyslogIdentifier=ufw-docker-protect

[Install]
WantedBy=multi-user.target
```

**Notes**:
- Removed `Restart=always` (incompatible with `Type=oneshot`).
- Added `ExecStartPre=-/usr/local/bin/ufw-docker-protect doctor --repair` (heals the state on boot).
- Added logging directives (journal integration).
- `PartOf=docker.service` so the service is reloaded when Docker restarts.

---

## 4. TESTING & VALIDATION GAPS

### 4.1 **Unit Tests (Python)** (Quality & Confidence)
**Issue**: No test coverage mentioned. Rule logic is complex and error-prone.

**Recommendation** (`tests/test_ufw_docker_protect.py`):
```python
import pytest
from ufw_docker_protect import RuleParser, RuleApplier, RuleQueue

class TestRuleParser:
    def test_parse_valid_rule(self):
        rule = RuleParser.parse("allow 443/tcp 0.0.0.0/0")
        assert rule.action == "allow"
        assert rule.port == 443
        assert rule.protocol == "tcp"
        assert rule.source == "0.0.0.0/0"
    
    def test_parse_invalid_port(self):
        with pytest.raises(ValueError, match="out of range"):
            RuleParser.parse("allow 99999/tcp 0.0.0.0/0")
    
    def test_parse_invalid_cidr(self):
        with pytest.raises(ValueError, match="invalid CIDR"):
            RuleParser.parse("allow 443/tcp 192.168.1.999/24")

class TestRuleApplier:
    @pytest.fixture
    def applier(self, tmp_path):
        return RuleApplier(rules_file=tmp_path / "ports.json")
    
    def test_idempotent_add(self, applier, mocker):
        # Mock subprocess to avoid actual iptables calls
        mocker.patch("subprocess.run")
        applier.add_rule("443/tcp", "0.0.0.0/0")
        applier.add_rule("443/tcp", "0.0.0.0/0")  # Should be a no-op
        assert len(applier.rules) == 1
    
    def test_ipv6_parity(self, applier, mocker):
        # Ensure both iptables and ip6tables are called
        mock_run = mocker.patch("subprocess.run")
        applier.add_rule("443/tcp", "0.0.0.0/0")
        calls = [c[0][0] for c in mock_run.call_args_list]
        assert "iptables" in calls
        assert "ip6tables" in calls
```

**Test coverage targets**:
- Rule syntax validation (all edge cases).
- IPv4 and IPv6 rule application parity.
- Idempotency (duplicate adds are no-ops).
- Rollback and snapshot behavior.
- Transaction log recovery.

---

### 4.2 **Integration Tests** (Quality & Confidence)
**Issue**: Unit tests mock subprocess; integration tests will be on real Docker/iptables.

**Recommendation** (`tests/integration/test_docker_integration.py`):
```python
import subprocess
import time
import pytest

@pytest.fixture
def docker_container():
    """Spin up a test container."""
    cid = subprocess.check_output([
        "docker", "run", "-d", "--name", "test-ufw",
        "alpine", "sleep", "3600"
    ]).decode().strip()
    yield cid
    subprocess.run(["docker", "rm", "-f", cid], check=False)

def test_external_access_denied_by_default(docker_container):
    """Verify that external traffic is dropped by default."""
    # From a test host, try to connect to port 80 on the container
    # Expect timeout/refused
    pass

def test_explicit_allow_permits_access(docker_container):
    """Verify that an explicit allow rule permits traffic."""
    container_ip = subprocess.check_output([
        "docker", "inspect", "-f", "{{.NetworkSettings.IPAddress}}",
        docker_container
    ]).decode().strip()
    
    # Expose port 80
    subprocess.run([
        "ufw-docker-protect", "allow-port", "80/tcp", "0.0.0.0/0"
    ], check=True)
    
    # Now a curl from test host should work
    result = subprocess.run(
        ["curl", "-m", "2", f"http://{container_ip}:80"],
        capture_output=True
    )
    assert result.returncode == 0 or result.returncode == 7  # 0 = success, 7 = connection refused (still okay, not timeout)

def test_ipv6_parity(docker_container):
    """Verify IPv6 rules are applied in lockstep with IPv4."""
    subprocess.run([
        "ufw-docker-protect", "allow-port", "443/tcp", "::/0"
    ], check=True)
    
    # Check both iptables and ip6tables
    ipv4_rules = subprocess.check_output(["iptables-save"]).decode()
    ipv6_rules = subprocess.check_output(["ip6tables-save"]).decode()
    
    assert "443" in ipv4_rules
    assert "443" in ipv6_rules
```

**Scope**:
- Multiple container scenarios (single host, Swarm, eventually K8s).
- Port exposure and revocation.
- Chaos scenarios (Docker daemon restart, iptables manual edits, network disconnect).

---

### 4.3 **Chaos/Fault Injection Tests** (Quality & Confidence)
**Issue**: Real-world conditions include failures. The tool must be resilient.

**Recommendation** (`tests/chaos/`):
```python
def test_sync_during_docker_restart():
    """Simulate Docker restart during a sync operation."""
    # Start a sync, midway restart docker daemon
    # Verify the tool recovers gracefully

def test_iptables_manual_edit_recovery():
    """Verify recovery if someone manually edits iptables while tool is running."""
    # Add/remove a rule manually
    # Run `doctor --repair`
    # Verify state is corrected

def test_disk_full_during_snapshot():
    """Verify the tool handles disk-full gracefully."""
    # Mock disk full, try to create a snapshot
    # Expect a clear error, not a crash
```

---

### 4.4 **Performance Baseline** (Quality & Confidence)
**Issue**: No mention of performance targets. At scale (thousands of containers), rule lookup/application could be slow.

**Recommendation**:
- **Baseline metrics** (`tests/performance/`):
  ```
  Operation            | Time (ms) | Limit (ms) | Status
  --------------------+----------+----------+---------
  sync (100 rules)    |    45    |    200   | ✓
  add_rule()          |     5    |     20   | ✓
  list_rules()        |    12    |     50   | ✓
  doctor              |    80    |    500   | ✓
  ```

- **Run with each release** to catch regressions.
- Document expected scaling (e.g., "sync time = 0.5ms per rule").

---

## 5. DOCUMENTATION & DEVELOPER EXPERIENCE GAPS

### 5.1 **Architecture Decision Records (ADRs)** (Operational & Knowledge)
**Issue**: Your document explains the logic, but why those specific decisions? No rationale for future maintainers.

**Recommendation** (`docs/adr/`):

**ADR-001: IPv6 Rule Fix**
```
# Decision: Use `-i docker0 -j RETURN` (not `-o docker0 -j RETURN`) for internal traffic

## Context
Docker containers communicate via bridge networks (docker0, br+). Early rule ordering
must allow internal traffic without exposing it to external IPs.

## Problem
Initial spec used `-o docker0 -j RETURN`, which returns (allows) ALL outbound traffic
to the docker0 interface, including from external sources. This defeats the drop-default.

## Decision
Replace with `-i docker0 -j RETURN` and `-i br+ -j RETURN`. These match traffic
*ingress* to the bridge (container-to-container), not *egress*. Combined with the
default `DROP` on the `-o` side, this prevents external->container leaks.

## Consequences
- Internal container traffic is unrestricted (intended, since they're in the same trust domain).
- External traffic MUST match an explicit allow rule in DOCKER-UFW-PORTS.
- IPv6 rules must be identical to maintain parity.

## Status: Accepted (resolves logical contradiction in original spec)
```

**ADR-002: Async Rule Queue vs. Synchronous Sync**
```
# Decision: Implement async job queue for rule updates

## Context
Rapid rule additions/removals (e.g., container churn) can cause race conditions
if sync() is blocking and re-entrant.

## Decision
- Introduce asyncio.Queue for rule changes.
- Background thread processes the queue atomically.
- Each item is applied and logged before the next is processed.

## Consequences
- Slightly more complex code (async/await, locks).
- Much higher concurrency (multiple clients can queue rules without blocking).
- State is guaranteed consistent even under load.

## Status: Accepted
```

---

### 5.2 **Troubleshooting Runbook** (Operational)
**Issue**: When things break, users have no diagnostic guide.

**Recommendation** (`docs/TROUBLESHOOTING.md`):

```markdown
# UFW Docker Protect Troubleshooting

## Problem: Container can't access external services (e.g., downloads)

### Symptoms
- Container can't reach the internet (ping fails, DNS times out).
- Other containers on the host work fine.
- UFW is not enabled on the host.

### Diagnosis Steps
1. Check if the tool is active: `systemctl status ufw-docker-protect`
2. List rules: `ufw-docker-protect list-rules`
3. Run health check: `ufw-docker-protect doctor`
4. Check iptables: `iptables-save | grep DOCKER-USER`

### Resolution
- Outbound traffic is allowed by default (RETURN on docker0 ingress).
- Issue is likely DNS or firewall at a different layer.
- If you're certain it's UFW, check if external access is being logged:
  `dmesg | grep DOCKER-BLOCK`

---

## Problem: Explicit allow rule not working

### Symptoms
- Added rule: `ufw-docker-protect allow-port 443/tcp 192.168.1.100`
- Traffic from 192.168.1.100 still times out.

### Diagnosis Steps
1. Confirm the rule exists: `ufw-docker-protect list-rules | grep 443`
2. Check if it's in both IPv4 and IPv6:
   `iptables-save | grep 443`
   `ip6tables-save | grep 443`
3. Is the source IP correct?
   - Does the client's actual source IP match 192.168.1.100? (Check with `netstat` on the client.)
   - Are there intermediate NAT devices rewriting the source?

### Resolution
- If the rule is missing, retry with `--force`: 
  `ufw-docker-protect allow-port 443/tcp 192.168.1.100 --force`
- If the rule exists but doesn't work, check the container's network mode:
  `docker inspect <cid> | grep -A5 NetworkSettings`
- Verify the container is actually listening on the port:
  `docker exec <cid> netstat -tuln | grep 443`

---

## Problem: Performance degradation after adding many rules

### Symptoms
- Rule lookup or sync operations are slow (> 500ms).
- `ufw-docker-protect list-rules` takes > 1 second.

### Diagnosis Steps
1. Get a performance baseline: `ufw-docker-protect --benchmark`
2. Check rule count: `ufw-docker-protect list-rules --count`
3. Profile the sync operation: `time ufw-docker-protect sync`

### Resolution
- Consider archiving old rules: `ufw-docker-protect archive --older-than 90d`
- If you have > 1000 rules, consider splitting into multiple networks.
```

---

### 5.3 **API Reference & Usage Examples** (Operational)
**Issue**: The CLI is not formally specified.

**Recommendation** (`docs/CLI.md`):

```markdown
# UFW Docker Protect CLI Reference

## Commands

### allow-port
```
ufw-docker-protect allow-port <port>/<protocol> [source-ip] [--force] [--dry-run]

Examples:
  ufw-docker-protect allow-port 443/tcp 0.0.0.0/0
  ufw-docker-protect allow-port 8080/tcp 192.168.1.0/24
  ufw-docker-protect allow-port 53/udp ::/0  # IPv6
  ufw-docker-protect allow-port 5432/tcp --dry-run  # Preview only
  ufw-docker-protect allow-port 22/tcp --force  # Override idempotency
```

### revoke-port
```
ufw-docker-protect revoke-port <port>/<protocol> [source-ip]

Examples:
  ufw-docker-protect revoke-port 443/tcp 0.0.0.0/0
  ufw-docker-protect revoke-port 8080/tcp 192.168.1.0/24
```

### list-rules
```
ufw-docker-protect list-rules [--format json|table|iptables-save] [--filter key=value]

Examples:
  ufw-docker-protect list-rules
  ufw-docker-protect list-rules --format json
  ufw-docker-protect list-rules --filter port=443
  ufw-docker-protect list-rules --filter protocol=udp
```

### sync
```
ufw-docker-protect sync [--dry-run] [--verbose]

Rebuilds DOCKER-USER and DOCKER-UFW-PORTS chains from ports.json.
Idempotent — safe to call multiple times.
```

### doctor
```
ufw-docker-protect doctor [--repair] [--verbose]

Validates Docker daemon config, rule consistency, IPv6 parity.
With --repair, automatically fixes detected issues.
```

### rollback
```
ufw-docker-protect rollback [timestamp]

Lists available snapshots if no timestamp provided.
Restores the chain to a previous state.
```

### batch
```
ufw-docker-protect batch [file] [--dry-run]

Applies multiple rules from a file (one per line) atomically.
With --stdin, reads from standard input.

Format (one per line):
  allow 443/tcp 0.0.0.0/0
  revoke 8080/tcp 10.0.0.0/8
  allow 22/tcp --force
```

### export-rules
```
ufw-docker-protect export-rules [--format iptables-save|json] [> file]

Exports current rules for backup/audit.
Can be restored with: iptables-restore < file
```

### compare
```
ufw-docker-protect compare <state1> <state2>

Compares two rule snapshots and shows what changed.

Examples:
  ufw-docker-protect compare current snapshot-1682423154
  ufw-docker-protect compare snapshot-001 snapshot-002
```

---

## Exit Codes

| Code | Meaning |
|------|---------|
| 0    | Success |
| 1    | General error (check stderr for details) |
| 2    | Syntax error in rule |
| 3    | Rule already exists (idempotency) |
| 4    | Rule not found |
| 5    | Daemon misconfiguration |
| 10   | Permission denied (not root) |
```

---

### 5.4 **In-Code Diagnostics & Comments** (Operational & Knowledge)
**Issue**: Python code will be complex. Future maintainers need clear guidance on the rule logic.

**Recommendation** (example from `ufw_docker_protect.py`):

```python
def build_docker_user_chain(self):
    """
    Construct the DOCKER-USER chain with strict rule ordering.
    
    The chain implements AWS Security Group semantics:
    1. Allow established/related connections (conntrack).
    2. Allow localhost (127.0.0.1/32 and ::1/128).
    3. Return internal traffic (docker0, br+) without further filtering.
    4. Drop-in explicit allow rules from DOCKER-UFW-PORTS.
    5. Optional logging (if --enable-logging).
    6. Default deny (implicit via policy or explicit DROP).
    
    Why this order?
    - Established/related first: Stateful flows (e.g., replies to outbound
      connections) should pass without checking the allow list.
    - Localhost early: Local processes (e.g., reverse proxies) must never
      be blocked.
    - Internal traffic early: Containers on the same bridge talk freely
      (they're in the same trust domain).
    - Explicit allows late: User rules are checked last, allowing for
      performance optimization (most traffic hits earlier rules).
    - Default deny: Anything not explicitly allowed is dropped.
    
    IPv6 parity:
    - Every rule in this function is applied to BOTH iptables and ip6tables.
    - Test both separately; don't assume they're the same.
    
    Idempotency:
    - This function is safe to call multiple times. It:
      1. Checks if DOCKER-USER exists; creates if missing.
      2. Checks each rule before inserting (no duplicates).
      3. Flushes DOCKER-UFW-PORTS before rebuilding (no stale rules).
    """
    for iptables_cmd in ['iptables', 'ip6tables']:
        self._ensure_chain_exists(iptables_cmd, 'DOCKER-USER')
        self._ensure_chain_exists(iptables_cmd, 'DOCKER-UFW-PORTS')
        
        # Step 1: Established/related (must be first for performance)
        self._add_rule_if_missing(
            iptables_cmd, 'DOCKER-USER',
            '-m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT',
            line_num=0  # Insert at position 0
        )
        
        # Step 2: Localhost (IPv4 and IPv6 loopback are different)
        src = '127.0.0.1/32' if iptables_cmd == 'iptables' else '::1/128'
        self._add_rule_if_missing(
            iptables_cmd, 'DOCKER-USER',
            f'-s {src} -j ACCEPT',
            line_num=1
        )
        
        # ... etc.
```

---

## 6. ADDITIONAL QUICK WINS

### 6.1 **Container-Aware Rules** (Nice-to-Have)
**Feature**: Allow rules scoped to specific containers by name/ID.
```bash
ufw-docker-protect allow-port 443/tcp 0.0.0.0/0 --container my-app
# Only applies to container "my-app", not all containers
```

**Implementation**: Use container IP lookup (docker inspect) to insert rules scoped by source, not global.

### 6.2 **Integration with Docker Labels** (Nice-to-Have)
**Feature**: Read port allow/deny policies from container labels.
```dockerfile
LABEL ufw.allow.443.tcp="0.0.0.0/0"
LABEL ufw.allow.8080.tcp="10.0.0.0/8"
```

**Implementation**: Sync on container start (use Docker events API).

### 6.3 **Grafana/Prometheus Metrics** (Nice-to-Have)
**Feature**: Export rule count, sync times, denied packets.
```
ufw_docker_rules_total{protocol="tcp", port="443"} 1
ufw_docker_sync_duration_ms 42
ufw_docker_denied_packets_total 123
```

---

## Implementation Roadmap

### Phase 1 (Critical): Foundation
- [ ] Fix systemd unit (no `Restart=always`).
- [ ] Implement async job queue.
- [ ] Add rollback/snapshot system.
- [ ] Write unit tests (rule parsing, idempotency).

**Effort**: 2-3 weeks | **Risk**: Medium (testing required)

### Phase 2 (High-Value): Reliability
- [ ] Implement transaction log & atomic operations.
- [ ] Pre-flight validation & dry-run mode.
- [ ] Daemon state recovery (`doctor --repair`).
- [ ] Integration tests (Docker, iptables).

**Effort**: 2-3 weeks | **Risk**: Low (well-defined scope)

### Phase 3 (Polish): Operations
- [ ] Structured logging (JSON, rotation).
- [ ] Batch operations API.
- [ ] Rule export/compare commands.
- [ ] Comprehensive troubleshooting guide.

**Effort**: 1-2 weeks | **Risk**: Low (no core logic changes)

### Phase 4 (Bonus): Insights
- [ ] ADRs and architecture docs.
- [ ] Performance benchmarking.
- [ ] Chaos tests.
- [ ] Container-aware & label-driven rules.

**Effort**: 2-3 weeks | **Risk**: Low (optional enhancements)

---

## Summary: Priority Matrix

| Area | Item | Impact | Effort | Phase |
|------|------|--------|--------|-------|
| **Architecture** | Async queue | High | 3d | 1 |
| **Architecture** | Volume mount strategy | Medium | 1d | 1 |
| **Architecture** | IPv6 rules throughout | Critical | 2d | 1 |
| **Architecture** | Idempotency spec | Critical | 2d | 1 |
| **Reliability** | Rollback/snapshot | High | 3d | 1 |
| **Reliability** | Transaction log | High | 3d | 2 |
| **Reliability** | Pre-flight validation | High | 2d | 2 |
| **Reliability** | Daemon recovery | High | 2d | 2 |
| **Operations** | Logging | Medium | 2d | 3 |
| **Operations** | Rule export/compare | Medium | 2d | 3 |
| **Operations** | Batch API | Medium | 2d | 3 |
| **Operations** | Systemd fix | Critical | 0.5d | 1 |
| **Testing** | Unit tests | Medium | 3d | 1 |
| **Testing** | Integration tests | Medium | 3d | 2 |
| **Testing** | Chaos tests | Low | 2d | 4 |
| **Testing** | Performance baseline | Low | 1d | 4 |
| **Docs** | ADRs | Low | 1d | 4 |
| **Docs** | Troubleshooting runbook | Medium | 2d | 3 |
| **Docs** | CLI reference | Medium | 1d | 3 |
| **Docs** | In-code comments | Medium | 2d | 3 |

---

## Final Notes

Your core logic fix (the IPv6-aware rule ordering) is sound and well-articulated. The gaps are primarily in the engineering surrounding it: reliability, testing, observability, and user experience. A production-grade tool needs all five dimensions. Start with Phase 1 (systemd fix + async queue + snapshots), then iterate based on real-world usage. Good luck!
