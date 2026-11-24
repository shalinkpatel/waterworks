import { join } from "node:path";
import { pathToFileURL } from "node:url";

const piRoot = process.env.PI_CODING_AGENT_ROOT;
if (!piRoot) throw new Error("PI_CODING_AGENT_ROOT is required");
const importFromPi = (relative) => import(pathToFileURL(join(piRoot, relative)).href);
const { createAgentSession, DefaultResourceLoader, ModelRuntime, SessionManager, SettingsManager } =
  await importFromPi("dist/index.js");
const { fauxProvider, fauxAssistantMessage, fauxToolCall } = await importFromPi("../pi-ai/dist/providers/faux.js");

const browserId = process.env.WW_BROWSER_ID;
if (!browserId) throw new Error("WW_BROWSER_ID is required");

const agentDir = join(process.cwd(), "tmp/pi-sdk-test");
const modelRuntime = await ModelRuntime.create({
  authPath: join(agentDir, "auth.json"),
  modelsPath: null,
  refreshOnCreate: false,
});
const faux = fauxProvider();
modelRuntime.registerNativeProvider(faux.provider);

function responseFor(context) {
  const text = context.messages
    .flatMap((message) => Array.isArray(message.content) ? message.content : [])
    .filter((block) => block.type === "text")
    .map((block) => block.text)
    .findLast((text) => text.startsWith("Waterworks message\nID: "));
  const id = text?.match(/^ID: (.+)$/m)?.[1];
  if (!id) throw new Error("No Waterworks message in model context");
  return fauxAssistantMessage(
    fauxToolCall("ww_send", {
      to: browserId,
      type: "test.pong.v1",
      payload: { text: "hello from pi" },
      reply_to: id,
    }),
  );
}

faux.setResponses([responseFor, fauxAssistantMessage("done")]);

const resourceLoader = new DefaultResourceLoader({
  cwd: process.cwd(),
  agentDir,
  additionalExtensionPaths: [join(process.cwd(), ".pi/extensions/waterworks.js")],
});
await resourceLoader.reload();

const { session } = await createAgentSession({
  cwd: process.cwd(),
  agentDir,
  model: faux.getModel(),
  modelRuntime,
  resourceLoader,
  sessionManager: SessionManager.inMemory(process.cwd()),
  settingsManager: SettingsManager.inMemory({
    compaction: { enabled: false },
    retry: { enabled: false },
  }),
});

await session.bindExtensions({ mode: "json" });

session.subscribe((event) => {
  if (event.type === "agent_settled" && faux.getPendingResponseCount() === 0) {
    faux.appendResponses([responseFor, fauxAssistantMessage("done")]);
  }
});

process.on("SIGTERM", () => session.dispose());
process.on("SIGINT", () => session.dispose());
await new Promise(() => {});
