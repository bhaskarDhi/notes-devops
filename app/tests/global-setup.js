const knex = require('knex');
const knexConfig = require('../knexfile');

module.exports = async function globalSetup() {
  const db = knex(knexConfig);
  await db.migrate.latest();
  await db.destroy();
};
