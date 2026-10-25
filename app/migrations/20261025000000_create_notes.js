exports.up = function (knex) {
  return knex.schema.createTable('notes', (table) => {
    table.increments('id').primary();
    table.string('title', 200).notNullable();
    table.text('content').notNullable().defaultTo('');
    table.timestamps(true, true);
  });
};

exports.down = function (knex) {
  return knex.schema.dropTable('notes');
};
