import type pg from 'pg';
import type { Env } from '../config/env.js';
import { createPool } from '../platform/db/pool.js';

// Everything the app needs from the outside world, created in one place.
// Tests can build their own Deps and pass them to buildApp().
export interface Deps {
  pool: pg.Pool;
  close(): Promise<void>;
}

export function createDeps(env: Env): Deps {
  const pool = createPool(env.DATABASE_URL);
  return {
    pool,
    close: () => pool.end(),
  };
}