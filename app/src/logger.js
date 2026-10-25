const pino = require('pino');
const config = require('./config');

const logger = pino({
  level: config.env === 'test' ? 'silent' : config.logLevel,
  base: { service: 'notes-app' },
});

module.exports = logger;
