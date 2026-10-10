import { existsSync } from 'node:fs';
import { defineConfig } from 'drizzle-kit';

// Locally, read the repo-root .env. In CI the variable comes from the environment.
if (existsSync('../../.env')) process.loadEnvFile('../../.env');

const url = process.env.MIGRATION_DATABASE_URL;
if (!url) throw new Error('MIGRATION_DATABASE_URL is not set (see .env.example)');

export default defineConfig({
  dialect: 'postgresql',
  schema: './src/schema.ts',
  out: './migrations',
  dbCredentials: { url },
  // Applied-migration records live in their own schema, which the app roles cannot see.
  migrations: { schema: 'drizzle', table: 'schema_migrations' },
});
