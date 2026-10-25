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
