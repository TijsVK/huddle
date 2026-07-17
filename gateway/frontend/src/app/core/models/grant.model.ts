export interface Grant {
  container: string;
  until: number;
}

export type GrantMap = Record<string, Grant>;

/** Root grant (passwordless sudo for the default `vscode` user). */
export interface RootGrant {
  until: number;
  permanent: boolean;
}

export type RootGrantMap = Record<string, { until: number }>;

/**
 * Sentinel `until` value (unix seconds, 2100-01-01) marking a grant that never
 * expires. Any grant with `until >= PERMANENT_UNTIL` is treated as permanent.
 */
export const PERMANENT_UNTIL = 4102444800;
