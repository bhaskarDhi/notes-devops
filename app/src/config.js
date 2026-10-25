const fs = require('node:fs');

function dbSsl() {
  if (process.env.DB_SSL !== 'true') {
    return false;
  }
  const caFile = process.env.DB_SSL_CA_FILE;
  if (caFile) {
    return { ca: fs.readFileSync(caFile, 'utf8'), rejectUnauthorized: true };
  }
  return { rejectUnauthorized: false };
}

module.exports = {
  port: Number(process.env.PORT || 3000),
  logLevel: process.env.LOG_LEVEL || 'info',
  env: process.env.NODE_ENV || 'development',
  version: process.env.APP_VERSION || 'dev',
  db: {
    host: process.env.DB_HOST || 'localhost',
    port: Number(process.env.DB_PORT || 5432),
    user: process.env.DB_USER || 'notes',
    password: process.env.DB_PASSWORD || '',
    database: process.env.DB_NAME || 'notes',
    ssl: dbSsl(),
  },
};
