const config = require('./src/config');

module.exports = {
  client: 'pg',
  connection: config.db,
  pool: { min: 0, max: 10 },
  migrations: { directory: './migrations' },
  seeds: { directory: './seeds' },
};
