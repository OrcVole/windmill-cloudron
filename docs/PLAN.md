# PLAN — Windmill for Cloudron

Refined from the foundation brief after Phase 0 ground-truthing. Effort tags per sub-phase; default
`max`. Gate discipline (field guide §11): a phase is done when its gate passes.

## Status snapshot (2026-06-27)

| Phase | State |
|---|---|
| 0 Orientation, prior art, scaffolding | ✅ done |
| 1 Architecture & ADRs (0001–0006) | ✅ done |
| 2 Package skeleton (Dockerfile/start/supervisor/nginx/manifest/icon/docs) | ✅ done |
| 3 Local build + smoke | ✅ done — smoke gate green |
| 4 Deploy to live Cloudron + functional validation | ✅ done — live, healthy, all code langs + webhook + email |
| 5 Integration with sibling AI apps (incl. bge reranker) | ✅ done — egress + real bge rerank call |
| 6 Backup / restore | ◐ partial — backup verified (incl. PG) during update; dedicated restore-into-fresh recommended on a throwaway |
| 7 Update / upgrade path | ✅ done — update applied, data persisted |
| 8 Hardening & compliance review | ◐ partial — posture set (ADR 0005), password changed, base_url set |
| 9 Docs, release, `CloudronVersions.json`, push to GitHub + Forgejo | ⏳ in progress |
| 10 Handoff | ⏳ in progress |

## Key decisions (locked)

- Single container, `MODE=standalone`, nginx-fronted, supervisor-managed. (ADR 0001)
- `cloudron/base` final stage; COPY the unmodified CE binary + runtimes. (ADR 0002)
- **Bundled PostgreSQL 16**, not the addon — empirically validated. (ADR 0003)
- All state in the bundled Postgres → rides `/app/data` backup; no external key file. (ADR 0004)
- nsjail/unshare off; trusted-author single-tenant posture; no Docker-step jobs. (ADR 0005)
- App-native auth, `optionalSso`, no `proxyAuth`; change default password is a checklist item. (ADR 0006)

## Remaining work (next actions)

### Phase 4 — live deploy + validation — **max**
- Publish the image (GHCR) and install on a Windmill subdomain, OR build on the box.
- On-box: log in, change the superadmin password, create a workspace, run a script in **each**
  language (Python/TS/Go/Bash/SQL), build a flow, set a schedule, fire a **webhook** (verifies
  `BASE_URL`), send an email via the `sendmail` addon.
- Confirm the security posture empirically (Docker-step job fails; native jobs run).

### Phase 5 — integration — **high**
- From a Windmill script, reach sibling apps over HTTPS (qdrant, tei, docling, langfuse,
  agentgateway, rustfs, ollama, and the **bge reranker**).
- Wire one concrete proof pipeline (e.g. docling → tei embeddings → qdrant; rerank via the bge
  reranker) and/or Windmill AI → agentgateway as an OpenAI-compatible endpoint.

### Phase 6 — backup/restore — **max**
- `cloudron backup create` → `cloudron restore` (net-zero) on a throwaway: state survives, entrypoint
  takes the "existing" path (no reseed), ownership/modes re-asserted.
- Destroy + restore into a fresh install; verify full recovery.

### Phase 7 — update — **max**
- `cloudron update` to a new package build: migrations run clean, data preserved, topology holds.
- Make the migration a standing gate; script the single-`ARG` version bump.

### Phase 8 — hardening — **max**
- Walk field guide §11 + Cloudron skills checklist; resource limits; ~60 s proxy-timeout mitigation;
  cookie/CORS/`BASE_URL` correctness.

### Phase 9 — release — **high**
- `CloudronVersions.json` (inlined manifest, registry digest, valid contactEmail, non-empty iconUrl,
  ≥1 mediaLinks, bracket changelog). Stranger-install gate. Tag + push to GitHub (OrcVole) and
  the private Forgejo mirror using the provided tokens (never committed). Lessons-Learned doc.

### Phase 10 — handoff — **medium**
- Final summary; known limitations; sync GitHub + Forgejo.
