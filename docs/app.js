// ============================================================================
// Klong Phai Farm CRM — front-end logic.
//
// There is no separate backend server for this app. Every read/write below
// goes straight from the browser to Supabase, authenticated as whoever is
// logged in. What that person is allowed to see or change is enforced by the
// Row Level Security policies in sql/schema.sql, on the database side — not
// by anything in this file. Treat this file as UI convenience only, never as
// the security boundary.
// ============================================================================

const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

const STAGE_LABEL = {
  lead: "Lead", qualified: "Qualified", proposal: "Proposal",
  won: "Won", at_risk: "At risk", dormant: "Dormant", lost: "Lost",
};

let myProfile = null;     // { id, full_name, role }
let editingId = null;     // client id currently open in the modal, or null = "new"
let directorView = "mine"; // director only: "mine" (own pipeline) or "leads" (team leads feed)
let adminView = "all";     // admin only: "all" (full record list) or "summary" (per-rep achievement)

// ---------------------------------------------------------------- elements
const loginScreen  = document.getElementById("login-screen");
const appScreen    = document.getElementById("app-screen");
const loginForm    = document.getElementById("login-form");
const loginError   = document.getElementById("login-error");
const mfaBlock     = document.getElementById("mfa-block");
const directorTabs = document.getElementById("director-tabs");
const tabMineBtn   = document.getElementById("tab-mine");
const tabLeadsBtn  = document.getElementById("tab-leads");
const adminTabs    = document.getElementById("admin-tabs");
const tabAllBtn    = document.getElementById("tab-all");
const tabSummaryBtn = document.getElementById("tab-summary");
const clientsTable = document.getElementById("clients-table");
const summaryTable = document.getElementById("summary-table");
const pipelineStats = document.getElementById("pipeline-stats");

init();

async function init() {
  const { data: { session } } = await sb.auth.getSession();
  if (session) {
    await onSignedIn();
  } else {
    showLogin();
  }
}

// --------------------------------------------------------------- auth flow
loginForm.addEventListener("submit", async (e) => {
  e.preventDefault();
  loginError.textContent = "";
  const email = document.getElementById("email").value.trim();
  const password = document.getElementById("password").value;

  const { error } = await sb.auth.signInWithPassword({ email, password });
  if (error) {
    loginError.textContent = error.message;
    return;
  }

  // If this account has an authenticator app enrolled, Supabase will report
  // that the session is stuck at "aal1" and needs a TOTP code to reach
  // "aal2" before it's fully authenticated.
  const { data: level } = await sb.auth.mfa.getAuthenticatorAssuranceLevel();
  if (level.currentLevel === "aal1" && level.nextLevel === "aal2") {
    const { data: factors } = await sb.auth.mfa.listFactors();
    const totp = factors.totp[0];
    mfaBlock.classList.remove("hidden");
    const code = prompt("Enter your 6-digit authenticator code:");
    const { data: challenge, error: chErr } = await sb.auth.mfa.challenge({ factorId: totp.id });
    if (chErr) { loginError.textContent = chErr.message; return; }
    const { error: verErr } = await sb.auth.mfa.verify({
      factorId: totp.id, challengeId: challenge.id, code,
    });
    if (verErr) { loginError.textContent = "Wrong code — try again."; return; }
  }

  await onSignedIn();
});

document.getElementById("sign-out-btn").addEventListener("click", async () => {
  await sb.auth.signOut();
  myProfile = null;
  showLogin();
});

function showLogin() {
  appScreen.classList.add("hidden");
  loginScreen.classList.remove("hidden");
}

async function onSignedIn() {
  const { data: { user } } = await sb.auth.getUser();
  const { data: profile, error } = await sb
    .from("profiles")
    .select("id, full_name, role")
    .eq("id", user.id)
    .single();

  if (error || !profile) {
    loginError.textContent = "Signed in, but no profile row exists for this account yet — ask your admin.";
    await sb.auth.signOut();
    return;
  }

  myProfile = profile;
  loginScreen.classList.add("hidden");
  appScreen.classList.remove("hidden");
  document.getElementById("who-name").textContent = myProfile.full_name;
  document.getElementById("who-role").textContent = myProfile.role;

  setupForRole();
  await loadClients();
}

// ------------------------------------------------------ role-specific setup
function setupForRole() {
  const title = document.getElementById("list-title");
  const note  = document.getElementById("role-note");
  const newBtn = document.getElementById("new-client-btn");
  const assignedWrap = document.getElementById("assigned-to-wrap");

  // Reset director/admin-only UI; re-enabled below only for that role.
  directorTabs.classList.add("hidden");
  adminTabs.classList.add("hidden");
  clientsTable.classList.remove("hidden");
  summaryTable.classList.add("hidden");
  pipelineStats.classList.add("hidden");
  newBtn.classList.remove("hidden");

  if (myProfile.role === "admin") {
    // Admin gets two views: the full record list (as before), and a
    // per-sales-rep achievement summary — counts by stage plus won/open
    // pipeline value. Admin-only, same as the CEO-level visibility already
    // required for this role.
    adminTabs.classList.remove("hidden");
    adminView = "all";
    tabAllBtn.classList.add("active");
    tabSummaryBtn.classList.remove("active");
    title.textContent = "All clients & deals";
    note.textContent = "You see every record. Deal values and assignment are visible and editable.";
    assignedWrap.classList.remove("hidden");
    populateAssignedToDropdown();
  } else if (myProfile.role === "director") {
    // Director gets two views: their own personal pipeline (targets/visits,
    // just like a sales rep), and a read-only feed of new leads across the
    // whole team. Default to their own pipeline.
    directorTabs.classList.remove("hidden");
    directorView = "mine";
    tabMineBtn.classList.add("active");
    tabLeadsBtn.classList.remove("active");
    updateDirectorHeader();
  } else {
    title.textContent = "Your pipeline";
    note.textContent = "You only see clients assigned to you.";
  }
}

function updateDirectorHeader() {
  const title = document.getElementById("list-title");
  const note  = document.getElementById("role-note");
  const newBtn = document.getElementById("new-client-btn");

  if (directorView === "mine") {
    title.textContent = "My pipeline";
    note.textContent = "Your own clients and deals, just like a sales rep — only you can see this.";
    newBtn.classList.remove("hidden");
  } else {
    title.textContent = "Team leads";
    note.textContent = "New leads across the whole team — read-only. Not deal values, not other reps' pipelines.";
    newBtn.classList.add("hidden"); // read-only feed, nothing to create here
  }
}

tabMineBtn.addEventListener("click", () => switchDirectorView("mine"));
tabLeadsBtn.addEventListener("click", () => switchDirectorView("leads"));

async function switchDirectorView(view) {
  directorView = view;
  tabMineBtn.classList.toggle("active", view === "mine");
  tabLeadsBtn.classList.toggle("active", view === "leads");
  updateDirectorHeader();
  await loadClients();
}

tabAllBtn.addEventListener("click", () => switchAdminView("all"));
tabSummaryBtn.addEventListener("click", () => switchAdminView("summary"));

async function switchAdminView(view) {
  adminView = view;
  tabAllBtn.classList.toggle("active", view === "all");
  tabSummaryBtn.classList.toggle("active", view === "summary");
  clientsTable.classList.toggle("hidden", view !== "all");
  summaryTable.classList.toggle("hidden", view !== "summary");
  document.getElementById("new-client-btn").classList.toggle("hidden", view !== "all");
  document.getElementById("list-title").textContent =
    view === "all" ? "All clients & deals" : "Team summary";
  document.getElementById("role-note").textContent = view === "all"
    ? "You see every record. Deal values and assignment are visible and editable."
    : "Totals per sales rep — stage breakdown, won value, and open pipeline value. Only you can see this.";

  if (view === "summary") {
    await loadSummary();
  } else {
    await loadClients();
  }
}

// --------------------------------------------------------- personal stats
// Win rate is deliberately based only on "won" vs "at_risk" — the accounts
// actually being tracked month to month — not leads/qualified/proposal/
// dormant/lost, which aren't part of "did they order this month or not".
function winRate(won, atRisk) {
  const tracked = won + atRisk;
  return tracked > 0 ? Math.round((won / tracked) * 100) : null;
}

function renderPipelineStats(rows) {
  const won = rows.filter(c => c.stage === "won").length;
  const atRisk = rows.filter(c => c.stage === "at_risk").length;
  const atRiskValue = rows
    .filter(c => c.stage === "at_risk")
    .reduce((sum, c) => sum + (Number(c.deal_value) || 0), 0);
  const rate = winRate(won, atRisk);

  const rateClass = rate === null ? "" : rate >= 50 ? "win-rate-good" : "win-rate-bad";
  const rateText = rate === null ? "—" : `${rate}%`;

  pipelineStats.innerHTML = `
    <span class="stat"><strong>${won}</strong>won this month</span>
    <span class="stat"><strong>${atRisk}</strong>at risk (haven't ordered yet)</span>
    ${atRisk > 0 ? `<span class="stat"><strong>${atRiskValue.toLocaleString()} ฿</strong>sitting at risk</span>` : ""}
    <span class="stat ${rateClass}"><strong>${rateText}</strong>win rate</span>
  `;
}

// ------------------------------------------------------------ team summary
async function loadSummary() {
  // Reuses the same "admin full access" RLS policy that already lets admin
  // read every clients/profiles row — no new database permissions needed.
  const [{ data: clients, error: cErr }, { data: profiles, error: pErr }] = await Promise.all([
    sb.from("clients").select("assigned_to, stage, deal_value"),
    sb.from("profiles").select("id, full_name, role").order("full_name"),
  ]);

  const head = document.getElementById("summary-head");
  const body = document.getElementById("summary-body");
  const err = cErr || pErr;

  if (err) {
    body.innerHTML = `<tr><td colspan="10">Couldn't load summary: ${err.message}</td></tr>`;
    return;
  }

  const OPEN_STAGES = ["lead", "qualified", "proposal", "at_risk", "dormant"];

  const byRep = {};
  (profiles || []).forEach(p => {
    if (p.role === "admin") return; // admin has no personal pipeline to summarize
    byRep[p.id] = {
      name: p.full_name, role: p.role,
      lead: 0, qualified: 0, proposal: 0, won: 0, at_risk: 0, dormant: 0, lost: 0,
      wonValue: 0, openValue: 0, atRiskValue: 0,
    };
  });

  (clients || []).forEach(c => {
    const rep = byRep[c.assigned_to];
    if (!rep) return; // unassigned row, or assigned to an admin — not shown per-rep
    rep[c.stage] = (rep[c.stage] || 0) + 1;
    const value = Number(c.deal_value) || 0;
    if (c.stage === "won") rep.wonValue += value;
    else if (OPEN_STAGES.includes(c.stage)) rep.openValue += value;
    if (c.stage === "at_risk") rep.atRiskValue += value;
  });

  head.innerHTML = `<tr>
      <th>Sales rep</th><th>Leads</th><th>Qualified</th><th>Proposal</th>
      <th>Won</th><th>At risk</th><th>Dormant</th><th>Lost</th>
      <th>Win rate</th>
      <th>Won value</th><th>At risk value</th><th>Open pipeline value</th>
    </tr>`;

  const rows = Object.values(byRep);

  if (!rows.length) {
    body.innerHTML = `<tr><td colspan="11">No sales reps or director yet.</td></tr>`;
    return;
  }

  body.innerHTML = rows.map(r => {
    const rate = winRate(r.won, r.at_risk);
    return `
    <tr>
      <td>${escapeHtml(r.name)}<br><small style="color:var(--muted)">${r.role}</small></td>
      <td>${r.lead}</td><td>${r.qualified}</td><td>${r.proposal}</td>
      <td>${r.won}</td><td>${r.at_risk}</td><td>${r.dormant}</td><td>${r.lost}</td>
      <td>${rate === null ? "—" : rate + "%"}</td>
      <td>${r.wonValue.toLocaleString()} ฿</td>
      <td>${r.atRiskValue.toLocaleString()} ฿</td>
      <td>${r.openValue.toLocaleString()} ฿</td>
    </tr>
  `;
  }).join("");

  const totals = rows.reduce((acc, r) => {
    ["lead", "qualified", "proposal", "won", "at_risk", "dormant", "lost", "wonValue", "openValue", "atRiskValue"]
      .forEach(k => { acc[k] = (acc[k] || 0) + r[k]; });
    return acc;
  }, {});
  const totalRate = winRate(totals.won, totals.at_risk);

  body.innerHTML += `
    <tr class="totals-row">
      <td>Total</td>
      <td>${totals.lead}</td><td>${totals.qualified}</td><td>${totals.proposal}</td>
      <td>${totals.won}</td><td>${totals.at_risk}</td><td>${totals.dormant}</td><td>${totals.lost}</td>
      <td>${totalRate === null ? "—" : totalRate + "%"}</td>
      <td>${totals.wonValue.toLocaleString()} ฿</td>
      <td>${totals.atRiskValue.toLocaleString()} ฿</td>
      <td>${totals.openValue.toLocaleString()} ฿</td>
    </tr>`;
}

async function populateAssignedToDropdown() {
  const { data, error } = await sb.from("profiles").select("id, full_name, role").order("full_name");
  if (error) return;
  const sel = document.getElementById("f-assigned-to");
  sel.innerHTML = data.map(p => `<option value="${p.id}">${p.full_name} (${p.role})</option>`).join("");
}

// -------------------------------------------------------------- list/table
async function loadClients() {
  if (myProfile.role === "admin" && adminView === "summary") {
    await loadSummary();
    return;
  }

  const isDirector = myProfile.role === "director";
  const onTeamLeadsTab = isDirector && directorView === "leads";

  // Director "My pipeline" queries the real clients table filtered to their
  // own rows client-side (RLS on the server already permits this — see
  // "clients: director reads/inserts/updates own" in schema.sql). Director
  // "Team leads" uses the column-limited, org-wide director_leads view, same
  // as before. Everyone else is unchanged.
  let query;
  if (onTeamLeadsTab) {
    query = sb.from("director_leads").select("*");
  } else if (isDirector) {
    query = sb.from("clients").select("*").eq("assigned_to", myProfile.id);
  } else {
    query = sb.from("clients").select("*");
  }

  const { data, error } = await query.order("created_at", { ascending: false });

  const head = document.getElementById("table-head");
  const body = document.getElementById("table-body");

  if (error) {
    body.innerHTML = `<tr><td colspan="6">Couldn't load records: ${error.message}</td></tr>`;
    return;
  }

  const showValue = myProfile.role === "admin" || myProfile.role === "sales" || (isDirector && !onTeamLeadsTab);
  const showAssigned = myProfile.role === "admin";
  const editable = !onTeamLeadsTab; // admin, sales, and director's own pipeline are all editable

  // Personal "how am I doing" line for sales reps and the director's own
  // pipeline (not the admin views — they get the same numbers per rep in
  // Team summary — and not the director's org-wide Team leads feed, which
  // isn't a personal pipeline).
  const showPersonalStats = myProfile.role === "sales" || (isDirector && !onTeamLeadsTab);
  if (showPersonalStats) {
    renderPipelineStats(data || []);
    pipelineStats.classList.remove("hidden");
  } else {
    pipelineStats.classList.add("hidden");
  }

  head.innerHTML = `<tr>
      <th>Client</th><th>Segment</th><th>Stage</th>
      ${showValue ? "<th>Deal value</th>" : ""}
      <th>Next action</th>
      ${showAssigned ? "<th>Assigned to</th>" : ""}
    </tr>`;

  body.innerHTML = (data || []).map(c => `
    <tr class="clickable-row" data-id="${c.id}" data-editable="${editable}">
      <td>${escapeHtml(c.name)}${c.contact_name ? `<br><small>${escapeHtml(c.contact_name)}</small>` : ""}</td>
      <td>${escapeHtml(c.segment || "")}</td>
      <td><span class="badge badge-${c.stage}">${STAGE_LABEL[c.stage] || c.stage}</span></td>
      ${showValue ? `<td>${c.deal_value ? Number(c.deal_value).toLocaleString() + " ฿" : "—"}</td>` : ""}
      <td>${escapeHtml(c.next_action || "—")}${c.next_action_date ? `<br><small>${c.next_action_date}</small>` : ""}</td>
      ${showAssigned ? `<td>${c.assigned_to || "—"}</td>` : ""}
    </tr>
  `).join("") || `<tr><td colspan="6">Nothing here yet.</td></tr>`;

  body.querySelectorAll("tr.clickable-row").forEach(row => {
    if (row.dataset.editable === "true") {
      row.addEventListener("click", () => openEditModal(row.dataset.id, data));
    }
  });
}

function escapeHtml(str) {
  const d = document.createElement("div");
  d.textContent = str ?? "";
  return d.innerHTML;
}

// -------------------------------------------------------------- edit modal
const modal = document.getElementById("edit-modal");
const editForm = document.getElementById("edit-form");

document.getElementById("new-client-btn").addEventListener("click", () => openEditModal(null, []));
document.getElementById("cancel-edit-btn").addEventListener("click", closeModal);

function openEditModal(id, currentRows) {
  editingId = id;
  const record = id ? currentRows.find(r => r.id === id) : null;

  document.getElementById("modal-title").textContent = id ? "Edit client" : "New client";
  document.getElementById("f-name").value = record?.name || "";
  document.getElementById("f-contact").value = record?.contact_name || "";
  document.getElementById("f-phone").value = record?.phone || "";
  document.getElementById("f-email").value = record?.email || "";
  document.getElementById("f-segment").value = record?.segment || "Restaurant";
  document.getElementById("f-stage").value = record?.stage || "lead";
  document.getElementById("f-value").value = record?.deal_value ?? "";
  document.getElementById("f-next-date").value = record?.next_action_date || "";
  document.getElementById("f-next-action").value = record?.next_action || "";
  document.getElementById("f-notes").value = record?.notes || "";
  if (myProfile.role === "admin" && record?.assigned_to) {
    document.getElementById("f-assigned-to").value = record.assigned_to;
  }

  modal.classList.remove("hidden");
}

function closeModal() {
  modal.classList.add("hidden");
  editingId = null;
}

editForm.addEventListener("submit", async (e) => {
  e.preventDefault();

  const payload = {
    name: document.getElementById("f-name").value.trim(),
    contact_name: document.getElementById("f-contact").value.trim() || null,
    phone: document.getElementById("f-phone").value.trim() || null,
    email: document.getElementById("f-email").value.trim() || null,
    segment: document.getElementById("f-segment").value,
    stage: document.getElementById("f-stage").value,
    deal_value: document.getElementById("f-value").value || null,
    next_action_date: document.getElementById("f-next-date").value || null,
    next_action: document.getElementById("f-next-action").value.trim() || null,
    notes: document.getElementById("f-notes").value.trim() || null,
  };

  if (myProfile.role === "admin") {
    payload.assigned_to = document.getElementById("f-assigned-to").value;
  } else if (!editingId) {
    payload.assigned_to = myProfile.id; // sales reps always own what they create
  }

  const query = editingId
    ? sb.from("clients").update(payload).eq("id", editingId)
    : sb.from("clients").insert(payload);

  const { error } = await query;
  if (error) {
    alert("Couldn't save: " + error.message);
    return;
  }

  closeModal();
  await loadClients();
});
