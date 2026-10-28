// ============================================================================
// Phone camera page — capture.html (Migration 018)
// ============================================================================
// No login: the QR token in the address (?t=...) is checked by the edge
// function on every call, and only lets this page add photos for its day.
// Photos are resized on the phone, uploaded straight to private storage with
// a one-time signed URL, and the reading starts on the server. Nothing is
// read back here except "is the QR still valid" and how many were sent.
// ============================================================================

const capToken = new URLSearchParams(location.search).get("t") || "";
// The phone never signs in: no session is stored or refreshed.
const capClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
});

const capItems = [];   // { n, time, state: prep|send|done|error, blob, thumb, error }
let capSent = 0;
let capBusy = false;

const $ = (id) => document.getElementById(id);

function capShowExpired() {
  $("c-ready").classList.add("hidden");
  $("c-expired").classList.remove("hidden");
  $("c-day").textContent = "";
  $("c-link").textContent = "";
}

async function capInit() {
  if (!/^[0-9a-f-]{36}$/i.test(capToken)) { capShowExpired(); return; }
  try {
    const s = await weighCallFn({ action: "link_status", token: capToken });
    if (!s.valid) { capShowExpired(); return; }
    capSent = s.sent || 0;
    $("c-day").textContent = weighThaiDate(s.work_date);
    $("c-link").innerHTML = '<span class="c-dot"></span>ต่อกับคอมพิวเตอร์แล้ว';
    $("c-ready").classList.remove("hidden");
    capRender();
  } catch (e) {
    $("c-day").textContent = e.code === "offline" ? "ไม่มีสัญญาณอินเทอร์เน็ต — ลองใหม่อีกครั้ง" : "ตรวจ QR ไม่ได้: " + e.message;
  }
}

function capRender() {
  $("c-count").textContent = String(capSent);
  const list = $("c-list");
  list.innerHTML = "";
  capItems.slice().reverse().forEach((it) => {
    const li = document.createElement("li");
    li.className = "c-item";
    const img = document.createElement("img");
    img.alt = "";
    if (it.thumb) img.src = it.thumb;
    const body = document.createElement("div");
    body.className = "c-item-body";
    const t = document.createElement("div");
    t.className = "c-item-title";
    t.textContent = "ใบที่ " + it.n;
    const s = document.createElement("div");
    s.className = "c-item-time";
    s.textContent = it.time + (it.error ? " · " + it.error : "");
    body.append(t, s);
    li.append(img, body);
    if (it.state === "error") {
      const b = document.createElement("button");
      b.type = "button";
      b.className = "c-pill c-pill-red";
      b.textContent = "ส่งไม่สำเร็จ · แตะเพื่อลองใหม่";
      b.addEventListener("click", () => { it.state = "prep"; it.error = null; capRender(); capPump(); });
      li.append(b);
    } else {
      const p = document.createElement("span");
      p.className = "c-pill " + (it.state === "done" ? "c-pill-green" : "c-pill-blue");
      p.textContent = it.state === "done" ? "ส่งแล้ว" : it.state === "send" ? "กำลังส่ง…" : "กำลังเตรียม…";
      li.append(p);
    }
    list.append(li);
  });
}

function capAdd(files) {
  [...files].forEach((f) => {
    capItems.push({
      n: capSent + capItems.filter((i) => i.state !== "done").length + 1,
      time: new Date().toLocaleTimeString("th-TH", { hour: "2-digit", minute: "2-digit" }),
      state: "prep", file: f, blob: null, thumb: null, error: null,
    });
  });
  capRender();
  capPump();
}

// One at a time, in order: a factory connection is not always strong, and a
// failed photo stays on the list with a retry button instead of vanishing.
async function capPump() {
  if (capBusy) return;
  capBusy = true;
  try {
    let it;
    while ((it = capItems.find((i) => i.state === "prep"))) {
      it.state = "send";
      capRender();
      try {
        if (!it.blob) {
          it.blob = await weighResizePhoto(it.file);
          it.thumb = URL.createObjectURL(it.blob);
          it.file = null;
        }
        await weighUploadPhoto(capClient, it.blob, { token: capToken }, null);
        it.state = "done";
        it.blob = null;
        capSent++;
      } catch (e) {
        if (e.status === 410) { capShowExpired(); return; }
        it.state = "error";
        it.error = e.code === "offline" ? "ไม่มีสัญญาณ" : e.message;
      }
      capRender();
    }
  } finally {
    capBusy = false;
  }
}

$("c-camera").addEventListener("change", (e) => { capAdd(e.target.files); e.target.value = ""; });
$("c-gallery").addEventListener("change", (e) => { capAdd(e.target.files); e.target.value = ""; });

// Leaving with photos still sending would lose them.
window.addEventListener("beforeunload", (e) => {
  if (capItems.some((i) => i.state === "prep" || i.state === "send")) { e.preventDefault(); e.returnValue = ""; }
});

capInit();
