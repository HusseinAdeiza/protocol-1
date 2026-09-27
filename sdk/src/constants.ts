/** Deepest tree the circuits accept. Matches `MAX_DEPTH` in `circuits/lib`. */
export const MAX_DEPTH = 32;

/** How many past roots the pool will accept a proof against. */
export const ROOT_HISTORY = 64;

/** ERC-2981's denominator. */
export const BPS_DENOM = 10_000n;

/** How long a seller's acceptance holds the buyer's settlement window open. */
export const ACCEPT_WINDOW_SECONDS = 72 * 60 * 60;
