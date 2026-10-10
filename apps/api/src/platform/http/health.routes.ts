import type { FastifyPluginAsync } from 'fastify';
import type pg from 'pg';

interface HealthOptions {
  pool: pg.Pool;
}

// /healthz: is the process alive? Never touches dependencies, so a database
//           outage does not make the platform restart a healthy process.
// /readyz:  can it serve traffic right now? Checks the database; a 503 tells the
//           load balancer to stop sending requests here until it recovers.
export const healthRoutes: FastifyPluginAsync<HealthOptions> = async (app, { pool }) => {
  app.get('/healthz', { logLevel: 'warn' }, async () => ({ status: 'ok' }));

  app.get('/readyz', { logLevel: 'warn' }, async (request, reply) => {
    try {
      await pool.query('SELECT 1');
      return { status: 'ok', database: 'ok' };
    } catch (err) {
      request.log.warn({ err }, 'readiness check failed: database unreachable');
      return reply.code(503).send({ status: 'unavailable', database: 'unreachable' });
    }
  });
};