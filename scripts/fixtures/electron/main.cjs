// A disposable Electron editor. No network, accounts, or chat submission.
const { app, BrowserWindow, Menu } = require('electron');
const fs = require('node:fs');
const path = require('node:path');
const directory = process.argv[2];
const token = path.basename(directory);
let window;
let menuEnabled = true;
app.whenReady().then(async () => {
  app.setAccessibilitySupportEnabled(true);
  function configureMenu(enabled) {
    menuEnabled = enabled;
    Menu.setApplicationMenu(Menu.buildFromTemplate(enabled
      ? [{ label: 'Edit', submenu: [{ role: 'paste' }] }]
      : []));
  }
  configureMenu(true);
  window = new BrowserWindow({ width: 680, height: 260 });
  // Apps with no native Paste item register the shortcut in their own key handler.
  window.webContents.on('before-input-event', (event, input) => {
    if (!menuEnabled && input.type === 'keyDown' && input.meta && input.key.toLowerCase() === 'v') {
      event.preventDefault();
      window.webContents.paste();
    }
  });
  await window.loadFile(path.join(__dirname, 'editor.html'));
  window.setTitle(`Flow Electron insertion check ${token}`);
  window.show();
  window.focus();
  fs.writeFileSync(path.join(directory, 'ready.json'), JSON.stringify({ pid: process.pid, token }));
  let command = '';
  let busy = false;
  setInterval(async () => {
    if (busy) return;
    busy = true;
    try {
      const next = fs.readFileSync(path.join(directory, 'command.json'), 'utf8');
      if (next !== command) {
        command = next;
        const config = JSON.parse(next);
        configureMenu(config.menu);
        await window.webContents.executeJavaScript(`resetEditor(${JSON.stringify(config)})`);
        window.focus();
      }
      const state = await window.webContents.executeJavaScript('editorState()');
      fs.writeFileSync(path.join(directory, 'state.json'), JSON.stringify(state));
    } catch {} finally { busy = false; }
  }, 40);
});
app.on('window-all-closed', () => app.quit());
