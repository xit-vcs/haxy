const grid = document.getElementById("grid");
const pageJsonBase64 = document.getElementById("page").textContent;

let wasmInstance;
const decoder = new TextDecoder();
let currentHtml = "";

const MIN_COLS = 30;

// measured once after the font is loaded. recomputed lazily if it ever
// reads back as zero (e.g. measured before the font was actually ready).
let cellWidth = null;

function measureCellWidth() {
    const probe = document.createElement("span");
    probe.style.position = "absolute";
    probe.style.visibility = "hidden";
    probe.style.whiteSpace = "pre";
    probe.textContent = "X".repeat(100);
    grid.appendChild(probe);
    const w = probe.getBoundingClientRect().width / 100;
    probe.remove();
    return w;
}

function maxCols() {
    if (!cellWidth) cellWidth = measureCellWidth();
    return Math.max(MIN_COLS, Math.floor(document.body.clientWidth / cellWidth));
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
            if (html !== currentHtml) {
                currentHtml = html;
                grid.innerHTML = html;
            }
        },
    },
};

WebAssembly.instantiateStreaming(fetch("haxy.wasm"), importObject).then(async (result) => {
    wasmInstance = result.instance;

    // wait for the @font-face to load before measuring cell width, otherwise
    // we get the fallback font's metrics.
    if (document.fonts && document.fonts.ready) {
        await document.fonts.ready;
    }

    // the page is embedded as base64 so it can sit inside the host html
    // without worrying about characters that would terminate the script tag.
    // decode here and hand the raw json bytes to the wasm.
    const jsonBytes = Uint8Array.from(atob(pageJsonBase64), (c) => c.charCodeAt(0));
    const ptr = wasmInstance.exports._alloc(jsonBytes.length);
    new Uint8Array(wasmInstance.exports.memory.buffer, ptr, jsonBytes.length).set(jsonBytes);
    wasmInstance.exports._start(ptr, jsonBytes.length, maxCols());

    document.addEventListener("keydown", (event) => {
        if (["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "PageUp", "PageDown", "Home", "End"].includes(event.key)) {
            event.preventDefault();
        }
        wasmInstance.exports._onKeyDown(event.keyCode);
        wasmInstance.exports._tick(maxCols());
    });

    grid.addEventListener("click", (event) => {
        const span = event.target.closest(".clickable");
        if (!span) return;
        const focusId = Number(span.dataset.focusId);
        wasmInstance.exports._onMouseClick(focusId);
        wasmInstance.exports._tick(maxCols());
    });

    let resizeTimer = null;
    window.addEventListener("resize", () => {
        clearTimeout(resizeTimer);
        resizeTimer = setTimeout(() => {
            wasmInstance.exports._tick(maxCols());
        }, 100);
    });
});
