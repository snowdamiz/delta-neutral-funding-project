export const DATABASE_RESET_APPROVAL = "WIPE PAPER DATABASE";

export function approvedDatabaseReset(body: string): boolean {
  try {
    const parsed = JSON.parse(body) as { approval?: unknown };
    return parsed !== null &&
      typeof parsed === "object" &&
      Object.keys(parsed).length === 1 &&
      parsed.approval === DATABASE_RESET_APPROVAL;
  } catch {
    return false;
  }
}
