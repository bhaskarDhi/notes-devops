const app = require('./app');
const config = require('./config');
const db = require('./db');
const logger = require('./logger');

const server = app.listen(config.port, () => {
  logger.info({ port: config.port, env: config.env }, 'notes-app started');
});

function shutdown(signal) {
  logger.info({ signal }, 'shutting down');
  server.close(async () => {
    await db.destroy();
    logger.info('bye');
    process.exit(0);
  });
  setTimeout(() => process.exit(1), 10000).unref();
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
