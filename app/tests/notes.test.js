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
