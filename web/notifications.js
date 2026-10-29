// ============================================================================
// Notifications — the bell in the header (Migration 021, 29 Oct 2026)
// ============================================================================
// Clément (admin) is told when weighing results change after confirmation:
// a confirmed paper reopened, re-confirmed with different weights (before →
// after), a confirmed paper's PO / customer changed, or any paper deleted.
// The rows are written by database triggers only; this file shows them.
//
// Live: realtime on the notifications table (each person receives only their
// own rows — RLS), with a poll every minute as a fallback.
//
// Loaded before app.js; uses its globals at run time (sb, myProfile,
// escapeHtml, escapeAttr, switchPaceView, openSystem) and weighing.js (W).
// ============================================================================

const notifBtn   = document.getElementById("notif-btn");
const notifCount = document.getElementById("notif-count");
const notifPanel = document.getElementById("notif-panel");

const N = {
  items: [],
  loaded: false,
  open: false,
  channel: null,
  timer: null,
  seen: new Set(),     // ids already shown, so only really new ones raise a toast
};
const NOTIF_POLL_MS = window.__notifPollMs || 60000;
const NOTIF_ROLES = ["admin"];

const NOTIF_KIND = {
  weighing_reopened:    { label: "Reopened",     cls: "n-tag-amber" },
  weighing_changed:     { label: "Changed",      cls: "n-tag-red" },
  weighing_reconfirmed: { label: "Re-confirmed", cls: "n-tag-green" },
  weighing_deleted:     { label: "Deleted",      cls: "n-tag-red" },
};

function notifEnabled() { return !!myProfile && NOTIF_ROLES.includes(myProfile.role); }

async function notifStart() {
  notifStop();
  if (!notifEnabled()) return;
  N.items = []; N.loaded = false; N.seen = new Set();
  notifBtn.classList.remove("hidden");
  await notifLoad();
  try {
    N.channel = sb.channel("notifications-" + myProfile.id)
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "notifications", filter: "recipient=eq." + myProfile.id }, () => notifLoad())
      .subscribe();
  } catch (e) { N.channel = null; }
  notifSchedule();
}

function notifStop() {
  clearTimeout(N.timer);
  if (N.channel) { try { sb.removeChannel(N.channel); } catch (e) { /* ignore */ } }
  N.channel = null;
  notifBtn.classList.add("hidden");
  notifClose();
  const t = document.getElementById("notif-toast");
  if (t) t.remove();
}

function notifSchedule() {
  clearTimeout(N.timer);
  N.timer = setTimeout(async () => {
    if (!notifEnabled()) return;
    if (!document.hidden) await notifLoad();
    notifSchedule();
  }, NOTIF_POLL_MS);
}

document.addEventListener("visibilitychange", () => {
  if (!document.hidden && notifEnabled() && N.loaded) notifLoad();
});

async function notifLoad() {
  if (!notifEnabled()) return;
  const { data, error } = await sb.from("notifications").select("*")
    .eq("recipient", myProfile.id)
    .order("created_at", { ascending: false })
    .limit(50);
  if (error) {
    // Migration 021 not run yet, or offline: keep quiet, keep the last list.
    console.warn("notifications:", error.message);
    if (!N.loaded) notifBtn.classList.add("hidden");
    return;
  }
  notifBtn.classList.remove("hidden");
  const fresh = (data || []).filter((n) => !N.seen.has(n.id) && !n.read_at);
  const first = !N.loaded;
  N.items = data || [];
  N.items.forEach((n) => N.seen.add(n.id));
  N.loaded = true;
  notifBadge();
  if (N.open) notifRender();
  if (!first && fresh.length) notifToast(fresh[0], fresh.length);
}

function notifUnread() { return N.items.filter((n) => !n.read_at).length; }

function notifBadge() {
  const n = notifUnread();
  notifCount.textContent = n > 9 ? "9+" : String(n);
  notifCount.classList.toggle("hidden", !n);
  notifBtn.setAttribute("aria-label", n ? `Notifications — ${n} unread` : "Notifications");
  notifBtn.classList.toggle("notif-has", !!n);
}

function notifWhen(ts) {
  const d = new Date(ts);
  const day = d.toLocaleDateString("en-GB", { day: "numeric", month: "short", timeZone: "Asia/Bangkok" });
  const time = d.toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit", timeZone: "Asia/Bangkok" });
  const today = new Date(Date.now() + 7 * 3600e3).toISOString().slice(0, 10);
  const that = new Date(d.getTime() + 7 * 3600e3).toISOString().slice(0, 10);
  return that === today ? `today ${time}` : `${day} ${time}`;
}

function notifKg(v) { return v === null || v === undefined || v === "" ? "—" : Number(v).toFixed(2); }

// Before / after detail under each notification
function notifDetailsHtml(n) {
  const d = n.details || {};
  const parts = [];
  const lines = Array.isArray(d.lines) ? d.lines : [];
  const fields = Array.isArray(d.fields) ? d.fields : [];
  const FIELD = { po_number: "PO", customer_name: "Customer", company: "Company", delivery_date: "Delivery date" };
  if (lines.length) {
    parts.push(`<table class="n-table"><thead><tr><th>Line</th><th class="n-num">Before (kg)</th><th class="n-num">After (kg)</th></tr></thead><tbody>${
      lines.map((l) => `<tr class="n-${escapeAttr(l.change)}"><td>${escapeHtml(l.description || "line " + l.line_no)}${
        l.description_before ? ` <span class="n-muted">(was “${escapeHtml(l.description_before)}”)</span>` : ""}${
        l.change === "added" ? ' <span class="n-muted">added</span>' : l.change === "removed" ? ' <span class="n-muted">removed</span>' : ""}</td>
        <td class="n-num">${notifKg(l.before_kg)}</td><td class="n-num n-strong">${notifKg(l.after_kg)}</td></tr>`).join("")}</tbody></table>`);
  }
  if (fields.length) {
    parts.push(`<ul class="n-fields">${fields.map((f) => `<li>${escapeHtml(FIELD[f.field] || f.field)}: ${escapeHtml(f.before || "—")} → <strong>${escapeHtml(f.after || "—")}</strong></li>`).join("")}</ul>`);
  }
  const snap = n.kind === "weighing_deleted" ? d.deleted : n.kind === "weighing_reopened" ? d.confirmed : null;
  if (snap && Array.isArray(snap.lines) && snap.lines.length) {
    parts.push(`<table class="n-table"><thead><tr><th>${n.kind === "weighing_deleted" ? "Lines deleted" : "Confirmed weights"}</th><th class="n-num">Ordered</th><th class="n-num">kg</th></tr></thead><tbody>${
      snap.lines.map((l) => `<tr><td>${escapeHtml(l.description || "line " + l.line_no)}</td><td class="n-num">${escapeHtml(l.ordered_text || "")}</td><td class="n-num n-strong">${notifKg(l.actual_kg)}</td></tr>`).join("")}</tbody></table>`);
  }
  if (snap) {
    const bits = [snap.company, snap.delivery_date ? "delivery " + snap.delivery_date : "", "weighed " + snap.work_date].filter(Boolean);
    parts.push(`<p class="n-muted n-small">${escapeHtml(bits.join(" · "))}</p>`);
  }
  return parts.join("");
}

function notifRender() {
  const unread = notifUnread();
  notifPanel.innerHTML = `
    <div class="n-head">
      <strong>Notifications</strong>
      <span class="n-head-acts">
        ${unread ? `<button type="button" class="btn-link" data-n="read-all">Mark all as read</button>` : ""}
        <button type="button" class="n-close" data-n="close" aria-label="Close">×</button>
      </span>
    </div>
    <p class="n-intro">Weighing changes after confirmation, and deleted papers.</p>
    ${N.items.length ? `<ul class="n-list">${N.items.map((n) => {
      const k = NOTIF_KIND[n.kind] || { label: "Notice", cls: "n-tag-amber" };
      const detail = notifDetailsHtml(n);
      return `<li class="n-item${n.read_at ? "" : " n-unread"}" data-id="${escapeAttr(n.id)}">
        <div class="n-top"><span class="n-tag ${k.cls}">${k.label}</span><span class="n-when">${escapeHtml(notifWhen(n.created_at))}</span></div>
        <div class="n-title">${escapeHtml(n.title)}</div>
        ${n.body ? `<div class="n-body">${escapeHtml(n.body)}</div>` : ""}
        <div class="n-meta">by ${escapeHtml(n.actor_name || "the system")}</div>
        <div class="n-acts">
          ${detail ? `<details><summary>Details</summary>${detail}</details>` : ""}
          ${n.paper_id && n.kind !== "weighing_deleted" ? `<button type="button" class="btn-link" data-n="open" data-id="${escapeAttr(n.id)}">Open paper ›</button>` : ""}
          ${n.read_at ? "" : `<button type="button" class="btn-link n-mark" data-n="read" data-id="${escapeAttr(n.id)}">Mark as read</button>`}
        </div>
      </li>`;
    }).join("")}</ul>`
    : `<p class="n-empty">Nothing yet. You are told here when a confirmed weight is reopened, changed or deleted.</p>`}`;
}

function notifOpenPanel() {
  N.open = true;
  notifRender();
  notifPanel.classList.remove("hidden");
  notifBtn.setAttribute("aria-expanded", "true");
  const t = document.getElementById("notif-toast");
  if (t) t.remove();
}

function notifClose() {
  N.open = false;
  notifPanel.classList.add("hidden");
  notifBtn.setAttribute("aria-expanded", "false");
}

notifBtn.addEventListener("click", (e) => {
  e.stopPropagation();
  if (N.open) notifClose(); else { notifOpenPanel(); notifLoad(); }
});

document.addEventListener("click", (e) => {
  if (N.open && !notifPanel.contains(e.target) && !notifBtn.contains(e.target)) notifClose();
});
document.addEventListener("keydown", (e) => { if (e.key === "Escape" && N.open) { notifClose(); notifBtn.focus(); } });

notifPanel.addEventListener("click", async (e) => {
  const el = e.target.closest("[data-n]");
  if (!el) return;
  const act = el.dataset.n;
  if (act === "close") { notifClose(); return; }
  if (act === "read-all") { await notifMarkRead(N.items.filter((n) => !n.read_at).map((n) => n.id)); return; }
  if (act === "read") { await notifMarkRead([el.dataset.id]); return; }
  if (act === "open") {
    const n = N.items.find((x) => x.id === el.dataset.id);
    if (!n) return;
    await notifMarkRead([n.id]);
    notifClose();
    await notifOpenPaper(n);
  }
});

async function notifMarkRead(ids) {
  if (!ids.length) return;
  const now = new Date().toISOString();
  N.items.forEach((n) => { if (ids.includes(n.id)) n.read_at = now; });
  notifBadge();
  if (N.open) notifRender();
  const { error } = await sb.from("notifications").update({ read_at: now }).in("id", ids);
  if (error) console.warn("notifications: mark read failed:", error.message);
}

// Opens the paper on the weighing screen, on its weighing day.
async function notifOpenPaper(n) {
  const chooser = document.getElementById("system-chooser");
  if (chooser && !chooser.classList.contains("hidden")) {
    chooser.classList.add("hidden");
    document.querySelector(".toolbar").classList.remove("hidden");
    document.querySelector(".page-footer").classList.remove("hidden");
  }
  W.pendingOpen = { date: n.work_date, id: n.paper_id };
  await switchPaceView("weighing");
}

function notifToast(n, count) {
  const old = document.getElementById("notif-toast");
  if (old) old.remove();
  const t = document.createElement("button");
  t.type = "button";
  t.id = "notif-toast";
  t.className = "notif-toast";
  t.setAttribute("role", "status");
  t.innerHTML = `<span class="notif-toast-k">${count > 1 ? count + " new notifications" : "New notification"}</span><span>${escapeHtml(n.title)}</span>`;
  t.addEventListener("click", () => { t.remove(); notifOpenPanel(); });
  document.body.appendChild(t);
  setTimeout(() => { if (t.isConnected) t.remove(); }, 8000);
}

document.getElementById("sign-out-btn").addEventListener("click", notifStop);
