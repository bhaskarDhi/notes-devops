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
