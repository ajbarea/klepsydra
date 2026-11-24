import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { engineInfo, card } from "./fleet/model.js";

const read = (p) => readFileSync(new URL(p, import.meta.url), "utf8");

test("engineInfo maps harness and model to maker and tooltip", () => {
  // agy running Claude Opus 4.6 (AJ's exact 11-14 example)
  const agyClaude = engineInfo("agy", "Claude Opus 4.6");
  assert.equal(agyClaude.engine, "agy");
  assert.equal(agyClaude.harness, "agy");
  assert.equal(agyClaude.model, "Claude Opus 4.6");
  assert.equal(agyClaude.maker, "anthropic");
  assert.equal(agyClaude.makerLabel, "Anthropic");
  assert.equal(agyClaude.tooltip, "agy \u00b7 Claude Opus 4.6");
  assert.equal(agyClaude.ariaLabel, "agy running Claude Opus 4.6");

  // agy running Gemini
  const agyGemini = engineInfo("agy", "Gemini 3.8 Flash High");
  assert.equal(agyGemini.maker, "gemini");
  assert.equal(agyGemini.tooltip, "agy \u00b7 Gemini 3.8 Flash High");

  // copilot running GPT-4o
  const copilotGpt = engineInfo("copilot", "GPT-4o");
  assert.equal(copilotGpt.engine, "copilot");
  assert.equal(copilotGpt.harness, "Copilot");
  assert.equal(copilotGpt.maker, "openai");
  assert.equal(copilotGpt.tooltip, "Copilot \u00b7 GPT-4o");

  // copilot running Claude Sonnet
  const copilotClaude = engineInfo("copilot", "Claude 3.5 Sonnet");
  assert.equal(copilotClaude.maker, "anthropic");
  assert.equal(copilotClaude.tooltip, "Copilot \u00b7 Claude 3.5 Sonnet");

  // agy running local Meta Llama
  const agyLlama = engineInfo("agy", "Meta-Llama-3.1-70B");
  assert.equal(agyLlama.maker, "meta");
  assert.equal(agyLlama.tooltip, "agy \u00b7 Meta-Llama-3.1-70B");

  // Claude Code running Opus
  const claudeOpus = engineInfo("claude", "Opus 4.6");
  assert.equal(claudeOpus.maker, "anthropic");
  assert.equal(claudeOpus.tooltip, "Claude \u00b7 Opus 4.6");

  // Defaults when no model is specified
  const claudeDefault = engineInfo("claude", null);
  assert.equal(claudeDefault.maker, "anthropic");
  assert.equal(claudeDefault.tooltip, "Claude");

  const agyDefault = engineInfo("agy", null);
  assert.equal(agyDefault.maker, "gemini");
  assert.equal(agyDefault.tooltip, "agy");

  const copilotDefault = engineInfo("copilot", null);
  assert.equal(copilotDefault.maker, "copilot");
  assert.equal(copilotDefault.tooltip, "Copilot");

  // No known engine and no model yields null
  assert.equal(engineInfo(null, null), null);

  // Statusline object model handling
  const statusModel = engineInfo("agy", { id: "gemini-3.8-flash", display_name: "Gemini 3.8 Flash" });
  assert.equal(statusModel.model, "Gemini 3.8 Flash");
  assert.equal(statusModel.maker, "gemini");
  assert.equal(statusModel.tooltip, "agy \u00b7 Gemini 3.8 Flash");
});

test("card() extracts engine, model, and in-flight delegate status", () => {
  const CAST = { characters: {} };
  const now = Date.now();

  // Claude session default
  const c1 = card({ session_id: "s1" }, CAST, now);
  assert.equal(c1.engine, "claude");
  assert.equal(c1.maker, "anthropic");
  assert.equal(c1.engineInfo.tooltip, "Claude");
  assert.equal(c1.delegate, null);

  // agy interactive session with Claude Opus
  const c2 = card({ session_id: "s2", engine: "agy", model: "Claude Opus 4.6" }, CAST, now);
  assert.equal(c2.engine, "agy");
  assert.equal(c2.maker, "anthropic");
  assert.equal(c2.model, "Claude Opus 4.6");
  assert.equal(c2.engineInfo.tooltip, "agy \u00b7 Claude Opus 4.6");

  // In-flight delegate chip from background
  const c3 = card({ session_id: "s3", background: { delegate: "agy" } }, CAST, now);
  assert.equal(c3.delegate, "agy");

  // In-flight delegate chip as object
  const c4 = card({ session_id: "s4", delegate: { engine: "copilot" } }, CAST, now);
  assert.equal(c4.delegate, "copilot");
});

test("wall.html and wall.css contain engine-badge and delegate elements", () => {
  const html = read("./wall.html");
  assert.match(html, /<span class="engine-badge" hidden><\/span>/, "engine-badge in wall.html");
  assert.match(html, /<p class="where">[\s\S]*?<span class="engine-badge" hidden><\/span>[\s\S]*?<a class="gh"/, "engine-badge placed beside repo and GitHub mark");
  assert.match(html, /<p class="crew-line" hidden>[\s\S]*?<span class="delegate" hidden><\/span>/, "delegate chip in crew-line");

  const css = read("./fleet/wall.css");
  assert.match(css, /\.engine-badge \{ display: inline-flex; flex: none; color: var\(--text-dim\); \}/);
  assert.match(css, /\.engine-badge svg \{ width: 14px; height: 14px; \}/);
  assert.match(css, /\.crew-line \.delegate \{ display: inline-flex;/);
});
