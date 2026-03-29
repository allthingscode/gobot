# Reference: Awesome Agentic Patterns

## Objective

This document references the [Awesome Agentic Patterns](https://agentic-patterns.com/) library (GitHub: [nibzard/awesome-agentic-patterns](https://github.com/nibzard/awesome-agentic-patterns)) - a curated editorial library of AI agent design patterns, trade-offs, and operating models. This resource should inform architectural decisions when designing and implementing gobot features.

---

## Overview

**Website:** https://agentic-patterns.com/  
**Repository:** https://github.com/nibzard/awesome-agentic-patterns  
**Patterns:** 157 patterns across 8 categories  
**Status:** Active open-source reference (as of March 2026)

The library is organized into two primary domains:
1. **Architecture** - How agents are structured and orchestrated
2. **Operations** - How agents are run, monitored, and improved

---

## Pattern Categories

### 1. Orchestration & Control
Patterns for managing agent workflows, decision-making, and execution flow.

**Key Patterns Relevant to GoBot:**
- **Action-Selector Pattern** - Route user intents to specialized handlers while maintaining centralized oversight
- **Workspace-Native Multi-Agent Orchestration** - Coordinate multiple agents within a shared workspace context
- **Specification-Driven Agent Development** - Define agent behavior through formal specifications before implementation
- **Human-in-the-Loop Approval Framework** - Insert human approval gates for high-risk functions

**Relevant GoBot Features:**
- F-001 Spawn Tool (sub-agent creation)
- F-012 Strategic Hooks
- F-038 Per-Specialist Model Routing
- F-044 Agent State Policies

### 2. Context & Memory
Patterns for managing agent state, memory, and context windows.

**Key Patterns Relevant to GoBot:**
- **Schema-Guided Graph Retrieval for Multi-Hop Reasoning** - Structured knowledge retrieval
- **Context Compaction** - Summarizing older turns to preserve context window space
- **Memory Consolidation** - Async consolidation of session memories
- **Session Isolation** - Per-channel-peer isolation for privacy

**Relevant GoBot Features:**
- F-002 SQLite Memory
- F-013 Session Isolation
- F-015 Context Compaction
- F-028 Memory Consolidation
- F-029 Search Memory Tool
- F-030 Vector Semantic Memory
- F-037 Timestamped Session Logs

### 3. Security & Safety
Patterns for securing agent operations and ensuring safe execution.

**Key Patterns Relevant to GoBot:**
- **Zero-Trust Agent Mesh** - Cryptographic identity and delegation between agents
- **Tool Sandboxing** - Isolating tool execution in sandboxed environments
- **PII Secret Masking** - Preventing leakage of sensitive information
- **DM Pairing** - Authorization workflows for unknown senders

**Relevant GoBot Features:**
- F-014 DM Pairing
- F-019 PII Secret Masking
- F-020 Immutable Audit Trail
- F-021 Secure Secrets
- F-024 Tool Sandboxing
- F-040 Google OAuth DPAPI
- F-041 MCP Secrets DPAPI

### 4. Feedback Loops & Reliability
Patterns for evaluating, monitoring, and improving agent performance.

**Key Patterns Relevant to GoBot:**
- **LLM Observability** - Span-level tracing of agent workflows
- **Circuit Breakers** - Fail-fast protection for external service calls
- **Intelligent Retry** - Exponential backoff with jitter for resilience
- **Transactional Checkpoints** - Session state persistence for recovery

**Relevant GoBot Features:**
- F-004 Preflight Diagnostics
- F-005 Behavioral Testing Suite
- F-006 Integration Stress Tests
- F-016 Circuit Breakers
- F-017 Intelligent Retry
- F-018 Transactional Checkpoints
- F-022 OpenTelemetry
- F-023 Health Heartbeat
- F-026 E2E Simulation
- F-027 Race Protection

### 5. UX & Collaboration
Patterns for human-agent interaction and collaborative workflows.

**Key Patterns Relevant to GoBot:**
- **Human-in-the-Loop Approval Framework** - Multi-channel approval interfaces
- **Markdown Logging** - Human-readable session logs

**Relevant GoBot Features:**
- F-003 HTML Reports
- F-037 Timestamped Session Logs
- F-043 Telegram Formatting

---

## Pattern Maturity Levels

The library categorizes patterns by maturity:
- **Validated in Production** - Battle-tested in real systems
- **Established** - Well-documented with clear implementations
- **Emerging** - New patterns gaining adoption
- **Proposed** - Experimental patterns under consideration

When implementing GoBot features, prioritize patterns marked as "validated in production" or "established" for core infrastructure, while "emerging" patterns may be appropriate for experimental features.

---

## Integration with GoBot Architecture

### Current Alignment

GoBot's existing architecture already aligns with several patterns from this library:

1. **Session Management** - GoBot's checkpoint/resume system aligns with "Transactional Checkpoints"
2. **Memory System** - SQLite FTS5 with consolidation aligns with "Memory Consolidation" patterns
3. **Hooks System** - F-012 Strategic Hooks align with "Action-Selector" and observability patterns
4. **Security** - DM Pairing and secret management align with "Zero-Trust" principles

### Gap Analysis

When reviewing the backlog, consider these patterns that may need additional attention:

1. **Multi-Agent Orchestration** - While GoBot has spawn_agent, broader multi-agent patterns may need consideration
2. **Observability** - OpenTelemetry integration (F-022) should reference LLM Observability patterns
3. **Human-in-the-Loop** - Approval frameworks for high-risk operations (email sending, task deletion)
4. **Vector Semantic Memory** - F-030 should consider graph retrieval patterns

---

## Decision Guide

The site provides a decision guide at `/decision` that helps teams choose patterns based on:
- System maturity (prototype vs production)
- Risk tolerance
- Team size and expertise
- Integration requirements

When planning new GoBot features, consult this guide to select appropriate patterns before implementation.

---

## References

- Main Site: https://agentic-patterns.com/
- Pattern Catalog: https://agentic-patterns.com/patterns
- Pattern Graph: https://agentic-patterns.com/graph
- Decision Guide: https://agentic-patterns.com/decision
- GitHub: https://github.com/nibzard/awesome-agentic-patterns

---

## Backlog Alignment Analysis

The following existing GoBot backlog items should explicitly reference and consider patterns from the Awesome Agentic Patterns library:

### High Priority Updates

#### F-022: OpenTelemetry Integration
**Current Gap:** References Honeycomb.io but not the agentic-patterns "LLM Observability" pattern.
**Recommendation:** Add reference to `/patterns/llm-observability` which specifically covers span-level tracing of agent workflows, visual UI debugging, and workflow linking. This pattern is marked as "proposed" in the library but provides concrete guidance on tracing agent "thought" processes.

#### F-030: Vector Semantic Memory
**Current Gap:** Focuses on technical implementation (chromem-go, usearch) but doesn't reference graph-based retrieval patterns.
**Recommendation:** Add reference to `/patterns/schema-guided-graph-retrieval` (newly added March 2026) for multi-hop reasoning. This pattern specifically addresses structured knowledge retrieval which complements the hybrid BM25+vector approach already planned.

#### F-044: Agent State Policies
**Current Gap:** Already references agentic-patterns.com (good!), but could expand.
**Recommendation:** The filesystem-based state pattern is correctly referenced. Consider also:
- `/patterns/transactional-checkpoints` for atomic state transitions
- `/patterns/circuit-breaker-for-agent-operations` for failure recovery during state persistence

### Medium Priority Updates

#### F-001: Spawn Tool / Subagent Orchestration
**Current Gap:** References CrewAI and AutoGen but not agentic-patterns multi-agent patterns.
**Recommendation:** Add reference to:
- `/patterns/workspace-native-multi-agent-orchestration` - for coordinating multiple agents within shared workspace context
- `/patterns/action-selector-pattern` - for routing intents to specialized handlers

#### F-012: Strategic Hooks
**Current Gap:** References go-kit and LangChain but not agentic-patterns.
**Recommendation:** The Action-Selector pattern from agentic-patterns directly aligns with the hook system design. Consider cross-referencing for validation.

#### F-015: Context Compaction
**Current Gap:** References LangChain and Anthropic but not agentic-patterns.
**Recommendation:** While not explicitly listed in the pattern catalog, the "Context Compaction" concept aligns with memory management patterns. Monitor for future pattern additions in this category.

### Low Priority / Monitoring

#### F-016: Circuit Breakers
**Current Gap:** References Azure pattern but not agentic-patterns.
**Recommendation:** The library has a "Circuit Breaker for Agent Operations" pattern. Consider cross-referencing for additional agent-specific guidance (e.g., handling LLM API failures vs traditional HTTP services).

#### F-024: Tool Sandboxing
**Current Gap:** References OpenClaw and gVisor.
**Recommendation:** Monitor for future "Zero-Trust Agent Mesh" pattern updates which covers cryptographic identity between agents - relevant for secure tool delegation.

### Potential New Feature Candidates

Based on pattern gaps identified:

1. **Human-in-the-Loop Approval Framework** - No direct equivalent in backlog
   - Pattern: `/patterns/human-in-loop-approval-framework` (validated in production)
   - Use case: Approval gates for high-risk operations (email sending, task deletion, shell commands)
   - Priority: Consider for P2 feature

2. **Specification-Driven Development** - Process improvement
   - Pattern: `/patterns/specification-driven-agent-development`
   - Use case: Formalize feature specification process (already partially done with backlog format)
   - Priority: Documentation/process improvement

3. **Workspace-Native Multi-Agent Orchestration** - Architecture enhancement
   - Pattern: `/patterns/workspace-native-multi-agent-orchestration`
   - Use case: Enhance F-001 with workspace-aware agent coordination
   - Priority: Consider for Phase 4 (Gateway mode)

## Notes

- This reference was added March 2026
- The library is actively maintained with new patterns added regularly
- Consider subscribing to updates for new patterns relevant to GoBot's architecture
- Cross-reference with OpenClaw Design (05-openclaw-design.md) for complementary patterns
- **Action Item:** Review and update F-022, F-030, F-044 to include specific agentic-patterns references
