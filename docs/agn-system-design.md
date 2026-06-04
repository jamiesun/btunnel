# AGN System Design

## 1. Purpose

AGN means **Agent-defined Network**.

AGN is a control, service, and automation layer built around btunnel. btunnel
remains the small encrypted data plane. AGN adds autonomous node agents,
service discovery, signed network intent, health probing, AI-assisted
operations, and user-facing APIs without embedding that complexity into
btunnel itself.

The first AGN implementation target is `agnbot`: an autonomous agent process
that runs beside every btunnel node.

```text
btunnel = encrypted packet forwarding engine
agnbot  = autonomous operator for one btunnel node
AGN     = the network formed by cooperating agnbots
```

This document is written for implementation agents. It defines intent,
boundaries, flows, features, and acceptance criteria. It deliberately avoids
implementation pseudocode.

## 2. Design Goals

### 2.1 Primary Goals

1. **Keep btunnel minimal**
   - btunnel owns TUN, UDP, crypto, hub relay, policy, and local UDS commands.
   - btunnel must not embed AI, service registry, HTTP APIs, UI, authentication
     services, or service-specific proxy logic.

2. **Make agnbot the autonomous operator**
   - agnbot manages one local btunnel daemon.
   - agnbot reads local intent documents.
   - agnbot talks to local btunnel through UDS or `ptctl`.
   - agnbot talks to other agnbots through the AGN overlay or a configured
     control channel.
   - agnbot can use an LLM to generate plans, diagnose failures, and write
     intent drafts, but deterministic validation decides what is executable.

3. **Define network intent with human-readable documents**
   - A new node can start from a Markdown file, usually `AGN.md`.
   - Markdown is for humans and AI context.
   - Machine-executable intent must live in a strict structured block inside
     the Markdown file.

4. **Enable self-organizing private networks**
   - Any node may run agnbot, whether it is a Hub or a Spoke.
   - Hub agnbots may coordinate registration and discovery, but the model must
     not require all intelligence to live inside the Hub.
   - Nodes should exchange signed intent, service metadata, health state, and
     policy requirements.

5. **Support NAT-friendly home/office/device networks**
   - Spokes normally live behind NAT.
   - Spokes initiate outbound connectivity to a public Hub.
   - Hub/Spoke relay is the primary v1 model.
   - NAT hole punching is explicitly out of scope for the first AGN release.

6. **Expose services, not protocols**
   - AGN may publish that a node offers services such as SOCKS5, DNS, RADIUS,
     or HTTP API.
   - AGN must not implement those service protocols inside btunnel.
   - AGN service registry describes, verifies, probes, and authorizes access.
     Traffic still flows through btunnel.

### 2.2 Non-Goals

AGN v1 must not:

- Load third-party logic into the btunnel process.
- Add a btunnel plugin ABI.
- Make btunnel listen on a remote management TCP port.
- Turn the Hub into a SOCKS5, DNS, RADIUS, or HTTP reverse proxy.
- Depend on LLM output without deterministic validation.
- Store PSKs, session keys, or private keys in generated Markdown drafts.
- Use a service discovery feature to bypass btunnel policy and peer
  authorization.

## 3. System Roles

### 3.1 btunnel

btunnel is the data plane.

Responsibilities:

- Create and manage the TUN device.
- Bind and process UDP tunnel traffic.
- Encrypt, authenticate, and relay packets.
- Enforce peer identity, per-peer PSK, session epoch, anti-replay, and
  `allowed_src`.
- Maintain local policy state.
- Expose local UDS commands for control.
- Report status and counters once the status API exists.

btunnel must stay usable without AGN.

### 3.2 agnbot

agnbot is the node-local autonomous operator.

Responsibilities:

- Read local AGN intent documents.
- Validate intent against deterministic rules.
- Generate btunnel config or runtime commands.
- Start, stop, and monitor the local btunnel process when configured to do so.
- Query local btunnel status.
- Publish node intent to other agnbots.
- Receive and verify signed service metadata.
- Probe services through the overlay.
- Generate AGN.md drafts with LLM assistance.
- Present plans to users before applying risky changes.
- Keep an audit log of all applied changes.

agnbot must not implement btunnel's packet format or become a data-plane
replacement.

### 3.3 Hub agnbot

A Hub agnbot is an agnbot running on a public or stable relay node.

Additional responsibilities:

- Coordinate Spoke registrations.
- Generate drafts for newly observed nodes.
- Verify signed service metadata.
- Maintain a service list for the AGN.
- Probe service reachability from the Hub's network perspective.
- Publish reachable service records to authorized nodes.
- Help diagnose relay, policy, NAT, and route issues.

The Hub agnbot may coordinate, but it must not be the only place where network
intent can exist.

### 3.4 Spoke agnbot

A Spoke agnbot runs on a NATed home, office, laptop, or device node.

Responsibilities:

- Describe local routes and services.
- Sign local service metadata.
- Register with one or more Hub agnbots.
- Keep local btunnel connected.
- Request access to remote services or routes.
- Verify remote service metadata before use.

## 4. High-Level Architecture

```text
User / Admin / AI
      |
      v
  agnbot API / CLI / TUI / Web UI
      |
      +-----------------------------+
      |                             |
      v                             v
 local AGN.md                 peer agnbots
 signed intent                signed intent/service state
      |                             |
      v                             v
 deterministic validator       AGN overlay/control channel
      |
      v
 local btunnel UDS / ptctl
      |
      v
 btunnel daemon
      |
      v
 encrypted UDP tunnel
```

Key architectural rule:

```text
agnbot may depend on btunnel's public control/status interface.
btunnel must not depend on agnbot.
```

## 5. Trust and Security Model

### 5.1 Node Identity

Every AGN node has a stable node identity independent of btunnel session state.

Requirements:

- Each node has a node id.
- Each node has a signing identity.
- Signed documents must bind the signature to the node id.
- A Hub must reject a service document whose `node_id` does not match the peer
  identity that submitted it.
- A node identity must be revocable.

The concrete signing algorithm is an implementation choice. The first version
should prefer a simple modern signature scheme with stable library support in
the agnbot implementation language.

### 5.2 btunnel Link Secrets

btunnel uses per-peer PSKs and session epochs. AGN must treat these as low-level
transport secrets.

Rules:

- AGN.md must not contain generated session keys.
- Hub-generated drafts must never include PSKs.
- If agnbot writes btunnel config, it must apply strict file permissions.
- Service metadata signing keys and btunnel PSKs are different trust domains.

### 5.3 Signed Intent

An AGN document becomes executable only when it is signed or explicitly trusted
by local policy.

Required signed fields:

- document version
- node id
- routes provided
- services declared
- visibility or ACL rules
- expiration or validity window
- signer identity

The signature must cover canonical structured content, not arbitrary Markdown.

### 5.4 AI Safety Boundary

LLM output is advisory.

Rules:

- LLM may generate a draft.
- LLM may explain diagnosis.
- LLM may propose a plan.
- Deterministic validation must approve any executable plan.
- Risky changes require user confirmation unless an explicit automation policy
  permits them.

Risky changes include:

- Adding or removing peers.
- Changing PSKs or identity keys.
- Publishing a service.
- Widening route access.
- Exposing SOCKS5, DNS, RADIUS, admin HTTP APIs, or other sensitive services.

## 6. Intent Document Model

### 6.1 File Format

The default human-facing file is `AGN.md`.

Markdown provides:

- human explanation
- operational notes
- AI context
- change history

Machine-readable intent lives inside a fenced block:

```text
```agn
...
```
```

The content of the `agn` block must use a strict structured format such as YAML
or JSON. The implementation must define one canonical syntax and reject mixed or
ambiguous input.

### 6.2 Intent Categories

An AGN intent document may describe:

- node identity
- node role
- Hub connection intent
- routes the node provides
- routes the node wants to access
- services the node provides
- service visibility
- local health checks
- automation policy

### 6.3 Observed vs Declared State

Hub-generated drafts must separate observed facts from declared intent.

Observed facts:

- current endpoint
- last seen time
- detected overlay address
- reachable ports
- traffic counters
- route behavior

Declared intent:

- service name
- service type
- service visibility
- allowed consumers
- route access policy
- user-approved descriptions

Observed facts alone must not publish a service. They can only produce a draft.

## 7. Service Registry Model

### 7.1 Purpose

The service registry answers:

- Which node offers a service?
- What type of service is it?
- Where is it reachable inside the AGN overlay?
- Is it currently reachable?
- Who is allowed to see or use it?
- Which signed document declared it?

The service registry does not proxy service traffic.

### 7.2 Service Types

AGN must support arbitrary service types by metadata, including:

- `socks5`
- `dns`
- `radius`
- `http`
- `https`
- `tcp`
- `udp`
- `custom`

Service-specific behavior must be optional. The default capability is reachability
probing and listing.

### 7.3 Service Metadata Requirements

Every service record must include:

- service id
- service type
- node id
- address inside the overlay or allowed node subnet
- port
- protocol
- visibility
- declaration source
- signature status
- reachability status

Sensitive service types must default to private visibility.

Sensitive examples:

- SOCKS5
- DNS recursive resolver
- RADIUS
- admin HTTP APIs
- database ports
- router management ports

### 7.4 Reachability Probing

Hub agnbot may probe services, but only within strict limits.

Rules:

- Probing must be rate-limited.
- Probing must be scoped to declared services unless the user explicitly enables
  discovery mode.
- Discovery mode must default to off.
- Probe results must be stored as observed state, not declared intent.
- UDP services must support an unknown or partial reachability state.

### 7.5 Service Publication

A service becomes publishable only when:

- its declaration is valid
- its signature is valid
- its address belongs to the declaring node's allowed route scope
- its visibility policy allows the requesting viewer
- its expiration has not passed

Reachability may affect status, but an unreachable service can still exist as a
declared service with `down` status.

## 8. Logical Flows

### 8.1 New Node Onboarding

Goal: add a new Spoke with minimal manual work.

Flow:

1. User installs btunnel and agnbot on the new node.
2. User provides either an `AGN.md` file or bootstrap credentials.
3. Local agnbot validates local identity and intent.
4. Local agnbot starts or checks btunnel.
5. Local agnbot connects to a Hub agnbot through the available control channel.
6. Hub agnbot verifies the node identity and proposed intent.
7. Hub agnbot generates or updates btunnel peer/policy commands as needed.
8. Local agnbot applies local btunnel commands through UDS.
9. Hub agnbot applies Hub-side btunnel commands through its local UDS.
10. Both sides verify reachability.
11. The onboarding result is written as an audit entry.

### 8.2 Hub-Generated AGN.md Draft

Goal: reduce user configuration effort.

Flow:

1. Hub agnbot observes a new or incomplete node.
2. Hub agnbot collects known context.
3. Hub agnbot asks the LLM to draft a human-readable AGN.md.
4. The draft marks all inferred services and permissions as pending.
5. User or node agnbot reviews the draft.
6. Approved structured intent is signed.
7. Hub agnbot verifies the signature.
8. Hub agnbot publishes the node intent.

### 8.3 Service Registration

Goal: publish a service without embedding service logic in btunnel.

Flow:

1. Node agnbot reads local service metadata.
2. Node agnbot validates service address, type, visibility, and expiration.
3. Node agnbot signs the service declaration.
4. Node agnbot sends the declaration to Hub agnbot.
5. Hub agnbot verifies signature and node binding.
6. Hub agnbot verifies that service address is inside the node's authorized
   route scope.
7. Hub agnbot probes reachability if probing is enabled.
8. Hub agnbot updates the service list.
9. Authorized users or nodes can query the service list.

### 8.4 AI-Assisted Diagnosis

Goal: explain and fix network failures safely.

Flow:

1. User asks agnbot a diagnosis question.
2. agnbot collects deterministic evidence:
   - local btunnel status
   - peer status
   - policy list
   - counters
   - service registry state
   - recent audit entries
   - reachability probe results
3. agnbot passes sanitized evidence to the LLM.
4. LLM produces an explanation and a proposed plan.
5. agnbot validates the plan deterministically.
6. User confirms if the plan changes network state.
7. agnbot applies changes through local UDS or peer agnbot coordination.
8. agnbot verifies the outcome and records an audit entry.

### 8.5 Policy and Route Intent Application

Goal: convert high-level intent into btunnel runtime state.

Flow:

1. agnbot loads signed route intent.
2. agnbot computes required local and Hub-side forwarding behavior.
3. agnbot verifies that each policy target maps to an authorized peer.
4. agnbot submits low-level btunnel commands through UDS.
5. agnbot confirms policy state through `ptctl` or UDS status.
6. agnbot records the applied intent version.

## 9. Functional Requirements

### 9.1 agnbot Core

- Run as a long-lived node-local daemon.
- Provide a CLI for local administration.
- Optionally provide an HTTP API or local UI.
- Read `AGN.md` and structured AGN intent.
- Validate structured intent before execution.
- Maintain local state and audit logs.
- Interact with local btunnel only through public control/status interfaces.
- Never link against btunnel internal source code.

### 9.2 btunnel Control Integration

agnbot needs these btunnel-facing capabilities:

- query daemon status
- list peers
- list policies
- add/remove policies
- add/remove/update peers when btunnel supports runtime peer commands
- inspect counters and last seen values when available
- print or apply network plans when available

If btunnel lacks a capability, agnbot must report it explicitly rather than
guessing or editing internal files unsafely.

### 9.3 AGN Document Handling

- Parse exactly one structured AGN block from `AGN.md`, unless explicit multi-block
  support is added later.
- Reject malformed structured blocks.
- Reject unsupported document versions.
- Reject unsigned remote intent unless local policy marks that source as trusted.
- Preserve human Markdown sections when updating the structured block.
- Keep generated drafts clearly marked as drafts.

### 9.4 Service Registry

- Register signed service metadata.
- Verify service metadata signatures.
- Enforce node id binding.
- Enforce address ownership against allowed route scope.
- Probe reachability.
- Maintain service status.
- Support service list queries.
- Support service detail queries.
- Support service expiration.
- Support service removal or revocation.

### 9.5 AI Interaction

- Support interactive planning.
- Generate AGN.md drafts.
- Explain current network topology.
- Diagnose unreachable nodes or services.
- Suggest btunnel commands or AGN intent patches.
- Require deterministic validation before execution.
- Require confirmation for risky changes unless automation policy allows them.

### 9.6 Audit and Rollback

- Record every applied change.
- Include actor, source document, validation result, commands issued, and
  verification result.
- Support showing the last applied plan.
- Support rollback for changes that have a reversible representation.
- Never rely on an LLM transcript as the only audit source.

## 10. Interfaces

### 10.1 Local btunnel Interface

The preferred local interface is btunnel's UDS control protocol or `ptctl`.

Required properties:

- local-only by default
- deterministic replies
- JSON output for machine consumers where possible
- non-zero exit or explicit error result on failure
- no remote TCP management listener in btunnel

### 10.2 agnbot-to-agnbot Interface

The agnbot mesh interface may use HTTPS, gRPC, WebSocket, or another transport.

Requirements:

- authenticated
- encrypted
- versioned
- replay-resistant
- able to exchange signed intent documents
- able to exchange service registry updates
- able to exchange health summaries

Transport selection is an implementation decision. The protocol semantics are
more important than the transport.

### 10.3 User Interface

AGN should support at least:

- local CLI
- interactive onboarding
- status and diagnosis command
- service list command
- generate draft command
- apply plan command

A Web UI is optional for v1, but the system should not make a future UI hard.

## 11. Data Boundaries

### 11.1 Static Intent

Static intent lives in:

- `AGN.md`
- signed service metadata
- local trust policy

Static intent answers: what should exist?

### 11.2 Runtime State

Runtime state lives in agnbot's local state store and btunnel runtime state.

Runtime state answers: what is happening now?

Examples:

- current endpoint
- last seen
- reachability status
- counters
- active policies
- applied document version
- recent failures

Static intent and runtime state must not be merged into a single ambiguous file.

### 11.3 Secrets

Secrets include:

- btunnel per-peer PSKs
- node signing private keys
- controller tokens
- LLM provider tokens

Rules:

- Hub-generated drafts must not include secrets.
- Audit logs must not include secrets.
- LLM prompts must not include secrets.
- Config files containing secrets must have restrictive permissions.

## 12. Implementation Phases

### Phase 1: AGN Intent and Local Operator

Deliver:

- `agnbot` daemon skeleton
- CLI
- `AGN.md` parser
- deterministic validator
- local btunnel status integration
- local audit log
- draft generation without applying changes

Acceptance:

- agnbot can read a valid `AGN.md`
- agnbot rejects invalid intent
- agnbot can query local btunnel
- agnbot can explain current local state

### Phase 2: Hub/Spoke Onboarding

Deliver:

- Hub agnbot registration endpoint
- Spoke agnbot registration client
- signed node intent exchange
- Hub-generated AGN.md draft
- local apply plan through btunnel UDS

Acceptance:

- a new Spoke can register with a Hub
- Hub generates a draft from observed context
- user approval turns draft into signed intent
- btunnel policy/peer state is updated through public commands only

### Phase 3: Service Registry

Deliver:

- signed service metadata
- service list
- reachability probing
- visibility and ACL model
- service query command

Acceptance:

- node can publish a service
- Hub verifies signature and address scope
- unauthorized viewers cannot see private services
- reachable/unreachable status is reported accurately

### Phase 4: AI Network Operator

Deliver:

- LLM-backed interactive mode
- topology explanation
- diagnosis workflow
- plan generation
- safe apply and verification

Acceptance:

- LLM can draft but cannot bypass validation
- risky changes require confirmation
- all applied changes are auditable
- failed changes are reported with evidence

### Phase 5: Production Hardening

Deliver:

- systemd units
- packaging
- key rotation policy
- backup/restore of AGN state
- metrics export
- integration tests across multiple nodes

Acceptance:

- a Hub and two Spokes can be deployed from docs
- service registry survives agnbot restart
- btunnel remains usable if agnbot is stopped
- agnbot restart does not disrupt data-plane forwarding

## 13. Acceptance Checklist

### 13.1 Architecture Acceptance

- [ ] btunnel has no dependency on AGN or agnbot.
- [ ] agnbot does not import btunnel internal source modules.
- [ ] agnbot controls btunnel only through public local interfaces.
- [ ] btunnel remains functional without agnbot.
- [ ] AGN service registry does not proxy service protocols.

### 13.2 Security Acceptance

- [ ] Remote intent is signed.
- [ ] Service metadata is signed.
- [ ] Signatures bind to node id.
- [ ] Service addresses are checked against authorized route scope.
- [ ] Secrets are never sent to LLM prompts.
- [ ] Generated drafts never include PSKs or private keys.
- [ ] Risky changes require explicit approval or explicit automation policy.

### 13.3 AI Acceptance

- [ ] LLM output is marked as draft or proposal.
- [ ] Deterministic validation runs before apply.
- [ ] Apply plans show exact intended changes.
- [ ] Applied plans are audited.
- [ ] AI diagnosis cites concrete evidence from status, counters, policies, or
      service probes.

### 13.4 Service Registry Acceptance

- [ ] A node can publish a signed service.
- [ ] Hub rejects unsigned service metadata.
- [ ] Hub rejects metadata for the wrong node id.
- [ ] Hub rejects service addresses outside the node's allowed scope.
- [ ] Hub can mark services reachable, unreachable, or unknown.
- [ ] Service visibility is enforced.

### 13.5 Operations Acceptance

- [ ] agnbot can query local btunnel status.
- [ ] agnbot can report peer health.
- [ ] agnbot can report service health.
- [ ] agnbot can produce an onboarding draft.
- [ ] agnbot can apply a validated plan.
- [ ] agnbot can show audit history.
- [ ] Stopping agnbot does not stop existing btunnel forwarding.

## 14. Key Design Decisions

1. **Process separation over plugin loading**
   - AGN uses sidecar agents.
   - btunnel does not load plugins.

2. **Documents over hidden state**
   - User intent should be visible and reviewable.
   - Runtime state remains separate.

3. **LLM as operator assistant, not authority**
   - AI generates drafts and explanations.
   - Validators and user policy decide execution.

4. **Hub as coordinator, not gateway**
   - Hub may coordinate discovery and relay traffic.
   - Hub must not become a multi-protocol application proxy.

5. **Service registry over service proxy**
   - AGN helps users find and authorize services.
   - Service traffic remains normal overlay traffic.

## 15. Open Design Questions

These must be answered before implementation reaches production:

1. What signature scheme and identity file format should AGN v1 use?
2. Should AGN state use a local embedded database or append-only files?
3. Should agnbot-to-agnbot communication use the btunnel overlay, direct HTTPS,
   or both?
4. What is the minimum btunnel status API needed by agnbot v1?
5. How should service visibility be represented: node allow-list, group
   allow-list, tags, or policy expressions?
6. How should AGN handle multiple Hubs?
7. What is the revocation model for a lost node identity?
8. What information can be safely sent to an LLM provider by default?

## 16. Implementation Guidance for Agents

When implementing AGN:

- Start with boundaries, not UI.
- Do not modify btunnel unless a required public interface is missing.
- Prefer small, observable milestones.
- Keep every LLM-assisted action explainable and auditable.
- Treat signed structured intent as the source of truth.
- Treat Markdown prose as context only.
- Keep the first service registry minimal: metadata, signature, reachability,
  visibility.
- Build the system so it remains useful without any LLM provider configured.

