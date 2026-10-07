const ms = require('ms');
require('http').createServer((_, res) => res.end(ms(60000))).listen(process.env.PORT || 3000);
