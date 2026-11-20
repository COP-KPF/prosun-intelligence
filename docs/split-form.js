// ============================================================================
// Postpone a product — one form for production and the middle office
// (Migrations 040, 041)
// ============================================================================
// Middle office › Confirmed weights (040, 19 Nov 2026) and production's
// Weighing screen (041, 20 Nov 2026) postpone one or more products of a
// working paper — the whole line or part of its quantity. The products move
// to a new working paper, "part 2" (3, 4 …) of the same PO, with its own
// delivery and invoice; the rest of the order stays on the paper.
//
// What happened to the products (Clément, 19–20 Nov):
//   - paper not confirmed yet (production is weighing it): back to
//     production on a new day — the only choice;
//   - confirmed paper: the team chooses — produced, delivered later (their
//     weights move with them), or not produced, back to production.
//
// The whole order is still postponed with the existing buttons (027 on the
// weighing screen, 028 in Confirmed weights).
//
// One form open at a time (SF.form). Each screen draws it inside its own
// layout with sfFormHtml(), passes its input events to sfField() and saves
// with sfSave(). Loaded after weighing.js (T, weighFmt, weighUnit,
// weighShortDate, weighBangkokToday, PP_REASONS, ppReasonOk, ppNoteLabel).
// ============================================================================

const SF = { form: null };

function sfAddDays(iso, n) {
  const d = new Date(iso + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}
function sfQty(q, u) {
  return `${Number(q).toLocaleString("en-GB", { maximumFractionDigits: 3 })} ${u ? weighUnit(u) : ""}`.trim();
}

// paper: { id, status, work_date, delivery_date, po_number, customer_name }
// lines: [{ id, description, ordered_text, ordered_qty, ordered_unit, actual_kg }]
// where: "weighing" (production) or "weights" (Confirmed weights)
function sfOpen(where, paper, lines) {
  const confirmed = paper.status === "confirmed";
  const f = {
    where, paper: Object.assign({}, paper), lines: lines.map((l) => Object.assign({}, l)),
    confirmed, mode: confirmed ? "" : "production", work: "", date: "", reason: "", note: "",
    sel: {}, error: null, busy: false,
  };
  // Production, paper still being weighed: tomorrow by default, the delivery
  // moved by as many days (as the whole-order Postpone does).
  if (!confirmed && where === "weighing") {
    const today = weighBangkokToday();
    const base = paper.work_date > today ? paper.work_date : today;
    f.work = sfAddDays(base, 1);
    const cur = paper.delivery_date || paper.work_date;
    const shift = Math.round((new Date(f.work) - new Date(paper.work_date)) / 86400000);
    let del = sfAddDays(cur, shift);
    if (del < f.work) del = f.work;
    f.date = del;
  }
  SF.form = f;
}
function sfIsOpen(paperId) { return !!(SF.form && SF.form.paper.id === paperId); }
function sfClose() { SF.form = null; }

// A paper can have a product postponed if it has two products or more, or one
// with an ordered quantity (part of it can move).
function sfCanSplit(lines) {
  return (lines || []).length > 1 || (lines || []).some((l) => Number(l.ordered_qty) > 0);
}

// ---------------------------------------------------------------- the form
function sfFormHtml() {
  const f = SF.form;
  if (!f) return "";
  const p = f.paper;
  const current = p.delivery_date || p.work_date;
  const today = weighBangkokToday();
  const minDate = sfAddDays(current, 1) > today ? sfAddDays(current, 1) : today;
  const label = [p.po_number ? "PO " + p.po_number : "", p.customer_name || ""].filter(Boolean).join(" · ");
  const later = f.mode === "later";
  const v = sfCheck();
  const rowsHtml = f.lines.map((l) => {
    const s = f.sel[l.id] || {};
    const hasQty = Number(l.ordered_qty) > 0;
    const partial = s.on && hasQty && s.qty !== "" && s.qty !== undefined && Number(s.qty) < Number(l.ordered_qty);
    const prop = partial && l.actual_kg !== null && l.actual_kg !== undefined && Number(s.qty) > 0
      ? Math.round(Number(l.actual_kg) * Number(s.qty) / Number(l.ordered_qty) * 100) / 100 : null;
    return `<tr class="${s.on ? "sf-on" : ""}">
      <td><input type="checkbox" id="sf-on-${escapeAttr(l.id)}" data-sf-line="${escapeAttr(l.id)}" data-sf="on"${s.on ? " checked" : ""}></td>
      <td class="sf-desc"><label for="sf-on-${escapeAttr(l.id)}">${escapeHtml(l.description || "")}</label></td>
      <td class="w-num">${escapeHtml(l.ordered_text || "")}</td>
      <td class="w-num">${l.actual_kg === null || l.actual_kg === undefined ? "—" : weighFmt(l.actual_kg)}</td>
      <td class="w-num">${hasQty ? `<input type="number" class="sf-num" min="0" step="any" inputmode="decimal" data-sf-line="${escapeAttr(l.id)}" data-sf="qty"
          value="${escapeAttr(s.qty === undefined ? "" : String(s.qty))}" placeholder="${escapeAttr(weighFmt(l.ordered_qty))}"${s.on ? "" : " disabled"}
          aria-label="${escapeAttr(T("จำนวนที่เลื่อน ", "Quantity to move ") + (l.description || ""))}"> ${escapeHtml(weighUnit(l.ordered_unit) || "")}`
        : `<span class="w-small w-muted">${T("ทั้งรายการ", "whole line")}</span>`}</td>
      ${f.confirmed ? `<td class="w-num">${later && partial ? `<input type="number" class="sf-num" min="0" step="0.01" inputmode="decimal" data-sf-line="${escapeAttr(l.id)}" data-sf="kg"
          value="${escapeAttr(s.kg === undefined ? "" : String(s.kg))}" placeholder="${prop === null ? "" : escapeAttr(String(prop))}"
          aria-label="${escapeAttr(T("กก. ที่เลื่อน ", "Kg moved ") + (l.description || ""))}"> kg` : `<span class="w-small w-muted">${s.on && !partial && later ? T("ทั้งหมด", "all") : ""}</span>`}</td>` : ""}
    </tr>`;
  }).join("");

  const modeHtml = f.confirmed ? `
      <fieldset class="sf-mode">
        <legend>${T("สินค้านี้", "These products are")} *</legend>
        <label><input type="radio" name="sf-mode" value="later" data-sf="mode"${later ? " checked" : ""}>
          ${T("ผลิตแล้ว — ส่งทีหลัง (น้ำหนักที่ยืนยันแล้วย้ายไปด้วย)", "Produced — delivered later (their confirmed weights move with them)")}</label>
        <label><input type="radio" name="sf-mode" value="production" data-sf="mode"${f.mode === "production" ? " checked" : ""}>
          ${T("ยังไม่ได้ผลิต — กลับไปผลิตใหม่ (ใบงานใหม่รอผลิตในวันที่เลือก)", "Not produced — back to production (a new paper waits for production on the chosen day)")}</label>
      </fieldset>`
    : `<p class="w-note w-note-violet sf-only">${T(
        "ใบนี้ยังไม่ได้ยืนยันน้ำหนัก: สินค้าที่เลือกจะกลับไปผลิตใหม่ในวันที่เลือก เป็นใบงาน “ส่วนที่ 2” ที่รอผลิต",
        "The weights of this paper are not confirmed yet: the chosen products go back to production on the chosen day, as a “part 2” paper waiting for production.")}</p>`;

  return `<form class="w-pp-form sf-form" id="sf-form" novalidate>
      <h3>${T("เลื่อนสินค้า", "Postpone a product")} — ${escapeHtml(label)}</h3>
      <p class="w-small w-muted">${T(
        `ตอนนี้ส่ง ${escapeHtml(weighShortDate(current))} · เลือกสินค้าที่จะเลื่อน (ทั้งรายการ หรือใส่จำนวนบางส่วน) สินค้าที่เลือกจะเป็นใบงานใหม่ “ส่วนที่ 2” ของ PO เดียวกัน ส่งและออกใบแจ้งหนี้แยก ที่เหลืออยู่ในใบงานนี้`,
        `Delivery now ${escapeHtml(weighShortDate(current))} · choose the products to move (whole line, or type part of the quantity). They become a new working paper, “part 2” of the same PO, delivered and invoiced on its own; the rest stays on this paper.`)}</p>
      ${f.error ? `<div class="w-msg w-msg-error" role="alert" id="sf-error">${escapeHtml(f.error)}</div>` : ""}
      <div class="table-scroll"><table class="w-table sf-table">
        <thead><tr><th><span class="pp-sr">${T("เลือก", "Choose")}</span></th><th>${T("สินค้า", "Product")}</th><th class="w-num">${T("สั่ง", "Ordered")}</th>
          <th class="w-num">${f.confirmed ? T("ชั่งจริง (kg)", "Actual (kg)") : T("ชั่งแล้ว (kg)", "Weighed so far (kg)")}</th><th class="w-num">${T("จำนวนที่เลื่อน", "Quantity to move")}</th>
          ${f.confirmed ? `<th class="w-num">${T("กก. ที่เลื่อน", "Kg moved")}</th>` : ""}</tr></thead>
        <tbody>${rowsHtml}</tbody></table></div>
      ${modeHtml}
      <div class="w-pp-fields">
        ${f.mode === "production" ? `<label>${T("วันผลิตใหม่", "New production day")} *
          <input type="date" id="sf-work" min="${escapeAttr(today)}" value="${escapeAttr(f.work || "")}" required></label>` : ""}
        <label>${T("วันส่งใหม่", "New delivery date")} *
          <input type="date" id="sf-date" min="${escapeAttr(minDate)}" value="${escapeAttr(f.date || "")}" required></label>
        <label class="w-pp-wide">${T("สาเหตุ", "Reason")} *
          <select id="sf-reason" required>
            <option value="">${T("เลือกสาเหตุ", "Choose a reason")}</option>
            ${PP_REASONS.map(([k, lab]) => `<option value="${k}"${f.reason === k ? " selected" : ""}>${escapeHtml(lab())}</option>`).join("")}
          </select></label>
        <label class="w-pp-full">${ppNoteLabel()}
          <input type="text" id="sf-note" value="${escapeAttr(f.note || "")}" maxlength="300"></label>
      </div>
      <div class="w-pp-actions">
        <button type="submit" class="w-btn w-btn-violet" id="sf-save"${v.ok && !f.busy ? "" : " disabled"}>${T("เลื่อนสินค้า", "Postpone the products")}</button>
        <button type="button" class="w-btn w-btn-outline" data-sf-act="cancel">${T("ยกเลิก", "Cancel")}</button>
        <span class="w-small w-pp-hint" id="sf-hint" role="status">${escapeHtml(v.ok ? v.summary : v.missing)}</span>
      </div>
    </form>`;
}

// What is still missing (shown next to the button), or a summary when ready.
function sfCheck() {
  const f = SF.form;
  if (!f) return { ok: false, missing: "" };
  const p = f.paper;
  const chosen = f.lines.filter((l) => (f.sel[l.id] || {}).on);
  const current = p.delivery_date || p.work_date;
  const today = weighBangkokToday();
  let missing = null;
  let whole = 0;
  for (const l of chosen) {
    const s = f.sel[l.id];
    const q = s.qty === "" || s.qty === undefined ? null : Number(s.qty);
    if (q !== null && !(q > 0)) { missing = T(`ใส่จำนวนที่มากกว่า 0 (${l.description})`, `Type a quantity above 0 (${l.description})`); break; }
    if (q === null || q >= Number(l.ordered_qty)) whole++;
    else if (f.mode === "later" && s.kg !== "" && s.kg !== undefined && !(Number(s.kg) > 0 && Number(s.kg) < Number(l.actual_kg))) {
      missing = T(`กก. ที่เลื่อนต้องน้อยกว่า ${weighFmt(l.actual_kg)} (${l.description})`, `Kg moved must be less than ${weighFmt(l.actual_kg)} (${l.description})`); break;
    }
  }
  const whole_btn = f.where === "weighing" ? T("“เลื่อนผลิต”", "“Postpone”") : T("“เลื่อนส่ง”", "“Postpone”");
  if (!missing && !chosen.length) missing = T("เลือกสินค้าที่จะเลื่อน", "Choose the products to move");
  else if (!missing && whole >= f.lines.length) missing = T(`เลือกทุกสินค้า: ใช้ปุ่ม ${whole_btn} เพื่อเลื่อนทั้งออเดอร์`, `Every product is chosen: use ${whole_btn} for the whole order`);
  else if (!missing && !f.mode) missing = T("เลือก: ผลิตแล้ว หรือ ยังไม่ได้ผลิต", "Choose: produced, or not produced");
  else if (!missing && f.mode === "production" && !f.work) missing = T("เลือกวันผลิตใหม่", "Choose the new production day");
  else if (!missing && f.mode === "production" && f.work < today) missing = T("วันผลิตต้องเป็นวันนี้หรือหลังจากนี้", "The production day must be today or later");
  else if (!missing && f.mode === "production" && f.work === p.work_date) missing = T("เลือกวันผลิตอื่น", "Choose another production day");
  else if (!missing && !f.date) missing = T("เลือกวันส่งใหม่", "Choose the new delivery date");
  else if (!missing && current && f.date <= current) missing = T("วันส่งใหม่ต้องหลังวันส่งเดิม", "The new delivery date must be after the current one");
  else if (!missing && f.date < today) missing = T("วันส่งใหม่ต้องเป็นวันนี้หรือหลังจากนี้", "The new delivery date must be today or later");
  else if (!missing && f.mode === "production" && f.work > f.date) missing = T("วันส่งต้องไม่ก่อนวันผลิต", "The delivery date must be on or after the production day");
  else if (!missing && !ppReasonOk(f.reason, f.note)) missing = !f.reason ? T("เลือกสาเหตุ", "Choose a reason") : T("สาเหตุ “อื่น ๆ” ต้องมีหมายเหตุ", "Add a comment when the reason is Other");
  if (missing) return { ok: false, missing };
  const n = chosen.length;
  return { ok: true, summary: T(
    `${n} สินค้า → ส่วนที่ 2 · ส่ง ${weighShortDate(f.date)}`,
    `${n} product${n === 1 ? "" : "s"} → part 2 · delivery ${weighShortDate(f.date)}`) };
}

// An input of the form changed. Keeps the values; calls redraw() only when
// the layout changes (choice, a product ticked, part of a quantity), and
// gives the focus back. Returns true when the event belonged to the form.
function sfField(t, redraw) {
  const f = SF.form;
  if (!f || !t || !t.closest || !t.closest("#sf-form")) return false;
  let again = false;
  if (t.dataset.sf === "mode") { f.mode = t.value; again = true; }
  else if (t.dataset.sfLine) {
    const s = f.sel[t.dataset.sfLine] = f.sel[t.dataset.sfLine] || {};
    if (t.dataset.sf === "on") { s.on = t.checked; again = true; }
    else if (t.dataset.sf === "qty") {
      const l = f.lines.find((x) => x.id === t.dataset.sfLine);
      const part = (v) => v !== undefined && v !== "" && l && Number(v) < Number(l.ordered_qty);
      const was = part(s.qty);
      s.qty = t.value;
      again = f.mode === "later" && was !== part(s.qty);
    } else if (t.dataset.sf === "kg") s.kg = t.value;
  }
  else if (t.id === "sf-work") f.work = t.value;
  else if (t.id === "sf-date") f.date = t.value;
  else if (t.id === "sf-reason") f.reason = t.value;
  else if (t.id === "sf-note") f.note = t.value.trim();
  f.error = null;
  if (again) {
    const id = t.id, line = t.dataset.sfLine, which = t.dataset.sf;
    redraw();
    const el = id ? document.getElementById(id)
      : document.querySelector(`#sf-form [data-sf-line="${CSS.escape(line || "")}"][data-sf="${which}"]`);
    if (el) el.focus();
  } else {
    const v = sfCheck();
    const btn = document.getElementById("sf-save");
    const hint = document.getElementById("sf-hint");
    if (btn) btn.disabled = !v.ok || f.busy;
    if (hint) hint.textContent = v.ok ? v.summary : v.missing;
  }
  return true;
}

// Saves. Returns { ok, text } — the message for the screen — or { ok: false }
// with f.error set (the screen redraws the form).
async function sfSave(redraw) {
  const f = SF.form;
  if (!f || f.busy) return { ok: false };
  const v = sfCheck();
  if (!v.ok) { f.error = v.missing; redraw(); return { ok: false }; }
  const moves = f.lines.filter((l) => (f.sel[l.id] || {}).on).map((l) => {
    const s = f.sel[l.id];
    const q = s.qty === "" || s.qty === undefined ? null : Number(s.qty);
    const partial = q !== null && q < Number(l.ordered_qty);
    return { line_id: l.id, qty: partial ? q : null,
             actual_kg: partial && f.mode === "later" && s.kg !== "" && s.kg !== undefined ? Number(s.kg) : null };
  });
  f.busy = true; f.error = null;
  redraw();
  const { data, error } = await sb.rpc("weighing_postpone_lines", {
    p_paper: f.paper.id, p_moves: moves, p_mode: f.mode, p_delivery_date: f.date,
    p_work_date: f.mode === "production" ? f.work : null, p_reason: f.reason, p_note: f.note || null, p_from: f.where });
  f.busy = false;
  if (error) {
    f.error = /weighing_postpone_lines|schema cache|does not exist|Could not find/i.test(error.message || "")
      ? T("ยังเลื่อนสินค้าไม่ได้: กรุณารัน Migration 041 ใน Supabase", "Postponing a product is not available yet: run Migration 041 in Supabase.")
      : T("เลื่อนไม่สำเร็จ: ", "Could not postpone: ") + error.message;
    redraw();
    return { ok: false };
  }
  const p = f.paper;
  const label = p.po_number ? "PO " + p.po_number : p.customer_name || T("ใบงาน", "The paper");
  const part = data && data.part ? data.part : 2;
  SF.form = null;
  return { ok: true, data, text: f.mode === "later"
    ? T(`${label}: สินค้าที่เลือกเป็นส่วนที่ ${part} ส่งวันที่ ${weighShortDate(f.date)} — ที่เหลือยังอยู่ในใบงานนี้`,
        `${label}: the chosen products are now part ${part}, delivered ${weighShortDate(f.date)} — the rest stays on this paper`)
    : T(`${label}: สินค้าที่เลือกกลับไปผลิตวันที่ ${weighShortDate(f.work)} เป็นส่วนที่ ${part} ส่งวันที่ ${weighShortDate(f.date)}`,
        `${label}: the chosen products go back to production on ${weighShortDate(f.work)} as part ${part}, delivered ${weighShortDate(f.date)}`) };
}

// ---------------------------------------------------------------- tags
// From weighing_split_marks (040): "Part 2" next to a part's PO …
function sfPartTag(mark) {
  if (!mark || mark.part < 2) return "";
  return `<span class="ws-part" title="${escapeAttr(T("ส่วนหนึ่งของออเดอร์ที่ถูกแยกส่ง", "A part of an order delivered in several times"))}">${T("ส่วนที่", "Part")} ${mark.part}</span>`;
}

// … and, on the original order, each part and what it holds.
function sfFamilyHtml(mark, paperId) {
  if (!mark || !mark.family || !mark.family.length) return "";
  const items = mark.family.filter((f) => f.paper_id !== paperId).map((f) => {
    const what = (f.lines || []).map((l) => `${l.description} ${l.whole ? (l.ordered_text || sfQty(l.qty, l.unit))
      : sfQty(l.qty, l.unit) + T(" จาก ", " of ") + (l.ordered_text || sfQty(l.of_qty, l.unit))}`).join(", ");
    const how = f.mode === "production" ? T("กลับไปผลิต", "back to production") : T("ผลิตแล้ว ส่งทีหลัง", "produced, delivered later");
    return `<span class="ws-split-item">✂ ${T("ส่วนที่", "Part")} ${f.part} → ${escapeHtml(weighShortDate(f.delivery_date))}${what ? ": " + escapeHtml(what) : ""} · ${how}</span>`;
  });
  if (mark.part > 1) items.unshift(`<span class="ws-split-item">${T("แยกจากออเดอร์เดิม (ส่วนที่ 1)", "Split from the original order (part 1)")}</span>`);
  return items.join("");
}

// The parts of the papers on a screen (quietly empty before Migration 040).
async function sfLoadMarks(paperIds) {
  const out = {};
  const ids = [...new Set(paperIds || [])];
  if (!ids.length) return out;
  const { data, error } = await sb.rpc("weighing_split_marks", { p_papers: ids });
  if (!error) (data || []).forEach((m) => { out[m.paper_id] = m; });
  return out;
}
