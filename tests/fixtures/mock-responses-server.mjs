import { appendFileSync, writeFileSync } from "node:fs";
import http from "node:http";

const [readyPath, requestLogPath] = process.argv.slice(2);
if (!readyPath || !requestLogPath) {
  throw new Error("Usage: mock-responses-server.mjs <ready-path> <request-log-path>");
}

const usage = {
  input_tokens: 0,
  input_tokens_details: null,
  output_tokens: 0,
  output_tokens_details: null,
  total_tokens: 0,
};

function sse(events) {
  return events
    .map((event) => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`)
    .join("");
}

function functionCallResponse(cycle) {
  const number = cycle + 1;
  return sse([
    {
      type: "response.created",
      response: { id: `resp-loopback-${number}-call` },
    },
    {
      type: "response.output_item.done",
      item: {
        type: "function_call",
        call_id: `call-loopback-${number}`,
        name: "shell_command",
        arguments: JSON.stringify({ command: "git status --short" }),
      },
    },
    {
      type: "response.completed",
      response: { id: `resp-loopback-${number}-call`, usage },
    },
  ]);
}

function completionResponse(cycle) {
  const number = cycle + 1;
  return sse([
    {
      type: "response.created",
      response: { id: `resp-loopback-${number}-completion` },
    },
    {
      type: "response.output_item.done",
      item: {
        type: "message",
        role: "assistant",
        id: `msg-loopback-${number}`,
        content: [{ type: "output_text", text: "E2E_DONE" }],
      },
    },
    {
      type: "response.completed",
      response: { id: `resp-loopback-${number}-completion`, usage },
    },
  ]);
}

let responsesRequestCount = 0;
const server = http.createServer((request, response) => {
  const chunks = [];
  request.on("data", (chunk) => chunks.push(chunk));
  request.on("end", () => {
    const rawBody = Buffer.concat(chunks).toString("utf8");
    let body = null;
    if (rawBody) {
      try {
        body = JSON.parse(rawBody);
      } catch {
        body = { invalidJson: rawBody };
      }
    }
    appendFileSync(
      requestLogPath,
      `${JSON.stringify({ method: request.method, url: request.url, body })}\n`,
      "utf8",
    );

    if (request.method === "GET" && request.url?.endsWith("/models")) {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(
        JSON.stringify({
          object: "list",
          data: [
            {
              id: "gpt-5.2-codex",
              object: "model",
              created: 0,
              owned_by: "loopback",
            },
          ],
        }),
      );
      return;
    }

    if (request.method !== "POST" || request.url !== "/v1/responses") {
      response.writeHead(404, { "content-type": "application/json" });
      response.end(JSON.stringify({ error: "not found" }));
      return;
    }

    if (responsesRequestCount >= 4) {
      response.writeHead(500, { "content-type": "application/json" });
      response.end(JSON.stringify({ error: "unexpected extra Responses request" }));
      return;
    }
    const cycle = Math.floor(responsesRequestCount / 2);
    const payload =
      responsesRequestCount % 2 === 0
        ? functionCallResponse(cycle)
        : completionResponse(cycle);
    responsesRequestCount += 1;

    response.writeHead(200, {
      "content-type": "text/event-stream",
      "cache-control": "no-cache",
      connection: "close",
    });
    response.end(payload);
  });
});

server.listen(0, "127.0.0.1", () => {
  const address = server.address();
  if (!address || typeof address === "string") {
    throw new Error("Loopback server did not expose a TCP port");
  }
  writeFileSync(
    readyPath,
    JSON.stringify({
      host: "127.0.0.1",
      port: address.port,
      baseUrl: `http://127.0.0.1:${address.port}/v1`,
    }),
    "utf8",
  );
});

function shutdown() {
  server.close(() => process.exit(0));
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
