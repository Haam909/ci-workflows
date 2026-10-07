const test = require("node:test");
const assert = require("node:assert");
test("second", () => assert.strictEqual(require("./index").second(), "1s"));
