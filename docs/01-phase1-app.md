# Phase 1: The Notes App (local)

**Goal:** a small but production-style Node.js app with a real database, tests, a secure Docker image, and a test command that is **identical** on the Mac and in CI.

**Done when:** the app runs at `http://localhost:3005` and the tests pass inside Docker.

---

## 1.1 What the app does

| Endpoint | Purpose | Used by |
|---|---|---|
| `GET /` | small HTML page (list, add, delete notes) | people |
| `GET/POST /api/notes`, `GET/PUT/DELETE /api/notes/:id` | REST API for notes | the page, tests |
| `GET /health` | "is the process alive?" + version (git commit) | Docker `HEALTHCHECK`, smoke test |
| `GET /ready` | "can I reach the database?" | smoke test, uptime probe |
| `GET /metrics` | numbers for Prometheus | monitoring (Phase 8) |

**Why two health endpoints?** `/health` answers even if the database is down, so we can tell "app crashed" apart from "database problem". `/ready` is what the smoke test and the uptime probe use: only "ready" means users can really use the app.

---

## 1.2 Decisions made in this phase

| # | Decision | Why |
|---|---|---|
| P1-1 | CommonJS (`require`), not ES modules | simplest for Jest and for beginners; no build step |
| P1-2 | Express 5 | handles errors thrown in `async` routes automatically (Express 4 needed try/catch everywhere) |
| P1-3 | All settings from environment variables (`src/config.js`) | same image everywhere; only the environment changes (12-factor app idea) |
| P1-4 | Database SSL option (`DB_SSL`, `DB_SSL_CA_FILE`) built in now | RDS for PostgreSQL 16 requires SSL by default (Phase 4) |
| P1-5 | Knex migrations, run as a **separate step** (`npm run migrate`), not automatically at app start | if several app copies start at once, they would race to change the database; an explicit step is safer and visible in the pipeline |
| P1-6 | Fixed demo data in a seed file (no Faker) | runs in the production image, which has no dev packages |
| P1-7 | JSON logs with only method, URL, status, time (`pino`) | Loki can search fields; no headers means no cookies or tokens in logs |
| P1-8 | Prometheus metrics in the app (`prom-client`) | request count, latency and errors per route: the basis for alerts |
| P1-9 | Security headers with `helmet`; the HTTPS-upgrade rule only in production | locally we use http; in production Caddy gives HTTPS |
| P1-10 | Graceful shutdown on `SIGTERM` | `docker stop` and deploys send SIGTERM; requests finish and DB connections close cleanly |
| P1-11 | Tests against real PostgreSQL via `compose.ci.yml` | same database engine as production; same command on Mac and Jenkins |
| P1-12 | Multi-stage Dockerfile: `deps` → `test` → `production` | tests run with dev packages; production image has none |
| P1-13 | Production image runs as user `node`; files owned by root, read-only | if the app is hacked, the attacker can't change the code or act as root |
| P1-14 | Git commit stamped into the image (`ARG GIT_SHA` → `APP_VERSION`, OCI label) | `/health` tells exactly which commit is running |
| P1-15 | Local port **3005** | 3000 was already used on the Mac by another project |

---

## 1.3 Project layout

```text
nodejs cicd/                 (Git repo: notes-devops)
├── app/
│   ├── src/
│   │   ├── app.js           Express app: middleware + routes
│   │   ├── server.js        starts the app, graceful shutdown
│   │   ├── config.js        settings from environment variables
│   │   ├── db.js            Knex database connection
│   │   ├── logger.js        pino JSON logger
│   │   ├── metrics.js       Prometheus metrics
│   │   └── routes/notes.js  notes API
│   ├── migrations/          database tables (Knex)
│   ├── seeds/               demo data
│   ├── public/              HTML page (index.html, app.js, style.css)
│   ├── tests/               Jest + Supertest
│   ├── knexfile.js          Knex settings
│   ├── eslint.config.js     code style rules
│   ├── package.json / package-lock.json
│   ├── Dockerfile
│   └── .dockerignore
├── compose.yml              local: app + postgres
├── compose.ci.yml           tests: tests + temporary postgres
├── .env.example             settings template (no secrets)
├── .gitignore
├── README.md
└── docs/                    this documentation
```

---

## 1.4 Dependencies

<sub>File: `app/package.json`</sub>

```json
{
  "name": "notes-app",
  "version": "1.0.0",
  "description": "Notes demo app for learning CI/CD (Node.js + PostgreSQL)",
  "private": true,
  "main": "src/server.js",
  "engines": {
    "node": ">=22"
  },
  "scripts": {
    "start": "node src/server.js",
    "dev": "node --watch src/server.js",
    "migrate": "knex migrate:latest --knexfile knexfile.js",
    "migrate:rollback": "knex migrate:rollback --knexfile knexfile.js",
    "seed": "knex seed:run --knexfile knexfile.js",
    "lint": "eslint .",
    "test": "jest --runInBand"
  },
  "jest": {
    "testEnvironment": "node",
    "globalSetup": "./tests/global-setup.js"
  },
  "dependencies": {
    "express": "^5.3.0",
    "helmet": "^8.3.0",
    "knex": "^3.3.0",
    "pg": "^8.23.1",
    "pino": "^10.4.0",
    "pino-http": "^11.0.0",
    "prom-client": "^15.1.3"
  },
  "devDependencies": {
    "@eslint/js": "^10.0.1",
    "eslint": "^10.13.0",
    "globals": "^17.13.0",
    "jest": "^30.5.2",
    "supertest": "^7.3.1"
  }
}
```

| Package | Why |
|---|---|
| `express` | web framework |
| `knex` + `pg` | SQL query builder + migrations, PostgreSQL driver |
| `pino` + `pino-http` | fast JSON logs |
| `prom-client` | Prometheus metrics |
| `helmet` | security headers |
| `jest`, `supertest` (dev) | tests; Supertest sends HTTP requests to the app without opening a port |
| `eslint`, `@eslint/js`, `globals` (dev) | code style and common-mistake checks |

`package-lock.json` pins the exact version of every package (and their dependencies). `npm ci` installs **exactly** those versions, so the Mac, Jenkins and the image get the same code. Result of the install: **0 vulnerabilities**.

---

## 1.5 Configuration and database

<sub>File: `app/src/config.js`</sub>

```javascript
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
```

- `DB_SSL=true` + `DB_SSL_CA_FILE` → verify the database certificate (used with RDS later).
- `DB_SSL=true` without a CA file → encrypted but not verified (fallback).
- Defaults make local development easy; production sets everything through `.env` (Phase 7, from SSM).

<sub>File: `app/knexfile.js`</sub>

```javascript
const config = require('./src/config');

module.exports = {
  client: 'pg',
  connection: config.db,
  pool: { min: 0, max: 10 },
  migrations: { directory: './migrations' },
  seeds: { directory: './seeds' },
};
```

<sub>File: `app/src/db.js`</sub>

```javascript
const knex = require('knex');
const knexConfig = require('../knexfile');

const db = knex(knexConfig);

module.exports = db;
```

### Migration

<sub>File: `app/migrations/20261025000000_create_notes.js`</sub>

```javascript
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
```

- `up` creates the table, `down` removes it (`npm run migrate:rollback`).
- `timestamps(true, true)` adds `created_at` and `updated_at` with default `now()`.
- Knex records applied migrations in a table `knex_migrations`, so `migrate` only runs new files.

### Seed (demo data)

<sub>File: `app/seeds/01_demo_notes.js`</sub>

```javascript
exports.seed = async function (knex) {
  await knex('notes').del();
  await knex('notes').insert([
    { title: 'Welcome to Notes', content: 'This app is deployed by a CI/CD pipeline.' },
    { title: 'Phase 1', content: 'Build the app, the tests and the Docker image.' },
    { title: 'Phase 4', content: 'Terraform creates the VPC, servers and RDS.' },
    { title: 'Phase 7', content: 'Jenkins: lint, test, build, scan, push, deploy, smoke test.' },
  ]);
};
```

---

## 1.6 The application code

### `app/src/app.js`

<sub>File: `app/src/app.js`</sub>

```javascript
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
```

| Part | Why |
|---|---|
| `app.disable('x-powered-by')` | don't advertise "Express" to attackers |
| `helmet({...})` | security headers (CSP, HSTS, no-sniff...); HTTPS upgrade only in production |
| `pinoHttp({... serializers})` | one JSON log line per request; skip `/health` and `/metrics` (noise) |
| `metricsMiddleware` | measure every request |
| `express.json({ limit: '100kb' })` | refuse huge bodies (simple protection) |
| `/ready` → `select 1` | proves the database answers; returns **503** if not |
| 404 handler + error handler | always JSON; never leak stack traces to users |

### `app/src/routes/notes.js`

<sub>File: `app/src/routes/notes.js`</sub>

```javascript
const express = require('express');
const db = require('../db');

const router = express.Router();

function parseId(req, res) {
  const id = Number(req.params.id);
  if (!Number.isInteger(id) || id < 1) {
    res.status(400).json({ error: 'id must be a positive number' });
    return null;
  }
  return id;
}

function validate(body) {
  const title = typeof body.title === 'string' ? body.title.trim() : '';
  const content = typeof body.content === 'string' ? body.content : '';
  if (!title) return { error: 'title is required' };
  if (title.length > 200) return { error: 'title must be at most 200 characters' };
  if (content.length > 5000) return { error: 'content must be at most 5000 characters' };
  return { title, content };
}

router.get('/', async (req, res) => {
  const notes = await db('notes').orderBy('created_at', 'desc').orderBy('id', 'desc');
  res.json(notes);
});

router.get('/:id', async (req, res) => {
  const id = parseId(req, res);
  if (id === null) return;
  const note = await db('notes').where({ id }).first();
  if (!note) return res.status(404).json({ error: 'note not found' });
  res.json(note);
});

router.post('/', async (req, res) => {
  const data = validate(req.body || {});
  if (data.error) return res.status(400).json({ error: data.error });
  const [note] = await db('notes').insert(data).returning('*');
  res.status(201).json(note);
});

router.put('/:id', async (req, res) => {
  const id = parseId(req, res);
  if (id === null) return;
  const data = validate(req.body || {});
  if (data.error) return res.status(400).json({ error: data.error });
  const [note] = await db('notes')
    .where({ id })
    .update({ ...data, updated_at: db.fn.now() })
    .returning('*');
  if (!note) return res.status(404).json({ error: 'note not found' });
  res.json(note);
});

router.delete('/:id', async (req, res) => {
  const id = parseId(req, res);
  if (id === null) return;
  const deleted = await db('notes').where({ id }).del();
  if (!deleted) return res.status(404).json({ error: 'note not found' });
  res.status(204).end();
});

module.exports = router;
```

- `parseId`: rejects `abc` or `-1` with 400 before touching the database.
- `validate`: title required, max 200; content max 5000 (same limits as the database column).
- `.returning('*')`: PostgreSQL returns the saved row in one query.

### `app/src/metrics.js`

<sub>File: `app/src/metrics.js`</sub>

```javascript
const client = require('prom-client');

const register = new client.Registry();
client.collectDefaultMetrics({ register });

const httpRequests = new client.Counter({
  name: 'http_requests_total',
  help: 'Number of HTTP requests',
  labelNames: ['method', 'route', 'status'],
  registers: [register],
});

const httpDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'HTTP request duration in seconds',
  labelNames: ['method', 'route', 'status'],
  buckets: [0.01, 0.05, 0.1, 0.25, 0.5, 1, 2, 5],
  registers: [register],
});

function metricsMiddleware(req, res, next) {
  const end = httpDuration.startTimer();
  res.on('finish', () => {
    let route = res.statusCode === 404 ? 'not_found' : 'static';
    if (req.route) {
      route = (req.baseUrl + req.route.path).replace(/(.)\/$/, '$1');
    }
    const labels = { method: req.method, route, status: String(res.statusCode) };
    httpRequests.inc(labels);
    end(labels);
  });
  next();
}

module.exports = { register, metricsMiddleware };
```

| Metric | Type | Use |
|---|---|---|
| `http_requests_total{method,route,status}` | counter | requests per second, error rate (5xx) |
| `http_request_duration_seconds` | histogram | latency, e.g. 95th percentile |
| default metrics (`process_*`, `nodejs_*`) | gauges | memory, CPU, event loop lag |

The `route` label uses the **route pattern** (`/api/notes/:id`), not the real URL (`/api/notes/17`). Otherwise every note id would create a new time series and Prometheus would fill up ("high cardinality").

### `app/src/logger.js` and `app/src/server.js`

<sub>File: `app/src/logger.js`</sub>

```javascript
const pino = require('pino');
const config = require('./config');

const logger = pino({
  level: config.env === 'test' ? 'silent' : config.logLevel,
  base: { service: 'notes-app' },
});

module.exports = logger;
```

<sub>File: `app/src/server.js`</sub>

```javascript
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
```

- Logs are silent during tests (clean test output).
- `server.close()` stops accepting new connections and waits for running requests; then the DB pool closes. The 10-second timer forces exit if something hangs.

### The page (`app/public/`)

<sub>File: `app/public/index.html`</sub>

```html
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Notes</title>
  <link rel="stylesheet" href="/style.css">
</head>
<body>
  <header>
    <h1><span>Notes</span> App</h1>
    <small id="version">Node.js + PostgreSQL</small>
  </header>
  <main>
    <form id="note-form">
      <input id="title" name="title" placeholder="Title" maxlength="200" required>
      <textarea id="content" name="content" placeholder="Write something..." maxlength="5000"></textarea>
      <button type="submit">Add note</button>
      <p id="error" class="error" hidden></p>
    </form>
    <ul id="notes"></ul>
  </main>
  <script src="/app.js"></script>
</body>
</html>
```

<sub>File: `app/public/app.js`</sub>

```javascript
const list = document.getElementById('notes');
const form = document.getElementById('note-form');
const errorBox = document.getElementById('error');

function showError(message) {
  errorBox.textContent = message;
  errorBox.hidden = !message;
}

function render(notes) {
  list.innerHTML = '';
  if (notes.length === 0) {
    const empty = document.createElement('li');
    empty.className = 'empty';
    empty.textContent = 'No notes yet.';
    list.appendChild(empty);
    return;
  }
  for (const note of notes) {
    const item = document.createElement('li');
    const title = document.createElement('h3');
    title.textContent = note.title;
    const content = document.createElement('p');
    content.textContent = note.content;
    const remove = document.createElement('button');
    remove.textContent = 'Delete';
    remove.className = 'delete';
    remove.addEventListener('click', () => deleteNote(note.id));
    item.append(title, content, remove);
    list.appendChild(item);
  }
}

async function loadNotes() {
  const res = await fetch('/api/notes');
  render(await res.json());
}

async function deleteNote(id) {
  await fetch(`/api/notes/${id}`, { method: 'DELETE' });
  loadNotes();
}

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  const res = await fetch('/api/notes', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      title: document.getElementById('title').value,
      content: document.getElementById('content').value,
    }),
  });
  if (!res.ok) {
    const body = await res.json();
    showError(body.error || 'Could not save the note');
    return;
  }
  showError('');
  form.reset();
  loadNotes();
});

loadNotes();
```

The JavaScript is in its own file (not inline) because the security header `script-src 'self'` blocks inline scripts. Notes are inserted with `textContent` (never `innerHTML`), so a note containing `<script>` is shown as text, not run (prevents XSS).

---

## 1.7 Tests

<sub>File: `app/tests/global-setup.js`</sub>

```javascript
const knex = require('knex');
const knexConfig = require('../knexfile');

module.exports = async function globalSetup() {
  const db = knex(knexConfig);
  await db.migrate.latest();
  await db.destroy();
};
```

<sub>File: `app/tests/health.test.js`</sub>

```javascript
const request = require('supertest');
const app = require('../src/app');
const db = require('../src/db');

afterAll(() => db.destroy());

describe('health endpoints', () => {
  test('GET /health returns ok', async () => {
    const res = await request(app).get('/health');
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('ok');
    expect(res.body.version).toBeDefined();
  });

  test('GET /ready checks the database', async () => {
    const res = await request(app).get('/ready');
    expect(res.status).toBe(200);
    expect(res.body.database).toBe('ok');
  });

  test('GET /metrics returns Prometheus metrics', async () => {
    await request(app).get('/health');
    const res = await request(app).get('/metrics');
    expect(res.status).toBe(200);
    expect(res.text).toContain('http_requests_total');
  });

  test('unknown route returns 404 JSON', async () => {
    const res = await request(app).get('/nope');
    expect(res.status).toBe(404);
    expect(res.body.error).toBe('not found');
  });
});
```

<sub>File: `app/tests/notes.test.js`</sub>

```javascript
const request = require('supertest');
const app = require('../src/app');
const db = require('../src/db');

beforeEach(() => db('notes').truncate());
afterAll(() => db.destroy());

describe('notes API', () => {
  test('creates and lists notes (newest first)', async () => {
    await request(app).post('/api/notes').send({ title: 'First', content: 'a' }).expect(201);
    await request(app).post('/api/notes').send({ title: 'Second' }).expect(201);

    const res = await request(app).get('/api/notes').expect(200);
    expect(res.body.map((n) => n.title)).toEqual(['Second', 'First']);
  });

  test('rejects a note without title', async () => {
    const res = await request(app).post('/api/notes').send({ content: 'no title' });
    expect(res.status).toBe(400);
    expect(res.body.error).toBe('title is required');
  });

  test('rejects a title longer than 200 characters', async () => {
    const res = await request(app).post('/api/notes').send({ title: 'x'.repeat(201) });
    expect(res.status).toBe(400);
  });

  test('gets one note by id', async () => {
    const created = await request(app).post('/api/notes').send({ title: 'Read me' });
    const res = await request(app).get(`/api/notes/${created.body.id}`).expect(200);
    expect(res.body.title).toBe('Read me');
  });

  test('updates a note', async () => {
    const created = await request(app).post('/api/notes').send({ title: 'Old' });
    const res = await request(app)
      .put(`/api/notes/${created.body.id}`)
      .send({ title: 'New', content: 'changed' })
      .expect(200);
    expect(res.body.title).toBe('New');
    expect(res.body.content).toBe('changed');
  });

  test('deletes a note', async () => {
    const created = await request(app).post('/api/notes').send({ title: 'Bye' });
    await request(app).delete(`/api/notes/${created.body.id}`).expect(204);
    await request(app).get(`/api/notes/${created.body.id}`).expect(404);
  });

  test('returns 404 for a missing note and 400 for a bad id', async () => {
    await request(app).get('/api/notes/99999').expect(404);
    await request(app).get('/api/notes/abc').expect(400);
  });
});
```

| Part | Why |
|---|---|
| `globalSetup` runs migrations once | the test database gets the real tables |
| `beforeEach(() => db('notes').truncate())` | every test starts with an empty table |
| `afterAll(() => db.destroy())` | close connections so Jest can exit |
| `--runInBand` | test files run one after another (they share one database) |

<sub>File: `app/eslint.config.js`</sub>

```javascript
const js = require('@eslint/js');
const globals = require('globals');

module.exports = [
  { ignores: ['node_modules/', 'coverage/'] },
  js.configs.recommended,
  {
    files: ['**/*.js'],
    languageOptions: { ecmaVersion: 2024, sourceType: 'commonjs', globals: { ...globals.node } },
  },
  {
    files: ['tests/**/*.js'],
    languageOptions: { globals: { ...globals.jest } },
  },
  {
    files: ['public/**/*.js'],
    languageOptions: { sourceType: 'script', globals: { ...globals.browser } },
  },
];
```

---

## 1.8 Docker

### `app/Dockerfile`

<sub>File: `app/Dockerfile`</sub>

```dockerfile
FROM node:24-alpine AS base
WORKDIR /app


FROM base AS deps
COPY package.json package-lock.json ./
RUN npm ci --omit=dev


FROM base AS test
ENV NODE_ENV=test
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
CMD ["sh", "-c", "npm run lint && npm test"]


FROM base AS production
ENV NODE_ENV=production
ARG GIT_SHA=dev
ENV APP_VERSION=$GIT_SHA
LABEL org.opencontainers.image.source="https://github.com/bhaskarDhi/notes-devops" \
      org.opencontainers.image.revision=$GIT_SHA
COPY --from=deps /app/node_modules ./node_modules
COPY package.json knexfile.js ./
COPY src ./src
COPY migrations ./migrations
COPY seeds ./seeds
COPY public ./public
RUN chmod -R a+rX /app
USER node
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD wget -qO- http://127.0.0.1:3000/health || exit 1
CMD ["node", "src/server.js"]
```

| Stage / line | Why |
|---|---|
| `node:24-alpine` | official Node.js 24 LTS on Alpine Linux: small image |
| `deps`: `npm ci --omit=dev` | only production packages, exact versions from the lock file |
| `test`: `npm ci` + `COPY . .` + `npm run lint && npm test` | all packages + tests; used by `compose.ci.yml` and Jenkins |
| `production`: copy `node_modules` from `deps` + only the needed folders | no tests, no dev tools, no `.env` in the image |
| `ARG GIT_SHA` → `ENV APP_VERSION`, `LABEL ...revision` | the image knows its commit; `/health` shows it |
| `RUN chmod -R a+rX /app` | everyone may read; files stay owned by root (see problem 1.11) |
| `USER node` | run as a normal user, not root |
| `HEALTHCHECK ... wget /health` | Docker marks the container `healthy`/`unhealthy` |
| `CMD ["node", "src/server.js"]` | start Node directly (not via `npm`), so `SIGTERM` reaches the app |

### `app/.dockerignore`

<sub>File: `app/.dockerignore`</sub>

```gitignore
node_modules
coverage
.env
.git
Dockerfile
.dockerignore
*.md
```

### `compose.yml` (local)

<sub>File: `compose.yml`</sub>

```yaml
name: notes

services:

  db:
    image: postgres:16-alpine
    container_name: notes-db
    environment:
      POSTGRES_DB: ${DB_NAME}
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - notes-pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}"]
      interval: 5s
      timeout: 5s
      retries: 10

  app:
    build:
      context: ./app
      target: production
    container_name: notes-app
    env_file:
      - .env
    ports:
      - "3005:3000"
    depends_on:
      db:
        condition: service_healthy

volumes:
  notes-pgdata:
```

### `compose.ci.yml` (tests)

<sub>File: `compose.ci.yml`</sub>

```yaml
name: notes-ci

services:

  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: notes_test
      POSTGRES_USER: notes
      POSTGRES_PASSWORD: notes_test_pw
    tmpfs:
      - /var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U notes -d notes_test"]
      interval: 2s
      timeout: 3s
      retries: 20

  tests:
    build:
      context: ./app
      target: test
    environment:
      NODE_ENV: test
      DB_HOST: db
      DB_PORT: "5432"
      DB_NAME: notes_test
      DB_USER: notes
      DB_PASSWORD: notes_test_pw
    depends_on:
      db:
        condition: service_healthy
```

| Part | Why |
|---|---|
| `name: notes-ci` | separate Compose project: never touches the local app's database |
| `tmpfs` for the database | data lives in memory: fast, and gone after the run |
| `target: test` | builds the test stage of the Dockerfile |
| `depends_on ... service_healthy` | tests start only when PostgreSQL is ready |

### Settings: `.env.example` and `.gitignore`

<sub>File: `.env.example`</sub>

```dotenv
NODE_ENV=development
PORT=3000
LOG_LEVEL=info

DB_HOST=db
DB_PORT=5432
DB_NAME=notes
DB_USER=notes
DB_PASSWORD=change_me_local
DB_SSL=false
```

<sub>File: `.gitignore`</sub>

```gitignore
# Node
node_modules/
coverage/
npm-debug.log*

# Secrets
.env
.env.*
!.env.example
*.pem

# Terraform
.terraform/
*.tfstate
*.tfstate.*
*.tfvars
!*.tfvars.example
crash.log

# Ansible
*.retry

# OS / editors
.DS_Store
.idea/
.vscode/
```

---

## 1.9 Commands

```bash
cd ~/Documents/"nodejs cicd"

# settings (once)
cp .env.example .env
sed -i '' 's/change_me_local/notes_local_pw/' .env

# tests (same as CI)
docker compose -f compose.ci.yml run --rm --build tests
docker compose -f compose.ci.yml down -v

# run the app
docker compose up -d --build
docker compose ps                         # notes-app: Up (healthy)
docker compose exec app npm run migrate   # Batch 1 run: 1 migrations
docker compose exec app npm run seed      # Ran 1 seed files
curl -s localhost:3005/health             # {"status":"ok","version":"dev"}
curl -s localhost:3005/ready              # {"status":"ready","database":"ok"}
# browser: http://localhost:3005

# stop
docker compose down                       # keep data
docker compose down -v                    # delete data too
```

---

## 1.10 Results

| Check | Result |
|---|---|
| `npm install` | 0 vulnerabilities |
| ESLint | no problems |
| Tests (real PostgreSQL 16) | 11 passed |
| Production-only install | starts; no jest/eslint/supertest inside |
| `/health` with `APP_VERSION=abc1234` | `{"status":"ok","version":"abc1234"}` |
| `SIGTERM` | logs "shutting down" → "bye", exit 0 |
| On the Mac (Docker) | migrate ✅, seed ✅, `/health` ✅, `/ready` ✅ |

---

## 1.11 Problems and fixes

### `Cannot read package config /app/package.json: permission denied`
- **Cause:** the files on the Mac had permissions `rw-------` (only the owner may read). Docker copies permissions into the image; the files belong to root there, and the app runs as user `node`, who may not read them.
- **Fix 1 (image):** `RUN chmod -R a+rX /app` before `USER node`. Works whatever the file permissions on the build machine are.
- **Fix 2 (Mac):** `chmod -R u=rwX,go=rX .` gives normal permissions (`rw-r--r--` files, `rwxr-xr-x` folders).
- **Lesson:** running as non-root is safer, but the user must still be able to **read** the code. Build images that don't depend on the build machine's file permissions.

### `npm install` fails with `ENOSYS: function not implemented, symlink`
- **Cause:** a shared folder that does not support symbolic links (npm creates links in `node_modules/.bin`).
- **Fix:** run `npm install` in a normal folder (or inside Docker). `node_modules` is never copied around anyway: it is rebuilt from `package-lock.json`.

### The `%` at the end of curl output
- Not an error: the response has no final newline and zsh marks that with `%`.
