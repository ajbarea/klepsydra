import { test } from "node:test";
import assert from "node:assert/strict";
import {
  pickDefaultEngine,
  extractLastEngineUsed,
  computeAccountRoom,
  groupAgyModels,
  buildEngineEntries,
  buildMenuList,
} from "./fleet/newsession.js";

const NOW = 1_795_026_210_000; // Wed Nov 18 2026 ~1:23 PM EST
const secs = (ms) => Math.round(ms / 1000);

test("pickDefaultEngine: user choice takes precedence when installed and signed in", () => {
  const engines = [
    { id: "claude", installed: true, signedIn: true },
    { id: "agy", installed: true, signedIn: true },
    { id: "copilot", installed: false, signedIn: false },
  ];
  const pick = pickDefaultEngine({
    userChoice: "agy",
    lastEngineUsed: "claude",
    engines,
  });
  assert.equal(pick.id, "agy");
  assert.equal(pick.reason, "your chosen default");
});

test("pickDefaultEngine: falls through to lastEngineUsed if user choice is missing or not installed", () => {
  const engines = [
    { id: "claude", installed: true, signedIn: true },
    { id: "agy", installed: false, signedIn: false },
    { id: "copilot", installed: false, signedIn: false },
  ];
  const pick = pickDefaultEngine({
    userChoice: "agy", // not installed
    lastEngineUsed: "claude",
    engines,
  });
  assert.equal(pick.id, "claude");
  assert.equal(pick.reason, "the engine you used last");
});

test("pickDefaultEngine: picks lastEngineUsed when no user choice is set", () => {
  const engines = [
    { id: "claude", installed: true, signedIn: true },
    { id: "agy", installed: true, signedIn: true },
    { id: "copilot", installed: true, signedIn: true },
  ];
  const pick = pickDefaultEngine({
    userChoice: null,
    lastEngineUsed: "agy",
    engines,
  });
  assert.equal(pick.id, "agy");
  assert.equal(pick.reason, "the engine you used last");
});

test("pickDefaultEngine: falls through to first installed and signed in engine when no lastEngineUsed", () => {
  const engines = [
    { id: "claude", installed: false, signedIn: false },
    { id: "agy", installed: true, signedIn: true },
    { id: "copilot", installed: true, signedIn: true },
  ];
  const pick = pickDefaultEngine({
    userChoice: null,
    lastEngineUsed: null,
    engines,
  });
  assert.equal(pick.id, "agy");
  assert.equal(pick.reason, "the first installed and signed-in engine");
});

test("extractLastEngineUsed: gets engine from newest session", () => {
  const sessions = [
    { session_id: "s1", status_at: 1000, engine: "claude" },
    { session_id: "s2", status_at: 2000, engine: "agy" },
    { session_id: "s3", status_at: 1500, engine: "claude" },
  ];
  assert.equal(extractLastEngineUsed(sessions), "agy");
});

test("extractLastEngineUsed: falls back when sessions list is empty", () => {
  assert.equal(extractLastEngineUsed([], "claude"), "claude");
  assert.equal(extractLastEngineUsed(null, "claude"), "claude");
});

test("computeAccountRoom: formats room remaining from session or week", () => {
  const acct = {
    account: "a1",
    windows: {
      five_hour: { used_percentage: 7.2, resets_at: secs(NOW + 3600e3 * 2) },
      seven_day: { used_percentage: 4.0, resets_at: secs(NOW + 3600e3 * 24 * 6) },
    },
  };
  const room = computeAccountRoom(acct, NOW);
  assert.equal(room.bold, "93%");
  assert.match(room.detail, /session · back to full/);
  assert.equal(room.spent, false);
});

test("computeAccountRoom: formats spent account as out until reset", () => {
  const acct = {
    account: "a2",
    windows: {
      seven_day: { used_percentage: 100, resets_at: secs(NOW + 3600e3 * 4) },
    },
  };
  const room = computeAccountRoom(acct, NOW);
  assert.equal(room.bold, "out");
  assert.match(room.detail, /until/);
  assert.equal(room.spent, true);
});

test("computeAccountRoom: placeholder when no readings exist", () => {
  const room = computeAccountRoom({}, NOW);
  assert.equal(room.bold, "–");
  assert.equal(room.detail, "no reading yet");
  assert.equal(room.spent, false);
});

test("groupAgyModels: groups models into Gemini and Claude & GPT", () => {
  const models = [
    { id: "gemini-3.8-flash-high", label: "Gemini 3.8 Flash (High)" },
    { id: "gemini-3.8-flash-low", label: "Gemini 3.8 Flash (Low)" },
    { id: "claude-sonnet-4-6", label: "Claude Sonnet 4.6 (Thinking)" },
  ];
  const agyUsage = {
    windows: {
      five_hour: { used_percentage: 7, resets_at: secs(NOW + 3600e3 * 2) },
      seven_day: { used_percentage: 4, resets_at: secs(NOW + 3600e3 * 24 * 6) },
      claude_gpt: { used_percentage: 100, resets_at: secs(NOW + 3600e3 * 2.5) },
    },
  };
  const groups = groupAgyModels(models, agyUsage, NOW);
  assert.equal(groups.length, 2);
  assert.equal(groups[0].key, "gemini");
  assert.match(groups[0].label, /Gemini · 93% of the session, 96% of the week/);
  assert.equal(groups[0].models[0].disabled, false);

  assert.equal(groups[1].key, "claude_gpt");
  assert.match(groups[1].label, /Claude & GPT · spent/);
  assert.equal(groups[1].models[0].disabled, true);
  assert.equal(groups[1].models[0].why, "spent");
});

test("groupAgyModels: hides Claude & GPT models when plan has no such group", () => {
  const models = [
    { id: "gemini-3.8-flash-high", label: "Gemini 3.8 Flash (High)" },
    { id: "claude-sonnet-4-6", label: "Claude Sonnet 4.6 (Thinking)" },
  ];
  const agyUsage = {
    windows: {
      five_hour: { used_percentage: 7, resets_at: secs(NOW + 3600e3 * 2) },
      seven_day: { used_percentage: 4, resets_at: secs(NOW + 3600e3 * 24 * 6) },
    },
  };
  const groups = groupAgyModels(models, agyUsage, NOW);
  assert.equal(groups.length, 1);
  assert.equal(groups[0].key, "gemini");
});

test("buildMenuList: default engine is NEVER repeated in the menu list", () => {
  const entries = [
    { id: "claude", engineId: "claude", name: "Claude", installed: true, signedIn: true },
    { id: "agy", engineId: "agy", name: "Antigravity", installed: true, signedIn: true },
    { id: "copilot", engineId: "copilot", name: "Copilot", installed: false, signedIn: false },
  ];
  const menu = buildMenuList(entries, "claude");
  assert.equal(menu.length, 2);
  assert.ok(!menu.some((e) => e.engineId === "claude"), "default engine omitted from menu");
  assert.equal(menu[0].engineId, "agy");
  assert.equal(menu[1].engineId, "copilot");
});

test("buildMenuList: missing engines are marked disabled with reason and action", () => {
  const entries = [
    { id: "claude", engineId: "claude", name: "Claude", installed: true, signedIn: true },
    { id: "agy", engineId: "agy", name: "Antigravity", installed: false, signedIn: false },
    { id: "copilot", engineId: "copilot", name: "Copilot", installed: true, signedIn: false },
  ];
  const menu = buildMenuList(entries, "claude");
  const agy = menu.find((e) => e.engineId === "agy");
  const copilot = menu.find((e) => e.engineId === "copilot");

  assert.equal(agy.disabled, true);
  assert.equal(agy.missingReason, "Not installed on this PC");
  assert.equal(agy.missingAction, "How to install");

  assert.equal(copilot.disabled, true);
  assert.equal(copilot.missingReason, "Installed, not signed in");
  assert.equal(copilot.missingAction, "Sign in");
});
