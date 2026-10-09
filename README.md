# OpsFlow

Backend monorepo (pnpm workspaces).

## Layout

- `apps/api` — API server (`src/platform` for infrastructure, `src/modules` for features)
- `packages/contracts` — shared request/response contracts, one folder per module
- `packages/db` — database schema, migrations and seeds
- `packages/api-client` — typed client for the API
- `packages/config` — shared tsconfig, ESLint and Vitest config
- `infra` — Docker, Compose and database setup
- `tools/generators` — scaffolding for new modules and resources
- `docs` — architecture decision records (`adr`) and ER diagrams (`erd`)

## Getting started

Requires Node 24+ and pnpm.

```sh
pnpm install
pnpm build
pnpm test
```
