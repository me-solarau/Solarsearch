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

  return { session, role: matched, db, access: held };
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

// Apps a role can open (retailer has no portal page yet, so it's omitted here).
const ROLE_APPS = {
  admin: { label: "HQ", href: "/hq.html" },
  sales_rep: { label: "Sales Tech", href: "/tech.html" },
  installer: { label: "Installer", href: "/installer.html" },
};

// Floating app-switcher for multi-role logins. Reads my_access() (or a passed access
// object), and if the user holds more than one app, injects a small fixed control so they
// can hop between the apps they hold instead of typing URLs. No-op for single-role users.
export async function mountRoleSwitcher(access) {
  const db = getSupabaseClient();
  if (!access) {
    const { data } = await db.rpc("my_access");
    access = data || {};
  }
  const here = location.pathname.replace(/\/+$/, "") || "/";
  const apps = Object.entries(ROLE_APPS).filter(([r]) => access[r]).map(([, a]) => a);
  if (apps.length < 2) return; // nothing to switch between
  if (document.getElementById("ss-role-switcher")) return;

  const wrap = document.createElement("div");
  wrap.id = "ss-role-switcher";
  wrap.style.cssText =
    "position:fixed;top:10px;right:10px;z-index:9999;font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif";
  const btn = document.createElement("button");
  btn.textContent = "Apps ▾";
  btn.style.cssText =
    "background:#0F2E27;color:#fff;border:none;border-radius:999px;padding:7px 13px;font-size:.8rem;font-weight:700;cursor:pointer;box-shadow:0 2px 8px rgba(0,0,0,.2)";
  const menu = document.createElement("div");
  menu.style.cssText =
    "display:none;margin-top:6px;background:#fff;border:1px solid #DBE5DE;border-radius:10px;overflow:hidden;box-shadow:0 6px 20px rgba(0,0,0,.15);min-width:150px";
  apps.forEach((a) => {
    const isHere = a.href.replace(/\/+$/, "") === here;
    const item = document.createElement("a");
    item.href = a.href;
    item.textContent = a.label + (isHere ? "  •" : "");
    item.style.cssText =
      "display:block;padding:10px 14px;color:#0F2E27;text-decoration:none;font-size:.85rem;font-weight:600" +
      (isHere ? ";background:#E8F1EA;cursor:default" : "");
    if (isHere) item.addEventListener("click", (e) => e.preventDefault());
    menu.appendChild(item);
  });
  btn.addEventListener("click", () => {
    menu.style.display = menu.style.display === "none" ? "block" : "none";
  });
  document.addEventListener("click", (e) => {
    if (!wrap.contains(e.target)) menu.style.display = "none";
  });
  wrap.appendChild(btn);
  wrap.appendChild(menu);
  document.body.appendChild(wrap);
}
