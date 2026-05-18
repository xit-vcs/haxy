const grid = document.getElementById("grid");

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
    wasmInstance.exports._start();

    document.addEventListener("keydown", (event) => {
        if (["ArrowUp", "ArrowDown", "PageUp", "PageDown", "Home", "End"].includes(event.key)) {
            event.preventDefault();
        }
        wasmInstance.exports._onKeyDown(event.keyCode);
        wasmInstance.exports._tick();
    });
});
