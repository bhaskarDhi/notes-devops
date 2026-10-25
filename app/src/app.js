const path = require('node:path');
const express = require('express');
const helmet = require('helmet');
const pinoHttp = require('pino-http');
const db = require('./db');
const config = require('./config');
const logger = require('./logger');
const { register, metricsMiddleware } = require('./metrics');
const notesRouter = require('./routes/notes');

const app = express();

app.disable('x-powered-by');
app.use(
  helmet({
    contentSecurityPolicy: {
      directives: { upgradeInsecureRequests: config.env === 'production' ? [] : null },
    },
  }),
);
app.use(
  pinoHttp({
    logger,
    autoLogging: { ignore: (req) => ['/health', '/metrics'].includes(req.url) },
    serializers: {
      req: (req) => ({ method: req.method, url: req.url }),
      res: (res) => ({ statusCode: res.statusCode }),
    },
  }),
);
app.use(metricsMiddleware);
app.use(express.json({ limit: '100kb' }));

app.get('/health', (req, res) => {
  res.json({ status: 'ok', version: config.version });
});

app.get('/ready', async (req, res) => {
  try {
    await db.raw('select 1');
    res.json({ status: 'ready', database: 'ok' });
  } catch (err) {
    req.log.error({ err }, 'database not reachable');
    res.status(503).json({ status: 'not ready', database: 'error' });
  }
});

app.get('/metrics', async (req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

app.use('/api/notes', notesRouter);
app.use(express.static(path.join(__dirname, '..', 'public')));

app.use((req, res) => {
  res.status(404).json({ error: 'not found' });
});

// eslint-disable-next-line no-unused-vars
app.use((err, req, res, next) => {
  req.log.error({ err }, 'unhandled error');
  const status = err.status || 500;
  res.status(status).json({ error: status === 500 ? 'internal server error' : err.message });
});

module.exports = app;
