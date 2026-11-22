const { randomUUID } = require("node:crypto");
const { appendFileSync } = require("node:fs");
const { createServer } = require("node:http");

const model = "asb-local";
const eventsFile = process.argv[2];

createServer(async (request, response) => {
  if (request.headers.authorization !== "Bearer asb-local") {
    response.writeHead(401).end();
    return;
  }
  if (request.method === "GET" && request.url === "/v1/models") {
    response.writeHead(200, { "Content-Type": "application/json" });
    response.end(JSON.stringify({ object: "list", data: [{ id: model, object: "model" }] }));
    return;
  }
  if (request.method !== "POST" || request.url !== "/v1/chat/completions") {
    response.writeHead(404).end();
    return;
  }

  let raw = "";
  for await (const chunk of request) raw += chunk;
  let body;
  try {
    body = JSON.parse(raw);
  } catch {
    response.writeHead(400).end("Expected a JSON chat request");
    return;
  }
  // OpenClaw can append another user message after the original prompt.
  if (body?.model !== model || body.stream !== true || !Array.isArray(body.messages)) {
    response.writeHead(400).end("Expected a streaming asb-local chat request");
    return;
  }
  const userText = body.messages
    .filter(message => message.role === "user")
    .flatMap(message => Array.isArray(message.content)
      ? message.content.filter(part => part.type === "text").map(part => part.text)
      : [message.content])
    .join("\n");
  const nonce = userText.match(/\basb-check-([a-f0-9]{32})\b/)?.[1];
  if (!nonce) {
    response.writeHead(400).end("Missing asb-check ID in user text");
    return;
  }

  const receipt = "receipt-" + randomUUID();
  appendFileSync(eventsFile, JSON.stringify({ nonce, receipt }) + "\n", { mode: 0o600 });
  const stream = {
    id: "chatcmpl-" + randomUUID(), object: "chat.completion.chunk",
    created: Math.floor(Date.now() / 1000), model,
  };
  response.writeHead(200, { "Content-Type": "text/event-stream" });
  function send(delta, finish_reason) {
    const choices = [{ index: 0, delta, finish_reason }];
    response.write("data: " + JSON.stringify({ ...stream, choices }) + "\n\n");
  }
  send({ role: "assistant", content: receipt }, null);
  send({}, "stop");
  response.end("data: [DONE]\n\n");
}).listen(18080, "127.0.0.1");
