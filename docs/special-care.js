// ============================================================================
// Special care clients — ลูกค้าดูแลพิเศษ (Migration 043, 24 Nov 2026)
// ============================================================================
// Clément: a "Special care" flag on a client, set by admin only. Rules:
//   No postpone (ห้ามเลื่อน), Exact quantity (ส่งครบจำนวน), Priority delivery
//   (ส่งก่อน, with an optional time window), and free special-care
//   instructions. Middle office, production, delivery and sales all see it;
//   production ticks "special care checked" before confirming the weights
//   (the database refuses the confirmation without it).
//
// This file holds
//   • the shared helpers every screen uses (scMatch, scForPaper, scForName,
//     scForCode, scTagHtml, scRulesHtml, scBoxHtml, scPostponeWarnHtml,
//     scAckOk) — loaded after weighing-common.js, before the screens;
//   • the admin page Management › Special care (scOpen / scClose / scLoad).
// Matching papers to clients is done by the database (special_care_match):
// the paper's printed name → client code, as in Sales › Clients.
// ============================================================================

const SC = {
  clients: {},        // code → { code, name, no_postpone, exact_quantity, priority_delivery, delivery_window, instructions, … }
  papers: {},         // working paper id → code
  names: {},          // client name as written → code
  checks: {},         // paper id → { by, at }
  missing: false,     // Migration 043 not run yet: every helper stays silent
  // admin page
  list: null, loading: false, message: null, q: "", results: [], searching: false,
  edit: null,         // { code, name, no_postpone, exact_quantity, priority_delivery, delivery_window, instructions, isNew }
  saving: false,
};
const scSection = document.getElementById("special-care-section");

// Text in the screen's language; bi = both languages ("ไทย · English"), as on the delivery board.
function scT(th, en, bi) { return bi ? `${th} · ${en}` : T(th, en); }

function scIsMissing(error) {
  return /special_care|schema cache|does not exist|Could not find/i.test((error && error.message) || "");
}

// Which of these papers / names belong to a special care client. Merges into
// SC; quietly does nothing before Migration 043.
async function scMatch(paperIds, names) {
  if (SC.missing || typeof sb === "undefined") return;
  const ids = [...new Set((paperIds || []).filter(Boolean))];
  const nm = [...new Set((names || []).filter((n) => n && String(n).trim()))];
  if (!ids.length && !nm.length) return;
  const { data, error } = await sb.rpc("special_care_match", { p_papers: ids, p_names: nm });
  if (error) { if (scIsMissing(error)) SC.missing = true; else console.warn("special care:", error.message); return; }
  ids.forEach((id) => { delete SC.papers[id]; delete SC.checks[id]; });
  nm.forEach((n) => { delete SC.names[n]; });
  Object.assign(SC.clients, data.clients || {});
  Object.assign(SC.papers, data.papers || {});
  Object.assign(SC.names, data.names || {});
  Object.assign(SC.checks, data.checks || {});
}

// Every flagged client the user may see (codes) — for screens keyed by client code.
async function scLoadCodes() {
  if (SC.missing || typeof sb === "undefined") return [];
  const { data, error } = await sb.rpc("special_care_list");
  if (error) { if (scIsMissing(error)) SC.missing = true; return []; }
  (data || []).forEach((c) => { SC.clients[c.code] = c; });
  SC.codesLoaded = new Set((data || []).map((c) => c.code));
  return data || [];
}

function scForCode(code) {
  if (!code) return null;
  const k = String(code).trim().toUpperCase();
  if (SC.codesLoaded && !SC.codesLoaded.has(k)) return null;      // flag removed since
  return SC.clients[k] || null;
}
function scForName(name) { return name && SC.names[name] ? SC.clients[SC.names[name]] || null : null; }
function scForPaper(p) {
  if (!p) return null;
  const code = (p.id && SC.papers[p.id]) || (p.customer_name && SC.names[p.customer_name]);
  return code ? SC.clients[code] || null : null;
}
function scCheckOf(paperId) { return SC.checks[paperId] || null; }

// ⭐ Special care — a small tag next to the client's name.
function scTagHtml(info, opts = {}) {
  if (!info) return "";
  const rules = scRuleList(info, opts.bi).map((r) => r.text).join(" · ");
  const title = [scT("ลูกค้าดูแลพิเศษ", "Special care client", opts.bi), rules, info.instructions || ""].filter(Boolean).join("\n");
  const label = opts.short ? "⭐" : `⭐ ${escapeHtml(scT("ดูแลพิเศษ", "Special care", opts.bi))}`;
  return ` <span class="sc-tag" title="${escapeAttr(title)}" aria-label="${escapeAttr(title)}">${label}</span>`;
}

function scRuleList(info, bi) {
  const out = [];
  if (!info) return out;
  if (info.no_postpone) out.push({ key: "np", icon: "🚫", text: scT("ห้ามเลื่อน", "No postpone", bi) });
  if (info.exact_quantity) out.push({ key: "eq", icon: "⚖", text: scT("ส่งครบจำนวน", "Exact quantity", bi) });
  if (info.priority_delivery) out.push({ key: "pd", icon: "⚡", text: scT("ส่งก่อน", "Priority delivery", bi) + (info.delivery_window ? ` (${info.delivery_window})` : "") });
  return out;
}

// Rule chips: 🚫 No postpone · ⚖ Exact quantity · ⚡ Priority delivery (before 10:00)
function scRulesHtml(info, opts = {}) {
  return scRuleList(info, opts.bi).map((r) =>
    `<span class="sc-rule sc-rule-${r.key}">${r.icon} ${escapeHtml(r.text)}</span>`).join(" ");
}

// The full box: rules + instructions. opts.check = { paperId, can } shows
// production's tick (weighing screen).
function scBoxHtml(info, opts = {}) {
  if (!info) return "";
  const bi = !!opts.bi;
  const chk = opts.check ? scCheckOf(opts.check.paperId) : null;
  let tick = "";
  if (opts.check) {
    if (opts.check.locked) {
      tick = chk ? `<div class="sc-checked">✓ ${escapeHtml(scT("ตรวจการดูแลพิเศษแล้ว", "Special care checked", bi))} · ${escapeHtml(chk.by || "")} ${escapeHtml(scTime(chk.at))}</div>` : "";
    } else if (opts.check.can) {
      tick = `<label class="sc-tick${chk ? " on" : ""}">
        <input type="checkbox" data-sc-act="check" data-paper="${escapeAttr(opts.check.paperId)}"${chk ? " checked" : ""}${SC.saving ? " disabled" : ""}>
        <span><strong>${escapeHtml(scT("ตรวจการดูแลพิเศษแล้ว", "Special care checked", bi))}</strong>
        <small>${escapeHtml(scT("ทำตามคำแนะนำด้านบนครบแล้ว — ต้องติ๊กก่อนยืนยันน้ำหนัก", "The instructions above were followed — required before confirming the weights", bi))}${chk ? ` · ${escapeHtml(chk.by || "")} ${escapeHtml(scTime(chk.at))}` : ""}</small></span>
      </label>`;
    } else {
      tick = `<div class="sc-unchecked">${escapeHtml(chk
        ? scT("ตรวจการดูแลพิเศษแล้ว", "Special care checked", bi) + " · " + (chk.by || "") + " " + scTime(chk.at)
        : scT("ฝ่ายผลิตยังไม่ได้ติ๊กตรวจการดูแลพิเศษ", "Production has not ticked special care yet", bi))}</div>`;
    }
  }
  return `<div class="sc-box${opts.compact ? " sc-box-compact" : ""}" role="note">
    <div class="sc-box-head"><strong>⭐ ${escapeHtml(scT("ลูกค้าดูแลพิเศษ", "Special care client", bi))}</strong>
      <span class="sc-rules">${scRulesHtml(info, { bi })}</span></div>
    ${info.instructions ? `<div class="sc-instr">${escapeHtml(info.instructions)}</div>` : ""}
    ${tick}
  </div>`;
}

// Warning inside a postpone form. kind "order" = the whole order moves
// (No postpone); "product" = one product moves (No postpone or Exact quantity).
// Returns "" when no rule applies. The tick box must be ticked to save.
function scPostponeWarnHtml(info, kind, opts = {}) {
  if (!info) return "";
  const np = !!info.no_postpone;
  const eq = kind === "product" && !!info.exact_quantity;
  if (!np && !eq) return "";
  const bi = !!opts.bi;
  const lines = [];
  if (np) lines.push(scT("ลูกค้ารายนี้ห้ามเลื่อนออเดอร์", "This client's orders must not be postponed", bi));
  if (eq) lines.push(scT("ลูกค้ารายนี้ต้องได้สินค้าครบทุกรายการ — โทรแจ้งลูกค้าก่อนเลื่อนสินค้า", "This client must receive every product in full — call the client before moving a product", bi));
  return `<div class="sc-warn" role="alert">
    <strong>⚠ ${escapeHtml(scT("ลูกค้าดูแลพิเศษ", "Special care client", bi))} — ${escapeHtml(info.name || "")}</strong>
    <span class="sc-rules">${scRulesHtml(info, { bi })}</span>
    <ul>${lines.map((l) => `<li>${escapeHtml(l)}</li>`).join("")}</ul>
    ${info.instructions ? `<div class="sc-instr">${escapeHtml(info.instructions)}</div>` : ""}
    <label class="sc-ack"><input type="checkbox" class="sc-ack-box" data-sc-ack="1"${opts.acked ? " checked" : ""}>
      ${escapeHtml(scT("เข้าใจแล้ว ยังต้องเลื่อน — ผู้บริหารจะได้รับแจ้งทันที", "Understood, it still has to move — management is notified at once", bi))}</label>
  </div>`;
}

// True when the form has no special care warning, or its box is ticked.
function scAckOk(root) {
  const box = root && root.querySelector(".sc-ack-box");
  return !box || box.checked;
}

function scTime(iso) {
  if (!iso) return "";
  try {
    return new Date(iso).toLocaleString("en-GB", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit", timeZone: "Asia/Bangkok" });
  } catch (e) { return ""; }
}

// Production's tick (weighing screen). Returns true when saved.
async function scSetCheck(paperId, on) {
  SC.saving = true;
  const { data, error } = await sb.rpc("special_care_check", { p_paper: paperId, p_on: !!on });
  SC.saving = false;
  if (error) return { ok: false, error: error.message };
  if (data && data.by) SC.checks[paperId] = data; else delete SC.checks[paperId];
  return { ok: true };
}

// The database refuses to confirm a flagged paper without the tick.
function scIsCheckRequired(error) {
  return /special_care_check_required/i.test((error && (error.message + " " + (error.details || ""))) || "");
}


// ============================================================================
// Admin page — Management › Special care
// ============================================================================
async function scOpen() {
  if (!scSection) return;
  if (typeof paceLiveStart === "function") paceLiveStart();
  scSection.classList.remove("hidden");
  SC.message = null;
  scSection.innerHTML = `<p class="mg-muted">${escapeHtml(T("กำลังโหลด…", "Loading…"))}</p>`;
  await scLoad();
}

function scClose() {
  if (!scSection || scSection.classList.contains("hidden")) return;
  scSection.classList.add("hidden");
  scSection.innerHTML = "";
  SC.edit = null;
  SC.results = [];
  SC.q = "";
}
function scPageOpen() { return scSection && !scSection.classList.contains("hidden"); }

async function scLoad() {
  if (!scPageOpen()) return;
  scReadForm();                          // a half-filled form survives the reload
  SC.loading = true;
  const { data, error } = await sb.rpc("special_care_list");
  SC.loading = false;
  if (error) {
    SC.list = null;
    SC.message = { kind: "err", text: scIsMissing(error)
      ? T("ฐานข้อมูลยังไม่อัปเดต: กรุณารัน Migration 043 ใน Supabase", "The database is not up to date: run Migration 043 in Supabase.")
      : T("โหลดไม่สำเร็จ: ", "Could not load: ") + error.message };
  } else {
    SC.list = data || [];
    SC.list.forEach((c) => { SC.clients[c.code] = c; });
  }
  scDraw();
}

function scDraw() {
  if (!scPageOpen()) return;
  const list = SC.list || [];
  const msg = SC.message ? `<div class="${SC.message.kind === "ok" ? "pp-ok" : "mg-msg"}" id="sc-msg" role="status">${escapeHtml(SC.message.text)}</div>` : "";
  const editing = SC.edit;
  scSection.innerHTML = `
    <div class="sc-bar">
      <p class="mg-small mg-muted">${escapeHtml(T(
        "ลูกค้าที่ต้องดูแลพิเศษ — ฝ่ายผลิต มิดเดิลออฟฟิศ ฝ่ายจัดส่ง และฝ่ายขาย เห็นป้าย ⭐ และคำแนะนำบนออเดอร์ของลูกค้ารายนี้ ฝ่ายผลิตต้องติ๊ก “ตรวจการดูแลพิเศษแล้ว” ก่อนยืนยันน้ำหนัก",
        "Clients who need special care — production, the middle office, delivery and sales see the ⭐ tag and the instructions on this client's orders. Production must tick “special care checked” before confirming the weights."))}</p>
      ${weighLangHtml()}
    </div>
    ${msg}
    <section class="mg-card sc-add">
      <h3>${escapeHtml(T("เพิ่มลูกค้าดูแลพิเศษ", "Add a special care client"))}</h3>
      <div class="sc-search">
        <label for="sc-q" class="pp-sr">${escapeHtml(T("ค้นหาลูกค้า (ชื่อหรือรหัส)", "Find a client (name or code)"))}</label>
        <input id="sc-q" type="search" autocomplete="off" value="${escapeAttr(SC.q)}" placeholder="${escapeAttr(T("ชื่อลูกค้าหรือรหัส เช่น CR010", "Client name or code, e.g. CR010"))}">
      </div>
      <div id="sc-results">${scResultsHtml()}</div>
    </section>
    ${editing ? scFormHtml(editing) : ""}
    <section class="mg-card">
      <h3>${escapeHtml(T("ลูกค้าดูแลพิเศษ", "Special care clients"))} <span class="mg-muted mg-small">${list.length}</span></h3>
      ${SC.list === null ? "" : list.length ? `<div class="table-scroll"><table class="sc-table">
        <thead><tr><th>${escapeHtml(T("ลูกค้า", "Client"))}</th><th>${escapeHtml(T("กฎ", "Rules"))}</th>
          <th>${escapeHtml(T("คำแนะนำการดูแลพิเศษ", "Special care instructions"))}</th>
          <th>${escapeHtml(T("ชื่อบนใบงาน", "Names on working papers"))}</th>
          <th>${escapeHtml(T("แก้ไขล่าสุด", "Last change"))}</th><th></th></tr></thead>
        <tbody>${list.map((c) => `<tr data-code="${escapeAttr(c.code)}">
          <td><strong>${escapeHtml(c.name)}</strong><br><span class="mg-muted mg-small">${escapeHtml(c.code)}</span></td>
          <td class="sc-rules-cell">${scRulesHtml(c) || `<span class="mg-muted">—</span>`}</td>
          <td class="sc-instr-cell">${c.instructions ? escapeHtml(c.instructions) : `<span class="mg-muted">—</span>`}</td>
          <td class="sc-names-cell">${(c.paper_names || []).length
            ? (c.paper_names || []).map((n) => `<span class="sc-name">${escapeHtml(n)}</span>`).join(" ")
            : `<span class="sc-nolink">${escapeHtml(T("ยังไม่มีชื่อบนใบงานที่เชื่อมกับรหัสนี้ — ใบงานจะยังไม่ขึ้นป้าย เชื่อมได้ที่ ฝ่ายขาย › ลูกค้า", "No working-paper name linked to this code yet — papers will not be flagged. Link one in Sales › Clients."))}</span>`}</td>
          <td class="mg-small">${escapeHtml(c.updated_by_name || "")}<br><span class="mg-muted">${escapeHtml(scTime(c.updated_at))}</span></td>
          <td class="sc-acts"><button type="button" class="ws-chip" data-sc-act="edit" data-code="${escapeAttr(c.code)}">${escapeHtml(T("แก้ไข", "Edit"))}</button>
            <button type="button" class="ws-chip sc-remove" data-sc-act="remove" data-code="${escapeAttr(c.code)}">${escapeHtml(T("เอาออก", "Remove"))}</button></td>
        </tr>`).join("")}</tbody></table></div>`
      : `<p class="mg-muted">${escapeHtml(T("ยังไม่มีลูกค้าดูแลพิเศษ — ค้นหาลูกค้าด้านบนเพื่อเพิ่ม", "No special care client yet — find a client above to add one."))}</p>`}
    </section>`;
}

function scResultsHtml() {
  if (SC.searching) return `<p class="mg-muted mg-small">${escapeHtml(T("กำลังค้นหา…", "Searching…"))}</p>`;
  if (SC.q.trim().length < 2) return "";
  if (!SC.results.length) return `<p class="mg-muted mg-small">${escapeHtml(T("ไม่พบลูกค้า", "No client found"))}</p>`;
  return `<ul class="sc-results">${SC.results.map((r) => `<li>
    <button type="button" class="sc-result" data-sc-act="pick" data-code="${escapeAttr(r.code)}" data-name="${escapeAttr(r.name)}">
      <strong>${escapeHtml(r.name)}</strong> <span class="mg-muted">${escapeHtml(r.code)}${r.zone ? " · " + escapeHtml(r.zone) : ""}${r.salesperson ? " · " + escapeHtml(r.salesperson) : ""}</span>
      ${r.flagged ? `<span class="sc-tag">⭐ ${escapeHtml(T("ดูแลพิเศษแล้ว", "Already special care"))}</span>` : ""}
    </button></li>`).join("")}</ul>`;
}

function scFormHtml(e) {
  return `<form class="mg-card sc-form" id="sc-form" novalidate>
    <h3>⭐ ${escapeHtml(e.name)} <span class="mg-muted mg-small">${escapeHtml(e.code)}</span></h3>
    ${e.error ? `<div class="mg-msg" role="alert">${escapeHtml(e.error)}</div>` : ""}
    <fieldset class="sc-rules-pick">
      <legend>${escapeHtml(T("กฎ", "Rules"))}</legend>
      <label><input type="checkbox" id="sc-np"${e.no_postpone ? " checked" : ""}> 🚫 <strong>${escapeHtml(T("ห้ามเลื่อน", "No postpone"))}</strong>
        <small>${escapeHtml(T("เลื่อนได้ แต่ทุกหน้าจะเตือนก่อน และผู้บริหารได้รับแจ้งทันที", "Postponing stays possible, but every screen warns first and management is notified at once"))}</small></label>
      <label><input type="checkbox" id="sc-eq"${e.exact_quantity ? " checked" : ""}> ⚖ <strong>${escapeHtml(T("ส่งครบจำนวน", "Exact quantity"))}</strong>
        <small>${escapeHtml(T("ห้ามส่งขาด: การเลื่อนสินค้าบางรายการจะเตือนก่อน และแจ้งผู้บริหาร", "No short delivery: moving one product to another day warns first and notifies management"))}</small></label>
      <label><input type="checkbox" id="sc-pd"${e.priority_delivery ? " checked" : ""}> ⚡ <strong>${escapeHtml(T("ส่งก่อน", "Priority delivery"))}</strong>
        <small>${escapeHtml(T("ขึ้นเป็นลำดับแรกในกระดานจัดส่ง", "First on the delivery board"))}</small></label>
      <label class="sc-window">${escapeHtml(T("ช่วงเวลาส่ง (ไม่บังคับ)", "Delivery time window (optional)"))}
        <input type="text" id="sc-window" maxlength="60" value="${escapeAttr(e.delivery_window || "")}" placeholder="${escapeAttr(T("เช่น ก่อน 10:00", "e.g. before 10:00"))}"></label>
    </fieldset>
    <label class="sc-instr-field">${escapeHtml(T("คำแนะนำการดูแลพิเศษ (ทุกฝ่ายเห็น)", "Special care instructions (every team sees them)"))}
      <textarea id="sc-instr" rows="4" maxlength="1000" placeholder="${escapeAttr(T("เช่น ตรวจเส้นเลือดในอกไก่ทุกชิ้น · แพ็คสุญญากาศเท่านั้น · โทรหาเชฟก่อนส่ง", "e.g. Check every breast for blood vessels · vacuum pack only · call the chef before delivery"))}">${escapeHtml(e.instructions || "")}</textarea></label>
    <div class="sc-form-acts">
      <button type="submit" class="w-btn" id="sc-save"${SC.saving ? " disabled" : ""}>${escapeHtml(e.isNew ? T("เพิ่มเป็นลูกค้าดูแลพิเศษ", "Add as special care client") : T("บันทึก", "Save"))}</button>
      <button type="button" class="w-btn w-btn-outline" data-sc-act="cancel">${escapeHtml(T("ยกเลิก", "Cancel"))}</button>
    </div>
  </form>`;
}

let scSearchTimer = null;
async function scSearch() {
  const q = SC.q.trim();
  if (q.length < 2) { SC.results = []; scRedrawResults(); return; }
  SC.searching = true; scRedrawResults();
  const { data, error } = await sb.rpc("special_care_search", { p_q: q });
  SC.searching = false;
  if (q !== SC.q.trim()) return;            // typed on meanwhile
  SC.results = error ? [] : (data || []);
  if (error) SC.message = { kind: "err", text: T("ค้นหาไม่สำเร็จ: ", "Search failed: ") + error.message };
  scRedrawResults();
}
function scRedrawResults() {
  const el = document.getElementById("sc-results");
  if (el) el.innerHTML = scResultsHtml();
}

function scReadForm() {
  const v = (id) => document.getElementById(id);
  if (!SC.edit || !v("sc-form")) return;
  Object.assign(SC.edit, {
    no_postpone: v("sc-np").checked, exact_quantity: v("sc-eq").checked, priority_delivery: v("sc-pd").checked,
    delivery_window: v("sc-window").value.trim(), instructions: v("sc-instr").value.trim(),
  });
}

async function scSave() {
  scReadForm();
  const e = SC.edit;
  if (!e || SC.saving) return;
  if (!e.no_postpone && !e.exact_quantity && !e.priority_delivery && !e.instructions) {
    e.error = T("เลือกอย่างน้อยหนึ่งกฎ หรือเขียนคำแนะนำ", "Choose at least one rule or write the instructions.");
    scDraw(); return;
  }
  SC.saving = true; scDraw();
  const { error } = await sb.rpc("special_care_set", {
    p_code: e.code, p_no_postpone: e.no_postpone, p_exact_quantity: e.exact_quantity, p_priority_delivery: e.priority_delivery,
    p_delivery_window: e.delivery_window || null, p_instructions: e.instructions || null });
  SC.saving = false;
  if (error) { e.error = T("บันทึกไม่สำเร็จ: ", "Could not save: ") + error.message; scDraw(); return; }
  SC.message = { kind: "ok", text: T(`บันทึกแล้ว — ${e.name} เป็นลูกค้าดูแลพิเศษ`, `Saved — ${e.name} is a special care client`) };
  SC.edit = null; SC.q = ""; SC.results = [];
  await scLoad();
}

async function scRemove(code) {
  const c = (SC.list || []).find((x) => x.code === code);
  if (!c) return;
  if (!confirm(T(`เอา ${c.name} ออกจากลูกค้าดูแลพิเศษ? ป้ายและคำแนะนำจะหายจากทุกหน้าจอ`,
                 `Remove ${c.name} from special care? The tag and the instructions disappear from every screen.`))) return;
  const { error } = await sb.rpc("special_care_remove", { p_code: code });
  SC.message = error ? { kind: "err", text: T("เอาออกไม่สำเร็จ: ", "Could not remove: ") + error.message }
                     : { kind: "ok", text: T(`เอา ${c.name} ออกแล้ว`, `${c.name} removed from special care`) };
  if (SC.edit && SC.edit.code === code) SC.edit = null;
  delete SC.clients[code];
  await scLoad();
}

if (scSection) {
  scSection.addEventListener("input", (e) => {
    if (e.target.id === "sc-q") {
      SC.q = e.target.value;
      clearTimeout(scSearchTimer);
      scSearchTimer = setTimeout(scSearch, 250);
    }
  });
  scSection.addEventListener("submit", (e) => {
    if (e.target.id === "sc-form") { e.preventDefault(); scSave(); }
  });
  scSection.addEventListener("click", (e) => {
    const lang = e.target.closest('[data-act="lang"]');
    if (lang) { scReadForm(); weighSetLang(lang.dataset.lang); scDraw(); return; }
    const b = e.target.closest("[data-sc-act]");
    if (!b) return;
    const act = b.dataset.scAct;
    if (act === "pick") {
      const code = b.dataset.code;
      const cur = (SC.list || []).find((x) => x.code === code);
      SC.edit = cur ? Object.assign({ isNew: false }, cur)
                    : { code, name: b.dataset.name, no_postpone: true, exact_quantity: false, priority_delivery: false, delivery_window: "", instructions: "", isNew: true };
      SC.message = null;
      scDraw();
      const f = document.getElementById("sc-form");
      if (f && f.scrollIntoView) f.scrollIntoView({ block: "nearest" });
    } else if (act === "edit") {
      const cur = (SC.list || []).find((x) => x.code === b.dataset.code);
      if (cur) { SC.edit = Object.assign({ isNew: false }, cur); SC.message = null; scDraw(); }
    } else if (act === "cancel") {
      SC.edit = null; scDraw();
    } else if (act === "remove") {
      scRemove(b.dataset.code);
    }
  });
  document.getElementById("switch-system-btn").addEventListener("click", scClose);
  document.getElementById("sign-out-btn").addEventListener("click", () => {
    scClose();
    Object.assign(SC, { clients: {}, papers: {}, names: {}, checks: {}, list: null, missing: false, codesLoaded: null });
  });
}

// The warning's box in a whole-order postpone form turns its button on (ppSyncForm, weighing.js).
document.addEventListener("change", (e) => {
  const box = e.target.closest && e.target.closest(".sc-ack-box");
  if (!box || !box.form || !box.form.querySelector("[data-pp=save]")) return;
  if (typeof ppSyncForm === "function") ppSyncForm(box.form);
});
