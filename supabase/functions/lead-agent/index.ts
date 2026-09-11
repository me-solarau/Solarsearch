// lead-agent — "Billy", the Solarsearch AI lead-follow-up agent.
//
// Billy texts new leads from the Solarsearch Kudosity number, qualifies them
// (bill, timeline, ownership, roof, battery interest, existing solar, size
// preference), collects switchboard/meter/location photos for compliant
// inverter placement, and — the moment a lead qualifies — prices an official
// indicative estimate through the SAME quote_estimate engine HQ's Instant
// quote uses, texts it, then gauges budget fit and pushes toward the free
// on-site assessment (formal quote follows that). Conversation state lives in
// agent_threads; every message goes through sms-send so the sms_messages log
// stays the single audit trail.
//
// POST { lead_id }                    -> start a thread + send Billy's opener (HQ admin or service role)
// POST { inbound: { from, body } }   -> handle a customer reply (service role only; called by sms-inbound)
//   returns { handled: boolean } — sms-inbound falls back to its old canned
//   path when handled is false.
//
// Guards (in addition to sms-send's suppression/quiet-hours/opt-out gates):
//   never text our own numbers; hard cap of MAX_MSGS Billy messages per
//   thread; at most HOURLY_CAP Billy sends per number per hour. Dollar
//   figures come ONLY from quote_estimate — the model is forbidden to invent
//   prices and the estimate SMS is composed in code, not by the model.
//
// Secrets: ANTHROPIC_API_KEY, optional MODEL (default claude-sonnet-4-5),
// HQ_ALERT_SMS, KUDOSITY_FROM_NUMBER. SUPABASE_URL / SERVICE_ROLE injected.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANTHROPIC_KEY = Deno.env.get("ANTHROPIC_API_KEY");
const MODEL = Deno.env.get("MODEL") || "claude-sonnet-4-5";
const HQ_SMS = Deno.env.get("HQ_ALERT_SMS") || "";
const K_FROM = Deno.env.get("KUDOSITY_FROM_NUMBER") || "";
const META_PAGE_TOKEN = Deno.env.get("META_PAGE_TOKEN") || "";   // Messenger sends
const WA_TOKEN = Deno.env.get("WA_TOKEN") || "";                 // WhatsApp Cloud API
const WA_PHONE_NUMBER_ID = Deno.env.get("WA_PHONE_NUMBER_ID") || "";

const MAX_MSGS = 18;   // Billy outbound per thread, lifetime (estimate SMS included)
const HOURLY_CAP = 6;  // Billy outbound per number per hour

// Default gear — identical to HQ's Instant quote defaults so both quote the
// same reference system.
const PANEL_PART = "AIKO-A465-MAH54Mb";   // 465 W
const INVERTER_PART = "GW-GW15K-ETA-G20";
const BATTERY_PART = "GDWGW8.3-BAT-D-G20"; // 8.3 kWh usable per module

const normPhone = (n: string) => String(n || "").replace(/\D/g, "").slice(-9);
const OUR_NUMBERS = [HQ_SMS, K_FROM].map(normPhone).filter(Boolean);

async function sbFetch(path: string, init: RequestInit = {}) {
  return fetch(`${SB_URL}/rest/v1/${path}`, {
    ...init,
    headers: {
      apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`,
      "Content-Type": "application/json", Prefer: "return=representation",
      ...(init.headers || {}),
    },
  });
}
async function rpc(fn: string, args: Record<string, unknown>) {
  return fetch(`${SB_URL}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify(args),
  });
}
async function callFn(name: string, payload: Record<string, unknown>) {
  return fetch(`${SB_URL}/functions/v1/${name}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
}

// next 08:05 Australia/Sydney as UTC ISO — where quiet-hours-deferred sends land
function next8amSydneyISO(): string {
  const now = Date.now();
  for (let h = 1; h <= 36; h++) {
    const t = new Date(now + h * 3600e3);
    const hr = Number(new Intl.DateTimeFormat("en-AU", { hour: "2-digit", hour12: false, timeZone: "Australia/Sydney" }).format(t));
    if (hr === 8) { t.setMinutes(5, 0, 0); return t.toISOString(); }
  }
  return new Date(now + 12 * 3600e3).toISOString();
}

// Send one Billy SMS; if sms-send defers for quiet hours, reschedule for 8:05am.
async function billySend(to: string, body: string, lead_id: string | null) {
  if (OUR_NUMBERS.includes(normPhone(to))) return { ok: false, error: "own number" };
  let r = await callFn("sms-send", { to, body, lead_id, kind: "billy" });
  if (r.status === 425) {
    r = await callFn("sms-send", { to, body, lead_id, kind: "billy", send_at: next8amSydneyISO() });
  }
  const j = await r.json().catch(() => ({}));
  return { ok: r.ok, ...j };
}

// Log a non-SMS Billy message into the same audit table the transcripts read.
async function logChannelMsg(direction: string, ident: string, body: string, lead_id: string | null, kind: string) {
  await sbFetch("sms_messages", { method: "POST", body: JSON.stringify({
    direction, body, lead_id,
    from_number: direction === "in" ? ident : "billy",
    to_number: direction === "in" ? "billy" : ident,
    status: direction === "in" ? "received" : "sent", kind,
  }) }).catch(() => {});
}

// Record a channel send failure where it can be read without platform logs.
async function logSendFail(channel: string, ident: string, status: number, detail: string) {
  await sbFetch("meta_webhook_log", { method: "POST", body: JSON.stringify({
    sig_ok: false, object: `send_fail:${channel}`, note: `${ident} http=${status} ${detail}`.slice(0, 500),
  }) }).catch(() => {});
}

// The Solarsearch Facebook page id (public — appears in every webhook entry).
const FB_PAGE_ID = "1262476340286076";

// Messenger's Send API needs the PAGE's own access token (so `me` resolves to
// the page). META_PAGE_TOKEN may be a page token already, or a never-expiring
// System User token — in which case we exchange it for the page token once and
// cache it for the life of the warm instance. Either input ends up correct.
let PAGE_TOKEN_CACHE = "";
async function pageAccessToken(): Promise<string> {
  if (PAGE_TOKEN_CACHE) return PAGE_TOKEN_CACHE;
  try {
    const r = await fetch(`https://graph.facebook.com/v21.0/${FB_PAGE_ID}?fields=access_token&access_token=${encodeURIComponent(META_PAGE_TOKEN)}`);
    const j = await r.json().catch(() => null);
    if (r.ok && j?.access_token) { PAGE_TOKEN_CACHE = String(j.access_token); return PAGE_TOKEN_CACHE; }
  } catch { /* fall through */ }
  return META_PAGE_TOKEN; // already a page token, or nothing better available
}

// Messenger reply via the Graph Send API.
async function fbSend(psid: string, text: string, lead_id: string | null) {
  if (!META_PAGE_TOKEN) return { ok: false, error: "META_PAGE_TOKEN not set" };
  const tok = await pageAccessToken();
  const r = await fetch(`https://graph.facebook.com/v21.0/${FB_PAGE_ID}/messages?access_token=${encodeURIComponent(tok)}`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ recipient: { id: psid }, messaging_type: "RESPONSE", message: { text } }),
  });
  const ok = r.ok;
  if (!ok) { const d = await r.text().catch(() => ""); console.error("lead-agent: fbSend failed", r.status, d); await logSendFail("messenger", `fb:${psid}`, r.status, d); }
  await logChannelMsg("out", `fb:${psid}`, text, lead_id, "billy");
  return { ok };
}

// WhatsApp reply via the Cloud API (session message — always a response
// inside the 24h customer-service window, since Billy only ever replies).
async function waSend(waId: string, text: string, lead_id: string | null) {
  if (!WA_TOKEN || !WA_PHONE_NUMBER_ID) return { ok: false, error: "WhatsApp not configured" };
  const r = await fetch(`https://graph.facebook.com/v21.0/${WA_PHONE_NUMBER_ID}/messages`, {
    method: "POST",
    headers: { Authorization: `Bearer ${WA_TOKEN}`, "Content-Type": "application/json" },
    body: JSON.stringify({ messaging_product: "whatsapp", to: waId, type: "text", text: { body: text } }),
  });
  const ok = r.ok;
  if (!ok) { const d = await r.text().catch(() => ""); console.error("lead-agent: waSend failed", r.status, d); await logSendFail("whatsapp", `wa:${waId}`, r.status, d); }
  await logChannelMsg("out", `wa:${waId}`, text, lead_id, "billy");
  return { ok };
}

// One door for every channel Billy speaks through.
async function channelSend(thread: Record<string, any>, text: string, lead_id: string | null) {
  const ch = thread.channel || "sms";
  if (ch === "messenger") return fbSend(String(thread.phone).replace(/^fb:/, ""), text, lead_id);
  if (ch === "whatsapp") {
    const d = String(thread.phone).replace(/\D/g, "");
    return waSend(d.length === 9 ? "61" + d : d, text, lead_id);
  }
  return billySend("0" + thread.phone, text, lead_id);
}

async function hqAlert(text: string) {
  if (!HQ_SMS) return;
  await callFn("sms-send", { to: HQ_SMS, body: text.slice(0, 450), kind: "hq_alert" }).catch(() => {});
}

async function billySentLastHour(digits: string): Promise<number> {
  try {
    const since = new Date(Date.now() - 3600e3).toISOString();
    const r = await sbFetch(
      `sms_messages?select=id&direction=eq.out&kind=eq.billy&to_number=like.*${digits}` +
      `&created_at=gte.${encodeURIComponent(since)}`,
    );
    const rows = await r.json().catch(() => []);
    return Array.isArray(rows) ? rows.length : HOURLY_CAP;
  } catch { return HOURLY_CAP; }
}

// Deterministic service-area check against the same table HQ uses. null =
// unknown postcode / lookup failed (treat as unverified, not out-of-area).
async function inServiceArea(pc: string): Promise<boolean | null> {
  // "0000" is the placeholder postcode new Messenger/WhatsApp leads are created
  // with before they tell us where they are — treat it as UNKNOWN, never as a
  // real (out-of-area) postcode, or every such lead gets wrongly declined.
  if (!/^\d{4}$/.test(pc) || pc === "0000") return null;
  const r = await sbFetch(`installer_service_areas?select=postcode&postcode=eq.${pc}&paused=eq.false&limit=1`);
  const rows = await r.json().catch(() => null);
  if (!Array.isArray(rows)) return null;
  return rows.length > 0;
}

// ---------------------------------------------------------------------------
// Instant estimate — deterministic sizing + the shared quote_estimate engine.
// The model NEVER produces these numbers; it only reacts to them afterwards.
// ---------------------------------------------------------------------------
function sizeSystem(ex: Record<string, any>, lead: Record<string, any>) {
  const bill = Number(ex?.bill_quarterly) || (lead?.bill_quarterly_cents ? lead.bill_quarterly_cents / 100 : 0);
  const daily = bill > 0 ? bill / 29.2 : 20; // ~kWh/day at 32c and 91.25 days
  const pref = Number(ex?.size_kw_pref) || 0;
  const hasExisting = !!(ex?.existing_solar && /\d/.test(String(ex.existing_solar)));
  let kw = pref > 0 ? pref : Math.min(13.3, Math.max(6.6, Math.round((daily / 3.8) * 2) / 2));
  if (hasExisting && pref === 0) kw = 0; // battery retrofit on an existing array
  let panelQty = 0;
  if (kw > 0) { panelQty = Math.ceil((kw * 1000) / 465); kw = Math.round(panelQty * 0.465 * 10) / 10; }
  const wantsBattery = ex?.battery_interest !== false;
  const modules = !wantsBattery ? 0 : bill >= 900 ? 3 : bill >= 550 ? 2 : 1;
  const kwh = Math.round(modules * 8.3 * 10) / 10;
  const storey = Number(ex?.storeys) === 2 ? 2 : 1;
  return { kw, panelQty, modules, kwh, storey };
}

async function instantEstimate(ex: Record<string, any>, lead: Record<string, any>) {
  const s = sizeSystem(ex, lead);
  if (!s.panelQty && !s.modules) return null;
  const payload = {
    solar_kw: s.kw, panel_part: PANEL_PART, panel_qty: s.panelQty,
    inverter_part: INVERTER_PART, inverter_qty: 1, inverter_kw: Math.max(s.kw, 5),
    battery_part: BATTERY_PART, battery_qty: s.modules, battery_kwh_usable: s.kwh,
    battery_modules: s.modules, battery_stacks: 1,
    mounting_bos: s.panelQty * 45, storey: s.storey, phase: 1,
    dc_run_m: s.panelQty ? 25 : 0, ac_run_m: 5,
  };
  const r = await rpc("quote_estimate", { p: payload });
  const j = await r.json().catch(() => null);
  if (!r.ok || !j?.total_incl_gst) {
    console.error("lead-agent: quote_estimate failed", r.status, JSON.stringify(j).slice(0, 300));
    return null;
  }
  // Marketplace indicative: materials at cost + labour, no retail material
  // margin — predicts the competitive quotes the customer will actually get.
  // HQ's Instant quote keeps the full retail stack (total_incl_gst).
  const indicative = (Number(j.materials_cost) + Number(j.labour_total)) * 1.10 - Number(j.stc_rebate);
  const total = Math.round(indicative / 100) * 100;
  const sysText = [s.kw > 0 ? `${s.kw} kW solar` : null, s.kwh > 0 ? `${s.kwh} kWh battery` : null]
    .filter(Boolean).join(" + ");
  return {
    sysText, total, sizing: s,
    stc_rebate: j.stc_rebate, stc_solar: j.stc_solar, stc_battery: j.stc_battery,
    engine_total: j.total_incl_gst,
  };
}

const fmt$ = (n: number) => "$" + Number(n || 0).toLocaleString("en-AU", { maximumFractionDigits: 0 });

function estimateSms(first: string, est: { sysText: string; total: number; stc_rebate: number }) {
  return `${first ? first + ", h" : "H"}ere's your indicative Solarsearch estimate: ${est.sysText} — around ` +
    `${fmt$(est.total)} installed after ${fmt$(est.stc_rebate)} in rebates. It's an estimate only — a formal ` +
    `quote for acceptance follows your free on-site assessment. Is that roughly in line with what you had in mind?`;
}

// Warm, code-composed decline for a lead whose postcode is outside the areas
// Solarsearch covers. Fixed wording so it never invents a promise or a date.
function outOfAreaSms(first: string, pc: string) {
  return `${first ? first + ", t" : "T"}hanks for reaching out! I'm really sorry — postcode ${pc} is just outside the ` +
    `areas Solarsearch currently covers (Newcastle, Lake Macquarie, the Hunter & NSW Mid-Coast). We're expanding, so ` +
    `I'll keep your details on file and be in touch the moment we can help. Really appreciate your interest.`;
}

// ---------------------------------------------------------------------------
// Billy's brain. Product knowledge is drawn from what installers on the
// network (ME-SOLAR and peers) actually install, but the voice is pure
// Solarsearch — Billy never names an installer to a customer.
// ---------------------------------------------------------------------------
const BILLY_SYSTEM = `You are Billy, the SMS assistant for Solarsearch (solarsearch.com.au) — the solar & battery marketplace for Newcastle, Lake Macquarie, the Hunter and NSW Mid-Coast. You follow up people who enquired about solar, a battery, or both.

The LEAD CONTEXT names the CHANNEL (SMS, Messenger or WhatsApp). Early on, in a natural way, get the person's first name ("who am I chatting with?") and record it in extracted.name. CONTACT DETAILS ARE MANDATORY BEFORE BOOKING: the team books and confirms the assessment by phone, so you MUST have their name AND a best mobile number on file (extracted.mobile, an Australian mobile like 04xx xxx xxx) before you set status "book". On Messenger there is NO phone number on file at all — so you must ask for their mobile before booking; on SMS/WhatsApp you already have the number they're messaging from, but still confirm their name. If you're missing the name or mobile when they want to book, your reply asks for what's missing and you stay "active" — never confirm a booking without a contactable mobile. Every reply must be under 300 characters, one question at a time, plain friendly Australian English. No emoji unless the customer uses them first. If asked whether you are a bot, say you're Solarsearch's AI assistant and a human specialist follows up — never pretend to be human.

Goal: qualify the lead, get an indicative estimate in front of them, gauge budget fit, collect site photos, and land the free on-site assessment. FIRST, always confirm WHERE they are if the LEAD CONTEXT does not already show a postcode/suburb — we currently service Newcastle, Lake Macquarie, the Hunter and NSW Mid-Coast only; record extracted.postcode (4 digits) and extracted.suburb. If the LEAD CONTEXT marks the location OUTSIDE our service area: apologise warmly, say we are expanding and will keep their details for when we reach them, set status "not_interested" with "out of area" in the summary, and do NOT qualify further or promise anything. Then learn, worked in naturally over a few messages (never as a form): (1) rough quarterly electricity bill, (2) timeline — ready now / ~3 months / ~6 months / next 12 months / just researching, (3) rebate history — ask whether they've ever claimed the federal Cheaper Home Batteries rebate (NEVER ask bluntly if they own the home; the rebate question covers eligibility and ownership naturally — renters and prior claimants reveal themselves in the answer; record both owner_status and rebate_claimed from it), (4) single or double storey and roof type (tin/tile), (5) battery interest, (6) any existing solar (size, age, inverter brand), (7) what system size they have in mind, in kW, if they have one.

ADDRESS — REQUIRED BEFORE ANY ESTIMATE: before you qualify them, get the full street address of the install (street number + street + suburb, e.g. "12 Ocean St, Merewether"). The natural line: the estimate is site-specific and the free assessment happens at the property, so you need the address to put real numbers against it. Record it in extracted.address (and postcode/suburb from it). The system will NOT send an estimate until an address is on file — never promise the estimate before you have it, and never guess or complete a partial address yourself.

Site photos: once the conversation is flowing, ask them to text back three photos — their switchboard with the door open, their electricity meter, and a step-back shot showing where the switchboard sits and the space around it. Explain why in one line: it lets the installer confirm a compliant spot for the inverter before anyone visits. Photos arrive in the transcript as [photo: …] lines — thank them and track progress in extracted.photos ("requested", "some", "all"). NEVER claim to have looked at or assessed a photo; a licensed installer reviews them.

Pricing protocol — strict: you never invent or state dollar figures yourself. When you set status "qualified", the system automatically texts the customer an official indicative estimate right after your message (it will appear in the transcript). From your next turn, gauge whether that estimate fits their budget — record extracted.budget_fit as "yes", "stretch" or "no" — and reassure them a formal quote for acceptance follows the free assessment. You may refer to the estimate's figures once they appear in the transcript, but never adjust or renegotiate them; if they push on price, note it and steer to the assessment where the formal quote is prepared.

Product knowledge — equipment the accredited installers on the Solarsearch network fit (answer questions briefly and confidently; never name a specific installer):
- Batteries / hybrid systems: Sigenergy SigenStor (modular stack, ~8–48 kWh, VPP-ready), Tesla Powerwall 3, Enphase IQ Battery, GoodWe.
- Inverters: Sigenergy, GoodWe, Sungrow, SMA, Fronius, Growatt, Solis, Enphase IQ8 microinverters, Q CELLS Q.VOLT hybrid.
- Panels: AIKO, Jinko, Trina, LONGi, Q CELLS — typically 440–475 W residential panels.
- Racking: Clenergy, engineered for both tin and tile roofs.
- Typical homes land on 6.6–13.2 kW of solar; batteries usually 8–25 kWh.
Incentives you may mention as approximate, never promised: federal STC rebate on solar (built into quotes); federal Cheaper Home Batteries discount (~30% off installed battery cost); VPP programs that pay battery owners.

Never: give electrical or safety advice, promise savings figures, discuss other customers, invent discounts, or keep pushing after a clear no. Complex, sensitive or off-topic requests → hand to the team.

CONTACT DETAILS — HARD RULE: the ONLY contact details you may ever give out are these two, exactly as written: this number they're already talking to you on (0430 251 786) and the email hello@solarsearch.com.au. Never state any other phone number, email, website page, or physical address — anything else would be invented and could belong to a stranger. (Details the customer gave you themselves — their own address or mobile — are fine to confirm back to them.) The natural line: replying here always reaches us, the team will text them from this number, and hello@solarsearch.com.au works for anything written.

Output ONLY JSON, no markdown fences:
{"reply":"...","status":"active|qualified|book|human|not_interested","extracted":{"bill_quarterly":number|null,"timeline":"now|3m|6m|12m|research"|null,"owner_status":"owner|renter"|null,"rebate_claimed":true|false|null,"name":"..."|null,"address":"..."|null,"postcode":"..."|null,"suburb":"..."|null,"storeys":1|2|null,"roof":"tin|tile|other"|null,"battery_interest":true|false|null,"existing_solar":"..."|null,"size_kw_pref":number|null,"photos":"requested|some|all"|null,"budget_fit":"yes|stretch|no"|null,"mobile":"..."|null,"notes":"..."},"summary":"1–2 sentence informed briefing for the Solarsearch owner"}

Status rules: "qualified" once the location is confirmed in-area AND the full street address is recorded AND bill + timeline and the rebate/ownership picture are known (reply should thank them and lead into the estimate that's about to arrive — e.g. "give me one sec and I'll fire through an indicative estimate"). Without a street address, stay "active" and ask for it. "book" ONLY when the customer wants the assessment AND you have their name and a mobile on file — reply should confirm the team will text appointment times shortly. If they want to book but name or mobile is missing, stay "active" and ask for the missing detail first (e.g. "Great — what's the best mobile for the team to text you times on, and your name?"). "human" if they ask for a person or a call, or raise anything complex. "not_interested" on a clear no (close politely). Otherwise "active". "reply" may be "" to stay silent (e.g. abuse or spam). In "extracted" report only what you actually learned, null otherwise; bill_quarterly in whole dollars. "summary" must always reflect everything known so far, including budget fit and photo status.`;

type BillyOut = {
  reply?: string;
  status?: string;
  extracted?: Record<string, unknown>;
  summary?: string;
};

// Only these keys from the model's extracted blob survive the merge — the
// bookkeeping flags (qualified_alerted, instant_estimate, …) are code-owned.
const EXTRACT_KEYS = ["bill_quarterly", "timeline", "owner_status", "rebate_claimed", "name", "address", "postcode", "suburb", "mobile", "storeys", "roof",
  "battery_interest", "existing_solar", "size_kw_pref", "photos", "budget_fit", "notes"];

async function askBilly(context: string): Promise<BillyOut | null> {
  if (!ANTHROPIC_KEY) return null;
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": ANTHROPIC_KEY,
      "anthropic-version": "2023-06-01",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: MODEL, max_tokens: 700, system: BILLY_SYSTEM,
      messages: [{ role: "user", content: context }],
    }),
  });
  if (!res.ok) {
    console.error("lead-agent: anthropic error", res.status, await res.text().catch(() => ""));
    return null;
  }
  const data = await res.json().catch(() => null);
  const text: string = data?.content?.find((b: { type: string }) => b.type === "text")?.text || "";
  const raw = text.replace(/^```(?:json)?\s*/i, "").replace(/\s*```\s*$/, "").trim();
  try { return JSON.parse(raw) as BillyOut; }
  catch { console.error("lead-agent: unparseable model output", raw.slice(0, 200)); return null; }
}

// Conversation so far for this number, oldest first, as a plain transcript.
async function transcriptFor(digits: string): Promise<string> {
  const r = await sbFetch(
    `sms_messages?select=direction,body,kind,created_at` +
    `&or=(from_number.like.*${digits},to_number.like.*${digits})` +
    `&order=created_at.asc&limit=60`,
  );
  const rows = await r.json().catch(() => []);
  return (Array.isArray(rows) ? rows : [])
    .filter((m: { body?: string }) => (m.body || "").trim())
    .map((m: { direction: string; kind?: string; body?: string }) =>
      `${m.direction === "out" ? (m.kind === "billy" ? "BILLY" : "SOLARSEARCH (automated)") : "CUSTOMER"}: ${m.body}`)
    .join("\n");
}

async function loadThread(digits: string) {
  const r = await sbFetch(`agent_threads?phone=eq.${digits}&status=eq.active&select=*&limit=1`);
  const rows = await r.json().catch(() => []);
  return Array.isArray(rows) && rows[0] ? rows[0] : null;
}

async function patchThread(id: string, patch: Record<string, unknown>) {
  await sbFetch(`agent_threads?id=eq.${id}`, {
    method: "PATCH", body: JSON.stringify({ ...patch, updated_at: new Date().toISOString() }),
  });
}

// Push what Billy learned onto the lead row itself so HQ scoring/next-step
// logic sees real columns, not a side store.
async function updateLeadFromExtract(lead_id: string, ex: Record<string, unknown>, customer_id?: string, customer_mobile?: string, customer_name?: string, site_id?: string, site_postcode?: string, site_address?: string) {
  // Persist the location the customer gives us onto the site record. New
  // Messenger/WhatsApp leads start with a "0000" / "(not provided)" placeholder;
  // without this the real postcode lives only on the conversation and the site
  // (and the out-of-area demand view built on it) stays blank. Never overwrite a
  // real value with a blank, and never store the placeholder.
  if (site_id) {
    const sp: Record<string, unknown> = {};
    const pc = String((ex as Record<string, unknown>)?.postcode || "").trim();
    if (/^\d{4}$/.test(pc) && pc !== "0000" && pc !== String(site_postcode || "").trim()) sp.postcode = pc;
    const addr = String((ex as Record<string, unknown>)?.address || "").trim();
    if (addr && addr.length > 4 && !/not provided/i.test(addr) && addr !== String(site_address || "").trim()) sp.address = addr;
    if (Object.keys(sp).length) {
      await sbFetch(`sites?id=eq.${site_id}`, { method: "PATCH", body: JSON.stringify(sp) }).catch(() => {});
    }
  }
  // A mobile learned on Messenger unlocks SMS/WhatsApp contact later.
  const mdigits = String(ex?.mobile || "").replace(/\D/g, "");
  if (customer_id && !customer_mobile && /^0?4\d{8}$/.test(mdigits)) {
    await sbFetch(`customers?id=eq.${customer_id}`, {
      method: "PATCH", body: JSON.stringify({ mobile: (mdigits.length === 9 ? "0" : "") + mdigits }),
    }).catch(() => {});
  }
  // A name learned in-conversation (esp. on Messenger, which starts nameless).
  const learnedName = String(ex?.name || "").trim().slice(0, 80);
  if (customer_id && !customer_name && learnedName) {
    await sbFetch(`customers?id=eq.${customer_id}`, {
      method: "PATCH", body: JSON.stringify({ full_name: learnedName }),
    }).catch(() => {});
  }
  const patch: Record<string, unknown> = {};
  const bill = Number(ex?.bill_quarterly);
  if (bill > 0) patch.bill_quarterly_cents = Math.round(bill * 100);
  if (typeof ex?.timeline === "string" && ex.timeline) patch.timeline = ex.timeline;
  if (typeof ex?.owner_status === "string" && ex.owner_status) patch.owner_status = ex.owner_status;
  if (Object.keys(patch).length) {
    await sbFetch(`leads?id=eq.${lead_id}`, { method: "PATCH", body: JSON.stringify(patch) });
  }
}
async function setLeadState(lead_id: string, from: string[], to: string) {
  // best-effort: only advance from the expected states, never regress
  await sbFetch(`leads?id=eq.${lead_id}&state=in.(${from.join(",")})`, {
    method: "PATCH", body: JSON.stringify({ state: to }),
  }).catch(() => {});
}
async function noteLead(lead_id: string, note: string) {
  await sbFetch(`leads?id=eq.${lead_id}`, {
    method: "PATCH", body: JSON.stringify({ admin_notes: note.slice(0, 900) }),
  }).catch(() => {});
}

// Attach stray inbound log rows (logged before any lead was known) to the lead
// so the HQ drawer transcript is complete. Update-only — never deletes.
async function adoptInboundRows(lead_id: string, digits: string) {
  await sbFetch(`sms_messages?direction=eq.in&lead_id=is.null&from_number=like.*${digits}`, {
    method: "PATCH", body: JSON.stringify({ lead_id }),
  }).catch(() => {});
}

async function leadFor(lead_id: string) {
  const r = await sbFetch(
    `leads?id=eq.${lead_id}&select=id,site_id,state,lead_type,bill_quarterly_cents,timeline,owner_status,customers(id,full_name,mobile),sites(id,postcode,address)`,
  );
  const rows = await r.json().catch(() => []);
  return Array.isArray(rows) && rows[0] ? rows[0] : null;
}

function leadContext(lead: Record<string, any>, thread: Record<string, any> | null, locLine = "") {
  const name = lead?.customers?.full_name || "";
  return [
    `LEAD CONTEXT`,
    `Name: ${name || "(unknown)"}`,
    `Enquiry type: ${lead?.lead_type || "solar"}`,
    `Channel: ${thread?.channel === "messenger" ? "Facebook Messenger" : thread?.channel === "whatsapp" ? "WhatsApp" : "SMS"}`,
    locLine,
    lead?.bill_quarterly_cents ? `Known quarterly bill: $${Math.round(lead.bill_quarterly_cents / 100)}` : "",
    lead?.timeline ? `Known timeline: ${lead.timeline}` : "",
    lead?.owner_status ? `Known ownership: ${lead.owner_status}` : "",
    thread?.extracted && Object.keys(thread.extracted).length
      ? `Previously extracted: ${JSON.stringify(thread.extracted)}` : "",
  ].filter(Boolean).join("\n");
}

// Run one Billy turn (used for both a fresh customer message and an AI-opener
// on a lead that arrived with initial text).
async function converse(thread: Record<string, any>, lead: Record<string, any>) {
  const digits = thread.phone as string;
  const name = lead?.customers?.full_name || "lead";
  const first = String(lead?.customers?.full_name || "").split(" ")[0];
  const mob = lead?.customers?.mobile || digits;

  if ((thread.msg_count ?? 0) >= MAX_MSGS) {
    await patchThread(thread.id, { status: "expired", summary: thread.summary || "Hit message cap" });
    await hqAlert(`Billy — thread with ${name} hit the message cap. ${thread.summary || ""}`);
    return { handled: true, note: "message cap" };
  }
  if (await billySentLastHour(String(digits).replace(/\D/g, "")) >= HOURLY_CAP) {
    console.warn("lead-agent: hourly cap reached, staying silent", digits);
    return { handled: true, note: "hourly cap" };
  }

  // location: prefer what Billy has extracted, else the lead's site record
  const pcRaw = String(thread?.extracted?.postcode || lead?.sites?.postcode || "").trim();
  const pc = pcRaw === "0000" ? "" : pcRaw;   // ignore the placeholder postcode
  let locLine = "";
  if (pc) {
    const svc = await inServiceArea(pc);
    locLine = `Location: postcode ${pc}` +
      (svc === true ? " (WITHIN our service area)" : svc === false ? " — OUTSIDE our current service area" : "");
  } else {
    locLine = "Location: UNKNOWN — confirm their suburb/postcode before qualifying";
  }

  const tx = await transcriptFor(String(digits).replace(/\D/g, ""));
  const out = await askBilly(
    `${leadContext(lead, thread, locLine)}\n\nCONVERSATION SO FAR (oldest first):\n${tx}\n\nThe last CUSTOMER message is the one to answer. Reply as Billy.`,
  );
  if (!out) return { handled: true, note: "model unavailable" };

  // merge model-extracted facts under code-owned bookkeeping
  const exIn = (out.extracted || {}) as Record<string, unknown>;
  const exClean: Record<string, unknown> = {};
  for (const k of EXTRACT_KEYS) if (exIn[k] !== undefined && exIn[k] !== null) exClean[k] = exIn[k];
  const merged: Record<string, any> = { ...(thread.extracted || {}), ...exClean };
  await updateLeadFromExtract(lead.id, merged, lead?.customers?.id, lead?.customers?.mobile, lead?.customers?.full_name, lead?.site_id, lead?.sites?.postcode, lead?.sites?.address);

  let status = ["active", "qualified", "book", "human", "not_interested"].includes(out.status || "")
    ? out.status! : "active";
  let reply = (out.reply || "").trim().slice(0, 480);

  // Service-area screen for THIS turn. The postcode may only have been parsed
  // from the message we just answered, so re-check it against the merged facts
  // (the model that drafted the reply may not have known it yet). If it's
  // OUTSIDE our postcodes, Billy politely declines and the thread closes —
  // overriding the reply with a warm, code-composed decline unless the model
  // already declined on its own.
  const pcTurnRaw = String(merged.postcode || lead?.sites?.postcode || "").trim();
  const pcTurn = pcTurnRaw === "0000" ? "" : pcTurnRaw;   // ignore the placeholder postcode
  const svcTurn = pcTurn ? await inServiceArea(pcTurn) : null;
  if (svcTurn === false) {
    if (status !== "not_interested") reply = outOfAreaSms(first, pcTurn);
    status = "not_interested";
    merged.out_of_area = true;
  }

  let sends = 0;
  if (reply) {
    const r = await channelSend(thread, reply, lead.id);
    if (r.ok) sends++;
  }

  // Qualified → price it and text the indicative estimate, but ONLY once the
  // postcode is positively confirmed inside our service area. Out-of-area leads
  // are already declined and closed above, so this only ever sees an in-area or
  // an as-yet-unknown postcode — and an unknown one waits (like a missing
  // address does) and prices on a later turn once it's confirmed.
  if (status === "qualified" && String(merged.address || "").trim() && svcTurn === true && !merged.qualified_alerted) {
    merged.qualified_alerted = true;
    let estLine = "";
    const est = await instantEstimate(merged, lead);
    if (est) {
      const r = await channelSend(thread, estimateSms(first, est), lead.id);
      if (r.ok) sends++;
      merged.instant_estimate = {
        system: est.sysText, total: est.total, stc_rebate: est.stc_rebate,
        sized: est.sizing, at: new Date().toISOString(),
      };
      estLine = ` Indicative: ${est.sysText} ≈ ${fmt$(est.total)} after rebates.`;
    }
    await hqAlert(`Billy — QUALIFIED: ${name} (${mob}), ${merged.address}. ${out.summary || ""}${estLine}`);
    await noteLead(lead.id, `Billy — ${out.summary || "qualified"}${estLine}`);
    await setLeadState(lead.id, ["captured", "validated", "scored", "contacted"], "qualified");
  }

  // Wants the assessment: tell the owner — the pool/booking machinery takes
  // over from HQ (tech grabs, then times are texted). Fires once per thread —
  // but only once we have a contactable mobile, since the team books by phone.
  // A Messenger lead with no mobile isn't actionable, so hold the alert and let
  // the prompt drive Billy to ask; it fires on a later turn once the mobile lands.
  const contactMobile = normPhone(String(merged.mobile || lead?.customers?.mobile || ""));
  const haveMobile = /^4\d{8}$/.test(contactMobile);
  if (status === "book" && haveMobile && !merged.booking_alerted) {
    merged.booking_alerted = true;
    const who = String(merged.name || lead?.customers?.full_name || name);
    await hqAlert(`Billy — WANTS ASSESSMENT: ${who} (0${contactMobile}). ${out.summary || ""} Book it from HQ (tech grab → text times).`);
    await noteLead(lead.id, `Billy — wants assessment. ${out.summary || ""}`);
    await setLeadState(lead.id, ["captured", "validated", "scored", "contacted"], "qualified");
  }

  const closing = status === "human" || status === "not_interested";
  await patchThread(thread.id, {
    status: closing ? status : "active",
    extracted: merged,
    summary: out.summary || thread.summary || null,
    msg_count: (thread.msg_count ?? 0) + sends,
    last_inbound_at: new Date().toISOString(),
  });
  if (closing) {
    const tag = status === "human" ? "WANTS A HUMAN" : merged.out_of_area ? "OUT OF AREA" : "NOT INTERESTED";
    const extra = merged.out_of_area ? ` (postcode ${pcTurn}, not serviced)` : "";
    await hqAlert(`Billy — ${tag}: ${name} (${mob})${extra}. ${out.summary || ""}`);
    await noteLead(lead.id, `Billy — ${out.summary || tag}${extra}`);
  }
  return { handled: true, replied: sends > 0, status };
}

// ---------------------------------------------------------------------------
// Follow-up sweep — Billy's one proactive nudge. A scheduled poke (pg_cron)
// hits this; it finds active threads where Billy spoke last and the customer
// then went quiet, and sends a single gentle "still keen?" — once per thread,
// ever. Bounded to daytime Sydney hours and to the 4–22h-since-last-activity
// window, which keeps WhatsApp/Messenger sends inside Meta's 24h reply window.
// ---------------------------------------------------------------------------
async function followupSweep() {
  // Daytime only (08:00–20:59 Australia/Sydney) — never nudge overnight.
  const syd = Number(new Intl.DateTimeFormat("en-AU", { hour: "2-digit", hour12: false, timeZone: "Australia/Sydney" }).format(new Date()));
  if (syd < 8 || syd >= 21) return { ok: true, skipped: "outside daytime hours", nudged: 0 };

  const since4h = new Date(Date.now() - 4 * 3600e3).toISOString();
  const since22h = new Date(Date.now() - 22 * 3600e3).toISOString();
  const r = await sbFetch(
    `agent_threads?status=eq.active&select=*` +
    `&updated_at=lt.${encodeURIComponent(since4h)}&updated_at=gt.${encodeURIComponent(since22h)}` +
    `&order=updated_at.asc&limit=25`,
  );
  const threads = await r.json().catch(() => []);
  if (!Array.isArray(threads)) return { ok: true, nudged: 0, scanned: 0 };

  let nudged = 0;
  for (const t of threads) {
    const ex = (t.extracted || {}) as Record<string, any>;
    if (ex.followed_up) continue;                         // already delivered — one nudge per thread, ever
    if ((ex.followup_attempts ?? 0) >= 3) continue;       // gave up after repeated send failures
    if ((t.msg_count ?? 0) >= MAX_MSGS) continue;
    const digits = String(t.phone).replace(/^fb:/, "").replace(/\D/g, "");
    if (!digits || OUR_NUMBERS.includes(normPhone(digits))) continue;

    // Only nudge if the LAST message was Billy's — i.e. the customer went quiet.
    const lm = await sbFetch(
      `sms_messages?select=direction,created_at&or=(from_number.like.*${digits},to_number.like.*${digits})` +
      `&order=created_at.desc&limit=1`,
    );
    const lmr = await lm.json().catch(() => []);
    if (!Array.isArray(lmr) || !lmr[0] || lmr[0].direction !== "out") continue;

    const lead = await leadFor(t.lead_id);
    if (!lead) continue;
    const first = String(lead?.customers?.full_name || "").split(" ")[0];
    const nudge = `Hi${first ? " " + first : ""}, Billy from Solarsearch — just circling back. ` +
      `Still keen to get your solar & battery estimate sorted? Happy to pick up right where we left off whenever suits.`;

    const sr = await channelSend(t, nudge, lead.id);
    if (sr.ok) {
      // Delivered — flag as nudged so it never fires again.
      await patchThread(t.id, { extracted: { ...ex, followed_up: true, followed_up_at: new Date().toISOString() }, msg_count: (t.msg_count ?? 0) + 1 });
      nudged++;
    } else {
      // Send failed (e.g. a dead token) — count the attempt so a transient
      // outage doesn't permanently burn the nudge, but cap retries at 3.
      await patchThread(t.id, { extracted: { ...ex, followup_attempts: (ex.followup_attempts ?? 0) + 1, followup_last_error_at: new Date().toISOString() } });
    }
  }
  return { ok: true, scanned: threads.length, nudged };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const json = (b: unknown, s = 200) =>
    new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
  try {
    const auth = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
    const isService = auth === SERVICE_KEY;
    const body = await req.json().catch(() => ({}));

    // ---- scheduled follow-up sweep (service role, or the pg_cron token) ----
    if (body.followup_sweep) {
      let okAuth = isService;
      if (!okAuth && body.token) {
        const s = await sbFetch(`app_secrets?name=eq.followup_token&select=value&limit=1`);
        const rows = await s.json().catch(() => []);
        okAuth = Array.isArray(rows) && !!rows[0]?.value && rows[0].value === body.token;
      }
      if (!okAuth) return json({ error: "forbidden" }, 403);
      if (body.dry_run) {
        const since4h = new Date(Date.now() - 4 * 3600e3).toISOString();
        const since22h = new Date(Date.now() - 22 * 3600e3).toISOString();
        const r = await sbFetch(
          `agent_threads?status=eq.active&select=id,channel,phone,msg_count,updated_at,extracted` +
          `&updated_at=lt.${encodeURIComponent(since4h)}&updated_at=gt.${encodeURIComponent(since22h)}&order=updated_at.asc&limit=25`,
        );
        const rows = await r.json().catch(() => []);
        const cand = (Array.isArray(rows) ? rows : []).filter((t: Record<string, any>) => { const e = t.extracted || {}; return !e.followed_up && (e.followup_attempts ?? 0) < 3; });
        return json({ ok: true, dry_run: true, candidates: cand.map((t: Record<string, any>) => ({ id: t.id, channel: t.channel, updated_at: t.updated_at })) });
      }
      return json(await followupSweep());
    }

    // ---- re-engage captured out-of-area leads once their zone goes live ----
    // hq_activate_zone reopens the threads and flags extracted.reengage_pending;
    // this sends each a one-off "good news, we now cover you" on their channel.
    // Best-effort: a Messenger/WhatsApp lead last active >24h ago is outside
    // Meta's reply window and the send simply fails (flag stays for a retry).
    if (body.reengage) {
      let okAuth = isService;
      if (!okAuth) {
        const chk = await fetch(`${SB_URL}/rest/v1/rpc/is_admin`, {
          method: "POST",
          headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${auth}`, "Content-Type": "application/json" },
          body: "{}",
        });
        okAuth = chk.ok && (await chk.json().catch(() => false)) === true;
      }
      if (!okAuth) return json({ error: "forbidden" }, 403);
      const r = await sbFetch(`agent_threads?status=eq.active&extracted->>reengage_pending=eq.true&select=*&limit=50`);
      const threads = await r.json().catch(() => []);
      let reengaged = 0;
      for (const t of (Array.isArray(threads) ? threads : [])) {
        const lead = await leadFor(t.lead_id);
        if (!lead) continue;
        const first = String(lead?.customers?.full_name || "").split(" ")[0];
        const msg = `Great news${first ? " " + first : ""} — Solarsearch now covers your area! Keen to pick up where we left off and get your solar & battery estimate sorted? If it still suits, tell me your rough quarterly power bill and I'll get started.`;
        const sr = await channelSend(t, msg, lead.id);
        const ex = { ...(t.extracted || {}) };
        delete ex.reengage_pending;
        if (sr.ok) { await patchThread(t.id, { extracted: { ...ex, reengaged_at: new Date().toISOString() }, msg_count: (t.msg_count ?? 0) + 1 }); reengaged++; }
      }
      return json({ ok: true, reengaged });
    }

    // ---- customer reply, forwarded by sms-inbound (service role only) ----
    if (body.inbound) {
      if (!isService) return json({ error: "forbidden" }, 403);
      const from = String(body.inbound.from || "");
      const digits = normPhone(from);
      if (!digits || OUR_NUMBERS.includes(digits)) return json({ handled: false });
      const thread = await loadThread(digits);
      if (!thread) return json({ handled: false });
      const lead = await leadFor(thread.lead_id);
      if (!lead) return json({ handled: false });
      await adoptInboundRows(lead.id, digits);
      await setLeadState(lead.id, ["captured", "validated", "scored"], "contacted");
      const r = await converse(thread, lead);
      return json(r);
    }

    // ---- Messenger / WhatsApp inbound, forwarded by meta-inbound (service role only) ----
    if (body.channel_inbound) {
      if (!isService) return json({ error: "forbidden" }, 403);
      const ch = body.channel_inbound.channel === "whatsapp" ? "whatsapp" : "messenger";
      const sender = String(body.channel_inbound.sender || "").replace(/[^\d]/g, "");
      const text = String(body.channel_inbound.text || "").slice(0, 1500).trim();
      if (!sender || !text) return json({ handled: false });
      // Thread key: WhatsApp uses real phone digits (shared with SMS threads);
      // Messenger has no phone, so the PSID is namespaced.
      const key = ch === "whatsapp" ? normPhone(sender) : `fb:${sender}`;
      const ident = ch === "whatsapp" ? `wa:${sender}` : `fb:${sender}`;
      if (ch === "whatsapp" && OUR_NUMBERS.includes(normPhone(sender))) return json({ handled: false });

      let thread = await loadThread(key);
      let lead: Record<string, any> | null = null;
      if (thread) {
        lead = await leadFor(thread.lead_id);
        if (thread.channel !== ch) { await patchThread(thread.id, { channel: ch }); thread.channel = ch; }
      } else {
        const name = String(body.channel_inbound.name || "").slice(0, 80);
        const cap = await rpc("capture_lead", { payload: {
          name, mobile: ch === "whatsapp" ? "0" + normPhone(sender) : null,
          source_platform: ch === "whatsapp" ? "whatsapp" : "facebook_messenger",
          utm: { channel: ch, sender_id: sender },
        } });
        const cj = await cap.json().catch(() => null);
        if (!cj?.lead_id) { console.error("lead-agent: capture_lead failed for", ch); return json({ handled: false }); }
        const ins = await sbFetch("agent_threads", {
          method: "POST",
          body: JSON.stringify({ lead_id: cj.lead_id, phone: key, status: "active", channel: ch }),
        });
        thread = (await ins.json().catch(() => []))?.[0];
        if (!thread) return json({ handled: false });
        lead = await leadFor(cj.lead_id);
        await callFn("notify-new-lead", { lead_id: cj.lead_id }).catch(() => {});
      }
      if (!lead) return json({ handled: false });
      await logChannelMsg("in", ident, text, lead.id, "inbound");
      await setLeadState(lead.id, ["captured", "validated", "scored"], "contacted");
      const r = await converse(thread, lead);
      return json(r);
    }

    // ---- start a thread for a lead (HQ admin button, or sms-inbound cold text) ----
    if (body.lead_id) {
      if (!isService) {
        // verify the caller is an HQ admin using their own JWT
        const chk = await fetch(`${SB_URL}/rest/v1/rpc/is_admin`, {
          method: "POST",
          headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${auth}`, "Content-Type": "application/json" },
          body: "{}",
        });
        const isAdmin = await chk.json().catch(() => false);
        if (!chk.ok || isAdmin !== true) return json({ error: "admin only" }, 403);
      }
      const lead = await leadFor(String(body.lead_id));
      if (!lead) return json({ error: "lead not found" }, 404);
      const mobile = lead?.customers?.mobile || "";
      const digits = normPhone(mobile);
      if (!digits) return json({ error: "lead has no mobile" }, 400);
      if (OUR_NUMBERS.includes(digits)) return json({ error: "refusing to text our own number" }, 400);

      const existing = await loadThread(digits);
      if (existing) {
        // already talking — if this start came with fresh inbound text, converse
        if (body.has_inbound_text) { const r = await converse(existing, lead); return json({ thread_id: existing.id, ...r }); }
        return json({ thread_id: existing.id, already_active: true });
      }

      const ins = await sbFetch("agent_threads", {
        method: "POST",
        body: JSON.stringify({ lead_id: lead.id, phone: digits, status: "active" }),
      });
      const created = (await ins.json().catch(() => []))?.[0];
      if (!created) return json({ error: "could not create thread" }, 500);
      await adoptInboundRows(lead.id, digits);

      if (body.has_inbound_text) {
        // lead arrived via a cold text — let Billy answer what they actually said
        const r = await converse(created, lead);
        await setLeadState(lead.id, ["captured", "validated", "scored"], "contacted");
        return json({ thread_id: created.id, ...r });
      }

      const first = (lead?.customers?.full_name || "").split(" ")[0];
      const what = lead.lead_type === "battery" ? "a battery"
        : lead.lead_type === "solar_battery" ? "solar and a battery" : "solar";
      const opener =
        `Hi${first ? " " + first : ""}, Billy from Solarsearch here — thanks for your enquiry about ${what}. ` +
        `I'll line up the right local accredited installers for you. Quick one to get started: roughly what's your quarterly power bill?`;
      const r = await billySend("0" + digits, opener, lead.id);
      if (!r.ok) return json({ error: r.error || "send failed", thread_id: created.id }, 502);
      await patchThread(created.id, { msg_count: 1 });
      await setLeadState(lead.id, ["captured", "validated", "scored"], "contacted");
      return json({ thread_id: created.id, sent: true });
    }

    return json({ error: "lead_id or inbound required" }, 400);
  } catch (e) {
    console.error("lead-agent error", e);
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
