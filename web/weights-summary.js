// ============================================================================
// Confirmed weights — read-only summary (Migration 020, 28 Oct 2026)
// ============================================================================
// The actual weights Khun Muay confirmed on the weighing screen, for the
// people who use them downstream: accounting (invoices in Odoo) and
// purchasing, and the middle office (30 Oct 2026). Shown in PROSUN PACE ›
// Accounting / Purchasing / Middle office › Confirmed weights.
//
// Keeps itself up to date: readers have no access to the weighing tables, so
// they cannot receive the database's live events. Instead the summary is
// fetched again every 20 seconds while the screen is open and the browser tab
// is in front, and at once when the tab comes back — filters, search and
// scroll position are kept.
//
// "Checked" marks (Migration 022, 30 Oct 2026): clicking a paper's line marks
// it as checked for the reader's department and colours it, so colleagues see
// what has already been opened. Shared inside a department (with the name and
// time), separate between departments. If the factory re-confirms the paper
// with new weights afterwards, it turns amber: "changed since checked". The
// tick box in the first column undoes a mark. Marks never change a weight.
//
// Read-only by design: a wrong number is corrected at the factory, where the
// photo is checked ("แก้ไข" on the weighing screen), so there is one source of
// truth. The data comes from the database function weighing_confirmed_lines,
// which returns confirmed papers only — a paper still being checked never
// appears here.
//
// Loaded after weighing.js (reuses weighDiff, weighFmt, weighUnit,
// weighCompanyShort, weighShortDate, weighLangHtml's language, T) and before
// app.js; uses app.js globals at run time (sb, myProfile, escapeHtml,
// escapeAttr, downloadXlsx).
// ============================================================================

const wsSection = document.getElementById("weights-section");

const WS = {
  from: null,          // ISO date, Bangkok
  to: null,
  preset: "today",
  company: "all",      // all | Prosun Farm | Prosun Food
  q: "",               // search: customer, PO or product
  rows: [],            // weighing_confirmed_lines result
  pending: 0,          // papers in the period not yet confirmed
  loading: false,
  message: null,       // { kind, text }
  timer: null,
  sig: "",             // fingerprint of the last data shown — redraw only on change
  updatedAt: null,     // last successful load
  dept: "accounting",  // whose "checked" marks: accounting | purchasing | middle_office
  show: "all",         // all | todo (not checked, or changed since) | done
};

const WS_DEPT_LABEL = {
  accounting:    () => T("บัญชี", "Accounting"),
  purchasing:    () => T("จัดซื้อ", "Purchasing"),
  middle_office: () => T("ฝ่ายสนับสนุนการขาย", "Middle office"),
};

// Staff mark for their own department; admin for the menu he opened it from
// (paceWeightsDept in app.js). The database applies the same rule.
function wsDeptFor() {
  const r = myProfile && myProfile.role;
  if (r === "accounting") return "accounting";
  if (r === "purchasing") return "purchasing";
  if (r === "sale_support") return "middle_office";
  const fromMenu = typeof paceWeightsDept === "string" ? paceWeightsDept : "Accounting";
  return fromMenu === "Purchasing" ? "purchasing" : fromMenu === "Middle office" ? "middle_office" : "accounting";
}

function wsCheckState(r) {
  if (!r.checked_at) return "none";
  if (r.check_confirmed_at && r.confirmed_at && new Date(r.confirmed_at) > new Date(r.check_confirmed_at)) return "changed";
  return "checked";
}

const WS_REFRESH_MS = window.__wsRefreshMs || 20000;

function wsAddDays(iso, n) {
  const d = new Date(iso + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

// Periods are by delivery date. Weeks run Monday to Sunday, so a Sunday
// delivery is never left out.
function wsPresetRange(preset) {
  const today = weighBangkokToday();
  const dow = (new Date(today + "T00:00:00Z").getUTCDay() + 6) % 7;   // Monday = 0
  const monday = wsAddDays(today, -dow);
  const first = today.slice(0, 8) + "01";
  const nextFirst = (() => { const d = new Date(first + "T00:00:00Z"); d.setUTCMonth(d.getUTCMonth() + 1); return d.toISOString().slice(0, 10); })();
  const prevFirst = (() => { const d = new Date(first + "T00:00:00Z"); d.setUTCMonth(d.getUTCMonth() - 1); return d.toISOString().slice(0, 10); })();
  switch (preset) {
    case "yesterday": return [wsAddDays(today, -1), wsAddDays(today, -1)];
    case "tomorrow":  return [wsAddDays(today, 1), wsAddDays(today, 1)];
    case "week":      return [monday, wsAddDays(monday, 6)];
    case "lastweek":  return [wsAddDays(monday, -7), wsAddDays(monday, -1)];
    case "month":     return [first, wsAddDays(nextFirst, -1)];
    case "lastmonth": return [prevFirst, wsAddDays(first, -1)];
    default:          return [today, today];
  }
}

const WS_PRESETS = [
  ["yesterday", () => T("เมื่อวาน", "Yesterday")],
  ["today",     () => T("วันนี้", "Today")],
  ["tomorrow",  () => T("พรุ่งนี้", "Tomorrow")],
  ["week",      () => T("สัปดาห์นี้", "This week")],
  ["lastweek",  () => T("สัปดาห์ที่แล้ว", "Last week")],
  ["month",     () => T("เดือนนี้", "This month")],
  ["lastmonth", () => T("เดือนที่แล้ว", "Last month")],
];


// ----------------------------------------------------------- open / close
async function openWeights() {
  if (!WEIGH_LANG) WEIGH_LANG = myProfile.role === "admin" ? "en" : "th";
  if (myProfile.role === "accounting") {
    document.getElementById("who-role").textContent = T("บัญชี", "Accounting");
  }
  wsSection.classList.remove("hidden");
  const dept = wsDeptFor();
  if (dept !== WS.dept) { WS.dept = dept; WS.rows = []; WS.sig = ""; }
  if (!WS.from) [WS.from, WS.to] = wsPresetRange(WS.preset);
  wsSection.innerHTML = `<p class="w-muted">${T("กำลังโหลด…", "Loading…")}</p>`;
  await wsLoad();
}

function closeWeights() {
  clearTimeout(WS.timer);
  if (wsSection.classList.contains("hidden")) return;
  wsSection.classList.add("hidden");
  wsSection.innerHTML = "";
}

function wsOpen() { return !wsSection.classList.contains("hidden"); }

function wsSchedule() {
  clearTimeout(WS.timer);
  if (!wsOpen()) return;
  WS.timer = setTimeout(async () => {
    if (!wsOpen()) return;
    if (document.hidden || WS.loading) { wsSchedule(); return; }
    await wsLoad({ silent: true });
  }, WS_REFRESH_MS);
}

document.addEventListener("visibilitychange", () => {
  if (!document.hidden && wsOpen() && !WS.loading) wsLoad({ silent: true });
});

document.getElementById("switch-system-btn").addEventListener("click", closeWeights);
document.getElementById("sign-out-btn").addEventListener("click", () => {
  closeWeights();
  WS.from = WS.to = null; WS.preset = "today"; WS.rows = []; WS.q = ""; WS.company = "all"; WS.show = "all"; WS.sig = "";
});


// ------------------------------------------------------------------ data
// silent = the automatic refresh: no "Loading…", the filters stay as they
// are, and the table is redrawn only if something actually changed. A failed
// silent refresh (e.g. a short network drop) keeps the last data on screen.
async function wsLoad(opts = {}) {
  const silent = !!opts.silent;
  const from = WS.from, to = WS.to, dept = WS.dept;
  WS.loading = true;
  if (!silent) WS.message = null;
  const [lines, pending] = await Promise.all([
    sb.rpc("weighing_confirmed_lines", { p_from: from, p_to: to, p_dept: dept }),
    sb.rpc("weighing_unconfirmed_count", { p_from: from, p_to: to }),
  ]);
  WS.loading = false;
  if (!wsOpen()) return;
  if (from !== WS.from || to !== WS.to || dept !== WS.dept) return;   // the period changed meanwhile; that load wins
  if (lines.error) {
    if (!silent) {
      WS.rows = [];
      WS.sig = "";
      WS.message = { kind: "error", text: T("โหลดข้อมูลไม่ได้: ", "Could not load: ") + lines.error.message };
      wsRender();
    }
    wsSchedule();
    return;
  }
  const rows = lines.data || [];
  const count = pending.error ? WS.pending : Number(pending.data) || 0;
  const sig = JSON.stringify([rows, count]);
  WS.updatedAt = new Date();
  if (silent && sig === WS.sig) {
    const st = document.getElementById("ws-updated");
    if (st) st.textContent = wsUpdatedText();
  } else {
    WS.rows = rows;
    WS.pending = count;
    WS.sig = sig;
    if (silent) wsRenderResults(); else wsRender();
  }
  wsSchedule();
}

function wsUpdatedText() {
  return WS.updatedAt
    ? T(`อัปเดต ${weighTime(WS.updatedAt.toISOString())} · รีเฟรชเองทุก 20 วินาที`, `Updated ${weighTime(WS.updatedAt.toISOString())} · refreshes by itself every 20 s`)
    : "";
}

function wsFiltered(ignoreShow) {
  const q = WS.q.trim().toLowerCase();
  return WS.rows.filter((r) => {
    if (!ignoreShow && WS.show !== "all") {
      const st = wsCheckState(r);
      if (WS.show === "done" && st !== "checked") return false;
      if (WS.show === "todo" && st === "checked") return false;
    }
    if (WS.company !== "all" && r.company !== WS.company) return false;
    if (!q) return true;
    return [r.customer_name, r.po_number, r.description].some((v) => v && String(v).toLowerCase().includes(q));
  });
}

function wsWhen(ts) {
  if (!ts) return "";
  const d = new Date(ts);
  const day = d.toLocaleDateString(WEIGH_LANG === "en" ? "en-GB" : "th-TH", { day: "numeric", month: "numeric", timeZone: "Asia/Bangkok" });
  return `${day} ${weighTime(ts)}`;
}

function wsRangeLabel() {
  const o = { day: "numeric", month: "short", year: "numeric" };
  return WS.from === WS.to ? weighThaiDate(WS.from, o) : `${weighThaiDate(WS.from, o)} – ${weighThaiDate(WS.to, o)}`;
}


// ------------------------------------------------------------- rendering
function wsRender() {
  wsSection.innerHTML = `
  ${WS.message ? `<div class="w-msg w-msg-${WS.message.kind}" role="status">${escapeHtml(WS.message.text)}
    <button type="button" class="w-msg-close" data-ws="dismiss" aria-label="${T("ปิด", "Close")}">×</button></div>` : ""}
  <div class="w-head">
    <div>
      <h2 class="w-day">${escapeHtml(wsRangeLabel())}</h2>
      <div class="w-muted w-small">${T("น้ำหนักจริงที่โรงงานยืนยันแล้ว ตามวันส่ง — ดูอย่างเดียว ถ้าตัวเลขผิดให้โรงงานแก้", "Actual weights confirmed at the factory, by delivery date — read-only; a wrong number is corrected by the factory")}</div>
      <div class="w-small ws-howto">${T(
        `คลิกที่ใบงานเพื่อทำเครื่องหมายว่าตรวจแล้ว — เพื่อนใน${WS_DEPT_LABEL[WS.dept]()}จะเห็นด้วย · เอาเครื่องหมายออกที่ช่อง ✓`,
        `Click a paper to mark it checked — your ${WS_DEPT_LABEL[WS.dept]()} colleagues see it too · untick the ✓ box to undo`)}</div>
    </div>
    <div class="w-head-right">${weighLangHtml().replace(/data-act="lang"/g, 'data-ws="lang"')}</div>
  </div>

  <section class="w-panel ws-filters">
    <div class="ws-presets" role="group" aria-label="${T("ช่วงวันที่", "Period")}">
      ${WS_PRESETS.map(([k, label]) => `<button type="button" class="ws-chip${WS.preset === k ? " on" : ""}" data-ws="preset" data-preset="${k}" aria-pressed="${WS.preset === k}">${label()}</button>`).join("")}
    </div>
    <div class="ws-fields">
      <label>${T("วันส่ง ตั้งแต่", "Delivery from")}<input type="date" data-ws-field="from" value="${escapeAttr(WS.from)}"></label>
      <label>${T("ถึง", "to")}<input type="date" data-ws-field="to" value="${escapeAttr(WS.to)}"></label>
      <label>${T("บริษัท", "Company")}
        <select data-ws-field="company">
          <option value="all"${WS.company === "all" ? " selected" : ""}>${T("ทั้งหมด", "All")}</option>
          <option value="Prosun Farm"${WS.company === "Prosun Farm" ? " selected" : ""}>Prosun Farm</option>
          <option value="Prosun Food"${WS.company === "Prosun Food" ? " selected" : ""}>Prosun Food</option>
        </select></label>
      <label>${T("แสดง", "Show")}
        <select data-ws-field="show">
          <option value="all"${WS.show === "all" ? " selected" : ""}>${T("ทั้งหมด", "All papers")}</option>
          <option value="todo"${WS.show === "todo" ? " selected" : ""}>${T("ยังไม่ได้ตรวจ", "Not checked yet")}</option>
          <option value="done"${WS.show === "done" ? " selected" : ""}>${T("ตรวจแล้ว", "Checked")}</option>
        </select></label>
      <label class="ws-search">${T("ค้นหา", "Search")}<input type="search" data-ws-field="q" value="${escapeAttr(WS.q)}" placeholder="${T("ลูกค้า, PO หรือสินค้า", "Customer, PO or product")}"></label>
      <button type="button" class="w-btn w-btn-outline" data-ws="refresh">${T("โหลดใหม่", "Refresh")}</button>
    </div>
  </section>

  <div id="ws-results">${wsResultsHtml()}</div>`;
}

function wsResultsHtml() {
  const rows = wsFiltered();
  const papers = new Set(rows.map((r) => r.paper_id)).size;
  const base = wsFiltered(true);
  const basePapers = new Set(base.map((r) => r.paper_id)).size;
  const doneP = new Set(base.filter((r) => wsCheckState(r) === "checked").map((r) => r.paper_id)).size;
  const changedP = new Set(base.filter((r) => wsCheckState(r) === "changed").map((r) => r.paper_id)).size;
  const totalKg = rows.reduce((s, r) => s + (r.actual_kg === null ? 0 : Number(r.actual_kg)), 0);
  let prev = null;

  return `
  <div class="w-counters ws-counters">
    <div class="w-counter w-c-green"><span>${T("ใบงานที่ยืนยัน", "Confirmed papers")}</span><strong>${papers}</strong></div>
    <div class="w-counter"><span>${T("รายการ", "Lines")}</span><strong>${rows.length}</strong></div>
    <div class="w-counter"><span>${T("น้ำหนักรวม (kg)", "Total actual (kg)")}</span><strong>${weighFmt(totalKg)}</strong></div>
    <div class="w-counter ${WS.pending ? "w-c-amber" : ""}"><span>${T("ยังไม่ยืนยัน", "Not yet confirmed")}</span><strong>${WS.pending}</strong></div>
    <div class="w-counter ws-c-checked"><span>${T("ตรวจแล้ว", "Checked")} (${escapeHtml(WS_DEPT_LABEL[WS.dept]())})</span><strong>${doneP} / ${basePapers}</strong></div>
  </div>
  ${changedP ? `<div class="w-note w-note-amber ws-pending">${T(
    `${changedP} ใบที่ตรวจแล้วถูกแก้น้ำหนักที่โรงงานภายหลัง (สีส้ม) — ตรวจอีกครั้ง`,
    `${changedP} checked paper${changedP === 1 ? " was" : "s were"} corrected at the factory afterwards (amber) — check again`)}</div>` : ""}
  ${WS.pending ? `<div class="w-note w-note-amber ws-pending">${T(
    `ยังมีใบงาน ${WS.pending} ใบในช่วงนี้ที่โรงงานยังตรวจไม่เสร็จ — ยังไม่อยู่ในตาราง`,
    `${WS.pending} paper${WS.pending === 1 ? "" : "s"} in this period ${WS.pending === 1 ? "is" : "are"} still being checked at the factory — not in the table yet`)}</div>` : ""}

  <section class="w-panel w-table-panel">
    <div class="w-panel-head">
      <div>
        <h3>${T("ตารางน้ำหนักที่ยืนยันแล้ว", "Confirmed weights")}</h3>
        <div class="w-small w-muted">${T(`${rows.length} รายการจาก ${papers} ใบงาน`, `${rows.length} line${rows.length === 1 ? "" : "s"} from ${papers} paper${papers === 1 ? "" : "s"}`)}
          · <span id="ws-updated">${escapeHtml(wsUpdatedText())}</span></div>
      </div>
      <button type="button" class="w-btn" data-ws="export"${rows.length ? "" : " disabled"}>${T("ส่งออก Excel", "Export to Excel")}</button>
    </div>
    <div class="table-scroll w-scroll">
      <table class="w-table" id="weights-table">
        <thead><tr><th class="ws-cb-col" title="${T("ตรวจแล้ว", "Checked")}">✓</th><th>${T("วันส่ง", "Delivery")}</th><th>${T("บริษัท", "Company")}</th><th>PO</th><th>${T("ลูกค้า", "Customer")}</th><th>${T("สินค้า", "Product")}</th>
          <th class="w-num">${T("สั่ง", "Ordered")}</th><th class="w-num">${T("ชั่งจริง (kg)", "Actual (kg)")}</th><th class="w-num">${T("ต่าง", "Difference")}</th>
          <th>${T("ยืนยันโดย", "Confirmed by")}</th><th>${T("รูป", "Photo")}</th><th>${T("ตรวจแล้ว", "Checked")} · ${escapeHtml(WS_DEPT_LABEL[WS.dept]())}</th></tr></thead>
        <tbody>${WS.loading ? `<tr><td colspan="12" class="w-empty">${T("กำลังโหลด…", "Loading…")}</td></tr>`
          : rows.length ? rows.map((r) => {
          const first = r.paper_id !== prev;
          prev = r.paper_id;
          const d = weighDiff(r);
          const st = wsCheckState(r);
          const label = [r.po_number ? "PO " + r.po_number : "", r.customer_name || ""].filter(Boolean).join(" · ");
          return `<tr class="ws-row ws-st-${st}${first ? " w-first" : ""}" data-paper="${escapeAttr(r.paper_id)}">
            <td class="ws-cb-col">${first ? `<input type="checkbox" class="ws-cb" data-ws-check="${escapeAttr(r.paper_id)}"${st === "checked" ? " checked" : ""} aria-label="${T("ตรวจแล้ว", "Checked")}: ${escapeAttr(label)}">` : ""}</td>
            <td>${first ? (r.delivery_date ? escapeHtml(weighShortDate(r.delivery_date)) : `<span class="w-muted" title="${T("ไม่มีวันส่งบนใบงาน — ใช้วันที่ชั่ง", "No delivery date on the paper — weighing day shown")}">${escapeHtml(weighShortDate(r.work_date))}*</span>`) : ""}</td>
            <td>${first ? escapeHtml(weighCompanyShort(r.company)) : ""}</td>
            <td class="w-mono">${first ? escapeHtml(r.po_number || "") : ""}</td>
            <td>${first ? escapeHtml(r.customer_name || "") : ""}</td>
            <td class="w-wrap">${escapeHtml(r.description || "")}${r.edited ? ` <span class="ws-edited" title="${T("แก้ตัวเลขด้วยมือที่โรงงาน", "Corrected by hand at the factory")}">${T("แก้ไข", "corrected")}</span>` : ""}</td>
            <td class="w-num">${escapeHtml(r.ordered_text || "")}</td>
            <td class="w-num w-strong">${r.actual_kg === null ? `<span class="w-muted">—</span>` : weighFmt(r.actual_kg)}</td>
            <td class="w-num ${d.warn ? "w-warn" : ""}">${escapeHtml(d.text)}</td>
            <td>${first ? escapeHtml(`${r.confirmed_by_name || ""} ${wsWhen(r.confirmed_at)}`.trim()) : ""}</td>
            <td>${first ? (r.photo_deleted_at ? `<span class="w-muted w-small">${T("ลบแล้ว", "Deleted")}</span>`
              : `<button type="button" class="btn-link" data-ws="photo" data-path="${escapeAttr(r.photo_path)}" data-paper="${escapeAttr(r.paper_id)}">${T("ดูรูป", "View")}</button>`) : ""}</td>
            <td class="ws-check-who">${first ? (st === "checked" ? `✓ ${escapeHtml(`${r.checked_by_name || ""} ${wsWhen(r.checked_at)}`.trim())}`
              : st === "changed" ? `<span class="ws-changed-tag">${T("แก้หลังตรวจ — ตรวจอีกครั้ง", "Changed since checked")}</span>` : "") : ""}</td>
          </tr>`;
        }).join("") : `<tr><td colspan="12" class="w-empty">${WS.rows.length
          ? T("ไม่มีรายการที่ตรงกับตัวกรอง", "No lines match the filters")
          : T("ยังไม่มีน้ำหนักที่ยืนยันในช่วงนี้", "No confirmed weights in this period yet")}</td></tr>`}</tbody>
      </table>
    </div>
    <p class="w-small w-muted w-foot">${T(
      "แถวสีเขียว = ตรวจแล้ว · แถวสีส้ม = โรงงานแก้น้ำหนักหลังตรวจ · สินค้าที่สั่งเป็นตัว / แพค แสดงน้ำหนักเฉลี่ยต่อหน่วยในช่อง “ต่าง” · ตัวเลขสีส้ม = ต่างจากที่สั่งเกิน ±5% · * = ใบงานไม่มีวันส่ง ใช้วันที่ชั่ง · รูปเก็บไว้ 4 สัปดาห์",
      "Green rows = checked · amber rows = corrected at the factory after they were checked · lines ordered by the piece or pack show the average kg per unit under “Difference” · orange figures = more than ±5% off the order · * = no delivery date on the paper, weighing day used · photos are kept 4 weeks")}</p>
  </section>`;
}

function wsRenderResults() {
  const el = document.getElementById("ws-results");
  if (!el) return;
  const sc = el.querySelector(".w-scroll");
  const left = sc ? sc.scrollLeft : 0;
  el.innerHTML = wsResultsHtml();
  const sc2 = el.querySelector(".w-scroll");
  if (sc2 && left) sc2.scrollLeft = left;
}


// --------------------------------------------------------------- actions
wsSection.addEventListener("click", async (e) => {
  const el = e.target.closest("[data-ws]");
  // A click anywhere on a paper's rows (not on a control) marks it checked.
  if (!el) {
    if (e.target.closest("input, select, label, a, button")) return;
    const tr = e.target.closest("tr.ws-row[data-paper]");
    if (tr && wsSection.contains(tr)) {
      const row = WS.rows.find((r) => r.paper_id === tr.dataset.paper);
      if (row && wsCheckState(row) !== "checked") await wsMark(tr.dataset.paper, true);
    }
    return;
  }
  if (!wsSection.contains(el)) return;
  const act = el.dataset.ws;
  if (act === "dismiss") { WS.message = null; wsRender(); return; }
  if (act === "lang") {
    weighSetLang(el.dataset.lang);
    if (myProfile.role === "accounting") document.getElementById("who-role").textContent = T("บัญชี", "Accounting");
    wsRender();
    return;
  }
  if (act === "preset") {
    WS.preset = el.dataset.preset;
    [WS.from, WS.to] = wsPresetRange(WS.preset);
    WS.loading = true; wsRender();
    await wsLoad();
    return;
  }
  if (act === "refresh") { await wsLoad(); return; }
  if (act === "export") { wsExport(); return; }
  if (act === "photo") {
    const row = WS.rows.find((r) => r.paper_id === el.dataset.paper);
    const opening = wsOpenPhoto(el.dataset.path);      // opens the tab during the click
    if (row && wsCheckState(row) !== "checked") wsMark(el.dataset.paper, true);
    await opening;
  }
});

// Mark / unmark a paper for this department. Shown at once; undone if the
// database refuses (e.g. the factory reopened the paper meanwhile).
async function wsMark(paperId, checked) {
  const rows = WS.rows.filter((r) => r.paper_id === paperId);
  if (!rows.length) return;
  const before = rows.map((r) => ({ checked_at: r.checked_at, checked_by_name: r.checked_by_name, check_confirmed_at: r.check_confirmed_at }));
  const now = new Date().toISOString();
  rows.forEach((r) => Object.assign(r, checked
    ? { checked_at: now, checked_by_name: myProfile.full_name, check_confirmed_at: r.confirmed_at }
    : { checked_at: null, checked_by_name: null, check_confirmed_at: null }));
  wsRenderResults();
  const { data, error } = await sb.rpc("weighing_mark_checked", { p_paper: paperId, p_dept: WS.dept, p_checked: checked });
  if (error) {
    rows.forEach((r, i) => Object.assign(r, before[i]));
    WS.message = { kind: "error", text: T("บันทึกการตรวจไม่ได้: ", "Could not save the check: ") + error.message };
    wsRender();
    return;
  }
  const res = Array.isArray(data) ? data[0] : data;
  if (res) rows.forEach((r) => Object.assign(r, {
    checked_at: res.checked_at || null, checked_by_name: res.checked_by_name || null, check_confirmed_at: res.check_confirmed_at || null }));
  WS.sig = JSON.stringify([WS.rows, WS.pending]);
  wsRenderResults();
}

wsSection.addEventListener("change", async (e) => {
  if (e.target.dataset.wsCheck) { await wsMark(e.target.dataset.wsCheck, e.target.checked); return; }
  const f = e.target.dataset.wsField;
  if (!f || f === "q") return;
  if (f === "company") { WS.company = e.target.value; wsRenderResults(); return; }
  if (f === "show") { WS.show = e.target.value; wsRenderResults(); return; }
  if (!e.target.value) return;
  WS[f] = e.target.value;
  if (WS.from > WS.to) { if (f === "from") WS.to = WS.from; else WS.from = WS.to; }
  WS.preset = "custom";
  WS.loading = true; wsRender();
  await wsLoad();
});

// Search filters as you type, redrawing only the results (the box keeps focus).
wsSection.addEventListener("input", (e) => {
  if (e.target.dataset.wsField !== "q") return;
  WS.q = e.target.value;
  wsRenderResults();
});

// The window is opened during the click itself, so browsers don't block it,
// then pointed at a short-lived signed link to the private photo.
async function wsOpenPhoto(path) {
  const win = window.open("", "_blank");
  const { data, error } = await sb.storage.from(WEIGH_BUCKET).createSignedUrl(path, 600);
  if (error || !data || !data.signedUrl) {
    if (win) win.close();
    WS.message = { kind: "error", text: T("เปิดรูปไม่ได้: ", "Could not open the photo: ") + ((error && error.message) || T("ไม่พบรูป", "photo not found")) };
    wsRender();
    return;
  }
  if (win) win.location.href = data.signedUrl;
  else window.location.href = data.signedUrl;
}


// ------------------------------------------------------------ Excel export
// One row per line, numbers as numbers and dates as YYYY-MM-DD, so the sheet
// can be filtered, totalled or prepared for an Odoo import without retyping.
function wsExport() {
  const rows = wsFiltered();
  const header = WEIGH_LANG === "en"
    ? ["Delivery date", "Weighing day", "Company", "PO", "Customer", "Line", "Product", "Ordered",
       "Ordered qty", "Unit", "Actual (kg)", "Difference (kg)", "kg per unit", "Corrected by hand",
       "Confirmed by", "Confirmed at", "Checked (" + WS_DEPT_LABEL[WS.dept]() + ") by", "Checked at"]
    : ["วันส่ง", "วันที่ชั่ง", "บริษัท", "PO", "ลูกค้า", "ลำดับ", "สินค้า", "สั่ง",
       "จำนวนสั่ง", "หน่วย", "น้ำหนักจริง (kg)", "ต่าง (kg)", "kg ต่อหน่วย", "แก้ไขด้วยมือ",
       "ยืนยันโดย", "เวลายืนยัน", "ตรวจแล้ว (" + WS_DEPT_LABEL[WS.dept]() + ") โดย", "เวลาตรวจ"];
  const out = [header];
  rows.forEach((r) => {
    const d = weighDiff(r);
    out.push([
      r.delivery_date || "", r.work_date || "", r.company || "", r.po_number || "", r.customer_name || "",
      r.line_no, r.description || "", r.ordered_text || "",
      r.ordered_qty === null || r.ordered_qty === undefined ? "" : Number(r.ordered_qty),
      weighUnit(r.ordered_unit),
      r.actual_kg === null || r.actual_kg === undefined ? "" : Number(r.actual_kg),
      d.kg === null ? "" : d.kg,
      d.perUnit === null ? "" : d.perUnit,
      r.edited ? T("ใช่", "Yes") : "",
      r.confirmed_by_name || "",
      r.confirmed_at ? new Date(new Date(r.confirmed_at).getTime() + 7 * 3600 * 1000).toISOString().slice(0, 16).replace("T", " ") : "",
      wsCheckState(r) === "checked" ? (r.checked_by_name || "") : wsCheckState(r) === "changed" ? T("แก้หลังตรวจ", "Changed since checked") : "",
      wsCheckState(r) === "checked" && r.checked_at ? new Date(new Date(r.checked_at).getTime() + 7 * 3600 * 1000).toISOString().slice(0, 16).replace("T", " ") : "",
    ]);
  });
  const name = WS.from === WS.to ? WS.from : `${WS.from} to ${WS.to}`;
  downloadXlsx(`Confirmed weights ${name}.xlsx`, T("น้ำหนักที่ยืนยันแล้ว", "Confirmed weights"), out,
    [12, 12, 12, 13, 26, 6, 40, 12, 9, 7, 12, 12, 10, 10, 16, 16, 18, 16]);
}
