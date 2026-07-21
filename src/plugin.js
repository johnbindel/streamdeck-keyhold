import { spawn } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import streamDeck from "@elgato/streamdeck";

const HERE = dirname(fileURLToPath(import.meta.url));
const HELPER = join(HERE, process.platform === "win32" ? "keyholder.exe" : "keyholder");

const MODIFIERS = ["ctrl", "alt", "shift", "cmd"];

const DEFAULTS = {
	key: "t",
	ctrl: true,
	alt: true,
	shift: false,
	cmd: true,
	releaseKey: "",
	releaseCtrl: false,
	releaseAlt: false,
	releaseShift: false,
	releaseCmd: false,
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

function comboOf(settings) {
	const merged = { ...DEFAULTS, ...settings };
	const mods = MODIFIERS.filter((m) => merged[m]);
	return { key: String(merged.key).toLowerCase(), mods };
}

function releaseComboOf(settings) {
	const merged = { ...DEFAULTS, ...settings };
	if (!merged.releaseKey) return null;

	const mods = MODIFIERS.filter((m) => merged[`release${m[0].toUpperCase()}${m.slice(1)}`]);
	return { key: String(merged.releaseKey).toLowerCase(), mods };
}

function command(verb, { key, mods }) {
	return `${verb} ${mods.length ? mods.join(",") : "-"} ${key}`;
}

/**
 * Which action instances are currently holding. A pedal can be released while a
 * different profile is showing, so release is unconditional rather than re-derived from
 * settings that may have changed underneath us mid-hold.
 */
const holding = new Map();

streamDeck.actions.onKeyDown((ev) => {
	send(command("D", comboOf(ev.payload.settings)));
	holding.set(ev.action.id, releaseComboOf(ev.payload.settings));
});

streamDeck.actions.onKeyUp((ev) => {
	if (!holding.has(ev.action.id)) return;
	const releaseCombo = holding.get(ev.action.id);
	holding.delete(ev.action.id);
	send("U");
	if (releaseCombo) send(command("T", releaseCombo));
});

streamDeck.connect();
