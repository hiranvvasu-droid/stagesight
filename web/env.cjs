const fs = require('node:fs');
const path = require('node:path');
// Private local configuration. This file never prints environment values.
function loadPrivateEnv() {
  const file = path.join(__dirname, '.env.local');
  if (!fs.existsSync(file)) return;
  for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
    const match = line.match(/^([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$/);
    if (!match || process.env[match[1]]) continue;
    process.env[match[1]] = match[2].replace(/^(['"])(.*)\1$/, '$2');
  }
}
module.exports = { loadPrivateEnv };
