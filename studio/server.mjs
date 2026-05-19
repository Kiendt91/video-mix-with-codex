import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, "..");
const publicRoot = path.join(__dirname, "public");
const jobs = new Map();
let nextJobId = 1;

const port = Number(process.env.VIDEO_MIX_STUDIO_PORT || process.env.PORT || 4327);
const configDir = path.join(process.env.APPDATA || os.homedir(), "video-mix-with-codex");
const aiSettingsPath = path.join(configDir, "ai-settings.json");

const providerDefaults = {
  openai: {
    label: "OpenAI",
    type: "openai-compatible",
    baseUrl: "https://api.openai.com/v1",
    apiKeyEnv: "OPENAI_API_KEY",
    model: "gpt-4.1",
  },
  anthropic: {
    label: "Claude / Anthropic",
    type: "anthropic",
    baseUrl: "https://api.anthropic.com",
    apiKeyEnv: "ANTHROPIC_API_KEY",
    model: "claude-3-5-sonnet-latest",
  },
  gemini: {
    label: "Gemini",
    type: "gemini",
    baseUrl: "https://generativelanguage.googleapis.com/v1beta",
    apiKeyEnv: "GEMINI_API_KEY",
    model: "gemini-1.5-pro",
  },
  grok: {
    label: "Grok / xAI",
    type: "openai-compatible",
    baseUrl: "https://api.x.ai/v1",
    apiKeyEnv: "XAI_API_KEY",
    model: "grok-2-latest",
  },
  custom: {
    label: "Custom OpenAI-compatible",
    type: "openai-compatible",
    baseUrl: "http://127.0.0.1:11434/v1",
    apiKeyEnv: "",
    model: "local-model",
  },
};

const defaultTaskRouting = {
  draftEdl: { provider: "openai", model: "", temperature: 0.2 },
  repairEdl: { provider: "openai", model: "", temperature: 0.1 },
  reviewQa: { provider: "anthropic", model: "", temperature: 0.2 },
  shotSelection: { provider: "gemini", model: "", temperature: 0.2 },
  scriptToPlan: { provider: "openai", model: "", temperature: 0.3 },
};

function json(res, status, payload) {
  const body = JSON.stringify(payload, null, 2);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
  });
  res.end(body);
}

function text(res, status, body, contentType = "text/plain; charset=utf-8") {
  res.writeHead(status, {
    "content-type": contentType,
    "cache-control": "no-store",
  });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => {
      if (chunks.length === 0) {
        resolve({});
        return;
      }
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString("utf8")));
      } catch (error) {
        reject(error);
      }
    });
    req.on("error", reject);
  });
}

function addArg(args, name, value) {
  if (value === undefined || value === null || value === "") return;
  args.push(name, String(value));
}

function addSwitch(args, name, value) {
  if (value) args.push(name);
}

function runPowerShell(scriptRelativePath, args, label) {
  const id = String(nextJobId++);
  const startedAt = new Date().toISOString();
  const job = {
    id,
    label,
    status: "running",
    startedAt,
    finishedAt: null,
    exitCode: null,
    command: ["powershell", "-ExecutionPolicy", "Bypass", "-File", scriptRelativePath, ...args].join(" "),
    logs: [],
  };
  jobs.set(id, job);

  const child = spawn(
    "powershell",
    ["-ExecutionPolicy", "Bypass", "-File", path.join(repoRoot, scriptRelativePath), ...args],
    { cwd: repoRoot, windowsHide: true },
  );

  const append = (kind, chunk) => {
    const lines = chunk.toString("utf8").split(/\r?\n/);
    for (const line of lines) {
      if (line.length > 0) job.logs.push({ time: new Date().toISOString(), kind, line });
    }
    if (job.logs.length > 2000) job.logs.splice(0, job.logs.length - 2000);
  };

  child.stdout.on("data", (chunk) => append("stdout", chunk));
  child.stderr.on("data", (chunk) => append("stderr", chunk));
  child.on("error", (error) => {
    job.status = "failed";
    job.finishedAt = new Date().toISOString();
    job.logs.push({ time: job.finishedAt, kind: "error", line: error.message });
  });
  child.on("close", (code) => {
    job.exitCode = code;
    job.finishedAt = new Date().toISOString();
    job.status = code === 0 ? "completed" : "failed";
  });

  return job;
}

function sanitizeName(value) {
  return String(value || "video-mix-project")
    .replace(/[<>:"/\\|?*\u0000-\u001f]/g, "-")
    .replace(/\s+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "")
    .slice(0, 80) || "video-mix-project";
}

function ensureDir(dir) {
  mkdirSync(dir, { recursive: true });
}

function readJsonIfExists(filePath) {
  if (!filePath || !existsSync(filePath)) return null;
  return JSON.parse(readFileSync(filePath, "utf8"));
}

function mergeAiSettings(saved = {}) {
  const providers = {};
  for (const [id, defaults] of Object.entries(providerDefaults)) {
    providers[id] = {
      ...defaults,
      ...(saved.providers?.[id] || {}),
    };
  }
  return {
    providers,
    tasks: {
      ...defaultTaskRouting,
      ...(saved.tasks || {}),
    },
  };
}

function readAiSettings() {
  return mergeAiSettings(readJsonIfExists(aiSettingsPath) || {});
}

function publicAiSettings(settings = readAiSettings()) {
  const providers = {};
  for (const [id, provider] of Object.entries(settings.providers || {})) {
    const apiKey = provider.apiKey || process.env[provider.apiKeyEnv || ""];
    providers[id] = {
      ...provider,
      apiKey: "",
      hasApiKey: Boolean(apiKey),
    };
  }
  return {
    configPath: aiSettingsPath,
    providers,
    tasks: settings.tasks || {},
  };
}

function saveAiSettings(input) {
  const current = readAiSettings();
  const providers = { ...current.providers };
  for (const [id, incoming] of Object.entries(input.providers || {})) {
    const previous = providers[id] || providerDefaults[id] || {};
    const next = { ...previous, ...incoming };
    if (!incoming.apiKey) {
      next.apiKey = incoming.clearApiKey ? "" : previous.apiKey || "";
    }
    if (incoming.clearApiKey) next.apiKey = "";
    delete next.hasApiKey;
    delete next.clearApiKey;
    providers[id] = next;
  }
  const tasks = { ...current.tasks, ...(input.tasks || {}) };
  ensureDir(configDir);
  writeFileSync(aiSettingsPath, JSON.stringify({ providers, tasks }, null, 2), "utf8");
  return readAiSettings();
}

function resolveProviderForTask(taskName, override = {}) {
  const settings = readAiSettings();
  const routing = { ...(settings.tasks?.[taskName] || {}), ...override };
  const providerId = routing.provider || "openai";
  const provider = settings.providers?.[providerId];
  if (!provider) throw new Error(`Unknown AI provider: ${providerId}`);
  const apiKey = provider.apiKey || process.env[provider.apiKeyEnv || ""];
  if (!apiKey && provider.type !== "openai-compatible") {
    throw new Error(`Missing API key for ${provider.label || providerId}. Save one in AI settings or set ${provider.apiKeyEnv}.`);
  }
  return {
    providerId,
    provider,
    apiKey,
    model: routing.model || provider.model,
    temperature: routing.temperature ?? 0.2,
  };
}

function stripJsonFence(textValue) {
  const text = String(textValue || "").trim();
  const fenced = text.match(/```(?:json)?\s*([\s\S]*?)```/i);
  return (fenced ? fenced[1] : text).trim();
}

async function callAiProvider(task, prompt, override = {}) {
  const route = resolveProviderForTask(task, override);
  const { provider, apiKey, model, temperature } = route;
  if (!globalThis.fetch) throw new Error("Node fetch is not available. Use Node.js 18+.");

  if (provider.type === "anthropic") {
    const response = await fetch(`${provider.baseUrl.replace(/\/$/, "")}/v1/messages`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": apiKey,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model,
        max_tokens: 8192,
        temperature,
        messages: [{ role: "user", content: prompt }],
      }),
    });
    const data = await response.json();
    if (!response.ok) throw new Error(data.error?.message || `Anthropic request failed: ${response.status}`);
    return data.content?.map((part) => part.text || "").join("\n").trim() || "";
  }

  if (provider.type === "gemini") {
    const url = `${provider.baseUrl.replace(/\/$/, "")}/models/${encodeURIComponent(model)}:generateContent?key=${encodeURIComponent(apiKey)}`;
    const response = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        contents: [{ role: "user", parts: [{ text: prompt }] }],
        generationConfig: { temperature },
      }),
    });
    const data = await response.json();
    if (!response.ok) throw new Error(data.error?.message || `Gemini request failed: ${response.status}`);
    return data.candidates?.[0]?.content?.parts?.map((part) => part.text || "").join("\n").trim() || "";
  }

  const headers = { "content-type": "application/json" };
  if (apiKey) headers.authorization = `Bearer ${apiKey}`;
  const response = await fetch(`${provider.baseUrl.replace(/\/$/, "")}/chat/completions`, {
    method: "POST",
    headers,
    body: JSON.stringify({
      model,
      temperature,
      messages: [
        { role: "system", content: "You are an expert music-video edit planner. Follow the requested output format exactly." },
        { role: "user", content: prompt },
      ],
    }),
  });
  const data = await response.json();
  if (!response.ok) throw new Error(data.error?.message || `OpenAI-compatible request failed: ${response.status}`);
  return data.choices?.[0]?.message?.content?.trim() || "";
}

function collectAiContext(body) {
  const chunks = [];
  chunks.push(`# Task\n${body.task || "draftEdl"}`);
  if (body.brief) chunks.push(`# Brief\n${body.brief}`);
  if (body.sources) chunks.push(`# Sources\n${body.sources}`);
  if (body.musicPath) chunks.push(`# Music Path\n${body.musicPath}`);
  if (body.musicUrl) chunks.push(`# Music URL\n${body.musicUrl}`);
  if (body.mode) chunks.push(`# Mode\n${body.mode}`);

  const fileInputs = [
    ["EDL", body.edl],
    ["Media metadata", body.mediaMetadata],
    ["Candidate audit", body.candidateAudit],
    ["QA summary", body.qaSummary],
    ["Existing brief", body.briefPath],
  ];
  for (const [label, filePath] of fileInputs) {
    if (!filePath || !existsSync(filePath)) continue;
    const textValue = readFileSync(filePath, "utf8").slice(0, 120000);
    chunks.push(`# ${label}: ${filePath}\n${textValue}`);
  }

  const task = body.task || "draftEdl";
  if (task === "draftEdl") {
    chunks.push(`# Output contract
Return only valid JSON for an EDL matching this repo's schema. Include project, music, shots, and captions/dialogue arrays as needed. Every shot must include id, source, sourceStart, timelineStart, duration, audioRole, storyBeat, musicBeat, transition, and visualRisk.`);
  } else if (task === "repairEdl") {
    chunks.push("# Output contract\nReturn only the corrected EDL JSON. Do not include markdown.");
  } else {
    chunks.push("# Output contract\nReturn concise markdown with concrete findings and next actions.");
  }
  return chunks.join("\n\n");
}

function runAiTask(body) {
  const id = String(nextJobId++);
  const startedAt = new Date().toISOString();
  const task = body.task || "draftEdl";
  const job = {
    id,
    label: `ai:${task}`,
    status: "running",
    startedAt,
    finishedAt: null,
    exitCode: null,
    command: `ai ${task}`,
    logs: [],
    outputPath: null,
    resultPreview: null,
  };
  jobs.set(id, job);

  queueMicrotask(async () => {
    try {
      const prompt = body.prompt || collectAiContext(body);
      const route = resolveProviderForTask(task, {
        provider: body.provider,
        model: body.model,
        temperature: body.temperature,
      });
      job.logs.push({ time: new Date().toISOString(), kind: "info", line: `Provider: ${route.provider.label} / ${route.model}` });
      const result = await callAiProvider(task, prompt, {
        provider: body.provider,
        model: body.model,
        temperature: body.temperature,
      });
      const workDir = body.workDir ? path.resolve(body.workDir) : repoRoot;
      ensureDir(path.join(workDir, "ai"));
      const stamp = new Date().toISOString().replace(/[:.]/g, "-");
      const outputPath = body.outputPath || path.join(workDir, "ai", `${task}-${stamp}.txt`);
      writeFileSync(outputPath, result, "utf8");
      job.outputPath = outputPath;
      job.logs.push({ time: new Date().toISOString(), kind: "stdout", line: `AI output written to: ${outputPath}` });

      if (task === "draftEdl" || task === "repairEdl") {
        try {
          const parsed = JSON.parse(stripJsonFence(result));
          const edlOutput = body.edlOutput || path.join(workDir, task === "draftEdl" ? "edl.ai-draft.json" : "edl.ai-repaired.json");
          writeFileSync(edlOutput, JSON.stringify(parsed, null, 2), "utf8");
          job.logs.push({ time: new Date().toISOString(), kind: "stdout", line: `Parsed EDL JSON written to: ${edlOutput}` });
        } catch (error) {
          job.logs.push({ time: new Date().toISOString(), kind: "stderr", line: `Could not parse AI output as EDL JSON: ${error.message}` });
        }
      }

      job.resultPreview = result.slice(0, 2000);
      job.exitCode = 0;
      job.status = "completed";
    } catch (error) {
      job.exitCode = 1;
      job.status = "failed";
      job.logs.push({ time: new Date().toISOString(), kind: "error", line: error instanceof Error ? error.message : String(error) });
    } finally {
      job.finishedAt = new Date().toISOString();
    }
  });

  return job;
}

function createBrief(body) {
  if (!body.workDir) throw new Error("workDir is required.");
  const workDir = path.resolve(body.workDir);
  ensureDir(workDir);
  const briefPath = path.join(workDir, "ai-edit-brief.md");
  const title = body.title || sanitizeName(path.basename(workDir));
  const lines = [
    `# ${title}`,
    "",
    "## Inputs",
    `- WorkDir: ${workDir}`,
    `- Sources: ${body.sources || ""}`,
    `- Music URL: ${body.musicUrl || ""}`,
    `- Music Path: ${body.musicPath || ""}`,
    `- Style: ${body.mode || "Cinematic"}`,
    `- Output: ${body.outputName || ""}`,
    "",
    "## Edit Brief",
    body.brief || "(No brief text supplied.)",
    "",
    "## Required Output",
    "- Create an EDL JSON first.",
    "- Use source contact sheets and candidate audit before rendering.",
    "- Keep source videos muted unless dialogue is explicitly listed.",
    "- Run final QA and generate the review UI.",
    "",
    "## Suggested Commands",
    "```powershell",
    `.\\scripts\\Invoke-VideoMixPipeline.ps1 -WorkDir "${workDir}" -Sources "${body.sources || ""}" ${body.musicUrl ? `-MusicUrl "${body.musicUrl}"` : ""} ${body.musicPath ? `-MusicPath "${body.musicPath}"` : ""}`,
    "```",
    "",
  ];
  writeFileSync(briefPath, lines.join("\n"), "utf8");
  return briefPath;
}

function buildPipelineArgs(body) {
  const args = [];
  addArg(args, "-WorkDir", body.workDir);
  addArg(args, "-Sources", body.sources);
  addArg(args, "-MusicUrl", body.musicUrl);
  addArg(args, "-MusicPath", body.musicPath);
  addArg(args, "-Edl", body.edl);
  addArg(args, "-Mode", body.mode || "Cinematic");
  addArg(args, "-ProjectDir", body.projectDir);
  addArg(args, "-GsapPath", body.gsapPath);
  addArg(args, "-RenderOutput", body.renderOutput);
  addSwitch(args, "-Render", body.render);
  addSwitch(args, "-CreateReview", body.createReview);
  addSwitch(args, "-UseOcr", body.useOcr);
  addSwitch(args, "-SkipSourceAudit", body.skipSourceAudit);
  addSwitch(args, "-SkipCandidateAudit", body.skipCandidateAudit);
  addSwitch(args, "-Force", body.force);
  return args;
}

function serveStatic(req, res, pathname) {
  const requested = pathname === "/" ? "/index.html" : pathname;
  const filePath = path.resolve(publicRoot, "." + requested);
  if (!filePath.startsWith(publicRoot)) {
    text(res, 403, "Forbidden");
    return;
  }
  if (!existsSync(filePath) || !statSync(filePath).isFile()) {
    text(res, 404, "Not found");
    return;
  }
  const ext = path.extname(filePath).toLowerCase();
  const type = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".svg": "image/svg+xml",
  }[ext] || "application/octet-stream";
  text(res, 200, readFileSync(filePath), type);
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url || "/", `http://${req.headers.host || "localhost"}`);
  try {
    if (req.method === "GET" && url.pathname.startsWith("/api/jobs/")) {
      const id = url.pathname.split("/").pop();
      const job = jobs.get(id);
      if (!job) {
        json(res, 404, { error: "Job not found" });
        return;
      }
      json(res, 200, job);
      return;
    }

    if (req.method === "GET" && url.pathname === "/api/health") {
      json(res, 200, {
        ok: true,
        repoRoot,
        port,
        node: process.version,
        aiSettingsPath,
      });
      return;
    }

    if (req.method === "GET" && url.pathname === "/api/ai/settings") {
      json(res, 200, publicAiSettings());
      return;
    }

    if (req.method === "POST" && url.pathname === "/api/ai/settings") {
      const body = await readBody(req);
      const settings = saveAiSettings(body);
      json(res, 200, publicAiSettings(settings));
      return;
    }

    if (req.method === "POST" && url.pathname === "/api/ai/run-task") {
      const body = await readBody(req);
      const job = runAiTask(body);
      json(res, 202, job);
      return;
    }

    if (req.method === "POST" && url.pathname === "/api/jobs/pipeline") {
      const body = await readBody(req);
      const job = runPowerShell("scripts/Invoke-VideoMixPipeline.ps1", buildPipelineArgs(body), "pipeline");
      json(res, 202, job);
      return;
    }

    if (req.method === "POST" && url.pathname === "/api/jobs/review") {
      const body = await readBody(req);
      const args = [];
      addArg(args, "-ProjectDir", body.projectDir);
      addArg(args, "-Edl", body.edl);
      addArg(args, "-FinalMp4", body.finalMp4);
      addArg(args, "-QaDir", body.qaDir);
      addArg(args, "-CandidateAuditDir", body.candidateAuditDir);
      addArg(args, "-OutDir", body.outDir);
      addArg(args, "-Title", body.title);
      const job = runPowerShell("scripts/New-EditReview.ps1", args, "review");
      json(res, 202, job);
      return;
    }

    if (req.method === "POST" && url.pathname === "/api/jobs/qa") {
      const body = await readBody(req);
      const args = [];
      addArg(args, "-ProjectDir", body.projectDir);
      addArg(args, "-FinalMp4", body.finalMp4);
      addArg(args, "-Edl", body.edl);
      addSwitch(args, "-CreateContactSheet", true);
      addSwitch(args, "-FailOnBlackFrames", body.failOnBlackFrames);
      const job = runPowerShell("scripts/Test-VideoMix.ps1", args, "qa");
      json(res, 202, job);
      return;
    }

    if (req.method === "POST" && url.pathname === "/api/brief") {
      const body = await readBody(req);
      const briefPath = createBrief(body);
      json(res, 201, {
        briefPath,
        briefUrl: pathToFileURL(briefPath).href,
      });
      return;
    }

    serveStatic(req, res, decodeURIComponent(url.pathname));
  } catch (error) {
    json(res, 500, { error: error instanceof Error ? error.message : String(error) });
  }
});

server.listen(port, "127.0.0.1", () => {
  console.log(`Video Mix Studio: http://127.0.0.1:${port}`);
  console.log(`Repo: ${repoRoot}`);
});
