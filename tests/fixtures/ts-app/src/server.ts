import { createServer } from 'node:http';
import ms from 'ms';

createServer((_, res) => res.end(ms(60000))).listen(process.env.PORT || 3000);
