const grid = document.getElementById("grid");
const overlay = document.getElementById("overlay");
const pageJson = document.getElementById("page-data").textContent;

let wasmInstance;
const decoder = new TextDecoder();
const encoder = new TextEncoder();
let currentHtml = "";
// each scroll div's wasm-side offset (in cells) as of the last render, keyed by
// scroll id. when a new render's offset differs, the wasm moved the scroll on
// purpose and its offset is applied; otherwise the browser position (the user's
// scrolling) is preserved.
const wasmOffsets = {};
// seeded from the server-rendered overlay so the first wasm tick can no-op
// when its layout happens to match the server's. otherwise the first tick
// always rebuilds and any pre-load focus state is lost.
let currentOverlay = overlay.innerHTML;

const MIN_COLS = 30;

// measured once after the font is loaded. recomputed lazily if either reads
// back as zero (e.g. measured before the font was actually ready).
let cellWidth = null;
let cellHeight = null;

function measureCell() {
    const probe = document.createElement("span");
    probe.style.position = "absolute";
    probe.style.visibility = "hidden";
    probe.style.whiteSpace = "pre";
    probe.textContent = "X".repeat(100);
    grid.appendChild(probe);
    const rect = probe.getBoundingClientRect();
    probe.remove();
    cellWidth = rect.width / 100;
    cellHeight = rect.height;
}

function maxCols() {
    if (!cellWidth) measureCell();
    return Math.max(MIN_COLS, Math.floor(document.body.clientWidth / cellWidth));
}

// minimum row count for the wasm build — the TUI fills at least the
// viewport height, longer content extends past it and the browser scrolls.
function minRows() {
    if (!cellHeight) measureCell();
    return Math.max(1, Math.floor(document.documentElement.clientHeight / cellHeight));
}

function readWasmString(ptr, len) {
    const memory = wasmInstance.exports.memory;
    return decoder.decode(new Uint8Array(memory.buffer, ptr, len));
}

const importObject = {
    env: {
        _consoleLog: function (ptr, len) {
            console.log(readWasmString(ptr, len));
        },
        _setHtml: function (ptr, len) {
            const html = readWasmString(ptr, len);
            if (html === currentHtml) return;
            currentHtml = html;
            // each web-native Scroll renders as a .scroll div; replacing
            // innerHTML recreates them and would reset their scroll position
            // every tick, so snapshot scrollTop/Left by their stable id and
            // restore it after the swap. (mouse-wheel scrolling happens with no
            // tick, so it isn't affected.)
            const positions = {};
            for (const el of grid.querySelectorAll(".scroll[data-scroll-id]")) {
                positions[el.dataset.scrollId] = { top: el.scrollTop, left: el.scrollLeft };
            }
            grid.innerHTML = html;
            for (const el of grid.querySelectorAll(".scroll[data-scroll-id]")) {
                const id = el.dataset.scrollId;
                const offset = { top: Number(el.dataset.scrollY || 0), left: Number(el.dataset.scrollX || 0) };
                const prev = wasmOffsets[id];
                const p = positions[id];
                if (p && prev && prev.top === offset.top && prev.left === offset.left) {
                    el.scrollTop = p.top;
                    el.scrollLeft = p.left;
                } else {
                    // the wasm's offset changed (or this div is new — a fresh
                    // page load or a bumped content version): apply it,
                    // converted from cells to pixels.
                    if (!cellWidth || !cellHeight) measureCell();
                    el.scrollTop = offset.top * cellHeight;
                    el.scrollLeft = offset.left * cellWidth;
                }
                wasmOffsets[id] = offset;
            }
        },
        _replaceState: function (ptr, len) {
            const url = readWasmString(ptr, len);
            // passive same-page URL changes. replaceState changes the URL
            // without adding a history entry, so the back button isn't
            // cluttered with unnecessary entries.
            if (window.location.pathname !== url) {
                history.replaceState({}, "", url);
            }
        },
        _setOverlay: function (ptr, len) {
            const html = readWasmString(ptr, len);
            // diff against the previous overlay HTML; an unchanged overlay
            // means no layout/structure has shifted (typing alone doesn't
            // produce a diff because we deliberately omit the `value`
            // attribute on inputs — the browser tracks that). skipping the
            // innerHTML assignment keeps the live <form> alive across the
            // mousedown→focusin→tick→click sequence, which is what lets
            // the very first click on the submit button actually submit.
            if (html === currentOverlay) return;
            currentOverlay = html;
            overlay.innerHTML = html;
        },
        _focusInput: function (id) {
            const target = overlay.querySelector(`[data-focus-id="${id}"]`);
            if (target && document.activeElement !== target) target.focus();
        },
        _navigate: function (ptr, len) {
            // a real browser navigation to another top-level page (the wasm
            // can't render it client-side without server data).
            window.location.assign(readWasmString(ptr, len));
        },
        _scrollToFocus: function (id) {
            // bring the focused widget into view within its own .scroll div. it's
            // several spans (one per row) sharing this id, in top-to-bottom order,
            // so the first gives its top/left edge and the last its bottom.
            const els = grid.querySelectorAll(`[data-focus-id="${id}"]`);
            if (els.length === 0) return;
            const container = els[0].closest(".scroll");
            if (!container) return;

            const c = container.getBoundingClientRect();
            const first = els[0].getBoundingClientRect();
            const last = els[els.length - 1].getBoundingClientRect();
            const top = first.top - c.top + container.scrollTop;
            const bottom = last.bottom - c.top + container.scrollTop;
            const left = first.left - c.left + container.scrollLeft;

            // vertical is the priority axis: fit the widget, preferring its top
            // when it's taller than the viewport.
            if (top < container.scrollTop || bottom - top > container.clientHeight) {
                container.scrollTop = top;
            } else if (bottom > container.scrollTop + container.clientHeight) {
                container.scrollTop = bottom - container.clientHeight;
            }
            // horizontal: only reveal the row's start, never chase the right edge,
            // so moving down through varying-width rows doesn't yank the view
            // sideways. (a hidden-overflow x axis stays at 0, so this no-ops.)
            if (left < container.scrollLeft) container.scrollLeft = left;
        },
    },
};

function sendTextInputValue(focusId, value) {
    const bytes = encoder.encode(value);
    const ptr = wasmInstance.exports._alloc(bytes.length);
    new Uint8Array(wasmInstance.exports.memory.buffer, ptr, bytes.length).set(bytes);
    wasmInstance.exports._setTextInputValue(focusId, ptr, bytes.length);
    wasmInstance.exports._tick(minRows(), maxCols());
}

function sendEnter(form) {
    const btn = form.querySelector("button[type=submit][data-focus-id]");
    if (!btn) return;
    wasmInstance.exports._onMouseClick(Number(btn.dataset.focusId));
    wasmInstance.exports._onKeyDown(13);
    wasmInstance.exports._tick(minRows(), maxCols());
}

WebAssembly.instantiateStreaming(fetch("/haxy.wasm"), importObject).then(async (result) => {
    wasmInstance = result.instance;

    // wait for the @font-face to load before measuring cell width, otherwise
    // we get the fallback font's metrics.
    if (document.fonts && document.fonts.ready) {
        await document.fonts.ready;
    }

    // the page is embedded as raw json in a script tag.
    // encode to utf-8 bytes and hand it to the wasm.
    const jsonBytes = encoder.encode(pageJson);
    const ptr = wasmInstance.exports._alloc(jsonBytes.length);
    new Uint8Array(wasmInstance.exports.memory.buffer, ptr, jsonBytes.length).set(jsonBytes);
    wasmInstance.exports._init(ptr, jsonBytes.length, minRows(), maxCols());

    document.addEventListener("keydown", (event) => {
        // let the browser handle modifier combos. the TUI only uses unmodified keys,
        // so intercepting these would just break normal browser navigation.
        if (event.altKey || event.ctrlKey || event.metaKey) return;
        // when a form element (text input or submit button) owns focus, the
        // browser handles typing and Tab natively (and Enter on the button
        // submits). we only forward keys into the TUI when focus is elsewhere.
        // exception: arrow up/down on an input unfocuses it and forwards
        // the event so the TUI can move focus between widgets.
        if (document.activeElement) {
            const tag = document.activeElement.tagName;
            const isArrow = event.key === "ArrowUp" || event.key === "ArrowDown" ||
                event.key === "ArrowLeft" || event.key === "ArrowRight";
            if (tag === "INPUT" && event.key === "Enter") {
                // enter in a text input never submits the form; only the
                // submit button does
                event.preventDefault();
                return;
            }
            if (tag === "INPUT" && (event.key === "ArrowUp" || event.key === "ArrowDown")) {
                // up/down moves between widgets; left/right stay in the input
                document.activeElement.blur();
            } else if (tag === "BUTTON" && isArrow) {
                // arrows navigate away from a focused submit button
                document.activeElement.blur();
            } else if (tag === "INPUT" || tag === "BUTTON" || tag === "TEXTAREA") {
                // Enter (submit / newline), typing, Tab, and a textarea's
                // arrows — handled natively by the browser
                return;
            }
        }
        if (["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "PageUp", "PageDown", "Home", "End"].includes(event.key)) {
            event.preventDefault();
        }
        wasmInstance.exports._onKeyDown(event.keyCode);
        wasmInstance.exports._tick(minRows(), maxCols());
    });

    // submit on mousedown rather than waiting for click: the focusin this
    // same mousedown fires ticks the wasm, and a resulting overlay rebuild
    // would detach the button before its click could land. the form is
    // guaranteed live at mousedown time.
    document.addEventListener("mousedown", (event) => {
        if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
        const btn = event.target.closest ? event.target.closest("button[type=submit][data-focus-id]") : null;
        if (!btn || !btn.form) return;
        // empty-action forms are handled by their onsubmit on the click path
        if (!btn.form.getAttribute("action")) return;
        // if the button survives to receive the click, don't submit twice
        btn.addEventListener("click", (e) => e.preventDefault(), { once: true });
        btn.form.requestSubmit(btn);
    });

    // listeners on document (not #grid) since the form lives outside #grid;
    // input/focus events from form elements still bubble up to document.
    document.addEventListener("input", (event) => {
        const t = event.target;
        if (!t || (t.tagName !== "INPUT" && t.tagName !== "TEXTAREA") || !t.dataset.focusId) return;
        sendTextInputValue(Number(t.dataset.focusId), t.value);
    });

    document.addEventListener("focusin", (event) => {
        const t = event.target;
        if (!t || !t.dataset || !t.dataset.focusId) return;
        // sync the wasm focus to wherever the browser moved focus
        wasmInstance.exports._setFocus(Number(t.dataset.focusId));
        // a click's mousedown fires this focusin before the click event. ticking
        // here would rebuild #grid and destroy the node before its click lands,
        // swallowing the navigation and forcing a second click — so don't
        // re-render for a grid element. overlay controls live outside #grid and
        // survive the diff, so they still tick.
        if (!grid.contains(t)) wasmInstance.exports._tick(minRows(), maxCols());
    });

    grid.addEventListener("click", (event) => {
        const span = event.target.closest(".clickable");
        if (!span) return;
        // leave modified / non-left clicks (open-in-new-tab, etc.) to the browser
        if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
        // wasm routes the click: an in-page link just moves focus and re-renders,
        // a cross-page one calls _navigate. suppress the <a>'s own navigation so
        // an in-page link doesn't also trigger a redundant full page load.
        event.preventDefault();
        const focusId = Number(span.dataset.focusId);
        wasmInstance.exports._onMouseClick(focusId);
        wasmInstance.exports._tick(minRows(), maxCols());
    });

    let resizeTimer = null;
    window.addEventListener("resize", () => {
        clearTimeout(resizeTimer);
        resizeTimer = setTimeout(() => {
            wasmInstance.exports._tick(minRows(), maxCols());
        }, 100);
    });
});
