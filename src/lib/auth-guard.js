import { getSupabaseClient } from "./supabase.js";

// Shared client-side gate for every portal page (retailer/sales_rep/installer
// for now; admin/hq.html joins this in Phase 2). Real access control is still
// enforced server-side by RLS — this only prevents portal markup/data from
// rendering to a browser with no valid session/role, per Section 1.2.
export async function requireRole(allowedRoles, { loginPage = "/login.html" } = {}) {
  const db = getSupabaseClient();

  const {
    data: { session },
  } = await db.auth.getSession();

  if (!session) {
    location.href = `${loginPage}?next=${encodeURIComponent(location.pathname)}`;
    return null;
  }

  // A user can legitimately hold several roles at once (admin via user_roles; sales_rep /
  // installer / retailer via their approved identity records). my_access() returns all of
  // them, so a page admits anyone holding ANY of its allowed roles — one login can enter
  // every app it genuinely holds, not just a single user_roles.role.
  const { data: access } = await db.rpc("my_access");
  const held = access || {};
  const matched = (allowedRoles || []).find((r) => held[r]);
  if (!matched) {
    location.href = loginPage;
    return null;
  }

  return { session, role: matched, db };
}

export function homeForRole(role) {
  switch (role) {
    case "admin":
      return "/hq.html";
    case "installer":
      return "/installer.html";
    case "sales_rep":
      return "/tech.html";
    // retailer.html doesn't exist yet (Phase 7) — fall back to the login
    // page's own post-login placeholder until it's built.
    default:
      return "/login.html";
  }
}
