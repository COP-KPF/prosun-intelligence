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
  last: {}, lastMissing: false,  // code → last order (Migration 044)
  ov: null, ovMissing: false,    // cards' figures (Migration 049)
  view: "cards", fileCode: null, files: {}, filter: "all", cq: "", adding: false,
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
// Admin page — Management › Special care (cards + client file, Migration 049)
// ============================================================================
// Clément, 25 Nov 2026: design options A (one card per client) and C (client
// file) chosen. Cards: stats, filters, one card per client with the rules,
// instructions, last order and the order days of the last 30 days. A click
// opens the client file: figures for 30 days, the last orders with ordered and
// weighed quantities, the usual basket and the postponements.
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
  SC.adding = false;
  SC.view = "cards";
  SC.fileCode = null;
}
function scPageOpen() { return scSection && !scSection.classList.contains("hidden"); }

async function scLoad() {
  if (!scPageOpen()) return;
  scReadForm();                          // a half-filled form survives the reload
  SC.loading = true;
  const [{ data, error }, lo, ov] = await Promise.all([
    sb.rpc("special_care_list"), sb.rpc("special_care_last_orders"), sb.rpc("special_care_overview")]);
  SC.loading = false;
  SC.lastMissing = !!lo.error && scIsMissing(lo.error);
  SC.last = lo.error ? {} : (lo.data || {});
  // Cards' figures (Migration 049). Before 049 the cards show without them.
  SC.ovMissing = !!ov.error && scIsMissing(ov.error);
  SC.ov = ov.error ? null : ov.data;
  if (error) {
    SC.list = null;
    SC.message = { kind: "err", text: scIsMissing(error)
      ? T("ฐานข้อมูลยังไม่อัปเดต: กรุณารัน Migration 043 ใน Supabase", "The database is not up to date: run Migration 043 in Supabase.")
      : T("โหลดไม่สำเร็จ: ", "Could not load: ") + error.message };
  } else {
    SC.list = data || [];
    SC.list.forEach((c) => { SC.clients[c.code] = c; });
  }
  if (SC.view === "file" && SC.fileCode) {
    if (!(SC.list || []).some((c) => c.code === SC.fileCode)) { SC.view = "cards"; SC.fileCode = null; }
    else await scLoadFile(SC.fileCode, true);
  }
  scDraw();
}

async function scLoadFile(code, quiet) {
  if (!quiet) { SC.files[code] = SC.files[code] || null; scDraw(); }
  const { data, error } = await sb.rpc("special_care_client_file", { p_code: code });
  SC.files[code] = error ? { error: scIsMissing(error)
    ? T("รัน Migration 049 ใน Supabase เพื่อดูแฟ้มลูกค้า", "Run Migration 049 in Supabase to see the client file.")
    : T("โหลดไม่สำเร็จ: ", "Could not load: ") + error.message } : data;
  if (!quiet) scDraw();
}

function scOv(code) { return (SC.ov && SC.ov.clients && SC.ov.clients[code]) || null; }

// Card filters: all, ordered today / yesterday, quiet, never ordered, one per salesperson.
function scFilters(list) {
  const reps = [...new Set(list.map((c) => (scOv(c.code) || {}).rep).filter(Boolean))].sort((a, b) =>
    (a === "House") - (b === "House") || a.localeCompare(b));
  const f = [
    { k: "all", label: T(`ทั้งหมด ${list.length}`, `All ${list.length}`) },
    { k: "recent", label: T("สั่งวันนี้ / เมื่อวาน", "Ordered today / yesterday") },
    { k: "quiet", label: T("เงียบเกิน 14 วัน", "Quiet > 14 days") },
    { k: "none", label: T("ยังไม่มีออเดอร์", "No order yet") },
  ];
  if (SC.ov) reps.forEach((r) => f.push({ k: "rep:" + r, label: r }));
  return f;
}
function scMatchFilter(c) {
  const o = scOv(c.code) || {};
  const ds = o.days_since;
  const f = SC.filter || "all";
  if (f === "recent") return (ds !== null && ds !== undefined && ds <= 1) || !!o.next_order;
  if (f === "quiet") return ds !== null && ds !== undefined && ds > 14 && !o.next_order;
  if (f === "none") return ds === null || ds === undefined;
  if (f.startsWith("rep:")) return o.rep === f.slice(4);
  return true;
}
function scMatchSearch(c) {
  const q = (SC.cq || "").trim().toLowerCase();
  if (!q) return true;
  const l = (SC.last[c.code] || {}).last;
  const hay = [c.name, c.code, c.instructions, (scOv(c.code) || {}).rep, ...(c.paper_names || []),
               ...((l && l.lines) || []).map((x) => x.description)].join(" ").toLowerCase();
  return hay.includes(q);
}

function scDraw() {
  if (!scPageOpen()) return;
  const msg = SC.message ? `<div class="${SC.message.kind === "ok" ? "pp-ok" : "mg-msg"}" id="sc-msg" role="status">${escapeHtml(SC.message.text)}</div>` : "";
  scSection.innerHTML = SC.view === "file" && SC.fileCode ? scFileHtml(msg) : scCardsHtml(msg);
}

function scCardsHtml(msg) {
  const list = SC.list || [];
  const st = (SC.ov && SC.ov.stats) || null;
  const shown = list.filter((c) => scMatchFilter(c) && scMatchSearch(c))
    .sort((a, b) => scSortKey(a) - scSortKey(b) || a.name.localeCompare(b.name));
  const tile = (label, value, sub, cls) => `<div class="sc-stat${cls ? " " + cls : ""}"><span class="sc-stat-l">${escapeHtml(label)}</span>
    <span class="sc-stat-v">${escapeHtml(String(value))}</span><span class="sc-stat-s">${escapeHtml(sub)}</span></div>`;
  return `
    <div class="sc-bar">
      <p class="mg-small mg-muted">${escapeHtml(T(
        "ลูกค้าที่ต้องดูแลพิเศษ — ฝ่ายผลิต มิดเดิลออฟฟิศ ฝ่ายจัดส่ง และฝ่ายขาย เห็นป้าย ⭐ และคำแนะนำบนออเดอร์ของลูกค้ารายนี้ ฝ่ายผลิตต้องติ๊ก “ตรวจการดูแลพิเศษแล้ว” ก่อนยืนยันน้ำหนัก กดที่การ์ดเพื่อเปิดแฟ้มลูกค้า",
        "Clients who need special care — production, the middle office, delivery and sales see the ⭐ tag and the instructions on this client's orders; production ticks “special care checked” before confirming the weights. Click a card to open the client file."))}</p>
      ${weighLangHtml()}
    </div>
    ${msg}
    <div class="sc-tools">
      <label class="sc-cq"><span class="pp-sr">${escapeHtml(T("ค้นหาในลูกค้าดูแลพิเศษ", "Search the special care clients"))}</span>
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><circle cx="11" cy="11" r="7"></circle><path d="M20 20l-4-4"></path></svg>
        <input id="sc-cq" type="search" autocomplete="off" value="${escapeAttr(SC.cq || "")}" placeholder="${escapeAttr(T("ลูกค้า รหัส หรือสินค้า", "Client, code or product"))}"></label>
      <button type="button" class="w-btn" data-sc-act="add-toggle" aria-expanded="${SC.adding ? "true" : "false"}">${escapeHtml(SC.adding ? T("ปิด", "Close") : T("+ เพิ่มลูกค้า", "+ Add client"))}</button>
    </div>
    ${SC.adding ? `<section class="mg-card sc-add">
      <h3>${escapeHtml(T("เพิ่มลูกค้าดูแลพิเศษ", "Add a special care client"))}</h3>
      <div class="sc-search">
        <label for="sc-q" class="pp-sr">${escapeHtml(T("ค้นหาลูกค้า (ชื่อหรือรหัส)", "Find a client (name or code)"))}</label>
        <input id="sc-q" type="search" autocomplete="off" value="${escapeAttr(SC.q)}" placeholder="${escapeAttr(T("ชื่อลูกค้าหรือรหัส เช่น CR010", "Client name or code, e.g. CR010"))}">
      </div>
      <div id="sc-results">${scResultsHtml()}</div>
    </section>` : ""}
    ${SC.edit && SC.edit.isNew ? scFormHtml(SC.edit) : ""}
    ${SC.ovMissing ? `<div class="mg-msg" role="status">${escapeHtml(T("รัน Migration 049 ใน Supabase เพื่อดูตัวเลขบนการ์ด", "Run Migration 049 in Supabase to see the figures on the cards."))}</div>` : ""}
    ${st ? `<div class="sc-stats">
      ${tile(T("ลูกค้าดูแลพิเศษ", "Special care clients"), st.clients, T(`${list.filter((c) => c.no_postpone).length} ห้ามเลื่อน · ${list.filter((c) => c.priority_delivery).length} ส่งก่อน`, `${list.filter((c) => c.no_postpone).length} No postpone · ${list.filter((c) => c.priority_delivery).length} Priority`))}
      ${tile(T("มีออเดอร์วันนี้", "Ordering today"), st.ordering_today, T("ใบงานส่งวันนี้", "papers due today"))}
      ${tile(T("ถูกเลื่อน 7 วัน", "Postponed, last 7 days"), st.postponed_7d, T("ผู้บริหารได้รับแจ้งทุกครั้ง", "management was notified each time"), st.postponed_7d ? "sc-stat-bad" : "")}
      ${tile(T("เงียบเกิน 14 วัน", "Quiet > 14 days"), st.quiet_14, T(`${st.no_order} รายยังไม่มีออเดอร์ใน PACE`, `${st.no_order} with no order in PACE yet`), st.quiet_14 ? "sc-stat-warn" : "")}
    </div>` : ""}
    <div class="sc-filters" role="group" aria-label="${escapeAttr(T("ตัวกรอง", "Filters"))}">
      ${scFilters(list).map((f) => `<button type="button" class="sc-filter${(SC.filter || "all") === f.k ? " on" : ""}" data-sc-act="filter" data-k="${escapeAttr(f.k)}" aria-pressed="${(SC.filter || "all") === f.k}">${escapeHtml(f.label)}</button>`).join("")}
    </div>
    ${SC.list === null ? "" : !list.length
      ? `<p class="mg-muted">${escapeHtml(T("ยังไม่มีลูกค้าดูแลพิเศษ — กด “+ เพิ่มลูกค้า”", "No special care client yet — use “+ Add client”."))}</p>`
      : !shown.length ? `<p class="mg-muted">${escapeHtml(T("ไม่มีลูกค้าตรงกับตัวกรองนี้", "No client matches this filter."))}</p>`
      : `<div class="sc-cards">${shown.map(scCardHtml).join("")}</div>`}`;
}

// Cards: newest order first, quiet ones after, never ordered last.
function scSortKey(c) {
  const o = scOv(c.code);
  if (o) return o.next_order ? -1 : o.days_since === null || o.days_since === undefined ? 9999 : o.days_since;
  const l = (SC.last[c.code] || {}).last;
  return l ? -new Date(l.order_date).getTime() / 864e5 : 9999;
}

function scAgePill(c) {
  const o = scOv(c.code);
  const l = (SC.last[c.code] || {}).last;
  let d = o ? o.days_since : l ? weighDaysBetween(l.order_date, weighBangkokToday()) : null;
  if (o && o.next_order) return `<span class="sc-age sc-age-ok">${escapeHtml(T("ถัดไป ", "Next ") + weighDayShort(o.next_order))}</span>`;
  if (d === null || d === undefined) return `<span class="sc-age sc-age-none">${escapeHtml(T("ยังไม่มีออเดอร์", "No order yet"))}</span>`;
  if (d < 0) return `<span class="sc-age sc-age-ok">${escapeHtml(scAgo(l.order_date))}</span>`;
  const cls = d <= 7 ? "sc-age-ok" : d <= 14 ? "sc-age-mid" : "sc-age-bad";
  const txt = d === 0 ? T("วันนี้", "Today") : d === 1 ? T("เมื่อวาน", "Yesterday") : T(`${d} วันก่อน`, `${d} days ago`);
  return `<span class="sc-age ${cls}">${escapeHtml(txt)}</span>`;
}

function scStatusText(status, delivery) {
  if (delivery) return { delivered: T("ส่งแล้ว", "Delivered"), out: T("ระหว่างส่ง", "On the road"), dispatch: T("ที่ศูนย์กระจาย", "At dispatch"), problem: T("ปัญหาการส่ง", "Delivery problem") }[delivery] || delivery;
  return status === "confirmed" ? T("ยืนยันน้ำหนักแล้ว", "Weights confirmed")
    : status === "postponed" ? T("ถูกเลื่อน", "Postponed") : T("รอชั่ง / ตรวจ", "Being weighed");
}
function scQty(w) {
  return w.ordered_text || (w.ordered_qty != null ? `${Number(w.ordered_qty)} ${weighUnit(w.ordered_unit)}` : "");
}

function scCardHtml(c) {
  const o = scOv(c.code);
  const x = SC.last[c.code] || {};
  const l = x.last;
  const lines = (l && l.lines) || [];
  const strip = o ? `<div class="sc-strip-head"><span>${escapeHtml(T("30 วันล่าสุด", "Last 30 days"))}</span>
      <span><strong>${o.n30}</strong> ${escapeHtml(T("ออเดอร์", o.n30 === 1 ? "order" : "orders"))} · ${escapeHtml(weighFmt(o.kg30, 0))} kg${o.postponed30 ? ` · <span class="sc-bad">${escapeHtml(T(`เลื่อน ${o.postponed30}`, `${o.postponed30} postponed`))}</span>` : ""}</span></div>
    <div class="sc-strip" role="img" aria-label="${escapeAttr(T(`มีออเดอร์ ${(o.days30 || []).length} วันใน 30 วัน`, `Orders on ${(o.days30 || []).length} of the last 30 days`))}">${
      Array.from({ length: 30 }, (_, i) => `<span${(o.days30 || []).includes(29 - i) ? ' class="on"' : ""}></span>`).join("")}</div>` : "";
  let last;
  if (SC.lastMissing) last = "";
  else if (l) last = `<div class="sc-card-last-head"><span><strong>${escapeHtml(T("ออเดอร์ล่าสุด", "Last order"))}</strong> · ${escapeHtml(weighDayShort(l.order_date))}${l.po_number ? " · " + escapeHtml(l.po_number) : ""}</span>
        <span class="sc-last-status sc-last-${escapeAttr(l.status)}">${escapeHtml(scStatusText(l.status))}</span></div>
      <ul class="sc-lines">${lines.slice(0, 3).map((w) => `<li><span class="sc-prod">${escapeHtml(w.description || "—")}</span>
        <span class="sc-qty">${escapeHtml(scQty(w))}${w.actual_kg != null && l.status === "confirmed" ? ` · <strong>${escapeHtml(weighFmt(w.actual_kg))} kg</strong>` : ""}</span></li>`).join("")}</ul>
      ${lines.length > 3 ? `<span class="sc-more-n">${escapeHtml(T(`+ อีก ${lines.length - 3} รายการ`, `+ ${lines.length - 3} more`))}</span>` : ""}`;
  else if (x.invoice) last = `<div class="sc-card-last-head"><span><strong>${escapeHtml(T("ใบแจ้งหนี้ Odoo ล่าสุด", "Last Odoo invoice"))}</strong> · ${escapeHtml(weighDayShort(x.invoice.invoice_date))}</span></div>
      <span class="mg-muted mg-small">${escapeHtml(T("ยังไม่มีใบงานใน PACE", "No working paper in PACE yet"))}</span>`;
  else last = `<span class="mg-muted mg-small">${escapeHtml(T("ยังไม่มีออเดอร์ใน PACE", "No order in PACE yet"))}</span>`;
  const unlinked = !(c.paper_names || []).length;
  return `<article class="sc-card" data-sc-open="${escapeAttr(c.code)}">
    <div class="sc-card-head">
      <div class="sc-card-id"><h3><button type="button" class="sc-card-name" data-sc-act="open" data-code="${escapeAttr(c.code)}">${escapeHtml(c.name)}</button></h3>
        <span class="mg-muted mg-small">${escapeHtml(c.code)}${o ? " · " + escapeHtml(o.rep) : ""}</span></div>
      ${scAgePill(c)}
    </div>
    <div class="sc-rules">${scRulesHtml(c)}</div>
    ${c.instructions ? `<p class="sc-card-instr">${escapeHtml(c.instructions)}</p>` : ""}
    ${unlinked ? `<p class="sc-nolink">${escapeHtml(T("ยังไม่มีชื่อบนใบงานที่เชื่อมกับรหัสนี้ — ใบงานจะยังไม่ขึ้นป้าย", "No working-paper name linked to this code — papers are not flagged yet."))}</p>` : ""}
    <div class="sc-card-last">${last}</div>
    ${strip}
  </article>`;
}

// ---------------------------------------------------------------- client file
function scFileHtml(msg) {
  const c = (SC.list || []).find((x) => x.code === SC.fileCode);
  if (!c) return msg;
  const o = scOv(c.code);
  const f = SC.files[c.code];
  const kpi = (label, v, bad) => `<div class="sc-kpi${bad ? " sc-kpi-bad" : ""}"><span>${escapeHtml(label)}</span><strong>${escapeHtml(String(v))}</strong></div>`;
  let body;
  if (f === undefined || f === null) body = `<p class="mg-muted">${escapeHtml(T("กำลังโหลด…", "Loading…"))}</p>`;
  else if (f.error) body = `<div class="mg-msg" role="status">${escapeHtml(f.error)}</div>`;
  else {
    const n30 = Number(f.orders_30) || 0;
    body = `
    <section class="mg-card">
      <h3>${escapeHtml(T("ออเดอร์ล่าสุด", "Last orders"))}</h3>
      ${f.orders.length ? `<div class="table-scroll"><table class="sc-otable">
        <thead><tr><th>${escapeHtml(T("วันส่ง", "Delivery"))}</th><th>PO</th>
          <th>${escapeHtml(T("สินค้า · สั่ง → ชั่งจริง", "Products · ordered → weighed"))}</th>
          <th class="num">${escapeHtml(T("รวม", "Total"))}</th><th>${escapeHtml(T("สถานะ", "Status"))}</th></tr></thead>
        <tbody>${f.orders.map((r) => `<tr>
          <td class="nowrap"><strong>${escapeHtml(weighThaiDate(r.order_date, { weekday: "short", day: "numeric", month: "short" }))}</strong><br><span class="mg-muted mg-small">${escapeHtml(scAgo(r.order_date))}</span></td>
          <td class="nowrap">${escapeHtml(r.po_number || "—")}${r.part ? `<br><span class="mg-small">${escapeHtml(T("ส่วนที่", "Part"))} ${Number(r.part)}</span>` : ""}<br><span class="mg-muted mg-small">${escapeHtml(weighCompanyShort(r.company))}</span></td>
          <td><ul class="sc-lines">${(r.lines || []).map((w) => `<li><span class="sc-prod">${escapeHtml(w.description || "—")}</span>
            <span class="sc-qty">${escapeHtml(scQty(w))}${w.actual_kg != null && r.status === "confirmed" ? ` → <strong>${escapeHtml(weighFmt(w.actual_kg))} kg</strong>` : ""}</span></li>`).join("")}</ul></td>
          <td class="num nowrap">${r.status === "confirmed" && r.total_kg != null ? `<strong>${escapeHtml(weighFmt(r.total_kg))} kg</strong>` : "—"}</td>
          <td><span class="sc-last-status sc-last-${escapeAttr(r.delivery === "problem" ? "postponed" : r.status)}">${escapeHtml(scStatusText(r.status, r.delivery))}</span>
            ${r.postponed ? `<br><span class="sc-bad mg-small">${escapeHtml(T("เลื่อน", "Postponed"))} ${escapeHtml(weighDayShort(r.postponed.from))} → ${escapeHtml(weighDayShort(r.postponed.to))}${typeof ppReasonLabel === "function" ? " · " + escapeHtml(ppReasonLabel(r.postponed.reason)) : ""}</span>` : ""}</td>
        </tr>`).join("")}</tbody></table></div>`
      : `<p class="mg-muted">${escapeHtml(T("ยังไม่มีออเดอร์ใน PACE", "No order in PACE yet"))}</p>`}
    </section>
    <div class="sc-file-cols">
      <section class="mg-card">
        <h3>${escapeHtml(T("สินค้าที่สั่งประจำ (30 วัน)", "Usual basket, last 30 days"))}</h3>
        ${f.basket.length ? f.basket.map((b) => `<div class="sc-basket">
          <span class="sc-prod">${escapeHtml(b.description)}</span>
          <span class="sc-bar-track" aria-hidden="true"><span style="width:${Math.round(100 * b.orders / Math.max(n30, 1))}%"></span></span>
          <span class="mg-small">${escapeHtml(T(`${b.orders} จาก ${n30} ออเดอร์`, `${b.orders} of ${n30} order${n30 === 1 ? "" : "s"}`))}${b.avg_qty != null ? ` · ~${escapeHtml(String(Number(b.avg_qty)))} ${escapeHtml(weighUnit(b.unit))}` : ""}</span>
        </div>`).join("") : `<p class="mg-muted">${escapeHtml(T("ไม่มีออเดอร์ใน 30 วัน", "No order in the last 30 days"))}</p>`}
      </section>
      <section class="mg-card">
        <h3>${escapeHtml(T("การเลื่อน (30 วัน)", "Postponements, last 30 days"))}</h3>
        ${f.postponements.length ? `<ul class="sc-pp">${f.postponements.map((x) => `<li>
          <strong>${escapeHtml(weighDayShort(x.from))} → ${escapeHtml(x.to ? weighDayShort(x.to) : T("ยังไม่มีวัน", "no date"))}</strong>
          <span>${escapeHtml({ product: T("เลื่อนสินค้า", "product moved"), delivery: T("เลื่อนส่ง", "delivery moved"), production: T("เลื่อนผลิต", "production moved"), order: T("เลื่อนออเดอร์", "order moved") }[x.what] || x.what)}
            · ${escapeHtml(x.by === "production" ? T("โดยฝ่ายผลิต", "by production") : T("โดยมิดเดิลออฟฟิศ", "by the middle office"))}${typeof ppReasonLabel === "function" ? " · " + escapeHtml(ppReasonLabel(x.reason)) : ""}${x.po ? " · " + escapeHtml(x.po) : ""}</span>
        </li>`).join("")}</ul>` : `<p class="mg-muted">${escapeHtml(T("ไม่มีการเลื่อนใน 30 วัน", "No postponement in the last 30 days"))}</p>`}
      </section>
    </div>`;
  }
  return `
    <div class="sc-bar">
      <button type="button" class="w-btn w-btn-outline" data-sc-act="back">← ${escapeHtml(T("ลูกค้าดูแลพิเศษทั้งหมด", "All special care clients"))}</button>
      ${weighLangHtml()}
    </div>
    ${msg}
    <section class="mg-card sc-file-head">
      <div class="sc-file-top">
        <div>
          <h2>${escapeHtml(c.name)}</h2>
          <span class="mg-muted mg-small">${escapeHtml(c.code)}${o ? " · " + escapeHtml(T("พนักงานขาย ", "salesperson ") + o.rep) : ""} · ${escapeHtml(T("ชื่อบนใบงาน: ", "names on papers: "))}${(c.paper_names || []).length ? escapeHtml(c.paper_names.join(", ")) : `<span class="sc-nolink">${escapeHtml(T("ยังไม่เชื่อม", "none linked"))}</span>`}</span>
        </div>
        <div class="sc-file-acts">
          <button type="button" class="w-btn w-btn-outline" data-sc-act="edit" data-code="${escapeAttr(c.code)}">${escapeHtml(T("แก้ไขกฎ", "Edit rules"))}</button>
          <button type="button" class="w-btn w-btn-outline sc-remove" data-sc-act="remove" data-code="${escapeAttr(c.code)}">${escapeHtml(T("เอาออก", "Remove"))}</button>
        </div>
      </div>
      <div class="sc-rules">${scRulesHtml(c)}</div>
      ${c.instructions ? `<p class="sc-card-instr sc-file-instr">${escapeHtml(c.instructions)}</p>` : ""}
      ${o ? `<div class="sc-kpis">
        ${kpi(T("ออเดอร์ 30 วัน", "Orders, 30 days"), o.n30)}
        ${kpi(T("กก. 30 วัน", "Kg, 30 days"), weighFmt(o.kg30, 0))}
        ${kpi(T("ถูกเลื่อน 30 วัน", "Postponed, 30 days"), o.postponed30, o.postponed30 > 0)}
        ${kpi(T("ต่างเกิน ±5% (รายการ)", "Lines off ±5 %"), o.off5_30, o.off5_30 > 0)}
      </div>` : ""}
      <span class="mg-muted mg-small">${escapeHtml(T("แก้ไขล่าสุด ", "Last change ") + (c.updated_by_name || "") + " · " + scTime(c.updated_at))}</span>
    </section>
    ${SC.edit && !SC.edit.isNew && SC.edit.code === c.code ? scFormHtml(SC.edit) : ""}
    ${body}`;
}

async function scOpenFile(code) {
  SC.view = "file"; SC.fileCode = code; SC.edit = null; SC.message = null;
  scDraw();
  window.scrollTo && window.scrollTo(0, 0);
  await scLoadFile(code);
}

// "today", "3 days ago", "in 2 days"
function scAgo(iso) {
  if (!iso) return "";
  const d = weighDaysBetween(iso, weighBangkokToday());
  if (d === 0) return T("วันนี้", "today");
  if (d === 1) return T("เมื่อวาน", "yesterday");
  if (d === -1) return T("พรุ่งนี้", "tomorrow");
  return d > 0 ? T(`${d} วันก่อน`, `${d} days ago`) : T(`อีก ${-d} วัน`, `in ${-d} days`);
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
      <label><input type="checkbox" id="sc-np"${e.no_postpone ? " checked" : ""}> <strong>${escapeHtml(T("ห้ามเลื่อน", "No postpone"))}</strong>
        <small>${escapeHtml(T("เลื่อนได้ แต่ทุกหน้าจะเตือนก่อน และผู้บริหารได้รับแจ้งทันที", "Postponing stays possible, but every screen warns first and management is notified at once"))}</small></label>
      <label><input type="checkbox" id="sc-eq"${e.exact_quantity ? " checked" : ""}> <strong>${escapeHtml(T("ส่งครบจำนวน", "Exact quantity"))}</strong>
        <small>${escapeHtml(T("ห้ามส่งขาด: การเลื่อนสินค้าบางรายการจะเตือนก่อน และแจ้งผู้บริหาร", "No short delivery: moving one product to another day warns first and notifies management"))}</small></label>
      <label><input type="checkbox" id="sc-pd"${e.priority_delivery ? " checked" : ""}> <strong>${escapeHtml(T("ส่งก่อน", "Priority delivery"))}</strong>
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
  SC.edit = null; SC.q = ""; SC.results = []; SC.adding = false;
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
  if (!error && SC.fileCode === code) { SC.view = "cards"; SC.fileCode = null; }
  await scLoad();
}

if (scSection) {
  scSection.addEventListener("input", (e) => {
    if (e.target.id === "sc-q") {
      SC.q = e.target.value;
      clearTimeout(scSearchTimer);
      scSearchTimer = setTimeout(scSearch, 250);
    } else if (e.target.id === "sc-cq") {
      SC.cq = e.target.value;
      const pos = e.target.selectionStart;
      scDraw();
      const box = document.getElementById("sc-cq");
      if (box) { box.focus(); try { box.setSelectionRange(pos, pos); } catch (err) { /* type=search */ } }
    }
  });
  scSection.addEventListener("submit", (e) => {
    if (e.target.id === "sc-form") { e.preventDefault(); scSave(); }
  });
  scSection.addEventListener("click", (e) => {
    const lang = e.target.closest('[data-act="lang"]');
    if (lang) { scReadForm(); weighSetLang(lang.dataset.lang); scDraw(); return; }
    const b = e.target.closest("[data-sc-act]");
    if (!b) {
      // a click anywhere on a card opens the client file
      const card = e.target.closest("[data-sc-open]");
      if (card && !e.target.closest("a, input, label")) scOpenFile(card.dataset.scOpen);
      return;
    }
    const act = b.dataset.scAct;
    if (act === "open") { scOpenFile(b.dataset.code); return; }
    if (act === "back") { SC.view = "cards"; SC.fileCode = null; SC.edit = null; scDraw(); return; }
    if (act === "filter") { SC.filter = b.dataset.k; scDraw(); return; }
    if (act === "add-toggle") {
      SC.adding = !SC.adding; if (!SC.adding) { SC.q = ""; SC.results = []; if (SC.edit && SC.edit.isNew) SC.edit = null; }
      scDraw();
      if (SC.adding) { const q = document.getElementById("sc-q"); if (q) q.focus(); }
      return;
    }
    if (act === "pick") {
      const cur = (SC.list || []).find((x) => x.code === b.dataset.code);
      if (cur) { SC.adding = false; SC.q = ""; SC.results = []; scOpenFile(cur.code).then(() => { SC.edit = Object.assign({ isNew: false }, cur); scDraw(); }); return; }
    }
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
