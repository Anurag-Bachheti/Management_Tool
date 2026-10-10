import { existsSync } from 'node:fs';
import { loadEnv } from '../config/env.js';
import { buildApp } from './app.js';
import { createDeps } from './deps.js';

const SHUTDOWN_TIMEOUT_MS = 10_000;

async function main(): Promise<void> {
  // Local development reads the repo-root .env. In production the platform sets
  // real environment variables, and variables that are already set always win.
  if (existsSync('../../.env')) process.loadEnvFile('../../.env');

  const env = loadEnv(process.env);
  const deps = createDeps(env);
  const app = await buildApp({ env, deps });

  // Graceful shutdown: stop accepting new requests, let in-flight ones finish,
  // close the database pool, then exit. Deploys and Ctrl+C both go through here.
  let shuttingDown = false;
  const shutdown = async (signal: NodeJS.Signals): Promise<void> => {
    if (shuttingDown) return;
    shuttingDown = true;
    app.log.info({ signal }, 'shutting down');

    const forceExit = setTimeout(() => {
      app.log.error('shutdown took too long, forcing exit');
      process.exit(1);
    }, SHUTDOWN_TIMEOUT_MS);
    forceExit.unref();

    try {
      await app.close();
      await deps.close();
      app.log.info('shutdown complete');
      // No process.exit() here: with nothing left running, Node exits by itself
      // with code 0, after the logger has flushed its last lines.
    } catch (err) {
      app.log.error({ err }, 'error during shutdown');
      process.exitCode = 1;
    }
  };
  process.once('SIGINT', () => void shutdown('SIGINT'));
  process.once('SIGTERM', () => void shutdown('SIGTERM'));

  await app.listen({ host: env.HOST, port: env.PORT });
}

main().catch((err: unknown) => {
  console.error(err instanceof Error ? err.message : err);
  process.exit(1);
});