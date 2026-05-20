const grid = document.getElementById("grid");
const pageJsonBase64 = document.getElementById("page").textContent;

let wasmInstance;
const decoder = new TextDecoder();
let currentHtml = "";

function readWasmString(ptr, len) {
    const memory = wasmInstance.exports.memory;
    return decoder.decode(new Uint8Array(memory.buffer, ptr, len));
}

var importObject = {
    env: {
        _consoleLog: function(ptr, len) {
            console.log(readWasmString(ptr, len));
        },
        _setHtml: function(ptr, len) {
            const html = readWasmString(ptr, len);
            if (html !== currentHtml) {
                currentHtml = html;
                grid.innerHTML = html;
            }
        },
    },
};

WebAssembly.instantiateStreaming(fetch("haxy.wasm"), importObject).then((result) => {
    wasmInstance = result.instance;

    // the page is embedded as base64 so it can sit inside the host html
    // without worrying about characters that would terminate the script tag.
    // decode here and hand the raw json bytes to the wasm.
    const jsonBytes = Uint8Array.from(atob(pageJsonBase64), (c) => c.charCodeAt(0));
    const ptr = wasmInstance.exports._alloc(jsonBytes.length);
    new Uint8Array(wasmInstance.exports.memory.buffer, ptr, jsonBytes.length).set(jsonBytes);
    wasmInstance.exports._start(ptr, jsonBytes.length);

    document.addEventListener("keydown", (event) => {
        if (["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "PageUp", "PageDown", "Home", "End"].includes(event.key)) {
            event.preventDefault();
        }
        wasmInstance.exports._onKeyDown(event.keyCode);
        wasmInstance.exports._tick();
    });
});
