import { readFile } from "node:fs/promises";
import { buildShadowAction } from "./shadow.js";

const args = process.argv.slice(2);
if (
  args.length !== 4 ||
  args[0] !== "--intent" ||
  args[2] !== "--simulation"
) {
  throw new Error("usage: shadow-cli --intent FILE --simulation FILE");
}

const [intent, simulation] = await Promise.all([
  readFile(args[1]!, "utf8").then(JSON.parse),
  readFile(args[3]!, "utf8").then(JSON.parse),
]);
process.stdout.write(`${JSON.stringify(buildShadowAction(intent, simulation))}\n`);
