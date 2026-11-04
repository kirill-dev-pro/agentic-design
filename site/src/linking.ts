// What happens when Google or GitHub sign in to an account that already exists (account linking,
// src/workerstack.ts). Better Auth links only when the provider says the email is verified; the
// existing account keeps its password and sessions (owner's decision, 2026-11-04), and its email
// counts as verified from then on, proven by the provider.
//
// Accepted risk, recorded with the decision (cloud-design decision 17): the site sends no email
// yet, so a password account's email is never verified. Whoever registered someone else's address
// with a password before its owner signs in with Google keeps that password. Revisit when email
// verification works: then link only to verified accounts again.
import { eq } from 'drizzle-orm'

import { user } from './schema'

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Db = any

export async function secureLinkedAccount(db: Db, linked: { userId: string; providerId: string }) {
	if (linked.providerId === 'credential') return
	await db.update(user).set({ emailVerified: true, updatedAt: new Date() }).where(eq(user.id, linked.userId))
}
