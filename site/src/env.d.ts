// The bundler compiles `*.wasm?module` imports to a WebAssembly.Module in the Worker.
declare module '*.wasm?module' {
	const mod: WebAssembly.Module
	export default mod
}
