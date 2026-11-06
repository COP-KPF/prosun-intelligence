// ============================================================================
// Payables — PROSUN PACE › Accounting › Payables (Migration 025, 6 Nov 2026)
// ============================================================================
// Accounting scans and checks; Khun Ann reviews; Khun Kirana selects the
// payments; Clément gives the last approval; Khun Kirana records the payment.
//
// This screen decides nothing. What each person may do comes from
// payable_my_permissions, and the database refuses anything else (see the
// migration). Every step goes through a database function.
//
// Refreshes every 15 seconds while open and in front (5 while a scan is being
// read), and when the browser tab comes back.
//
// Loaded after weighing.js (weighLangHtml) and payables-common.js; uses app.js
// globals at run time (sb, myProfile, escapeHtml, escapeAttr, downloadXlsx).
// ============================================================================

const pySection = document.getElementById("payables-section");

const PY = {
  tab: null, perms: null, rows: [], company: "all", q: "", status: "open",
  sel: new Set(), link: null, uploads: [], message: null, timer: null, sig: "",
  planned: null, paidDate: null, paidRef: "", batchComment: "", suppliers: {},
  open: null, form: null, events: [], fileUrl: null, comment: "", saving: false,
  dirty: false, saveTimer: null, saveState: "", loadError: null, updatedAt: null,
};

const PY_REFRESH_MS = window.__pyRefreshMs || 15000;
const PY_READING_MS = window.__pyReadingMs || 5000;
const PY_IN_PROGRESS = ["uploading", "queued", "reading"];
const PY_DRAFT = ["read", "failed", "returned"];
const PY_OUTSTANDING = ["read", "failed", "returned", "submitted", "reviewed", "proposed", "approved"];

const PY_STATUS = {
  uploading: { th: "กำลังส่ง", en: "Uploading", cls: "w-pill-blue" },
  queued:    { th: "กำลังอ่าน", en: "Reading", cls: "w-pill-blue" },
  reading:   { th: "กำลังอ่าน", en: "Reading", cls: "w-pill-blue" },
  read:      { th: "รอตรวจกับสแกน", en: "To check", cls: "w-pill-amber" },
  failed:    { th: "อ่านไม่ได้", en: "Could not read", cls: "w-pill-red" },
  returned:  { th: "ส่งกลับแก้ไข", en: "Returned", cls: "w-pill-red" },
  submitted: { th: "รอ Khun Ann ตรวจ", en: "Waiting for review", cls: "w-pill-blue" },
  reviewed:  { th: "พร้อมให้เลือกจ่าย", en: "Ready to select", cls: "w-pill-blue" },
  proposed:  { th: "รออนุมัติ", en: "Waiting for approval", cls: "w-pill-amber" },
  approved:  { th: "อนุมัติแล้ว รอจ่าย", en: "Approved, to pay", cls: "w-pill-green" },
  paid:      { th: "จ่ายแล้ว", en: "Paid", cls: "w-pill-green" },
  void:      { th: "ยกเลิก", en: "Void", cls: "w-pill-red" },
};

function pyStatusHtml(s) {
  const st = PY_STATUS[s] || { th: s, en: s, cls: "w-pill-blue" };
  return `<span class="w-pill ${st.cls}">${escapeHtml(T(st.th, st.en))}</span>`;
}

function pyCents(v) { const n = Number(v); return v === null || v === undefined || v === "" || !isFinite(n) ? 0 : Math.round(n * 100); }
function pyMoney(v) {
  if (v === null || v === undefined || v === "") return "—";
  return Number(v).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}
function pySum(rows) { return rows.reduce((a, r) => a + pyCents(r.net_amount), 0) / 100; }
function pyDate(iso) { return iso ? `${iso.slice(8, 10)}/${iso.slice(5, 7)}/${iso.slice(0, 4)}` : "—"; }
function pyCompany(c) { return c === "Prosun Farm" ? "Farm" : c === "Prosun Food" ? "Food" : "—"; }
function pyDays(a, b) { return Math.round((new Date(b + "T00:00:00Z") - new Date(a + "T00:00:00Z")) / 86400000); }
function pyOverdue(r) { return PY_OUTSTANDING.includes(r.status) && r.due_date && r.due_date < weighBangkokToday(); }
function pyNum(v) {
  if (v === null || v === undefined) return null;
  const t = String(v).replace(/[,\s฿]/g, "");
  if (t === "") return null;
  const n = Number(t);
  return isFinite(n) ? n : null;
}


// ----------------------------------------------------------- open / close
async function openPayables() {
  if (!WEIGH_LANG) WEIGH_LANG = myProfile.role === "admin" ? "en" : "th";
  pySection.classList.remove("hidden");
  pySection.innerHTML = `<p class="w-muted">${T("กำลังโหลด…", "Loading…")}</p>`;
  PY.sig = "";
  if (!PY.planned) PY.planned = weighBangkokToday();
  if (!PY.paidDate) PY.paidDate = weighBangkokToday();
  const { data, error } = await sb.rpc("payable_my_permissions");
  if (error) {
    pySection.innerHTML = `<div class="mg-msg">${T("ยังเปิดส่วนเจ้าหนี้ไม่ได้: ", "Payables could not be opened: ")}${escapeHtml(error.message)}</div>`;
    return;
  }
  PY.perms = data;
  if (!PY.tab || !pyTabs().some((t) => t.key === PY.tab)) PY.tab = pyDefaultTab();
  if (PY.perms.scan) await pyEnsureLink();
  await pyLoadSuppliers();
  await pyLoad();
}

async function pyLoadSuppliers() {
  const { data } = await sb.from("payable_suppliers").select("supplier_key, terms_days");
  PY.suppliers = {};
  (data || []).forEach((s) => { PY.suppliers[s.supplier_key] = s.terms_days; });
}

function closePayables() {
  clearTimeout(PY.timer);
  if (pySection.classList.contains("hidden")) return;
  pyFlush();
  pySection.classList.add("hidden");
  pySection.innerHTML = "";
  PY.open = null; PY.form = null;
}

function pyIsOpen() { return !pySection.classList.contains("hidden"); }

function pyTabs() {
  const p = PY.perms || {};
  const c = (fn) => PY.rows.filter(fn).length;
  const tabs = [];
  if (p.approve) tabs.push({ key: "approve", label: T("อนุมัติ", "Approve"), n: c((r) => r.status === "proposed") });
  if (p.review)  tabs.push({ key: "review",  label: T("ตรวจ", "Review"), n: c((r) => r.status === "submitted") });
  if (p.select || p.approve) tabs.push({ key: "select", label: T("เลือกจ่าย", "Select"), n: c((r) => r.status === "reviewed") });
  if (p.pay)     tabs.push({ key: "pay",     label: T("จ่าย", "Pay"), n: c((r) => r.status === "approved") });
  if (p.scan)    tabs.push({ key: "scan",    label: T("สแกนและตรวจ", "Scan and check"), n: c((r) => PY_DRAFT.includes(r.status)) });
  if (p.read)    tabs.push({ key: "summary", label: T("สรุป", "Summary"), n: 0 });
  if (p.read)    tabs.push({ key: "all",     label: T("บิลทั้งหมด", "All bills"), n: 0 });
  return tabs;
}

function pyDefaultTab() {
  const p = PY.perms || {};
  if (p.approve) return "approve";
  if (p.review) return "review";
  if (p.select) return "select";
  if (p.scan) return "scan";
  return "summary";
}


// ------------------------------------------------------------------- data
async function pyLoad() {
  clearTimeout(PY.timer);
  const cols = "id,status,file_path,file_type,uploaded_at,read_error,company,document_no,no_document_reason,po_number,vendor_code,vendor_name,reference,bill_date,due_date,deposit_amount,net_amount,planned_pay_date,approved_at,approved_by,paid_date,paid_reference,last_comment,updated_at";
  const { data, error } = await sb.from("payables").select(cols).order("uploaded_at", { ascending: false }).limit(5000);
  if (!pyIsOpen()) return;
  if (error) {
    PY.loadError = error.message;
  } else {
    PY.loadError = null;
    PY.rows = (data || []).filter((r) => r.status !== "uploading");
    PY.updatedAt = new Date();
    const live = new Set(PY.rows.map((r) => r.id));
    [...PY.sel].forEach((id) => { if (!live.has(id)) PY.sel.delete(id); });
  }
  const sig = JSON.stringify([PY.rows.map((r) => [r.id, r.status, r.updated_at]), PY.loadError]);
  const changed = sig !== PY.sig;
  PY.sig = sig;
  if (PY.open) {
    await pyRefreshOpen(changed);
  } else if (changed && !pyTyping()) {
    pyRender();
  } else if (changed) {
    pyUpdateTabCounts();
  }
  pySchedule();
}

function pySchedule() {
  clearTimeout(PY.timer);
  const reading = PY.rows.some((r) => PY_IN_PROGRESS.includes(r.status));
  PY.timer = setTimeout(async () => {
    if (!pyIsOpen()) return;
    if (!document.hidden) await pyLoad(); else pySchedule();
  }, reading ? PY_READING_MS : PY_REFRESH_MS);
}

document.addEventListener("visibilitychange", () => {
  if (!document.hidden && pyIsOpen()) pyLoad();
});

function pyTyping() {
  const a = document.activeElement;
  return !!a && pySection.contains(a) && ["INPUT", "TEXTAREA", "SELECT"].includes(a.tagName);
}

function pyUpdateTabCounts() {
  pyTabs().forEach((t) => {
    const b = pySection.querySelector(`[data-act="tab"][data-tab="${t.key}"] .py-count`);
    if (b) b.textContent = t.n;
  });
}

function pyFiltered() {
  const q = PY.q.trim().toLowerCase();
  return PY.rows.filter((r) => {
    if (PY.company !== "all" && r.company !== PY.company) return false;
    if (q && ![r.document_no, r.po_number, r.vendor_name, r.vendor_code, r.reference, r.paid_reference]
      .some((v) => String(v || "").toLowerCase().includes(q))) return false;
    return true;
  });
}

function pyOrderDue(rows) {
  return rows.slice().sort((a, b) => String(a.due_date || "9999").localeCompare(String(b.due_date || "9999")));
}


// ----------------------------------------------------------------- render
function pyRender() {
  if (!pyIsOpen()) return;
  if (PY.open) { pyRenderDetail(); return; }
  const tabs = pyTabs();
  const body = PY.tab === "approve" ? pyApproveHtml()
    : PY.tab === "review" ? pyReviewHtml()
    : PY.tab === "select" ? pySelectHtml()
    : PY.tab === "pay" ? pyPayHtml()
    : PY.tab === "scan" ? pyScanHtml()
    : PY.tab === "summary" ? pySummaryHtml()
    : pyAllHtml();
  pySection.innerHTML = `
    <div class="mg-bar">
      <div class="py-tabs" role="tablist">${tabs.map((t) => `
        <button type="button" role="tab" aria-selected="${t.key === PY.tab}" class="py-tab${t.key === PY.tab ? " on" : ""}" data-act="tab" data-tab="${t.key}">
          ${escapeHtml(t.label)}${t.key === "summary" || t.key === "all" ? "" : ` <span class="py-count${t.n ? " py-count-on" : ""}">${t.n}</span>`}
        </button>`).join("")}</div>
      <div class="mg-bar-right">
        <select data-field="company" aria-label="${T("บริษัท", "Company")}">
          <option value="all"${PY.company === "all" ? " selected" : ""}>${T("ทุกบริษัท", "All companies")}</option>
          <option value="Prosun Farm"${PY.company === "Prosun Farm" ? " selected" : ""}>Prosun Farm</option>
          <option value="Prosun Food"${PY.company === "Prosun Food" ? " selected" : ""}>Prosun Food</option>
        </select>
        ${weighLangHtml()}
      </div>
    </div>
    ${pyMessageHtml()}
    ${PY.loadError ? `<div class="mg-msg">${escapeHtml(PY.loadError)}</div>` : ""}
    ${body}`;
}

function pyMessageHtml() {
  if (!PY.message) return "";
  return `<div class="w-msg w-msg-${PY.message.kind}" role="status">${escapeHtml(PY.message.text)}
    <button type="button" class="w-msg-close" data-act="dismiss" aria-label="${T("ปิด", "Close")}">×</button></div>`;
}

function pyTableHtml(rows, opts) {
  opts = opts || {};
  if (!rows.length) return `<p class="mg-muted py-empty">${escapeHtml(opts.empty || T("ไม่มีรายการ", "Nothing here"))}</p>`;
  const today = weighBangkokToday();
  const allOn = opts.pick && rows.every((r) => PY.sel.has(r.id));
  return `<div class="mg-table-wrap"><table class="mg-table py-table">
    <thead><tr>
      ${opts.pick ? `<th><input type="checkbox" data-act="pick-all" ${allOn ? "checked" : ""} aria-label="${T("เลือกทั้งหมด", "Select all")}"></th>` : ""}
      <th>${T("เลขที่ / PO", "Document / PO")}</th><th>${T("ผู้ขาย", "Supplier")}</th><th>${T("บริษัท", "Company")}</th>
      <th>${T("วันที่บิล", "Bill date")}</th><th>${T("ครบกำหนด", "Due")}</th>
      ${opts.planned ? `<th>${T("กำหนดจ่าย", "Planned")}</th>` : ""}
      <th class="mg-n">${T("ยอดจ่าย (บาท)", "To pay (THB)")}</th><th>${T("สถานะ", "Status")}</th>
      ${opts.action ? "<th></th>" : ""}
    </tr></thead>
    <tbody>${rows.map((r) => {
      const late = pyOverdue(r);
      return `<tr class="py-row" data-act="open" data-id="${escapeAttr(r.id)}">
        ${opts.pick ? `<td data-label=""><input type="checkbox" data-act="pick" data-id="${escapeAttr(r.id)}" ${PY.sel.has(r.id) ? "checked" : ""} aria-label="${T("เลือก", "Select")} ${escapeAttr(r.document_no || "")}"></td>` : ""}
        <td data-label="${T("เลขที่", "Document")}"><strong>${escapeHtml(r.document_no || (PY_IN_PROGRESS.includes(r.status) ? T("กำลังอ่าน…", "Reading…") : T("ไม่มีเลขที่", "No number")))}</strong><br><small class="mg-muted">${escapeHtml(r.po_number || "")}</small></td>
        <td data-label="${T("ผู้ขาย", "Supplier")}">${escapeHtml(r.vendor_name || "—")}${r.last_comment && ["returned", "reviewed"].includes(r.status) ? `<br><small class="py-comment-note">${escapeHtml(r.last_comment)}</small>` : ""}</td>
        <td data-label="${T("บริษัท", "Company")}">${escapeHtml(pyCompany(r.company))}</td>
        <td data-label="${T("วันที่บิล", "Bill date")}">${pyDate(r.bill_date)}</td>
        <td data-label="${T("ครบกำหนด", "Due")}" class="${late ? "py-late" : ""}">${pyDate(r.due_date)}${late ? `<br><small>${T("เกิน", "late")} ${pyDays(r.due_date, today)} ${T("วัน", "d")}</small>` : ""}</td>
        ${opts.planned ? `<td data-label="${T("กำหนดจ่าย", "Planned")}">${pyDate(r.planned_pay_date)}</td>` : ""}
        <td data-label="${T("ยอดจ่าย", "To pay")}" class="mg-n"><strong>${pyMoney(r.net_amount)}</strong></td>
        <td data-label="${T("สถานะ", "Status")}">${pyStatusHtml(r.status)}</td>
        ${opts.action ? `<td data-label="">${opts.action(r)}</td>` : ""}
      </tr>`;
    }).join("")}</tbody></table></div>`;
}

function pyPicked(rows) { return rows.filter((r) => PY.sel.has(r.id)); }

function pyPickedNote(rows) {
  const picked = pyPicked(rows);
  return `<strong class="py-total">${picked.length} ${T("บิล", picked.length === 1 ? "bill" : "bills")} · ${pyMoney(pySum(picked))} THB</strong>`;
}

function pyReviewHtml() {
  const rows = pyOrderDue(pyFiltered().filter((r) => r.status === "submitted"));
  return `<div class="mg-card py-card">
    <p class="mg-muted mg-small">${T("เปิดแต่ละบิลเพื่อเทียบกับสแกน ถ้าไม่ถูกต้องให้ส่งกลับพร้อมความเห็น", "Open a bill to compare it with its scan. If something is wrong, return it with a comment.")}</p>
    ${pyTableHtml(rows, { pick: true, empty: T("ไม่มีบิลรอตรวจ", "No bills waiting for review") })}
    ${rows.length ? `<div class="py-batch">${pyPickedNote(rows)}
      <button type="button" class="btn-primary" data-act="review" ${pyPicked(rows).length ? "" : "disabled"}>${T("ตรวจแล้ว", "Mark reviewed")}</button></div>` : ""}
  </div>`;
}

function pySelectHtml() {
  const f = pyFiltered();
  const rows = pyOrderDue(f.filter((r) => r.status === "reviewed"));
  const waiting = pyOrderDue(f.filter((r) => r.status === "proposed"));
  return `<div class="mg-card py-card">
    <h3>${T("เลือกบิลที่ต้องการจ่าย", "Select the payments to propose")}</h3>
    ${pyTableHtml(rows, { pick: true, empty: T("ไม่มีบิลให้เลือก", "No bills ready to select") })}
    ${rows.length ? `<div class="py-batch">${pyPickedNote(rows)}
      <label>${T("วันที่จะจ่าย", "Payment date")} <input type="date" data-field="planned" value="${escapeAttr(PY.planned)}"></label>
      <input type="text" class="py-grow" data-field="batchComment" placeholder="${T("ความเห็น (ถ้ามี)", "Comment (optional)")}" value="${escapeAttr(PY.batchComment)}">
      <button type="button" class="btn-primary" data-act="propose" ${pyPicked(rows).length ? "" : "disabled"}>${T("ส่งขออนุมัติ", "Send for approval")}</button></div>` : ""}
  </div>
  <div class="mg-card py-card">
    <h3>${T("รออนุมัติ", "Waiting for approval")} <span class="mg-muted">· ${pyMoney(pySum(waiting))} THB</span></h3>
    ${pyTableHtml(waiting, { planned: true, empty: T("ไม่มีบิลรออนุมัติ", "Nothing waiting for approval"),
      action: PY.perms.select ? (r) => `<button type="button" class="btn-link" data-act="unpropose" data-id="${escapeAttr(r.id)}">${T("เอาออก", "Remove")}</button>` : null })}
  </div>`;
}

function pyApproveHtml() {
  const rows = pyOrderDue(pyFiltered().filter((r) => r.status === "proposed"));
  const today = weighBangkokToday();
  const dueSoon = rows.filter((r) => r.due_date && r.due_date <= today);
  return `<div class="mg-card py-card">
    <h3>${T("การจ่ายที่รออนุมัติ", "Payments waiting for your approval")}</h3>
    <p class="mg-muted mg-small">${rows.length} ${T("บิล", rows.length === 1 ? "bill" : "bills")} · ${pyMoney(pySum(rows))} THB · ${T("ครบกำหนดแล้ว", "due or overdue")}: ${dueSoon.length}</p>
    ${pyTableHtml(rows, { pick: true, planned: true, empty: T("ไม่มีบิลรออนุมัติ", "Nothing waiting for approval") })}
    ${rows.length ? `<div class="py-batch">${pyPickedNote(rows)}
      <input type="text" class="py-grow" data-field="batchComment" placeholder="${T("ความเห็น (จำเป็นเมื่อพักไว้)", "Comment (required to hold)")}" value="${escapeAttr(PY.batchComment)}">
      <button type="button" class="btn-secondary" data-act="hold" ${pyPicked(rows).length ? "" : "disabled"}>${T("พักไว้ก่อน", "Hold")}</button>
      <button type="button" class="btn-primary" data-act="approve" ${pyPicked(rows).length ? "" : "disabled"}>${T("อนุมัติ", "Approve")}</button></div>` : ""}
  </div>`;
}

function pyPayHtml() {
  const rows = pyOrderDue(pyFiltered().filter((r) => r.status === "approved"));
  return `<div class="mg-card py-card">
    <h3>${T("อนุมัติแล้ว รอจ่าย", "Approved, to pay")}</h3>
    <p class="mg-muted mg-small">${T("จ่ายผ่านธนาคารตามปกติ แล้วบันทึกวันที่และเลขอ้างอิงที่นี่", "Pay through the bank as usual, then record the date and reference here.")}</p>
    ${pyTableHtml(rows, { pick: true, planned: true, empty: T("ไม่มีบิลรอจ่าย", "Nothing to pay") })}
    ${rows.length ? `<div class="py-batch">${pyPickedNote(rows)}
      <label>${T("วันที่จ่าย", "Paid on")} <input type="date" data-field="paidDate" value="${escapeAttr(PY.paidDate)}" max="${weighBangkokToday()}"></label>
      <input type="text" class="py-grow" data-field="paidRef" placeholder="${T("เลขอ้างอิงธนาคาร", "Bank reference")}" value="${escapeAttr(PY.paidRef)}">
      <button type="button" class="btn-primary" data-act="paid" ${pyPicked(rows).length ? "" : "disabled"}>${T("บันทึกว่าจ่ายแล้ว", "Record as paid")}</button></div>` : ""}
  </div>`;
}

function pyQrHtml() {
  if (!PY.link) return `<p class="mg-muted">${T("ยังไม่มี QR", "No QR code yet")}</p>`;
  const url = new URL("ap-capture.html?t=" + PY.link.token, location.href).href;
  let svg = `<a href="${escapeAttr(url)}" target="_blank" rel="noopener">${T("เปิดหน้าถ่ายรูป", "Open the camera page")}</a>`;
  if (typeof qrcode === "function") {
    const qr = qrcode(0, "M");
    qr.addData(url);
    qr.make();
    svg = qr.createSvgTag({ cellSize: 5, margin: 2, scalable: true, alt: T("QR เปิดหน้าสแกนบนมือถือ", "QR code to open the phone scanning page") });
  }
  return `<div class="w-qr" data-qr-url="${escapeAttr(url)}">${svg}</div>
    <p class="w-small w-center">${T("ใช้ได้ถึง 23:59 วันนี้", "Valid until 23:59 today")} ·
    <button type="button" class="btn-link" data-act="new-link">${T("สร้างใหม่", "New code")}</button></p>`;
}

function pyScanHtml() {
  const f = pyFiltered();
  const reading = f.filter((r) => PY_IN_PROGRESS.includes(r.status));
  const todo = f.filter((r) => PY_DRAFT.includes(r.status));
  const returned = todo.filter((r) => r.status === "returned");
  const check = todo.filter((r) => r.status !== "returned");
  return `<div class="py-scan">
    <div class="mg-card py-qr">
      <h3>${T("สแกนด้วยมือถือ", "Scan with a phone")}</h3>
      ${pyQrHtml()}
      <label class="btn-secondary py-upload">${T("อัปโหลดรูปหรือ PDF", "Upload photos or PDFs")}
        <input type="file" data-act="upload" accept="image/*,application/pdf" multiple class="hidden"></label>
      ${PY.uploads.length ? `<ul class="w-uploads">${PY.uploads.map((u) => `<li><span>${escapeHtml(u.name)}</span><span class="w-pill ${u.state === "error" ? "w-pill-red" : u.state === "done" ? "w-pill-green" : "w-pill-blue"}">${u.state === "error" ? T("ส่งไม่สำเร็จ", "Failed") : u.state === "done" ? T("ส่งแล้ว", "Sent") : T("กำลังส่ง…", "Sending…")}</span>${u.error ? `<small class="w-err">${escapeHtml(u.error)}</small>` : ""}</li>`).join("")}</ul>` : ""}
    </div>
    <div class="py-scan-main">
      ${returned.length ? `<div class="mg-card py-card"><h3>${T("ส่งกลับให้แก้ไข", "Returned to you")}</h3>${pyTableHtml(returned)}</div>` : ""}
      <div class="mg-card py-card"><h3>${T("รอตรวจกับสแกน", "To check against the scan")}</h3>
        ${pyTableHtml(reading.concat(check), { empty: T("สแกนบิลเพื่อเริ่ม", "Scan a bill to begin") })}</div>
    </div>
  </div>`;
}

function pyBuckets(rows) {
  const today = weighBangkokToday();
  const b = { nodue: 0, notdue: 0, d15: 0, d30: 0, d31: 0 };
  rows.forEach((r) => {
    const c = pyCents(r.net_amount);
    if (!r.due_date) { b.nodue += c; return; }
    const late = pyDays(r.due_date, today);
    if (late <= 0) b.notdue += c;
    else if (late <= 15) b.d15 += c;
    else if (late <= 30) b.d30 += c;
    else b.d31 += c;
  });
  return b;
}

function pySummaryHtml() {
  const f = pyFiltered();
  const today = weighBangkokToday();
  const week = new Date(new Date(today + "T00:00:00Z").getTime() + 7 * 86400000).toISOString().slice(0, 10);
  const open = f.filter((r) => PY_OUTSTANDING.includes(r.status));
  const late = open.filter(pyOverdue);
  const soon = open.filter((r) => r.due_date && r.due_date >= today && r.due_date <= week);
  const waiting = f.filter((r) => r.status === "proposed");
  const toPay = f.filter((r) => r.status === "approved");
  const paidMonth = f.filter((r) => r.status === "paid" && r.paid_date && r.paid_date.slice(0, 7) === today.slice(0, 7));
  const noNumber = open.filter((r) => !String(r.document_no || "").trim());
  const noDue = open.filter((r) => !r.due_date);
  const tile = (k, rows, cls, act) => `<div class="mg-card mg-tile ${cls || ""}">
    <span class="mg-tile-k">${escapeHtml(k)}</span>
    <span class="mg-tile-v">${pyMoney(pySum(rows))}</span>
    <span class="mg-tile-s">${rows.length} ${T("บิล", rows.length === 1 ? "bill" : "bills")}</span>
    ${act ? `<button type="button" class="mg-go" data-act="tab" data-tab="${act}">${T("เปิด", "Open")} ›</button>` : ""}
  </div>`;
  const b = pyBuckets(open);
  const groups = new Map();
  open.forEach((r) => {
    const k = (r.vendor_code || r.vendor_name || T("ไม่ทราบผู้ขาย", "Unknown supplier")).toUpperCase();
    if (!groups.has(k)) groups.set(k, { name: r.vendor_name || T("ไม่ทราบผู้ขาย", "Unknown supplier"), code: r.vendor_code, rows: [] });
    groups.get(k).rows.push(r);
  });
  const sup = [...groups.values()].map((g) => ({
    ...g, total: pySum(g.rows), overdue: pySum(g.rows.filter(pyOverdue)),
    approved: pySum(g.rows.filter((r) => r.status === "approved")),
    oldest: g.rows.map((r) => r.due_date).filter(Boolean).sort()[0] || null,
  })).sort((x, y) => y.total - x.total);
  return `<div class="mg-tiles">
      ${tile(T("ยอดค้างจ่ายทั้งหมด", "Total owed"), open)}
      ${tile(T("เกินกำหนด", "Overdue"), late, late.length ? "mg-alert" : "")}
      ${tile(T("ครบกำหนดใน 7 วัน", "Due in 7 days"), soon)}
      ${tile(T("รออนุมัติ", "Waiting for approval"), waiting, "", PY.perms.approve ? "approve" : "")}
      ${tile(T("อนุมัติแล้ว รอจ่าย", "Approved, to pay"), toPay, "", PY.perms.pay ? "pay" : "")}
      ${tile(T("จ่ายแล้วเดือนนี้", "Paid this month"), paidMonth, "mg-good")}
    </div>
    <div class="mg-card py-card">
      <h3>${T("อายุหนี้", "Age of what is owed")}</h3>
      <div class="mg-table-wrap"><table class="mg-table"><thead><tr>
        <th class="mg-n">${T("ยังไม่ครบกำหนด", "Not yet due")}</th><th class="mg-n">${T("เกิน 1–15 วัน", "1–15 days late")}</th>
        <th class="mg-n">${T("เกิน 16–30 วัน", "16–30 days late")}</th><th class="mg-n">${T("เกิน 31 วันขึ้นไป", "31+ days late")}</th>
        <th class="mg-n">${T("ไม่มีวันครบกำหนด", "No due date")}</th></tr></thead>
        <tbody><tr><td class="mg-n">${pyMoney(b.notdue / 100)}</td><td class="mg-n">${pyMoney(b.d15 / 100)}</td><td class="mg-n">${pyMoney(b.d30 / 100)}</td><td class="mg-n">${pyMoney(b.d31 / 100)}</td><td class="mg-n">${pyMoney(b.nodue / 100)}</td></tr></tbody>
      </table></div>
    </div>
    <div class="mg-card py-card">
      <div class="mg-card-head"><h3>${T("แยกตามผู้ขาย", "By supplier")}</h3>
        <button type="button" class="btn-secondary" data-act="export">${T("ส่งออก Excel", "Export to Excel")}</button></div>
      ${sup.length ? `<div class="mg-table-wrap"><table class="mg-table"><thead><tr>
        <th>${T("ผู้ขาย", "Supplier")}</th><th class="mg-n">${T("บิล", "Bills")}</th><th class="mg-n">${T("ค้างจ่าย", "Owed")}</th>
        <th class="mg-n">${T("เกินกำหนด", "Overdue")}</th><th class="mg-n">${T("อนุมัติแล้ว", "Approved")}</th><th>${T("ครบกำหนดเก่าสุด", "Oldest due")}</th></tr></thead>
        <tbody>${sup.map((s) => `<tr class="py-row" data-act="supplier" data-name="${escapeAttr(s.code || s.name)}">
          <td>${escapeHtml(s.name)} ${s.code ? `<small class="mg-muted">${escapeHtml(s.code)}</small>` : ""}</td>
          <td class="mg-n">${s.rows.length}</td><td class="mg-n"><strong>${pyMoney(s.total)}</strong></td>
          <td class="mg-n ${s.overdue ? "py-late" : ""}">${pyMoney(s.overdue)}</td><td class="mg-n">${pyMoney(s.approved)}</td><td>${pyDate(s.oldest)}</td></tr>`).join("")}</tbody></table></div>`
        : `<p class="mg-muted">${T("ยังไม่มียอดค้างจ่าย", "Nothing owed yet")}</p>`}
    </div>
    <p class="mg-muted mg-small py-limit">${T("รวมเฉพาะบิลที่สแกนเข้าระบบนี้ บิลที่ยังไม่ได้สแกนจะไม่อยู่ในยอด", "Includes only bills scanned here: anything not yet scanned is missing from these totals.")}
      ${noNumber.length ? T(` บิลไม่มีเลขที่ ${noNumber.length} ใบ`, ` Without a document number: ${noNumber.length}.`) : ""}
      ${noDue.length ? T(` ยังไม่มีวันครบกำหนด ${noDue.length} ใบ`, ` Without a due date yet: ${noDue.length}.`) : ""}</p>`;
}

function pyAllHtml() {
  let rows = pyFiltered();
  if (PY.status === "open") rows = rows.filter((r) => PY_OUTSTANDING.concat(PY_IN_PROGRESS).includes(r.status));
  else if (PY.status !== "all") rows = rows.filter((r) => r.status === PY.status);
  return `<div class="mg-card py-card">
    <div class="py-filters">
      <input type="search" class="py-grow" data-field="q" placeholder="${T("ค้นหา เลขที่ PO ผู้ขาย เลขอ้างอิง", "Search document, PO, supplier, reference")}" value="${escapeAttr(PY.q)}">
      <select data-field="status" aria-label="${T("สถานะ", "Status")}">
        <option value="open"${PY.status === "open" ? " selected" : ""}>${T("ยังไม่จ่าย", "Not yet paid")}</option>
        <option value="all"${PY.status === "all" ? " selected" : ""}>${T("ทั้งหมด", "All")}</option>
        ${["read", "returned", "submitted", "reviewed", "proposed", "approved", "paid", "void"].map((s) => `<option value="${s}"${PY.status === s ? " selected" : ""}>${escapeHtml(T(PY_STATUS[s].th, PY_STATUS[s].en))}</option>`).join("")}
      </select>
      <button type="button" class="btn-secondary" data-act="export">${T("ส่งออก Excel", "Export to Excel")}</button>
    </div>
    <p class="mg-muted mg-small">${rows.length} ${T("บิล", rows.length === 1 ? "bill" : "bills")} · ${pyMoney(pySum(rows.filter((r) => r.status !== "void")))} THB</p>
    ${pyTableHtml(pyOrderDue(rows), { planned: true })}
  </div>`;
}


// ----------------------------------------------------------- bill screen
function pyFormFrom(b) {
  const lines = Array.isArray(b.lines) ? b.lines : [];
  return {
    company: b.company || "", document_no: b.document_no || "", no_document_reason: b.no_document_reason || "",
    po_number: b.po_number || "", vendor_code: b.vendor_code || "", vendor_name: b.vendor_name || "",
    reference: b.reference || "", bill_date: b.bill_date || "", due_date: b.due_date || "",
    vat_amount: b.vat_amount, wht_amount: b.wht_amount, deposit_amount: b.deposit_amount, net_amount: b.net_amount,
    note: b.note || "",
    lines: lines.map((l) => ({ description: l.description || "", quantity: l.quantity ?? null, unit_price: l.unit_price ?? null, amount: l.amount ?? null })),
  };
}

function pyEditable() {
  return !!PY.open && PY.perms.scan && PY_DRAFT.includes(PY.open.status);
}

function pyTermsDue() {
  const f = PY.form;
  if (!pyEditable() || f.due_date || !f.bill_date) return false;
  const key = String(f.vendor_code || f.vendor_name || "").trim().toUpperCase();
  const days = PY.suppliers[key];
  if (days === undefined || days === null) return false;
  f.due_date = new Date(new Date(f.bill_date + "T00:00:00Z").getTime() + days * 86400000).toISOString().slice(0, 10);
  return true;
}

async function pyOpenBill(id) {
  await pyFlush();
  await pyLoadSuppliers();
  const { data, error } = await sb.from("payables").select("*").eq("id", id).maybeSingle();
  if (error || !data) {
    PY.message = { kind: "error", text: error ? error.message : T("ไม่พบบิล", "Bill not found") };
    pyRender();
    return;
  }
  PY.open = data;
  PY.form = pyFormFrom(data);
  PY.comment = "";
  PY.fileUrl = null;
  PY.saveState = "";
  const termsUsed = pyTermsDue();
  await pyLoadOpenExtras();
  pyRenderDetail();
  window.scrollTo(0, 0);
  if (termsUsed) pyQueueSave();
}

async function pyLoadOpenExtras() {
  const b = PY.open;
  const [ev, signed] = await Promise.all([
    sb.from("payable_events").select("*").eq("payable_id", b.id).order("at"),
    PY.fileUrl ? Promise.resolve({ data: { signedUrl: PY.fileUrl } }) : sb.storage.from(PAY_BUCKET).createSignedUrl(b.file_path, 3600),
  ]);
  PY.events = ev.data || [];
  PY.fileUrl = signed.data ? signed.data.signedUrl : null;
}

// Someone else moved the bill while it is on screen: reload it unless the user
// is typing in it, and say so.
async function pyRefreshOpen(changed) {
  if (!PY.open || !changed) return;
  const row = PY.rows.find((r) => r.id === PY.open.id);
  if (!row || (row.updated_at === PY.open.updated_at && row.status === PY.open.status)) return;
  if (PY.dirty || PY.saving) return;
  const { data } = await sb.from("payables").select("*").eq("id", PY.open.id).maybeSingle();
  if (!data || !PY.open) return;
  const moved = data.status !== PY.open.status;
  PY.open = data;
  if (!pyTyping() || moved) {
    PY.form = pyFormFrom(data);
    await pyLoadOpenExtras();
    if (moved) PY.message = { kind: "info", text: T("บิลนี้เพิ่งเปลี่ยนสถานะ", "This bill has just changed status") };
    pyRenderDetail();
  }
}

function pyChecks() {
  const f = PY.form;
  const out = [];
  const sum = f.lines.reduce((a, l) => a + pyCents(l.amount), 0) + pyCents(f.vat_amount) - pyCents(f.wht_amount);
  const net = pyCents(f.net_amount);
  const addsUp = f.net_amount !== null && f.net_amount !== undefined && f.net_amount !== "" && Math.abs(sum - net) <= 5;
  out.push({ ok: addsUp, key: "sum", text: addsUp
    ? T(`ยอดรวมรายการตรงกับยอดจ่าย ${pyMoney(net / 100)}`, `Lines add up to the net amount: ${pyMoney(net / 100)}`)
    : T(`ยอดรวมรายการ ${pyMoney(sum / 100)} ไม่ตรงกับยอดจ่าย ${pyMoney(net / 100)}`, `Lines add up to ${pyMoney(sum / 100)}, but the net amount is ${pyMoney(net / 100)}`) });
  const bad = f.lines.filter((l) => l.quantity !== null && l.unit_price !== null && l.amount !== null
    && Math.abs(Math.round(l.quantity * l.unit_price * 100) - pyCents(l.amount)) > 5);
  if (bad.length) out.push({ ok: false, text: T(`จำนวน × ราคา ไม่ตรงกับยอดเงิน ${bad.length} รายการ`, `Quantity × price differs from the amount on ${bad.length} ${bad.length === 1 ? "line" : "lines"}`) });
  const no = String(f.document_no || "").trim().toUpperCase();
  const dup = no ? PY.rows.filter((r) => r.id !== PY.open.id && r.status !== "void" && r.company === f.company && String(r.document_no || "").trim().toUpperCase() === no) : [];
  if (dup.length) out.push({ ok: false, text: T(`เลขที่ ${no} มีอยู่แล้วในระบบ`, `Document ${no} is already in the system`) });
  if (!no && !String(f.no_document_reason || "").trim()) out.push({ ok: false, text: T("ไม่มีเลขที่เอกสาร ต้องระบุเหตุผล", "No document number: a reason is required") });
  if (!f.due_date) out.push({ ok: false, text: T("ยังไม่มีวันครบกำหนด", "No due date yet") });
  return out;
}

function pyFieldHtml(label, key, type, value, opts) {
  opts = opts || {};
  const ro = !pyEditable();
  if (ro) {
    const shown = type === "date" ? pyDate(value) : type === "money" ? pyMoney(value) : (value || "—");
    return `<div class="py-field${opts.wide ? " py-wide" : ""}"><span class="py-label">${escapeHtml(label)}</span><span class="py-value">${escapeHtml(String(shown))}</span></div>`;
  }
  const req = opts.required ? " py-req" : "";
  const input = type === "company"
    ? `<select data-form="${key}"><option value=""></option>${["Prosun Farm", "Prosun Food"].map((c) => `<option${value === c ? " selected" : ""}>${c}</option>`).join("")}</select>`
    : type === "date" ? `<input type="date" data-form="${key}" value="${escapeAttr(value || "")}">`
    : type === "money" ? `<input type="text" inputmode="decimal" class="py-num" data-form="${key}" value="${value === null || value === undefined ? "" : escapeAttr(value)}">`
    : `<input type="text" data-form="${key}" value="${escapeAttr(value || "")}">`;
  return `<label class="py-field${opts.wide ? " py-wide" : ""}"><span class="py-label${req}">${escapeHtml(label)}</span>${input}</label>`;
}

function pyActionsHtml() {
  const b = PY.open, p = PY.perms;
  const btn = [];
  let needsComment = false;
  if (p.scan && PY_DRAFT.includes(b.status)) {
    if (b.status !== "returned") btn.push(`<button type="button" class="btn-secondary" data-act="reread">${T("อ่านใหม่", "Read again")}</button>`);
    btn.push(`<button type="button" class="btn-link py-danger" data-act="void">${T("ยกเลิกบิล", "Void")}</button>`);
    btn.push(`<button type="button" class="btn-primary" data-act="submit">${T("ตรวจกับสแกนแล้ว ส่ง Khun Ann", "Checked against the scan: submit")}</button>`);
    needsComment = true;
  }
  if (p.review && b.status === "submitted") {
    btn.push(`<button type="button" class="btn-secondary" data-act="return">${T("ส่งกลับแก้ไข", "Return to accounting")}</button>`);
    btn.push(`<button type="button" class="btn-primary" data-act="review-one">${T("ตรวจแล้ว", "Mark reviewed")}</button>`);
    needsComment = true;
  }
  if (p.review && ["reviewed", "proposed", "approved"].includes(b.status)) {
    btn.push(`<button type="button" class="btn-secondary" data-act="return">${T("ส่งกลับแก้ไข", "Return to accounting")}</button>`);
    needsComment = true;
  }
  if (p.select && b.status === "proposed") btn.push(`<button type="button" class="btn-secondary" data-act="unpropose" data-id="${escapeAttr(b.id)}">${T("เอาออกจากรายการเลือก", "Remove from selection")}</button>`);
  if (p.approve && ["proposed", "approved"].includes(b.status)) {
    btn.push(`<button type="button" class="btn-secondary" data-act="return">${T("ส่งกลับแก้ไข", "Return to accounting")}</button>`);
    btn.push(`<button type="button" class="btn-secondary" data-act="hold-one">${T("พักไว้ก่อน", "Hold")}</button>`);
    if (b.status === "proposed") btn.push(`<button type="button" class="btn-primary" data-act="approve-one">${T("อนุมัติ", "Approve")} ${pyMoney(b.net_amount)} THB</button>`);
    needsComment = true;
  }
  if ((p.review || p.approve) && ["submitted", "reviewed", "proposed", "approved"].includes(b.status)) {
    btn.unshift(`<button type="button" class="btn-link py-danger" data-act="void">${T("ยกเลิกบิล", "Void")}</button>`);
    needsComment = true;
  }
  let pay = "";
  if (p.pay && b.status === "approved") {
    pay = `<div class="py-batch">
      <label>${T("วันที่จ่าย", "Paid on")} <input type="date" data-field="paidDate" value="${escapeAttr(PY.paidDate)}" max="${weighBangkokToday()}"></label>
      <input type="text" class="py-grow" data-field="paidRef" placeholder="${T("เลขอ้างอิงธนาคาร", "Bank reference")}" value="${escapeAttr(PY.paidRef)}">
      <button type="button" class="btn-primary" data-act="paid-one">${T("บันทึกว่าจ่ายแล้ว", "Record as paid")}</button></div>`;
  }
  if (p.pay && b.status === "paid") {
    btn.push(`<button type="button" class="btn-secondary" data-act="undo-paid">${T("ยกเลิกการบันทึกจ่าย", "Cancel payment record")}</button>`);
    needsComment = true;
  }
  if (!btn.length && !pay) return "";
  return `<div class="mg-card py-card py-actions">
    ${pay}
    ${needsComment ? `<textarea rows="2" data-field="comment" placeholder="${T("ความเห็น (จำเป็นเมื่อส่งกลับ พักไว้ หรือยกเลิก)", "Comment (required to return, hold or void)")}">${escapeHtml(PY.comment)}</textarea>` : ""}
    ${btn.length ? `<div class="py-btns">${btn.join("")}</div>` : ""}
  </div>`;
}

function pyRenderDetail() {
  const b = PY.open, f = PY.form;
  if (!b) { pyRender(); return; }
  const edit = pyEditable();
  const checks = pyChecks();
  const siblings = (b.po_number ? PY.rows.filter((r) => r.id !== b.id && r.po_number === b.po_number && r.status !== "void") : []);
  const isPdf = b.file_type === "application/pdf";
  const doc = PY.fileUrl
    ? (isPdf ? `<iframe src="${escapeAttr(PY.fileUrl)}" title="${T("สแกนบิล", "Bill scan")}" class="py-doc"></iframe>`
             : `<a href="${escapeAttr(PY.fileUrl)}" target="_blank" rel="noopener"><img src="${escapeAttr(PY.fileUrl)}" alt="${T("สแกนบิล", "Bill scan")}" class="py-doc-img"></a>`)
    : `<p class="mg-muted">${T("เปิดไฟล์สแกนไม่ได้", "The scan could not be opened")}</p>`;
  const sel = ["approved", "paid"].includes(b.status) ? `<p class="mg-small">${T("อนุมัติ", "Approved")}: <strong>${pyMoney(b.approved_amount)} THB</strong></p>` : "";
  const paid = b.status === "paid" ? `<p class="mg-small">${T("จ่ายเมื่อ", "Paid on")} ${pyDate(b.paid_date)} · ${T("อ้างอิง", "reference")} ${escapeHtml(b.paid_reference || "")}</p>` : "";
  pySection.innerHTML = `
    <div class="mg-bar">
      <button type="button" class="btn-secondary" data-act="back">‹ ${T("กลับ", "Back")}</button>
      <div class="mg-bar-right">${pyStatusHtml(b.status)} <span class="mg-muted mg-small" id="py-save">${escapeHtml(PY.saveState)}</span> ${weighLangHtml()}</div>
    </div>
    ${pyMessageHtml()}
    ${b.status === "failed" ? `<div class="mg-msg">${T("อ่านบิลไม่ได้ กรอกเองหรืออ่านใหม่: ", "This bill could not be read. Enter it by hand or read again: ")}${escapeHtml(b.read_error || "")}</div>` : ""}
    ${b.last_comment && ["returned", "reviewed", "void"].includes(b.status) ? `<div class="py-note"><strong>${T("ความเห็นล่าสุด", "Latest comment")}:</strong> ${escapeHtml(b.last_comment)}</div>` : ""}
    <div class="py-detail">
      <div class="mg-card py-doc-card">
        ${doc}
        ${PY.fileUrl ? `<p class="mg-small"><a href="${escapeAttr(PY.fileUrl)}" target="_blank" rel="noopener">${T("เปิดในแท็บใหม่", "Open in a new tab")}</a></p>` : ""}
      </div>
      <div class="py-side">
        <div class="mg-card py-card">
          <div class="py-grid">
            ${pyFieldHtml(T("บริษัทที่จ่าย", "Paying company"), "company", "company", f.company, { required: true })}
            ${pyFieldHtml(T("เลขที่เอกสาร", "Document no."), "document_no", "text", f.document_no)}
            ${pyFieldHtml(T("ผู้ขาย (จ่ายให้)", "Supplier (pay to)"), "vendor_name", "text", f.vendor_name, { required: true, wide: true })}
            ${pyFieldHtml(T("รหัสผู้ขาย", "Supplier code"), "vendor_code", "text", f.vendor_code)}
            ${pyFieldHtml("PO", "po_number", "text", f.po_number)}
            ${pyFieldHtml(T("วันที่บิล", "Bill date"), "bill_date", "date", f.bill_date, { required: true })}
            ${pyFieldHtml(T("ครบกำหนด", "Due date"), "due_date", "date", f.due_date, { required: true })}
            ${pyFieldHtml(T("อ้างอิง", "Reference"), "reference", "text", f.reference, { wide: true })}
            ${!String(f.document_no || "").trim() ? pyFieldHtml(T("เหตุผลที่ไม่มีเลขที่", "Why there is no document number"), "no_document_reason", "text", f.no_document_reason, { wide: true, required: true }) : ""}
          </div>
          <div class="mg-table-wrap"><table class="mg-table py-lines"><thead><tr>
            <th>${T("รายการ", "Description")}</th><th class="mg-n">${T("จำนวน", "Qty")}</th><th class="mg-n">${T("ราคา", "Price")}</th><th class="mg-n">${T("ยอดเงิน", "Amount")}</th>${edit ? "<th></th>" : ""}
          </tr></thead><tbody>${f.lines.map((l, i) => edit ? `<tr>
            <td><input type="text" data-line="${i}" data-key="description" value="${escapeAttr(l.description)}" aria-label="${T("รายการ", "Description")}"></td>
            <td><input type="text" inputmode="decimal" class="py-num" data-line="${i}" data-key="quantity" value="${l.quantity ?? ""}" aria-label="${T("จำนวน", "Quantity")}"></td>
            <td><input type="text" inputmode="decimal" class="py-num" data-line="${i}" data-key="unit_price" value="${l.unit_price ?? ""}" aria-label="${T("ราคา", "Price")}"></td>
            <td><input type="text" inputmode="decimal" class="py-num" data-line="${i}" data-key="amount" value="${l.amount ?? ""}" aria-label="${T("ยอดเงิน", "Amount")}"></td>
            <td><button type="button" class="btn-link py-danger" data-act="del-line" data-i="${i}" aria-label="${T("ลบรายการ", "Remove line")}">×</button></td></tr>`
            : `<tr><td>${escapeHtml(l.description)}</td><td class="mg-n">${l.quantity ?? ""}</td><td class="mg-n">${l.unit_price === null ? "" : pyMoney(l.unit_price)}</td><td class="mg-n">${pyMoney(l.amount)}</td></tr>`).join("")}
          </tbody></table></div>
          ${edit ? `<button type="button" class="btn-link" data-act="add-line">+ ${T("เพิ่มรายการ", "Add line")}</button>` : ""}
          <div class="py-grid py-totals">
            ${pyFieldHtml("VAT", "vat_amount", "money", f.vat_amount)}
            ${pyFieldHtml(T("หัก ณ ที่จ่าย", "Withholding tax"), "wht_amount", "money", f.wht_amount)}
            ${pyFieldHtml(T("มัดจำที่จ่ายแล้ว", "Deposit already paid"), "deposit_amount", "money", f.deposit_amount)}
            ${pyFieldHtml(T("ยอดจ่ายสุทธิ", "Net amount to pay"), "net_amount", "money", f.net_amount, { required: true })}
          </div>
          ${f.note ? `<p class="py-note mg-small">${T("จากการอ่าน", "From the reading")}: ${escapeHtml(f.note)}</p>` : ""}
          ${sel}${paid}
          ${b.planned_pay_date ? `<p class="mg-small">${T("กำหนดจ่าย", "Planned payment")}: ${pyDate(b.planned_pay_date)}</p>` : ""}
          <ul class="py-checks" id="py-checks">${pyChecksHtml(checks)}</ul>
        </div>
        ${pyActionsHtml()}
        ${siblings.length ? `<div class="mg-card py-card"><h3>${T("บิลอื่นใน PO นี้", "Other bills on this PO")}</h3>
          <ul class="py-mini">${siblings.map((s) => `<li><button type="button" class="btn-link" data-act="open" data-id="${escapeAttr(s.id)}">${escapeHtml(s.document_no || T("ไม่มีเลขที่", "No number"))}</button> <span class="mg-n">${pyMoney(s.net_amount)}</span> ${pyStatusHtml(s.status)}</li>`).join("")}</ul></div>` : ""}
        <div class="mg-card py-card"><h3>${T("ประวัติ", "History")}</h3>
          ${PY.events.length ? `<ol class="py-history">${PY.events.map((e) => `<li><span class="mg-muted mg-small">${pyDate(new Date(new Date(e.at).getTime() + 7 * 3600000).toISOString().slice(0, 10))} ${escapeHtml(weighTime(e.at))}</span>
            <strong>${escapeHtml(e.actor_name || "")}</strong> ${escapeHtml(e.action)} · ${pyMoney(e.net_amount)} THB${e.comment ? `<br><span class="py-comment-note">${escapeHtml(e.comment)}</span>` : ""}</li>`).join("")}</ol>`
            : `<p class="mg-muted mg-small">${T("ยังไม่มีการดำเนินการ", "No steps yet")}</p>`}
        </div>
      </div>
    </div>`;
}

function pyChecksHtml(checks) {
  return checks.map((c) => `<li class="${c.ok ? "py-ok" : "py-bad"}"><span aria-hidden="true">${c.ok ? "✓" : "!"}</span> ${escapeHtml(c.text)}</li>`).join("");
}


// ------------------------------------------------------------------- save
function pyPayload() {
  const f = PY.form;
  const empty = (v) => { const t = String(v ?? "").trim(); return t === "" ? null : t; };
  return {
    company: empty(f.company), document_no: empty(f.document_no), no_document_reason: empty(f.no_document_reason),
    po_number: empty(f.po_number), vendor_code: empty(f.vendor_code), vendor_name: empty(f.vendor_name),
    reference: empty(f.reference), bill_date: empty(f.bill_date), due_date: empty(f.due_date),
    vat_amount: f.vat_amount ?? null, wht_amount: f.wht_amount ?? null, deposit_amount: f.deposit_amount ?? null,
    net_amount: f.net_amount ?? null, lines: f.lines,
  };
}

function pyQueueSave() {
  PY.dirty = true;
  pySetSave(T("กำลังบันทึก…", "Saving…"));
  clearTimeout(PY.saveTimer);
  PY.saveTimer = setTimeout(pyFlush, 600);
}

function pySetSave(text) {
  PY.saveState = text;
  const el = document.getElementById("py-save");
  if (el) el.textContent = text;
}

async function pyFlush() {
  clearTimeout(PY.saveTimer);
  if (!PY.dirty || !PY.open) return true;
  PY.dirty = false;
  PY.saving = true;
  const { data, error } = await sb.from("payables").update(pyPayload()).eq("id", PY.open.id).select("id, updated_at");
  PY.saving = false;
  if (error || !data || !data.length) {
    PY.dirty = true;
    pySetSave(T("บันทึกไม่สำเร็จ", "Not saved"));
    PY.message = { kind: "error", text: error ? error.message : T("บิลนี้ถูกล็อกแล้ว", "This bill is locked") };
    return false;
  }
  PY.open.updated_at = data[0].updated_at;
  pySetSave(T("บันทึกแล้ว", "Saved"));
  return true;
}


// ---------------------------------------------------------------- actions
async function pyRpc(fn, args, okText) {
  const { data, error } = await sb.rpc(fn, args);
  if (error) {
    PY.message = { kind: "error", text: error.message };
    return { ok: false };
  }
  PY.message = okText ? { kind: "info", text: okText } : null;
  return { ok: true, data };
}

async function pyAfterBatch() {
  PY.sel.clear();
  PY.batchComment = "";
  PY.sig = "";
  await pyLoad();
}

async function pyAfterBill(res) {
  if (res.ok) { PY.open = null; PY.form = null; PY.comment = ""; PY.sig = ""; await pyLoad(); pyRender(); }
  else pyRenderDetail();
}

function pySelectedRows(statuses) {
  return PY.rows.filter((r) => PY.sel.has(r.id) && statuses.includes(r.status));
}

function pyNeedComment(text) {
  if (String(text || "").trim()) return true;
  PY.message = { kind: "error", text: T("กรุณาใส่ความเห็น", "Please enter a comment") };
  pyRender();
  return false;
}

async function pyAction(act, el) {
  if (act === "tab") { PY.tab = el.dataset.tab; PY.sel.clear(); PY.message = null; pyRender(); return; }
  if (act === "dismiss") { PY.message = null; pyRender(); return; }
  if (act === "lang") { weighSetLang(el.dataset.lang); pyRender(); return; }
  if (act === "open") { await pyOpenBill(el.dataset.id); return; }
  if (act === "back") { await pyFlush(); PY.open = null; PY.form = null; PY.message = null; PY.sig = ""; await pyLoad(); pyRender(); return; }
  if (act === "supplier") { PY.q = el.dataset.name; PY.status = "open"; PY.tab = "all"; pyRender(); return; }
  if (act === "export") { pyExport(); return; }
  if (act === "new-link") { await pyEnsureLink(true); pyRender(); return; }
  if (act === "add-line") { PY.form.lines.push({ description: "", quantity: null, unit_price: null, amount: null }); pyQueueSave(); pyRenderDetail(); return; }
  if (act === "del-line") { PY.form.lines.splice(Number(el.dataset.i), 1); pyQueueSave(); pyRenderDetail(); return; }

  const id = PY.open && PY.open.id;
  el.disabled = true;
  if (act === "review") {
    const r = pySelectedRows(["submitted"]);
    const res = await pyRpc("payable_review", { p_ids: r.map((x) => x.id) }, T(`ตรวจแล้ว ${r.length} บิล`, `${r.length} reviewed`));
    if (res.ok) await pyAfterBatch(); else pyRender();
  } else if (act === "propose") {
    const r = pySelectedRows(["reviewed"]);
    const res = await pyRpc("payable_propose", { p_ids: r.map((x) => x.id), p_date: PY.planned, p_comment: PY.batchComment || null }, T(`ส่งขออนุมัติ ${r.length} บิล`, `${r.length} sent for approval`));
    if (res.ok) await pyAfterBatch(); else pyRender();
  } else if (act === "approve") {
    const r = pySelectedRows(["proposed"]);
    const res = await pyRpc("payable_approve", { p_ids: r.map((x) => x.id), p_total: pySum(r), p_comment: PY.batchComment || null }, T(`อนุมัติ ${r.length} บิล ${pyMoney(pySum(r))} บาท`, `${r.length} approved: ${pyMoney(pySum(r))} THB`));
    if (res.ok) await pyAfterBatch(); else pyRender();
  } else if (act === "hold") {
    if (!pyNeedComment(PY.batchComment)) return;
    const r = pySelectedRows(["proposed"]);
    const res = await pyRpc("payable_hold", { p_ids: r.map((x) => x.id), p_comment: PY.batchComment }, T(`พักไว้ ${r.length} บิล`, `${r.length} held`));
    if (res.ok) await pyAfterBatch(); else pyRender();
  } else if (act === "paid") {
    const r = pySelectedRows(["approved"]);
    const res = await pyRpc("payable_mark_paid", { p_ids: r.map((x) => x.id), p_date: PY.paidDate, p_reference: PY.paidRef }, T(`บันทึกจ่ายแล้ว ${r.length} บิล`, `${r.length} recorded as paid`));
    if (res.ok) { PY.paidRef = ""; await pyAfterBatch(); } else pyRender();
  } else if (act === "unpropose") {
    const res = await pyRpc("payable_unpropose", { p_id: el.dataset.id }, T("เอาออกจากรายการแล้ว", "Removed from the selection"));
    if (PY.open) await pyAfterBill(res); else { PY.sig = ""; await pyLoad(); pyRender(); }
  } else if (act === "submit") {
    if (await pyFlush()) await pyAfterBill(await pyRpc("payable_submit", { p_id: id, p_comment: PY.comment || null }, T("ส่งให้ Khun Ann แล้ว", "Submitted for review")));
    else pyRenderDetail();
  } else if (act === "reread") {
    try {
      const { data: s } = await sb.auth.getSession();
      await payCallFn({ action: "read", bill_id: id }, s.session.access_token);
      await pyAfterBill({ ok: true });
    } catch (e) { PY.message = { kind: "error", text: e.message }; pyRenderDetail(); }
  } else if (act === "review-one") {
    await pyAfterBill(await pyRpc("payable_review", { p_ids: [id], p_comment: PY.comment || null }, T("ตรวจแล้ว", "Reviewed")));
  } else if (act === "approve-one") {
    await pyAfterBill(await pyRpc("payable_approve", { p_ids: [id], p_total: Number(PY.open.net_amount), p_comment: PY.comment || null }, T("อนุมัติแล้ว", "Approved")));
  } else if (act === "hold-one") {
    if (pyNeedCommentDetail()) await pyAfterBill(await pyRpc("payable_hold", { p_ids: [id], p_comment: PY.comment }, T("พักไว้แล้ว", "Held")));
  } else if (act === "return") {
    if (pyNeedCommentDetail()) await pyAfterBill(await pyRpc("payable_return", { p_id: id, p_comment: PY.comment }, T("ส่งกลับแล้ว", "Returned to accounting")));
  } else if (act === "void") {
    if (pyNeedCommentDetail()) await pyAfterBill(await pyRpc("payable_void", { p_id: id, p_comment: PY.comment }, T("ยกเลิกบิลแล้ว", "Bill voided")));
  } else if (act === "paid-one") {
    const res = await pyRpc("payable_mark_paid", { p_ids: [id], p_date: PY.paidDate, p_reference: PY.paidRef }, T("บันทึกจ่ายแล้ว", "Recorded as paid"));
    if (res.ok) PY.paidRef = "";
    await pyAfterBill(res);
  } else if (act === "undo-paid") {
    if (pyNeedCommentDetail()) await pyAfterBill(await pyRpc("payable_undo_paid", { p_id: id, p_comment: PY.comment }, T("ยกเลิกการบันทึกจ่ายแล้ว", "Payment record cancelled")));
  }
}

function pyNeedCommentDetail() {
  if (String(PY.comment || "").trim()) return true;
  PY.message = { kind: "error", text: T("กรุณาใส่ความเห็น", "Please enter a comment") };
  pyRenderDetail();
  return false;
}

async function pyEnsureLink(fresh) {
  const me = myProfile.id;
  if (fresh && PY.link) {
    await sb.from("payable_capture_links").update({ revoked: true }).eq("token", PY.link.token);
    PY.link = null;
  }
  if (!fresh) {
    const { data } = await sb.from("payable_capture_links").select("token, expires_at")
      .eq("created_by", me).eq("revoked", false).gt("expires_at", new Date().toISOString())
      .order("created_at", { ascending: false }).limit(1);
    if (data && data.length) { PY.link = data[0]; return; }
  }
  const midnight = new Date(new Date(weighBangkokToday() + "T00:00:00+07:00").getTime() + 86400000).toISOString();
  const { data, error } = await sb.from("payable_capture_links")
    .insert({ created_by: me, expires_at: midnight }).select("token, expires_at").single();
  if (error) PY.message = { kind: "error", text: error.message };
  else PY.link = data;
}

async function pyUpload(files) {
  const { data: s } = await sb.auth.getSession();
  const token = s.session && s.session.access_token;
  for (const file of [...files]) {
    const u = { name: file.name, state: "send", error: null };
    PY.uploads.unshift(u);
    pyRender();
    try {
      const prepared = await payPrepareFile(file);
      await payUploadFile(sb, prepared, {}, token);
      u.state = "done";
    } catch (e) {
      u.state = "error";
      u.error = e.message;
    }
    PY.uploads = PY.uploads.slice(0, 8);
    PY.sig = "";
    await pyLoad();
  }
}

function pyExport() {
  const rows = pyOrderDue(pyFiltered().filter((r) => r.status !== "void"));
  const head = [T("เลขที่", "Document"), "PO", T("รหัสผู้ขาย", "Supplier code"), T("ผู้ขาย", "Supplier"), T("บริษัท", "Company"),
    T("วันที่บิล", "Bill date"), T("ครบกำหนด", "Due date"), T("ยอดจ่าย (บาท)", "Net to pay (THB)"), T("สถานะ", "Status"),
    T("กำหนดจ่าย", "Planned"), T("วันที่จ่าย", "Paid on"), T("อ้างอิงธนาคาร", "Bank reference")];
  const data = rows.map((r) => [r.document_no || "", r.po_number || "", r.vendor_code || "", r.vendor_name || "", r.company || "",
    r.bill_date || "", r.due_date || "", r.net_amount === null ? "" : Number(r.net_amount),
    T((PY_STATUS[r.status] || {}).th || r.status, (PY_STATUS[r.status] || {}).en || r.status),
    r.planned_pay_date || "", r.paid_date || "", r.paid_reference || ""]);
  downloadXlsx(`Payables ${weighBangkokToday()}.xlsx`, "Payables", [head, ...data], [16, 14, 12, 30, 14, 12, 12, 16, 22, 12, 12, 18]);
}


// ----------------------------------------------------------------- events
pySection.addEventListener("click", async (e) => {
  // The tick box's cell never opens the bill: a near miss must not leave the list.
  const cell = e.target.closest("td,th");
  if (cell && cell.querySelector('[data-act="pick"],[data-act="pick-all"]')) return;
  if (e.target.closest("a")) return;
  const el = e.target.closest("[data-act]");
  if (!el || el.tagName === "INPUT") return;
  await pyAction(el.dataset.act, el);
});

pySection.addEventListener("change", async (e) => {
  const t = e.target;
  if (t.dataset.act === "upload") { await pyUpload(t.files); t.value = ""; return; }
  if (t.dataset.act === "pick") {
    if (t.checked) PY.sel.add(t.dataset.id); else PY.sel.delete(t.dataset.id);
    pyRender();
    return;
  }
  if (t.dataset.act === "pick-all") {
    const statuses = { review: ["submitted"], select: ["reviewed"], approve: ["proposed"], pay: ["approved"] }[PY.tab] || [];
    pyFiltered().filter((r) => statuses.includes(r.status)).forEach((r) => { if (t.checked) PY.sel.add(r.id); else PY.sel.delete(r.id); });
    pyRender();
    return;
  }
  if (t.dataset.field === "company") { PY.company = t.value; PY.sel.clear(); pyRender(); return; }
  if (t.dataset.field === "status") { PY.status = t.value; pyRender(); return; }
  if (t.dataset.form && t.tagName === "SELECT") { PY.form[t.dataset.form] = t.value; pyQueueSave(); pyUpdateChecks(); return; }
  if (t.dataset.form === "bill_date" || t.dataset.form === "vendor_code" || t.dataset.form === "vendor_name" || t.dataset.form === "document_no") {
    if (pyTermsDue() || t.dataset.form === "document_no") { pyQueueSave(); pyRenderDetail(); }
  }
});

pySection.addEventListener("input", (e) => {
  const t = e.target;
  if (t.dataset.field === "q") {
    PY.q = t.value;
    const pos = t.selectionStart;
    pyRender();
    const again = pySection.querySelector('[data-field="q"]');
    if (again) { again.focus(); again.setSelectionRange(pos, pos); }
    return;
  }
  if (t.dataset.field) {
    if (t.dataset.field === "planned") PY.planned = t.value;
    else if (t.dataset.field === "paidDate") PY.paidDate = t.value;
    else if (t.dataset.field === "paidRef") PY.paidRef = t.value;
    else if (t.dataset.field === "batchComment") PY.batchComment = t.value;
    else if (t.dataset.field === "comment") PY.comment = t.value;
    return;
  }
  if (t.dataset.form) {
    const key = t.dataset.form;
    PY.form[key] = ["vat_amount", "wht_amount", "deposit_amount", "net_amount"].includes(key) ? pyNum(t.value) : t.value;
    pyQueueSave();
    pyUpdateChecks();
    return;
  }
  if (t.dataset.line !== undefined) {
    const line = PY.form.lines[Number(t.dataset.line)];
    line[t.dataset.key] = t.dataset.key === "description" ? t.value : pyNum(t.value);
    pyQueueSave();
    pyUpdateChecks();
  }
});

function pyUpdateChecks() {
  const el = document.getElementById("py-checks");
  if (el) el.innerHTML = pyChecksHtml(pyChecks());
}
