import pg from 'pg';

// One connection pool per process. Everything that talks to the database
// borrows a connection from here; nothing else opens connections.
export function createPool(connectionString: string): pg.Pool {
  return new pg.Pool({
    connectionString,
    application_name: 'opsflow-api',     // visible in pg_stat_activity
    max: 10,                             // connections kept open at most
    idleTimeoutMillis: 30_000,           // close connections idle for 30 s
    connectionTimeoutMillis: 5_000,      // give up if no connection within 5 s
    statement_timeout: 10_000,           // Postgres cancels any query running over 10 s
  });
}