import { keccak256, toHex, type Hex } from "viem";

export const ROLE_KEYS = {
  governance: `0x${"0".repeat(64)}` as Hex,
  guardian: keccak256(toHex("optara.role.GUARDIAN")),
  riskAdmin: keccak256(toHex("optara.role.RISK_ADMIN")),
  seriesCreator: keccak256(toHex("optara.role.SERIES_CREATOR")),
  oracleAdmin: keccak256(toHex("optara.role.ORACLE_ADMIN")),
  venueAdmin: keccak256(toHex("optara.role.VENUE_ADMIN")),
} as const;

export const TRUSTED_ROLES = [
  { key: ROLE_KEYS.governance, label: "Governance", short: "Governance", help: "Can approve products, enable venues and grant roles." },
  { key: ROLE_KEYS.guardian, label: "Guardian", short: "Guardian", help: "Can pause or reduce risk quickly." },
  { key: ROLE_KEYS.riskAdmin, label: "Risk admin", short: "Risk", help: "Can make conservative risk changes." },
  { key: ROLE_KEYS.seriesCreator, label: "Series creator", short: "Lister", help: "Can list approved option series." },
  { key: ROLE_KEYS.oracleAdmin, label: "Oracle admin", short: "Oracle", help: "Can approve settlement oracle configs." },
  { key: ROLE_KEYS.venueAdmin, label: "Venue admin", short: "Venue", help: "Can register and activate venue markets." },
] as const;

export type TrustedRoleKey = (typeof TRUSTED_ROLES)[number]["key"];
export type RoleMap = Map<Hex, boolean>;

export function roleNames(roleMap?: RoleMap, short = false): string[] {
  if (!roleMap) return [];
  return TRUSTED_ROLES.filter((r) => roleMap.get(r.key)).map((r) => (short ? r.short : r.label));
}

export function hasAnyTrustedRole(roleMap?: RoleMap): boolean {
  return roleNames(roleMap).length > 0;
}

export function hasRole(roleMap: RoleMap | undefined, key: Hex): boolean {
  return !!roleMap?.get(key);
}
