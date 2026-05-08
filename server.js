// WARNING: This allows arbitrary command execution - only use in isolated dev/testing environments
// DO NOT expose to the internet or use in production

const express = require('express');
const { exec } = require('child_process');

const app = express();
app.use(express.json());

app.post('/run', (req, res) => {
  const { cmd } = req.body;

  if (!cmd) {
    return res.status(400).json({ error: 'cmd is required' });
  }

  exec(cmd, (error, stdout, stderr) => {
    if (error) {
      return res.status(500).json({ error: error.message, stderr });
    }
    res.json({ stdout, stderr });
  });
});

const PORT = 3000;
app.listen(PORT, () => {
  console.log(`Server running on http://localhost:${PORT}`);
});
