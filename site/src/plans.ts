// Plans and entitlements (docs/cloud-design.md, decisions 2 and 13). Code reads
// entitlements, never the plan's name, so limits and prices change here or per workspace
// (workspace_plan.entitlements) without touching the checks.

export type Entitlements = {
	/** May hold cloud documents (M2: sync, web editing, realtime). */
	cloudDocs: boolean
	/** Assets and versions, each blob counted once per workspace. */
	storageBytes: number
	sharedFiles: number
	maxPenBytes: number
	maxAssetBytes: number
}

const MB = 1024 * 1024

export const PLANS = {
	free: {
		// decision 16: cloud documents are free until billing exists
		cloudDocs: true,
		storageBytes: 1024 * MB,
		sharedFiles: 100,
		maxPenBytes: 50 * MB,
		maxAssetBytes: 25 * MB,
	},
	pro: {
		cloudDocs: true,
		storageBytes: 10 * 1024 * MB,
		sharedFiles: 10_000,
		maxPenBytes: 50 * MB,
		maxAssetBytes: 25 * MB,
	},
} satisfies Record<string, Entitlements>

export type Plan = keyof typeof PLANS

/** A workspace's entitlements: its plan's, with the overrides stored for it. */
export function entitlementsOf(plan: string, overrides: string | null | undefined): Entitlements {
	const base: Entitlements = PLANS[(plan in PLANS ? plan : 'free') as Plan]
	let extra: Partial<Entitlements> = {}
	try {
		const parsed = JSON.parse(overrides || '{}')
		if (parsed && typeof parsed === 'object') extra = parsed
	} catch {
		// a broken override never widens anything
	}
	const out = { ...base }
	for (const key of Object.keys(base) as (keyof Entitlements)[]) {
		if (typeof extra[key] === typeof base[key]) (out as Record<string, unknown>)[key] = extra[key]
	}
	return out
}
