const fs = require("fs");

function checkJson(source, name) {
  let index = 0;

  function fail(message) {
    throw new Error(`${name}:${index + 1}: ${message}`);
  }

  function whitespace() {
    while (/\s/.test(source[index] || "")) index++;
  }

  function string() {
    const start = index++;
    while (index < source.length) {
      if (source[index] === "\\") {
        index += 2;
      } else if (source[index++] === '"') {
        return JSON.parse(source.slice(start, index));
      }
    }
    fail("unterminated string");
  }

  function value(path) {
    whitespace();
    const character = source[index];
    if (character === "{") return object(path);
    if (character === "[") return array(path);
    if (character === '"') {
      string();
      return;
    }
    const token = source.slice(index).match(/^(?:true|false|null|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?)/)?.[0];
    if (!token) fail("invalid JSON value");
    index += token.length;
  }

  function object(path) {
    index++;
    whitespace();
    const keys = new Set();
    if (source[index] === "}") {
      index++;
      return;
    }
    while (index < source.length) {
      if (source[index] !== '"') fail("object key must be a string");
      const key = string();
      if (keys.has(key)) fail(`duplicate object key ${JSON.stringify(key)} at ${path}`);
      keys.add(key);
      whitespace();
      if (source[index++] !== ":") fail("missing colon after object key");
      value(`${path}.${key}`);
      whitespace();
      const delimiter = source[index++];
      if (delimiter === "}") return;
      if (delimiter !== ",") fail("missing comma between object members");
      whitespace();
    }
    fail("unterminated object");
  }

  function array(path) {
    index++;
    whitespace();
    if (source[index] === "]") {
      index++;
      return;
    }
    let item = 0;
    while (index < source.length) {
      value(`${path}[${item++}]`);
      whitespace();
      const delimiter = source[index++];
      if (delimiter === "]") return;
      if (delimiter !== ",") fail("missing comma between array items");
      whitespace();
    }
    fail("unterminated array");
  }

  value("$");
  whitespace();
  if (index !== source.length) fail("content after JSON value");
}

if (process.argv.length < 3) {
  console.error(`Usage: ${process.argv[1]} JSON_FILE [...]`);
  process.exit(2);
}

try {
  for (const path of process.argv.slice(2)) {
    checkJson(fs.readFileSync(path, "utf8"), path);
  }
} catch (error) {
  console.error(`ERROR: ${error.message}`);
  process.exit(1);
}
