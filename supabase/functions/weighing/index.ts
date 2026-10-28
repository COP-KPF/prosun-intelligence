// ============================================================================
// Supabase edge function `weighing` — Migration 018's server side.
// ============================================================================
// Why a server function at all: the AI reading needs an API key, and nothing
// in this app may hold a secret in the browser (see web/config.js). This
// function is the only place the Anthropic key lives (a Supabase secret).
//
// Actions (POST JSON { action, ... }):
//   link_status  { token }            phone: is this QR still valid, which day
//   upload_url   { token? }           phone (QR token) or PC (signed-in user):
//                                     creates the paper row, returns a one-time
//                                     signed upload URL for its photo
//   uploaded     { paper_id, token? } photo is in storage → queue + read it
//   read         { paper_id }         PC only: read (again) a paper
//   cleanup      {}                   PC only: delete photos older than
//                                     PHOTO_KEEP_DAYS (default 28); the PC
//                                     screen calls it when it opens. Papers
//                                     and weights are kept.
//
// Who may call:
//   * a phone holding a valid capture token (weighing_capture_links) — can
//     only ADD photos for that link's day; it reads nothing back
//   * a signed-in factory_admin, production or admin user (their own
//     Supabase session token) — Production section of PROSUN PACE
//
// Deploy: Supabase dashboard > Edge Functions > Deploy a new function >
// name "weighing", paste this file, and turn OFF "Enforce JWT verification"
// (the phone has no login; this file checks every caller itself).
// Secrets (Edge Functions > Secrets): PROSUN_AI_KEY (the reading service
// key from console.anthropic.com), optionally WEIGH_MODEL (default
// claude-sonnet-5-5).
// ============================================================================

import { createClient } from "npm:@supabase/supabase-js@2";

function encodeBase64(bytes: Uint8Array): string {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(s);
}

const BUCKET = "weighing-photos";
const MAX_PHOTOS_PER_LINK = 300;           // caps cost if a QR photo ever leaks
const STALE_READING_MS = 3 * 60 * 1000;     // a "reading" older than this is retried
const BIG_GAP = 0.2;                        // >20% off the ordered kg → must be looked at
const CLEANUP_BATCH = 200;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void } | undefined;

function env(name: string): string | undefined {
  return Deno.env.get(name) ?? undefined;
}

function adminClient() {
  const url = env("SUPABASE_URL");
  const key = env("SUPABASE_SERVICE_ROLE_KEY") ?? env("SUPABASE_SECRET_KEY");
  if (!url || !key) throw new Error("server not configured (SUPABASE_URL / service key)");
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

export function bangkokToday(now = Date.now()): string {
  return new Date(now + 7 * 3600 * 1000).toISOString().slice(0, 10);
}

// ---------------------------------------------------------------- callers
type Caller =
  | { kind: "user"; id: string; role: string }
  | { kind: "link"; token: string; work_date: string }
  | { kind: "none"; reason: string };

// deno-lint-ignore no-explicit-any
async function identify(db: any, req: Request, body: any): Promise<Caller> {
  const auth = req.headers.get("Authorization") ?? "";
  const jwt = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  // A signed-in user's session token is a JWT with three parts; the
  // publishable key the phone sends is not, and is skipped.
  if (jwt && jwt.split(".").length === 3) {
    const { data, error } = await db.auth.getUser(jwt);
    if (!error && data?.user) {
      const { data: prof } = await db.from("profiles").select("role").eq("id", data.user.id).single();
      if (prof && ["factory_admin", "production", "admin"].includes(prof.role)) {
        return { kind: "user", id: data.user.id, role: prof.role };
      }
      if (!body?.token) return { kind: "none", reason: "role" };
    }
  }
  if (body?.token) {
    if (typeof body.token !== "string" || !/^[0-9a-f-]{36}$/i.test(body.token)) {
      return { kind: "none", reason: "link" };
    }
    const { data: link } = await db.from("weighing_capture_links")
      .select("token, work_date, expires_at, revoked").eq("token", body.token).maybeSingle();
    if (!link || link.revoked || new Date(link.expires_at).getTime() < Date.now()) {
      return { kind: "none", reason: "link" };
    }
    return { kind: "link", token: link.token, work_date: link.work_date };
  }
  return { kind: "none", reason: "auth" };
}

// ------------------------------------------------------------- the reading
export const READ_TOOL = {
  name: "record_working_paper",
  description: "Record what is printed and handwritten on one Prosun FM-SA-01 working paper (ใบสั่งงาน).",
  input_schema: {
    type: "object",
    properties: {
      is_working_paper: { type: "boolean", description: "false if the photo is not an FM-SA-01 working paper" },
      company: { type: "string", enum: ["Prosun Farm", "Prosun Food", "unknown"], description: "From the letterhead top left" },
      po_number: { type: ["string", "null"], description: "Exactly as printed after 'PO. NO. :', e.g. 69-091001 or UR69-091005" },
      customer: { type: ["string", "null"], description: "First line after 'ส่ง :', as printed, including any code in brackets" },
      delivery_date: { type: ["string", "null"], description: "The 'Delivery Date' as YYYY-MM-DD (Gregorian). Printed as d/m/yy with yy = Gregorian year, e.g. 9/10/26 = 2026-10-09" },
      lines: {
        type: "array",
        description: "One entry per product line of the main table, top to bottom. A table row with no quantity is a continuation of the description above it — merge it, do not make a new line.",
        items: {
          type: "object",
          properties: {
            description: { type: "string", description: "Full printed รายละเอียด text, continuation rows joined with a space" },
            ordered_text: { type: ["string", "null"], description: "จำนวน cell exactly as printed, e.g. '12 ตัว', '5 Kg'" },
            ordered_qty: { type: ["number", "null"] },
            ordered_unit: { type: ["string", "null"], enum: ["kg", "g", "pcs", "pack", "jar", "other", null], description: "ตัว/ชิ้น/pcs → pcs; แพ็ค/pack → pack; กก./kg → kg" },
            handwritten_text: { type: ["string", "null"], description: "Everything handwritten in the kg. column for this line (including its continuation rows), transcribed exactly, e.g. '4.2 + 5.9' or '12.5'. null if empty." },
            weights: { type: "array", items: { type: "number" }, description: "Each separate handwritten weight in kg, in order. Do NOT add them up. Convert Thai digits. Grams → kg. Empty array if nothing is written." },
            confidence: { type: "string", enum: ["high", "medium", "low"], description: "high only if every digit and the decimal point are unambiguous" },
            doubt: { type: ["string", "null"], description: "If not high: a short reason in Thai, e.g. 'ทศนิยมไม่ชัด: 3.8 หรือ 3.0', 'มีขีดฆ่าแก้ตัวเลข'" },
          },
          required: ["description", "ordered_text", "ordered_qty", "ordered_unit", "handwritten_text", "weights", "confidence", "doubt"],
        },
      },
      other_handwriting: { type: ["string", "null"], description: "Handwriting outside the kg. column (e.g. in หมายเหตุ or beside a line), transcribed" },
      photo_problem: { type: ["string", "null"], description: "In Thai, if the photo is blurry, cut off, too dark, or two papers overlap; else null" },
    },
    required: ["is_working_paper", "company", "po_number", "customer", "delivery_date", "lines", "other_handwriting", "photo_problem"],
  },
};

export const READ_PROMPT = `You read photos of Prosun's factory working papers (form FM-SA-01, "ใบสั่งงาน"), taken with a phone at the end of a shift.

The paper is PRINTED by sales support, then the factory WRITES BY HAND the actual weight of each line in the empty "kg." column after weighing. Your output is checked by a person against the photo before it is used for invoicing, so never guess: an honest "low" confidence is far better than a confident wrong number.

Layout (portrait A4):
- Top left: logo and company letterhead — "Prosun Farm Co., Ltd." or "Prosun Food Co., Ltd." (or the Thai name).
- Top right box: "PO. NO. :" followed by the paper number (e.g. 69-091001; Under Roof papers start with UR), then "Date :", then "Delivery Date วัน... ที่ d/m/yy".
- "ส่ง :" box: customer name (often with a code in brackets, e.g. Cagette (CR033)), then extra lines such as "Standing order" or an address.
- Main table columns: Reference | รายละเอียด (description) | จำนวน (ordered quantity + unit, printed) | kg. (handwritten actual weight).
  A row with a description but no จำนวน continues the description above (packaging or cutting instructions) — it is NOT a separate line, but a weight written on that row belongs to the line above.
- Below: หมายเหตุ (notes) box, then signature boxes. The right-hand column (meat types, packaging list) is a fixed legend: ignore it. A second page with Lot No. may appear: ignore it.

Handwriting rules:
- Weights are in kilograms. If several numbers are written for one line (per bag/tray, stacked, or joined with +), list each one separately in "weights" — do not sum.
- If a number is crossed out and rewritten, use the rewritten one, set confidence "medium" and say so in "doubt".
- Thai digits (๐๑๒๓๔๕๖๗๘๙) → Arabic. A comma used as a decimal point is a decimal point.
- If a value is written in grams (e.g. "850 g"), convert to kg and mention it in "doubt".
- If the kg. cell is empty, weights = [] and handwritten_text = null.
- Never fill in a weight that is not written. Never copy the ordered quantity into weights.

Record the paper with the record_working_paper tool.`;

export type ReadLine = {
  description: string;
  ordered_text: string | null;
  ordered_qty: number | null;
  ordered_unit: string | null;
  handwritten_text: string | null;
  weights: number[];
  confidence: "high" | "medium" | "low";
  doubt: string | null;
};

const UNITS = new Set(["kg", "g", "pcs", "pack", "jar", "other"]);

function num(v: unknown): number | null {
  if (typeof v === "number" && isFinite(v)) return v;
  if (typeof v === "string") {
    const t = v.replace(/[๐-๙]/g, (d) => String("๐๑๒๓๔๕๖๗๘๙".indexOf(d))).replace(",", ".").trim();
    const n = parseFloat(t);
    return isFinite(n) ? n : null;
  }
  return null;
}

function fmt(n: number): string {
  return String(Math.round(n * 1000) / 1000);
}

// Turns the model's answer into rows for weighing_lines, deciding which
// lines a person must look at before the paper can be confirmed.
// deno-lint-ignore no-explicit-any
export function normalizeLines(raw: any) {
  const lines: ReadLine[] = Array.isArray(raw?.lines) ? raw.lines : [];
  return lines.map((l, i) => {
    const weights = (Array.isArray(l?.weights) ? l.weights : [])
      .map(num).filter((n: number | null): n is number => n !== null && n >= 0);
    const orderedQty = num(l?.ordered_qty);
    const unit = typeof l?.ordered_unit === "string" && UNITS.has(l.ordered_unit) ? l.ordered_unit : null;
    const conf = l?.confidence === "high" || l?.confidence === "medium" || l?.confidence === "low"
      ? l.confidence : "low";
    const actual = weights.length ? Math.round(weights.reduce((a: number, b: number) => a + b, 0) * 1000) / 1000 : null;

    const reasons: string[] = [];
    if (conf !== "high") reasons.push((l?.doubt && String(l.doubt).trim()) || "อ่านไม่ชัด");
    if (weights.length > 1) reasons.push(`เขียนไว้ ${weights.length} ค่า (${weights.map(fmt).join(" + ")}) รวมให้แล้ว`);
    if (!weights.length) reasons.push("ไม่พบน้ำหนักในช่อง kg.");
    const orderedKg = unit === "kg" ? orderedQty : unit === "g" && orderedQty !== null ? orderedQty / 1000 : null;
    if (actual !== null && orderedKg && Math.abs(actual - orderedKg) / orderedKg > BIG_GAP) {
      reasons.push(`ต่างจากที่สั่ง (${fmt(orderedKg)} kg) มากกว่า ${Math.round(BIG_GAP * 100)}%`);
    }

    return {
      line_no: i + 1,
      description: String(l?.description ?? "").trim(),
      ordered_text: l?.ordered_text ?? null,
      ordered_qty: orderedQty,
      ordered_unit: unit,
      weights,
      handwritten_text: l?.handwritten_text ?? null,
      actual_kg: actual,
      confidence: conf,
      flag_reason: reasons.length ? Array.from(new Set(reasons)).join(" · ") : null,
      checked: false,
      edited: false,
    };
  });
}

// deno-lint-ignore no-explicit-any
export function normalizeHeader(raw: any) {
  const company = raw?.company === "Prosun Farm" || raw?.company === "Prosun Food" ? raw.company : null;
  const d = typeof raw?.delivery_date === "string" && /^\d{4}-\d{2}-\d{2}$/.test(raw.delivery_date)
    ? raw.delivery_date : null;
  const notes = [raw?.photo_problem, raw?.other_handwriting ? `ลายมืออื่น: ${raw.other_handwriting}` : null]
    .filter(Boolean).join(" · ");
  return {
    company,
    po_number: raw?.po_number ? String(raw.po_number).trim() : null,
    customer_name: raw?.customer ? String(raw.customer).trim() : null,
    delivery_date: d,
    note: notes || null,
  };
}

async function callModel(image: Uint8Array, mediaType: string): Promise<{ input: unknown; model: string }> {
  // PROSUN_AI_KEY is the name used in this project; the vendor's default
  // name is still accepted so either works.
  const key = env("PROSUN_AI_KEY") ?? env("ANTHROPIC_API_KEY");
  if (!key) throw new Error("PROSUN_AI_KEY is not set (Edge Functions > Secrets)");
  const model = env("WEIGH_MODEL") ?? "claude-sonnet-5-5";
  const payload = JSON.stringify({
    model,
    max_tokens: 4000,
    system: READ_PROMPT,
    tools: [READ_TOOL],
    tool_choice: { type: "tool", name: READ_TOOL.name },
    messages: [{
      role: "user",
      content: [
        { type: "image", source: { type: "base64", media_type: mediaType, data: encodeBase64(image) } },
        { type: "text", text: "Read this working paper and record it." },
      ],
    }],
  });

  let lastErr = "";
  for (let attempt = 0; attempt < 3; attempt++) {
    if (attempt) await new Promise((r) => setTimeout(r, 2000 * attempt));
    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: payload,
      signal: AbortSignal.timeout(110_000),
    });
    if (res.ok) {
      const out = await res.json();
      // deno-lint-ignore no-explicit-any
      const use = (out?.content ?? []).find((c: any) => c.type === "tool_use");
      if (!use) throw new Error("the model returned no reading");
      return { input: use.input, model: out.model ?? model };
    }
    lastErr = `${res.status} ${(await res.text()).slice(0, 300)}`;
    if (![429, 500, 502, 503, 504, 529].includes(res.status)) break;
  }
  throw new Error("reading service error: " + lastErr);
}

// deno-lint-ignore no-explicit-any
export async function readPaper(db: any, paperId: string): Promise<void> {
  // Claim the paper so two triggers never read it at once.
  const { data: paper } = await db.from("weighing_papers")
    .select("id, status, photo_path, read_started_at").eq("id", paperId).maybeSingle();
  if (!paper || paper.status === "confirmed" || paper.status === "uploading") return;
  if (paper.status === "reading" && paper.read_started_at &&
      Date.now() - new Date(paper.read_started_at).getTime() < STALE_READING_MS) return;

  const { error: claimErr } = await db.from("weighing_papers")
    .update({ status: "reading", read_started_at: new Date().toISOString(), read_error: null })
    .eq("id", paperId).neq("status", "confirmed");
  if (claimErr) throw claimErr;

  try {
    const { data: blob, error: dlErr } = await db.storage.from(BUCKET).download(paper.photo_path);
    if (dlErr || !blob) throw new Error("photo not found in storage");
    const bytes = new Uint8Array(await blob.arrayBuffer());
    const mediaType = ["image/jpeg", "image/png", "image/webp"].includes(blob.type) ? blob.type : "image/jpeg";

    const { input, model } = await callModel(bytes, mediaType);
    const header = normalizeHeader(input);
    const lines = normalizeLines(input);
    // deno-lint-ignore no-explicit-any
    if ((input as any)?.is_working_paper === false) {
      header.note = ["รูปนี้ไม่ใช่ใบงาน FM-SA-01", header.note].filter(Boolean).join(" · ");
    }

    const { error: delErr } = await db.from("weighing_lines").delete().eq("paper_id", paperId);
    if (delErr) throw delErr;
    if (lines.length) {
      const { error: insErr } = await db.from("weighing_lines")
        .insert(lines.map((l) => ({ ...l, paper_id: paperId })));
      if (insErr) throw insErr;
    }
    const { error: upErr } = await db.from("weighing_papers").update({
      ...header,
      status: "read",
      read_at: new Date().toISOString(),
      read_model: model,
      read_result: input,
      read_error: null,
    }).eq("id", paperId).neq("status", "confirmed");
    if (upErr) throw upErr;
  } catch (e) {
    await db.from("weighing_papers").update({
      status: "failed",
      read_error: String((e as Error)?.message ?? e).slice(0, 500),
    }).eq("id", paperId).neq("status", "confirmed");
  }
}

// Free-plan storage is 1 GB: photos older than PHOTO_KEEP_DAYS go. The
// paper row, its lines and every confirmed weight stay; photo_deleted_at
// records when the picture was removed.
// deno-lint-ignore no-explicit-any
export async function cleanupPhotos(db: any, now = Date.now()) {
  const days = Number(env("PHOTO_KEEP_DAYS") ?? 28);
  if (!(days >= 1)) return { deleted: 0, cutoff: null };
  const cutoff = new Date(now + 7 * 3600 * 1000 - days * 86400 * 1000).toISOString().slice(0, 10);
  let deleted = 0;
  for (let round = 0; round < 10; round++) {
    const { data: old, error } = await db.from("weighing_papers")
      .select("id, photo_path")
      .lt("work_date", cutoff)
      .is("photo_deleted_at", null)
      .limit(CLEANUP_BATCH);
    if (error) throw error;
    if (!old || !old.length) break;
    // deno-lint-ignore no-explicit-any
    const { error: rmErr } = await db.storage.from(BUCKET).remove(old.map((p: any) => p.photo_path));
    if (rmErr) throw rmErr;
    const { error: upErr } = await db.from("weighing_papers")
      .update({ photo_deleted_at: new Date(now).toISOString() })
      // deno-lint-ignore no-explicit-any
      .in("id", old.map((p: any) => p.id));
    if (upErr) throw upErr;
    deleted += old.length;
    if (old.length < CLEANUP_BATCH) break;
  }
  return { deleted, cutoff };
}

function inBackground(p: Promise<unknown>) {
  const safe = p.catch((e) => console.error("weighing read failed", e));
  if (typeof EdgeRuntime !== "undefined" && EdgeRuntime?.waitUntil) EdgeRuntime.waitUntil(safe);
  return safe;
}

// ------------------------------------------------------------------ handler
export async function handler(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  // deno-lint-ignore no-explicit-any
  let body: any;
  try { body = await req.json(); } catch { return json({ error: "bad request" }, 400); }

  try {
    const db = adminClient();
    const caller = await identify(db, req, body);

    if (body.action === "link_status") {
      if (caller.kind !== "link") return json({ valid: false });
      const { count } = await db.from("weighing_papers")
        .select("id", { count: "exact", head: true }).eq("capture_token", caller.token);
      return json({ valid: true, work_date: caller.work_date, sent: count ?? 0 });
    }

    if (caller.kind === "none") {
      const msg = caller.reason === "link" ? "QR code expired — scan the new one on the PC" : "not allowed";
      return json({ error: msg, code: caller.reason }, caller.reason === "link" ? 410 : 403);
    }

    if (body.action === "cleanup") {
      if (caller.kind !== "user") return json({ error: "not allowed" }, 403);
      return json(await cleanupPhotos(db));
    }

    if (body.action === "upload_url") {
      if (caller.kind === "link") {
        const { count } = await db.from("weighing_papers")
          .select("id", { count: "exact", head: true }).eq("capture_token", caller.token);
        if ((count ?? 0) >= MAX_PHOTOS_PER_LINK) return json({ error: "too many photos on this QR code" }, 429);
      }
      const workDate = caller.kind === "link"
        ? caller.work_date
        : (typeof body.work_date === "string" && /^\d{4}-\d{2}-\d{2}$/.test(body.work_date) ? body.work_date : bangkokToday());
      const id = crypto.randomUUID();
      const path = `${workDate}/${id}.jpg`;
      const { error: insErr } = await db.from("weighing_papers").insert({
        id,
        work_date: workDate,
        photo_path: path,
        status: "uploading",
        uploaded_by: caller.kind === "user" ? caller.id : null,
        capture_token: caller.kind === "link" ? caller.token : null,
      });
      if (insErr) throw insErr;
      const { data: signed, error: sErr } = await db.storage.from(BUCKET).createSignedUploadUrl(path);
      if (sErr || !signed) throw sErr ?? new Error("could not create upload URL");
      return json({ paper_id: id, path, upload_token: signed.token, signed_url: signed.signedUrl });
    }

    if (body.action === "uploaded" || body.action === "read") {
      const paperId = String(body.paper_id ?? "");
      const { data: paper } = await db.from("weighing_papers")
        .select("id, status, capture_token, photo_path").eq("id", paperId).maybeSingle();
      if (!paper) return json({ error: "paper not found" }, 404);
      if (caller.kind === "link" && (body.action === "read" || paper.capture_token !== caller.token)) {
        return json({ error: "not allowed" }, 403);
      }
      if (paper.status === "confirmed") return json({ error: "paper is confirmed" }, 409);

      if (body.action === "uploaded") {
        if (paper.status !== "uploading") return json({ ok: true, status: paper.status });
        const folder = paper.photo_path.split("/")[0];
        const file = paper.photo_path.split("/")[1];
        const { data: found } = await db.storage.from(BUCKET).list(folder, { search: file, limit: 1 });
        if (!found || !found.length) return json({ error: "photo not uploaded yet" }, 409);
        await db.from("weighing_papers").update({ status: "queued" }).eq("id", paperId);
      }
      const done = inBackground(readPaper(db, paperId));
      if (typeof EdgeRuntime === "undefined") await done;   // local runs / tests
      return json({ ok: true, status: "queued" });
    }

    return json({ error: "unknown action" }, 400);
  } catch (e) {
    console.error(e);
    return json({ error: String((e as Error)?.message ?? e) }, 500);
  }
}

Deno.serve(handler);
