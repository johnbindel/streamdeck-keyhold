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

/**
 * The last key pressed, so a failure can be shown on the device. The helper is the only
 * thing that actually presses keys, so when it cannot start — a missing or quarantined
 * binary, a permission the system withheld — the button would otherwise do nothing at all
 * and give no hint why. A log file nobody opens is not feedback.
 */
let lastPressed = null;

function helperFailed(reason) {
	streamDeck.logger.error(reason);
	if (lastPressed) reported(lastPressed.showAlert());
}

function send(line) {
	if (!helper || helper.exitCode !== null) {
		helper = spawn(HELPER, [], { stdio: ["pipe", "pipe", "pipe"] });
		helper.on("error", (err) => helperFailed(`helper failed to start: ${err}`));
		helper.on("exit", (code, signal) => {
			// Code 0 is the helper shutting down with the plugin, which is not a failure.
			if (code) helperFailed(`helper exited with code ${code}`);
			else if (signal) helperFailed(`helper was killed by ${signal}`);
		});
		helper.stderr.on("data", (data) => streamDeck.logger.error(`helper: ${data}`));

		// The helper only talks back while capturing, and every reply is one line.
		let pending = "";
		helper.stdout.on("data", (data) => {
			pending += data.toString();
			const lines = pending.split("\n");
			pending = lines.pop() ?? "";
			for (const reply of lines) {
				if (reply) onHelperReply(reply.trim());
			}
		});
	}
	try {
		helper.stdin.write(`${line}\n`);
	} catch (err) {
		helperFailed(`could not reach the helper: ${err}`);
	}
}

/**
 * Recording a combination cannot be done in the property inspector alone. It is a web
 * view, so by the time a keystroke arrives the system has already acted on it — recording
 * ⌃⌥⌘T would fire whatever ⌃⌥⌘T is bound to instead of recording it, which defeats the
 * entire point of a plugin for hotkeys that are already taken. The helper taps the
 * keyboard, swallows the keys, and reports them here; we relay them to the inspector.
 */
function onHelperReply(reply) {
	const [kind, ...rest] = reply.split(" ");
	if (kind === "CAPTURE") {
		reported(streamDeck.ui.sendToPropertyInspector({ event: "capture", state: rest[0] }));
		return;
	}
	if (kind === "K" && rest.length === 2) {
		reported(streamDeck.ui.sendToPropertyInspector({
			event: "key",
			down: rest[0] === "D",
			name: rest[1],
		}));
	}
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
 * The helper keys holds by id so two pedals held at once release only their own keys.
 * Every press gets a fresh id: with a pause configured, a release sequence outlives the
 * press, and a re-press during that window must not have its brand-new hold torn down by
 * the previous sequence's release. Stream Deck ids are opaque, so strip anything that
 * would confuse a space-delimited protocol.
 */
let holdCount = 0;

function nextHoldId(actionId) {
	holdCount += 1;
	return `${String(actionId).replace(/\s+/g, "")}-${holdCount}`;
}

/**
 * Milliseconds to wait, clamped to something a person could plausibly want. An app that
 * drops a hotkey arriving in the same millisecond as the release needs a gap of tens of
 * milliseconds; anything past a few seconds is a misconfiguration.
 */
const MAX_PAUSE_MS = 5000;

function pauseOf(settings, name) {
	const value = Math.round(Number(settings?.[name]));
	if (!Number.isFinite(value) || value <= 0) return 0;
	return Math.min(value, MAX_PAUSE_MS);
}

function pause(ms) {
	return new Promise((resolve) => setTimeout(resolve, ms));
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

function beginHold(actionId, settings, { endsAfterMs = MAX_HOLD_MS, onDeadline } = {}) {
	const previous = finishHold(actionId);
	const id = nextHoldId(actionId);
	const heldCombo = comboOf(settings);
	if (heldCombo) send(`D ${id} ${comboFields(heldCombo)}`);
	holding.set(actionId, {
		id,
		held: !!heldCombo,
		preReleaseCombo: comboOf(settings, "preRelease"),
		releaseCombo: comboOf(settings, "release"),
		pauseBeforeRelease: pauseOf(settings, "pauseBeforeReleaseMs"),
		pauseAfterRelease: pauseOf(settings, "pauseAfterReleaseMs"),
		// For Timed Tap the deadline is the feature, not a backstop, so it passes its own
		// duration and a handler that does not log the release as a fault.
		deadline: setTimeout(() => {
			if (onDeadline) onDeadline();
			else streamDeck.logger.warn(`hold on ${actionId} passed ${endsAfterMs}ms; releasing it`);
			reported(finishHold(actionId));
		}, endsAfterMs),
	});
	return previous;
}

/**
 * Order matters and is the whole point of having two slots: the first tap lands on top of
 * the hold while it is still down, the second after it is gone. An app whose push-to-talk
 * ends on a separate hotkey needs one or the other, and which one is not something we can
 * guess.
 */
function finishHold(actionId) {
	const hold = holding.get(actionId);
	if (!hold) return Promise.resolve();
	holding.delete(actionId);
	clearTimeout(hold.deadline);

	if (hold.preReleaseCombo) send(`T ${comboFields(hold.preReleaseCombo)}`);
	if (!hold.pauseBeforeRelease && !hold.pauseAfterRelease) {
		if (hold.held) send(`U ${hold.id}`);
		if (hold.releaseCombo) send(`T ${comboFields(hold.releaseCombo)}`);
		return Promise.resolve();
	}
	return releaseAfterPauses(hold);
}

/**
 * The paused path is separate so the common case — no pauses configured — stays a
 * straight line of writes with no await between the tap and the release.
 */
async function releaseAfterPauses(hold) {
	if (hold.pauseBeforeRelease) await pause(hold.pauseBeforeRelease);
	if (hold.held) send(`U ${hold.id}`);
	if (hold.pauseAfterRelease) await pause(hold.pauseAfterRelease);
	if (hold.releaseCombo) send(`T ${comboFields(hold.releaseCombo)}`);
}

// A pause makes releasing asynchronous, so the handlers hand the promise back rather than
// dropping it. Nothing waits on the result, but a failure has to reach the log.
function reported(release) {
	return release.catch((err) => streamDeck.logger.error(`release failed: ${err}`));
}

const ACTIONS = {
	hold: "com.johnbindel.keyhold.hold",
	toggle: "com.johnbindel.keyhold.toggle",
	timed: "com.johnbindel.keyhold.timed",
	repeat: "com.johnbindel.keyhold.repeat",
};

/** Off and on images for the two actions that show whether they are currently holding. */
const OFF = 0;
const ON = 1;

function numberOf(settings, name, { min, max, fallback }) {
	const value = Math.round(Number(settings?.[name]));
	if (!Number.isFinite(value) || value <= 0) return fallback;
	return Math.min(Math.max(value, min), max);
}

/**
 * Repeat Key sends taps rather than holding, so it needs its own bookkeeping: nothing is
 * ever down between taps, and there is no hold for the helper to release.
 */
const repeating = new Map();

function startRepeat(actionId, settings) {
	stopRepeat(actionId);
	const combo = comboOf(settings);
	if (!combo) return;
	const perSecond = numberOf(settings, "repeatsPerSecond", { min: 1, max: 20, fallback: 8 });

	send(`T ${comboFields(combo)}`);
	const timer = setInterval(() => send(`T ${comboFields(combo)}`), Math.round(1000 / perSecond));
	// The same backstop the holds get: a repeat left running because a key-up was lost
	// would type forever.
	const deadline = setTimeout(() => {
		streamDeck.logger.warn(`repeat on ${actionId} passed ${MAX_HOLD_MS}ms; stopping it`);
		stopRepeat(actionId);
	}, MAX_HOLD_MS);
	repeating.set(actionId, { timer, deadline });
}

function stopRepeat(actionId) {
	const repeat = repeating.get(actionId);
	if (!repeat) return;
	repeating.delete(actionId);
	clearInterval(repeat.timer);
	clearTimeout(repeat.deadline);
}

/** Press to start holding, press again to let go. */
function toggleHold(ev) {
	if (holding.has(ev.action.id)) {
		return Promise.all([finishHold(ev.action.id), ev.action.setState(OFF)]);
	}
	const seconds = numberOf(ev.payload.settings, "autoReleaseSeconds", {
		min: 5, max: 3600, fallback: MAX_HOLD_MS / 1000,
	});
	return Promise.all([
		beginHold(ev.action.id, ev.payload.settings, {
			endsAfterMs: seconds * 1000,
			onDeadline: () => reported(ev.action.setState(OFF)),
		}),
		ev.action.setState(ON),
	]);
}

streamDeck.actions.onKeyDown((ev) => {
	lastPressed = ev.action;
	switch (ev.action.manifestId) {
		case ACTIONS.toggle:
			return reported(toggleHold(ev));
		case ACTIONS.timed:
			return reported(beginHold(ev.action.id, ev.payload.settings, {
				endsAfterMs: numberOf(ev.payload.settings, "holdForMs", {
					min: 10, max: 10000, fallback: 80,
				}),
				onDeadline: () => {},
			}));
		case ACTIONS.repeat:
			startRepeat(ev.action.id, ev.payload.settings);
			return Promise.resolve();
		default:
			return reported(Promise.all([
				beginHold(ev.action.id, ev.payload.settings),
				ev.action.setState(ON),
			]));
	}
});

streamDeck.actions.onKeyUp((ev) => {
	lastPressed = ev.action;
	switch (ev.action.manifestId) {
		// Toggle Hold is driven entirely by key-down, and Timed Tap by its own timer.
		case ACTIONS.toggle:
		case ACTIONS.timed:
			return Promise.resolve();
		case ACTIONS.repeat:
			stopRepeat(ev.action.id);
			return Promise.resolve();
		default:
			return reported(Promise.all([
				finishHold(ev.action.id),
				ev.action.setState(OFF),
			]));
	}
});

// The button is going away — switched profile, unplugged device, page change. Its key-up
// may never arrive, so let go now rather than leave the key down. This applies to every
// action, including the latch, which is otherwise happy to stay on indefinitely.
streamDeck.actions.onWillDisappear((ev) => {
	stopRepeat(ev.action.id);
	return reported(finishHold(ev.action.id));
});

// The inspector asks for the keyboard while a recorder field has focus, and gives it back
// the moment recording ends.
streamDeck.ui.onSendToPlugin((ev) => {
	if (ev.payload?.event === "startCapture") send("C 1");
	if (ev.payload?.event === "stopCapture") send("C 0");
});

// Closing the inspector mid-recording must not leave the keyboard swallowed. The helper
// times out by itself too, but that is the backstop, not the mechanism.
streamDeck.ui.onDidDisappear(() => send("C 0"));

streamDeck.connect();
