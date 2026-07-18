# AX Svr — Infrastructure (Overview)

> **Audience:** internal engineering (infra / DBA / web). **Status:** Production deployed (10 VMs).
> **Source of truth:** private repo `github.com/minh0607/ax-svr-docs` — every command, config, and script lives under `docs/`. This wiki space is the map; the repo is the territory.

AX Svr is a fully high-available web platform on virtual machines: two load-balanced Nginx proxies (with a Keepalived VIP) front two Windows/IIS web servers; a 3-node PostgreSQL 17 cluster (Patroni + etcd) with automatic failover holds the data; a NAS serves web source; pgBackRest provides point-in-time backups. Production is **air-gapped**. The guiding principles are **no single point of failure**, **least-privilege access**, and **copy-paste-exact runbooks**.

![Architecture](../images/en/axsvr-architecture.png)

> Upload `docs/images/en/axsvr-architecture.png` as an attachment on this page.

## Child pages

This space is split into one page per component. Suggested order:

| # | Page | What it covers |
|---|------|----------------|
| 01 | **Architecture & Network** | Big-picture request flow, network topology, full host inventory |
| 02 | **Proxy HA** | Nginx + Keepalived VIP, TLS termination, load balancing |
| 03 | **Database HA** | PostgreSQL 17, Patroni + etcd, failover, multi-host connection |
| 04 | **Web / IIS** | Windows 2025 + IIS, deploy-to-local (`D:\app`), SPA/health |
| 05 | **NAS** | Samba source store, deploy-to-local, why not serve off NAS |
| 06 | **Backup** | pgBackRest (Plan B) + off-site (3-2-1), PITR, risk warning |
| 07 | **Security** | Air-gap, role-based firewall, DB three-layer access control |
| 08 | **Database Toolkit** | `axdb.sh`, the schema-per-app access model |
| 09 | **DevDB** | Standalone PG17 for the dev team |
| 10 | **Operations** | Common runbooks (onboarding, grants, audit, migration) |

## Deployment status

**Deployed (10 VMs):** 2 proxy, 2 web, 3 DB, NAS, DevDB — production is live.

**Monitoring:** the `mon` node was **not** built; the company's existing **Zabbix/Grafana** is used instead. `docs/axsvr-phase6-monitoring.md` (Prometheus/Grafana) is kept as reference only.

**Open items:**
- Integrate the cluster into the company Zabbix/Grafana.
- Off-site backup (`repo2`) to complete a 3-2-1 posture — Phase 5b.

## Repository map

| Area | Location |
|------|----------|
| Phase 0 — OS / network / hardening / autoinstall | `docs/axsvr-phase0-setup.md`, `docs/axsvr-autoinstall.md` |
| Phase 1 — PostgreSQL HA (etcd + Patroni) | `docs/axsvr-phase1-db.md` |
| Phase 2 — NAS | `docs/axsvr-phase2-nas.md` |
| Phase 3 — Web / IIS | `docs/axsvr-phase3-web-iis.md` |
| Phase 4 — Proxy HA | `docs/axsvr-phase4-proxy.md` |
| Phase 5 — Backup + off-site | `docs/axsvr-phase5-backup.md`, `docs/axsvr-backup-offsite.md` |
| Phase 6 — Monitoring (reference) | `docs/axsvr-phase6-monitoring.md` |
| DevDB | `docs/axsvr-devdb-setup.md` |
| DB toolkit | `docs/db-scripts/` |
| Firewall scripts | `docs/firewall/apply-firewall.sh`, `apply-firewall-windows.ps1` |
| Diagrams (EN / VI) | `docs/images/en/` · `docs/images/` |
| These wiki pages | `docs/confluence/` |

---
*Confluence: create this as the parent page, and the 01–10 pages as children. Paste each as Markdown and upload referenced PNGs as attachments.*
