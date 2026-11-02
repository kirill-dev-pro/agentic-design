import { defineConfig } from 'drizzle-kit'

export default defineConfig({
	dialect: 'turso',
	schema: './src/schema.ts',
	out: './migrations',
	dbCredentials: { url: process.env.DATABASE_URL ?? 'file:./data.db' },
})
