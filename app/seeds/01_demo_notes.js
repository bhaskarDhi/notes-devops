exports.seed = async function (knex) {
  await knex('notes').del();
  await knex('notes').insert([
    { title: 'Welcome to Notes', content: 'This app is deployed by a CI/CD pipeline.' },
    { title: 'Phase 1', content: 'Build the app, the tests and the Docker image.' },
    { title: 'Phase 4', content: 'Terraform creates the VPC, servers and RDS.' },
    { title: 'Phase 7', content: 'Jenkins: lint, test, build, scan, push, deploy, smoke test.' },
  ]);
};
