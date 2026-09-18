const test = require("node:test");
const assert = require("node:assert/strict");

const { extractHomePath, formatHomePath } = require("../path-conversion.js");

const HOME = "/Users/alice";

test("files input wins over uri-list and plain text", () => {
  assert.equal(
    extractHomePath({
      home: HOME,
      files: [{ uri: "file:///Users/alice/Documents/from-file.txt" }],
      uriList: "file:///Users/alice/Documents/from-uri.txt",
      plainText: "/Users/alice/Documents/from-text.txt",
    }),
    "/Users/alice/Documents/from-file.txt",
  );
});

test("single file URI decodes spaces and Japanese characters", () => {
  assert.equal(
    extractHomePath({
      home: HOME,
      files: [],
      uriList: "file:///Users/alice/My%20Files/%E8%B3%87%E6%96%99.txt",
      plainText: "",
    }),
    "/Users/alice/My Files/資料.txt",
  );
});

test("plain text accepts only one absolute path under home", () => {
  assert.equal(
    extractHomePath({ home: HOME, files: [], uriList: "", plainText: "/Users/alice/a b.txt" }),
    "/Users/alice/a b.txt",
  );
  for (const plainText of [
    "relative/file.txt",
    "/tmp/outside.txt",
    "/Users/alice/a\n/Users/alice/b",
    "ordinary text",
  ]) {
    assert.equal(extractHomePath({ home: HOME, files: [], uriList: "", plainText }), null);
  }
});

test("multiple files or URIs are rejected", () => {
  assert.equal(
    extractHomePath({
      home: HOME,
      files: [
        { uri: "file:///Users/alice/a" },
        { uri: "file:///Users/alice/b" },
      ],
      uriList: "",
      plainText: "",
    }),
    null,
  );
  assert.equal(
    extractHomePath({
      home: HOME,
      files: [],
      uriList: "file:///Users/alice/a\nfile:///Users/alice/b",
      plainText: "",
    }),
    null,
  );
});

test("iCloud Drive physical path is preserved below the home directory", () => {
  const absolute =
    "/Users/alice/Library/Mobile Documents/com~apple~CloudDocs/Work/資料.txt";
  assert.equal(
    formatHomePath({ home: HOME, absolutePath: absolute, languageId: "plaintext" }),
    "~/Library/Mobile Documents/com~apple~CloudDocs/Work/資料.txt",
  );
});

test("language-specific formatting uses portable home expressions and escapes syntax", () => {
  const absolute = '/Users/alice/Dir/a $b "c" \\ d.txt';
  assert.equal(
    formatHomePath({ home: HOME, absolutePath: absolute, languageId: "shellscript" }),
    '"$HOME/Dir/a \\$b \\"c\\" \\\\ d.txt"',
  );
  assert.equal(
    formatHomePath({ home: HOME, absolutePath: absolute, languageId: "lua" }),
    'os.getenv("HOME") .. "/Dir/a $b \\"c\\" \\\\ d.txt"',
  );
  assert.equal(
    formatHomePath({ home: HOME, absolutePath: absolute, languageId: "python" }),
    'Path.home() / "Dir/a $b \\"c\\" \\\\ d.txt"',
  );
  assert.equal(
    formatHomePath({ home: HOME, absolutePath: absolute, languageId: "markdown" }),
    '~/Dir/a $b "c" \\ d.txt',
  );
  assert.equal(
    formatHomePath({ home: HOME, absolutePath: absolute, languageId: "plaintext" }),
    '~/Dir/a $b "c" \\ d.txt',
  );
});

test("languages without a defined expansion rule are not auto-transformed", () => {
  const absolute = "/Users/alice/a.txt";
  for (const languageId of ["json", "jsonc", "yaml", "toml", "javascript", ""]) {
    assert.equal(formatHomePath({ home: HOME, absolutePath: absolute, languageId }), null);
  }
});
