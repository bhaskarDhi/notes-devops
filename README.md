# notes-devops

Notes App (Node.js 24 + PostgreSQL 16) used to learn an intermediate CI/CD setup:
Terraform (AWS VPC, EC2, RDS, ECR), Ansible, Jenkins (as code), Trivy, Prometheus, Grafana, Loki.

See `docs/` for the system design and step-by-step notes.

## Run locally

```bash
cp .env.example .env            # then set DB_PASSWORD
docker compose up -d --build
docker compose exec app npm run migrate
docker compose exec app npm run seed
# open http://localhost:3005
```

## Run the tests (same command as CI)

```bash
docker compose -f compose.ci.yml run --rm --build tests
docker compose -f compose.ci.yml down -v
```
