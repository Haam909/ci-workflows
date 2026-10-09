const http = require("node:http");
const ms = require("ms");

const handler = (req, res) => res.end(req.url === "/health" ? "healthy" : `up ${ms(1000)}`);
module.exports = { handler };

if (require.main === module) http.createServer(handler).listen(process.env.PORT || 8080);
