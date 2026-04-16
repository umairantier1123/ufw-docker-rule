# UFW Docker Protect: Quick Improvement Checklist

## Top 15 Actionable Items (Prioritized by Impact + Effort)

### Phase 1: Critical Foundation (Do First)
- [ ] **Fix systemd unit** — Remove `Restart=always` from `Type=oneshot` (2 hours)
  - Add: `ExecStartPre=-/usr/local/bin/ufw-docker-protect doctor --repair`
  - Add logging: `StandardOutput=journal StandardError=journal`
  
- [ ] **Implement async job queue** — Use `asyncio.Queue` for rule updates (3-4 days)
  - Prevents race conditions during container churn
  - Add file lock: `/run/ufw-docker-protect.lock` with timeout
  
- [ ] **IPv6 parity throughout** — Every rule applied to `iptables` AND `ip6tables` (2 days)
  - Create helper: `apply_rule(rule, action, both_ipv4_and_ipv6=True)`
  - Test matrix: verify every allow/deny on both stacks
  
- [ ] **Idempotency audit** — Use `iptables -C` before insert, deduplicate on startup (2 days)
  - Always check rule exists: `iptables -C DOCKER-UFW-PORTS ... && return`
  - Scan `iptables-save` on boot, delete dupes, rebuild from `ports.json`
  
- [ ] **Rollback + snapshot system** — Keep last 5 snapshots, provide `rollback <ts>` (3 days)
  - Before each operation: `iptables-save > /var/lib/ufw-docker-protect/snapshot-$(date +%s).rules`
  - Add `rollback` command: restores the chain from a named snapshot
  
- [ ] **Unit tests** — At least 30 tests covering parsing, idempotency, IPv6 (3 days)
  - Rule syntax validation (edge cases)
  - Idempotency check
  - IPv4/IPv6 parity
  - Rollback behavior

**Subtotal: 14-16 days (1 developer, 2-3 weeks)** ✓ Core reliability

---

### Phase 2: Reliability Hardening (Do Next)
- [ ] **Transaction log** — Log every rule change with status + error (2 days)
  - Format: `TXN_ID | ACTION | RULE_ID | STATUS | TIMESTAMP | ERROR`
  - On startup, scan for dangling transactions and rollback
  
- [ ] **Pre-flight validation + dry-run** — Syntax check before applying (2 days)
  - Port range check (1-65535)
  - CIDR validation
  - Conflict detection
  - `--dry-run` flag for preview
  
- [ ] **Daemon health recovery** — Auto-repair missing chains (1 day)
  - `doctor --repair` recreates `DOCKER-USER`, rebuilds from `ports.json`
  - Optional systemd timer: run every 30 minutes
  
- [ ] **Integration tests** — Real Docker + iptables scenarios (3 days)
  - Test: default-deny, explicit allow, IPv6 parity, rule revocation
  - Test: Docker restart during sync, manual iptables edits
  
- [ ] **Structured logging** — JSON format, rotation, audit trail (2 days)
  - Log file: `/var/log/ufw-docker-protect/activity.log`
  - Include: timestamp, action, rule, status, user, change_set_id
  - Rotate: keep 30 days by default

**Subtotal: 10 days (1 developer, 1.5 weeks)** ✓ Operations-ready

---

### Phase 3: Operations Polish (Do After MVP Works)
- [ ] **Batch operations API** — Add rules/revoke from file or stdin (2 days)
  - `ufw-docker-protect batch rules.txt` or `cat rules.txt | ufw-docker-protect batch --stdin`
  - Atomic: all-or-nothing on errors
  
- [ ] **Rule export/compare** — `export-rules`, `list-rules --filter`, `compare` (2 days)
  - `list-rules --format json|table|iptables-save`
  - `export-rules > backup.rules` for manual restore
  - `compare snapshot-1 snapshot-2` shows added/removed/changed
  
- [ ] **Comprehensive troubleshooting guide** — Common issues + diagnosis steps (2 days)
  - PDF/Markdown: 10-15 common failure modes
  - Include: diagnostic commands, resolution steps
  
- [ ] **CLI reference** — Formal spec for all commands (1 day)
  - man page or docs/CLI.md
  - Exit codes, examples, format specs
  
- [ ] **In-code diagnostics** — Comments + docstrings explaining rule logic (2 days)
  - Comment each rule step in `build_docker_user_chain()`
  - Docstrings for all public methods

**Subtotal: 9 days (1 developer, 1+ weeks)** ✓ Operational confidence

---

### Phase 4: Nice-to-Haves (Future Enhancements)
- [ ] **ADRs (Architecture Decision Records)** — Document why, not just what (1 day)
  - ADR-001: IPv6 rule fix (why `-i` not `-o`)
  - ADR-002: Async queue vs. sync
  
- [ ] **Performance benchmarking** — Baseline and regression tracking (1 day)
  - Benchmark: sync time, add_rule time, list_rules time, doctor time
  - Target: sync < 200ms for 100 rules
  
- [ ] **Chaos tests** — Docker restart, iptables manual edits, disk-full (2 days)
  
- [ ] **Container-aware rules** — Scope rules to specific containers (2 days)
  - `ufw-docker-protect allow-port 443/tcp 0.0.0.0/0 --container my-app`
  
- [ ] **Docker label integration** — Read policies from container labels (2 days)
  - `LABEL ufw.allow.443.tcp="0.0.0.0/0"`

**Subtotal: 8 days (optional)** ✓ Future-proofing

---

## Implementation Order (Recommended)

1. **Week 1**: Systemd unit fix + async queue + IPv6 rules + idempotency + snapshot system
2. **Week 2**: Transaction log + pre-flight validation + daemon recovery + unit tests
3. **Week 3**: Integration tests + structured logging + batch API + rule export
4. **Week 4**: Troubleshooting guide + CLI reference + in-code comments + ADRs (as time allows)

---

## Risk Mitigation

| Risk | Mitigation |
|------|-----------|
| Async queue introduces deadlock | Use timeouts on locks, extensive testing |
| Rule idempotency is complex | Unit test thoroughly, test with `iptables-save` inspection |
| IPv6 parity is easy to miss | Create a test matrix, check both stacks in every test |
| Rollback during critical operation | Use transaction log to detect incomplete rollbacks |
| Users don't understand snapshots | Include clear examples in troubleshooting guide |

---

## Definition of Done

A feature is complete when:
- [ ] Code is written and reviewed
- [ ] Unit tests pass (>90% coverage)
- [ ] Integration tests pass (real Docker + iptables)
- [ ] Manual testing on a test VM confirms behavior
- [ ] Documentation is updated (CLI ref, comments, examples)
- [ ] Edge cases are documented (e.g., "idempotency window is 1ms")
- [ ] Performance is baselined (if applicable)

---

## Questions for Your Team

1. **Async complexity**: Is introducing asyncio acceptable, or do you want a simpler blocking queue with systemd-timer retry?
2. **Volume mounts**: Is persistent state in `/var/lib/ufw-docker-protect/` acceptable, or do you need ephemeral (rebuild on boot)?
3. **Audit trail**: Is JSON logging sufficient, or do you need database/centralized logging integration?
4. **Testing environment**: Can you provision a test VM with Docker + iptables for integration tests?
5. **Release timeline**: MVP by end of Q2? Full polish by Q3?

---

## Success Metrics

- **Phase 1**: Tool works reliably in production for 1 month with zero unplanned downtime
- **Phase 2**: All rule changes are atomic, recoverable, and auditable
- **Phase 3**: Operations team can diagnose and fix issues without engineering help
- **Phase 4**: Users can extend the tool for custom scenarios (e.g., container-specific rules)

---

**Last Updated**: 2025-04-16  
**Estimated Total Effort**: 6-8 weeks (1 developer, full-time) to full polish
