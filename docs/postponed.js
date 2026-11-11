// ============================================================================
// Postponed orders — PACE › Middle office (Migration 027, 10 Nov 2026)
// ============================================================================
// One list of every postponed order, from two sources:
//   - Production: papers postponed on the weighing screen (the factory could
//     not produce them that day). Read-only here; production records them.
//   - Middle office: deliveries postponed from Confirmed weights (Migration
//     028 — the paper was produced, only its delivery moved), and the register,
//     for postponements that never reach the weighing screen — a client asking
//     to move a delivery, or an order moved before its paper reached
//     production. Sale support adds and corrects register rows; only admin
//     deletes them.
// Every new postponement, and any change to a register record's dates or
// reason, notifies management in the bell. The Management dashboard counts
// both sources.
//
// Loaded after weighing.js (reuses PP_REASONS, ppReasonLabel, weighLangHtml,
// weighSetLang, weighDayShort) and before management.js; uses app.js globals
// at run time (sb, myProfile, escapeHtml, escapeAttr, paceUserNames,
// ensurePaceUserNames).
// ============================================================================

const ppSection = document.getElementById("postponed-section");

const PP = {
  register: [],      // order_postponements
  factory: [],       // weighing_postponements
  customers: [],
  editing: null,     // the register row being corrected
  message: null,     // { kind: "ok" | "err", text }
  show: "all",       // all | factory | register | open
  missing: false,    // Migration 027 not run yet
};

function ppDate(iso) {
  if (!iso) return "—";
  return new Date(iso + "T00:00:00Z").toLocaleDateString(WEIGH_LANG === "en" ? "en-GB" : "th-TH",
    { day: "numeric", month: "short", year: "2-digit", timeZone: "UTC" });
}

function ppDays(a, b) {
  if (!a || !b) return null;
  return Math.round((new Date(b + "T00:00:00Z") - new Date(a + "T00:00:00Z")) / 86400000);
}

// Both sources in one shape, newest date missed first.
function ppRows() {
  const f = PP.factory.map(r => ({
    source: r.stage === "delivery" ? "confirmed" : "factory", id: r.id, paper_id: r.paper_id,
    customer_name: r.customer_name, po_number: r.po_number, company: r.company,
    product: r.lines ? T(`${r.lines} รายการ`, `${r.lines} line${r.lines === 1 ? "" : "s"}`) : null,
    quantity_kg: r.kg_ordered,
    original_date: r.from_delivery_date || r.from_work_date,
    new_date: r.to_delivery_date,
    production: r.stage === "delivery" ? null : [r.from_work_date, r.to_work_date],
    reason: r.reason, note: r.note, created_by: r.created_by, created_at: r.created_at,
  }));
  const m = PP.register.map(r => Object.assign({ source: "register" }, r));
  return f.concat(m).sort((a, b) =>
    (b.original_date || "").localeCompare(a.original_date || "") || String(b.created_at).localeCompare(String(a.created_at)));
}


// ----------------------------------------------------------- open / close
async function openPostponed() {
  if (!WEIGH_LANG) WEIGH_LANG = myProfile.role === "admin" ? "en" : "th";
  ppSection.classList.remove("hidden");
  ppSection.innerHTML = `<p class="mg-muted">${T("กำลังโหลด…", "Loading…")}</p>`;
  PP.message = null;
  PP.editing = null;
  if (!PP.customers.length) {
    const { data } = await sb.from("pace_customers").select("name").eq("active", true).order("name");
    PP.customers = [...new Set((data || []).map(c => c.name))];
  }
  await ensurePaceUserNames();
  await ppLoad();
}

function closePostponed() {
  if (ppSection.classList.contains("hidden")) return;
  ppSection.classList.add("hidden");
  ppSection.innerHTML = "";
}

document.getElementById("switch-system-btn").addEventListener("click", closePostponed);
document.getElementById("sign-out-btn").addEventListener("click", closePostponed);

async function ppLoad() {
  const [reg, fac] = await Promise.all([
    sb.from("order_postponements").select("*")
      .order("original_date", { ascending: false }).order("created_at", { ascending: false }).limit(300),
    sb.from("weighing_postponements").select("*").order("created_at", { ascending: false }).limit(300),
  ]);
  const err = reg.error || fac.error;
  PP.missing = !!err && /postponements|schema cache|does not exist/i.test(err.message || "");
  if (err) {
    PP.register = [];
    PP.factory = [];
    PP.message = { kind: "err", text: PP.missing
      ? T("ยังไม่พบตารางข้อมูล: กรุณารัน Migration 027 ใน Supabase", "The postponement tables are missing: run Migration 027 in Supabase.")
      : T("โหลดข้อมูลไม่สำเร็จ: ", "Could not load: ") + err.message };
  } else {
    PP.register = reg.data || [];
    PP.factory = fac.data || [];
  }
  ppDraw();
}


// ----------------------------------------------------------- draw
function ppFormHtml() {
  const e = PP.editing || {};
  const v = k => escapeAttr(e[k] === null || e[k] === undefined ? "" : String(e[k]));
  const reasons = PP_REASONS.map(([k, label]) =>
    `<option value="${k}" ${e.reason === k ? "selected" : ""}>${escapeHtml(label())}</option>`).join("");
  return `<form class="mg-card pp-form" id="pp-form" novalidate>
    <h3>${PP.editing ? T("แก้ไขรายการ", "Correct this record") : T("บันทึกออเดอร์ที่ถูกเลื่อน (นอกฝ่ายผลิต)", "Record a postponed order (outside production)")}</h3>
    <p class="mg-small mg-muted">${T(
      "ฝ่ายผลิตเลื่อนในหน้าชั่งน้ำหนัก รายการนั้นขึ้นที่นี่เอง ใช้แบบฟอร์มนี้สำหรับกรณีอื่น เช่น ลูกค้าขอเลื่อน หรือเลื่อนก่อนใบงานถึงฝ่ายผลิต",
      "Postponements made by production on the weighing screen appear here by themselves. Use this form for the others — a client asking to move a delivery, or an order moved before its paper reached production.")}</p>
    <div class="pp-fields">
      <label class="pp-wide">${T("ลูกค้า", "Client")} *
        <input id="pp-customer" list="pp-customers" required value="${v("customer_name")}" autocomplete="off">
        <datalist id="pp-customers">${PP.customers.map(c => `<option value="${escapeAttr(c)}"></option>`).join("")}</datalist>
      </label>
      <label>${T("เลขที่ PO", "PO number")}<input id="pp-po" value="${v("po_number")}"></label>
      <label>${T("บริษัท", "Company")}
        <select id="pp-company">
          <option value="">—</option>
          <option value="Prosun Farm" ${e.company === "Prosun Farm" ? "selected" : ""}>Prosun Farm</option>
          <option value="Prosun Food" ${e.company === "Prosun Food" ? "selected" : ""}>Prosun Food</option>
        </select>
      </label>
      <label class="pp-wide">${T("สินค้า", "Product")}<input id="pp-product" value="${v("product")}"></label>
      <label>${T("น้ำหนัก (กก.)", "Quantity (kg)")}<input id="pp-kg" type="number" min="0" step="0.01" inputmode="decimal" value="${v("quantity_kg")}"></label>
      <label>${T("วันส่งเดิม", "Original delivery date")} *<input id="pp-original" type="date" required value="${v("original_date")}"></label>
      <label>${T("วันส่งใหม่", "New delivery date")}<input id="pp-new" type="date" value="${v("new_date")}"></label>
      <label class="pp-wide">${T("สาเหตุ", "Reason")} *
        <select id="pp-reason" data-pp="reason" required><option value="">${T("เลือกสาเหตุ", "Choose a reason")}</option>${reasons}</select>
      </label>
      <label class="pp-full">${ppNoteLabel()}<input id="pp-note" data-pp="note" value="${v("note")}"></label>
    </div>
    <div class="pp-actions">
      <button type="submit" class="ws-chip on" id="pp-save" data-pp="save">${PP.editing ? T("บันทึกการแก้ไข", "Save correction") : T("บันทึก", "Save")}</button>
      <span class="mg-small pp-hint" data-pp="hint" role="status"></span>
      ${PP.editing ? `<button type="button" class="ws-chip" data-act="cancel">${T("ยกเลิก", "Cancel")}</button>` : ""}
      <span class="mg-small mg-muted">${T("ผู้บริหารจะได้รับแจ้งทุกครั้งที่บันทึก หรือแก้วันที่และสาเหตุ", "Management is notified of each new record and of any change to its dates or reason.")}</span>
    </div>
  </form>`;
}

function ppVisible(rows) {
  if (PP.show === "factory") return rows.filter(r => r.source === "factory");
  if (PP.show === "register") return rows.filter(r => r.source !== "factory");
  if (PP.show === "open") return rows.filter(r => !r.new_date);
  return rows;
}

function ppTableHtml(all) {
  const rows = ppVisible(all);
  const isAdmin = myProfile.role === "admin";
  if (!rows.length) {
    return `<div class="mg-card mg-small mg-muted" id="pp-empty">${T("ยังไม่มีรายการ", "Nothing recorded.")}</div>`;
  }
  const body = rows.map(r => {
    const delay = ppDays(r.original_date, r.new_date);
    const src = r.source === "factory"
      ? `<span class="pp-src pp-src-factory">${T("ฝ่ายผลิต", "Production")}</span>`
      : `<span class="pp-src pp-src-register">${T("มิดเดิลออฟฟิศ", "Middle office")}</span>${r.source === "confirmed"
        ? `<br><small class="mg-muted">${T("จากน้ำหนักที่ยืนยัน", "from Confirmed weights")}</small>` : ""}`;
    return `<tr class="${r.new_date ? "" : "mg-flag"}" data-source="${r.source}">
      <td>${src}</td>
      <td>${escapeHtml(ppDate(r.original_date))}</td>
      <td>${r.new_date ? escapeHtml(ppDate(r.new_date)) : `<strong>${T("ยังไม่มีวันใหม่", "No new date yet")}</strong>`}${
        r.production ? `<br><small class="mg-muted">${T("ผลิต", "production")} ${escapeHtml(weighDayShort(r.production[0]))} → ${escapeHtml(weighDayShort(r.production[1]))}</small>` : ""}</td>
      <td class="mg-n">${delay === null ? "—" : delay}</td>
      <td>${escapeHtml(r.customer_name || "—")}</td>
      <td>${escapeHtml(r.po_number || "—")}</td>
      <td>${escapeHtml(r.product || "—")}</td>
      <td class="mg-n">${r.quantity_kg === null || r.quantity_kg === undefined ? "—" : Number(r.quantity_kg).toLocaleString("en-GB", { maximumFractionDigits: 2 })}</td>
      <td>${escapeHtml(ppReasonLabel(r.reason))}${r.note ? `<br><small class="mg-muted">${escapeHtml(r.note)}</small>` : ""}</td>
      <td>${escapeHtml(paceUserNames[r.created_by] || "—")}</td>
      <td class="pp-row-actions">${r.source === "register" ? `
        <button type="button" class="mg-go" data-act="edit" data-id="${escapeAttr(r.id)}">${T("แก้ไข", "Correct")}</button>
        ${isAdmin ? `<button type="button" class="mg-go" data-act="delete" data-id="${escapeAttr(r.id)}">${T("ลบ", "Delete")}</button>` : ""}` : ""}
      </td>
    </tr>`;
  }).join("");
  return `<div class="mg-card" id="pp-list">
    <div class="mg-table-wrap"><table class="mg-table"><thead><tr>
      <th>${T("ที่มา", "Source")}</th><th>${T("วันส่งเดิม", "Original delivery")}</th><th>${T("วันส่งใหม่", "New delivery")}</th><th class="mg-n">${T("วัน", "Days")}</th>
      <th>${T("ลูกค้า", "Client")}</th><th>PO</th><th>${T("สินค้า", "Product")}</th><th class="mg-n">kg</th>
      <th>${T("สาเหตุ", "Reason")}</th><th>${T("ผู้บันทึก", "Recorded by")}</th><th></th>
    </tr></thead><tbody>${body}</tbody></table></div>
  </div>`;
}

function ppDraw() {
  if (ppSection.classList.contains("hidden")) return;
  const all = ppRows();
  const n = {
    all: all.length,
    factory: all.filter(r => r.source === "factory").length,
    register: all.filter(r => r.source !== "factory").length,
    open: all.filter(r => !r.new_date).length,
  };
  const chip = (k, label) =>
    `<button type="button" class="ws-chip ${PP.show === k ? "on" : ""}" data-act="show" data-show="${k}" aria-pressed="${PP.show === k}">${label} (${n[k]})</button>`;
  const msg = PP.message
    ? `<div class="${PP.message.kind === "ok" ? "pp-ok" : "mg-msg"}" id="pp-msg" role="status">${escapeHtml(PP.message.text)}</div>` : "";
  ppSection.innerHTML = `
    <div class="mg-bar">
      <p class="mg-small mg-muted">${T(
        "ทุกออเดอร์ที่วันส่งถูกเลื่อน: จากฝ่ายผลิต (หน้าชั่งน้ำหนัก) จากมิดเดิลออฟฟิศในหน้าน้ำหนักที่ยืนยัน และที่บันทึกด้านล่าง ถ้าเลื่อนซ้ำจะขึ้นเป็นรายการใหม่",
        "Every order whose delivery was pushed back: by production (weighing screen), by the middle office from Confirmed weights, and recorded below. An order moved twice shows twice.")}</p>
      ${weighLangHtml()}
    </div>
    ${msg}
    <div class="ws-presets">
      ${chip("all", T("ทั้งหมด", "All"))}
      ${chip("factory", T("ฝ่ายผลิต", "Production"))}
      ${chip("register", T("มิดเดิลออฟฟิศ", "Middle office"))}
      ${chip("open", T("ยังไม่มีวันใหม่", "No new date yet"))}
    </div>
    ${ppTableHtml(all)}
    ${PP.missing ? "" : ppFormHtml()}`;
  ppSyncForm(document.getElementById("pp-form"));
}

ppSection.addEventListener("input", e => { if (e.target.dataset.pp) ppSyncForm(e.target.form); });
ppSection.addEventListener("change", e => { if (e.target.dataset.pp) ppSyncForm(e.target.form); });


// ----------------------------------------------------------- events
function ppFormError(text) {
  let m = document.getElementById("pp-form-error");
  if (!m) {
    m = document.createElement("div");
    m.id = "pp-form-error";
    m.className = "mg-msg";
    m.setAttribute("role", "alert");
    document.getElementById("pp-form").prepend(m);
  }
  m.textContent = text;
}

ppSection.addEventListener("click", async e => {
  const b = e.target.closest("[data-act]");
  if (!b) return;
  const act = b.dataset.act;
  if (act === "lang") { weighSetLang(b.dataset.lang); ppDraw(); }
  else if (act === "show") { PP.show = b.dataset.show; ppDraw(); }
  else if (act === "cancel") { PP.editing = null; PP.message = null; ppDraw(); }
  else if (act === "edit") {
    PP.editing = PP.register.find(r => r.id === b.dataset.id) || null;
    PP.message = null;
    ppDraw();
    const f = document.getElementById("pp-form");
    if (f) f.scrollIntoView({ block: "start" });
  } else if (act === "delete") {
    if (!confirm(T("ลบรายการนี้? การลบจะถูกบันทึกไว้ และผู้บริหารจะได้รับแจ้ง", "Delete this record? The deletion is kept in the activity log and management is notified."))) return;
    const { data, error } = await sb.from("order_postponements").delete().eq("id", b.dataset.id).select("id");
    PP.message = error || !data || !data.length
      ? { kind: "err", text: T("ลบไม่สำเร็จ", "Could not delete") + (error ? ": " + error.message : "") }
      : { kind: "ok", text: T("ลบแล้ว", "Deleted.") };
    await ppLoad();
  }
});

ppSection.addEventListener("submit", async e => {
  e.preventDefault();
  const val = id => document.getElementById(id).value.trim();
  const row = {
    customer_name: val("pp-customer"),
    po_number: val("pp-po") || null,
    company: val("pp-company") || null,
    product: val("pp-product") || null,
    quantity_kg: val("pp-kg") === "" ? null : Number(val("pp-kg")),
    original_date: val("pp-original"),
    new_date: val("pp-new") || null,
    reason: val("pp-reason"),
    note: val("pp-note") || null,
  };
  let problem = null;
  if (!row.customer_name) problem = T("กรุณาระบุลูกค้า", "Enter the client.");
  else if (!row.original_date) problem = T("กรุณาระบุวันส่งเดิม", "Enter the original delivery date.");
  else if (!row.reason) problem = T("กรุณาเลือกสาเหตุ", "Choose a reason.");
  else if (row.new_date && row.new_date <= row.original_date) problem = T("วันส่งใหม่ต้องหลังวันส่งเดิม", "The new date must be after the original date.");
  else if (row.reason === "other" && !row.note) problem = T("สาเหตุ “อื่น ๆ” ต้องมีหมายเหตุ", "Add a comment when the reason is Other.");
  if (problem) { ppFormError(problem); return; }
  const saveBtn = document.getElementById("pp-save");
  saveBtn.disabled = true;
  const q = PP.editing
    ? sb.from("order_postponements").update(row).eq("id", PP.editing.id)
    : sb.from("order_postponements").insert(row);
  const { error } = await q;
  if (error) {
    saveBtn.disabled = false;
    ppFormError(T("บันทึกไม่สำเร็จ: ", "Could not save: ") + error.message);
    return;
  }
  PP.message = { kind: "ok", text: PP.editing ? T("แก้ไขแล้ว", "Correction saved.") : T("บันทึกแล้ว", "Recorded.") };
  PP.editing = null;
  await ppLoad();
});
