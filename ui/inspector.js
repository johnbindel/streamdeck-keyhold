// Shared property-inspector logic for every Key Hold action.
//
// The page describes itself with data attributes and this file wires up whatever it finds,
// so an action's inspector is just markup:
//
//   <input data-combo="hold">          a combination recorder; stores key + modifiers
//   <button data-clear="hold">         clears that recorder
//   <input data-number="holdForMs">    a numeric setting, clamped to its own min/max
//
// A page may set window.PAGE_DEFAULTS before loading this file to seed values for settings
// it has never saved.

const LEGACY_MODIFIERS = ["ctrl", "alt", "shift", "cmd"];
const MODIFIER_TOKENS = [
	"ctrl", "alt", "shift", "cmd",
	"lctrl", "rctrl", "lalt", "ralt", "lshift", "rshift", "lcmd", "rcmd",
];

const DEFAULTS = window.PAGE_DEFAULTS ?? {};

const RECORDERS = {};
for (const input of document.querySelectorAll("[data-combo]")) {
	RECORDERS[input.dataset.combo] = input;
}
const PREFIXES = Object.keys(RECORDERS);
const NUMBERS = [...document.querySelectorAll("[data-number]")];

const KEY_CODES = {
	Enter: "enter", NumpadEnter: "numpadenter", Space: "space", Tab: "tab",
	Escape: "escape", Backspace: "backspace", Delete: "delete", Insert: "insert",
	Home: "home", End: "end", PageUp: "pageup", PageDown: "pagedown",
	ArrowLeft: "left", ArrowRight: "right", ArrowUp: "up", ArrowDown: "down",
	Semicolon: "semicolon", Equal: "equal", Comma: "comma", Minus: "minus",
	Period: "period", Slash: "slash", Backquote: "backquote",
	BracketLeft: "leftbracket", Backslash: "backslash",
	BracketRight: "rightbracket", Quote: "quote",
};
const IS_MAC = /Mac/.test(navigator.platform);
// Apple's own key legend, as printed in macOS menus. Insert has no glyph because Apple
// keyboards have no Insert key. Return is ↩ (U+21A9); ⏎ and ↵ are the typographic return
// symbols Apple does not use.
const MAC_KEY_LABELS = {
	enter: "↩", numpadenter: "⌤", space: "␣", tab: "⇥", escape: "⎋",
	backspace: "⌫", delete: "⌦",
	home: "↖", end: "↘", pageup: "⇞", pagedown: "⇟",
};
const KEY_LABELS = {
	enter: "Enter", numpadenter: "Num Enter", space: "Space", tab: "Tab", escape: "Esc",
	backspace: "Backspace", delete: "Delete", insert: "Insert",
	home: "Home", end: "End", pageup: "Page Up", pagedown: "Page Down",
	left: "←", right: "→", up: "↑", down: "↓", semicolon: ";", equal: "=",
	comma: ",", minus: "−", period: ".", slash: "/", backquote: "`",
	leftbracket: "[", backslash: "\\", rightbracket: "]", quote: "'",
	...(IS_MAC ? MAC_KEY_LABELS : {}),
};
const MOD_LABELS = {
	ctrl: IS_MAC ? "⌃" : "Ctrl", alt: IS_MAC ? "⌥" : "Alt",
	shift: IS_MAC ? "⇧" : "Shift", cmd: IS_MAC ? "⌘" : "Win",
	lctrl: IS_MAC ? "⌃" : "Left Ctrl", rctrl: IS_MAC ? "⌃" : "Right Ctrl",
	lalt: IS_MAC ? "⌥" : "Left Alt", ralt: IS_MAC ? "⌥" : "Right Alt",
	lshift: IS_MAC ? "⇧" : "Left Shift", rshift: IS_MAC ? "⇧" : "Right Shift",
	lcmd: IS_MAC ? "⌘" : "Left Win", rcmd: IS_MAC ? "⌘" : "Right Win",
};

let websocket, uuid, settings = {};
let recording = null;
let pressedModifiers = new Set();
let draftModifiers = new Set();

// The first recorder on a page owns the unprefixed key/modifiers settings; the rest are
// prefixed. That keeps the original action's saved settings readable by every later one.
function settingName(prefix, name) {
	return prefix === "hold"
		? name
		: prefix + name[0].toUpperCase() + name.slice(1);
}

function comboFromSettings(source, prefix) {
	const savedModifiers = source[settingName(prefix, "modifiers")];
	return {
		key: source[settingName(prefix, "key")] ?? "",
		mods: Array.isArray(savedModifiers)
			? savedModifiers.filter((modifier) => MODIFIER_TOKENS.includes(modifier))
			: LEGACY_MODIFIERS.filter((modifier) => source[settingName(prefix, modifier)]),
	};
}

function displayCombo(combo) {
	const modifiers = combo.mods.map((mod) => MOD_LABELS[mod]);
	const key = combo.key ? KEY_LABELS[combo.key] ?? combo.key.toUpperCase() : "";
	return IS_MAC ? modifiers.join("") + key : [...modifiers, key].filter(Boolean).join(" + ");
}

function render() {
	const source = { ...DEFAULTS, ...settings };
	for (const prefix of PREFIXES) {
		RECORDERS[prefix].value = displayCombo(comboFromSettings(source, prefix));
	}
	for (const input of NUMBERS) {
		// Leave the field alone while it has focus, so re-rendering cannot rewrite digits
		// out from under someone mid-edit.
		if (document.activeElement !== input) {
			const value = source[input.dataset.number];
			input.value = value ? String(value) : "";
		}
	}
}

function save() {
	websocket.send(JSON.stringify({ event: "setSettings", context: uuid, payload: settings }));
	render();
}

function saveCombo(prefix, combo) {
	settings = {
		...settings,
		[settingName(prefix, "key")]: combo.key,
		[settingName(prefix, "modifiers")]: combo.mods,
	};
	save();
}

function saveNumber(input) {
	const value = Math.round(Number(input.value));
	const min = Number(input.min) || 0;
	const max = Number(input.max) || Number.MAX_SAFE_INTEGER;
	settings = {
		...settings,
		[input.dataset.number]: Number.isFinite(value) && value > min
			? Math.min(value, max)
			: min,
	};
	save();
}

function modifierFromCode(code) {
	return {
		ControlLeft: "lctrl", ControlRight: "rctrl",
		AltLeft: "lalt", AltRight: "ralt",
		ShiftLeft: "lshift", ShiftRight: "rshift",
		MetaLeft: "lcmd", MetaRight: "rcmd",
	}[code] ?? null;
}

function keyFromCode(code) {
	if (/^Key[A-Z]$/.test(code)) return code.slice(3).toLowerCase();
	if (/^Digit[0-9]$/.test(code)) return code.slice(5);
	if (/^F(?:[1-9]|1[0-9]|20)$/.test(code)) return code.toLowerCase();
	return KEY_CODES[code] ?? null;
}

function startRecording(prefix) {
	recording = prefix;
	pressedModifiers = new Set();
	draftModifiers = new Set();
	RECORDERS[prefix].value = "Press a combination…";
}

function finishRecording(prefix, key = "") {
	const combo = { key, mods: MODIFIER_TOKENS.filter((mod) => draftModifiers.has(mod)) };
	recording = null;
	pressedModifiers.clear();
	draftModifiers.clear();
	saveCombo(prefix, combo);
}

function onRecorderKeyDown(prefix, event) {
	if (recording !== prefix) return;
	event.preventDefault();
	event.stopPropagation();

	const modifier = modifierFromCode(event.code);
	if (modifier) {
		pressedModifiers.add(modifier);
		draftModifiers.add(modifier);
		const partial = displayCombo({ key: "", mods: MODIFIER_TOKENS.filter((m) => draftModifiers.has(m)) });
		RECORDERS[prefix].value = partial + (IS_MAC ? "" : " + ") + "…";
		return;
	}

	if (event.ctrlKey && !draftModifiers.has("lctrl") && !draftModifiers.has("rctrl")) draftModifiers.add("ctrl");
	if (event.altKey && !draftModifiers.has("lalt") && !draftModifiers.has("ralt")) draftModifiers.add("alt");
	if (event.shiftKey && !draftModifiers.has("lshift") && !draftModifiers.has("rshift")) draftModifiers.add("shift");
	if (event.metaKey && !draftModifiers.has("lcmd") && !draftModifiers.has("rcmd")) draftModifiers.add("cmd");
	const key = keyFromCode(event.code);
	if (key) finishRecording(prefix, key);
	else RECORDERS[prefix].value = "Unsupported key — try another";
}

function onRecorderKeyUp(prefix, event) {
	if (recording !== prefix) return;
	const modifier = modifierFromCode(event.code);
	if (!modifier) return;
	event.preventDefault();
	event.stopPropagation();
	pressedModifiers.delete(modifier);
	if (pressedModifiers.size === 0 && draftModifiers.size > 0) finishRecording(prefix);
}

for (const prefix of PREFIXES) {
	const recorder = RECORDERS[prefix];
	recorder.addEventListener("focus", () => startRecording(prefix));
	recorder.addEventListener("click", () => startRecording(prefix));
	recorder.addEventListener("keydown", (event) => onRecorderKeyDown(prefix, event));
	recorder.addEventListener("keyup", (event) => onRecorderKeyUp(prefix, event));
	recorder.addEventListener("blur", () => {
		if (recording === prefix) {
			recording = null;
			render();
		}
	});
}

for (const input of NUMBERS) {
	input.addEventListener("change", () => saveNumber(input));
	input.addEventListener("blur", () => saveNumber(input));
}

for (const button of document.querySelectorAll("[data-clear]")) {
	button.addEventListener("click", () => saveCombo(button.dataset.clear, { key: "", mods: [] }));
}

// eslint-disable-next-line no-unused-vars -- Stream Deck calls this by name.
function connectElgatoStreamDeckSocket(port, propertyInspectorUUID, registerEvent, info, actionInfo) {
	uuid = propertyInspectorUUID;
	settings = JSON.parse(actionInfo).payload.settings ?? {};
	websocket = new WebSocket("ws://127.0.0.1:" + port);

	websocket.onopen = () => {
		websocket.send(JSON.stringify({ event: registerEvent, uuid: propertyInspectorUUID }));
		render();
	};

	websocket.onmessage = (evt) => {
		const msg = JSON.parse(evt.data);
		if (msg.event === "didReceiveSettings") {
			settings = msg.payload.settings ?? {};
			render();
		}
	};
}
