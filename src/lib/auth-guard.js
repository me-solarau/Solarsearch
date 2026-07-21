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

  const { data: roleRow } = await db
    .from("user_roles")
    .select("role")
    .eq("user_id", session.user.id)
    .single();

  const role = roleRow?.role;
  if (!role || !allowedRoles.includes(role)) {
    location.href = loginPage;
    return null;
  }

  return { session, role, db };
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
