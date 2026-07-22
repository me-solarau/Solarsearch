// AI invoice reader for the supplier price loop.
// Takes a supplier invoice (PDF / image / pasted text), asks Claude to extract
// the supplier + line items {part_no, qty, unit_price}, and returns structured
// JSON for review in HQ. HQ then calls the `invoice_apply` RPC (admin, RLS-guarded)
// to update that supplier's live prices, flag parts in_use, and record drift.
//
// This function ONLY extracts — it never writes to the catalog itself, so a bad
// read can be corrected in the HQ review step before anything is applied.
//
// Requires ANTHROPIC_API_KEY (Supabase -> Edge Functions -> Secrets). Until set,
// returns 503 and HQ falls back to manual entry.
//
// Works for the drag-and-drop upload path now, and for the email-inbox path
// later: an inbound-email provider (Mailgun/Postmark/CloudMailin/SendGrid Inbound
// Parse) POSTs the invoice PDF here with source:"email".

import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY");
const MODEL = Deno.env.get("INVOICE_MODEL") || "claude-sonnet-5";

// Known suppliers, for mapping a free-text supplier name -> our catalog code.
const SUPPLIERS: { code: string; needles: string[] }[] = [
  { code: "goelectrical", needles: ["go electrical", "goelectrical", "tuggerah"] },
  { code: "greentech", needles: ["green tech", "greentech", "green-tech"] },
  { code: "learsmith", needles: ["lear & smith", "lear and smith", "lear smith", "lambton"] },
];

function mapSupplier(name: string | null | undefined): string | null {
  const s = String(name || "").toLowerCase();
  for (const sup of SUPPLIERS) if (sup.needles.some((n) => s.includes(n))) return sup.code;
  return null;
}

const INSTRUCTION = `You are reading an Australian solar/electrical wholesaler document — a tax invoice, order confirmation, or price quote — from suppliers like Go Electrical, Green Tech, or Lear & Smith.

Extract every product line item. For each line:
- part_no: the supplier's product/part number exactly as printed (e.g. "GDWGW9.999K-EHA-G20", "SIG11040041", "CLNER-I-05"). This is the key we match on — copy it verbatim, do not invent.
- description: the product description.
- qty: quantity as a number (null if not shown).
- unit_price: the EX-GST price per single unit, in AUD, as a plain number (no "$", no commas). If only a line total is shown, divide by qty. If prices include GST, divide by 1.1 to get ex-GST. If a line has no price, use null.

Also extract: supplier_name (the vendor issuing the document), invoice_no, invoice_date (as YYYY-MM-DD), and subtotal (ex-GST total, number or null).

Ignore freight, GST lines, rounding, and non-product rows.

Return ONLY a JSON object, no prose, exactly:
{"supplier_name": string|null, "invoice_no": string|null, "invoice_date": string|null, "subtotal": number|null, "lines": [{"part_no": string, "description": string|null, "qty": number|null, "unit_price": number|null}]}`;

function extractJson(text: string): any {
  const s = text.indexOf("{");
  const e = text.lastIndexOf("}");
  if (s === -1 || e === -1) throw new Error("no JSON in model reply");
  return JSON.parse(text.slice(s, e + 1));
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const json = (b: unknown, status = 200) =>
    new Response(JSON.stringify(b), { status, headers: { ...CORS, "Content-Type": "application/json" } });

  try {
    if (!ANTHROPIC_API_KEY) return json({ error: "ai not configured", detail: "set ANTHROPIC_API_KEY" }, 503);
    const body = await req.json().catch(() => ({}));
    const { supplier_code, source, source_ref, text, file_base64, media_type } = body ?? {};

    // Build the Claude content blocks: a document/image (if provided) + the text + instruction.
    const content: any[] = [];
    if (file_base64) {
      const mt = String(media_type || "application/pdf");
      if (mt === "application/pdf") {
        content.push({ type: "document", source: { type: "base64", media_type: mt, data: file_base64 } });
      } else {
        content.push({ type: "image", source: { type: "base64", media_type: mt, data: file_base64 } });
      }
    }
    if (text && String(text).trim()) content.push({ type: "text", text: `Document text:\n${text}` });
    if (content.length === 0) return json({ error: "no invoice content (need file_base64 or text)" }, 400);
    content.push({ type: "text", text: INSTRUCTION });

    const resp = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "x-api-key": ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
      },
      body: JSON.stringify({ model: MODEL, max_tokens: 4096, messages: [{ role: "user", content }] }),
    });
    if (!resp.ok) return json({ error: "ai read failed", detail: await resp.text() }, 502);
    const data = await resp.json();
    const reply = (data.content || []).map((c: any) => c.text || "").join("");

    let parsed: any;
    try { parsed = extractJson(reply); } catch (e) {
      return json({ error: "could not parse invoice", detail: String((e as Error).message), raw: reply }, 422);
    }

    const lines = Array.isArray(parsed.lines) ? parsed.lines : [];
    const code = supplier_code || mapSupplier(parsed.supplier_name);

    return json({
      ok: true,
      supplier_code: code,             // null if we couldn't map — HQ asks the user to pick
      supplier_name: parsed.supplier_name ?? null,
      invoice_no: parsed.invoice_no ?? null,
      invoice_date: parsed.invoice_date ?? null,
      subtotal: parsed.subtotal ?? null,
      source: source || "upload",
      source_ref: source_ref ?? null,
      line_count: lines.length,
      lines,
    });
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
