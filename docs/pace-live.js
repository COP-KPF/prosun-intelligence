// ============================================================================
// PACE — live updates between departments (Migration 041, 20 Nov 2026)
// ============================================================================
// Clément: when production or the middle office postpones an order (or a
// product), the other side must see it at once.
//
// The database keeps one stamp per subject (table pace_live, topic "orders"),
// renewed by every change to working papers, their products, postponements,
// the middle office register, delivery marks, invoices and closures. Only the
// stamp is published to realtime — it holds no order data — so each screen,
// when it hears the stamp change, reloads its own data through its own
// permissions: Weighing, Confirmed weights, Postponed orders, Delivery board
// and the menu count. Screens still refresh on their usual timer if the live
// connection is down.
//
// Loaded before the screens (weighing.js, weights-summary.js, postponed.js,
// delivery.js); uses app.js's `sb` at run time.
// ============================================================================

const PACE_LIVE = { channel: null, subs: new Set(), timer: null, connected: false };

// Register a screen's reload. Returns a function that unregisters it.
function paceLiveOn(cb) {
  PACE_LIVE.subs.add(cb);
  paceLiveStart();
  return () => PACE_LIVE.subs.delete(cb);
}

// Connects once signed in (called by the screens when they open).
function paceLiveStart() {
  if (PACE_LIVE.channel || typeof sb === "undefined" || !sb || typeof sb.channel !== "function") return;
  if (typeof myProfile === "undefined" || !myProfile) return;
  try {
    PACE_LIVE.channel = sb.channel("pace-live")
      .on("postgres_changes", { event: "*", schema: "public", table: "pace_live" }, paceLiveFire)
      .subscribe((status) => { PACE_LIVE.connected = status === "SUBSCRIBED"; });
  } catch (e) {
    PACE_LIVE.channel = null;   // the screens' own timers keep them current
  }
}

// Several changes in a row (a postponement writes a paper, its products and
// a history line) make one reload.
function paceLiveFire() {
  clearTimeout(PACE_LIVE.timer);
  PACE_LIVE.timer = setTimeout(() => {
    PACE_LIVE.subs.forEach((cb) => { try { cb(); } catch (e) { console.warn("Live update:", e); } });
  }, 600);
}

function paceLiveStop() {
  clearTimeout(PACE_LIVE.timer);
  if (PACE_LIVE.channel) { try { sb.removeChannel(PACE_LIVE.channel); } catch (e) { /* ignore */ } }
  PACE_LIVE.channel = null;
  PACE_LIVE.connected = false;
}

document.getElementById("sign-out-btn").addEventListener("click", paceLiveStop);
