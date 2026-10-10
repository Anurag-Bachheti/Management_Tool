import { randomUUID } from 'node:crypto';
import Fastify, { type FastifyInstance } from 'fastify';
import type { Env } from '../config/env.js';
import { healthRoutes } from '../platform/http/health.routes.js';
import type { Deps } from './deps.js';

export interface AppOptions {
  env: Env;
  deps: Deps;
}

// Accept a caller's request id only if it looks safe; otherwise make a new one.
const SAFE_REQUEST_ID = /^[A-Za-z0-9._-]{1,64}$/;

// Builds the Fastify instance without starting it. server.ts starts it;
// tests call buildApp() and send requests with app.inject(), no network needed.
export async function buildApp({ env, deps }: AppOptions): Promise<FastifyInstance> {
  const app = Fastify({
    logger:
      env.NODE_ENV === 'development'
        ? {
            level: env.LOG_LEVEL,
            transport: { target: 'pino-pretty', options: { translateTime: 'HH:MM:ss', ignore: 'pid,hostname' } },
          }
        : { level: env.LOG_LEVEL },
    genReqId: (req) => {
      const incoming = req.headers['x-request-id'];
      return typeof incoming === 'string' && SAFE_REQUEST_ID.test(incoming) ? incoming : randomUUID();
    },
  });

  // Every response carries its request id, so a user's bug report can be matched to the logs.
  app.addHook('onSend', async (request, reply) => {
    reply.header('x-request-id', request.id);
  });

  // An idle pooled connection can fail (for example if Postgres restarts).
  // Without a listener, Node would crash the whole process on that error.
  // Log only the message and code: the raw error carries the whole client object.
  deps.pool.on('error', (err: Error & { code?: string }) =>
    app.log.error({ code: err.code, message: err.message }, 'unexpected error on an idle database connection'),
  );

  await app.register(healthRoutes, { pool: deps.pool });

  return app;
}