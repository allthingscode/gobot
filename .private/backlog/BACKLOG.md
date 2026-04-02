# Gobot Strategic Backlog

Master index for the Go-native Strategic Edition agent. This backlog is the single source of truth for all planned features, active bugs, and architectural refactors.

---

## **Prioritization Principles**

All items in this backlog must be prioritized strictly according to the following principles:
1. **Increase Stability:** Fixes for crashes, silent failures, and core reliability issues (e.g., config validation, resource leaks) always take precedence over new features.
2. **Decrease Fragility:** Refactoring brittle systems (e.g., error handling, resource cleanup) and expanding test coverage are prioritized above cosmetic or QoL improvements.
3. **Avoid New Bugs:** Implementation plans must include defensive coding practices and adequate observability (logs, metrics) to prevent the introduction of new regressions.

---

## **Workflow: Agent vs Groomer Responsibilities**

| Role | Responsibilities |
|:---|:---|
| **Agent** | Update item `status` to final state (`Production`, `Resolved`). **Never delete or archive items.** |
| **Groomer** | Archive items by moving to `archived/` folder and updating index. Handle deduplication and rot detection. |

**⚠️ CRITICAL**: The `.private/` folder is gitignored. Deleted files cannot be recovered from git history. Always preserve items—let the Groomer handle archival.

---

## **Status Key**

- 🚀 **Production**: Deployed and active.
- 🏗️ **In Progress**: Actively being implemented.
- 📋 **Planning**: Spec written and approved.
- 📝 **Draft**: Initial idea, spec incomplete.
- 🗃️ **Archived**: No longer relevant or superseded.
- ✅ **Resolved**: Fixed and verified.

---

## **Features (`features/`)**

| ID | Title | Category | Status | Specialist | Priority |
|:---|:---|:---:|:---:|:---:|:---|
| F-017 | [Intelligent Retry with Backoff](features/F-017_Intelligent_Retry.md) | Reliability | 📋 | Architect | P2 |
| F-025 | [Local RAG (Local Vector Store)](features/F-025_Local_RAG.md) | Feature | 📝 | Researcher | P3 |
| F-030 | [Vector/Semantic Memory Layer (Phase 3)](features/F-030_Vector_Semantic_Memory.md) | Feature | 📝 | Researcher | P3 |
| F-046 | [HTTP Gateway & Telegram Control Flags](features/F-046_Gateway_Enabled_Flags.md) | Feature | 🚀 | Architect | P2 |
| F-047 | [Advanced Context Pruning & Compaction Policies](features/F-047_Advanced_Context_Management.md) | Feature | 📝 | Researcher | P2 |
| F-049 | [Reflection & Planning Loop](features/F-049_Reflection_Loop.md) | Feature | 📝 | Architect | P2 |
| F-053 | [Configuration Validation](features/F-053_Config_Validation.md) | Reliability | 📋 | Architect | P1 |
| F-054 | [Circuit Breaker Integration](features/F-054_Circuit_Breaker_Integration.md) | Reliability | 📋 | Architect | P2 |
| F-055 | [Fault Injection Tests](features/F-055_Fault_Injection_Tests.md) | Testing | 📋 | Architect | P2 |
| F-056 | [Concurrency Safety Metrics](features/F-056_Concurrency_Safety_Metrics.md) | Observability | 📋 | Architect | P2 |
| F-058 | [Automated Documentation Checks](features/F-058_Automated_Documentation_Checks.md) | Process | 📝 | Architect | P3 |
| F-059 | [Implement `gobot logs` Command](features/F-059_Gobot_Logs_Command.md) | Observability | 📋 | Architect | P2 |

---

## **Chores (`chores/`)**

| ID | Title | Category | Status | Specialist | Priority |
|:---|:---|:---:|:---:|:---:|:---|
| C-003 | [Configuration Schema Cleanup](chores/C-003_Config_Cleanup.md) | Refactor | 📋 | Architect | P3 |
| C-004 | [Resource Cleanup Pattern](chores/C-004_Resource_Cleanup_Pattern.md) | Reliability | 📋 | Architect | P1 |
| C-005 | [Error Handling Standardization](chores/C-005_Error_Handling_Standardization.md) | Refactor | 📋 | Architect | P2 |
| C-006 | [Troubleshooting Tools Documentation](chores/C-006_Troubleshooting_Tools_Documentation.md) | Documentation | 📋 | Architect | P2 |

---

## **Bugs (`bugs/`)**

| ID | Title | Status | Severity |
|:---|:---|:---:|:---|
| B-010 | [bot.go Stale Package Comment After Telego Migration](bugs/B-010_Bot_Package_Stale_Comment.md) | 📋 | Low (P3) |
| B-011 | [Doctor Probe Leaks Telego Bot Instance](bugs/B-011_Doctor_Probe_Telego_Leak.md) | 📋 | Low (P3) |
| B-013 | [Tool Failure Log Missing Session Key](bugs/B-013_Tool_Failure_Log_Missing_Session.md) | 📋 | Low (P3) |
| B-026 | [Storage Root Inconsistency in config.json](bugs/B-026_Config_StorageRoot_Mismatch.md) | 📋 | High (P1) |

---

## **Archived (`archived/`)**

| ID | Title | Status | Archived Date |
|:---|:---|:---:|:---|
| B-001 | [Telegram Thread/Topic Routing](archived/B-001_Telegram_Threads.md) | 🗃️ | 2026-03-29 |
| B-002 | [Markdown Escaping Fragility](archived/B-002_Markdown_Escaping.md) | 🗃️ | 2026-03-29 |
| B-003 | [Long Polling Reliability](archived/B-003_Polling_Reliability.md) | 🗃️ | 2026-03-29 |
| B-004 | [Cron Job BOM Failure](archived/B-004_Cron_BOM_Failure.md) | 🗃️ | 2026-03-29 |
| B-005 | [Cron Jobs Initialization Fix](archived/B-005_Cron_Jobs_Never_Fire.md) | 🗃️ | 2026-03-29 |
| B-006 | [Dead Code & Unused Config Fields](archived/B-006_Dead_Code.md) | 🗃️ | 2026-04-02 |
| B-007 | [Missing Telegram Thread Support in Vendor](archived/B-007_Vendor_Thread_Support.md) | 🗃️ | 2026-03-29 |
| B-008 | [isDuplicate False Positive — msgID-only key](archived/B-008_Dedup_Key_ChatID_Missing.md) | 🗃️ | 2026-04-02 |
| B-009 | [Log File Failure Silently Disables PII Redaction](archived/B-009_Redaction_Disabled_On_Log_Failure.md) | 🗃️ | 2026-03-29 |
| B-012 | [F-019 Missing Tests: WithAttrs + KindGroup Redaction](archived/B-012_F019_Missing_Test_Coverage.md) | 🗃️ | 2026-04-02 |
| B-014 | [Calendar Tool Returns Primary Calendar Only](archived/B-014_Calendar_Primary_Only.md) | 🗃️ | 2026-03-29 |
| B-015 | [Spawn Tool Missing Iteration Limit](archived/B-015_Spawn_Tool_Missing_Iteration_Limit.md) | 🗃️ | 2026-04-02 |
| B-016 | [Configuration & Constants Alignment](archived/B-016_Config_Alignment.md) | 🗃️ | 2026-04-01 |
| B-017 | [MCP Server Configuration Mapping Failure](archived/B-017_MCP_Mapping_Fix.md) | 🗃️ | 2026-04-01 |
| B-018 | [Doctor Panic on Short API Keys](archived/B-018_Doctor_Panic_Masking.md) | 🗃️ | 2026-04-01 |
| B-019 | [Cron Scheduler Test Race Condition](archived/B-019_Cron_Scheduler_Test_Race.md) | 🗃️ | 2026-04-02 |
| B-020 | [Cron Alert Bypasses Agent Loop](archived/B-020_Cron_Alert_Bypass_Agent_Loop.md) | 🗃️ | 2026-04-02 |
| B-021 | [Runner: Log Tool Call Sequence on Exhaustion](archived/B-021_Runner_Log_Tool_Sequence.md) | 🗃️ | 2026-04-02 |
| B-022 | [Make maxToolIterations Configurable](archived/B-022_Configurable_Max_Tool_Iterations.md) | 🗃️ | 2026-04-02 |
| B-023 | [Per-Job Execution Timeout in Cron Scheduler](archived/B-023_Per_Job_Execution_Timeout.md) | 🗃️ | 2026-04-02 |
| B-024 | [Invalid Go Version in go.mod](archived/B-024_Go_Version_Invalid.md) | 🗃️ | 2026-04-01 |
| B-025 | [Upstream Hardcoded Paths in shell/redirect.go](archived/B-025_Upstream_Hardcoded_Paths.md) | 🗃️ | 2026-04-02 |
| B-027 | [RedirectCDrive Cross-Platform Path Failure](archived/B-027_Cross_Platform_Shell_Tests.md) | 🗃️ | 2026-04-02 |
| B-028 | [Shell Tool ProjectRoot Injection Fix](archived/B-028_Project_Root_Injection.md) | 🗃️ | 2026-04-02 |
| C-001 | [Review Documentation Audit Report](archived/C-001_Documentation_Audit_Review.md) | 🗃️ | 2026-03-29 |
| C-002 | [Document Release Process in OPERATING_MANUAL](archived/C-002_Document_Release_Process.md) | 🗃️ | 2026-04-02 |
| C-004 | [CI Robustness and Windows Support](archived/C-004_CI_Robustness.md) | 🗃️ | 2026-04-01 |
| F-001 | [Spawn Tool / Subagent Orchestration](archived/F-001_Spawn_Tool.md) | 🗃️ | 2026-04-02 |
| F-002 | [SQLite FTS5 Long-Term Memory](archived/F-002_SQLite_Memory.md) | 🗃️ | 2026-04-02 |
| F-003 | [High-Readability HTML Email Reports](archived/F-003_HTML_Reports.md) | 🗃️ | 2026-04-02 |
| F-004 | [Preflight Diagnostics Expansion](archived/F-004_Preflight_Diagnostics.md) | 🗃️ | 2026-04-02 |
| F-005 | [Automated Behavioral Testing Suite](archived/F-005_Behavioral_Testing_Suite.md) | 🗃️ | 2026-04-02 |
| F-006 | [Integration Stress & Concurrency Tests](archived/F-006_Integration_Stress_Tests.md) | 🗃️ | 2026-04-02 |
| F-007 | [Startup Script (start_gobot.ps1)](archived/F-007_Startup_Script.md) | 🗃️ | 2026-04-02 |
| F-008 | [`gobot init` Hardcoded Paths Fix](archived/F-008_Init_Command_Fix.md) | 🗃️ | 2026-04-02 |
| F-009 | [Gmail Native Re-auth Flow](archived/F-009_Gmail_Native_Reauth.md) | 🗃️ | 2026-04-02 |
| F-010 | [Web Search Tool (Custom Tool)](archived/F-010_Web_Search_Tool.md) | 🗃️ | 2026-04-01 |
| F-011 | [Strategic Log Auditor (clog command)](archived/F-011_Clog_Command.md) | 🗃️ | 2026-04-02 |
| F-012 | [Strategic Hook System (Zero-Core Pollution)](archived/F-012_Strategic_Hooks.md) | 🗃️ | 2026-04-02 |
| F-013 | [Granular Session Isolation (`per-channel-peer`)](archived/F-013_Session_Isolation.md) | 🗃️ | 2026-04-02 |
| F-014 | [Secure DM Pairing (Human-in-the-Loop)](archived/F-014_DM_Pairing.md) | 🗃️ | 2026-04-02 |
| F-015 | [Automatic Context Compaction](archived/F-015_Context_Compaction.md) | 🗃️ | 2026-04-02 |
| F-016 | [Circuit Breakers & Bulkhead Isolation](archived/F-016_Circuit_Breakers.md) | 🗃️ | 2026-04-02 |
| F-018 | [Transactional Checkpoint Writes](archived/F-018_Transactional_Checkpoints.md) | 🗃️ | 2026-04-02 |
| F-019 | [PII & Secret Masking](archived/F-019_PII_Secret_Masking.md) | 🗃️ | 2026-04-02 |
| F-020 | [Immutable Audit Trail](archived/F-020_Immutable_Audit_Trail.md) | 🗃️ | 2026-04-02 |
| F-021 | [Secure Secrets Manager](archived/F-021_Secure_Secrets.md) | 🗃️ | 2026-04-02 |
| F-022 | [OpenTelemetry Tracing](archived/F-022_OpenTelemetry.md) | 🗃️ | 2026-04-02 |
| F-023 | [Health Heartbeat](archived/F-023_Health_Heartbeat.md) | 🗃️ | 2026-04-02 |
| F-024 | [Tool Sandboxing](archived/F-024_Tool_Sandboxing.md) | 🗃️ | 2026-04-02 |
| F-026 | [E2E Simulation Suite](archived/F-026_E2E_Simulation.md) | 🗃️ | 2026-04-02 |
| F-027 | [Race Condition Protection](archived/F-027_Race_Protection.md) | 🗃️ | 2026-04-02 |
| F-028 | [LLM-Driven Memory Consolidation](archived/F-028_Memory_Consolidation.md) | 🗃️ | 2026-04-02 |
| F-029 | [`search_memory` Agent Tool](archived/F-029_Search_Memory_Tool.md) | 🗃️ | 2026-04-02 |
| F-031 | [Config Helper Methods](archived/F-031_Config_Helper_Methods.md) | 🗃️ | 2026-04-02 |
| F-035 | [Windows Auto-Start (Task Scheduler)](archived/F-035_Windows_Auto_Start.md) | 🗃️ | 2026-04-02 |
| F-036 | [Gemini Search Grounding](archived/F-036_Gemini_Search_Grounding.md) | 🗃️ | 2026-04-02 |
| F-037 | [Timestamped Session Logs (Markdown)](archived/F-037_Timestamped_Session_Logs.md) | 🗃️ | 2026-04-02 |
| F-038 | [Per-Specialist Model Routing for Sub-Agents](archived/F-038_Per_Specialist_Model_Routing.md) | 🗃️ | 2026-04-02 |
| F-039 | [Task Write Operations — Complete + Update](archived/F-039_Task_Write_Operations.md) | 🗃️ | 2026-04-02 |
| F-040 | [Migrate Google OAuth Credentials to DPAPI](archived/F-040_Google_OAuth_DPAPI.md) | 🗃️ | 2026-04-02 |
| F-041 | [Migrate MCP Tool API Keys to DPAPI](archived/F-041_MCP_Secrets_DPAPI.md) | 🗃️ | 2026-04-02 |
| F-042 | [Version Management Setup](archived/F-042_Version_Management_Setup.md) | 🗃️ | 2026-04-02 |
| F-043 | [Semantic Telegram Formatter (HTML)](archived/F-043_Telegram_Formatting.md) | 🗃️ | 2026-04-02 |
| F-044 | [Agent State Policies and Standards](archived/F-044_Agent_State_Policies.md) | 🗃️ | 2026-04-02 |
| F-044.1 | [Core Types and Atomic Writes](archived/F-044.1_Core_Types_Atomic_Writes.md) | 🗃️ | 2026-04-02 |
| F-044.2 | [File-Based Locking with Timeout](archived/F-044.2_File_Locking.md) | 🗃️ | 2026-04-02 |
| F-044.3 | [Journal and Recovery](archived/F-044.3_Journal_Recovery.md) | 🗃️ | 2026-04-02 |
| F-044.4 | [State Manager](archived/F-044.4_State_Manager.md) | 🗃️ | 2026-04-02 |
| F-044.5 | [Integration with Agent/CLI](archived/F-044.5_Integration_CLI.md) | 🗃️ | 2026-04-02 |
| F-044.6 | [Durability Tests](archived/F-044.6_Durability_Tests.md) | 🗃️ | 2026-04-02 |
| F-045 | [PostTool Hook Implementation](archived/F-045_PostTool_Hook_Implementation.md) | 🗃️ | 2026-04-02 |
| F-048 | [Human-in-the-loop (HITL) Approval Framework](archived/F-048_HITL_Approval.md) | 🗃️ | 2026-04-02 |
| F-050 | [Installation and Onboarding UX](archived/F-050_Installation_UX.md) | 🗃️ | 2026-04-02 |
| F-051 | [Multi-Provider LLM Support](archived/F-051_Multi_Provider_LLM_Support.md) | 🗃️ | 2026-04-02 |
| F-052 | [Autonomous Execution for Scheduled Tasks](archived/F-052_Autonomous_Cron.md) | 🗃️ | 2026-04-02 |

---

## **Completed & Hardened**

- [x] **Spawn & Memory**: Subagent orchestration and FTS5 memory now in core production.
- [x] **Go-Native Auth**: Full `reauth` flow replaces Python dependence (**F-009**).
- [x] **Durable Storage**: Standardized on `D:\Gobot_Storage` for all assets.
- [x] **Precise Health Checks**: `gobot doctor` now uses live probes and precise token expiry.
- [x] **Message Reliability**: Deduplication and whitelist enforcement fully active.
- [x] **Automated Operations**: Startup script, Windows task scheduler, and log auditor (`clog`) in production.
- [x] **Gemini Search Grounding**: Morning briefing now uses real-time Google Search data (**F-036**).
- [x] **Multi-Provider LLM**: Native support for Gemini, Anthropic, and OpenAI-compatible providers (**F-051**).

---

## **Grooming Log**

**Last Groomed:** 2026-04-02T10:00:00-05:00
**Groomer:** Architect (Gemini CLI)

### Changes Made (This Session):
- ✅ **Backlog Maintenance**: Archived 61 items (Bugs: 12, Chores: 1, Features: 48) that were already moved to `archived/`.
- ✅ **Index Update**: Updated `BACKLOG.md` to reflect the current file system state.
- ✅ **Status Sync**: Verified and updated status for active items (F-017, B-026 set to Planning).
- ✅ **Link Verification**: Ensured all archived items point to the correct relative path.

### Previous Grooming (2026-04-01T23:55:00-05:00):
- ✅ **B-027 Resolved**: `RedirectCDrive` fixed with OS-agnostic `winBase` helper.
- ✅ **B-028 Resolved**: `projectRoot` injection improved.
- ✅ **Backlog Maintenance**: B-027 and B-028 added to the Bugs table and marked as resolved.

### Current Backlog State:
- **Features**: 11 active
- **Bugs**: 4 active
- **Chores**: 3 active
- **Archived**: 76 total

### Items Ready for Implementation:
| Priority | Item | Status |
|:---|:---|:---:|
| P2 | F-046: HTTP Gateway & Telegram Control Flags | 📝 Draft |
| P2 | F-047: Advanced Context Pruning | 📝 Draft |
| P2 | F-049: Reflection & Planning Loop | 📝 Draft |
| P3 | B-011: Doctor Probe Leaks Telego Bot Instance | 📋 Planning |
| P3 | C-003: Configuration Schema Cleanup | 📋 Planning |

---

## **🎯 Highest Priority Item for Next Sprint**

Based on the **Hardening First** prioritization matrix:

| Priority | Item | Type | Status | Rationale |
|:---|:---|:---:|:---:|:---|
| **P1** | **F-053: Configuration Validation** | Feature | 📋 Planning | **Stability**: Prevents runtime failures from config drift. Fail-fast with clear errors. |
ature | 📋 Planning | **Stability**: Prevents runtime failures from config drift. Fail-fast with clear errors. |
