import { spawn } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import streamDeck from "@elgato/streamdeck";

const HERE = dirname(fileURLToPath(import.meta.url));
const HELPER = join(HERE, process.platform === "win32" ? "keyholder.exe" : "keyholder");

const LEGACY_MODIFIERS = ["ctrl", "alt", "shift", "cmd"];
const MODIFIER_TOKENS = [
	"ctrl", "alt", "shift", "cmd",
	"lctrl", "rctrl", "lalt", "ralt", "lshift", "rshift", "lcmd", "rcmd",
];

const DEFAULTS = {
	key: "t",
	ctrl: true,
	alt: true,
	shift: false,
	cmd: true,
	modifiers: null,
	preReleaseKey: "",
	preReleaseModifiers: null,
	releaseKey: "",
	releaseCtrl: false,
	releaseAlt: false,
	releaseShift: false,
	releaseCmd: false,
	releaseModifiers: null,
};

/**
 * Long-lived helper process that does the actual key holding. It owns the combo
 * semantics because they differ per platform: macOS attaches modifiers as flags on a
 * single event, Windows must physically press each modifier key.
 */
let helper = null;

function send(line) {
	if (!helper || helper.exitCode !== null) {
		helper = spawn(HELPER, [], { stdio: ["pipe", "ignore", "pipe"] });
		helper.on("error", (err) => streamDeck.logger.error(`helper failed to start: ${err}`));
		helper.stderr.on("data", (data) => streamDeck.logger.error(`helper: ${data}`));
	}
	helper.stdin.write(`${line}\n`);
}

function comboOf(settings, prefix = "") {
	const merged = { ...DEFAULTS, ...settings };
	const settingName = (name) => prefix
		? `${prefix}${name[0].toUpperCase()}${name.slice(1)}`
		: name;
	const key = String(merged[settingName("key")] ?? "").toLowerCase();
	const savedModifiers = merged[settingName("modifiers")];
	const mods = Array.isArray(savedModifiers)
		? savedModifiers.filter((modifier) => MODIFIER_TOKENS.includes(modifier))
		: LEGACY_MODIFIERS.filter((modifier) => merged[settingName(modifier)]);
	return key || mods.length ? { key, mods } : null;
}

function command(verb, { key, mods }) {
	return `${verb} ${mods.length ? mods.join(",") : "-"} ${key || "-"}`;
}

/**
 * Which action instances are currently holding. A pedal can be released while a
 * different profile is showing, so release is unconditional rather than re-derived from
 * settings that may have changed underneath us mid-hold.
 */
const holding = new Map();

streamDeck.actions.onKeyDown((ev) => {
	const heldCombo = comboOf(ev.payload.settings);
	if (heldCombo) send(command("D", heldCombo));
	holding.set(ev.action.id, {
		held: !!heldCombo,
		preReleaseCombo: comboOf(ev.payload.settings, "preRelease"),
		releaseCombo: comboOf(ev.payload.settings, "release"),
	});
});

/**
 * Order matters and is the whole point of having two slots: "B" taps on top of the hold
 * while it is still down, "T" taps after it is gone. An app whose push-to-talk ends on a
 * separate hotkey needs one or the other, and which one is not something we can guess.
 */
streamDeck.actions.onKeyUp((ev) => {
	if (!holding.has(ev.action.id)) return;
	const { held, preReleaseCombo, releaseCombo } = holding.get(ev.action.id);
	holding.delete(ev.action.id);
	if (preReleaseCombo) send(command("B", preReleaseCombo));
	if (held) send("U");
	if (releaseCombo) send(command("T", releaseCombo));
});

streamDeck.connect();
