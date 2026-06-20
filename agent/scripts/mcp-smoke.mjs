// Smoke test: launch the MCP server over stdio, list its tools, and call
// get_state (read-only, safe to run against a live round). Command-issuing
// tools (ping/say/order) are exercised separately once the mod is reloaded.
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const transport = new StdioClientTransport({ command: "node", args: ["src/mcp-server.js"] });
const client = new Client({ name: "smoke", version: "0.0.0" });
await client.connect(transport);

const { tools } = await client.listTools();
console.log(`tools (${tools.length}):`);
for (const t of tools) console.log(`  ${t.name} — ${(t.description || "").split(".")[0]}.`);

console.log("\nget_state →");
const res = await client.callTool({ name: "get_state", arguments: {} });
console.log((res.content?.[0]?.text ?? JSON.stringify(res)).slice(0, 700));
console.log(res.isError ? "\n(isError=true)" : "");

await client.close();
process.exit(0);
