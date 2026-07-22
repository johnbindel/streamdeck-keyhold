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

function comboFields({ key, mods }) {
	return `${mods.length ? mods.join(",") : "-"} ${key || "-"}`;
}

/**
 * The helper keys holds by action id so two pedals held at once release only their own
 * keys. Ids come from Stream Deck and are opaque, so strip anything that would confuse a
 * space-delimited protocol.
 */
function holdId(actionId) {
	return String(actionId).replace(/\s+/g, "");
}

/**
 * A hold that never ends is the worst failure this plugin has — it leaves a key down
 * until the machine is logged out. Stream Deck normally sends onKeyUp, but a key-up can
 * be lost if the device is unplugged or the profile changes mid-hold, so every hold gets
 * a deadline as a backstop.
 */
const MAX_HOLD_MS = 5 * 60 * 1000;

/**
 * Which action instances are currently holding. The combos to run on release are captured
 * at key-down: a pedal can be released while a different profile is showing, so release
 * must not be re-derived from settings that may have changed underneath us mid-hold.
 */
const holding = new Map();

function beginHold(actionId, settings) {
	finishHold(actionId);
	const heldCombo = comboOf(settings);
	if (heldCombo) send(`D ${holdId(actionId)} ${comboFields(heldCombo)}`);
	holding.set(actionId, {
		held: !!heldCombo,
		preReleaseCombo: comboOf(settings, "preRelease"),
		releaseCombo: comboOf(settings, "release"),
		deadline: setTimeout(() => {
			streamDeck.logger.warn(`hold on ${actionId} passed ${MAX_HOLD_MS}ms; releasing it`);
			finishHold(actionId);
		}, MAX_HOLD_MS),
	});
}

/**
 * Order matters and is the whole point of having two slots: the first tap lands on top of
 * the hold while it is still down, the second after it is gone. An app whose push-to-talk
 * ends on a separate hotkey needs one or the other, and which one is not something we can
 * guess.
 */
function finishHold(actionId) {
	const hold = holding.get(actionId);
	if (!hold) return;
	holding.delete(actionId);
	clearTimeout(hold.deadline);
	if (hold.preReleaseCombo) send(`T ${comboFields(hold.preReleaseCombo)}`);
	if (hold.held) send(`U ${holdId(actionId)}`);
	if (hold.releaseCombo) send(`T ${comboFields(hold.releaseCombo)}`);
}

streamDeck.actions.onKeyDown((ev) => beginHold(ev.action.id, ev.payload.settings));
streamDeck.actions.onKeyUp((ev) => finishHold(ev.action.id));

// The button is going away — switched profile, unplugged device, page change. Its key-up
// may never arrive, so let go now rather than leave the key down.
streamDeck.actions.onWillDisappear((ev) => finishHold(ev.action.id));

streamDeck.connect();
