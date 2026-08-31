const fs = require("fs");
const commonmark = require("commonmark");

const path = process.argv[2];
if (!path) {
  console.error(`Usage: ${process.argv[1]} MARKDOWN_FILE`);
  process.exit(2);
}

const source = fs.readFileSync(path, "utf8");
const lines = source.split("\n");
const hiddenLines = new Set();
const headingColumns = new Map();
const walker = new commonmark.Parser().parse(source).walker();
let event;

while ((event = walker.next())) {
  if (!event.entering) continue;
  if (event.node.type === "heading") {
    const [[line, column]] = event.node.sourcepos;
    headingColumns.set(line, column);
    continue;
  }
  if (!["code_block", "html_block"].includes(event.node.type)) continue;
  const [[start], [end]] = event.node.sourcepos;
  for (let line = start; line <= end; line++) hiddenLines.add(line);
}

process.stdout.write(
  lines
    .map((line, index) => {
      const lineNumber = index + 1;
      if (hiddenLines.has(lineNumber)) return "";
      return line.slice((headingColumns.get(lineNumber) || 1) - 1);
    })
    .join("\n"),
);
