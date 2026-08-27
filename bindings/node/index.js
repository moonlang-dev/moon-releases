const root = require("path").join(__dirname, "..", "..");

const binding = require("node-gyp-build")(root);

try {
  binding.nodeTypeInfo = require("../../src/node-types.json");
} catch (_) {}

module.exports = binding;
